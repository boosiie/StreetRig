//
//  ARCameraFacing.swift
//  StreetRig
//
//  Which camera the AR pedal page is looking through, and — for the front one —
//  where the floor is when ARKit will not tell you.
//
//  WHY THE FRONT CAMERA IS THE DEFAULT, AND WHY THAT CHANGED EVERYTHING. This page
//  is used with the phone propped on the floor and the player standing over it. With
//  the REAR camera that setup is self-defeating in two ways at once: the screen faces
//  away from the player, so the one thing the page exists to show — which pedal is
//  which — is pointed at a wall; and placement was a TAP, which means walking back to
//  the phone, crouching, and touching the thing whose stillness the whole lock
//  depends on. The measured version of that: a real session locked and then unlocked
//  2.6 seconds later on `turned=15.2°`, which is what bending down to a propped phone
//  does to it.
//
//  Turning the phone around fixes both sight lines with one move. The screen faces
//  the player, so they can read it from standing; the lens faces the player, so it
//  sees the feet it is supposed to be watching.
//
//  WHAT IT COSTS, STATED PLAINLY. `planeDetection` exists only on the rear-camera
//  configurations — `ARWorldTracking`, `ARObjectScanning`, `ARBodyTracking`,
//  `ARPositionalTracking`, `ARGeoTracking`. `ARFaceTrackingConfiguration`, the only
//  front-camera one, has no such property and never will. So in front mode there is
//  no detected plane, no raycast against one, and nothing to turn green about. The
//  floor has to be ASSUMED, and `ARAssumedFloor` below is that assumption, made in
//  one place and labelled as one rather than smuggled in as a measurement.
//
//  AND BECAUSE THERE IS NOTHING TO TAP, NOTHING IS TAPPED. Front mode auto-places:
//  the same settling the outline used to wait for now places the board itself. The
//  gesture becomes the phone. Set it down and the board appears; pick it up and
//  tracking degrades and it clears; set it down again and it comes back. The player
//  never touches the screen, which is the only version of this that works from a
//  metre away — and it retires the bumped-phone unlock by removing the bump.
//
//  THE REAR PATH IS UNTOUCHED. Flipping back gets exactly what this page did before:
//  real planes, the green readiness outline, tap-to-place, a world anchor. Both are
//  real modes, and the difference between "measured" and "assumed" is the whole of
//  what separates them.
//

import ARKit
import Synchronization
import simd

// MARK: - The one number this mode guesses, remembered between sessions

