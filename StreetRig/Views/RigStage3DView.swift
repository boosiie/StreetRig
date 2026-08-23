//
//  RigStage3DView.swift
//  StreetRig
//
//  The whole rig as ONE 3D diorama in a single SceneKit view: the amp (center),
//  the pedalboard (in front), and the guitar (to the right, leaning on the stage's
//  own bar stool) all standing on a modelled floor and lit together. Dragging
//  orbits the entire scene at once — "moving the living room" — instead of the old
//  split model where a SwiftUI rotation3DEffect warped a flat snapshot while each
//  model orbited on its own.
//
//  Tapping a component plays a TWO-STAGE focus transition: stage 1 flies the
//  camera in to center that component and turn it face-on ("flat" to the screen);
//  when that lands, stage 2 zooms the control overlay in (see MainView). Closing
//  the overlay flies the camera back to the diorama.
//
//  Reuses the same procedural builders as the standalone views (ProceduralAmp,
//  PedalboardScene); the guitar comes through `GearModelLoader.guitarNode`, which
//  falls back to ProceduralGuitar. The amp head and the cabinet each wear
//  their own bespoke artwork when they have one — the SAME `<slug>.imageset`
//  that dresses the cards and the library, mapped onto the front of the box —
//  so swapping either piece visibly changes the stack. A piece with no artwork
//  falls back to the generic build, whose knobs turn live from GearItem.values.
//  Gated by FeatureFlags.amp3D. EVERY amp section renders here, a combo included:
//  a combo is simply a one-box amp in the same scene, so choosing one no longer
//  drops the whole stage — board and guitar with it — back to the flat layout.
//

import SwiftUI
import StreetRigEngine
import SceneKit
import simd
import UIKit

/// What a dragged gear card would replace on the 3D stage, resolved by what the
/// finger is hovering over. `nil` means "no specific piece" → the caller falls
/// back to a category-based apply (amp/cab replace the stack, a pedal is added).
enum RigDropTarget: Equatable {
    case ampStack
    case pedal(UUID)
    /// The marker beside the board: ADD this pedal rather than swap it for one
    /// already down there. Without it a board with pedals on it can only ever be
    /// replaced into, never grown.
    case addPedal
}

struct RigStage3DView: UIViewRepresentable {
    var amp: GearItem?
    /// The cabinet under the head. Threaded all the way through to the scene
    /// builder so the lower box can wear the selected cab's artwork — without
    /// it the diorama drew one hardcoded 4x12 no matter what was in the rig.
    var cabinet: GearItem?
    var pedals: [GearItem]
    var guitar: GearItem?
    /// The stage's current focus. When it returns to nil the camera flies back.
    var focused: RigComponent?
    /// True while a PEDAL is in the air anywhere — the add-slot marker shows for
    /// exactly that long. Driven from the drag rather than from the hover so the
    /// place to drop appears as the card leaves the rail, which is when the player
    /// is deciding where to go, not after they have already guessed.
    var pedalInFlight: Bool = false
    /// Fired after stage 1 lands, so the stage can open the zoom overlay (stage 2).
    var onFocus: ((RigComponent) -> Void)? = nil
    /// Fired when a gear card is dropped on the stage. `target` is the specific
    /// piece under the finger (highlighted during the drag), or nil for a
    /// drop that didn't land on a compatible piece.
    var onDrop: ((RigDropTarget?, GearItem) -> Void)? = nil
    /// The stage's registration with the custom drag controller. This view wires
    /// the live scene into it so the rail's drag can hit-test and highlight the 3D
    /// models under the finger.
    var dropArea: RigDropArea
    /// The drag controller itself, which the stage needs as a drag SOURCE: a piece
    /// lifted off the board here uses the same ghost, the same trash and the same
    /// window→appRoot conversion as a card lifted out of the rail.
    var controller: RigDragController

    func makeCoordinator() -> Coordinator { Coordinator(onFocus: onFocus) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.autoenablesDefaultLighting = false

        // One camera controller orbits the whole diorama around its center.
        // Inertia off so releasing hands straight over to the gentle spring-back.
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = false
        view.defaultCameraController.target = RigDiorama.lookTarget
        view.defaultCameraController.minimumVerticalAngle = -6      // don't dip under the floor
        view.defaultCameraController.maximumVerticalAngle = 80

        context.coordinator.view = view
        rebuild(view, context: context)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)

