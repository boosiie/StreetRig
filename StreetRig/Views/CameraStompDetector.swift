//
//  CameraStompDetector.swift
//  StreetRig
//
//  What the AR pedal page talks to. Owns the one ARSession, publishes the one
//  placement state, and turns a tap into a world anchor.
//
//  DEVICE-ONLY, AND MORE SO THAN BEFORE. ARKit does not run in the Simulator at all:
//  `ARWorldTrackingConfiguration.isSupported` is false and no frame is ever
//  delivered. `start()` lands on `.unsupported` there and the page falls back to its
//  gradient, its placeholder, and tap-to-toggle — which is not a nicety, it is the
//  path essentially all of this project's testing will ever exercise.
//
//  WHY ARKIT REPLACED THE CAPTURE SESSION. The page needed to know whether the phone
//  had been propped somewhere that works. That is a question about the floor and
//  about whether the device is being moved, and AVFoundation cannot answer either.
//  ARKit answers both for free as a side effect of world tracking, and it owns the
//  camera exclusively while it does — an AVCaptureSession cannot run alongside it.
//  So there is exactly one capture stack here now, and it is this one.
//
//  ONE SESSION, TWO HOSTS. The AR content is hosted in two places (the pager page
//  and the signal-check screen, which is presented over it as a full-screen cover, so
//  both can be alive at once). iOS hands the camera to one session; two would fight
//  over it exactly as two capture sessions did. `start()` / `stop()` stay
//  reference-counted: whichever copy is on screen keeps the session alive, and the
//  last one out pauses it.
//
//  REAL-TIME AUDIO. Nothing here touches the audio thread. A stomp is detected on the
//  session's own background queue, `onStomp` is dispatched to main, and the store
//  mutation it performs reaches the DSP through the existing lock-free parameter bus
//  — the identical path a finger-tap on a slot takes. ARKit's own cost is real (world
//  tracking plus a neural amp is a genuine thermal load), which is why plane meshing
//  is left off, light estimation is disabled, body-pose is throttled to ~18 Hz, and
//  slot positions are published to SwiftUI at no more than 30 Hz.
//

import ARKit
import AVFoundation
import Combine
import SwiftUI
import UIKit

// MARK: - The high-frequency half of the output, kept separate on purpose

/// Where the three slots are drawn when the layout is anchored to the floor.
///
/// Its own observable object rather than a `@Published` on the detector because it
/// changes up to 30×/second while locked: anything observing the detector would
/// re-render on every one of those, and the page's other observers (the banner, the
/// placeholder, the slot colours) care about none of them. Only the floating slot
/// container watches this.
@MainActor
final class ARSlotLayout: ObservableObject {
    /// View-space centres of slots 0, 1, 2 — or nil when the row is not anchored.
    @Published var slots: [CGPoint]?
}

// MARK: - The detector

@MainActor
final class CameraStompDetector: ObservableObject {

    /// ONE detector for the whole app — see the file header on why two sessions
    /// cannot coexist.
    static let shared = CameraStompDetector()

    /// The single source of truth for every piece of AR-page UI.
    @Published private(set) var state: ARPlacementState = .idle
    /// Normalized X (0…1) of the last stomp, for optional UI feedback.
    @Published var lastStompX: CGFloat?

    let layout = ARSlotLayout()

    /// Fired on the main thread when a stomp lands over a slot zone (0, 1, 2).
    var onStomp: ((Int) -> Void)?

    let session = ARSession()

    /// ARKit delivers delegate callbacks on the MAIN queue when `delegateQueue` is
    /// nil, so this is set rather than defaulted: running Vision on the main thread
    /// would stutter the very UI the player is trying to read, on top of a live amp
    /// sim. Serial by construction, which is what lets the coordinator and the pose
    /// tracker own plain mutable state with no locking at all.
    private let sessionQueue = DispatchQueue(label: "streetrig.ar.session", qos: .userInitiated)

    /// Strongly held. A session whose delegate has been deallocated goes quiet with
    /// no error and no crash — the page just stops updating and nobody can say why.
    private var coordinator: ARPlacementCoordinator!

    /// The view showing the feed, for turning a tap into a raycast in ITS coordinate
    /// space. Weak: the view belongs to SwiftUI's lifecycle, not to this.
    private weak var feedView: ARSCNView?

    private var placedAnchor: ARAnchor?
    private var geometry: ARPlacementCoordinator.ViewGeometry?
    private var clients = 0
    private var running = false

    /// The phone is on the floor and the player is looking at their feet, not at the
    /// screen. Touch is the only channel that reaches them for the two events that
    /// matter most: "it took" and "you lost it."
    private let haptics = UINotificationFeedbackGenerator()

    private static let anchorName = "streetrig.pedalRow"

