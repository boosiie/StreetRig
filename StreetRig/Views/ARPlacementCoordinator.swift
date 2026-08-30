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

/// Where the anchored pedal row sits on the real floor, in the form the SceneKit
/// nodes need: the anchor's world transform plus the slot centres in the ANCHOR's
/// own space, so a refinement to the anchor carries the whole row with it.
///
/// Distinct from the projected `[CGPoint]` the SwiftUI chrome uses. The 3D pedals
/// need no projection at all — SceneKit renders them through the same AR camera
/// that draws the feed, which is the entire reason they look like they are on the
/// floor rather than pasted over it.
///
/// THE ONE PLACE DECK HEIGHT IS DECIDED. Three things read slot position — the
/// SceneKit pedal node, the point `FloorSlotChrome` draws its label at, and
/// `slotCentersX`, which decides which slot a detected foot toggles. Once the pedals
/// stand on a board those three have to move UP together or a label sits over empty
/// carpet and a stomp lands on the wrong pedal. So the lift is applied exactly once,
/// here, into `offsets` — the projections downstream are untouched and follow for
/// free — and the amount is carried alongside so anything needing the floor again
/// can subtract the number that was actually used rather than re-derive one.
struct ARFloorPose: Equatable {
    var anchor: simd_float4x4
    /// Slot centres in the anchor's own space. WITH the deck lift already in them
    /// when there is a board: these are mount points, not floor points.
    var offsets: [simd_float4]
    /// Yaw, in radians about the anchor's up axis, that turns a pedal to face where
    /// the camera was standing when the player tapped. Fixed at lock time rather
    /// than tracked: pedals on a floor do not swivel to follow you around the room.
    var facing: Float
    /// How much of each offset's height is board rather than floor. Zero when
    /// `FeatureFlags.arPedalboard` is off, which is what makes that path identical
    /// to the flat row this replaced.
    var deckLift: Float
    /// The pitch that deck is raked at, for whatever is standing on it. Carried
    /// rather than looked up so the geometry a frame renders can never be a
    /// different shape from the one its offsets were computed for.
    var deckRake: Float