        // Watch the orbit gesture (alongside the built-in camera control) so we can
        // gently spring the view back to the centered pose when the user lets go.
        let orbit = UIPanGestureRecognizer(target: context.coordinator,
                                           action: #selector(Coordinator.handleOrbitPan(_:)))
        orbit.delegate = context.coordinator
        // ONE finger only — an orbit is a one-finger gesture, and a pan recognizer
        // otherwise accepts any number of touches, so a two-finger pinch was driving
        // this handler as well as the pinch one.
        orbit.maximumNumberOfTouches = 1
        view.addGestureRecognizer(orbit)

        // The pinch is ours end to end — it does the zooming AND the spring-back,
        // with the built-in controller switched off for the duration so there is no
        // second owner of the camera. See `handlePinch` for why it is not an
        // observer of the built-in zoom (two attempts at that did not come back).
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator
        pinch.cancelsTouchesInView = false      // leave the tap/orbit recognizers alone
        view.addGestureRecognizer(pinch)

        // Backstop: even if none of the above fires, this notices the camera sitting
        // away from home and brings it back. See `startZoomWatchdog`.
        context.coordinator.startZoomWatchdog()

        // Press-and-hold a piece to LIFT it off the stage and drag it to the
        // rail's trash. Deliberately the same 0.4s hold as a rail card
        // (GearCardView.dragGesture) so the whole app has one "pick gear up".
        //
        // It is a separate recognizer rather than a change to the hit-testing:
        // `componentUnderPoint` is reused untouched, so drag-to-replace and
        // tap-to-focus keep the exact behaviour they had. The tap recognizer
        // can't misfire here either — a UITapGestureRecognizer fails once the
        // touch is held past its own short limit, so a hold never zooms.
        let lift = UILongPressGestureRecognizer(target: context.coordinator,
                                                action: #selector(Coordinator.handleLift(_:)))
        lift.minimumPressDuration = 0.4
        // Tight, so a swipe across the stage still pages the app shell and only a
        // press that really stays put lifts a piece.
        lift.allowableMovement = 12
        lift.delegate = context.coordinator
        view.addGestureRecognizer(lift)

        // Wire this live scene into the stage's drop target. As the rail's drag
        // moves, `onHover` hit-tests the models under the finger and glows the
        // piece it would replace; `onDrop` swaps it. Points arrive in this view's
        // coordinate space (the controller subtracts the stage's frame origin).
        let coord = context.coordinator
        dropArea.onHover = { [weak coord] point, item, _ in
            coord?.highlightForDrag(at: point, item: item)
        }
        dropArea.onExit = { [weak coord] in
            coord?.setHighlight(nil)
            coord?.setAddSlotHot(false)
            coord?.currentTarget = nil
        }
        dropArea.onDrop = { [weak coord] item, _ in
            guard let coord else { return }
            coord.dropHandler?(coord.currentTarget, item)
        }
        coord.controller = controller
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let coord = context.coordinator
        coord.onFocus = onFocus
        coord.dropHandler = onDrop
        // The lift gesture hit-tests to a node NAME; these resolve that name back
        // to the real GearItem to hand the drag controller.
        coord.stagePedals = pedals
        coord.stageGuitar = guitar
        coord.stageAmp = amp
        coord.setAddSlot(visible: pedalInFlight)

        let sig = RigDiorama.signature(amp: amp, cabinet: cabinet, pedals: pedals, guitar: guitar)
        if coord.signature != sig {
            rebuild(view, context: context)          // gear set changed → rebuild
        } else {
            coord.applyAmp(values: amp?.values ?? [:])   // just knob values
        }

        // Overlay dismissed (focus → nil) → fly the camera back to the diorama.
        if focused == nil, coord.focusedNow != nil, !coord.animatingForward {
            coord.resetCamera()
        }
    }

    /// Rebuild the scene but keep the user's current camera orientation.
    private func rebuild(_ view: SCNView, context: Context) {
        context.coordinator.clearHighlight()      // old nodes are about to be replaced
        let scene = RigDiorama.make(amp: amp, cabinet: cabinet, pedals: pedals, guitar: guitar)
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: false)
        view.defaultCameraController.target = RigDiorama.lookTarget
        context.coordinator.cacheKnobs(in: scene, names: AmpScene.knobParamNames(for: amp))
        context.coordinator.applyAmp(values: amp?.values ?? [:])
        context.coordinator.signature = RigDiorama.signature(amp: amp, cabinet: cabinet,
                                                             pedals: pedals, guitar: guitar)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onFocus: ((RigComponent) -> Void)?
        var dropHandler: ((RigDropTarget?, GearItem) -> Void)?
        weak var view: SCNView?
        var signature = ""

        /// Component the camera is currently focused on (or flying toward).
        var focusedNow: RigComponent?
        /// True while stage 1 (the fly-in) is animating, so the return handler
        /// in updateUIView doesn't misfire before stage 2 has even opened.
        var animatingForward = false
        /// The diorama zoom radius (distance from lookTarget) captured the instant
        /// the user tapped into focus, so closing the overlay restores THEIR zoom
        /// rather than the fixed far default. nil until the first focus.
        var preFocusDistance: Float?

        private var knobs: [String: SCNNode] = [:]

        // Drag-to-replace state (driven by RigDragController).
        var currentTarget: RigDropTarget?             // what a drop right now would replace
        private var highlightedNode: SCNNode?

        // Drag-OFF state (this view driving RigDragController, the other way round).
        /// The shared drag controller, so a piece lifted here uses the same ghost,
        /// the same "appRoot" space and the same trash target as a rail card.
        var controller: RigDragController?
        /// The gear currently on the stage, kept in sync by `updateUIView`.
        var stagePedals: [GearItem] = []
        var stageGuitar: GearItem?
        var stageAmp: GearItem?
        /// The piece hidden for the duration of a lift, and what it was. While a
        /// piece is in your hand as a card it must not ALSO be sitting on the
        /// stage — the ghost is the piece, not a copy of it.
        private var liftedNode: SCNNode?
        private var liftedShadow: SCNNode?
        private var liftedComponent: RigComponent?
        /// True from the moment a lift is recognised until the finger comes up.
        private var lifting = false
        /// Scroll views switched off for the duration of a lift — in practice the
        /// app shell's paging TabView, which this stage sits inside. Dragging a
        /// pedal toward the rail is a leftward swipe, and without this the pager
        /// reads it as "go to the previous page" and slides the whole stage out
        /// from under the finger (which also drags the reported `stageFrame`
        /// along with it, so the ghost stops tracking).
        private var suspendedScrollViews: [UIScrollView] = []
        // Each affected material saved ONCE (deduped) so shared materials restore cleanly.
        private var savedMultiply: [(material: SCNMaterial, contents: Any?, intensity: CGFloat)] = []

        init(onFocus: ((RigComponent) -> Void)?) { self.onFocus = onFocus }

        /// Cache the live knob nodes. An art-textured head has none — its knobs
        /// are part of the drawing (see `ProceduralAmp.build`) — so these lookups
        /// return nil, the keys never land in the dictionary, and `applyAmp`
        /// simply has nothing to turn. That is the expected quiet path, not a bug.
        func cacheKnobs(in scene: SCNScene, names: [String]) {
            knobs.removeAll()
            for p in names {
                knobs[p] = scene.rootNode.childNode(withName: AmpScene.knobNodeName(p), recursively: true)
            }
        }

        func applyAmp(values: [String: Double]) {
            for (name, node) in knobs {
                node.eulerAngles.z = Studio3D.knobAngle(forValue: values[name] ?? 5)
            }
        }

        // MARK: Tap → stage 1

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let view, focusedNow == nil else { return }        // ignore taps while focused
            guard let (component, node) = componentUnderPoint(g.location(in: view)) else { return }
            switch component {
            case .pedal:                     focus(on: node, component: component)
            case .amp, .cabinet, .combo:     focus(on: node, component: .amp)
            case .guitar:                    break     // no controls to adjust
            }
        }

        /// Hit-test the scene at `point` and walk up to the nearest named gear
        /// group, returning which component it is and that group node. Shared by
        /// tap-to-focus and drag-to-replace.
        func componentUnderPoint(_ point: CGPoint) -> (RigComponent, SCNNode)? {
            guard let view else { return nil }
            let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
            for hit in hits {
                var node: SCNNode? = hit.node
                while let n = node {
                    if let name = n.name {
                        if name.hasPrefix("pedal_"),
                           let id = UUID(uuidString: String(name.dropFirst("pedal_".count))) {
                            return (.pedal(id), n)
                        }
                        if name == "ampRoot"    { return (.amp, n) }
                        if name == "guitarRoot" { return (.guitar, n) }
                    }
                    node = n.parent
                }
            }
            return nil
        }

        /// Stage 1: fly the camera in to center `node` and view its control face
        /// straight-on. When it lands, hand off to stage 2 via `onFocus`.
        private func focus(on node: SCNNode, component: RigComponent) {
            guard let view, let cam = view.pointOfView else { return }
            focusedNow = component
            animatingForward = true
            // Remember the diorama zoom before we take over the camera, so closing the
            // overlay (resetCamera) returns to the distance the user chose instead of
            // the far default. Read the on-screen (presentation) distance so it's right
            // even if a spring-back was still easing when they tapped.
            preFocusDistance = RigDiorama.distance(from: cam.presentation.position, to: RigDiorama.lookTarget)
            view.allowsCameraControl = false                 // take over the camera

            let (pos, ori) = focusPose(for: node, component: component)
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.6
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            SCNTransaction.completionBlock = { [weak self] in
                guard let self else { return }
                self.animatingForward = false
                DispatchQueue.main.async { self.onFocus?(component) }   // stage 2
            }
            cam.position = pos
            cam.orientation = ori
            SCNTransaction.commit()
        }

