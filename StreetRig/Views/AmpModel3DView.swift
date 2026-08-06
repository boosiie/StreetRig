//
//  AmpModel3DView.swift
//  StreetRig
//
//  The rig stage's first piece of gear to graduate from flat vector art
//  (GearArtView) to a real-time, rotatable 3D model. Backed by SceneKit
//  (SCNView via UIViewRepresentable): drag to orbit, pinch to zoom, plus a
//  gentle idle drift. Until a real, licensed .usdz is bundled it renders a
//  PROCEDURAL stand-in — a generic head + 4x12 cab, cream faceplate, and a row
//  of knobs with PBR metallic/roughness materials and image-based lighting — so
//  no brand logo or trademarked script is ever baked in. One knob per amp
//  parameter turns live from `GearItem.values`, proving the data binding.
//
//  Everything is additive and gated by `FeatureFlags.amp3D`; RigStageView only
//  swaps this in for the amp slot and leaves every other gear category, the
//  cards, and the zoom overlay on GearArtView.
//
//  ── Swap seam ──────────────────────────────────────────────────────────────
//  To drop in a real model later: bundle "Foo.usdz", set the amp's
//  `GearItem.modelName = "Foo"`, and name its knob nodes "knob_Gain",
//  "knob_Bass", … so they stay data-driven. `AmpScene.load(usdzNamed:)` then
//  loads it in place of the procedural build. See `AmpScene.make(for:)`.
//

import SwiftUI
import SceneKit
import UIKit

// MARK: - SwiftUI wrapper

/// A rotatable, PBR-lit 3D amp. Used only on the rig stage behind the feature
/// flag; the rest of the app keeps rendering `GearArtView`.
struct AmpModel3DView: UIViewRepresentable {
    /// The amp whose knobs drive the model (and whose `modelName` picks the asset).
    var item: GearItem?
    /// Fired on a single tap so the stage can zoom into the control overlay —
    /// preserving the tap-to-focus behavior the vector art had.
    var onTap: (() -> Void)? = nil

    /// Seconds per idle 360° turn (0 disables the drift).
    private let idleSpinPeriod: Double = 44

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let scene = AmpScene.make(for: item, idleSpinPeriod: idleSpinPeriod)
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: false)

        view.backgroundColor = .clear            // blend onto the stage gradient
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true          // smooth idle spin + PBR
        view.isPlaying = true
        view.autoenablesDefaultLighting = false  // we supply lights + IBL
        view.allowsCameraControl = true          // free drag-orbit + pinch-zoom

        // Cache knob nodes once so per-update value changes are cheap.
        context.coordinator.cacheKnobs(in: scene)

        // Single tap → zoom, coexisting with the camera controller's gestures.
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)

        context.coordinator.apply(values: item?.values ?? [:])
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.apply(values: item?.values ?? [:])
    }

    // MARK: Coordinator — holds knob nodes and routes the tap

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: (() -> Void)?
        private var knobs: [String: SCNNode] = [:]

        init(onTap: (() -> Void)?) { self.onTap = onTap }

        func cacheKnobs(in scene: SCNScene) {
            for name in AmpScene.knobParamNames {
                knobs[name] = scene.rootNode.childNode(withName: AmpScene.knobNodeName(name),
                                                       recursively: true)
            }
        }

        /// Turn each knob to match its 0–10 value (−135°…+135°, like the 2D knobs).
        func apply(values: [String: Double]) {
            for (name, node) in knobs {
                node.eulerAngles.z = AmpScene.knobAngle(forValue: values[name] ?? 5)
            }
        }

        @objc func handleTap() { onTap?() }

        // Let the tap fire alongside SceneKit's built-in orbit/zoom recognizers.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

// MARK: - Scene assembly

