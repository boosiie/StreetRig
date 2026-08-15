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
//  NOTHING 3D IS DRAWN HERE. The scene stays empty. `ARSCNView` is used purely
//  because it is the shortest correct path to "show me the session's camera feed,
//  right way up, in this rect" — SceneKit renders the background and no content.
//  Everything the player sees on top of it is SwiftUI. If a future change starts
//  adding nodes to this scene, the design decision behind this whole feature has been
//  reversed and the readiness system should be revisited with it.
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
        // Everything below is work with nothing to work on: there is no virtual
        // content to light, to grain-match, to motion-blur or to antialias. Left at
        // ARKit's defaults it would all still run, next to a neural amp on the audio
        // thread and world tracking on the CPU.
        view.automaticallyUpdatesLighting = false
        view.rendersCameraGrain = false
        view.rendersMotionBlur = false
        view.antialiasingMode = .none
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