        /// Fly the camera back to the diorama and hand control back to the user.
        /// Gently recenters the viewing ANGLE to the home framing while restoring the
        /// user's pre-focus zoom (the distance captured in `focus(on:)`), so closing
        /// the overlay no longer shoves the camera out to the fixed far pose. The
        /// orientation eases as a quaternion via `framedPose` (shortest arc) rather
        /// than `eulerAngles`, which could unwrap the long way around.
        func resetCamera() {
            focusedNow = nil
            guard let view, let cam = view.pointOfView else { return }
            let (pos, ori) = RigDiorama.framedPose(
                atDistanceFromTarget: preFocusDistance ?? RigDiorama.defaultCameraDistance)
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.5
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            SCNTransaction.completionBlock = { [weak view] in
                guard let view else { return }
                view.defaultCameraController.target = RigDiorama.lookTarget
                view.allowsCameraControl = true
            }
            cam.position = pos
            cam.orientation = ori
            SCNTransaction.commit()
        }

        // MARK: Orbit → gentle spring back to center

        /// Camera→lookTarget radius at the instant a pinch began; the pinch's scale
        /// is applied against it. Zero means no pinch is in flight.
        private var pinchStartDistance: Float = 0

        // MARK: Zoom watchdog — the backstop that does not trust gesture plumbing

        private var zoomWatchdog: Timer?

