//
//  ARCameraView.swift
//  StreetRig
//
//  The live camera feed behind the AR pedal slots — now an `ARSCNView`, because
//  ARKit owns the camera exclusively and an `AVCaptureVideoPreviewLayer` cannot be
//  fed by it. (Replaces CameraPreviewView, whose AVFoundation session no longer
//  exists; the part of it that mattered, sampling the orientation from the layout
//  pass, is carried forward below.)
//
//  THE SCENE HAS CONTENT NOW, and that is a reversal. This file used to say the
//  scene stays empty — ARKit for tracking, every pixel of gear in SwiftUI — and
//  warned that anything adding nodes here had reversed the design. `ARFloorPedals`
//  does exactly that, deliberately: the pedals are SceneKit models parented to the
//  world anchor, so they lie on the real floor in real perspective instead of being
//  rectangles pasted at a projected point. The chrome that has to be READ from
//  standing height — name, ON/OFF, the lamp — is still SwiftUI on top.
//
//  The two render settings below moved with that decision. Both were off because
//  there was nothing to light or to smooth; leaving them off now would give a pedal
//  lit for a different room (which reads as a sticker on the lens) and hard aliased
//  edges on a 7cm object several feet away. Motion blur and camera grain stay off:
//  they cost the same frame time and buy realism the player is not looking for
//  while trying to find a footswitch with their foot.
//
//  IT REPORTS ITS GEOMETRY, AND THAT IS THE POINT. The interface orientation AND the
//  viewport size are handed onward on every layout pass, because both are inputs to
//  the two conversions that have to agree: `ARCamera.projectPoint` for the slots and
//  `ARFrame.displayTransform` for the foot. Sampling them anywhere else — an
//  orientation notification, a `GeometryReader` in a different subtree — is how the
//  slots and the stomps end up in two nearly-identical spaces. A layout pass is the
//  one moment UIKit guarantees a rotation has already been committed; a notification
//  races the very change it is reacting to.
//
//  A landscape↔landscape flip is a 180° turn with IDENTICAL bounds, so there is no
//  size change to hang a one-shot update on — but UIKit still lays the hierarchy out,
//  which is the other reason this is done from `layoutSubviews` rather than once.
//

import ARKit
import SceneKit
import SwiftUI

struct ARCameraView: UIViewRepresentable {
    let session: ARSession
    /// Called on the main thread with the orientation and size the feed is being
    /// drawn at.
    var onGeometry: (UIInterfaceOrientation, CGSize) -> Void = { _, _ in }
    /// Handed the view itself, so a tap can be raycast in the view's own coordinates
    /// rather than converted into ARKit's normalized image space by hand.
    var onView: (ARSCNView?) -> Void = { _ in }

    func makeUIView(context: Context) -> FeedView {
        let view = FeedView(frame: .zero)
        view.session = session
        view.backgroundColor = .black
        // Lighting and antialiasing are ON because there is now content that needs
        // them (see the header). Grain and motion blur stay off: they run next to a
        // neural amp on the audio thread and world tracking on the CPU, and buy
        // nothing a player hunting for a footswitch with their foot will notice.
        view.automaticallyUpdatesLighting = true
        view.rendersCameraGrain = false
        view.rendersMotionBlur = false
        view.antialiasingMode = .multisampling2X
        view.onGeometry = onGeometry
        onView(view)
        return view
    }

    func updateUIView(_ view: FeedView, context: Context) {
        view.onGeometry = onGeometry
        onView(view)
        // A rotation reaches SwiftUI as a re-render (the safe-area insets swap sides)
        // as well as a layout pass, so the report is made from both. It costs an
        // equality check on the far end, not a reconfiguration.
        view.reportGeometry()
    }

    static func dismantleUIView(_ view: FeedView, coordinator: ()) {
        view.onGeometry = nil
        // The session outlives this view — the other host may still be showing it —
        // so make sure it is still running once this one is gone.
        CameraStompDetector.shared.attach(feedView: nil)
        CameraStompDetector.shared.cameraViewDetached()
    }

    final class FeedView: ARSCNView {
        var onGeometry: ((UIInterfaceOrientation, CGSize) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            reportGeometry()
        }

        func reportGeometry() {
            guard bounds.width > 1, bounds.height > 1 else { return }
            onGeometry?(sceneOrientation, bounds.size)
        }

        /// The view's OWN scene when it has one — a second scene (iPad) can be in a
        /// different orientation than the active one. Before the view is in a window
        /// there is nothing to ask but the app.
        private var sceneOrientation: UIInterfaceOrientation {
            if let scene = window?.windowScene { return CameraOrientation.orientation(of: scene) }
            return CameraOrientation.current
        }
    }
}
