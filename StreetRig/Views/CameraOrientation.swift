//
//  CameraOrientation.swift
//  StreetRig
//
//  ONE answer to "which way up is the camera?", shared by everything on the AR
//  pedal page: the preview layer that shows the feed, and the Vision request that
//  reads a foot out of it. They MUST agree — the player aims a stomp using the
//  picture, and the slot the stomp lands in is binned from Vision's coordinates.
//  Two tables would drift; one table cannot.
//
//  Deliberately free of AVFoundation and ARKit. It maps an interface orientation
//  to two numbers and nothing else, so the ARKit rewrite can hand it an
//  `ARFrame.capturedImage` orientation question without dragging a capture
//  session along.
//
//  WHY INTERFACE ORIENTATION IS THE SOURCE OF TRUTH. The two obvious candidates
//  are both wrong for THIS feature:
//
//    • `UIDevice.current.orientation` describes the PHONE. The whole premise here
//      is a phone propped on the floor pointing at your feet, so it reports
//      `.faceUp` / `.faceDown` / `.unknown` much of the time — none of which is
//      an interface orientation, and none of which says which way the slots are
//      drawn. (See the table below for the second trap: in landscape the device
//      and interface enums are INVERTED with respect to each other, so mixing
//      them silently buys a 180° error.)
//
//    • `AVCaptureDevice.RotationCoordinator` answers a different question —
//      "how much rotation keeps the horizon level RELATIVE TO GRAVITY". A phone
//      lying flat has no meaningful roll about the camera axis, and StreetRig is
//      landscape-locked, so a player physically holding the phone upright would
//      get portrait-upright video behind a landscape UI. Horizon-level is the
//      right answer for a photo app and the wrong one for this one.
//
//  What the player actually looks at is the interface: the three stomp slots are
//  laid out in interface space. Aligning the camera to the interface is what makes
//  the preview upright AND puts Vision's normalized coordinates in the same frame
//  the slots are binned in. That single alignment is the whole point of this file.
//

import UIKit
import ImageIO

enum CameraOrientation {

    // MARK: - The mapping table
    //
    // Keyed on UIInterfaceOrientation — NOT UIDeviceOrientation. UIKit defines
    // `UIInterfaceOrientationLandscapeLeft == UIDeviceOrientationLandscapeRight`
    // and vice versa, so a table that looks like this one but is fed device
    // orientations is 180° wrong in landscape. Do not "correct" the labels.
    //
    //   interface orientation | home button | preview angle | back-camera buffer
    //   ----------------------+-------------+---------------+-------------------
    //   .landscapeRight       | right       |   0°          | .up
    //   .landscapeLeft        | left        | 180°          | .down
    //   .portrait             | bottom      |  90°          | .right
    //   .portraitUpsideDown   | top         | 270°          | .left
    //
    // The two right-hand columns are the same rotation expressed twice, which is
    // exactly why callers must apply ONE of them and not both. `.landscapeRight`
    // is the identity row because 0° is, per AVFoundation, "the camera's
    // unrotated, native sensor orientation" — an iPhone's back camera is already
    // upright when the home button is on the right.
    //
    // StreetRig only ships the two landscape rows (it is landscape-locked on both
    // iPhone and iPad). The portrait rows are here because they are free, and
    // because a utility that only half-covers the enum invites a caller to guess.
    //
    // ARKIT USES THE SAME TABLE — NO EXTRA ROW NEEDED. `ARFrame.capturedImage`
    // arrives in the camera's native sensor orientation and never rotates with the
    // interface, which is exactly the state an unrotated `AVCaptureVideoDataOutput`
    // buffer is in. Same base, same table: an ARKit frame read for `.landscapeLeft`
    // still wants `.down`. The one thing ARKit adds is a SECOND consumer of these
    // coordinates (`ARFrame.displayTransform`, which wants the captured image's own
    // space rather than Vision's), and that is what `capturedImagePoint` below is
    // for — a hop between two conventions, not a second table.