        /// Watches the CAMERA rather than any gesture, and pulls it home whenever it
        /// is parked away from the default distance with nothing being touched.
        ///
        /// This exists because two recognizer-based attempts at the zoom rubber band
        /// both failed on device, and the Simulator could not be driven reliably
        /// enough to tell me which link in the chain was broken. Watching the result
        /// instead of the cause sidesteps the question entirely: it does not matter
        /// whether our pinch handler ran, whether SceneKit's built-in controller did
        /// the zooming, or whether the two fought — if the camera ends up somewhere
        /// other than home and the user is not touching the screen, it comes back.
        ///
        /// Deliberately cheap and deliberately dumb: 10 Hz, a distance compare, and
        /// an early-out while any recognizer is mid-gesture so it can never yank the
        /// view out from under a live pinch.
        func startZoomWatchdog() {
            zoomWatchdog?.invalidate()
            zoomWatchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.springBackIfCameraDrifted()
            }
        }

        private func springBackIfCameraDrifted() {
            guard focusedNow == nil, !animatingForward, let view, let cam = view.pointOfView else { return }
            // Never interrupt a gesture that is still in progress.
            if let gestures = view.gestureRecognizers,
               gestures.contains(where: { $0.state == .began || $0.state == .changed }) { return }
            // Compare the MODEL position, not the presentation one: the spring sets
            // the model value immediately, so an in-flight return already reads as
            // "home" here and cannot re-trigger itself every tick.
            let d = RigDiorama.distance(from: cam.position, to: RigDiorama.lookTarget)
            guard abs(d - RigDiorama.defaultCameraDistance) > 0.02 else { return }
            springBackToCenter()
        }

        deinit { zoomWatchdog?.invalidate() }

        @objc func handleOrbitPan(_ g: UIPanGestureRecognizer) {
            // `!lifting`: a piece is being pulled off the stage, so the finger is
            // moving the GEAR, not the camera. Without this the diorama would
            // orbit out from under the drag (and spring back on release).
            guard focusedNow == nil, !lifting, let view, let cam = view.pointOfView else { return }
            switch g.state {
            case .began:
                // Catch the camera mid-return (if any) so this orbit resumes from there
                // without a jump, and make sure control is back on in case the snap had
                // taken it offline.
                cam.position = cam.presentation.position
                cam.orientation = cam.presentation.orientation
                cam.removeAllAnimations()
                cam.removeAllActions()          // stop the snapback glide, if any
                view.allowsCameraControl = true
            case .ended, .cancelled, .failed:
                springBackToCenter()
            default:
                break
            }
        }

        // MARK: Pinch → spring the ZOOM back too

        /// The zoom half of the rubber band — and this handler does the ZOOMING as
        /// well as the spring-back, deliberately.
        ///
        /// Two earlier attempts left this as a passive observer of
        /// `allowsCameraControl`'s built-in pinch, and neither made the camera come
        /// back. Rather than keep guessing which half was at fault — the observer
        /// never firing, or the built-in controller restoring its own cached pose
        /// once control was handed back and undoing the ease — the zoom is now ours
        /// end to end. The built-in controller is switched OFF for the duration of
        /// the pinch, so there is no second owner of the camera to fight, and this
        /// handler cannot silently fail to run: if the view zooms at all, it ran.
        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard focusedNow == nil, let view, let cam = view.pointOfView else { return }
            switch g.state {
            case .began:
                // Catch the camera mid-return so the pinch resumes from where it
                // actually is instead of jumping.
                cam.position = cam.presentation.position
                cam.orientation = cam.presentation.orientation
                cam.removeAllAnimations()
                cam.removeAllActions()
                view.allowsCameraControl = false        // we own the camera now
                pinchStartDistance = RigDiorama.distance(from: cam.position,
                                                         to: RigDiorama.lookTarget)
            case .changed:
                guard pinchStartDistance > 0 else { return }
                // Fingers apart (scale > 1) = zoom in = a SMALLER radius. Clamped to
                // the same bounds `framedPose` uses, so a pinch can never crop the
                // pedalboard (see `minCameraDistance`).
                let raw = pinchStartDistance / Float(max(g.scale, 0.01))
                let d = min(max(raw, RigDiorama.minCameraDistance), RigDiorama.maxCameraDistance)
                let t = RigDiorama.lookTarget, p = cam.position
                let v = SCNVector3(p.x - t.x, p.y - t.y, p.z - t.z)
                let len = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
                guard len > 1e-5 else { return }
                // Change ONLY the radius — the user keeps whatever angle they orbited to.
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0     // track the fingers exactly
                cam.position = SCNVector3(t.x + v.x / len * d,
                                          t.y + v.y / len * d,
                                          t.z + v.z / len * d)
                SCNTransaction.commit()
            case .ended, .cancelled, .failed:
                pinchStartDistance = 0
                springBackToCenter()                     // hands control back on landing
            default:
                break
            }
        }

        /// Snap the camera back to the framed home view when the user lets go —
        /// ANGLE *and* ZOOM, always, whichever gesture they were using.
        ///
        /// This deliberately does NOT try to be clever about which recognizer saw the
        /// gesture. An earlier version preserved the user's zoom on an orbit release
        /// and only rubber-banded it on a pinch release, which meant the behaviour
        /// depended on UIKit's choice of recognizer for a given touch sequence — and
        /// a two-finger pinch drives BOTH a pinch and (by default) a pan, so the
        /// preserve-zoom path could win the race and silently cancel the return. The
        /// stage has one composed home view; every gesture ends back at it.
        ///
        /// This mirrors the fly-IN exactly: take the camera offline
        /// (`allowsCameraControl = false`, handed back on landing) and let a single
        /// SCNTransaction ease both position and orientation to the exact home pose.
        /// SCNTransaction is Core-Animation driven, so it always advances and settles
        /// precisely on the final values — no frozen frames, no partial move, no end
        /// teleport. (Hand-driving it per frame with an SCNAction stalled against the
        /// render loop, which is what left the camera on a weird angle until the final
        /// set snapped it straight.) Offline also stops the camera controller fighting it.
        private func springBackToCenter() {
            guard focusedNow == nil, let view, let cam = view.pointOfView else { return }
            let (end, endOrientation) =
                RigDiorama.framedPose(atDistanceFromTarget: RigDiorama.defaultCameraDistance)

            view.allowsCameraControl = false               // take over so nothing fights the ease
            cam.position = cam.presentation.position        // start from the live pose so it eases,
            cam.orientation = cam.presentation.orientation  // rather than jumping, from where they let go
            cam.removeAllAnimations()
            cam.removeAllActions()

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.55
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            SCNTransaction.completionBlock = { [weak view] in
                guard let view else { return }
                view.defaultCameraController.target = RigDiorama.lookTarget
                view.allowsCameraControl = true            // hand control back to the user
            }
            cam.position = end                             // straight to the home pose…
            cam.orientation = endOrientation               // …ending square on the home angle
            SCNTransaction.commit()
        }

        /// Camera position + orientation that centers `node` and looks straight
        /// at its control face (knob panel for a pedal, faceplate for the amp,
        /// body front for the guitar) so it reads "flat" to the screen.
        private func focusPose(for node: SCNNode, component: RigComponent) -> (SCNVector3, SCNQuaternion) {
            // Per component: a local focal point to keep dead-center, the control
            // face normal to look along, and how far back the camera sits.
            let localFocus: SCNVector3
            let localNormal: SCNVector3
            let dist: Float
            switch component {
            case .pedal:
                localFocus = SCNVector3(0, 0.47, -0.42)  // the center knob (middle of the top row)
                localNormal = SCNVector3(0, 0.85, 0.5)   // knob panel (top), tilted toward the front
                dist = 1.15
            case .amp, .cabinet, .combo:
                // Measured, not baked. The amp root is now any of three shapes —
                // a generic stack, an art-fitted stack of different proportions,
                // or a single squat combo — so a fixed focal point (it used to be
                // the original head's knob row) framed empty air above a combo.
                // Centre on whatever is actually there, at its front face.
                let (lo, hi) = node.boundingBox
                localFocus = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, hi.z)
                localNormal = SCNVector3(0, 0, 1)        // straight-on to the front → flat to the screen
                // Pull back in proportion to the piece's real world height so a
                // combo and a full stack fill about the same fraction of frame.
                dist = max(1.8, (hi.y - lo.y) * node.scale.y * 1.6)
            case .guitar:
                localFocus = SCNVector3(0, 0, 0)
                localNormal = SCNVector3(0, 0, 1)        // body front
                dist = 2.6
            }
            let center = node.convertPosition(localFocus, to: nil)         // focal point in world space
            let n = normalized(node.convertVector(localNormal, to: nil))   // face normal in world space
            let camPos = SCNVector3(center.x + n.x * dist, center.y + n.y * dist, center.z + n.z * dist)
            let tmp = SCNNode()
            tmp.position = camPos
            tmp.look(at: center)                          // point -Z at the focal point, +Y up
            return (camPos, tmp.orientation)
        }

        private func normalized(_ v: SCNVector3) -> SCNVector3 {
            let l = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
            return l > 1e-5 ? SCNVector3(v.x / l, v.y / l, v.z / l) : SCNVector3(0, 0, 1)
        }

        // Let taps coexist with the camera controller's orbit gesture.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        // MARK: Drag-OFF (lift a piece off the stage onto the rail's trash)

        /// Press-and-hold a pedal (or the guitar) to pick it up, then drag it to
        /// the trash to take it off the rig. Feeds `RigDragController` exactly like
        /// a rail card does — same ghost, same trash — but tagged `.stage`, which
        /// is what makes the trash unload the piece instead of deleting the gear.
        @objc func handleLift(_ g: UILongPressGestureRecognizer) {
            guard let view, let controller, focusedNow == nil else { return }
            let point = g.location(in: view)

            switch g.state {
            case .began:
                guard let (component, node) = componentUnderPoint(point),
                      let item = liftableItem(for: component) else { return }
                lifting = true
                // Out of the diorama the instant it is in hand, so the stage shows
                // the hole the card came out of. Restored on release unless the
                // bin actually took it — see `.ended`.
                node.isHidden = true
                liftedNode = node
                // The contact shadow is a separate flat plane, not a cast shadow,
                // so the piece leaves its blob printed on the floor unless the two
                // are hidden together. Pedals share one board-wide shadow, so only
                // the amp and the guitar have one of their own to take along.
                liftedShadow = node.name.flatMap { view.scene?.rootNode.childNode(withName: $0 + "Shadow",
                                                                                  recursively: true) }
                liftedShadow?.isHidden = true
                liftedComponent = component
                // Take the camera offline for the duration: SceneKit's built-in
                // controller would otherwise orbit on the very same finger.
                // Handed back on .ended, like every other path that borrows it.
                view.allowsCameraControl = false
                suspendAncestorScrolling(from: view)
                setHighlight(nil)
                currentTarget = nil
                controller.begin(item, at: appRootPoint(point, in: view), from: .stage)

            case .changed:
                guard lifting else { return }
                controller.move(to: appRootPoint(point, in: view))

            case .ended, .cancelled, .failed:
                guard lifting else { return }
                lifting = false
                // Read the drop target BEFORE `end()` resolves and clears it.
                let intoBin = controller.isOverTrash
                controller.end()
                // The gap stays only if the bin actually took the piece. The guitar
                // is always refused, and a release anywhere else does nothing, so
                // both have to come back — otherwise the stage keeps a hole in it
                // until something unrelated rebuilds the scene. When the piece IS
                // taken the store has already changed, and the rebuild that follows
                // discards this node anyway.
                if !(intoBin && liftedComponent != .guitar) {
                    liftedNode?.isHidden = false
                    liftedShadow?.isHidden = false
                }
                liftedNode = nil
                liftedShadow = nil
                liftedComponent = nil
                view.allowsCameraControl = true
                resumeAncestorScrolling()

            default:
                break
            }
        }

        /// Switch off every enclosing scroll view for the duration of a lift.
        /// Setting `isScrollEnabled = false` also CANCELS a pan already in flight,
        /// which is what snaps the pager back if it had begun to follow the finger
        /// in the fraction of a second before the long press was recognised.
        private func suspendAncestorScrolling(from view: UIView) {
            var next = view.superview
            while let current = next {
                if let scroll = current as? UIScrollView, scroll.isScrollEnabled {
                    scroll.isScrollEnabled = false
                    suspendedScrollViews.append(scroll)
                }
                next = current.superview
            }
        }

        private func resumeAncestorScrolling() {
            for scroll in suspendedScrollViews { scroll.isScrollEnabled = true }
            suspendedScrollViews.removeAll()
        }

        /// What a hit-tested component can be dragged off as.
        ///
        /// The guitar IS liftable even though it can never be removed — the trash
        /// refuses it out loud ("Your guitar is fixed"), which is a far better
        /// answer to "can I take this out?" than a piece that simply won't move.
        /// The amp is liftable too, and really does leave: the rig is allowed to
        /// have no amp (`RigStore.removeAmpFromRig`), it just says so loudly
        /// afterwards — a banner on the stage and a refusal to play.
        private func liftableItem(for component: RigComponent) -> GearItem? {
            switch component {
            case .pedal(let id):          return stagePedals.first { $0.id == id }
            case .guitar:                 return stageGuitar
            case .amp, .cabinet, .combo:  return stageAmp
            }
        }

        /// This view's local point → the shared "appRoot" space the drag
        /// controller, the ghost and the trash target all measure against.
        ///
        /// Goes via the WINDOW rather than by adding `controller.stageFrame.origin`,
        /// which would look like the obvious shortcut and is wrong: `stageFrame` is
        /// measured by a GeometryReader inside the shell's paged TabView, where the
        /// `.named("appRoot")` space does not resolve, so it comes back in window
        /// coordinates — off by the safe-area inset from the space the ghost and the
        /// trash are in. `appRootOrigin` is measured on the appRoot view itself and
        /// is the honest conversion. (Do not "simplify" this back.)
        private func appRootPoint(_ point: CGPoint, in view: UIView) -> CGPoint {
            let window = view.convert(point, to: nil)
            return controller?.appRootPoint(fromWindow: window) ?? window
        }

        // MARK: Drag-to-replace (driven by RigDragController)

        /// Given a finger point in this view's coordinate space and the card being
        /// dragged, hit-test the models, remember what a drop would replace, and
        /// glow that piece. Called continuously as the drag moves.
        /// Called continuously as a card is dragged over the stage. The finger is
        /// already known to be within the stage area (the controller only forwards
        /// in-stage points), so we pick a target by the dragged item's category —
        /// no pixel-precise hover needed — and glow that piece.
        func highlightForDrag(at point: CGPoint, item: GearItem) {
            let target = dragTarget(for: item, at: point)
            currentTarget = target
            // The marker is unlit, so the `multiply` highlight the real models use
            // would only make it dimmer. It gets its own swell instead.
            setAddSlotHot(target == .addPedal)
            setHighlight(target == .addPedal ? nil : node(for: target))
        }

        /// The piece a drop would replace, given the dragged item and finger point.
        /// Amp/cab/combo always target the one amp stack; a pedal targets whichever
        /// pedal is nearest the finger; the guitar isn't swappable.
        private func dragTarget(for item: GearItem, at point: CGPoint) -> RigDropTarget? {
            switch item.category {
            case .guitar:                   return nil
            case .amp, .cabinet, .comboAmp: return .ampStack
            default:                        return nearestPedalTarget(to: point)
            }
        }

        /// The named group node for a target (the amp stack, or a specific pedal).
        private func node(for target: RigDropTarget?) -> SCNNode? {
            guard let root = view?.scene?.rootNode else { return nil }
            switch target {
            case .ampStack:      return root.childNode(withName: "ampRoot", recursively: true)
            case .pedal(let id): return root.childNode(withName: "pedal_\(id.uuidString)", recursively: true)
            case .addPedal:      return root.childNode(withName: PedalboardScene.addSlotName, recursively: true)
            case nil:            return nil
            }
        }

        /// Show or hide the add-pedal marker.
        func setAddSlot(visible: Bool) {
            guard let node = view?.scene?.rootNode.childNode(withName: PedalboardScene.addSlotName,
                                                             recursively: true),
                  node.isHidden == visible else { return }
            node.isHidden = !visible
            if !visible { setAddSlotHot(false) }
        }

        /// Swell the marker while the finger is on it, so "let go now" is legible
        /// under a ghost card that covers most of it.
        func setAddSlotHot(_ hot: Bool) {
            guard let face = view?.scene?.rootNode.childNode(withName: PedalboardScene.addSlotFaceName,
                                                             recursively: true) else { return }
            let s: Float = hot ? 1.28 : 1
            guard face.scale.x != s else { return }
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.12
            face.scale = SCNVector3(s, s, s)
            SCNTransaction.commit()
        }

        /// Whichever is nearest the finger on screen: a pedal already on the board
        /// (swap it) or the add marker beside it (append). One comparison rather
        /// than two rules, so the marker competes for the finger on exactly the
        /// same terms as the pedals and there is no dead band between them.
        private func nearestPedalTarget(to point: CGPoint) -> RigDropTarget? {
            guard let view, let root = view.scene?.rootNode else { return nil }
            var best: (target: RigDropTarget, dist: CGFloat)?
            func consider(_ target: RigDropTarget, _ node: SCNNode) {
                let screen = view.projectPoint(node.worldPosition)
                let dist = hypot(CGFloat(screen.x) - point.x, CGFloat(screen.y) - point.y)
                if best == nil || dist < best!.dist { best = (target, dist) }
            }
            root.enumerateChildNodes { node, _ in
                guard let name = node.name, !node.isHidden else { return }
                if name.hasPrefix("pedal_"),
                   let id = UUID(uuidString: String(name.dropFirst("pedal_".count))) {
                    consider(.pedal(id), node)
                } else if name == PedalboardScene.addSlotName {
                    consider(.addPedal, node)
                }
            }
            return best?.target
        }

        /// Highlight `node` with a steady, darker tone across its whole hierarchy
        /// (knobs and small parts included), restoring any previously highlighted
        /// node first. Uses the `multiply` channel so it dims the real colors
        /// rather than recoloring — dark, but deliberately kept above black.
        func setHighlight(_ node: SCNNode?) {
            if node === highlightedNode { return }
            clearHighlight()
            guard let node else { return }
            highlightedNode = node

            let darken = UIColor(white: 0.48, alpha: 1)   // a gentle dim — reads as the target, not a heavy shadow
            var seen = Set<ObjectIdentifier>()
            node.enumerateHierarchy { child, _ in
                guard let materials = child.geometry?.materials else { return }
                for m in materials where seen.insert(ObjectIdentifier(m)).inserted {
                    savedMultiply.append((m, m.multiply.contents, m.multiply.intensity))
                    m.multiply.contents = darken
                    m.multiply.intensity = 1.0
                }
            }
        }

        func clearHighlight() {
            for saved in savedMultiply {
                saved.material.multiply.contents = saved.contents
                saved.material.multiply.intensity = saved.intensity
            }
            savedMultiply.removeAll()
            highlightedNode = nil
        }
    }
}

