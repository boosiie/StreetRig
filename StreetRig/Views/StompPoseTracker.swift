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

    // MARK: Tunables (first-pass; need on-device tuning)

    /// ARKit delivers ~60 Hz. Body-pose inference at that rate would be pure waste —
    /// and waste that competes with the amp sim. A stomp lasts far longer than 55 ms.
    private static let processInterval: TimeInterval = 1.0 / 18.0
    /// Downward speed that counts as a stomp, in viewport-heights per second. Carried
    /// over unchanged from the pre-ARKit detector, where it was image-heights per
    /// second — close enough in landscape to keep the tuning, different enough to
    /// re-check on a device.
    private static let stompVelocity: CGFloat = 1.6
    private static let debounce: TimeInterval = 0.55
    private static let minConfidence: Float = 0.3
    /// If the foot has been out of shot longer than this, forget where it was. Without
    /// it, a player who steps out of frame and back in produces one enormous apparent
    /// velocity on the frame they reappear — a phantom stomp, from standing still.
    private static let footStaleness: TimeInterval = 0.4

    private let request = VNDetectHumanBodyPoseRequest()

    private var lastProcess: TimeInterval = 0
    private var lastFootY: CGFloat?
    private var lastFootAt: TimeInterval = 0
    private var lastStomp: TimeInterval = 0

    /// Drop the motion history — on session restart, or anything else that makes the
    /// previous foot position a statement about a different situation.
    func reset() {
        lastFootY = nil
        lastFootAt = 0
        lastStomp = 0
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
                 slotCentersX: (CGFloat, CGFloat, CGFloat)?) -> Stomp? {
        let now = CACurrentMediaTime()
        guard now - lastProcess >= Self.processInterval else { return nil }
        let elapsed = lastProcess == 0 ? Self.processInterval : now - lastProcess
        lastProcess = now

        let orientation = CameraOrientation.imageOrientation(for: geometry.orientation)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let observation = request.results?.first,
              let points = try? observation.recognizedPoints(.all) else { return nil }

        // Both ankles, converted to view space before anything is decided about them.
        var foot: CGPoint?
        for joint in [VNHumanBodyPoseObservation.JointName.leftAnkle, .rightAnkle] {
            guard let point = points[joint], point.confidence > Self.minConfidence else { continue }
            let inView = viewPoint(point.location, geometry: geometry, displayTransform: displayTransform)
            // Lowest foot on the SCREEN — view space grows downward, so that is the
            // largest y. (In Vision's own bottom-left space it would be the smallest;
            // this is exactly the sign flip that makes mixing the two spaces so easy
            // to get wrong and so hard to notice.)
            if foot == nil || inView.y > foot!.y { foot = inView }
        }

        guard let foot else {
            if now - lastFootAt > Self.footStaleness { lastFootY = nil }
            return nil
        }

        let previous = lastFootY
        let stale = now - lastFootAt > Self.footStaleness
        lastFootY = foot.y
        lastFootAt = now
        guard let previous, !stale else { return nil }

        // Downward, as a fraction of the viewport per second.
        let velocity = (foot.y - previous) / geometry.size.height / CGFloat(elapsed)
        guard velocity > Self.stompVelocity, now - lastStomp > Self.debounce else { return nil }
        lastStomp = now

        return Stomp(slot: slot(forViewX: foot.x, width: geometry.size.width, centers: slotCentersX),
                     normalizedX: min(1, max(0, foot.x / geometry.size.width)))
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
