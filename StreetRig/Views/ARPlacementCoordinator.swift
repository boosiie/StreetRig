//
//  ARPlacementCoordinator.swift
//  StreetRig
//
//  "Is this spot good, and where is the pedal row?" — everything that happens per
//  ARFrame, off the main thread, for the AR pedal page.
//
//  WHY THIS EXISTS AT ALL. The page is used with the phone propped on the floor
//  aimed at the player's feet. Before this, the slots were pinned to the screen and
//  the page looked identical whether the phone was propped somewhere that worked or
//  lying face-down under a chair — the player only found out when stomps started
//  missing, mid-song. That is the worst failure a performance tool can have: it
//  fails quietly. The green outline this file drives is a promise ("this spot
//  works"), and the auto-unlock is the other half of that promise ("...and I will
//  tell you the moment it stops being true").
//
//  ARKIT IS A SENSOR HERE, NOT A RENDERER. Nothing 3D is drawn. ARKit supplies four
//  things and no more: the camera feed, a horizontal plane, a world anchor to pin
//  the layout to, and a tracking-quality signal. The slots stay SwiftUI views in
//  screen space; this file's whole output is a state and three screen points.
//
//  THE ONE COORDINATE SPACE. The slot positions and the stomp position must be
//  expressed in the SAME space or a stomp lands on the wrong slot — the exact class
//  of silent-wrongness this feature exists to kill. That space is UIKit VIEW SPACE:
//  points, origin top-left, in the viewport the camera feed fills.
//    • slots  — `ARCamera.projectPoint(_:orientation:viewportSize:)`, documented to
//               return "2D point in viewport coordinate system with origin at top-left".
//    • stomps — Vision → `CameraOrientation.capturedImagePoint` → the frame's
//               `displayTransform(for:viewportSize:)` → × viewport size.
//  Both end in the same units against the same viewport, so "the leftmost slot on
//  screen" and "the foot under the leftmost slot" are comparable by construction
//  rather than by coincidence.
//
//  THREADING. Every stored property below is touched ONLY on the ARSession's
//  delegate queue (a serial background queue the detector installs). The two
//  exceptions are the view-geometry atomics, which the main thread writes on layout,
//  and the three output closures, which hop to main themselves. That is why this
//  type is `nonisolated` rather than living on the main actor: the neural amp is on
//  the audio thread while this runs, and Vision must not be competing with SwiftUI
//  for the main thread on top of that.
//

import ARKit
import QuartzCore
import Synchronization
import UIKit
import simd

// MARK: - What the page is doing right now

/// Why `.searching` is still searching — the difference between "keep waiting" and
/// "do something different", which is the only part of this the player can act on.
nonisolated enum ARPlacementHint: Equatable, Sendable {
    /// No plane yet: keep the camera pointed at the floor.
    case lookingForFloor
    /// Tracking is `.limited` — the phone is being moved, or ARKit is still
    /// building its map.
    case holdStill
    /// There IS a big enough surface, but it is above the camera or out of shot —
    /// a table, a chair seat, or the floor just off the bottom of the frame.
    case aimLower
}

/// The ONE source of truth for the AR page. Every piece of UI — the banner text,
/// the slot outline colour, whether the slots float on the floor or sit in a row,
/// and whether a detected stomp is allowed through — reads this and nothing else.
nonisolated enum ARPlacementState: Equatable, Sendable {
    /// Nothing started yet.
    case idle
    /// No ARKit here. The Simulator (which never delivers a frame), or a
    /// configuration the device does not support.
    case unsupported
    /// Camera permission refused.
    case denied
    /// Camera live, placement subsystem gated off by `FeatureFlags.arPlacement` —
    /// i.e. the flat screen-fixed page this feature replaced.
    case running
    /// Camera live, looking for somewhere that works.
    case searching(ARPlacementHint)
    /// A usable floor is in view and tracking is steady. **Slots outline green.**
    case ready
    /// The player tapped; the layout is pinned to a world anchor.
    case locked
    /// Was locked, then the phone moved or tracking degraded. Auto-unlocked, and
    /// stomps are suppressed until it is re-placed.
    case lost

    /// Whether ARKit is delivering frames — i.e. whether to show the camera feed
    /// instead of the gradient-and-placeholder fallback.
    var isCameraLive: Bool {
        switch self {
        case .idle, .unsupported, .denied: return false
        case .running, .searching, .ready, .locked, .lost: return true
        }
    }

    /// Green means exactly one thing: "this position works." Never "pedal engaged" —
    /// that is amber, and the two must stay tellable apart at a glance from the floor.
    var placementIsGood: Bool { self == .ready || self == .locked }

    /// A bumped phone silently mis-mapping stomps is the precise failure this whole
    /// feature exists to prevent, so `.lost` swallows them until the player re-places.
    var acceptsStomps: Bool { isCameraLive && self != .lost }
}