// MARK: - Diorama assembly

/// Places the three procedural models on a shared floor and frames them. All
/// positions are in a single world so one camera orbit moves everything together.
enum RigDiorama {
    /// The point the camera orbits around (roughly the middle of the arrangement).
    /// Lifted with the amp: the stack is the tallest thing here, so orbiting about
    /// a point down at the pedalboard swung it out of frame.
    static let lookTarget = SCNVector3(0.5, 1.05, 0.0)

    /// Default diorama camera pose (also the pose the focus animation returns to).
    ///
    /// FRAMED FOR THE TALLEST AMP, deliberately. Every stack occupies the same
    /// vertical envelope by construction — `ProceduralAmp.Layout` solves each one's
    /// width from a fixed height budget, so a Plexi, a Dual Rectifier and a fitted
    /// art stack are all exactly `span` tall — and a combo is shorter still. So one
    /// framing covers the whole catalog, and the number that matters is the MARGIN
    /// above the head.
    ///
    /// That margin used to be roughly zero: the head sat right on the top edge, which
    /// is why raising the amp scale pushed it out of frame entirely. The camera now
    /// sits well back, putting the full envelope at ~0.23 of frame height rather than
    /// the ~0.32 it started at, so the stage reads as a room the rig sits IN rather
    /// than a box cropped around it. Note the trade, because it is not free: an amp's
    /// apparent size IS its fraction of the frame, so headroom is paid for by the amp
    /// reading smaller. What keeps it feeling big is `ampScale` against the guitar
    /// and board, not the camera.
    static let cameraPosition = SCNVector3(0.5, 4.3, 10.9)
    static let cameraPitch: Float = -0.29
    static let cameraFOV: CGFloat = 42