/// How high the lens is above the floor, as the player last corrected it.
///
/// WHY THIS IS THE THING WORTH REMEMBERING. Front mode cannot save "where the board
/// was": there is no anchor under it — the pose is re-derived from the camera every
/// frame, so the board is never anywhere in the world to come back to. ARKit's actual
/// memory for that, `ARWorldMap`, is declared only on the rear-camera configurations
/// (`ARWorldTracking`, `ARBodyTracking`, `ARPositionalTracking`); the face-tracking
/// configuration has no `initialWorldMap` and cannot relocalize into one.
///
/// But there IS a thing the player sets up once and would hate to set up again, and
/// it is the height of whatever they propped the phone on. That was a hardcoded 0.25,
/// which is right for nobody in particular: a phone on its case is 5 cm up, one on a
/// chair is 60. Getting it wrong is the difference between a board standing on the
/// floor and one sunk into it. So the guess becomes a correction, and the correction
/// is what persists — the same setup gets the same board next time it is opened.
///
/// THREADING. Read on the ARSession's delegate queue at up to 60 Hz and written from
/// the main thread by a drag, so the live value lives in an atomic exactly like the
/// view geometry does — a `UserDefaults` read per frame would be a disk-backed lookup
/// on the frame path. `UserDefaults` is the durable copy, not the hot one.
nonisolated enum ARFloorCalibration {

    /// How far below the HORIZON the board sits, seen from the lens — equivalently,
    /// with the floor a known height below the phone, how far away it is.
    ///
    /// This quantity has now been wrong twice in opposite directions. First it was a
    /// guessed camera height (0.25 m) with the board landing where that plane met the
    /// aim, which buried it under the bottom edge. Then it was an angle below the
    /// LENS AXIS, which kept it in frame at any recline — and floated it above the
    /// carpet, because a fixed angle below a tipped-back axis is above the horizon.
    ///
    /// Measuring from the horizon gets both: the board is on the ground because the
    /// ground is where the horizon-relative geometry puts it, and the angle still
    /// says where in the frame it lands for any given recline.
    /// 6° puts the board about 0.76 m in front on a floor 8 cm below the lens, which
    /// is where the old fixed 0.78 m distance had it — so the default apparent size
    /// is unchanged, only its height is (it is now on the ground rather than above it).
    /// 14°. 13° read as floating just off the floor, 15° overshot — this is the half
    /// step between them, about 1.3 cm below where it started at the board's distance.
    static let defaultPitch: Float = 14 * .pi / 180
    /// Far end of the room at one extreme, right under the phone at the other. Past
    /// 15° the distance clamp takes over and further dragging does nothing.
    static let minPitch: Float = 4 * .pi / 180
    static let maxPitch: Float = 30 * .pi / 180

    /// KEY BUMPED WITH THE MEANING. Saved values from the previous build are angles
    /// below the LENS AXIS; this one measures from the HORIZON, and a remembered 13°
    /// would silently become "0.35 m away" for someone who had calibrated a board they
    /// liked. Cheaper to let them re-drag once than to restore a number that no longer
    /// means what they set.
    private static let key = "streetrig.ar.placementPitch.axis3"
    private static let live = Atomic<UInt32>(defaultPitch.bitPattern)

    /// The value the frame path reads. One atomic load, no allocation.
    static var placementPitch: Float { Float(bitPattern: live.load(ordering: .relaxed)) }

    /// Degrees, for anything showing it to a person.
    static var placementDegrees: Float { placementPitch * 180 / .pi }

    /// Pull the saved correction into the atomic. Called once when the session starts.
    static func restore() {
        let saved = UserDefaults.standard.object(forKey: key) as? Double
        let value = clamp(saved.map(Float.init) ?? defaultPitch)
        live.store(value.bitPattern, ordering: .relaxed)
        ARDiagnostics.log("calib restore pitch=\(ARDiagnostics.f(value * 180 / .pi, 1))° "
                        + "(\(saved == nil ? "default" : "remembered"))")
    }

    /// Correct it, and remember the correction.
    ///
    /// Written straight through to `UserDefaults` rather than batched on some later
    /// event: the way this page ends is the player walking away from a propped phone,
    /// and there is no "done" moment to flush on.
    static func set(_ pitch: Float) {
        let value = clamp(pitch)
        live.store(value.bitPattern, ordering: .relaxed)
        UserDefaults.standard.set(Double(value), forKey: key)
    }

    /// Nudge by a delta in radians, for a drag. Returns the value actually taken after
    /// clamping, so a gesture that has run out of range stops rather than accumulating
    /// into a number the next drag has to unwind.
    @discardableResult
    static func adjust(by delta: Float) -> Float {
        let value = clamp(placementPitch + delta)
        set(value)
        return value
    }

    static func clamp(_ value: Float) -> Float { min(max(value, minPitch), maxPitch) }
}

/// Which way the AR page is looking.
///
/// Not a cosmetic switch: the two cases have different capabilities, a different
/// placement gesture, and a different idea of where the floor is. Everything that
/// branches on it is downstream of the one fact that front-camera ARKit cannot
/// detect planes.
nonisolated enum ARCameraFacing: String, Sendable, CaseIterable {
    /// `ARFaceTrackingConfiguration` with world tracking. Screen and lens both face
    /// the player. No planes; the floor is assumed and the board places itself.
    case front
    /// `ARWorldTrackingConfiguration`. Real horizontal planes, green readiness
    /// outline, tap to place, world-anchored board — the original page.
    case rear

    /// The default, and the reason this type exists — see the header.
    static let `default`: ARCameraFacing = .front

    /// Whether ARKit will hand this mode real planes to stand a board on.
    var detectsPlanes: Bool { self == .rear }

    /// Whether the board places itself once the view settles, rather than waiting to
    /// be tapped. The inverse of `detectsPlanes` today, but they are different
    /// questions and conflating them is how a mode ends up with neither.
    var placesAutomatically: Bool { self == .front }

    var diagName: String { rawValue }
}

// MARK: - Where the floor is when nothing detected one