    /// Degrees to rotate the video so it matches the interface, for
    /// `AVCaptureConnection.videoRotationAngle`. Always one of 0/90/180/270 —
    /// the only values a connection accepts — but callers must still ask
    /// `isVideoRotationAngleSupported(_:)` first, because an unsupported angle
    /// throws rather than failing softly.
    nonisolated static func previewRotationAngle(for orientation: UIInterfaceOrientation) -> CGFloat {
        switch orientation {
        case .landscapeRight:     return 0
        case .landscapeLeft:      return 180
        case .portrait:           return 90
        case .portraitUpsideDown: return 270
        // `.unknown` only shows up before a scene has settled. Fall back to the
        // identity row rather than guessing: no rotation is the one answer that
        // is never worse than doing nothing.
        default:                  return 0
        }
    }

    /// How to read an UNROTATED back-camera buffer for this interface
    /// orientation — what `VNImageRequestHandler` needs to be told so its
    /// normalized coordinates come back in the upright space the player sees
    /// (origin bottom-left, +x to the right of the picture, +y up).
    ///
    /// Back camera only. The front camera is mirrored, which these values do not
    /// account for; the AR page does not use it.
    nonisolated static func imageOrientation(for orientation: UIInterfaceOrientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .landscapeRight:     return .up
        case .landscapeLeft:      return .down
        case .portrait:           return .right
        case .portraitUpsideDown: return .left
        default:                  return .up
        }
    }

    // MARK: - Putting a Vision answer back where ARKit can use it

    /// Where a Vision result sits in the CAPTURED IMAGE's own normalized space —
    /// origin top-left, (1,1) bottom-right — ready to hand to
    /// `ARFrame.displayTransform(for:viewportSize:)`.
    ///
    /// Two conventions have to be crossed, and both are easy to get silently wrong:
    ///
    ///   1. **Origin.** Vision answers with the origin at the BOTTOM-left, y up.
    ///      ARKit's image space puts it at the TOP-left, y down. Hence `1 - y`.
    ///   2. **Rotation.** Vision answers in the space it was TOLD to read. Hand it
    ///      `imageOrientation(for: .landscapeLeft)` — i.e. `.down` — and its points
    ///      come back upright FOR THE PLAYER, not in the buffer's own coordinates.
    ///      `displayTransform` wants the buffer's coordinates, because rotating
    ///      them to the interface is precisely the job it is about to do. So the
    ///      rotation Vision applied has to be undone first, or it gets applied
    ///      twice and a stomp on the left of the picture lands on the right.
    ///
    /// This exists so the foot Vision found and the anchor ARKit is tracking can be
    /// compared in ONE viewport — which is the only reason a stomp toggles the slot
    /// it visibly landed under. Getting it wrong is not cosmetic: the detector keeps
    /// working and keeps toggling the wrong pedal, mid-song.
    nonisolated static func capturedImagePoint(fromVision point: CGPoint,
                                               for orientation: UIInterfaceOrientation) -> CGPoint {
        // Flip to a top-left origin first; every case below is stated in that space.
        let p = CGPoint(x: point.x, y: 1 - point.y)
        switch imageOrientation(for: orientation) {
        case .up:    return p                                    // 0°, nothing to undo
        case .down:  return CGPoint(x: 1 - p.x, y: 1 - p.y)      // undo 180°
        case .right: return CGPoint(x: p.y,     y: 1 - p.x)      // undo 90° clockwise
        case .left:  return CGPoint(x: 1 - p.y, y: p.x)          // undo 90° counter-clockwise
        // The mirrored orientations are unreachable here: `imageOrientation` only
        // ever returns the four rotations above (back camera, not mirrored).
        default:     return p
        }
    }

    // MARK: - Asking UIKit which orientation we are in

    /// The orientation of the scene the player is looking at.
    ///
    /// Used to seed a value before any view exists; a view that HAS a window
    /// should ask `orientation(of:)` with its own scene instead, which is both
    /// more specific and guaranteed settled by the time it is laid out.
    static var current: UIInterfaceOrientation {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        // No scene at all means nothing is on screen yet, so the identity row is
        // as good an answer as exists — and it will be replaced on first layout.
        guard let scene else { return .landscapeRight }
        return orientation(of: scene)
    }

    /// The scene's resolved interface orientation.
    ///
    /// Wrapped rather than read inline because the spelling moved: as of iOS 26
    /// `UIWindowScene.interfaceOrientation` is deprecated in favour of the
    /// resolved value on `effectiveGeometry`. One place to know that.
    static func orientation(of scene: UIWindowScene) -> UIInterfaceOrientation {
        scene.effectiveGeometry.interfaceOrientation
    }
}