    private init() {
        coordinator = ARPlacementCoordinator(
            placementEnabled: FeatureFlags.arPlacement,
            onState: { [weak self] state in
                // `DispatchQueue.main.async` rather than a `Task` because these are
                // ordered events — a `.locked` overtaking the `.ready` before it
                // would fire the wrong haptic — and main-queue dispatch is FIFO where
                // task enqueueing is not. `assumeIsolated` is exact here: this block
                // provably runs on the main thread.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(state) } }
            },
            onSlots: { [weak self] points in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.layout.slots = points } }
            },
            onStomp: { [weak self] slot, x in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.dispatchStomp(slot, at: x) } }
            })
        session.delegate = coordinator
        session.delegateQueue = sessionQueue
    }

    // MARK: - Lifecycle

    func start() {
        clients += 1
        guard !running else { return }              // the other host already has it live

        #if targetEnvironment(simulator)
        // Stated explicitly rather than left to `isSupported`, because this is the
        // path almost every test run takes and it should be impossible to misread.
        state = .unsupported
        #else
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            // Asked before `session.run` so the refusal lands on `.denied` with the
            // page's own explanation, rather than as an ARKit session failure.
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.clients > 0 else { return }
                        if granted { self.run() } else { self.state = .denied }
                    }
                }
            }
        default:
            state = .denied
        }
        #endif
    }

    func stop() {
        clients = max(0, clients - 1)
        guard clients == 0, running else { return }  // another host still needs the feed
        session.pause()
        running = false
    }

    private func run() {
        guard let configuration = Self.makeConfiguration() else { state = .unsupported; return }
        let initial: ARPlacementState = FeatureFlags.arPlacement ? .searching(.lookingForFloor) : .running
        state = initial
        layout.slots = nil
        placedAnchor = nil
        let coordinator = self.coordinator!
        sessionQueue.async { coordinator.reset(to: initial) }
        // No reset options, so resuming after the player paged away CONTINUES the map
        // ARKit already built and the outline goes green again in a second or two
        // instead of starting from nothing.
        //
        // The lock itself is deliberately NOT carried across a pause, even though the
        // anchor would survive. Coming back from a pause means relocalizing, which can
        // take several seconds and can quietly resolve to a slightly different place;
        // re-tapping costs half a second and is right by construction. For a thing
        // that is going to be stomped on mid-song, "ask again" beats "probably".
        ARDiagnostics.log("session.run \(type(of: configuration)) placement=\(FeatureFlags.arPlacement) "
                        + "initial=\(initial.diagName)")
        session.run(configuration, options: [])
        running = true
    }

    /// Re-run the configuration if this session is supposed to be live.
    ///
    /// Called when a camera view is torn down while another host is still on screen.
    /// ARKit does not document what an `ARSCNView` does to its session on dealloc,
    /// and "the pager page went black after swiping away and back" is a bug that
    /// would only ever show up on a device, in the one configuration hardest to test.
    /// Idempotent and rare, so paying for it beats reasoning about it.
    func cameraViewDetached() {
        guard running, clients > 0, let configuration = Self.makeConfiguration() else { return }
        session.run(configuration, options: [])
    }

    private static func makeConfiguration() -> ARConfiguration? {
        guard FeatureFlags.arPlacement else {
            // Gated off: ARKit is still the camera (there is no second capture stack),
            // but 3-DOF orientation tracking costs a fraction of world tracking and
            // maps no planes. The page behaves exactly as it did before placement
            // existed — fixed slot row, stomps binned by thirds.
            guard AROrientationTrackingConfiguration.isSupported else { return nil }
            let configuration = AROrientationTrackingConfiguration()
            configuration.isLightEstimationEnabled = false
            configuration.providesAudioData = false
            return configuration
        }
        guard ARWorldTrackingConfiguration.isSupported else { return nil }
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        // Everything below is a cost this page does not need, stated rather than
        // assumed — ARKit's defaults are tuned for apps that render 3D content, and
        // this one renders none of it.
        configuration.environmentTexturing = .none      // no virtual surfaces to light
        configuration.isLightEstimationEnabled = false
        configuration.frameSemantics = []               // no segmentation, no body mesh
        // The one that is not merely a cost: enabling audio data lets ARKit
        // reconfigure the AVAudioSession, which is currently carrying the player's
        // live guitar signal through the neural amp. It would be reconfigured out
        // from under them mid-note.
        configuration.providesAudioData = false
        return configuration
    }

    // MARK: - The camera view talks to this

    /// Where and which way up the feed is being drawn. Sampled in the camera view's
    /// layout pass, which is the one moment UIKit guarantees a rotation has been
    /// committed. Both halves of the shared coordinate space are derived from it.
    func setViewGeometry(orientation: UIInterfaceOrientation, size: CGSize) {
        geometry = ARPlacementCoordinator.ViewGeometry(orientation: orientation, size: size)
        coordinator.setViewGeometry(orientation: orientation, size: size)
    }

    func attach(feedView: ARSCNView?) { self.feedView = feedView }

    // MARK: - Placing and un-placing

    /// Pin the pedal row to the floor under `viewPoint`.
    ///
    /// Only from `.ready`: a tap before the outline is green would anchor the layout
    /// to whatever ARKit is currently guessing, which is the silent mis-mapping this
    /// feature exists to prevent.
    func place(at viewPoint: CGPoint) {
        guard state == .ready,
              let feedView,
              let geometry,
              let frame = session.currentFrame else {
            // A tap that does nothing is indistinguishable from a tap that was not
            // registered, so say which it was.
            ARDiagnostics.log("tap IGNORED state=\(state.diagName) feedView=\(feedView != nil) "
                            + "geometry=\(geometry != nil) frame=\(session.currentFrame != nil)")
            return
        }

        guard let result = raycast(from: viewPoint, in: feedView) else {
            ARDiagnostics.log("tap MISSED — no raycast hit at "
                            + "(\(ARDiagnostics.f(viewPoint.x, 0)), \(ARDiagnostics.f(viewPoint.y, 0)))")
            return
        }

        // Everything needed is copied out of the frame HERE, as values, so that
        // `frame` dies with this call and never escapes into the hop below. A retained
        // ARFrame starves the session — ARKit stops delivering new ones until it is
        // released — and a frame captured by an async closure is retained for as long
        // as that closure lives.
        let camera = frame.camera
        let cameraTransform = camera.transform
        let worldTransform = result.worldTransform
        let offsets = ARPlacementCoordinator.slotOffsets(anchorTransform: worldTransform,
                                                        camera: camera,
                                                        geometry: geometry)

        let anchor = ARAnchor(name: Self.anchorName, transform: worldTransform)
        placedAnchor = anchor
        // THIS is what makes the layout "not moving": the row is fixed in world
        // space, so it stays on the real floor while ARKit keeps revising where it
        // thinks the phone is.
        session.add(anchor: anchor)

        // Project the row ONCE here, before `.locked` is published, so the slots are
        // already in their floor positions on the first frame the page draws them
        // anchored. Without it the page switches to the anchored layout with nothing
        // to draw and all three slots blink out for a frame — at the exact moment the
        // player is being told it worked.
        layout.slots = offsets.map { offset in
            camera.projectPoint(simd_mul(worldTransform, offset).xyz,
                                orientation: geometry.orientation,
                                viewportSize: geometry.size)
        }

        let identifier = anchor.identifier
        let coordinator = self.coordinator!
        sessionQueue.async {
            coordinator.lock(anchorID: identifier,
                             anchorTransform: worldTransform,
                             slotOffsets: offsets,
                             cameraTransform: cameraTransform)
        }
        haptics.notificationOccurred(.success)
    }

    /// Forget the anchor and go looking again — the way back out of `.locked`.
    func reposition() {
        // Cleared BEFORE the anchor is removed, and both land on the same serial
        // queue in this order, so the `didRemove` callback finds nothing to react to
        // and cannot turn a deliberate reposition into a `.lost` warning.
        let coordinator = self.coordinator!
        sessionQueue.async { coordinator.clearPlacement() }
        if let placedAnchor { session.remove(anchor: placedAnchor) }
        placedAnchor = nil
        layout.slots = nil
    }

    private func raycast(from viewPoint: CGPoint, in view: ARSCNView) -> ARRaycastResult? {
        // The view's own coordinate space — the same space the tap arrived in and the
        // same space the slots are drawn in.
        if let query = view.raycastQuery(from: viewPoint, allowing: .existingPlaneGeometry, alignment: .horizontal),
           let hit = session.raycast(query).first {
            return hit
        }
        // A floor that is sparsely mapped (plain carpet, low light) may have a plane
        // ARKit is confident about without geometry under the exact pixel tapped.
        // Refusing the tap there would strand the player in `.ready` forever.
        guard let estimated = view.raycastQuery(from: viewPoint, allowing: .estimatedPlane, alignment: .horizontal) else {
            return nil
        }
        return session.raycast(estimated).first
    }

    // MARK: - Reacting to the coordinator

    private func apply(_ new: ARPlacementState) {
        // A late emission from a session that has since been paused would leave the
        // page describing a camera that is not running.
        guard running else { return }
        let old = state
        guard new != old else { return }
        state = new

        if new == .ready {
            // Warm the Taptic Engine now so the confirmation on the tap that follows
            // is immediate. A late haptic on a phone the player is not looking at is
            // worse than none: they have already stopped waiting for it.
            haptics.prepare()
        }
        if new == .lost {
            haptics.notificationOccurred(.warning)
            if let placedAnchor {
                session.remove(anchor: placedAnchor)   // the coordinator has already let go
                self.placedAnchor = nil
            }
            layout.slots = nil
        }
    }

    private func dispatchStomp(_ slot: Int, at x: CGFloat) {
        lastStompX = x
        onStomp?(slot)
    }
}