// MARK: - The per-frame brain

/// `@unchecked Sendable` because the compiler cannot see the rule this type is built
/// around, and the rule is real: **every stored property below is touched only on the
/// ARSession's delegate queue**, which the detector installs as a serial queue and
/// which is also where `lock`, `clearPlacement` and `reset` are hopped to. The only
/// members reachable from another thread are the two atomics (`orientationRaw`,
/// `viewportPacked`) and the three output closures, which are `let` and `@Sendable`.
/// The alternative — an actor — would make the per-frame path `await`-able and
/// therefore able to queue up behind the main actor, which is precisely what a
/// 60 Hz callback running next to a real-time audio thread must never do.
nonisolated final class ARPlacementCoordinator: NSObject, ARSessionDelegate, @unchecked Sendable {

    /// The viewport the camera feed fills, as the main thread last laid it out.
    /// Both halves of the shared coordinate space are derived from this pair, so
    /// they cannot disagree about which way up or how big the picture is.
    struct ViewGeometry: Sendable {
        var orientation: UIInterfaceOrientation
        var size: CGSize
    }

    // MARK: Tunables
    //
    // ALL OF THESE NEED ON-DEVICE TUNING. They are first-pass numbers chosen from
    // the physical situation (a phone propped on the floor, a person standing about
    // a metre away), not from measurement — ARKit cannot run in the Simulator, so
    // none of them has ever seen a real floor.

    /// Smallest horizontal plane that counts as "floor you could stand a pedalboard
    /// on" rather than detector noise or the top of a speaker cabinet.
    private static let minPlaneExtent: Float = 0.30                 // metres, per side
    /// How far BELOW the camera the plane has to be. Deliberately tiny: the phone is
    /// itself lying on the floor, maybe 8–15 cm up on its own case, so demanding a
    /// realistic "camera height" would reject the only setup this page supports.
    /// What it does buy is rejecting surfaces at or ABOVE the lens — a desk, a
    /// counter, a low shelf — which would otherwise light up green for a spot the
    /// player's feet cannot reach.
    private static let minCameraLift: Float = 0.03                  // metres
    /// How long everything has to hold before the outline turns green. Without it
    /// the border strobes grey/green on every marginal frame, which reads as broken.
    private static let readyDebounce: TimeInterval = 1.0
    /// Hysteresis: leaving `.ready` is slower than entering it, so one dropped frame
    /// cannot flip the promise off.
    private static let dropDebounce: TimeInterval = 0.4
    /// How long a lock survives non-`.normal` tracking before giving up. Short
    /// enough that a knocked phone is caught within a bar of music.
    private static let trackingGrace: TimeInterval = 1.0
    /// How far the phone may move, measured from where it was when the player
    /// tapped, before the lock is a lie.
    private static let maxLockDrift: Float = 0.15                   // metres
    private static let maxLockRotation: Float = 15 * .pi / 180      // radians
    /// Minimum time `.lost` stays on screen. Without it a phone that is nudged and
    /// settles flashes the warning too briefly to notice, and the player never
    /// learns the layout was dropped.
    private static let lostDwell: TimeInterval = 1.2
    /// Sideways spacing between the three slots on the real floor. Pedal centres on
    /// a board sit closer than this; feet do not.
    private static let slotSpacing: Float = 0.30                    // metres
    /// Ceiling on how often projected slot positions are published to SwiftUI.
    /// ARKit delivers 60 Hz; re-laying out three slots that often would burn main
    /// thread the amp sim needs, for motion no one can see.
    private static let slotPublishInterval: TimeInterval = 1.0 / 30.0
    /// Below this, a "move" is ARKit refining its estimate, not the phone moving.
    private static let slotPublishDeadband: CGFloat = 0.5           // points

    // MARK: Outputs
    //
    // `let` and set once at construction on purpose: they are read from the session
    // queue on every frame, and a closure that could be swapped mid-flight would be
    // a data race with no symptom until it crashed on stage.

    private let emitState: @Sendable (ARPlacementState) -> Void
    private let emitSlots: @Sendable ([CGPoint]?) -> Void
    /// (slot index, normalized x of the foot across the viewport).
    private let emitStomp: @Sendable (Int, CGFloat) -> Void

    /// Whether the readiness/anchoring layer runs at all. Fixed for the lifetime of
    /// the coordinator; flipping `FeatureFlags.arPlacement` needs a relaunch, which
    /// is what a compile-time gate means.
    private let placementEnabled: Bool

    private let pose = StompPoseTracker()

    init(placementEnabled: Bool,
         onState: @escaping @Sendable (ARPlacementState) -> Void,
         onSlots: @escaping @Sendable ([CGPoint]?) -> Void,
         onStomp: @escaping @Sendable (Int, CGFloat) -> Void) {
        self.placementEnabled = placementEnabled
        self.emitState = onState
        self.emitSlots = onSlots
        self.emitStomp = onStomp
        super.init()
    }

    // MARK: View geometry (main writes, session queue reads)

    /// Interface orientation, as a `UIInterfaceOrientation.rawValue`.
    ///
    /// The INTERFACE orientation is stored rather than the `CGImagePropertyOrientation`
    /// the previous version kept, because there are now two consumers — Vision and
    /// ARKit's `displayTransform` / `projectPoint`, which want the interface value —
    /// and storing the already-mapped answer would force the second one to map back.
    /// One stored fact, both answers derived from `CameraOrientation`.
    private let orientationRaw = Atomic<Int>(UIInterfaceOrientation.landscapeRight.rawValue)

    /// Viewport size as two `Float32` bit patterns packed into one word.
    ///
    /// An atomic rather than a lock for the same reason the orientation is: this is
    /// read on the frame path, which must never be able to block on the main thread
    /// while the neural amp is running. A rotation can leave the new orientation
    /// paired with the old size for a single frame; that is one frame of slightly
    /// wrong projection, absorbed by the readiness debounce, and it is a far better
    /// trade than a lock on the hot path.
    private let viewportPacked = Atomic<UInt64>(0)

    /// Called from the camera view's layout pass — the one moment UIKit guarantees a
    /// rotation has been committed (an orientation notification races the change it
    /// is reacting to).
    func setViewGeometry(orientation: UIInterfaceOrientation, size: CGSize) {
        orientationRaw.store(orientation.rawValue, ordering: .relaxed)
        let packed = UInt64(Float(size.width).bitPattern) << 32 | UInt64(Float(size.height).bitPattern)
        viewportPacked.store(packed, ordering: .relaxed)
    }

    private func currentGeometry() -> ViewGeometry? {
        let packed = viewportPacked.load(ordering: .relaxed)
        let width = CGFloat(Float(bitPattern: UInt32(truncatingIfNeeded: packed >> 32)))
        let height = CGFloat(Float(bitPattern: UInt32(truncatingIfNeeded: packed)))
        // Nothing has been laid out yet: there is no viewport to be correct about,
        // so do no work rather than project into a zero-sized rectangle.
        guard width > 1, height > 1 else { return nil }
        let orientation = UIInterfaceOrientation(rawValue: orientationRaw.load(ordering: .relaxed)) ?? .landscapeRight
        return ViewGeometry(orientation: orientation, size: CGSize(width: width, height: height))
    }

    // MARK: Session-queue state

    private struct PlaneSnapshot {
        var worldCenter: simd_float3
        var width: Float
        var height: Float
    }

    private var state: ARPlacementState = .idle
    /// Horizontal planes only, summarised. Kept as a running cache updated from the
    /// anchor callbacks rather than re-read from `frame.anchors` every frame, which
    /// would bridge an NSArray 60 times a second for data that changes rarely.
    private var planes: [UUID: PlaneSnapshot] = [:]

    private var readySince: TimeInterval?
    private var notReadySince: TimeInterval?
    private var lostSince: TimeInterval?
    private var degradedSince: TimeInterval?
    private var interrupted = false

    private var anchorID: UUID?
    private var anchorTransform: simd_float4x4?
    /// The three slot positions in the ANCHOR's own space. Stored relative to the
    /// anchor, not to the world, so that when ARKit refines where it thinks the
    /// anchor is the whole row moves with it — which is what makes the layout stay
    /// on the real floor instead of on a remembered guess of it.
    private var slotOffsets: [simd_float4]?
    /// Where the camera was, expressed in the anchor's frame, at the moment of the
    /// tap. Anchor-relative on purpose: ARKit periodically corrects its world
    /// origin, and a world-space comparison would read that correction as the player
    /// kicking the phone and drop a perfectly good lock.
    private var lockPose: simd_float4x4?

    /// Screen x of each slot centre, for binning a stomp. Three scalars rather than
    /// an array because this is read on every processed frame and rewritten on every
    /// frame — an array here would be a 60 Hz allocation for three numbers.
    private var slotCentersX: (CGFloat, CGFloat, CGFloat)?
    private var lastPublishedSlots: (CGPoint, CGPoint, CGPoint)?
    private var lastSlotPublish: TimeInterval = 0

    // MARK: Lifecycle, driven from the detector

    /// Seed the machine when the session (re)starts.
    func reset(to state: ARPlacementState) {
        self.state = state
        planes.removeAll(keepingCapacity: true)
        readySince = nil
        notReadySince = nil
        lostSince = nil
        degradedSince = nil
        interrupted = false
        clearLock()
        pose.reset()
    }

    /// Pin the layout. Called once per successful tap, with everything already
    /// resolved on the main thread (see `CameraStompDetector.place`) so this hop
    /// carries only value types and cannot touch a live `ARFrame`.
    func lock(anchorID: UUID,
              anchorTransform: simd_float4x4,
              slotOffsets: [simd_float4],
              cameraTransform: simd_float4x4) {
        self.anchorID = anchorID
        self.anchorTransform = anchorTransform
        self.slotOffsets = slotOffsets
        self.lockPose = simd_mul(simd_inverse(anchorTransform), cameraTransform)
        self.degradedSince = nil
        self.interrupted = false
        set(.locked)
    }

    /// The "reposition" affordance: forget the anchor and go looking again. Distinct
    /// from `unlock` because the player asked for it — no warning haptic, no `.lost`.
    func clearPlacement() {
        clearLock()
        readySince = nil
        notReadySince = nil
        lostSince = nil
        // State first, then the points. Both hops land on the main queue in this
        // order, and the page decides whether to draw the anchored row from the
        // STATE — so clearing the points first would leave one render with the
        // anchored layout selected and nothing to put in it, i.e. three slots
        // blinking out for a frame.
        set(.searching(.lookingForFloor))
        emitSlots(nil)
    }

    private func clearLock() {
        anchorID = nil
        anchorTransform = nil
        slotOffsets = nil
        lockPose = nil
        slotCentersX = nil
        lastPublishedSlots = nil
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // No viewport yet means nothing on screen to be right about. Returning here
        // also keeps Vision idle until the page is actually laid out.
        guard let geometry = currentGeometry() else { return }
        let now = CACurrentMediaTime()

        if placementEnabled {
            if case .locked = state {
                evaluateLock(camera: frame.camera, now: now, geometry: geometry)
            } else {
                evaluateReadiness(camera: frame.camera, now: now, geometry: geometry)
            }
        }

        guard state.acceptsStomps else { return }

        // ONE space: the same viewport, the same orientation, the same frame. The
        // display transform is what turns the captured image's coordinates into this
        // view's, and it is the only conversion applied to the foot — the slots
        // arrive in the same space via `projectPoint` above.
        let displayTransform = frame.displayTransform(for: geometry.orientation,
                                                      viewportSize: geometry.size)
        if let stomp = pose.process(pixelBuffer: frame.capturedImage,
                                    geometry: geometry,
                                    displayTransform: displayTransform,
                                    slotCentersX: slotCentersX) {
            emitStomp(stomp.slot, stomp.normalizedX)
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { ingest(anchors) }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { ingest(anchors) }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors {
            if anchor is ARPlaneAnchor {
                planes[anchor.identifier] = nil
            } else if anchor.identifier == anchorID {
                // ARKit dropped the thing the layout was pinned to. Whatever is on
                // screen is now decoration, so stop pretending it is a footswitch.
                unlock(now: CACurrentMediaTime())
            }
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        interrupted = true
        if case .locked = state { unlock(now: CACurrentMediaTime()) }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        interrupted = false
        // The map ARKit hands back after an interruption is a fresh one; planes
        // found before it are stale guesses about where the floor was.
        planes.removeAll(keepingCapacity: true)
        readySince = nil
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        // A failed session does not recover on its own. Report it as the page's
        // no-camera case so the always-available tap-to-toggle fallback takes over,
        // rather than leaving a dead feed and a banner that lies about looking.
        if let arError = error as? ARError, arError.code == .cameraUnauthorized {
            set(.denied)
        } else {
            set(.unsupported)
        }
    }

    private func ingest(_ anchors: [ARAnchor]) {
        for anchor in anchors {
            if let plane = anchor as? ARPlaneAnchor {
                guard plane.alignment == .horizontal else { continue }
                let centre = simd_mul(plane.transform, simd_float4(plane.center, 1)).xyz
                planes[plane.identifier] = PlaneSnapshot(worldCenter: centre,
                                                         width: plane.planeExtent.width,
                                                         height: plane.planeExtent.height)
            } else if anchor.identifier == anchorID {
                // ARKit refined where it believes the anchor is. Take the new
                // transform: the slot offsets are relative to it, so the row follows
                // the correction instead of drifting off the real floor.
                anchorTransform = anchor.transform
            }
        }
    }

    // MARK: - Readiness

    private func evaluateReadiness(camera: ARCamera, now: TimeInterval, geometry: ViewGeometry) {
        // Hold `.lost` long enough for a player looking at their feet to register it.
        if case .lost = state, now - (lostSince ?? now) < Self.lostDwell { return }

        let trackingNormal: Bool
        if case .normal = camera.trackingState { trackingNormal = true } else { trackingNormal = false }

        let cameraY = camera.transform.columns.3.y
        // Leaving is more forgiving than entering: while already green a plane may
        // slide a little outside the viewport without the promise becoming false.
        let alreadyReady = (state == .ready)
        let margin: CGFloat = alreadyReady ? 0.25 : 0

        var usable = false
        var sawSurface = false
        for plane in planes.values {
            guard plane.width >= Self.minPlaneExtent, plane.height >= Self.minPlaneExtent else { continue }
            sawSurface = true
            // Below the lens, or it is a desk / chair / shelf the player cannot stomp.
            guard plane.worldCenter.y < cameraY - Self.minCameraLift else { continue }
            guard inView(plane.worldCenter, camera: camera, geometry: geometry, margin: margin) else { continue }
            usable = true
            break
        }

        if usable && trackingNormal {
            notReadySince = nil
            if readySince == nil { readySince = now }
            if now - (readySince ?? now) >= Self.readyDebounce {
                set(.ready)
            } else if !alreadyReady {
                set(.searching(.holdStill))     // everything is right; just settling
            }
        } else {
            readySince = nil
            if notReadySince == nil { notReadySince = now }
            // One bad frame must not flip the outline off.
            if alreadyReady, now - (notReadySince ?? now) < Self.dropDebounce { return }
            set(.searching(hint(for: camera.trackingState, sawSurface: sawSurface)))
        }
    }

    private func hint(for tracking: ARCamera.TrackingState, sawSurface: Bool) -> ARPlacementHint {
        switch tracking {
        case .normal:
            // Tracking is fine and there IS a surface — so the problem is which
            // surface, or where it is pointed. Both answers are "lower".
            return sawSurface ? .aimLower : .lookingForFloor
        case .notAvailable:
            return .lookingForFloor
        case .limited(let reason):
            switch reason {
            case .excessiveMotion, .initializing, .relocalizing: return .holdStill
            case .insufficientFeatures:                          return .lookingForFloor
            @unknown default:                                    return .lookingForFloor
            }
        @unknown default:
            return .lookingForFloor
        }
    }

    /// Whether a world point is both in FRONT of the camera and inside the viewport.
    ///
    /// The front test is separate and comes first because `projectPoint` happily
    /// returns a plausible-looking point for geometry behind the lens — a floor the
    /// phone has been knocked away from would otherwise keep reading as "in view".
    private func inView(_ world: simd_float3,
                        camera: ARCamera,
                        geometry: ViewGeometry,
                        margin: CGFloat) -> Bool {
        let local = simd_mul(simd_inverse(camera.transform), simd_float4(world, 1))
        guard local.z < -0.05 else { return false }     // ARKit's camera looks down -Z
        let point = camera.projectPoint(world,
                                        orientation: geometry.orientation,
                                        viewportSize: geometry.size)
        guard point.x.isFinite, point.y.isFinite else { return false }
        let slackX = geometry.size.width * margin
        let slackY = geometry.size.height * margin
        return point.x >= -slackX && point.x <= geometry.size.width + slackX
            && point.y >= -slackY && point.y <= geometry.size.height + slackY
    }

    // MARK: - Holding, and losing, the lock

    private func evaluateLock(camera: ARCamera, now: TimeInterval, geometry: ViewGeometry) {
        guard !interrupted else { return unlock(now: now) }
        guard let anchorTransform, let slotOffsets, slotOffsets.count == 3 else { return unlock(now: now) }

        if case .normal = camera.trackingState {
            degradedSince = nil
        } else {
            if degradedSince == nil { degradedSince = now }
            guard now - (degradedSince ?? now) <= Self.trackingGrace else { return unlock(now: now) }
        }

        // Did the phone move? Asked in the ANCHOR's frame — see `lockPose`.
        if let lockPose {
            let cameraInAnchor = simd_mul(simd_inverse(anchorTransform), camera.transform)
            let moved = simd_distance(cameraInAnchor.columns.3.xyz, lockPose.columns.3.xyz)
            let turned = abs(simd_mul(lockPose.rotation.inverse, cameraInAnchor.rotation).angle)
            guard moved <= Self.maxLockDrift, turned <= Self.maxLockRotation else { return unlock(now: now) }
        }

        let worldCentre = simd_mul(anchorTransform, slotOffsets[1]).xyz
        let local = simd_mul(simd_inverse(camera.transform), simd_float4(worldCentre, 1))
        // The floor has gone behind the lens — the phone is face-down or tipped over.
        guard local.z < -0.05 else { return unlock(now: now) }

        let p0 = project(slotOffsets[0], anchor: anchorTransform, camera: camera, geometry: geometry)
        let p1 = project(slotOffsets[1], anchor: anchorTransform, camera: camera, geometry: geometry)
        let p2 = project(slotOffsets[2], anchor: anchorTransform, camera: camera, geometry: geometry)
        guard p0.x.isFinite, p1.x.isFinite, p2.x.isFinite else { return unlock(now: now) }

        // Binning reads this on the frame path; publishing to SwiftUI is throttled.
        slotCentersX = (p0.x, p1.x, p2.x)
        publishSlotsIfMoved((p0, p1, p2), now: now)
    }

    private func project(_ offset: simd_float4,
                         anchor: simd_float4x4,
                         camera: ARCamera,
                         geometry: ViewGeometry) -> CGPoint {
        let world = simd_mul(anchor, offset).xyz
        return camera.projectPoint(world, orientation: geometry.orientation, viewportSize: geometry.size)
    }

    private func publishSlotsIfMoved(_ points: (CGPoint, CGPoint, CGPoint), now: TimeInterval) {
        guard now - lastSlotPublish >= Self.slotPublishInterval else { return }
        if let last = lastPublishedSlots,
           abs(last.0.x - points.0.x) < Self.slotPublishDeadband,
           abs(last.0.y - points.0.y) < Self.slotPublishDeadband,
           abs(last.2.x - points.2.x) < Self.slotPublishDeadband,
           abs(last.2.y - points.2.y) < Self.slotPublishDeadband {
            return
        }
        lastSlotPublish = now
        lastPublishedSlots = points
        emitSlots([points.0, points.1, points.2])
    }

    private func unlock(now: TimeInterval) {
        clearLock()
        degradedSince = nil
        readySince = nil
        notReadySince = now
        lostSince = now
        set(.lost)          // state before points — see `clearPlacement`
        emitSlots(nil)
    }

    private func set(_ new: ARPlacementState) {
        guard new != state else { return }
        state = new
        emitState(new)
    }

    // MARK: - Laying the row out on the real floor

    /// The three slot positions, expressed in the anchor's own space, for a tap that
    /// hit `anchorTransform` while the camera was where `camera` says it was.
    ///
    /// Run on the MAIN thread at lock time (it needs the live `ARCamera`), then
    /// handed to `lock` as plain values.
    ///
    /// The hard part is which way "sideways" points. ARKit's camera axes are defined
    /// for a device in LANDSCAPE-RIGHT, so `transform.columns.0` is screen-right only
    /// in one of the two orientations this app ships — take it on faith in
    /// `.landscapeLeft` and the row comes out mirrored, i.e. every stomp toggles the
    /// wrong end of the board. The rotation that fixes it is the same one the preview
    /// and Vision already use, so it is read from `CameraOrientation` rather than
    /// re-derived here.
    nonisolated static func slotOffsets(anchorTransform: simd_float4x4,
                                        camera: ARCamera,
                                        geometry: ViewGeometry) -> [simd_float4] {
        let theta = Float(CameraOrientation.previewRotationAngle(for: geometry.orientation)) * .pi / 180
        let cameraRight = camera.transform.columns.0.xyz
        let cameraUp = camera.transform.columns.1.xyz
        var lateral = cos(theta) * cameraRight + sin(theta) * cameraUp
        lateral.y = 0                                    // keep the row flat on the floor

        if simd_length(lateral) < 1e-4 {
            // Screen-right is pointing almost straight up or down — the phone is
            // rolled onto its edge. Fall back to a sideways axis derived from where
            // it is looking, which is always defined.
            var forward = -camera.transform.columns.2.xyz
            forward.y = 0
            if simd_length(forward) < 1e-4 { forward = simd_float3(0, 0, -1) }
            lateral = simd_cross(simd_normalize(forward), simd_float3(0, 1, 0))
        }
        lateral = simd_normalize(lateral)

        let origin = anchorTransform.columns.3.xyz
        // The safety net, and the reason this is worth six extra lines: ask the
        // projector where these two would actually DRAW. The screen is what the
        // player aims at, so if the world layout and the screen disagree about which
        // end is left, the screen wins.
        let left = camera.projectPoint(origin - lateral * Self.slotSpacing,
                                       orientation: geometry.orientation, viewportSize: geometry.size)
        let right = camera.projectPoint(origin + lateral * Self.slotSpacing,
                                        orientation: geometry.orientation, viewportSize: geometry.size)
        if right.x < left.x { lateral = -lateral }

        let inverse = simd_inverse(anchorTransform)
        return [-Self.slotSpacing, 0, Self.slotSpacing].map { distance in
            simd_mul(inverse, simd_float4(origin + lateral * distance, 1))
        }
    }
}

// MARK: - simd conveniences
//
// `nonisolated` because the project defaults declarations to the main actor
// (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), and every caller of these is on the
// session queue.

extension simd_float4 {
    nonisolated var xyz: simd_float3 { simd_float3(x, y, z) }
}

extension simd_float4x4 {
    /// The rotation half of a rigid transform. Safe to read as a quaternion only
    /// because ARKit's transforms carry no scale.
    nonisolated var rotation: simd_quatf {
        simd_quatf(simd_float3x3(columns.0.xyz, columns.1.xyz, columns.2.xyz))
    }
}
