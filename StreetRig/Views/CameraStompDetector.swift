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
    /// Drives the SwiftUI chrome (name, lamp, ON/OFF) that tracks each pedal.
    @Published var slots: [CGPoint]?

    /// Where the row sits on the real floor, for the SceneKit pedals. Changes only
    /// on lock and on anchor refinement, so it costs nothing to keep beside the
    /// 30 Hz points.
    @Published var floor: ARFloorPose?

    /// The rocker's switch pad — a patch of empty floor beside the board that toggles
    /// it. Nil when no rocker is on the row.
    @Published var switchPad: SwitchPad?
}

/// Where the switch pad is, and which slot it switches.
struct SwitchPad: Equatable {
    let slot: Int
    let point: CGPoint
}

// MARK: - The detector

/// A tap the player just made, and whether it turned into a board.
///
/// EXISTS BECAUSE A TAP ON A CAMERA FEED IS INVISIBLE. Every other control on this
/// page is a thing you can see and press; placement is a tap on a picture of a
/// carpet, and until the board appears there is nothing at all to say the app
/// noticed. A tap that MISSED — no plane under that pixel — was worse still: it
/// looked exactly like a tap that worked but drew slowly, so the player's next move
/// was to tap again somewhere just as wrong. Marking the spot answers both halves at
/// once: where the app thinks the finger went, and whether it took.
///
/// `id` is what drives the animation: a new tap in the same place is a NEW mark, and
/// SwiftUI has to be told that or the ripple plays once and never again.
nonisolated struct ARTapMark: Identifiable, Equatable {
    let id: Int
    var point: CGPoint
    var landed: Bool
}

@MainActor
final class CameraStompDetector: ObservableObject {

    /// ONE detector for the whole app — see the file header on why two sessions
    /// cannot coexist.
    static let shared = CameraStompDetector()

    /// The last placement tap, for the page to draw. Low-frequency by nature — one
    /// per attempt — so unlike the 30 Hz slot points it costs nothing to publish
    /// from the detector itself rather than from its own object.
    @Published var lastTap: ARTapMark?
    private var tapCounter = 0

    /// Which camera the page is looking through. Front by default — see
    /// `ARCameraFacing` for why that is the ergonomic answer and what it costs.
    @Published private(set) var facing: ARCameraFacing = .default

    /// Which slot the player's foot is hovering over, or nil.
    ///
    /// Published on CHANGE only (the coordinator dedupes), so this is a handful of
    /// updates in a song rather than 18 a second — cheap enough to live on the
    /// detector rather than needing its own object like the slot points do.
    @Published private(set) var hoveredSlot: Int?