/// Builds the SCNScene (procedural stand-in or bundled .usdz), lighting, camera,
/// and the value→knob-angle math shared with the coordinator.
enum AmpScene {
    /// The amp faceplate knobs, in panel order — single source of truth is the
    /// data model, so the 3D knobs never drift from `GearItem.values`.
    static let knobParamNames: [String] = GearCategory.amp.parameters.map { $0.name }

    static func knobNodeName(_ param: String) -> String { "knob_\(param)" }

    /// 0–10 → −135°…+135°, negated so higher values turn the pointer clockwise
    /// from the front (matching `InteractiveKnob` in ComponentDetailView).
    static func knobAngle(forValue v: Double) -> Float {
        let frac = Float(max(0, min(10, v)) / 10)
        let deg = -135 + frac * 270
        return -deg * .pi / 180
    }

    /// Build the scene for `item`: a bundled `.usdz` if `modelName` is set and
    /// present, otherwise the procedural stand-in. This is the asset swap seam.
    static func make(for item: GearItem?, idleSpinPeriod: Double) -> SCNScene {
        let scene = SCNScene()
        let ampRoot = SCNNode()
        ampRoot.name = "ampRoot"

        if let name = item?.modelName, let loaded = load(usdzNamed: name) {
            ampRoot.addChildNode(loaded)
        } else {
            ProceduralAmp.build(into: ampRoot)
        }
        scene.rootNode.addChildNode(ampRoot)

        addStudioLighting(to: scene)
        addCamera(to: scene)
        addContactShadow(to: scene.rootNode)

        if idleSpinPeriod > 0 {
            let spin = SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: idleSpinPeriod)
            ampRoot.runAction(.repeatForever(spin))
        }
        return scene
    }

    /// The documented drop-in point for a real, vetted model. Returns the loaded
    /// model's nodes, or nil if the named asset isn't bundled — in which case
    /// `make(for:)` falls back to the procedural stand-in.
    static func load(usdzNamed name: String) -> SCNNode? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "usdz"),
              let scene = try? SCNScene(url: url) else { return nil }
        let holder = SCNNode()
        for child in scene.rootNode.childNodes { holder.addChildNode(child) }
        return holder
    }

    // MARK: Lighting (key + fill + ambient + image-based environment)

    private static func addStudioLighting(to scene: SCNScene) {
        scene.lightingEnvironment.contents = environmentImage()   // IBL for PBR reflections
        scene.lightingEnvironment.intensity = 1.15

        let key = SCNLight()
        key.type = .directional
        key.intensity = 780
        key.temperature = 5200
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.9, 0.5, 0)      // upper front-left
        scene.rootNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 300
        fill.temperature = 7200
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.eulerAngles = SCNVector3(-0.25, -0.9, 0)   // cooler right fill
        scene.rootNode.addChildNode(fillNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 110
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)
    }

    private static func addCamera(to scene: SCNScene) {
        let cam = SCNCamera()
        cam.fieldOfView = 34
        cam.wantsHDR = true
        cam.zNear = 0.05
        cam.zFar = 200
        let node = SCNNode()
        node.camera = cam
        node.name = "camera"
        node.position = SCNVector3(0, 0.15, 8.4)
        node.eulerAngles = SCNVector3(-0.045, 0, 0)         // slight downward tilt
        scene.rootNode.addChildNode(node)
    }

    /// A cheap fake contact shadow — a flat radial-gradient plane under the cab —
    /// so the amp reads as grounded without a shadow-casting light setup.
    private static func addContactShadow(to root: SCNNode) {
        let plane = SCNPlane(width: 5.4, height: 3.4)
        let m = SCNMaterial()
        m.diffuse.contents = radialShadowImage()
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
        node.eulerAngles.x = -.pi / 2                        // lay flat on the floor
        node.position = SCNVector3(0, -2.14, 0.15)
        node.renderingOrder = -10
        root.addChildNode(node)
    }

    // MARK: Procedurally-generated lighting/shadow textures

    /// A soft vertical gradient used as the image-based lighting environment
    /// (bright top → dark bottom) so metallic parts pick up believable studio
    /// reflections without shipping an HDR asset.
    private static func environmentImage() -> UIImage {
        let size = CGSize(width: 256, height: 128)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(white: 0.66, alpha: 1).cgColor,
                          UIColor(white: 0.30, alpha: 1).cgColor,
                          UIColor(white: 0.06, alpha: 1).cgColor] as CFArray
            guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors, locations: [0, 0.55, 1]) else { return }
            ctx.cgContext.drawLinearGradient(grad,
                                             start: CGPoint(x: 0, y: 0),
                                             end: CGPoint(x: 0, y: size.height),
                                             options: [])
        }
    }

    private static func radialShadowImage() -> UIImage {
        let size = CGSize(width: 256, height: 256)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let center = CGPoint(x: 128, y: 128)
            let colors = [UIColor(white: 0, alpha: 0.55).cgColor,
                          UIColor(white: 0, alpha: 0.0).cgColor] as CFArray
            guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors, locations: [0, 1]) else { return }
            ctx.cgContext.drawRadialGradient(grad, startCenter: center, startRadius: 0,
                                             endCenter: center, endRadius: 128, options: [])
        }
    }
}