    // MARK: Return framing (orbit release + pinch release + overlay close)
    // Every return path eases the camera all the way back to this canonical home
    // view — ANGLE and DISTANCE both. An earlier design preserved whatever zoom the
    // user had chosen, but with the zoom rubber-banding home there is nothing left
    // to preserve, and making the two paths differ is what let a release cancel a
    // pinch's own return. One home view, reached the same way every time.

    /// The default framing distance — ‖cameraPosition − lookTarget‖ ≈ 11.37. The
    /// distance the diorama is composed around, what every gesture returns to, and
    /// the fallback when no zoom was captured.
    static let defaultCameraDistance = distance(from: cameraPosition, to: lookTarget)

    /// Unit vector from lookTarget out to the default camera. Returns place the
    /// camera along this direction, so the rig stays centred and the pitch matches
    /// the designed 3/4 view.
    static let homeDirection: SCNVector3 = {
        let d = defaultCameraDistance
        guard d > 1e-5 else { return SCNVector3(0, 0, 1) }
        return SCNVector3((cameraPosition.x - lookTarget.x) / d,
                          (cameraPosition.y - lookTarget.y) / d,
                          (cameraPosition.z - lookTarget.z) / d)
    }()

    /// Bounds the zoom is clamped into, so no gear can leave the frame at any
    /// allowed distance. `max` = the default framing (never push past the pose the
    /// diorama was composed around).
    ///
    /// `min` is the closest you may zoom. It used to be reasoned about as a WIDTH
    /// problem — the guitar being the widest thing on the stage — but measuring it
    /// at the enlarged scales showed the real binding constraint is HEIGHT, and it
    /// is the PEDALBOARD: the board sits closest to the camera (z = 0.4), so as you
    /// zoom in it runs off the bottom of the frame well before the guitar reaches
    /// either side.
    ///
    /// Measured by parking the default camera at a candidate distance and looking:
    /// at d = 4.8 the board was cut off mid-pedal; at 6.5 the pedals still touched
    /// the edge; at 7.0 the pedal bodies were fully clear with only the board's
    /// front lip at the boundary. 7.2 keeps a little margin on that. **Raising
    /// `bScale` or moving the board forward means re-measuring this.**
    /// How far OUT a pinch may pull. This used to be `defaultCameraDistance` — i.e.
    /// exactly where the camera already sits — so pinching to zoom out clamped on
    /// the very first frame, moved the camera not at all, and therefore had nothing
    /// to spring back FROM. Zoom-in bounced and zoom-out did nothing, which reads as
    /// "the bounce only works one way". Zoom-in was unaffected because `min` (7.2)
    /// leaves it real room to travel.
    ///
    /// Now that every gesture returns home, letting the user pull back temporarily
    /// costs nothing — the wider view is transient by construction.
    static let maxCameraDistance = defaultCameraDistance * 1.75
    static let minCameraDistance: Float = 7.2

    // MARK: Backdrop

    /// The blue the diorama sits in — the colour the stage model's own author
    /// photographs it against.
    ///
    /// Set on the SCENE, and that is the whole point of it living here rather than
    /// only in `RigStageView`. The SCNView asks for a clear background
    /// (`backgroundColor = .clear`, `isOpaque = false`) and lets a SwiftUI colour show
    /// through — which works right up until the camera turns on post-processing.
    /// `wantsHDR` plus bloom, saturation and contrast route the frame through an
    /// offscreen pass that does not carry the clear background out with it, so the
    /// view composites opaque and paints over whatever SwiftUI put behind it.
    ///
    /// The symptom is badly misleading: the backdrop reads as "too dark" no matter
    /// what colour you set in SwiftUI, because none of those colours were ever on
    /// screen. Giving the scene its own background renders the blue in SceneKit,
    /// where it cannot be covered. `RigStageView.stageBackground` paints the SAME
    /// value for the strip of padding around the view, so the two agree whichever
    /// one you end up looking at.
    static let backdrop = UIColor(red: 0.196, green: 0.588, blue: 0.757, alpha: 1)   // #3296C1

    // MARK: Guitar placement

    /// Where the guitar's lower bout meets the boards. Unchanged from where the
    /// guitar stood when it was on a stand — the lean happens ABOUT this point, so
    /// moving it moves the whole guitar rather than just its top.
    static let guitarBase = SIMD2<Float>(1.80, -0.30)

    /// Ceiling on the lean. 25° is already a guitar propped at a lazy angle; past
    /// that it reads as falling over rather than resting.
    private static let maxGuitarLean: Float = 25 * .pi / 180