/// The front camera's stand-in for a detected plane.
///
/// TWO EARLIER VERSIONS GOT THIS WRONG IN OPPOSITE DIRECTIONS, and both are worth
/// keeping written down because the fix came from the failure.
///
/// The FIRST planted the board along the camera's aim and called the level plane
/// through that point the floor — which only means anything if the camera is tilted
/// down, so it refused any aim within a few degrees of level. A propped phone looks
/// roughly level across the floor, so it rejected the only pose this mode exists for:
/// a real session logged `aim=false` on every frame for ten seconds.
///
/// The SECOND put the floor a guessed 0.25 m below the lens and let the board land
/// where the aim met it. That accepted every pose — and buried the board under the
/// bottom edge of the picture, because on a near-level phone that geometry works out
/// to ~19° down. The only way to see it was to tilt the phone, which is the one thing
/// a propped phone cannot be asked to do.
///
/// WHAT BOTH SHARED was deriving the board's position from a guess about the WORLD
/// (how high the phone is) and hoping the picture came out. This one inverts that: the
/// board is planted a fixed angle below the LENS'S OWN AXIS, so its place in the frame
/// is the input rather than the output. It cannot fall out of shot, no pose is
/// rejected except one aimed above the placement angle, and nothing has to know how
/// high the phone was propped.
///
/// AND ONCE IT IS DOWN, IT STAYS DOWN. The pose is derived while the page is still
/// looking for a spot and then FROZEN at lock. An earlier version re-derived it every
/// frame so the board followed the phone; that is right for a phone being aimed and
/// wrong for one that has been set down, which is the whole of how this page is used.
/// The player props it, it settles, and from then on the board belongs to the room.
///
/// WHAT IS STILL ASSUMED: `distance`, which sets apparent size. Nothing else — and no
/// assumption at all about the real floor's height, which is unknowable from one
/// camera with no depth and no plane. That is the cost of the front camera, and it is
/// why `.rear` still exists.
///
/// AND IT ACCEPTS ANY RECLINE. A third failure, found on a device: the pose was still
/// gated on the placement ray pointing downward in the world, which refused any phone
/// leaning back more than 13°. Standing a phone on the floor means leaning it back, so
/// the mode refused its own reason for existing — and said "aim lower", which a
/// propped phone cannot do. See `anchorTransform`.
nonisolated enum ARAssumedFloor {

    /// How high the lens sits above the floor when the phone is stood on it.
    ///
    /// A phone propped on its edge on the floor puts the camera a few centimetres up,
    /// not the 0.25 m an earlier version guessed — that figure was a phone on a stand,
    /// and it is what buried the board below the picture. This is the ONE thing about
    /// the real world this mode assumes, and it is the cheapest possible assumption:
    /// the phone is on the floor, so the floor is just below the phone.
    static let propHeight: Float = 0.08                // metres

    /// Fallback board distance, and the bounds the calibrated one is held inside.
    /// Nearer than `minDistance` the board is under the lens; further than
    /// `maxDistance` it is a postage stamp on the horizon.
    static let distance: Float = 0.78                  // metres

    /// How far below the world's horizon the board must stay, whatever the recline.
    /// Small: it is a floor, so just under the horizon is where it belongs, and any
    /// more would drag the board down the frame on a phone that is only slightly
    /// tipped back.
    static let minGroundAngle: Float = 8 * .pi / 180
    static let minDistance: Float = 0.30
    static let maxDistance: Float = 1.60

    /// How far below HORIZONTAL the board sits, seen from the lens — which, with the
    /// floor a known `propHeight` below, is the same as saying how far away it is.
    ///
    /// Measured from horizontal rather than from the lens axis. Against the AXIS the
    /// board keeps its place in the frame whatever the phone does, which sounds ideal
    /// and is how it ended up FLOATING: tip the phone back 30° and a point 13° below
    /// its axis is 17° above the world's horizon, so the board hung in mid-air above
    /// the carpet. Against the HORIZON it is always on the ground, and what changes
    /// with recline is how much of the ground you can see — which is the honest
    /// trade, and the one the player can do something about.
    static var placementPitch: Float { ARFloorCalibration.placementPitch }


    /// A gravity-aligned anchor transform standing in for a detected plane.
    ///
    /// The anchor is built with its **+X along the row and its +Z pointing back at
    /// the camera**, which is what makes the board face the player without anything
    /// downstream having to work it out, and keeps the slot offsets constant as the
    /// heading turns.
    static func anchorTransform(camera: ARCamera) -> simd_float4x4? {
        anchorTransform(camera: camera, requestedPitch: placementPitch)
    }

    /// The same at an EXPLICIT angle, so the page can solve for the one that puts the
    /// board on the player's feet instead of trusting a constant to land there.
    static func anchorTransform(camera: ARCamera, requestedPitch: Float) -> simd_float4x4? {
        let origin = camera.transform.columns.3.xyz

        // BACK TO THE FRAME. The board is planted a fixed angle below the LENS'S OWN
        // AXIS, so where it lands in the PICTURE is the input rather than the output.
        //
        // A version that put it on the true floor plane instead was tried and pulled:
        // it is more correct about the world and worse to use, because how much floor
        // is in shot depends on the recline, so the board slid around the frame and
        // sometimes out of it. Against the axis it is always in the same place and
        // always visible, which is what this page actually needs. Camera forward is
        // −Z and up is +Y, so a ray `placementPitch` below the axis is (0, −sin, −cos).
        // NEVER ABOVE THE HORIZON.
        //
        // The angle is measured from the LENS AXIS, which is what keeps the board in
        // the same part of the picture at any recline — and that is the behaviour to
        // keep. What it does not know is where the GROUND is, so once the phone leans
        // back further than the placement angle itself, a ray 14° below the axis is
        // pointing UP in the world and the board is planted in mid-air. At 20° of
        // recline it sits 8 cm above the lens; at 30°, 22 cm. That is the board in the
        // sky, and it needs no change of setup to appear — just a steeper prop than
        // the one before.
        //
        // So the frame keeps deciding where the board sits, right up to the point
        // where the frame would put it off the ground, and the ground wins from there.
        // A phone propped near level — the common case, and the one that was reported
        // as perfect — never reaches the clamp and is completely unaffected.
        var forward = -camera.transform.columns.2.xyz
        let forwardLength = simd_length(forward)
        if forwardLength > 1e-4 { forward /= forwardLength }
        // How far the lens is aimed above horizontal, in radians. Negative when it is
        // aimed down, in which case the clamp is inert.
        let recline = asin(max(-1, min(1, forward.y)))
        let pitch = max(requestedPitch, recline + Self.minGroundAngle)

        // BUILT AGAINST GRAVITY, NOT AGAINST THE CAMERA'S OWN AXES — and this is the
        // ceiling bug.
        //
        // It used to rotate a local ray of (0, −sin, −cos) by the camera's basis,
        // taking the camera's −Y as "down". ARKit defines those axes for a device in
        // LANDSCAPE-RIGHT. Turn the phone the other way up — which is one of the two
        // orientations this app ships, and which rotation lock will happily leave you
        // in — and camera −Y points at the SKY. The board was planted on the ceiling,
        // and no amount of repositioning helped because the phone was still upside
        // down.
        //
        // The same trap is documented in `slotOffsets` for the sideways axis, where
        // it came out as a mirrored row. This is that bug on the vertical axis.
        //
        // Derived from the world instead: take how high the lens is aimed, subtract
        // the placement angle, and build the ray from the horizontal heading and true
        // world up. Gravity does not care which way up the phone is, so neither does
        // this.
        var heading = simd_float3(forward.x, 0, forward.z)
        let headingLen = simd_length(heading)
        heading = headingLen > 1e-4 ? heading / headingLen : simd_float3(0, 0, -1)
        let elevation = recline - pitch                     // negative = below horizontal
        let ray = simd_normalize(heading * cos(elevation) + simd_float3(0, 1, 0) * sin(elevation))

        // NO DOWNWARD REQUIREMENT — kept from the fix that removed it. Demanding the
        // ray point downward in the WORLD refused every phone leaning back more than
        // the placement angle, which is how standing a phone on the floor works, and
        // answered with "aim lower" — the one thing a propped phone cannot do.
        let centre = origin + ray * distance

        // The board lies level on the plane through `centre`, facing back the way the
        // camera is looking — the same horizontal heading the ray was built from, so
        // there is nothing left to re-derive here.
        let boardZ = -heading
        let boardX = simd_cross(simd_float3(0, 1, 0), boardZ)

        var transform = matrix_identity_float4x4
        transform.columns.0 = simd_float4(boardX, 0)
        transform.columns.1 = simd_float4(0, 1, 0, 0)
        transform.columns.2 = simd_float4(boardZ, 0)
        transform.columns.3 = simd_float4(centre, 1)
        return transform
    }

    /// Whether the camera is pointed somewhere a floor could plausibly be.
    ///
    /// EVERYTHING PASSES NOW except an aim with no heading — straight up or straight
    /// down, where there is nowhere to put a board in front of. Two rounds of
    /// tightening this were two rounds of refusing propped phones; see
    /// `anchorTransform`.
    static func isUsableAim(camera: ARCamera) -> Bool {
        anchorTransform(camera: camera) != nil
    }
}
