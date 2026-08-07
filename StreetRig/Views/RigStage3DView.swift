//
//  RigStage3DView.swift
//  StreetRig
//
//  The whole rig as ONE 3D diorama in a single SceneKit view: the amp (center),
//  the pedalboard (in front), and the guitar (to the right) all placed on a
//  common floor and lit together. Dragging orbits the entire scene at once —
//  "moving the living room" — instead of the old split model where a SwiftUI
//  rotation3DEffect warped a flat snapshot while each model orbited on its own.
//
//  Tapping a component plays a TWO-STAGE focus transition: stage 1 flies the
//  camera in to center that component and turn it face-on ("flat" to the screen);
//  when that lands, stage 2 zooms the control overlay in (see MainView). Closing
//  the overlay flies the camera back to the diorama.
//
//  Reuses the same procedural builders as the standalone views (ProceduralAmp,
//  PedalboardScene, ProceduralGuitar). The amp's knobs turn live from
//  GearItem.values. Gated by FeatureFlags.amp3D (stacks only; combo → vector).
//

import SwiftUI
import SceneKit
import UIKit

struct RigStage3DView: UIViewRepresentable {
    var amp: GearItem?
    var pedals: [GearItem]
    var guitar: GearItem?
    /// The stage's current focus. When it returns to nil the camera flies back.
    var focused: RigComponent?
    /// Fired after stage 1 lands, so the stage can open the zoom overlay (stage 2).
    var onFocus: ((RigComponent) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onFocus: onFocus) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.autoenablesDefaultLighting = false

        // One camera controller orbits the whole diorama around its center.
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.defaultCameraController.target = RigDiorama.lookTarget
        view.defaultCameraController.minimumVerticalAngle = -6      // don't dip under the floor
        view.defaultCameraController.maximumVerticalAngle = 80

        context.coordinator.view = view
        rebuild(view, context: context)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let coord = context.coordinator
        coord.onFocus = onFocus