    /// How to tip the guitar so it comes to rest on the stool — a rotation for a node
    /// that pivots on the guitar's base.
    ///
    /// Solved against the guitar's OWN MESH, not a formula. The first version placed
    /// the guitar's centre line one body-half-depth outside the seat's rim, which
    /// quietly assumes the guitar meets the stool broadside. It does not: at the
    /// height of a bar stool's seat a guitar is not a body, it is a NECK, so that
    /// allowance was about three times too generous and left it hanging 0.04 units
    /// clear of the stool — a visible gap, and contact is the entire point of a lean.
    ///
    /// So: tip the guitar until its geometry first meets the stool, by bisection. The
    /// stool is treated as a solid cylinder from the boards up to the seat, and first
    /// contact lands on the rim where a leaning guitar actually rests. Because the
    /// answer is measured, a different guitar — a Les Paul is a very different
    /// silhouette from a Strat — comes to rest correctly without retuning anything.
    ///
    /// Yaw alone when there is no stool, or when the guitar is too short to reach it
    /// at `maxGuitarLean`, which stands it up straight — the pose it had before there
    /// was anything to lean it on.
    static func leanPose(onto seat: StageEnvironment.SeatRest?,
                         resting points: [SIMD3<Float>],
                         from base: SIMD2<Float>,
                         yaw: Float) -> simd_quatf {
        let spin = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        guard let seat, seat.radius > 0, seat.centre.y > 0, !points.isEmpty else { return spin }

        let toSeat = SIMD2<Float>(seat.centre.x, seat.centre.z) - base
        let reach = simd_length(toSeat)
        guard reach > seat.radius else { return spin }        // standing on top of it already
        let direction = toSeat / reach

        // Work in the lean's own frame: `along` runs toward the stool, `up` is up, and
        // `across` is the axis the guitar turns about — which the lean never changes.
        // That makes the whole search two-dimensional and the inner loop a handful of
        // multiplies, which is what keeps bisecting an 85k-vertex mesh cheap.
        var along = [Float](repeating: 0, count: points.count)
        var up = [Float](repeating: 0, count: points.count)
        var across = [Float](repeating: 0, count: points.count)
        for (i, p) in points.enumerated() {
            let q = spin.act(p)
            along[i]  = q.x * direction.x + q.z * direction.y
            up[i]     = q.y
            across[i] = q.x * direction.y - q.z * direction.x
        }

        // In that frame the stool is a circle at (reach, 0) rising to the seat.
        func meetsStool(at angle: Float) -> Bool {
            let c = cos(angle), s = sin(angle)
            for i in points.indices {
                let height = -along[i] * s + up[i] * c
                guard height < seat.centre.y else { continue }          // clears the seat
                let forward = along[i] * c + up[i] * s - reach
                if forward * forward + across[i] * across[i] < seat.radius * seat.radius { return true }
            }
            return false
        }

        // Upright and already touching means the layout moved under us; leave it be.
        guard !meetsStool(at: 0), meetsStool(at: maxGuitarLean) else { return spin }

        var clear: Float = 0, touching = maxGuitarLean
        for _ in 0..<18 {
            let mid = (clear + touching) / 2
            if meetsStool(at: mid) { touching = mid } else { clear = mid }
        }
        return simd_quatf(angle: touching, axis: SIMD3<Float>(direction.y, 0, -direction.x)) * spin
    }