    /// Turn the phone around: swap the camera and start the placement over.
    ///
    /// A full reset rather than a reconfigure, because the two modes do not share a
    /// world. Front-mode boards are planted against an assumed floor; rear-mode ones
    /// against a detected plane anchor that the front session cannot see. Carrying
    /// either across the switch would leave a board hanging in a coordinate space
    /// nothing is tracking any more.
    func flipCamera() {
        facing = Self.resolvedFacing(facing == .front ? .rear : .front)
        ARDiagnostics.log("camera FLIP -> \(facing.diagName)")
        reposition()
        guard running, clients > 0 else { return }
        guard let configuration = Self.makeConfiguration(facing: facing) else {
            state = .unsupported
            return
        }
        let initial: ARPlacementState = FeatureFlags.arPlacement ? .searching(.lookingForFloor) : .running
        state = initial
        let coordinator = self.coordinator!
        let newFacing = facing
        sessionQueue.async {
            coordinator.setFacing(newFacing)
            coordinator.reset(to: initial)
        }
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    /// The camera this device can actually give you when you ask for `requested`.
    ///
    /// FRONT IS A DEFAULT, NOT A REQUIREMENT. It needs a TrueDepth camera and, for
    /// `supportsWorldTracking`, an A12 or later. A phone with neither is not broken —
    /// it is a phone that has to use the rear camera, and it should get the full
    /// plane-detecting page rather than "no camera here" on a camera that works.
    ///
    /// Resolved BEFORE `facing` is stored rather than inside `makeConfiguration`, so
    /// that the stored mode and the running session can never disagree. They must
    /// not: `facing` is what decides whether the readiness gate looks for planes and
    /// whether the board places itself, and a front-mode gate on a rear-mode session
    /// would wait for an aim check while ignoring the planes it was being handed.
    private static func resolvedFacing(_ requested: ARCameraFacing) -> ARCameraFacing {
        guard requested == .front, FeatureFlags.arPlacement else { return requested }
        guard ARFaceTrackingConfiguration.isSupported,
              ARFaceTrackingConfiguration.supportsWorldTracking else {
            ARDiagnostics.log("front camera unavailable (isSupported="
                            + "\(ARFaceTrackingConfiguration.isSupported) worldTracking="
                            + "\(ARFaceTrackingConfiguration.supportsWorldTracking)) — falling back to rear")
            return .rear
        }
        return .front
    }

    /// Record where a placement tap went and whether it landed.
    private func markTap(_ point: CGPoint, landed: Bool) {
        tapCounter += 1
        lastTap = ARTapMark(id: tapCounter, point: point, landed: landed)
    }

    /// The single source of truth for every piece of AR-page UI.
    @Published private(set) var state: ARPlacementState = .idle
    /// Normalized X (0…1) of the last stomp, for optional UI feedback.
    @Published var lastStompX: CGFloat?

    let layout = ARSlotLayout()

    /// Fired on the main thread when a stomp lands over a slot zone (0, 1, 2).
    var onStomp: ((Int) -> Void)?

    /// Fired on the main thread with (slot, 0…1) as the working foot rides up and
    /// down over a slot. A CLOSURE rather than a `@Published`, deliberately: this
    /// changes continuously while a foot is moving, and publishing it would re-render
    /// every observer of the detector at that rate to deliver a number only one of
    /// them wants. Same reasoning as `ARSlotLayout` existing at all.
    var onTreadle: ((Int, Double) -> Void)?

    /// Fired on the main thread when the foot pushes past the toe end of a treadle
    /// into its switch zone — one call per press. This is a rocker's on/off.
    var onTreadleSwitch: ((Int) -> Void)?

    /// Which treadle's switch zone the foot is standing in, or nil, and how far
    /// through the hold it is (0…1). Published because the UI has to draw the hold
    /// filling — that is the whole point of it.
    /// Why the last lock ended, in the coordinator's own words. Shown in the banner
    /// so a lock that drops for a reason other than a nudge says so.
    @Published private(set) var lastUnlockReason: String?
    @Published private(set) var treadleArmedSlot: Int?
    @Published private(set) var treadleArmProgress: Double = 0

    /// Which slots hold rocker pedals, so the coordinator can stop a rocking foot
    /// from throwing phantom stomps at the pedals either side of it. Set from the
    /// page whenever the rig changes.
    var treadleSlots: Set<Int> = [] {
        didSet {
            guard treadleSlots != oldValue else { return }
            coordinator?.setTreadleSlots(treadleSlots, on: sessionQueue)
        }
    }

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
            onFloor: { [weak self] pose in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.layout.floor = pose } }
            },
            onStomp: { [weak self] slot, x in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.dispatchStomp(slot, at: x) } }
            },
            onHover: { [weak self] slot in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.hoveredSlot = slot } }
            },
            onTreadle: { [weak self] slot, value in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.onTreadle?(slot, value) }
                }
            },
            onUnlockReason: { [weak self] reason in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.lastUnlockReason = reason } }
            },
            onTreadleArm: { [weak self] slot, progress in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.treadleArmedSlot = slot
                        self?.treadleArmProgress = progress
                    }
                }
            },
            onTreadleSwitch: { [weak self] slot in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.onTreadleSwitch?(slot) }
                }
            },
            onSwitchPad: { [weak self] slot, point in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.layout.switchPad = point.map { SwitchPad(slot: slot ?? 0, point: $0) }
                    }
                }
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
        // Resolved here, before anything reads it: this is the first moment the
        // device's real capabilities are knowable, and `facing` must describe the
        // session that is about to start rather than the one that was asked for.
        facing = Self.resolvedFacing(facing)
        // The remembered prop height, into the atomic the frame path reads, BEFORE
        // the first frame can arrive and derive a floor from the default.
        ARFloorCalibration.restore()
        guard let configuration = Self.makeConfiguration(facing: facing) else { state = .unsupported; return }
        let initial: ARPlacementState = FeatureFlags.arPlacement ? .searching(.lookingForFloor) : .running
        state = initial
        layout.slots = nil
        placedAnchor = nil
        let coordinator = self.coordinator!
        let currentFacing = facing
        sessionQueue.async {
            coordinator.setFacing(currentFacing)
            coordinator.reset(to: initial)
        }
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
        guard running, clients > 0, let configuration = Self.makeConfiguration(facing: facing) else { return }
        session.run(configuration, options: [])
    }

    private static func makeConfiguration(facing: ARCameraFacing) -> ARConfiguration? {
        // FRONT: the default, and the one with no planes in it. See ARCameraFacing.
        //
        // World tracking is switched on explicitly. Without it a face-tracking
        // session gives no gravity-aligned world at all, and `ARAssumedFloor` — which
        // relies on world +Y being up and on the camera having a world transform
        // worth reading — would be planting boards against a coordinate space that
        // rotates with the phone.
        if facing == .front, FeatureFlags.arPlacement {
            // Callers resolve support BEFORE getting here (`resolvedFacing`), so this
            // is the belt to that braces: reaching it means the two disagreed.
            guard ARFaceTrackingConfiguration.isSupported,
                  ARFaceTrackingConfiguration.supportsWorldTracking else { return nil }
            let configuration = ARFaceTrackingConfiguration()
            configuration.isWorldTrackingEnabled = true
            // One face is one too many for this page: it is watching FEET. Tracking
            // none of them is not an option the API offers, so it takes the minimum
            // and ignores the anchors.
            configuration.maximumNumberOfTrackedFaces = 1
            configuration.isLightEstimationEnabled = true
            // Same reasoning as the rear path: ARKit must not reconfigure the audio
            // session that is currently carrying the player's live guitar.
            configuration.providesAudioData = false
            return configuration
        }
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
        // There ARE virtual surfaces to light now — the floor pedals — so the
        // estimate is back on. `ARCameraView` sets `automaticallyUpdatesLighting`,
        // and without this the session produces no estimate for it to apply, which
        // leaves the pedals lit by nothing but ARFloorPedals' small ambient floor.
        // Texturing stays off: that is for reflective surfaces, and a stompbox on a
        // carpet reflects nothing worth the frame time.
        configuration.environmentTexturing = .none
        configuration.isLightEstimationEnabled = true
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
            markTap(viewPoint, landed: false)
            return
        }

        // FRONT MODE HAS NOTHING TO RAYCAST AGAINST, so a tap there is not a location
        // — it is a request to re-place at wherever the phone is now pointed. Kept
        // working rather than disabled: if the player CAN reach the phone, "tap to
        // try again" is the obvious thing to attempt, and refusing it silently would
        // read as the page being broken.
        guard facing.detectsPlanes else {
            markTap(viewPoint, landed: autoPlace())
            return
        }

        guard let result = raycast(from: viewPoint, in: feedView) else {
            ARDiagnostics.log("tap MISSED — no raycast hit at "
                            + "(\(ARDiagnostics.f(viewPoint.x, 0)), \(ARDiagnostics.f(viewPoint.y, 0)))")
            markTap(viewPoint, landed: false)
            return
        }

        // Everything needed is copied out of the frame HERE, as values, so that
        // `frame` dies with this call and never escapes into the hop below. A retained
        // ARFrame starves the session — ARKit stops delivering new ones until it is
        // released — and a frame captured by an async closure is retained for as long
        // as that closure lives.
        commit(worldTransform: result.worldTransform, camera: frame.camera, geometry: geometry)
        markTap(viewPoint, landed: true)
    }

    /// Place the board where the phone is currently aimed, with no tap and no plane.
    ///
    /// FRONT MODE'S ENTIRE PLACEMENT GESTURE, and it is not a gesture at all — it is
    /// what happens when the view settles. Called from `apply` the moment the page
    /// reaches `.ready`, and again from a tap if the player is close enough to make
    /// one. Returns whether a board actually went down, so a reachable tap can be
    /// marked landed or missed like any other.
    @discardableResult
    func autoPlace() -> Bool {
        guard let geometry, let frame = session.currentFrame else {
            ARDiagnostics.log("autoplace IGNORED geometry=\(geometry != nil) frame=\(session.currentFrame != nil)")
            return false
        }
        guard let worldTransform = ARAssumedFloor.anchorTransform(camera: frame.camera) else {
            // The only way front mode can refuse: the phone is level or looking up,
            // so there is no plausible floor in front of it. See `isUsableAim`.
            ARDiagnostics.log("autoplace REFUSED — aim not below level")
            return false
        }
        let origin = worldTransform.columns.3.xyz
        ARDiagnostics.log("AUTOPLACE at world(\(ARDiagnostics.f(origin.x)), \(ARDiagnostics.f(origin.y)), "
                        + "\(ARDiagnostics.f(origin.z))) "
                        + "camY=\(ARDiagnostics.f(frame.camera.transform.columns.3.y)) "
                        + "drop=\(ARDiagnostics.f(frame.camera.transform.columns.3.y - origin.y))m "
                        + "pitch=\(ARDiagnostics.f(ARFloorCalibration.placementDegrees, 1))° "
                        + "distance=\(ARDiagnostics.f(ARAssumedFloor.distance))m ASSUMED")
        commit(worldTransform: worldTransform, camera: frame.camera, geometry: geometry)
        return true
    }

    /// Pin the row to `worldTransform` and tell everyone. The half of placement that
    /// is identical whether the spot was raycast against a real plane or assumed from
    /// the camera's aim — kept in one place so the two modes cannot drift into
    /// different ideas of what "placed" means.
    private func commit(worldTransform: simd_float4x4,
                        camera: ARCamera,
                        geometry: ARPlacementCoordinator.ViewGeometry) {
        // Everything needed is copied out of the frame's camera HERE, as values, so
        // that the frame dies with the caller and never escapes into the hop below. A
        // retained ARFrame starves the session — ARKit stops delivering new ones until
        // it is released — and a frame captured by an async closure is retained for as
        // long as that closure lives.
        let cameraTransform = camera.transform
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
        // Refusing the tap there would strand the player in `.ready` forever — so the
        // plane is extended past its mapped edge instead.
        //
        // `.existingPlaneInfinite` AND NOT `.estimatedPlane`, WHICH THIS USED TO USE.
        // The difference is the whole of "it places on a flat surface": an infinite
        // plane is a real detected one carried on past where geometry has been filled
        // in, so it is flat by construction and level with the floor ARKit actually
        // found. An ESTIMATED plane is a guess made from feature points under the
        // tapped pixel, and it will happily hand back a tilted shelf of a surface in
        // the middle of a rug, a shadow, or a pile of cable — which is a board built
        // on a slope, discovered only once it is standing there crooked.
        //
        // Nothing is lost by the swap: `.ready` already REQUIRES a real horizontal
        // plane (`ingest` only ever records `plane.alignment == .horizontal`), so by
        // the time a tap is accepted at all there is a genuine plane to extend.
        guard let infinite = view.raycastQuery(from: viewPoint, allowing: .existingPlaneInfinite, alignment: .horizontal),
              let hit = session.raycast(infinite).first else {
            return nil
        }
        ARDiagnostics.log("raycast fell back to existingPlaneInfinite")
        return hit
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
            // FRONT MODE PLACES ITSELF HERE, and this line is the whole of "you never
            // touch the phone". `.ready` already means the view has settled and held;
            // in rear mode that merely PERMITS a tap, which is a gesture nobody a
            // metre away can make. Here the same condition performs the placement.
            if facing.placesAutomatically { autoPlace() }
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
