//
//  StompPoseTracker.swift
//  StreetRig
//
//  The stomp itself: ARFrame → Vision body pose → track the lowest ankle →
//  downward velocity + debounce → which slot it landed on.
//
//  A stomp is a FOOTSWITCH press on a real pedal, not an animation trigger. The slot
//  index this returns ends up on `RigStore.arSlots`, which `RigGraphCompiler` turns
//  into a pedal's `enabled`, which `RigAudioBridge` pushes onto the DSP's lock-free
//  parameter bus. Returning the wrong index does not look wrong — it sounds wrong,
//  mid-song, and keeps working.
//
//  ORIENTATION — TOLD, NOT ROTATED. `ARFrame.capturedImage` is always in the
//  camera's native landscape orientation; unlike an AVFoundation connection there is
//  no knob to make ARKit hand over pre-rotated buffers, and there should not be:
//  rotating a 60 Hz video buffer to save one matrix multiply would spend CPU the
//  neural amp needs on the audio thread, where stolen cycles are an audible dropout
//  rather than a dropped frame. So Vision is TOLD which way up the buffer is
//  (`CameraOrientation.imageOrientation`) and the coordinates are converted after.
//
//  EVERYTHING BELOW IS IN VIEW SPACE. The conversion to the viewport's own points
//  happens FIRST, before any thresholding or binning, so "downward" means downward
//  on the screen the player is looking at and "left" means left of the slot they are
//  aiming for — in the same space `ARPlacementCoordinator` projects the slots into.
//  The alternative (thresholding in Vision's space, binning in the view's) is how
//  the two quietly drift apart.
//
//  Every member is touched ONLY on the ARSession's delegate queue.
//

import CoreVideo
import QuartzCore
import Vision