    /// Every vertex `node` draws, in the space of `node`'s parent, scaled and lifted
    /// onto the lean pivot. Feeds `leanPose`, which needs the guitar's real silhouette
    /// rather than its bounding box — a box would come to rest on a corner that is not
    /// there.
    private static func leanPoints(of node: SCNNode, scale: Float, liftedBy lift: Float) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        func walk(_ n: SCNNode, _ m: simd_float4x4) {
            let w = m * simd_float4x4(n.transform)
            if let g = n.geometry, let src = g.sources(for: .vertex).first, src.componentsPerVector >= 3 {
                src.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    for i in 0..<src.vectorCount {
                        let b = i * src.dataStride + src.dataOffset
                        guard b + 12 <= raw.count else { continue }
                        let p = w * SIMD4<Float>(raw.loadUnaligned(fromByteOffset: b,     as: Float.self),
                                                 raw.loadUnaligned(fromByteOffset: b + 4, as: Float.self),
                                                 raw.loadUnaligned(fromByteOffset: b + 8, as: Float.self),
                                                 1)
                        out.append(SIMD3(p.x, p.y + lift, p.z) * scale)
                    }
                }
            }
            for c in n.childNodes { walk(c, w) }
        }
        walk(node, matrix_identity_float4x4)
        return out
    }

    /// Straight-line distance between two points (the camera↔lookTarget zoom radius).
    static func distance(from p: SCNVector3, to q: SCNVector3) -> Float {
        let dx = p.x - q.x, dy = p.y - q.y, dz = p.z - q.z
        return sqrt(dx * dx + dy * dy + dz * dz)
    }

    /// A centered, home-facing camera pose at a given distance from `lookTarget`.
    ///
    /// The position sits along `homeDirection`, so the rig stays centered and the
    /// pitch matches the designed 3/4 view; only the RADIUS comes from the caller.
    /// That's how both return paths preserve the user's pinch-zoom instead of
    /// snapping back to the fixed far `cameraPosition`. The distance is clamped into
    /// [minCameraDistance, maxCameraDistance] *here* so both paths bound it
    /// identically and no gear leaves the frame. Orientation comes from `look(at:)`
    /// → a quaternion, so callers animate the shortest arc back to level.
    static func framedPose(atDistanceFromTarget rawDistance: Float)
        -> (position: SCNVector3, orientation: SCNQuaternion) {
        let d = min(max(rawDistance, minCameraDistance), maxCameraDistance)
        let position = SCNVector3(lookTarget.x + homeDirection.x * d,
                                  lookTarget.y + homeDirection.y * d,
                                  lookTarget.z + homeDirection.z * d)
        let aim = SCNNode()
        aim.position = position
        aim.look(at: lookTarget)          // frames the rig; quaternion → shortest arc
        return (position, aim.orientation)
    }

    /// What the scene is BUILT from. The scene is only rebuilt when this string
    /// changes, so every piece the builder reads has to appear here — the
    /// cabinet included, or swapping cabs would leave the old one on screen
    /// until some unrelated change happened to force a rebuild.
    static func signature(amp: GearItem?, cabinet: GearItem?,
                          pedals: [GearItem], guitar: GearItem?) -> String {
        "\(amp?.id.uuidString ?? "-")|\(cabinet?.id.uuidString ?? "-")|\(guitar?.id.uuidString ?? "-")|"
            + pedals.map { $0.id.uuidString }.joined(separator: ",")
    }

    static func make(amp: GearItem?, cabinet: GearItem?,
                     pedals: [GearItem], guitar: GearItem?) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = backdrop        // see `backdrop` — NOT decoration
        let world = SCNNode()
        world.name = "world"

        // ---- Stage: the modelled club floor everything else stands on. Added
        // FIRST so it is behind the gear in the node order, and parented to
        // `world` so it orbits with the rig instead of sliding under it. Absent
        // asset → nil → the diorama renders on nothing, exactly as it used to.
        if let stage = StageEnvironment.node() { world.addChildNode(stage) }

        // ---- Amp: center, slightly back. Bottom (local y ≈ −2.15) sits on the floor.
        // Omitted entirely when the rig has no amp — exactly as the pedalboard
        // below already is. Falling through to the procedural amp here would draw
        // a generic amp for a rig that has none, which is worse than an empty
        // stage: the banner would be calling the thing you can see a lie.
        if amp != nil {
            let ampRoot = SCNNode()
            ampRoot.name = "ampRoot"
            // Fallback chain, first hit wins:
            //   1. a custom `.usdz` for the amp (head AND cab are one model — the
            //      documented seam in CUSTOMIZING-GEAR.md, which still wins outright),
            //   2. the procedural stack textured with the amp's and cab's own art,
            //   3. the plain generic stack.
            if let loaded = GearModelLoader.modelNode(for: amp) {   // custom .usdz: modelName / <slug> / category
                ampRoot.addChildNode(loaded)
            } else {
                ProceduralAmp.build(into: ampRoot, amp: amp, cabinet: cabinet)
            }
            // The amp is the centrepiece and was reading small next to the board and
            // the guitar — it is the piece you actually chose. Scaled up so it holds
            // the middle of the stage; the lift keeps its base on the floor either way.
            // This can go this high only because `cameraPosition` now frames the full
            // envelope with margin — at the old framing anything past ~0.62 clipped the
            // head off the top edge.
            let ampScale: Float = 0.70
            ampRoot.scale = SCNVector3(ampScale, ampScale, ampScale)
            ampRoot.position = SCNVector3(-0.1, 2.15 * ampScale, -0.9)   // aligned in x with the pedalboard
            world.addChildNode(ampRoot)
        }

        // ---- Pedalboard: in front of the amp (toward the camera).
        if !pedals.isEmpty {
            let board = PedalboardScene.boardNode(pedals: pedals)
            let bScale: Float = 0.54                     // scaled up with the guitar (matches the add marker)
            board.scale = SCNVector3(bScale, bScale, bScale)
            board.position = SCNVector3(-0.1, 0.16 * bScale, 0.4)   // close in front of the amp
            board.eulerAngles.x = -0.12                 // slight rake toward the camera
            world.addChildNode(board)
        }

        // ---- The add-pedal marker, one slot past the last pedal. Built even with
        // an empty board (which draws no board at all), so the answer to "where do
        // pedals go?" is in the same place whether you have none or five. Hidden
        // until a pedal is actually in the air — see RigStage3DView.setAddSlot.
        // Same scale as the board above — the marker is meant to read as the next
        // slot ON that board, so if the two ever diverge it sits at the wrong size
        // and the wrong height. Its y was 0.42 when the board was 0.44, so it is
        // expressed against `bScale` now rather than left as a bare constant.
        let bScale: Float = 0.54
        let addSlot = PedalboardScene.addSlotNode()
        addSlot.scale = SCNVector3(bScale, bScale, bScale)
        addSlot.position = SCNVector3(-0.1 + bScale * PedalboardScene.nextSlotX(pedalCount: pedals.count),
                                      0.955 * bScale, 0.4)
        addSlot.isHidden = true
        world.addChildNode(addSlot)

        // ---- Guitar: stood on the boards and leaned against the stool, to the
        // right of the amp. There is no stand any more — the stage supplies
        // something real to lean on, and a guitar left against the furniture is what
        // the end of a set actually looks like.
        let guitarRoot = SCNNode()
        guitarRoot.name = "guitarRoot"
        // The guitar body is a real `.usdz` now, resolved and fitted to the
        // procedural envelope by `GearModelLoader.guitarNode` — the one path both
        // this stage and the zoom detail view share, so they cannot disagree about
        // how big a guitar is. Never nil: it falls back loudly, never to nothing.
        let body = GearModelLoader.guitarNode(for: guitar)
        guitarRoot.addChildNode(body)
        // Bigger, which pushes the guitar's right edge out — and that edge is what
        // sets `minCameraDistance`, since it is the widest thing on the stage. The
        // two numbers move together; see the note there.
        let gScale: Float = 0.42
        guitarRoot.scale = SCNVector3(gScale, gScale, gScale)
        // The base of the body sits on `guitarLean`'s origin, so the tilt below
        // pivots on the point where the guitar meets the boards. The lift this
        // replaces (`2.1 * gScale`) was the depth of the STAND'S FEET, measured from
        // `ProceduralGuitar.buildStand`; with the stand gone it would just float the
        // guitar a third of a unit off the floor.
        let bounds = GearModelLoader.proceduralGuitarBounds
        guitarRoot.position = SCNVector3(0, -bounds.min.y * gScale, 0)

        let guitarLean = SCNNode()
        guitarLean.name = "guitarLean"
        guitarLean.addChildNode(guitarRoot)
        guitarLean.position = SCNVector3(guitarBase.x, 0, guitarBase.y)
        guitarLean.simdOrientation = leanPose(onto: StageEnvironment.stoolSeat,
                                              resting: leanPoints(of: body, scale: gScale, liftedBy: -bounds.min.y),
                                              from: guitarBase,
                                              yaw: -0.5)                 // body toward the camera
        world.addChildNode(guitarLean)

        scene.rootNode.addChildNode(world)

        // ---- Lighting + grounding shadows + camera.
        Studio3D.addLighting(to: scene)
        if amp != nil {
            // Widened with the amp itself — a 0.70-scale stack casting the old
            // 0.55-scale shadow reads as floating.
            Studio3D.addContactShadow(to: scene.rootNode, width: 3.8, height: 2.8,
                                      at: SCNVector3(-0.1, 0.02, -0.85), name: "ampRootShadow")
        }
        if !pedals.isEmpty {
            Studio3D.addContactShadow(to: scene.rootNode, width: 3.6, height: 1.6, at: SCNVector3(-0.1, 0.02, 0.4))
        }
        // Keeps the same 0.1 forward offset it always had, now measured off the
        // guitar's base rather than repeated as a literal — a leaning guitar touches
        // the floor at its lower bout, which is exactly where that base is.
        Studio3D.addContactShadow(to: scene.rootNode, width: 1.7, height: 1.4,
                                  at: SCNVector3(guitarBase.x, 0.02, guitarBase.y + 0.1),
                                  name: "guitarRootShadow")

        // Natural 3/4 "living-room" view, pulled back a touch so the full amp
        // (head included) fits. Horizontal projection makes the fov span the
        // rig's width so it fills the portrait width; user can pinch to zoom/orbit.
        let camNode = Studio3D.addCamera(to: scene, position: cameraPosition, tilt: cameraPitch, fov: cameraFOV)
        camNode.camera?.projectionDirection = .horizontal
        return scene
    }
}

#Preview {
    RigStage3DView(
        amp: GearItem(name: "Marswell JCM800 2203", category: .amp,
                      values: ["Gain": 8, "Bass": 6, "Mid": 4, "Treble": 7, "Presence": 5, "Master": 6]),
        cabinet: GearItem(name: "Marswell 1960A 4x12", category: .cabinet),
        pedals: [GearItem(name: "Ibonez Tube Screamer", category: .overdrive),
                 GearItem(name: "VOSS Digital Delay", category: .delay),
                 GearItem(name: "VOSS Reverb", category: .reverb)],
        guitar: GearItem(name: "Les Paul Standard", category: .guitar),
        focused: nil,
        dropArea: RigDropArea(),
        controller: RigDragController()
    )
    .frame(height: 460)
    .background(RigTheme.background)
    .preferredColorScheme(.dark)
}