    static func == (a: Self, b: Self) -> Bool {
        a.anchor == b.anchor && a.offsets == b.offsets && a.facing == b.facing
            && a.deckLift == b.deckLift && a.deckRake == b.deckRake
    }
}

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
    ///
    /// LOWERED FROM 0.30 after a real session. 30cm per side assumes ARKit hands over
    /// a tidy rectangle of floor, which is what it does in even indoor light and NOT
    /// what it does under a bright window or a stage light: glare kills the feature
    /// contrast plane-fitting runs on, so the floor arrives as a scatter of small
    /// patches instead of one slab, every one of them rejected here. That is the
    /// whole "it only works with no bright light" report. A 12cm patch that is
    /// horizontal and below the lens is still evidence of a floor — which is all this
    /// gate was ever meant to establish.
    private static let minPlaneExtent: Float = 0.12                 // metres, per side
    /// How far BELOW the camera the plane has to be. Deliberately tiny: the phone is
    /// itself lying on the floor, maybe 8–15 cm up on its own case, so demanding a
    /// realistic "camera height" would reject the only setup this page supports.
    /// What it does buy is rejecting surfaces at or ABOVE the lens — a desk, a
    /// counter, a low shelf — which would otherwise light up green for a spot the
    /// player's feet cannot reach.
    private static let minCameraLift: Float = 0.015                 // metres
    /// How long everything has to hold before the outline turns green. Without it
    /// the border strobes grey/green on every marginal frame, which reads as broken.
    /// Shortened with the gates below: they now accept a floor far more readily, so
    /// a full second of holding still reads as the page ignoring you.
    private static let readyDebounce: TimeInterval = 0.6
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
    ///
    /// Not private, because `ARFloorPedalboard` sizes the board from it: the board
    /// has to be as wide as THIS row, not as wide as a board you could buy. Read the
    /// note there before changing this number — it is the width of the thing the
    /// player stands over, in both directions at once.
    /// Fallback row spacing, and the bounds the FITTED one is held inside. The real
    /// spacing is derived from the viewport — see `slotOffsets`.
    nonisolated static let slotSpacing: Float = 0.30                // metres
    nonisolated static let minSlotSpacing: Float = 0.12
    nonisolated static let maxSlotSpacing: Float = 1.20

    /// HOW MUCH OF THE SCREEN THE BOARD TAKES, and how much is left beside it.
    ///
    /// The board used to be a fixed 0.30 m between pedals, projected wherever that
    /// landed — which, at any sane distance, is a small row in the middle of a big
    /// picture. Detecting a real floor accurately enough to do better turned out to
    /// be the weak link: it wants texture and even light, and a stage floor under a
    /// window gives neither.
    ///
    /// So the board is no longer sized in the world and projected; it is sized on the
    /// SCREEN and the world spacing solved backwards from it. The floor is assumed
    /// (it is right under the phone), the row fills the frame, and nothing depends on
    /// ARKit recognising a carpet.
    /// 0.38, pulled in from 0.48 — and the reason is DETECTION, not layout taste.
    ///
    /// Widening the board looks better and puts the outer pedals where Vision stops
    /// finding feet. Body pose needs the joint properly inside the frame; an ankle
    /// out at the edge comes back low-confidence or not at all, and a pedal whose
    /// foot is never SEEN cannot be fixed by giving it a bigger catch — there is
    /// nothing to catch. That was the right-hand pedal: not a small zone, an unseen
    /// foot.
    ///
    /// So the row is sized to sit inside the part of the frame the tracker actually
    /// works in. It costs apparent size, which was explicitly asked for, and that is
    /// the trade: a smaller board where all three pedals work beats a full-width one
    /// where the outer two do not.
    /// Back to 0.48. Narrowing it to 0.38 was meant to pull the outer pedals inside
    /// the region the pose tracker works in, but it bought that by crowding all three
    /// together — and the crowding was the worse problem. The LEFT SHIFT is what
    /// actually gave the right-hand pedal its margin, and that stays; the span does
    /// not need to pay for it as well.
    nonisolated static let rowSpanFraction: CGFloat = 0.48          // of viewport width
    /// Where the row's centre sits across the frame, leaving the rest for the pad.
    /// 0.56, pulled back from 0.62. The row was slid right to clear the switch pad,
    /// which put the right-hand pedal at 86% of the width — barely any frame beyond
    /// it, and the outer slots catch by having frame beyond them. It was the tightest
    /// target on the board and the one reported as not working. This gives it about
    /// half as much again to catch with, and still leaves the pad its space.
    nonisolated static let rowCentreFraction: CGFloat = 0.56
    /// Moved in from 0.10 for the same reason as the row: a switch pad at a tenth of
    /// the width puts the foot that presses it against the left edge, where the ankle
    /// stops being found. Its catch is still open-ended outward, so standing anywhere
    /// left of it counts — it just no longer ASKS the player to stand off-frame.
    /// 0.10. At 0.13 the pad's 88pt disc and the wah's 190pt chrome needed 139pt of
    /// separation and had 131 — so the switch drew ON TOP of the pedal it switches,
    /// which is the one place it must not be: the whole point of putting it on the
    /// empty floor is that standing on it is unambiguous.
    nonisolated static let padCentreFraction: CGFloat = 0.10
    /// Ceiling on how often projected slot positions are published to SwiftUI.
    /// ARKit delivers 60 Hz; re-laying out three slots that often would burn main
    /// thread the amp sim needs, for motion no one can see.
    private static let slotPublishInterval: TimeInterval = 1.0 / 30.0
    /// Below this, a "move" is ARKit refining its estimate, not the phone moving.
    private static let slotPublishDeadband: CGFloat = 0.5           // points

    /// How far above and below a pedal the treadle's full travel spans, as a fraction
    /// of the viewport. A rocking foot moves the ANKLE only a little — the toe does
    /// most of the travelling, and the toe is not a joint this API reports — so the
    /// band has to be narrow.
    ///
    /// TUNED ON A DEVICE (was 0.075, which was unplayable). The trap: this page is
    /// LANDSCAPE, so `geometry.size.height` is the SHORT side, ~400pt — not the
    /// ~870pt the number reads like. At 0.075 the full 0→1 sweep therefore demanded
    /// about 60pt of ANKLE travel on screen, and an ankle simply does not move that
    /// far when a foot rocks heel-to-toe. The reported symptom was the honest one:
    /// "it takes too much to move the wah, I can't even hear it" — the foot was
    /// covering maybe a quarter of the range, and a quarter of a 450 Hz → 1.6 kHz
    /// log sweep is not a wah, it is a slight tone change.
    ///
    /// 0.025 puts the full sweep inside ~20pt, which is the order of magnitude an
    /// ankle actually travels. Raise it if the sweep feels twitchy, lower it if a
    /// full rock still does not reach the extremes.
    /// 0.018, down from 0.025: a full sweep now takes about 14pt of ankle travel
    /// rather than 20. Reported as still needing too much foot for the movement a
    /// rock actually produces.
    private static let treadleBand: CGFloat = 0.018
    /// One-pole smoothing on the treadle. This ends up on a filter sweep, where raw
    /// 18 Hz jitter is an audible warble rather than a merely visual one — but too
    /// much of it reads as the pedal lagging the foot, which is its own kind of
    /// broken. Raised with the band above: a narrower band means the same jitter
    /// now moves the value further, so the response has to be quicker to keep up
    /// with a real rock rather than smearing it.
    /// Raised with the band: a narrower band means the same rock covers the range in
    /// less time, so the filter has to keep up or the sweep lags the foot.
    /// How fast the observed sweep range forgets. Slow — it is describing a stance,
    /// and a range that chased every frame would collapse onto the current position
    /// and leave no sweep at all.
    private static let sweepRangeBleed: CGFloat = 0.004
    /// Smallest observed travel, in points, that counts as a sweep rather than as
    /// jitter. Small on purpose: a foot seen head-on barely moves on screen, and
    /// whatever it does move is the whole of the signal available.
    private static let minSweepSpan: CGFloat = 3
    private static let treadleSmoothing: Double = 0.50
    /// Below this the value has not really moved; not worth a hop to the main thread.
    /// Finer than it was, because this now drives a POSITION BAR the player is
    /// watching as well as the filter, and a bar that advances in visible steps
    /// reads as broken tracking.
    private static let treadleStep: Double = 0.008
    /// THE SWITCH PAD: a patch of empty floor BESIDE the board, past the end of the
    /// row on the rocker's own side, in metres along the row axis from that end.
    ///
    /// Everything before this tried to carve the switch out of the pedal's own
    /// travel — past the toe, behind the heel — and every version traded one failure
    /// for another, because the sweep and the switch were competing for the same few
    /// centimetres of foot movement. Sideways is not scarce: the board is projected
    /// small, there is floor either side of it doing nothing, and a foot that steps
    /// off the pedal to the side is unambiguously not sweeping.
    ///
    /// So the switch is its own place on the floor. Step on it and stamp — no hold,
    /// no travel past an end, nothing that ordinary playing does by accident.
    nonisolated static let switchPadGap: Float = 0.30               // metres past the row's end
    /// How near the pad's centre the foot counts as being on it, in viewport widths.
    private static let switchPadRadius: CGFloat = 0.11
    /// UNUSED BY THE PAD, kept for the sweep's own clamping: the toe-end zone the
    /// switch used to live in. A dead gap before it and a ceiling above it.
    ///
    /// Two wrong answers got it here, and the second is the instructive one. First it
    /// sat one band past the toe and fired on contact — which is where a player
    /// already goes, since sweeping to full treble IS pushing the toe down, so it
    /// tripped constantly. Moving it behind the HEEL fixed that by making it
    /// unreachable: the ankle would have had to descend ~24pt BELOW the pedal, and
    /// the heel is already resting on the floor at the bottom of the sweep. The floor
    /// is a hard stop; no foot was ever going to get there.
    ///
    /// So it is back on the toe side, which is the only vertical direction with free
    /// travel — the ankle keeps rising as the toe presses harder, while the swept
    /// value stays clamped at 1.0. What makes it deliberate now is not its position
    /// but the GAP it must cross and the DWELL it must hold: press the toe well past
    /// the end of travel and keep it there. That is what a real wah's switch asks
    /// for too.
    ///
    /// The ceiling separates "toe jammed down" from "foot lifted off and walking
    /// away" — the first lands inside the zone, the second sails past it.
    private static let switchZoneGap: CGFloat = 0.04
    private static let switchZoneBand: CGFloat = 0.12
    /// How long the pad's ring takes to fill once a foot lands on it. Cosmetic — the
    /// stamp fires whenever it comes, filled or not.
    private static let switchArmFill: TimeInterval = 0.25
    /// A switch cannot fire again until the foot has come back out of the zone. One
    /// press, one click, exactly as the hardware behaves.
    private static let switchReleaseDebounce: TimeInterval = 0.25
    /// How long stomps stay suppressed after the working foot was last over a
    /// treadle.
    ///
    /// ROCKING A TREADLE IS DOWNWARD ANKLE MOTION, which is precisely what the stomp
    /// detector is looking for. Suppressing stomps on the treadle's own slot was not
    /// enough: the hover bins on the ankle's x, that wanders while a foot rocks, and
    /// a sweep would land a phantom stomp on the pedal NEXT to the wah. One foot
    /// cannot stomp a pedal it is not standing on, so while it is working a treadle
    /// nothing else may fire.
    private static let treadleStompSuppression: TimeInterval = 0.7
    /// The same idea in metres, for the front mode's re-derived floor: below this the
    /// board would be jittering in place rather than following anything.
    private static let floorPublishDeadband: Float = 0.002          // metres

    // MARK: Outputs
    //
    // `let` and set once at construction on purpose: they are read from the session
    // queue on every frame, and a closure that could be swapped mid-flight would be
    // a data race with no symptom until it crashed on stage.

    private let emitState: @Sendable (ARPlacementState) -> Void
    private let emitSlots: @Sendable ([CGPoint]?) -> Void
    /// The anchored row's pose on the floor. Emitted on lock, on every anchor
    /// refinement, and nil'd on unlock — NOT per frame: the nodes live in world
    /// space, so between refinements there is nothing to tell anyone.
    private let emitFloor: @Sendable (ARFloorPose?) -> Void
    /// (slot index, normalized x of the foot across the viewport).
    private let emitStomp: @Sendable (Int, CGFloat) -> Void
    /// Which slot the player's foot is currently over, or nil. Emitted only when the
    /// answer CHANGES — see the call site.
    /// Why the last lock ended, for the banner. The page used to say "phone moved"
    /// for every unlock, which is one of seven reasons and was the wrong one often
    /// enough to send a player chasing a phone that had not moved.
    private let emitUnlockReason: @Sendable (String) -> Void
    private let emitHover: @Sendable (Int?) -> Void
    /// Which slot's SWITCH ZONE the foot is standing in and how far through the hold
    /// it is (0…1). Nil the moment it leaves, so the player can see it arm and let go.
    private let emitTreadleArm: @Sendable (Int?, Double) -> Void
    /// Fired once per press, on the frame the foot stamps the pad.
    private let emitTreadleSwitch: @Sendable (Int) -> Void
    /// Where the switch pad is on screen, so the page can draw it on the empty floor
    /// beside the board. Nil when no rocker is on the row.
    private let emitSwitchPad: @Sendable (Int?, CGPoint?) -> Void
    /// Where the working foot sits vertically against the slot it is over, 0…1.
    ///
    /// 0 is heel-down (the foot low on screen, below the pedal), 1 is toe-down (high).
    /// Emitted as a POSITION, not as "a wah value": this layer is a sensor and has no
    /// idea what kind of pedal is in the slot. Whoever knows that decides what a
    /// treadle position means — see `ARPedalContentView`.
    private let emitTreadle: @Sendable (Int, Double) -> Void

    /// Whether the readiness/anchoring layer runs at all. Fixed for the lifetime of
    /// the coordinator; flipping `FeatureFlags.arPlacement` needs a relaunch, which
    /// is what a compile-time gate means.
    private let placementEnabled: Bool

    /// Which camera the session is running, and therefore whether there are planes to
    /// gate on at all. Session-queue only, like every other stored property here —
    /// set through `setFacing` rather than written directly.
    ///
    /// `cameraFacing`, not `facing`: this type already has a `facing`, and it means
    /// something entirely different (the row's yaw toward where the player stood).
    /// Two things called the same thing in one file is how the wrong one gets read.
    private var cameraFacing: ARCameraFacing = .default

    /// Tell the coordinator the camera changed. Hop to the session queue to call it.
    func setFacing(_ new: ARCameraFacing) { cameraFacing = new }

    private let pose = StompPoseTracker()

    init(placementEnabled: Bool,
         onState: @escaping @Sendable (ARPlacementState) -> Void,
         onSlots: @escaping @Sendable ([CGPoint]?) -> Void,
         onFloor: @escaping @Sendable (ARFloorPose?) -> Void,
         onStomp: @escaping @Sendable (Int, CGFloat) -> Void,
         onHover: @escaping @Sendable (Int?) -> Void,
         onTreadle: @escaping @Sendable (Int, Double) -> Void,
         onUnlockReason: @escaping @Sendable (String) -> Void,
         onTreadleArm: @escaping @Sendable (Int?, Double) -> Void,
         onTreadleSwitch: @escaping @Sendable (Int) -> Void,
         onSwitchPad: @escaping @Sendable (Int?, CGPoint?) -> Void) {
        self.placementEnabled = placementEnabled
        self.emitState = onState
        self.emitSlots = onSlots
        self.emitFloor = onFloor
        self.emitStomp = onStomp
        self.emitHover = onHover
        self.emitTreadle = onTreadle
        self.emitUnlockReason = onUnlockReason
        self.emitTreadleArm = onTreadleArm
        self.emitTreadleSwitch = onTreadleSwitch
        self.emitSwitchPad = onSwitchPad
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
        // CHANGES ONLY, and only because a flapping answer here is invisible in every
        // other way. The orientation feeds `projectPoint`, which decides where content
        // is drawn; the feed behind it is drawn from `displayTransform`. If this value
        // alternates — the view leaving and re-entering a window, two sources
        // disagreeing — the content rotates while the picture does not, which reads on
        // screen as flashing and sideways rather than as anything to do with geometry.
        let previous = orientationRaw.exchange(orientation.rawValue, ordering: .relaxed)
        if previous != orientation.rawValue {
            ARDiagnostics.log("geometry orientation \(previous) -> \(orientation.rawValue) "
                            + "size=\(ARDiagnostics.f(size.width, 0))x\(ARDiagnostics.f(size.height, 0))")
        }
        let packed = UInt64(Float(size.width).bitPattern) << 32 | UInt64(Float(size.height).bitPattern)
        let previousPacked = viewportPacked.exchange(packed, ordering: .relaxed)
        if previousPacked != packed, previousPacked != 0 {
            let oldW = Float(bitPattern: UInt32(previousPacked >> 32))
            let oldH = Float(bitPattern: UInt32(previousPacked & 0xFFFF_FFFF))
            ARDiagnostics.log("geometry size \(ARDiagnostics.f(oldW, 0))x\(ARDiagnostics.f(oldH, 0)) -> "
                            + "\(ARDiagnostics.f(size.width, 0))x\(ARDiagnostics.f(size.height, 0))")
        }
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
    /// See `ARFloorPose.facing`. Held here so a refinement can re-publish without
    /// recomputing it from a camera pose that has since moved.
    private var facing: Float = 0

    /// Screen x of each slot centre, for binning a stomp. Three scalars rather than
    /// an array because this is read on every processed frame and rewritten on every
    /// frame — an array here would be a 60 Hz allocation for three numbers.
    private var slotCentersX: (CGFloat, CGFloat, CGFloat)?
    private var lastPublishedSlots: (CGPoint, CGPoint, CGPoint)?
    private var lastSlotPublish: TimeInterval = 0
    /// Last hover published, so an unchanged answer is not re-sent 18×/second.
    private var lastHover: Int?
    /// View-space y of the three slot centres, alongside `slotCentersX`.
    private var slotCentersY: (CGFloat, CGFloat, CGFloat)?
    /// Which slot's switch zone the foot is in, mirrored here so entry and exit are
    /// each published once rather than on every frame.
    private var armedSlot: Int?
    /// When the foot arrived in the current switch zone, for the dwell.
    private var armedSince: TimeInterval = 0
    /// Last arm progress published, so a foot holding still does not spam the main
    /// thread with the same number.
    private var lastArmProgress: Double = -1
    /// Held true from the frame a switch fires until the foot leaves the zone, so one
    /// press is one click.
    private var switchLatched = false
    private var lastSwitchAt: TimeInterval = 0
    /// When the working foot was last over a slot holding a treadle.
    private var lastTreadleHoverAt: TimeInterval = 0
    /// Set once per placement, when the board has been aimed at the feet. Cleared on
    /// unlock so the next placement re-aims.
    private var aimedAtFeet = false
    /// The working foot's own high and low water marks over recent travel, and the
    /// slot they were measured on. See the note where they are used.
    private var sweepLow: CGFloat?
    private var sweepHigh: CGFloat?
    private var sweepSlot: Int?
    /// Smoothed screen y of the player's PLANTED foot — the floor line, as observed
    /// rather than assumed. Nil until a body has been seen.
    private var groundY: CGFloat?
    /// Which slots hold rocker pedals. Set from the main actor via
    /// `setTreadleSlots`, read only here on the session queue.
    private var treadleSlots: Set<Int> = []
    /// The pad's projected centre and the slot it switches, refreshed with the slots.
    private var switchPadPoint: CGPoint?
    private var switchPadSlot: Int?
    /// Last treadle value emitted, so a foot holding still does not push an unchanged
    /// number onto the main thread 18 times a second.
    private var lastTreadle: Double?
    private var lastTreadleLog: TimeInterval = 0
    /// The placement angle the frozen front-mode board was planted at. Compared each
    /// frame so a calibration drag can move it and nothing else can.
    private var placedPitch: Float = .nan
    /// Throttle state for the front mode's re-derived floor — see `publishFloorIfMoved`.
    private var lastFloorPublish: TimeInterval = 0
    private var lastPublishedFloorOrigin: simd_float3?

    /// Diagnostics throttle. The readiness gates are evaluated 60 times a second and
    /// the interesting thing about them is the trend, not the frame — at 60 Hz the
    /// console scrolls faster than it can be read and the console pipe becomes the
    /// bottleneck. Once a second is enough to watch a floor being found.
    private var lastGateLog: TimeInterval = 0
    private static let gateLogInterval: TimeInterval = 1.0

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
        // Which way the pedals face: toward wherever the phone was when the player
        // tapped. Yaw only, and taken once — a pedal lying on a floor keeps its
        // orientation when you walk around it.
        let camInAnchor = self.lockPose!.columns.3
        self.facing = atan2(camInAnchor.x, camInAnchor.z)
        publishFloor()
        let origin = anchorTransform.columns.3.xyz
        ARDiagnostics.log("LOCK at world(\(ARDiagnostics.f(origin.x)), \(ARDiagnostics.f(origin.y)), "
                        + "\(ARDiagnostics.f(origin.z))) camY=\(ARDiagnostics.f(cameraTransform.columns.3.y)) "
                        + "drop=\(ARDiagnostics.f(cameraTransform.columns.3.y - origin.y))m")
        // The board, once, here. On-device is the only place it can be SEEN, and a
        // board that came out the wrong size has to be diagnosable from a line of
        // console rather than from squinting at a photograph of a carpet.
        if FeatureFlags.arPedalboard {
            ARDiagnostics.log("BOARD \(ARDiagnostics.f(ARFloorPedalboard.width, 3))×"
                            + "\(ARDiagnostics.f(ARFloorPedalboard.depth, 3))m "
                            + "rake=\(ARDiagnostics.f(ARFloorPedalboard.rake * 180 / .pi, 1))° "
                            + "deck=\(ARDiagnostics.f(ARFloorPedalboard.deckHeight, 3))m "
                            + "tier=+\(ARDiagnostics.f(ARFloorPedalboard.tierStep, 3))m "
                            + "derived from spacing=\(ARDiagnostics.f(Self.slotSpacing)) "
                            + "pedal=\(ARDiagnostics.f(ARFloorPedals.pedalWidth, 3)) "
                            + "margin=\(ARDiagnostics.f(ARFloorPedalboard.frameMargin, 3))")
        }
        placedPitch = ARFloorCalibration.placementPitch
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
        // A stale glow over a board that is no longer there is worse than no glow.
        if lastHover != nil { lastHover = nil; emitHover(nil) }
        // The foot is gone, so it is not standing on a switch. Left armed, the
        // highlight would sit lit over a pedal nobody is near.
        if armedSlot != nil { armedSlot = nil; lastArmProgress = -1; emitTreadleArm(nil, 0) }
        switchLatched = false
        anchorID = nil
        anchorTransform = nil
        slotOffsets = nil
        lockPose = nil
        slotCentersX = nil
        slotCentersY = nil
        lastTreadle = nil
        lastPublishedFloorOrigin = nil
        placedPitch = .nan
        lastPublishedSlots = nil
        facing = 0
        emitFloor(nil)
    }

    /// Publish a re-derived front-mode floor, but not 60 times a second.
    ///
    /// The rear path emits a pose only on lock and on anchor refinement — rare events
    /// — so it never needed throttling. Front mode re-derives on EVERY frame, and
    /// every emission crosses to the main thread and re-renders the SceneKit driver
    /// next to a live neural amp. Same ceiling and the same reasoning as the slot
    /// points, plus a deadband so a stationary propped phone whose estimate is
    /// wobbling by a millimetre publishes nothing at all.
    private func publishFloorIfMoved(_ transform: simd_float4x4, now: TimeInterval) {
        guard now - lastFloorPublish >= Self.slotPublishInterval else { return }
        if let last = lastPublishedFloorOrigin {
            let moved = simd_distance(transform.columns.3.xyz, last)
            if moved < Self.floorPublishDeadband { return }
        }
        lastFloorPublish = now
        lastPublishedFloorOrigin = transform.columns.3.xyz
        publishFloor()
    }

    /// Hand the current floor pose out, if there is one to hand out.
    private func publishFloor() {
        guard let anchorTransform, let slotOffsets else { return emitFloor(nil) }
        // `slotOffsets` already carry the lift — see `ARFloorPose`. What is added
        // here is only the description of it, so the renderer never has to ask a
        // second time how high the deck was when these numbers were made.
        emitFloor(ARFloorPose(anchor: anchorTransform,
                              offsets: slotOffsets,
                              facing: facing,
                              deckLift: ARFloorPedalboard.mountLift,
                              deckRake: ARFloorPedalboard.mountRake))
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
        guard let reading = pose.process(pixelBuffer: frame.capturedImage,
                                         geometry: geometry,
                                         displayTransform: displayTransform,
                                         slotCentersX: slotCentersX) else { return }

        // ON CHANGE ONLY. The hover is recomputed ~18×/second and is the same answer
        // almost every time; publishing all of them would re-render the page at that
        // rate to say nothing. Which pedal a foot is over changes a handful of times
        // in a song.
        if reading.hoverSlot != lastHover {
            lastHover = reading.hoverSlot
            ARDiagnostics.log("hover slot=\(reading.hoverSlot.map(String.init) ?? "none")")
            emitHover(reading.hoverSlot)
        }
        // THE TREADLE. How high the working foot is riding against the pedal it is
        // over — the continuous half of what a foot can say, next to the discrete
        // "it stamped". Only meaningful while a foot is actually over a slot.
        if let slot = reading.hoverSlot, let foot = reading.footPoint,
           let centres = slotCentersY {
            let ys = [centres.0, centres.1, centres.2]
            if ys.indices.contains(slot) {
                // Measured DOWNWARD from the slot: view space grows down the screen, so
                // a foot above the pedal has the smaller y and should read as the high
                // end. Half a band either side, clamped.
                let band = geometry.size.height * Self.treadleBand
                // ZEROED ON THE PLAYER'S OWN FOOT, not on the drawn board.
                //
                // The board is a virtual object planted a fixed angle below the LENS,
                // which puts it about 11 cm UNDER the real floor for a phone propped
                // on that floor — it looks right because there is no depth cue to say
                // otherwise. Measuring the sweep against it put the zero below ground
                // while a real ankle rides ~9 cm above it: eleven centimetres of
                // offset against a two-centimetre band, so the sweep sat pinned at
                // full. Lowering the board by a degree moved that zero again, which is
                // why the sweep broke when the positioning changed.
                //
                // The planted foot IS the floor, reported every frame by the same
                // Vision pass that finds the sweeping one. Zeroing on it makes the
                // sweep independent of where the board is drawn — nudge the placement
                // angle all you like and the pedal still works — and self-calibrating
                // to the player's own stance and distance.
                //
                // Half a band below the floor line, so an ankle AT floor level reads 0
                // (heel down) and one riding a full band above reads 1 (toe down).
                // REVERSED. The mapping was ankle-rises → treble, which is what a real
                // wah does mechanically — press the toe down and the heel, and the
                // ankle with it, comes up. Through a camera looking at the feet it
                // comes out the other way round, and what a player rocks felt
                // backwards to what they heard. The gesture wins over the mechanism:
                // the ankle rising now reads as heel-down and the sweep runs the way
                // the foot expects.
                // MEASURED AGAINST THE FOOT'S OWN TRAVEL, not against the other leg
                // and not against a fixed number of screen points. This replaces both
                // of the things that kept breaking.
                //
                // Against the OTHER LEG: front-on, the pedal foot is further from the
                // lens than the standing foot, so perspective raises it on screen
                // before it has moved at all — and that offset ate most of a 14pt
                // band, which is why the sweep never reached its ends facing the
                // camera and was fine side-on, where "forward" is lateral and costs
                // no height.
                //
                // Against a FIXED BAND: how many points a rock covers depends on how
                // far away the player is, so one band is right at one distance and
                // wrong at every other — "only standing at a certain distance works".
                //
                // Watching the foot's own high and low water marks answers both. Any
                // constant offset cancels because both marks carry it, and the span
                // scales itself with distance and viewing angle because it IS the
                // travel, observed. The marks bleed back toward the current position
                // so a stance change re-ranges instead of leaving the pedal stuck at
                // an extreme forever.
                if slot != sweepSlot { sweepSlot = slot; sweepLow = nil; sweepHigh = nil }
                sweepLow = min(sweepLow ?? foot.y, foot.y)
                sweepHigh = max(sweepHigh ?? foot.y, foot.y)
                if let low = sweepLow, let high = sweepHigh {
                    sweepLow = low + (foot.y - low) * Self.sweepRangeBleed
                    sweepHigh = high + (foot.y - high) * Self.sweepRangeBleed
                }

                // THE ZONE HAS TO BE WIDER THAN THE TRAVEL, not narrower than it.
                //
                // Requiring a full band of observed travel before the range counts
                // was the wrong way round: front-on, a rock produces only a few
                // points of ankle movement, so the span never reached the band and
                // the sweep sat at 0.5 reporting nothing — "it isn't detecting the
                // leg motion". The seed only has to be big enough that sensor noise
                // is not mistaken for a sweep.
                let span = (sweepHigh ?? 0) - (sweepLow ?? 0)
                let raw: Double
                if span >= Self.minSweepSpan {
                    // Ankle at its LOWEST seen is toe-down, matching the reversal.
                    raw = Double((foot.y - (sweepLow ?? 0)) / span)
                } else {
                    // Not enough travel seen yet to trust a range — hold mid-sweep
                    // rather than slamming to an end on the first frame.
                    raw = 0.5
                }
                let clamped = min(1, max(0, raw))

                // Smoothed, because this drives a filter sweep in the audio path and
                // 18 Hz of Vision jitter would be audible as a warble on a held note.
                let smoothed = lastTreadle.map { $0 + (clamped - $0) * Self.treadleSmoothing } ?? clamped
                if abs(smoothed - (lastTreadle ?? -1)) > Self.treadleStep {
                    lastTreadle = smoothed
                    emitTreadle(slot, smoothed)
                    if ARDiagnostics.enabled, now - lastTreadleLog >= Self.gateLogInterval {
                        lastTreadleLog = now
                        ARDiagnostics.log("treadle slot=\(slot) pos=\(ARDiagnostics.f(CGFloat(smoothed), 2)) "
                                        + "footY=\(ARDiagnostics.f(foot.y, 0)) slotY=\(ARDiagnostics.f(ys[slot], 0)) "
                                        + "band=\(ARDiagnostics.f(band, 0))px")
                    }
                } else {
                    lastTreadle = smoothed
                }
            }
        }

        // THE FLOOR, AS SEEN. Smoothed hard: it is a reference the board is placed
        // against, so it should move like a floor rather than like a foot.
        if let ground = reading.groundPoint {
            groundY = groundY.map { $0 + (ground.y - $0) * 0.12 } ?? ground.y
        }

        // THE SWITCH PAD, checked before anything else claims the foot. It is a patch
        // of floor beside the board, so a foot standing on it is not on any pedal and
        // must not be read as sweeping one or stomping one.
        let onPad: Int? = {
            guard let foot = reading.footPoint, let pad = switchPadPoint, let slot = switchPadSlot,
                  geometry.size.width > 0 else { return nil }
            // OPEN-ENDED ON THE OUTSIDE, exactly like the end pedals.
            //
            // A radius around the pad's centre makes it a band you can overshoot: step
            // slightly too far and you are past the switch, standing on nothing. That
            // is the same shape of problem the middle slot had, and the reason the END
            // pedals were reported as perfect — they capture everything beyond
            // themselves, out to the edge of the frame.
            //
            // It bit hardest turning the wah back ON, because that is the approach you
            // make from off the board with nothing underfoot to aim by. Now anything
            // past the pad, away from the row, is the pad.
            // Open-ended AWAY from the board, but stopped at the halfway line to the
            // nearest pedal. Unbounded was swallowing the end pedal whenever the row
            // moved — the board is fitted to the frame, so its slots shift with the
            // placement angle, and a fixed radius that cleared them at one angle
            // covers them at another. A midpoint cannot: it is derived from where the
            // pedals actually are this frame.
            let rowCentreX = slotCentersX?.1 ?? geometry.size.width / 2
            let padIsOutboardLeft = pad.x < rowCentreX
            let nearestSlotX: CGFloat = {
                guard let c = slotCentersX else { return rowCentreX }
                let xs = [c.0, c.1, c.2]
                return padIsOutboardLeft ? (xs.min() ?? rowCentreX) : (xs.max() ?? rowCentreX)
            }()
            let boundary = (pad.x + nearestSlotX) / 2
            let onIt = padIsOutboardLeft ? foot.x <= boundary : foot.x >= boundary
            return onIt ? slot : nil
        }()

        if let slot = onPad {
            // STEPPING ON IT IS THE SWITCH. No stamp, no hold, no fill to wait out.
            //
            // Requiring a stomp on the pad meant the pad inherited every threshold the
            // stomp detector has — velocity, drop, dwell, lateral speed — and a foot
            // stepping sideways onto a target trips almost none of them. That is why
            // it "wasn't really working": the pad was found and the stamp never
            // registered. Nothing else lives out here, so arriving IS the gesture and
            // there is nothing to disambiguate it from.
            //
            // Latched until the foot leaves, so standing on it is one switch and not
            // eighteen a second.
            if armedSlot != slot {
                armedSlot = slot
                emitTreadleArm(slot, 1)
                if now - lastSwitchAt >= Self.switchReleaseDebounce {
                    lastSwitchAt = now
                    emitTreadleSwitch(slot)
                    ARDiagnostics.log("switch pad slot=\(slot) footX=\(ARDiagnostics.f(reading.footPoint?.x ?? 0, 0))")
                }
            }
            // A foot on the pad drives nothing else: no sweep, no stomp anywhere.
            return
        }

        if armedSlot != nil { armedSlot = nil; emitTreadleArm(nil, 0) }

        if let hovered = reading.hoverSlot, treadleSlots.contains(hovered) {
            lastTreadleHoverAt = now
        }
        if let stomp = reading.stomp {
            // A foot working a rocker cannot also be stomping something else — see
            // `treadleStompSuppression`. Without this, sweeping a wah toggled its
            // neighbours.
            if now - lastTreadleHoverAt < Self.treadleStompSuppression {
                ARDiagnostics.log("stomp suppressed (treadle in use) slot=\(stomp.slot)")
            } else {
                emitStomp(stomp.slot, stomp.normalizedX)
            }
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
                unlock(now: CACurrentMediaTime(), reason: .anchorRemoved)
            }
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        interrupted = true
        if case .locked = state { unlock(now: CACurrentMediaTime(), reason: .interrupted) }
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
                publishFloor()
            }
        }
    }

    // MARK: - Readiness

    private func evaluateReadiness(camera: ARCamera, now: TimeInterval, geometry: ViewGeometry) {
        // Hold `.lost` long enough for a player looking at their feet to register it.
        if case .lost = state, now - (lostSince ?? now) < Self.lostDwell { return }

        let trackingNormal: Bool
        if case .normal = camera.trackingState { trackingNormal = true } else { trackingNormal = false }

        // A PROPPED PHONE NEVER REACHES `.normal`, AND WAITING FOR IT IS A DEADLOCK.
        //
        // World tracking initialises from PARALLAX: ARKit needs the device to move to
        // triangulate anything. A phone standing still on the floor gives it none, so
        // it sits in `.limited(.initializing)` indefinitely — and this page's whole
        // premise is a phone that has been set down and left alone. The player was
        // told "getting its bearings — hold the phone steady", which is both the
        // wrong advice and unfollowable: holding it steadier is exactly what keeps it
        // from initialising.
        //
        // Front mode does not need world tracking to be good. It detects no planes,
        // assumes the floor is under the phone, fits the row to the FRAME, and freezes
        // the pose at lock. `.limited` is plenty for that. Only `.notAvailable` — no
        // pose at all — is genuinely unusable.
        let trackingUsable: Bool
        if case .notAvailable = camera.trackingState { trackingUsable = false } else { trackingUsable = true }

        // FRONT MODE HAS NO PLANES TO GATE ON, so it gates on the only two things it
        // can know: that ARKit is tracking properly, and that the phone is aimed
        // somewhere a floor could be. Everything below this branch — plane extents,
        // height above the lens, whether a plane is in shot — is asking questions
        // about detected geometry that does not exist here.
        //
        // Note what `.ready` MEANS in this mode, because it is not what it means
        // below: not "there is a floor here" but "the view has settled and the aim is
        // plausible". That is a weaker promise, and it is the honest one — which is
        // exactly why front mode goes on to PLACE on it rather than inviting a tap.
        if !cameraFacing.detectsPlanes {
            // WOULD THE BOARD ACTUALLY BE ON SCREEN? Front mode has no plane to gate
            // on, so this is the only thing standing between it and planting a board
            // behind the player — which it did: a real session turned the phone and
            // placed a row that projected to x = −1185 on an 844-wide viewport, with
            // its three slots 4 points apart. Off screen AND collapsed to a point,
            // which is what "sideways and flashing" actually was.
            //
            // Rear mode has always had this check (`inView` on the candidate plane);
            // front mode was allowed to skip it because there was no candidate to
            // check. There is one — the pose it is ABOUT to derive — so it checks that.
            let prospective = ARAssumedFloor.anchorTransform(camera: camera)
            let onScreen = prospective.map {
                inView($0.columns.3.xyz, camera: camera, geometry: geometry,
                       margin: state == .ready ? 0.25 : 0)
            } ?? false
            let aimOK = ARAssumedFloor.isUsableAim(camera: camera) && onScreen
            if ARDiagnostics.enabled, now - lastGateLog >= Self.gateLogInterval {
                lastGateLog = now
                let held = readySince.map { now - $0 } ?? 0
                ARDiagnostics.log("""
                    gate[front] track=\(camera.trackingState.diagName) aim=\(aimOK) \
                    onScreen=\(onScreen) \
                    held=\(ARDiagnostics.f(CGFloat(held)))s/\(Self.readyDebounce)s \
                    camY=\(ARDiagnostics.f(camera.transform.columns.3.y))
                    """)
            }
            // AIM AT THE FEET, ONCE, BEFORE COMMITTING.
            //
            // Placement was a constant angle below the lens, and a constant cannot
            // know how far away the player is standing — so it landed on their LEGS,
            // landed in the same wrong place after every reposition, and landed there
            // just the same with nobody in shot. All three are the same fact: it was
            // never looking.
            //
            // The page already knows where the floor is. Vision reports both ankles
            // every frame it sees a body, and the LOWER of the two is a foot standing
            // on the ground — which is the "account for two legs" part: the working
            // foot is usually the one in the air, so the standing one is the honest
            // reference. Solve for the angle that puts the board on that line.
            //
            // ONCE, latched, not a control loop. An earlier version steered this
            // every frame and the board re-placed itself constantly — it disappeared
            // and came back on every step. Solved at placement and then left alone,
            // it settles where the feet were and stays there.
            if !aimedAtFeet, let groundY, trackingUsable {
                aimedAtFeet = aimPlacementAtFeet(camera: camera, geometry: geometry, groundY: groundY)
            }

            if aimOK && trackingUsable {
                notReadySince = nil
                if readySince == nil { readySince = now }
                if now - (readySince ?? now) >= Self.readyDebounce {
                    set(.ready)
                } else if state != .ready {
                    set(.searching(.holdStill))
                }
            } else {
                readySince = nil
                if notReadySince == nil { notReadySince = now }
                if state == .ready, now - (notReadySince ?? now) < Self.dropDebounce { return }
                // `aimLower` no longer means "tilt the phone down" — recline is
                // accepted at any angle now (see `ARAssumedFloor.anchorTransform`),
                // so the only aims left here are straight up and straight down, and
                // "aim lower" is still the right thing to say to the first of them.
                set(.searching(trackingUsable ? .aimLower
                                              : hint(for: camera.trackingState, sawSurface: false)))
            }
            return
        }

        let cameraY = camera.transform.columns.3.y
        // Leaving is more forgiving than entering: while already green a plane may
        // slide a little outside the viewport without the promise becoming false.
        let alreadyReady = (state == .ready)
        let margin: CGFloat = alreadyReady ? 0.25 : 0

        var usable = false
        var sawSurface = false
        // Diagnostics only — see ARDiagnostics.swift. Tallied INSIDE the decision loop
        // rather than in a second pass so the numbers describe the same frame the
        // decision was actually made from; a re-walk would be a different instant and
        // would occasionally explain a rejection that never happened.
        var tooSmall = 0, tooHigh = 0, outOfView = 0
        var biggest: (w: Float, h: Float, dy: Float)?
        for plane in planes.values {
            if ARDiagnostics.enabled {
                let dy = plane.worldCenter.y - cameraY
                if biggest == nil || min(plane.width, plane.height) > min(biggest!.w, biggest!.h) {
                    biggest = (plane.width, plane.height, dy)
                }
            }
            guard plane.width >= Self.minPlaneExtent, plane.height >= Self.minPlaneExtent else {
                tooSmall += 1
                continue
            }
            sawSurface = true
            // Below the lens, or it is a desk / chair / shelf the player cannot stomp.
            guard plane.worldCenter.y < cameraY - Self.minCameraLift else {
                tooHigh += 1
                continue
            }
            // ANY PART OF IT, NOT ITS CENTRE. Testing only the centre is what stopped
            // this working at an upward angle: tip the phone up and a floor you are
            // still plainly standing on has its centre slide out of frame, so a plane
            // that fills the bottom third of the picture counted as "not in view".
            // The near edge is the part a player can actually reach anyway.
            guard planeInView(plane, camera: camera, geometry: geometry, margin: margin) else {
                outOfView += 1
                continue
            }
            usable = true
            break
        }

        if ARDiagnostics.enabled, now - lastGateLog >= Self.gateLogInterval {
            lastGateLog = now
            let held = readySince.map { now - $0 } ?? 0
            let best = biggest.map { "\(ARDiagnostics.f($0.w))x\(ARDiagnostics.f($0.h))m dy=\(ARDiagnostics.f($0.dy))" }
                ?? "none"
            ARDiagnostics.log("""
                gate track=\(camera.trackingState.diagName) planes=\(planes.count) \
                best=\(best) reject[small=\(tooSmall) high=\(tooHigh) offscreen=\(outOfView)] \
                usable=\(usable) held=\(ARDiagnostics.f(CGFloat(held)))s/\(Self.readyDebounce)s \
                camY=\(ARDiagnostics.f(cameraY))
                """)
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

    /// Publish the pad, throttled the same way the slot points are: it moves with
    /// them, so it would otherwise re-lay-out SwiftUI at frame rate.
    private var lastPadPublish: TimeInterval = 0
    private var lastPadPoint: CGPoint?
    private func publishSwitchPad(slot: Int?, point: CGPoint?) {
        if let point, let last = lastPadPoint,
           abs(point.x - last.x) < Self.slotPublishDeadband,
           abs(point.y - last.y) < Self.slotPublishDeadband, slot != nil {
            return
        }
        lastPadPoint = point
        emitSwitchPad(slot, point)
    }

    // THE FEET STEER IS GONE. It nudged the placement angle every frame toward the
    // observed floor line, which re-derived the anchor, which meant the board moved
    // — and in front mode a moving anchor reads as the board vanishing and coming
    // back. "Every time I move my feet the render disappears" was exactly that. The
    // page places against the FRAME instead; `groundPoint` is still reported by the
    // tracker and is the honest input if this is ever tried again, but not by
    // steering a live anchor.

    /// Pick the placement angle whose board lands on the observed floor line.
    ///
    /// A short search rather than an inversion: the projection runs through ARKit's
    /// own camera model and a clamp that depends on the recline, so there is no clean
    /// formula to invert — and this runs once, so a few dozen projections cost
    /// nothing. Returns false when nothing usable was found, leaving the constant in
    /// place and the aim unlatched to try again on a later frame.
    private func aimPlacementAtFeet(camera: ARCamera, geometry: ViewGeometry, groundY: CGFloat) -> Bool {
        var best: (pitch: Float, error: CGFloat)?
        var degrees = ARFloorCalibration.minPitch * 180 / .pi
        let maxDegrees = ARFloorCalibration.maxPitch * 180 / .pi
        while degrees <= maxDegrees {
            let pitch = degrees * .pi / 180
            if let candidate = ARAssumedFloor.anchorTransform(camera: camera, requestedPitch: pitch) {
                let point = camera.projectPoint(candidate.columns.3.xyz,
                                                orientation: geometry.orientation,
                                                viewportSize: geometry.size)
                if point.y.isFinite {
                    let error = abs(point.y - groundY)
                    if best == nil || error < best!.error { best = (pitch, error) }
                }
            }
            degrees += 0.5
        }
        guard let best else { return false }
        ARFloorCalibration.set(best.pitch)
        ARDiagnostics.log("aimed at feet: pitch=\(ARDiagnostics.f(best.pitch * 180 / .pi, 1))° "
                        + "groundY=\(ARDiagnostics.f(groundY, 0)) miss=\(ARDiagnostics.f(best.error, 0))pt")
        return true
    }

    /// Tell the coordinator which slots hold rocker pedals.
    ///
    /// Pushed in rather than looked up because the answer lives in `RigStore` on the
    /// main actor and this is needed on the session queue, 18 times a second. Hopping
    /// to main for it on every frame would be exactly the stutter the delegate queue
    /// exists to avoid.
    func setTreadleSlots(_ slots: Set<Int>, on queue: DispatchQueue) {
        queue.async { [weak self] in self?.treadleSlots = slots }
    }

    /// How high the ankle rides above the floor when a foot is resting on a pedal.
    ///
    /// The treadle's zero, not a cosmetic offset: Vision reports ankles, pedals sit on
    /// the floor, and the gap between the two is what the sweep is measured from.
    private static let ankleRest: Float = 0.09                      // metres

    /// A slot offset lifted to ankle height, in the anchor's own space. The anchor's
    /// +Y is world up by construction, so this is a straight lift.
    private func raised(_ offset: simd_float4) -> simd_float4 {
        simd_float4(offset.x, offset.y + Self.ankleRest, offset.z, offset.w)
    }

    /// Whether any part of a plane is on screen — its centre or any of its corners.
    ///
    /// The corners are derived from the extent about the centre, ignoring the plane's
    /// own rotation about Y. Deliberately: this is a "can the player see some of this
    /// floor" test, not a geometry query, and a rotated rectangle's corners never
    /// leave the circle those axis-aligned ones describe by enough to matter to it.
    private func planeInView(_ plane: PlaneSnapshot,
                             camera: ARCamera,
                             geometry: ViewGeometry,
                             margin: CGFloat) -> Bool {
        if inView(plane.worldCenter, camera: camera, geometry: geometry, margin: margin) {
            return true
        }
        let hw = plane.width / 2, hh = plane.height / 2
        for dx in [-hw, hw] {
            for dz in [-hh, hh] {
                let corner = plane.worldCenter + simd_float3(dx, 0, dz)
                if inView(corner, camera: camera, geometry: geometry, margin: margin) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Holding, and losing, the lock

    private func evaluateLock(camera: ARCamera, now: TimeInterval, geometry: ViewGeometry) {
        guard !interrupted else { return unlock(now: now, reason: .interrupted) }
        guard let anchorTransform, let slotOffsets, slotOffsets.count == 3 else {
            return unlock(now: now, reason: .anchorMissing)
        }

        // HOLDING THE LOCK ACCEPTS WHAT PLACING IT ACCEPTED.
        //
        // Readiness was relaxed to `.limited` because a propped, motionless phone
        // never reaches `.normal` — world tracking initialises from parallax and a
        // phone sitting still supplies none. This gate was left demanding `.normal`,
        // so the board placed and then dropped one `trackingGrace` later, every
        // time: "lost the board at the slightest movement". The two gates have to
        // agree, and `.limited` is the one that matches how this page is used.
        let holdable: Bool
        if case .notAvailable = camera.trackingState { holdable = false } else { holdable = true }
        if holdable {
            degradedSince = nil
        } else {
            if degradedSince == nil { degradedSince = now }
            guard now - (degradedSince ?? now) <= Self.trackingGrace else {
                return unlock(now: now, reason: .trackingLost,
                              detail: camera.trackingState.diagName)
            }
        }

        // FRONT MODE FOLLOWS THE PHONE INSTEAD OF BEING BROKEN BY IT.
        //
        // There is no real anchor here — the "floor" is an assumption re-derivable
        // from any camera pose (see `ARAssumedFloor`), so pinning it bought nothing
        // and cost everything: nudge the phone and the board either drifted off the
        // spot it was standing on or tripped the drift check and vanished. Re-deriving
        // it each frame means adjusting the phone SWINGS THE BOARD AROUND to stay in
        // front, which is what a propped-phone setup actually needs.
        //
        // The slot offsets are deliberately NOT recomputed. They live in the anchor's
        // own space, and the assumed anchor is built with its +X already along the row
        // and its +Z already pointing back at the camera — so when the heading turns,
        // the anchor's axes turn with it and the same three offsets stay correct. That
        // also keeps `facing` pinned at 0 by construction, which is why the board keeps
        // facing the player without re-running a layout pass 60 times a second.
        //
        // Everything below — the floor-behind check, the projection, the stomp
        // centres — still runs. What is skipped is only the drift unlock, which in
        // this mode would be firing on the one gesture the mode is designed around.
        // FRONT MODE FREEZES ONCE IT IS DOWN.
        //
        // An earlier version re-derived the pose from the camera on every frame so the
        // board followed the phone around. That is the right behaviour for a phone
        // being AIMED and the wrong one for a phone that has been SET DOWN — which is
        // the whole of how this page is used. The player props it, waits for the board,
        // and then walks away; from that moment the board belongs to the room, not to
        // the lens. Following meant it never settled, and a board that re-places itself
        // every few seconds is the flashing the player actually sees.
        //
        // So nothing is recomputed here. The anchor stays exactly where it was planted
        // and `evaluateLockTail` simply re-projects it, which is ordinary AR behaviour:
        // nudge the phone and the board holds its spot on the floor.
        //
        // The drift unlock stays skipped for the same reason it always was — a propped
        // phone that gets bumped should keep its board, not lose it.
        if !cameraFacing.detectsPlanes {
            // …EXCEPT while the player is actively adjusting where it sits.
            //
            // Freezing turned the calibration drag into a dead control: the angle
            // changed, the board did not, and the only visible result was the board
            // vanishing — because touching a propped phone moves it, and a FROZEN
            // anchor does not move with it, so it ended up behind the lens and tripped
            // the unlock 0.1 s after the drag landed.
            //
            // Re-deriving on a changed angle and ONLY on a changed angle keeps both
            // halves: the board follows the drag while a hand is on the phone, and the
            // instant the hand comes off it is frozen again, wherever it was left.
            // RE-DERIVED FROM THE CAMERA, EVERY FRAME — which reverses the freeze
            // above it, and the reasoning is worth keeping because both are right for
            // different phones.
            //
            // Freezing the anchor is correct when the pose it is frozen against is
            // TRUE. Front mode's is not: it runs on `.limited` tracking because a
            // motionless phone gives ARKit no parallax, and a limited pose drifts. A
            // world-anchored board seen through a drifting camera slides across the
            // picture and eventually off it — reported exactly, as the board sliding
            // away while the text stayed put. The text stayed because its projection
            // had been frozen; the SceneKit board had not, and could not be, because
            // it is rendered through that same drifting camera.
            //
            // Pinning the board to the CAMERA instead makes the drift cancel: the
            // pose error moves the camera and the board together, so the board holds
            // still in the frame — which is where the player is looking, and the only
            // place it has to hold still. The cost is that a bumped phone takes its
            // board with it rather than leaving it on the floor. For a phone propped
            // and left alone that is the better half of the trade, and it is the same
            // one already made for the chrome.
            let pitch = ARFloorCalibration.placementPitch
            placedPitch = pitch
            if let refreshed = ARAssumedFloor.anchorTransform(camera: camera) {
                self.anchorTransform = refreshed
                publishFloorIfMoved(refreshed, now: now)
            }
            return evaluateLockTail(camera: camera, now: now, geometry: geometry)
        }

        // Did the phone move? Asked in the ANCHOR's frame — see `lockPose`.
        if let lockPose {
            let cameraInAnchor = simd_mul(simd_inverse(anchorTransform), camera.transform)
            let moved = simd_distance(cameraInAnchor.columns.3.xyz, lockPose.columns.3.xyz)
            let turned = abs(simd_mul(lockPose.rotation.inverse, cameraInAnchor.rotation).angle)
            guard moved <= Self.maxLockDrift, turned <= Self.maxLockRotation else {
                return unlock(now: now, reason: .phoneMoved,
                              detail: "moved=\(ARDiagnostics.f(moved))m/\(Self.maxLockDrift) "
                                    + "turned=\(ARDiagnostics.f(turned * 180 / .pi, 1))°/15")
            }
        }

        evaluateLockTail(camera: camera, now: now, geometry: geometry)
    }

    /// The half of `evaluateLock` that both modes share: sanity-check where the row
    /// has ended up, project it, and hand the results on. Split out so the front path
    /// can skip the drift unlock above it without also skipping any of this.
    private func evaluateLockTail(camera: ARCamera, now: TimeInterval, geometry: ViewGeometry) {
        guard let anchorTransform, let slotOffsets, slotOffsets.count == 3 else {
            return unlock(now: now, reason: .anchorMissing)
        }

        let worldCentre = simd_mul(anchorTransform, slotOffsets[1]).xyz
        let local = simd_mul(simd_inverse(camera.transform), simd_float4(worldCentre, 1))
        // The floor has gone behind the lens — the phone is face-down or tipped over.
        guard local.z < -0.05 else { return unlock(now: now, reason: .floorBehind) }

        let p0 = project(slotOffsets[0], anchor: anchorTransform, camera: camera, geometry: geometry)
        let p1 = project(slotOffsets[1], anchor: anchorTransform, camera: camera, geometry: geometry)
        let p2 = project(slotOffsets[2], anchor: anchorTransform, camera: camera, geometry: geometry)
        guard p0.x.isFinite, p1.x.isFinite, p2.x.isFinite else {
            return unlock(now: now, reason: .badProjection)
        }

        // Binning reads this on the frame path; publishing to SwiftUI is throttled.
        slotCentersX = (p0.x, p1.x, p2.x)
        // The vertical half, for the treadle — and NOT the same three points as the
        // x's, which is the one place they must differ.
        //
        // The x's bin "which pedal is the foot over", and the pedal is on the floor.
        // The treadle measures "how high is the foot riding", and the joint Vision
        // reports is the ANKLE, which sits about `ankleRest` above the floor when a
        // foot is resting on a pedal. Measuring the ankle against the FLOOR point puts
        // the whole sweep permanently above its own band: it pins at 1.0 and the
        // player reports, correctly, that the sweep is gone.
        //
        // This went unnoticed while the board was floating in mid-air, because a board
        // planted a fixed angle below the lens axis happened to sit near ankle height
        // — the two errors cancelled. Putting the board on the ground uncovered it.
        //
        // Projected rather than offset in points, so it stays right as the board moves
        // nearer or further and the perspective changes with it.
        let a0 = project(raised(slotOffsets[0]), anchor: anchorTransform, camera: camera, geometry: geometry)
        let a1 = project(raised(slotOffsets[1]), anchor: anchorTransform, camera: camera, geometry: geometry)
        let a2 = project(raised(slotOffsets[2]), anchor: anchorTransform, camera: camera, geometry: geometry)
        slotCentersY = (a0.y.isFinite ? a0.y : p0.y,
                        a1.y.isFinite ? a1.y : p1.y,
                        a2.y.isFinite ? a2.y : p2.y)

        // THE SWITCH PAD, projected alongside the slots so it moves with the board.
        // It sits past the END of the row on the rocker's own side — which is empty
        // floor, and the whole point: a foot there is unambiguously not on a pedal.
        if let slot = treadleSlots.sorted().first {
            // THE RESERVED SIDE. The row is fitted to `rowSpanFraction` of the frame
            // and slid to `rowCentreFraction`, which leaves the far side empty by
            // construction — this puts the pad in the middle of that space. Derived
            // from the row's own width rather than a fixed distance in metres, so it
            // stays in the same part of the PICTURE however the board was fitted.
            //
            // Always the same side, never mirrored to follow the rocker: a control
            // you hit mid-song wants to be in one place every time.
            let centre = slotOffsets[1]
            let spacing = (slotOffsets[2].x - slotOffsets[0].x) / 2
            let metresPerFraction = (2 * spacing) / Float(Self.rowSpanFraction)
            let padX = centre.x + Float(Self.padCentreFraction - Self.rowCentreFraction) * metresPerFraction
            let padOffset = simd_float4(padX, centre.y, centre.z, centre.w)
            let projected = project(padOffset, anchor: anchorTransform, camera: camera, geometry: geometry)
            if projected.x.isFinite, projected.y.isFinite {
                switchPadSlot = slot
                switchPadPoint = projected
                publishSwitchPad(slot: slot, point: projected)
            } else {
                switchPadSlot = nil; switchPadPoint = nil; publishSwitchPad(slot: nil, point: nil)
            }
        } else if switchPadSlot != nil {
            switchPadSlot = nil; switchPadPoint = nil; publishSwitchPad(slot: nil, point: nil)
        }

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

    /// Why a lock was dropped. Recorded rather than inferred: "the layout unlocked" with
    /// no cause is the same species of silent failure this file exists to prevent, seen
    /// from the other side — and the three thresholds that can trigger it
    /// (`trackingGrace`, `maxLockDrift`, `maxLockRotation`) cannot be tuned without
    /// knowing which of them actually fired.
    enum UnlockReason: String {
        case anchorRemoved = "anchor removed by ARKit"
        case interrupted   = "session interrupted"
        case anchorMissing = "anchor or offsets missing"
        case trackingLost  = "tracking degraded past grace"
        case phoneMoved    = "phone moved"
        case floorBehind   = "floor went behind the lens"
        case badProjection = "slot projection not finite"
    }

    private func unlock(now: TimeInterval, reason: UnlockReason, detail: String = "") {
        ARDiagnostics.log("UNLOCK — \(reason.rawValue)\(detail.isEmpty ? "" : " (\(detail))")")
        aimedAtFeet = false
        emitUnlockReason(reason.rawValue)
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
        ARDiagnostics.log("state \(state.diagName) -> \(new.diagName)")
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
        let origin = anchorTransform.columns.3.xyz

        // THE ROW RUNS ACROSS THE PLAYER'S LINE OF SIGHT, AND THIS REVERSES HOW IT
        // USED TO BE DERIVED. It was the camera's SCREEN-RIGHT, rotated by the
        // preview angle — which is a different axis from "across the player" the
        // moment the tap lands anywhere but the middle of the frame. The row and the
        // board then sat at an angle to each other, and the fix for that was pedals
        // individually swivelled to face the phone: a board with its pedals mounted
        // crooked on it.
        //
        // Taking the row from the player's own direction instead makes the two the
        // same axis BY CONSTRUCTION. The board's rails end up square across the line
        // of sight, the pedals sit square on the rails, and `ARDeckFrame` — which
        // reads its heading off this row — turns the whole board to face the player
        // rather than turning three pedals to face them individually.
        var toPlayer = camera.transform.columns.3.xyz - origin
        toPlayer.y = 0                                   // keep the row flat on the floor

        if simd_length(toPlayer) < 1e-4 {
            // The camera is directly above the spot it just placed — there is no
            // horizontal direction to the player at all. Fall back to where the phone
            // is LOOKING, which is defined for every pose but one.
            var forward = -camera.transform.columns.2.xyz
            forward.y = 0
            if simd_length(forward) < 1e-4 { forward = simd_float3(0, 0, -1) }
            toPlayer = forward
        }
        // Horizontal, perpendicular to the player's direction: the axis the three
        // slots — and the board's rails — lie along.
        var lateral = simd_normalize(simd_cross(simd_float3(0, 1, 0), simd_normalize(toPlayer)))
        // The safety net, and the reason this is worth six extra lines: ask the
        // projector where these two would actually DRAW. The screen is what the
        // player aims at, so if the world layout and the screen disagree about which
        // end is left, the screen wins.
        let left = camera.projectPoint(origin - lateral * Self.slotSpacing,
                                       orientation: geometry.orientation, viewportSize: geometry.size)
        let right = camera.projectPoint(origin + lateral * Self.slotSpacing,
                                        orientation: geometry.orientation, viewportSize: geometry.size)
        let flipped = right.x < left.x
        if flipped { lateral = -lateral }
        // The mirror check, made visible. If this ever reports `flip=true` in
        // `.landscapeRight` (or false in `.landscapeLeft`), the rotation feeding
        // `lateral` disagrees with what the projector draws — which is precisely the
        // "every stomp toggles the wrong end of the board" bug, caught on the ground
        // instead of on stage.
        ARDiagnostics.log("layout orientation=\(geometry.orientation.rawValue) "
                        + "toPlayer=(\(ARDiagnostics.f(toPlayer.x)), \(ARDiagnostics.f(toPlayer.z))) "
                        + "leftX=\(ARDiagnostics.f(left.x, 0)) rightX=\(ARDiagnostics.f(right.x, 0)) "
                        + "flip=\(flipped) viewport=\(ARDiagnostics.f(geometry.size.width, 0))x"
                        + "\(ARDiagnostics.f(geometry.size.height, 0))")

        let inverse = simd_inverse(anchorTransform)
        // THE LIFT, APPLIED ONCE. Everything that cares where a slot is — the pedal
        // node, the label's projected point, the stomp binner's `slotCentersX` —
        // reads these three values or a projection of them, so raising them here is
        // the whole of "the chrome follows the pedals onto the board". Adding it in
        // the anchor's own frame, after the inverse, keeps it exactly reversible:
        // the anchor's +y IS its plane normal, so subtracting `deckLift` gets the
        // floor point back with no rotation involved. Zero when the board is off.
        // FIT THE ROW TO THE FRAME. `left`/`right` above already projected a known
        // lateral offset, so they measure how many points one metre of sideways is
        // worth at this board's distance — everything needed to solve the spacing
        // backwards from the screen span we want.
        var spacing = Self.slotSpacing
        var shift: Float = 0
        let pointsPerMetre = Float(abs(right.x - left.x)) / (2 * Self.slotSpacing)
        if pointsPerMetre > 1 {
            let targetSpan = Float(geometry.size.width * Self.rowSpanFraction)
            spacing = min(Self.maxSlotSpacing,
                          max(Self.minSlotSpacing, targetSpan / (2 * pointsPerMetre)))
            // …and slide the whole row off centre, so the empty side stays empty.
            let centreOffsetPoints = Float(geometry.size.width * (Self.rowCentreFraction - 0.5))
            shift = centreOffsetPoints / pointsPerMetre
        }
        ARDiagnostics.log("row fit spacing=\(ARDiagnostics.f(spacing))m shift=\(ARDiagnostics.f(shift))m "
                        + "ptsPerM=\(ARDiagnostics.f(pointsPerMetre, 0))")

        let lift = ARFloorPedalboard.mountLift
        return [-spacing + shift, shift, spacing + shift].map { distance in
            var offset = simd_mul(inverse, simd_float4(origin + lateral * distance, 1))
            offset.y += lift
            return offset
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