// MARK: - Procedural stand-in amp (generic silhouette, no brand, no logo)

/// Assembles a recognizable-but-generic amp: a head with a cream faceplate and a
/// live row of knobs, on a gold-framed 4x12 cabinet. Deliberately NOT a replica
/// of any real, trademarked product — the swap seam is where a licensed model
/// goes. Palette tracks `RigTheme` so the 3D reads like the rest of the app.
enum ProceduralAmp {
    static func build(into root: SCNNode) {
        let tolex = UIColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)   // black cabinet
        let cream = UIColor(red: 0.92, green: 0.88, blue: 0.78, alpha: 1)   // faceplate
        let gold  = UIColor(red: 0.79, green: 0.63, blue: 0.29, alpha: 1)   // trim
        let amber = UIColor(red: 1.00, green: 0.60, blue: 0.18, alpha: 1)   // tube glow
        let cloth = UIColor(white: 0.045, alpha: 1)                         // grille baffle

        let tolexMat = pbr(tolex, metalness: 0.0, roughness: 0.85)
        let creamMat = pbr(cream, metalness: 0.55, roughness: 0.32)
        let goldMat  = pbr(gold,  metalness: 0.90, roughness: 0.28)
        let clothMat = pbr(cloth, metalness: 0.0,  roughness: 0.95)
        let knobMat  = pbr(UIColor(white: 0.10, alpha: 1), metalness: 0.2, roughness: 0.45)
        let coneMat  = pbr(UIColor(white: 0.16, alpha: 1), metalness: 0.1, roughness: 0.70)

        // ---- Amp head ----
        addBox(3.4, 1.15, 1.25, chamfer: 0.06, mat: tolexMat, at: (0, 1.0, 0), to: root)

        // Gold frame peeking around the cream faceplate.
        addBox(3.02, 0.56, 0.05, chamfer: 0.02, mat: goldMat, at: (0, 1.12, 0.61), to: root)
        // Cream faceplate (slightly proud of the head front).
        addBox(2.9, 0.44, 0.06, chamfer: 0.015, mat: creamMat, at: (0, 1.12, 0.63), to: root)

        // ---- Knobs, one per amp parameter, in a row on the faceplate ----
        let names = AmpScene.knobParamNames
        let span: Float = 2.5
        let step = names.count > 1 ? span / Float(names.count - 1) : 0
        for (i, name) in names.enumerated() {
            let knob = makeKnob(body: knobMat, pointer: amber)
            knob.name = AmpScene.knobNodeName(name)
            knob.position = SCNVector3(-span / 2 + Float(i) * step, 1.12, 0.68)
            root.addChildNode(knob)
        }

