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

    /// Where the board sits in the FRAME, as an angle below the lens's own axis.
    ///
    /// THIS USED TO BE A CAMERA HEIGHT AND THAT WAS THE WRONG QUANTITY. Guessing how
    /// high the phone was propped (0.25 m) and letting the board fall where that plane
    /// met the aim put it ~19° down on a level phone — under the bottom of the picture,
    /// visible only by tilting the phone down. Angle-from-the-axis cannot do that: it
    /// is measured against the frame, so it lands in the same part of the frame no
    /// matter how the phone is sitting, and no guess about the prop enters into it.
    static let defaultPitch: Float = 13 * .pi / 180
    /// Just under the axis at one end, steeply down at the other. Beyond either the
    /// board is off the top of the picture or back under its bottom edge.
    static let minPitch: Float = 4 * .pi / 180
    static let maxPitch: Float = 30 * .pi / 180

    private static let key = "streetrig.ar.placementPitch"
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
nonisolated enum ARAssumedFloor {

    /// How far along the placement ray the board sits. Sets its apparent SIZE and
    /// nothing else now — where it lands in the frame is set by `placementPitch`.
    static let distance: Float = 0.78                  // metres

    /// How far BELOW the lens's own axis the board is planted, in radians.
    ///
    /// THE FIX FOR "IT IS UNDER THE FRAME". The previous version assumed a floor
    /// 0.25 m below the lens and let the board land wherever that plane met the aim.
    /// On a propped, near-level phone that works out to ~19° below the optical axis —
    /// far enough down that the board fell off the bottom of the picture, and the only
    /// way to see it was to tilt the phone down, which is the one thing a propped
    /// phone must not need.
    ///
    /// Measuring the angle from the CAMERA'S OWN AXIS instead of from a guessed floor
    /// inverts that: the board lands at the same place in the FRAME whatever the phone
    /// is doing, because the frame is what the angle is relative to. It cannot fall out
    /// of shot, and no assumption about how high the phone was propped enters into it.
    static var placementPitch: Float { ARFloorCalibration.placementPitch }

    /// A gravity-aligned anchor transform standing in for a detected plane.
    ///
    /// The anchor is built with its **+X along the row and its +Z pointing back at
    /// the camera**, which is what makes the board face the player without anything
    /// downstream having to work it out, and keeps the slot offsets constant as the
    /// heading turns.
    static func anchorTransform(camera: ARCamera) -> simd_float4x4? {
        let origin = camera.transform.columns.3.xyz

        // The placement ray, built in the CAMERA'S space and then rotated into the
        // world. Camera forward is −Z and up is +Y, so a ray `placementPitch` below
        // the axis is (0, −sin, −cos) — which is the whole trick: it is defined
        // against the picture, so it stays put in the picture.
        let pitch = placementPitch
        let localRay = simd_float3(0, -sin(pitch), -cos(pitch))
        let rotation = simd_float3x3(camera.transform.columns.0.xyz,
                                     camera.transform.columns.1.xyz,
                                     camera.transform.columns.2.xyz)
        let ray = simd_normalize(rotation * localRay)

        // It still has to point DOWNWARD in the world, or the "floor" it defines would
        // be level with the lens or above it. A phone tilted up past the placement
        // angle is the only thing this rejects.
        guard ray.y < -0.02 else { return nil }

        let centre = origin + ray * distance

        // Heading with the pitch flattened out: the board lies level on the plane
        // through `centre`, facing back the way the camera is looking.
        var heading = simd_float3(ray.x, 0, ray.z)
        let headingLength = simd_length(heading)
        guard headingLength > 1e-4 else { return nil }
        heading /= headingLength

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
    /// ALMOST EVERYTHING PASSES NOW, deliberately. The previous version used this to
    /// demand a downward tilt and thereby rejected the propped, level pose this mode
    /// is built for. What is left is the only genuinely useless aim: straight up or
    /// straight down, where there is no heading to put a board in front of.
    static func isUsableAim(camera: ARCamera) -> Bool {
        anchorTransform(camera: camera) != nil
    }
}