        let sig = RigDiorama.signature(amp: amp, pedals: pedals, guitar: guitar)
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
        let scene = RigDiorama.make(amp: amp, pedals: pedals, guitar: guitar)
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: false)
        view.defaultCameraController.target = RigDiorama.lookTarget
        context.coordinator.cacheKnobs(in: scene)
        context.coordinator.applyAmp(values: amp?.values ?? [:])
        context.coordinator.signature = RigDiorama.signature(amp: amp, pedals: pedals, guitar: guitar)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onFocus: ((RigComponent) -> Void)?
        weak var view: SCNView?
        var signature = ""

        /// Component the camera is currently focused on (or flying toward).
        var focusedNow: RigComponent?
        /// True while stage 1 (the fly-in) is animating, so the return handler
        /// in updateUIView doesn't misfire before stage 2 has even opened.
        var animatingForward = false

        private var knobs: [String: SCNNode] = [:]

        init(onFocus: ((RigComponent) -> Void)?) { self.onFocus = onFocus }

        func cacheKnobs(in scene: SCNScene) {
            knobs.removeAll()
            for p in AmpScene.knobParamNames {
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
            let hits = view.hitTest(g.location(in: view),
                                    options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
            for hit in hits {
                var node: SCNNode? = hit.node
                while let n = node {                       // walk up to a named group
                    if let name = n.name {
                        if name.hasPrefix("pedal_"),
                           let id = UUID(uuidString: String(name.dropFirst("pedal_".count))) {
                            focus(on: n, component: .pedal(id)); return
                        }
                        if name == "ampRoot" { focus(on: n, component: .amp); return }
                        // Guitar is intentionally not focusable — no controls to adjust.
                    }
                    node = n.parent
                }
            }
        }

        /// Stage 1: fly the camera in to center `node` and view its control face
        /// straight-on. When it lands, hand off to stage 2 via `onFocus`.
        private func focus(on node: SCNNode, component: RigComponent) {
            guard let view, let cam = view.pointOfView else { return }
            focusedNow = component
            animatingForward = true
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
        func resetCamera() {
            focusedNow = nil
            guard let view, let cam = view.pointOfView else { return }
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.5
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            SCNTransaction.completionBlock = { [weak view] in
                guard let view else { return }
                view.defaultCameraController.target = RigDiorama.lookTarget
                view.allowsCameraControl = true
            }
            cam.position = RigDiorama.cameraPosition
            cam.eulerAngles = SCNVector3(RigDiorama.cameraPitch, 0, 0)
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
                localFocus = SCNVector3(0, 1.12, 0.68)   // center of the amp's knob row on the faceplate
                localNormal = SCNVector3(0, 0, 1)        // straight-on to the faceplate → flat to the screen
                dist = 3.6
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
    }
}

// MARK: - Diorama assembly

/// Places the three procedural models on a shared floor and frames them. All
/// positions are in a single world so one camera orbit moves everything together.
enum RigDiorama {
    /// The point the camera orbits around (roughly the middle of the arrangement).
    static let lookTarget = SCNVector3(0.5, 0.9, 0.0)
    /// Default diorama camera pose (also the pose the focus animation returns to).
    static let cameraPosition = SCNVector3(0.5, 3.1, 6.9)
    static let cameraPitch: Float = -0.31
    static let cameraFOV: CGFloat = 42

    static func signature(amp: GearItem?, pedals: [GearItem], guitar: GearItem?) -> String {
        "\(amp?.id.uuidString ?? "-")|\(guitar?.id.uuidString ?? "-")|"
            + pedals.map { $0.id.uuidString }.joined(separator: ",")
    }

    static func make(amp: GearItem?, pedals: [GearItem], guitar: GearItem?) -> SCNScene {
        let scene = SCNScene()
        let world = SCNNode()
        world.name = "world"

        // ---- Amp: center, slightly back. Bottom (local y ≈ −2.15) sits on the floor.
        let ampRoot = SCNNode()
        ampRoot.name = "ampRoot"
        if let name = amp?.modelName, let loaded = AmpScene.load(usdzNamed: name) {
            ampRoot.addChildNode(loaded)
        } else {
            ProceduralAmp.build(into: ampRoot)
        }
        let ampScale: Float = 0.55
        ampRoot.scale = SCNVector3(ampScale, ampScale, ampScale)
        ampRoot.position = SCNVector3(-0.1, 2.15 * ampScale, -0.9)   // aligned in x with the pedalboard
        world.addChildNode(ampRoot)

        // ---- Pedalboard: in front of the amp (toward the camera).
        if !pedals.isEmpty {
            let board = PedalboardScene.boardNode(pedals: pedals)
            let bScale: Float = 0.44                     // slightly smaller board
            board.scale = SCNVector3(bScale, bScale, bScale)
            board.position = SCNVector3(-0.1, 0.16 * bScale, 0.4)   // close in front of the amp
            board.eulerAngles.x = -0.12                 // slight rake toward the camera
            world.addChildNode(board)
        }

        // ---- Guitar: to the right of the amp, angled toward center.
        let guitarRoot = SCNNode()
        guitarRoot.name = "guitarRoot"
        ProceduralGuitar.buildGuitar(into: guitarRoot)
        ProceduralGuitar.buildStand(into: guitarRoot)
        let gScale: Float = 0.34
        guitarRoot.scale = SCNVector3(gScale, gScale, gScale)
        guitarRoot.position = SCNVector3(1.8, 2.1 * gScale, -0.3)   // in closer to the amp
        guitarRoot.eulerAngles.y = -0.5
        world.addChildNode(guitarRoot)

        scene.rootNode.addChildNode(world)

        // ---- Lighting + grounding shadows + camera.
        Studio3D.addLighting(to: scene)
        Studio3D.addContactShadow(to: scene.rootNode, width: 2.8, height: 2.0, at: SCNVector3(-0.1, 0.02, -0.85))
        if !pedals.isEmpty {
            Studio3D.addContactShadow(to: scene.rootNode, width: 3.0, height: 1.2, at: SCNVector3(-0.1, 0.02, 0.35))
        }
        Studio3D.addContactShadow(to: scene.rootNode, width: 1.3, height: 1.1, at: SCNVector3(1.8, 0.02, -0.2))

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
        amp: GearItem(name: "Marshall JCM800", category: .amp,
                      values: ["Gain": 8, "Bass": 6, "Mid": 4, "Treble": 7, "Presence": 5, "Master": 6]),
        pedals: [GearItem(name: "Tube Screamer", category: .overdrive),
                 GearItem(name: "Carbon Copy", category: .delay),
                 GearItem(name: "Boss RV-6", category: .reverb)],
        guitar: GearItem(name: "Les Paul Standard", category: .guitar),
        focused: nil
    )
    .frame(height: 460)
    .background(RigTheme.background)
    .preferredColorScheme(.dark)
}