nonisolated final class StompPoseTracker {

    struct Stomp {
        let slot: Int
        /// Where it landed across the viewport, 0…1, for optional UI feedback.
        let normalizedX: CGFloat
    }

    /// What one processed frame saw: where the foot is, and whether it just stamped.
    ///
    /// THE HOVER WAS ALWAYS HERE AND WAS ALWAYS THROWN AWAY. This tracker has to know
    /// where the foot is on every frame in order to measure how fast it is moving —
    /// that was the whole point — but it only ever RETURNED anything on the frames
    /// where the speed crossed the threshold. From the player's side that made the
    /// feature binary and invisible: you stamp, and either something happens or
    /// nothing does, with no way to find out beforehand whether your foot is over the
    /// pedal you meant. Handing the hover out costs nothing that was not already
    /// computed, and it is what lets the board say "this one" before you commit.
    struct Reading {
        /// Which slot the foot is currently over, or nil when no foot is visible.
        let hoverSlot: Int?
        /// Non-nil only on the frame a downward stamp is detected.
        let stomp: Stomp?
        /// Where the WORKING foot is, in view space, when one is visible.
        ///
        /// Reported raw rather than pre-interpreted because a foot's position means
        /// different things to different callers: the slot binner wants its x, and a
        /// wah treadle wants its y measured against the pedal it is standing on. The
        /// tracker's job ends at "here is the foot".
        let footPoint: CGPoint?
    }

    // MARK: Tunables (first-pass; need on-device tuning)

    /// ARKit delivers ~60 Hz. Body-pose inference at that rate would be pure waste —
    /// and waste that competes with the amp sim. A stomp lasts far longer than 55 ms.
    private static let processInterval: TimeInterval = 1.0 / 18.0
    /// Downward speed that counts as a stomp, in viewport-heights per second. Carried
    /// over unchanged from the pre-ARKit detector, where it was image-heights per
    /// second — close enough in landscape to keep the tuning, different enough to
    /// re-check on a device.
    /// MEASURED DOWN FROM 1.6, WHICH WAS UNREACHABLE. That figure was inherited from
    /// the pre-ARKit detector and never checked against a person. A real session
    /// produced peaks of 1.58, 1.28 and 0.96 across a run of deliberate stomps and
    /// fired NOT ONCE — the hardest one missed by 0.02. Everything incidental in that
    /// same run (shifting weight, repositioning) sat at 0.66 and below, so this leaves
    /// a clear margin over the noise while actually being reachable by a foot.
    private static let stompVelocity: CGFloat = 0.55
    private static let debounce: TimeInterval = 0.55
    private static let minConfidence: Float = 0.3
    /// If the foot has been out of shot longer than this, forget where it was. Without
    /// it, a player who steps out of frame and back in produces one enormous apparent
    /// velocity on the frame they reappear — a phantom stomp, from standing still.
    private static let footStaleness: TimeInterval = 0.4
    /// How fast an ankle has to be going, in viewport-diagonals per second, before it
    /// is allowed to TAKE OVER as the working foot. Below this the previous choice
    /// stands, which is what stops the answer flickering between two feet that are
    /// both essentially still. NEEDS ON-DEVICE TUNING like every threshold here.
    private static let movingFootSpeed: CGFloat = 0.25
    /// How long a hover survives Vision losing sight of the foot. Long enough to ride
    /// out the one-frame dropouts that are normal even with a player standing plainly
    /// in shot, short enough that walking away clears the glow promptly.
    private static let hoverHold: TimeInterval = 0.35
    /// How far past the midpoint between two slots a foot must be before the hover
    /// moves, as a fraction of the gap between their centres. Pure anti-flicker: with
    /// it at zero the answer changes on sub-pixel jitter at the boundary.
    private static let slotSwitchMargin: CGFloat = 0.16
    /// How far the ankle has to travel DOWN, as a fraction of the viewport, to count
    /// as a stomp on displacement alone — see `stompWindow`.
    private static let stompDrop: CGFloat = 0.045
    /// …and the window it has to do it in. Together these are the "pressed down
    /// deliberately" trigger, as opposed to `stompVelocity`'s "moved down fast".
    private static let stompWindow: TimeInterval = 0.32
    /// Above this horizontal speed, in viewport-widths per second, the foot is
    /// crossing the board rather than pressing on it and stomps are suppressed.
    /// NEEDS ON-DEVICE TUNING: too low and a stomp that drifts slightly sideways is
    /// swallowed, too high and the fly-over it exists to stop comes back.
    private static let maxLateralForStomp: CGFloat = 0.22
    /// How long the foot has to have been over a slot before a stomp there counts.
    /// Short on purpose — long enough to exclude a fly-over, short enough that
    /// reaching and stomping in one motion still lands.
    private static let slotDwell: TimeInterval = 0.13

    private let request = VNDetectHumanBodyPoseRequest()

    /// One ankle's last known position and when it was seen.
    private struct FootTrack {
        var point: CGPoint
        var at: TimeInterval
    }

    private var lastProcess: TimeInterval = 0
    /// Index 0 is the left ankle, 1 the right. Separate histories — see `process`.
    private var tracks: [FootTrack?] = [nil, nil]
    /// Which ankle is currently doing the work. Sticky; see `movingFootSpeed`.
    private var activeFoot = 0
    private var lastFootAt: TimeInterval = 0
    private var lastStomp: TimeInterval = 0
    /// The last slot reported, for hysteresis and for riding out dropped frames.
    private var lastHoverSlot: Int?
    private var lastHoverAt: TimeInterval = 0
    /// When the working foot first arrived over `lastHoverSlot`.
    private var hoverSince: TimeInterval = 0
    /// A short trail of recent ankle heights per foot, for the displacement trigger.
    /// Only `stompWindow` of it is kept, so this is a handful of samples, not a log.
    private var trail: [[(y: CGFloat, at: TimeInterval)]] = [[], []]

    // Diagnostics only — see ARDiagnostics.swift. `stompVelocity` is the one tunable
    // here that cannot be reasoned about at all from a desk: it is a number about how
    // hard a particular person stomps, seen through a particular lens, at a particular
    // distance. What makes it tunable is knowing the peak the player ACTUALLY produced
    // on the frames that did not fire — "you peaked at 0.9 against a threshold of 1.6"
    // is an answer; "it didn't work" is not.
    private var peakVelocity: CGFloat = 0
    /// The best downward DISPLACEMENT in the last diagnostic second, alongside the
    /// best velocity. Both are logged because they are different ways to miss: a
    /// player whose presses are slow but deep needs a lower `stompDrop`, one whose
    /// stomps are quick and shallow needs a lower `stompVelocity`, and the two
    /// numbers are what tell those apart.
    private var peakDrop: CGFloat = 0
    private var footFrames = 0
    private var blindFrames = 0
    /// Frames where Vision returned no body at all. Counted separately from
    /// `blindFrames` (a body, but no usable ankle) because they are different
    /// failures: one is the player out of shot, the other is a detection that fell
    /// over on a frame. Conflating them is what made the first of these invisible.
    private var visionMisses = 0
    private var lastDiagLog: TimeInterval = 0
    private static let diagLogInterval: TimeInterval = 1.0

    /// Drop the motion history — on session restart, or anything else that makes the
    /// previous foot position a statement about a different situation.
    func reset() {
        tracks = [nil, nil]
        activeFoot = 0
        lastHoverSlot = nil
        lastHoverAt = 0
        hoverSince = 0
        trail = [[], []]
        peakDrop = 0
        lastFootAt = 0
        lastStomp = 0
        peakVelocity = 0
        footFrames = 0
        blindFrames = 0
        visionMisses = 0
    }

    /// - Parameters:
    ///   - slotCentersX: view-space x of the three slot centres when the layout is
    ///     anchored to the floor. `nil` means the slots are still in their fixed
    ///     bottom row, so bin by thirds of the viewport exactly as the page did
    ///     before any of this existed.
    /// - Returns: the stomp, if this frame completed one.
    func process(pixelBuffer: CVPixelBuffer,
                 geometry: ARPlacementCoordinator.ViewGeometry,
                 displayTransform: CGAffineTransform,
                 slotCentersX: (CGFloat, CGFloat, CGFloat)?) -> Reading? {
        let now = CACurrentMediaTime()
        guard now - lastProcess >= Self.processInterval else { return nil }
        // Per-ankle timing now comes from each track's own timestamp, so this is gone.
        _ = lastProcess
        lastProcess = now

        let orientation = CameraOrientation.imageOrientation(for: geometry.orientation)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        // THESE TWO RETURNS HELD THE LAST OF THE FLICKER, and they hid it as well as
        // caused it. A frame where Vision finds no BODY never reaches the foot
        // counters below, so the once-a-second `pose foot=16/16 frames` line read as a
        // perfect detection rate while the hover was dropping out several times a
        // second — the frames it was dropping on were in neither bucket. Both paths
        // now hold the last hover exactly as a missing-ankle frame does: a request
        // that found nothing is a gap in the data, not a player who has stepped away.
        do { try handler.perform([request]) } catch {
            visionMisses += 1
            return Reading(hoverSlot: heldHover(now: now), stomp: nil, footPoint: nil)
        }
        guard let observation = request.results?.first,
              let points = try? observation.recognizedPoints(.all) else {
            visionMisses += 1
            diagLogIfDue(now: now)
            return Reading(hoverSlot: heldHover(now: now), stomp: nil, footPoint: nil)
        }

        // BOTH ANKLES, TRACKED SEPARATELY. This used to collapse them to one point —
        // "the lowest foot on screen" — and that was wrong in a way that only shows up
        // with a real person standing on a real floor. A player has an ANCHOR foot
        // holding their weight and a WORKING foot that reaches for the pedal; which of
        // them is lower on screen swaps constantly as they shift, so the single tracked
        // point teleported between two feet a third of a metre apart. Every one of
        // those swaps looked like an enormous velocity — a phantom stomp from standing
        // still — and the slot it was attributed to was whichever foot happened to be
        // lower at that instant, not the one that moved.
        //
        // So each ankle keeps its own history and its own velocity, and the one that is
        // MOVING is the one that counts. The anchor foot is, by definition, the one
        // that is not.
        var seen: [CGPoint?] = [nil, nil]
        let joints: [VNHumanBodyPoseObservation.JointName] = [.leftAnkle, .rightAnkle]
        for (index, joint) in joints.enumerated() {
            guard let point = points[joint], point.confidence > Self.minConfidence else { continue }
            seen[index] = viewPoint(point.location, geometry: geometry, displayTransform: displayTransform)
        }

        guard seen.contains(where: { $0 != nil }) else {
            if now - lastFootAt > Self.footStaleness { tracks = [nil, nil] }
            blindFrames += 1
            diagLogIfDue(now: now)
            // A DROPPED FRAME IS NOT THE PLAYER LEAVING. Vision misses an ankle here
            // and there even with someone standing plainly in shot (`foot=9/10`), and
            // clearing the glow on each of those made it strobe. The hover is held
            // briefly instead, and only a real absence — longer than `hoverHold` —
            // puts it out.
            return Reading(hoverSlot: heldHover(now: now), stomp: nil, footPoint: nil)
        }
        footFrames += 1
        lastFootAt = now

        // Per-ankle velocity, in viewport-heights per second, downward positive.
        var downward: [CGFloat] = [0, 0]
        var speed: [CGFloat] = [0, 0]
        /// Horizontal speed alone, in viewport-WIDTHS per second. Kept apart from the
        /// combined `speed` because it answers a different question: not "is this foot
        /// the working one" but "is this foot travelling rather than stomping".
        var lateral: [CGFloat] = [0, 0]
        for index in 0..<2 {
            guard let point = seen[index] else { tracks[index] = nil; continue }
            defer { tracks[index] = FootTrack(point: point, at: now) }
            guard let previous = tracks[index], now - previous.at <= Self.footStaleness else { continue }
            let dt = max(now - previous.at, 1e-3)
            downward[index] = (point.y - previous.point.y) / geometry.size.height / CGFloat(dt)
            let dx = (point.x - previous.point.x) / geometry.size.width
            let dy = (point.y - previous.point.y) / geometry.size.height
            speed[index] = sqrt(dx * dx + dy * dy) / CGFloat(dt)
            lateral[index] = abs(dx) / CGFloat(dt)
        }

        // WHICH FOOT IS WORKING — CHOSEN ONLY FROM THE ONES ACTUALLY IN SHOT.
        //
        // The first version picked by speed and THEN checked visibility, which was
        // backwards and was the whole of the hover flicker. Vision frequently sees
        // just one ankle (the other is occluded by the leg in front of it, or its
        // confidence dips), and an unseen foot scores speed 0 — so `speed[0] >=
        // speed[1]` handed the answer to foot 0 whenever both read 0, including when
        // foot 0 was the one that was not there. The frame then returned no hover at
        // all. Measured: `hover slot=1 → none → 1 → none` every 60 ms while
        // `pose foot=13/13 frames` said a foot was visible on every single one.
        let visible = (0..<2).filter { seen[$0] != nil }
        guard let fastest = visible.max(by: { speed[$0] < speed[$1] }) else {
            diagLogIfDue(now: now)
            return Reading(hoverSlot: heldHover(now: now), stomp: nil, footPoint: nil)
        }
        // Stickiness, unchanged in spirit: a foot has to be meaningfully faster than a
        // foot merely holding still to TAKE OVER, or the answer flickers between two
        // near-motionless ankles. It can only stick to a foot that is still in shot.
        var candidate = fastest
        if speed[candidate] < Self.movingFootSpeed, visible.contains(activeFoot) {
            candidate = activeFoot
        }
        activeFoot = candidate
        let foot = seen[activeFoot]!

        // Where the WORKING foot is, decided the SAME way a stomp's slot is decided —
        // same binning, same centres, same viewport. If these two ever disagreed the
        // board would glow over one pedal and toggle another, which is the precise
        // silent-wrongness this page's headers are about.
        var hoverSlot = slot(forViewX: foot.x, width: geometry.size.width, centers: slotCentersX)
        // SLOT HYSTERESIS. Binning by nearest centre means a foot parked near a
        // boundary flips between two slots on sub-pixel jitter — visible in the log as
        // `slot=1 → 2 → 1` inside a fifth of a second, with the glow jumping pedals.
        // Once a slot is held it keeps the foot until the foot is CLEARLY into the
        // next one.
        if let centres = slotCentersX, let previous = lastHoverSlot, previous != hoverSlot {
            let xs = [centres.0, centres.1, centres.2]
            if xs.indices.contains(previous), xs.indices.contains(hoverSlot) {
                let toPrevious = abs(foot.x - xs[previous])
                let toNew = abs(foot.x - xs[hoverSlot])
                let gap = abs(xs[previous] - xs[hoverSlot])
                if toPrevious - toNew < gap * Self.slotSwitchMargin { hoverSlot = previous }
            }
        }
        // When the foot ARRIVED over this slot. Reaching across the board sweeps the
        // foot over the middle pedal on the way to an outer one, and that fly-over is
        // brief — so knowing how long it has been here is what separates "aiming at
        // this pedal" from "passing over it".
        if hoverSlot != lastHoverSlot { hoverSince = now }
        lastHoverSlot = hoverSlot
        lastHoverAt = now

        // TWO WAYS TO STOMP, because a stomp is not one motion.
        //
        // `velocity` catches the fast one — a foot swung down hard. That was the only
        // trigger, and on its own it demands something closer to a KICK than a stomp:
        // sampled at 18 Hz, a firm deliberate press produces no velocity spike at all,
        // it produces DISPLACEMENT. So the second trigger asks the other question —
        // has this ankle travelled down a real distance in the last third of a second
        // — and fires on a press that never moved fast at any single instant.
        //
        // What neither can see is the foot PIVOTING: the ankle stretching while the
        // ankle joint itself barely moves. `VNHumanBodyPoseObservation` stops at the
        // ankle — there is no toe or foot joint in it — so plantar flexion is simply
        // not observable here, and the displacement trigger is the closest available
        // stand-in for "pressed down" as distinct from "swung down".
        let velocity = downward[activeFoot]
        if velocity > peakVelocity { peakVelocity = velocity }

        trail[activeFoot].append((y: foot.y, at: now))
        trail[activeFoot].removeAll { now - $0.at > Self.stompWindow }
        let highest = trail[activeFoot].map(\.y).min() ?? foot.y
        let drop = (foot.y - highest) / geometry.size.height
        if drop > peakDrop { peakDrop = drop }

        let fired = velocity > Self.stompVelocity || drop > Self.stompDrop

        // REACHING ACROSS THE BOARD IS NOT STOMPING THE PEDAL YOU PASS OVER.
        //
        // The failure this prevents, in the player's words: reaching for an outer
        // pedal toggles the middle one. Nothing was wrong with the trigger — the foot
        // genuinely does travel down as it swings across, and at the instant it
        // crossed the threshold it genuinely was over the middle slot. What was
        // missing is that a STOMP IS A VERTICAL GESTURE and a reach is a horizontal
        // one, and the two are trivially separable once you look at the axis.
        //
        // Two independent guards, because they fail differently. A fast sideways
        // sweep is caught by `lateral`; a slow deliberate reach that pauses briefly
        // over the middle is caught by the dwell. Either alone leaves a gap.
        let travelling = lateral[activeFoot] > Self.maxLateralForStomp
        let settled = now - hoverSince >= Self.slotDwell
        if fired, travelling || !settled {
            ARDiagnostics.log("stomp SUPPRESSED slot=\(hoverSlot) "
                            + "lateral=\(ARDiagnostics.f(lateral[activeFoot]))/\(Self.maxLateralForStomp) "
                            + "dwell=\(ARDiagnostics.f(CGFloat(now - hoverSince), 2))s/\(Self.slotDwell) "
                            + "\(travelling ? "TRAVELLING" : "NOT SETTLED")")
        }
        guard fired, !travelling, settled, now - lastStomp > Self.debounce else {
            diagLogIfDue(now: now)
            return Reading(hoverSlot: hoverSlot, stomp: nil, footPoint: foot)
        }
        lastStomp = now
        // A fired stomp's trail is spent: leaving it would let the same descent fire
        // again the moment the debounce expires.
        trail[activeFoot].removeAll()
        let trigger = velocity > Self.stompVelocity ? "vel" : "drop"

        let stomp = Stomp(slot: hoverSlot,
                          normalizedX: min(1, max(0, foot.x / geometry.size.width)))
        let centres = slotCentersX.map {
            "[\(ARDiagnostics.f($0.0, 0)) \(ARDiagnostics.f($0.1, 0)) \(ARDiagnostics.f($0.2, 0))]"
        } ?? "thirds"
        ARDiagnostics.log("STOMP slot=\(stomp.slot) foot=\(activeFoot == 0 ? "L" : "R") by=\(trigger) "
                        + "lateral=\(ARDiagnostics.f(lateral[activeFoot])) "
                        + "dwell=\(ARDiagnostics.f(CGFloat(now - hoverSince), 2))s "
                        + "v=\(ARDiagnostics.f(velocity))/\(Self.stompVelocity) "
                        + "drop=\(ARDiagnostics.f(drop, 3))/\(Self.stompDrop) "
                        + "other=\(ARDiagnostics.f(downward[1 - activeFoot])) "
                        + "footX=\(ARDiagnostics.f(foot.x, 0)) centres=\(centres)")
        return Reading(hoverSlot: hoverSlot, stomp: stomp, footPoint: foot)
    }

    /// Once a second: is Vision finding an ankle at all, and how close did the hardest
    /// downward motion in that second come to firing. Two numbers that separate the
    /// three ways this can be silent — no body detected, foot detected but too slow, or
    /// firing correctly and the failure is downstream.
    /// The last hover, while it is still fresh enough to stand in for a dropped frame.
    private func heldHover(now: TimeInterval) -> Int? {
        guard now - lastHoverAt <= Self.hoverHold else {
            lastHoverSlot = nil
            return nil
        }
        return lastHoverSlot
    }

    private func diagLogIfDue(now: TimeInterval) {
        guard ARDiagnostics.enabled, now - lastDiagLog >= Self.diagLogInterval else { return }
        lastDiagLog = now
        ARDiagnostics.log("pose foot=\(footFrames)/\(footFrames + blindFrames) frames "
                        + "noBody=\(visionMisses) "
                        + "peakV=\(ARDiagnostics.f(peakVelocity))/\(Self.stompVelocity) "
                        + "peakDrop=\(ARDiagnostics.f(peakDrop, 3))/\(Self.stompDrop)")
        visionMisses = 0
        peakDrop = 0
        peakVelocity = 0
        footFrames = 0
        blindFrames = 0
        visionMisses = 0
    }

    /// Vision's answer, in the viewport's points.
    ///
    /// `capturedImagePoint` undoes the orientation Vision was told to read with and
    /// flips to a top-left origin; `displayTransform` then applies the rotation AND
    /// the aspect-fill crop that the camera feed is actually drawn with. That crop is
    /// why this is not simply `x * width`: the feed is 4:3-ish inside a 16:9-ish
    /// viewport, so a foot near the edge of the picture is not where naive scaling
    /// puts it — the pre-ARKit detector binned on raw normalized x and inherited that
    /// error.
    private func viewPoint(_ visionPoint: CGPoint,
                           geometry: ARPlacementCoordinator.ViewGeometry,
                           displayTransform: CGAffineTransform) -> CGPoint {
        let inImage = CameraOrientation.capturedImagePoint(fromVision: visionPoint,
                                                           for: geometry.orientation)
        let normalized = inImage.applying(displayTransform)
        return CGPoint(x: normalized.x * geometry.size.width,
                       y: normalized.y * geometry.size.height)
    }

    private func slot(forViewX x: CGFloat, width: CGFloat, centers: (CGFloat, CGFloat, CGFloat)?) -> Int {
        guard let centers else {
            // The fixed row: three equal columns across the page, left to right. The
            // back camera is not mirrored, so nothing is flipped here — the player's
            // own left foot appears on the right of the picture because they are
            // facing the phone, and the slot they aim at is the one they see under it.
            return min(2, max(0, Int(x / max(width, 1) * 3)))
        }
        // Anchored: nearest slot centre, which is the honest generalisation of thirds
        // once the row is somewhere on the floor rather than filling the screen.
        let d0 = abs(centers.0 - x), d1 = abs(centers.1 - x), d2 = abs(centers.2 - x)
        if d0 <= d1 { return d0 <= d2 ? 0 : 2 }
        return d1 <= d2 ? 1 : 2
    }
}