        // ---- Power lamp: emissive amber "tube glow" + a small warm light ----
        let lamp = SCNSphere(radius: 0.055)
        lamp.materials = [pbr(amber, metalness: 0.0, roughness: 0.3, emission: amber)]
        let lampNode = SCNNode(geometry: lamp)
        lampNode.position = SCNVector3(1.52, 1.12, 0.66)
        let glow = SCNLight()
        glow.type = .omni
        glow.color = amber
        glow.intensity = 55
        glow.attenuationEndDistance = 1.6
        lampNode.light = glow
        root.addChildNode(lampNode)

        // ---- Cabinet (4x12) ----
        addBox(3.7, 2.5, 1.45, chamfer: 0.05, mat: tolexMat, at: (0, -0.85, 0), to: root)
        // Gold border, then the dark baffle it frames.
        addBox(3.42, 2.22, 0.04, chamfer: 0.03, mat: goldMat,  at: (0, -0.85, 0.68), to: root)
        addBox(3.2, 2.02, 0.05, chamfer: 0.02, mat: clothMat, at: (0, -0.85, 0.70), to: root)

        // Four speaker cones (2x2) with dust caps.
        for sx in [-0.72, 0.72] as [Float] {
            for sy in [-0.35, -1.35] as [Float] {
                let cone = SCNCylinder(radius: 0.6, height: 0.05)
                cone.materials = [coneMat]
                let coneNode = SCNNode(geometry: cone)
                coneNode.eulerAngles.x = .pi / 2             // face forward (+Z)
                coneNode.position = SCNVector3(sx, sy, 0.73)
                root.addChildNode(coneNode)

                let cap = SCNSphere(radius: 0.13)
                cap.materials = [pbr(UIColor(white: 0.22, alpha: 1), metalness: 0.1, roughness: 0.5)]
                let capNode = SCNNode(geometry: cap)
                capNode.position = SCNVector3(sx, sy, 0.77)
                root.addChildNode(capNode)
            }
        }
    }

    // MARK: Builders

    /// A knob = a short forward-facing cylinder + a pointer notch, grouped so the
    /// group's Z rotation sweeps the pointer like a real dial.
    private static func makeKnob(body: SCNMaterial, pointer: UIColor) -> SCNNode {
        let group = SCNNode()

        let cyl = SCNCylinder(radius: 0.085, height: 0.06)
        cyl.materials = [body]
        let cylNode = SCNNode(geometry: cyl)
        cylNode.eulerAngles.x = .pi / 2                      // round face toward camera
        group.addChildNode(cylNode)

        let notch = SCNBox(width: 0.016, height: 0.06, length: 0.02, chamferRadius: 0)
        notch.materials = [pbr(pointer, metalness: 0.0, roughness: 0.4)]
        let notchNode = SCNNode(geometry: notch)
        notchNode.position = SCNVector3(0, 0.05, 0.035)      // near the top edge, on the face
        group.addChildNode(notchNode)

        return group
    }

    private static func addBox(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, chamfer: CGFloat,
                               mat: SCNMaterial, at p: (Float, Float, Float), to root: SCNNode) {
        let box = SCNBox(width: w, height: h, length: l, chamferRadius: chamfer)
        box.materials = [mat]
        let node = SCNNode(geometry: box)
        node.position = SCNVector3(p.0, p.1, p.2)
        root.addChildNode(node)
    }

    private static func pbr(_ color: UIColor, metalness: CGFloat, roughness: CGFloat,
                            emission: UIColor? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = metalness
        m.roughness.contents = roughness
        if let emission { m.emission.contents = emission }
        return m
    }
}

#Preview {
    AmpModel3DView(item: GearItem(name: "Amp Head", category: .amp,
                                  values: ["Gain": 8, "Bass": 6, "Mid": 3,
                                           "Treble": 7, "Presence": 5, "Master": 4]))
        .frame(width: 240, height: 200)
        .background(RigTheme.background)
        .preferredColorScheme(.dark)
}
