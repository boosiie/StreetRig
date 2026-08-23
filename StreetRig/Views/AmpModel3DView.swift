//
//  AmpModel3DView.swift
//  StreetRig
//
//  The rig stage's first piece of gear to graduate from flat vector art
//  (GearArtView) to a real-time, rotatable 3D model. Backed by SceneKit
//  (SCNView via UIViewRepresentable): drag to orbit, pinch to zoom. It sits
//  still at rest (no idle spin). With no bundled `.usdz` it builds a PROCEDURAL
//  stack from SceneKit primitives — and dresses it in the piece's own bespoke
//  2D artwork when it has any, mapping the PNG onto the front face and taking
//  the box proportions from the image so the drawing is never squashed. A piece
//  with no artwork falls back to the generic head + 4x12 cab, cream faceplate,
//  and a row of knobs (one per amp parameter) that turns live from
//  `GearItem.values`. Either way no real brand logo is baked into the geometry:
//  the shipped art is drawn under invented names.
//
//  Shared lighting/camera/shadow/material scaffolding lives in `Studio3D`.
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
import StreetRigEngine
import SceneKit
import UIKit

// MARK: - SwiftUI wrapper

/// A rotatable, PBR-lit 3D amp. Used only on the rig stage behind the feature
/// flag; the rest of the app keeps rendering `GearArtView`.
struct AmpModel3DView: UIViewRepresentable {
    /// The amp whose knobs drive the model (and whose `modelName` picks the asset).
    var item: GearItem?
    /// The cabinet under the head, so the lower box wears ITS artwork rather than
    /// the generic 4x12. `nil` (or a combo) leaves the cab generic.
    var cabinet: GearItem? = nil
    /// Fired on a single tap so the stage can zoom into the control overlay —
    /// preserving the tap-to-focus behavior the vector art had.
    var onTap: (() -> Void)? = nil

    /// Seconds per idle 360° turn. 0 = no idle drift (the amp rests facing front;
    /// the user still drags to orbit).
    private let idleSpinPeriod: Double = 0

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let scene = AmpScene.make(for: item, cabinet: cabinet, idleSpinPeriod: idleSpinPeriod)
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: false)

        view.backgroundColor = .clear            // blend onto the stage gradient
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.autoenablesDefaultLighting = false  // we supply lights + IBL
        view.allowsCameraControl = true          // free drag-orbit + pinch-zoom

        // Cache knob nodes once so per-update value changes are cheap.
        context.coordinator.cacheKnobs(in: scene, names: AmpScene.knobParamNames(for: item))

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

        func cacheKnobs(in scene: SCNScene, names: [String]) {
            knobs.removeAll()
            for name in names {
                knobs[name] = scene.rootNode.childNode(withName: AmpScene.knobNodeName(name),
                                                       recursively: true)
            }
        }

        /// Turn each knob to match its 0–10 value (−135°…+135°, like the 2D knobs).
        func apply(values: [String: Double]) {
            for (name, node) in knobs {
                node.eulerAngles.z = Studio3D.knobAngle(forValue: values[name] ?? 5)
            }
        }

        @objc func handleTap() { onTap?() }

        // Let the tap fire alongside SceneKit's built-in orbit/zoom recognizers.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

// MARK: - Scene assembly

/// Builds the SCNScene (procedural stand-in or bundled .usdz) for the amp and the
/// value→knob-angle wiring shared with the coordinator.
enum AmpScene {
    /// The amp faceplate knobs, in panel order — single source of truth is the
    /// data model, so the 3D knobs never drift from `GearItem.values`.
    ///
    /// PER ITEM, not per category: a Katana's faceplate carries Volume and three
    /// selectors the shared six do not, and a JC-120 has no Presence. Drawing the
    /// category's list would put the wrong knobs on the model — and, worse, cache
    /// knob nodes under names the item never sets, so they would sit frozen at
    /// noon. `knobParamNames` (no argument) stays as the fallback for the generic
    /// procedural head, which is built before any item is known.
    ///
    /// GROUPED controls are excluded: the Katana's five FX blocks are a panel
    /// SECTION, not faceplate knobs, and drawing fifteen more rotaries across a
    /// 3D amp face would turn a recognisable amp into a mixing desk.
    static func knobParamNames(for item: GearItem?) -> [String] {
        guard let item else { return knobParamNames }
        return item.parameters.filter { $0.group == nil }.map { $0.name }
    }
    static let knobParamNames: [String] = GearCategory.amp.parameters.map { $0.name }

    static func knobNodeName(_ param: String) -> String { "knob_\(param)" }

    /// Build the scene for `item`: a bundled `.usdz` if one resolves, otherwise
    /// the procedural stand-in — dressed in the piece's bespoke 2D art when it
    /// has any. This is the asset swap seam, and it is the SAME three-step chain
    /// the rig diorama uses (see `RigDiorama.make`):
    ///   1. custom `.usdz`          — `GearModelLoader` (modelName → slug → category)
    ///   2. art-textured procedural — the piece's `<slug>.imageset` on the boxes
    ///   3. plain procedural        — the generic head + 4x12
    static func make(for item: GearItem?, cabinet: GearItem? = nil,
                     idleSpinPeriod: Double) -> SCNScene {
        let scene = SCNScene()
        let ampRoot = SCNNode()
        ampRoot.name = "ampRoot"

        if let loaded = GearModelLoader.modelNode(for: item) {
            ampRoot.addChildNode(loaded)
        } else {
            ProceduralAmp.build(into: ampRoot, amp: item, cabinet: cabinet)
        }
        scene.rootNode.addChildNode(ampRoot)

        Studio3D.addLighting(to: scene)
        Studio3D.addCamera(to: scene, position: SCNVector3(0, 0.15, 8.4), tilt: -0.045, fov: 34)
        Studio3D.addContactShadow(to: scene.rootNode, width: 5.4, height: 3.4,
                                  at: SCNVector3(0, -2.14, 0.15))

        if idleSpinPeriod > 0 {
            let spin = SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: idleSpinPeriod)
            ampRoot.runAction(.repeatForever(spin))
        }
        return scene
    }

    /// The documented drop-in point for a real, vetted model. Returns the loaded
    /// model's nodes, or nil if the named asset isn't bundled — in which case
    /// the caller falls back to the procedural stand-in.
    static func load(usdzNamed name: String) -> SCNNode? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "usdz"),
              let scene = try? SCNScene(url: url) else { return nil }
        let holder = SCNNode()
        for child in scene.rootNode.childNodes { holder.addChildNode(child) }
        return holder
    }
}

// MARK: - Procedural amp (art-textured when the piece has an icon, generic otherwise)

/// Assembles the head + cabinet stack from SceneKit primitives, in one of two
/// dresses:
///
///  • **Art-textured** — when the amp (and/or the cabinet) resolves a bespoke
///    icon through `GearIconLoader`, that PNG is mapped onto the box's FRONT
///    face and the box's own width/height come from the image's pixel size, so
///    the drawing is never squashed to fit a box it wasn't drawn for. Sides,
///    back, top and bottom stay tolex, so the piece still reads as a solid
///    object when the diorama is orbited. This is what every piece the app
///    ships now looks like.
///
///  • **Generic** — the original stand-in: a head with a gold-framed cream
///    faceplate and a live row of knobs, on a gold-framed 4x12. Deliberately
///    NOT a replica of any real, trademarked product. It is the fallback for a
///    name with no matching asset, and it is what `ModelExporter` bakes as the
///    editable `.usdz` baseline — so its exact box sizes are load-bearing and
///    are kept verbatim (see `Layout.generic`).
///
/// Palette tracks `RigTheme` so the 3D reads like the rest of the app.
enum ProceduralAmp {

    // MARK: Palette

    private static let tolex = UIColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)  // black cabinet
    private static let cream = UIColor(red: 0.92, green: 0.88, blue: 0.78, alpha: 1)  // faceplate
    private static let gold  = UIColor(red: 0.79, green: 0.63, blue: 0.29, alpha: 1)  // trim
    private static let jewel = UIColor(red: 0.86, green: 0.11, blue: 0.11, alpha: 1)  // red power jewel
    private static let point = UIColor(white: 0.90, alpha: 1)                         // off-white knob pointer
    private static let cloth = UIColor(white: 0.045, alpha: 1)                        // grille baffle

    private static var tolexMat: SCNMaterial { Studio3D.pbr(tolex, metalness: 0.0, roughness: 0.82) }
    private static var creamMat: SCNMaterial { Studio3D.pbr(cream, metalness: 0.5,  roughness: 0.35) }
    private static var goldMat:  SCNMaterial { Studio3D.pbr(gold,  metalness: 0.9,  roughness: 0.34) }  // satin brass (not a mirror)
    private static var clothMat: SCNMaterial { Studio3D.pbr(cloth, metalness: 0.0,  roughness: 0.95) }
    private static var knobMat:  SCNMaterial { Studio3D.pbr(UIColor(white: 0.10, alpha: 1), metalness: 0.2, roughness: 0.45) }
    private static var coneMat:  SCNMaterial { Studio3D.pbr(UIColor(white: 0.16, alpha: 1), metalness: 0.1, roughness: 0.70) }

    // MARK: Entry points

    /// The generic stack, with no gear attached — what `ModelExporter` bakes.
    static func build(into root: SCNNode) { build(into: root, amp: nil, cabinet: nil) }

    /// The stack for a specific amp + cabinet, art-textured where art exists.
    ///
    /// KNOB COLLISION, resolved: the head art already has that amp's real knob
    /// row drawn on it — six on the JCM800's gold panel, nine along the bottom
    /// of the Dual Rectifier — so adding the procedural knob nodes on top would
    /// give every art-textured head TWO sets of knobs, in different places, at
    /// different sizes. There is no per-amp knob geometry to align to (the rows
    /// genuinely differ per model), so the live knobs are DROPPED on the art
    /// path and kept on the generic one. The cost is real and deliberate: the
    /// head's 3D knobs no longer turn with `GearItem.values` while you look at
    /// the diorama. Adjusting them still works — tapping the amp flies the
    /// camera in and opens `ComponentDetailView`, whose knobs and sliders are
    /// the actual control surface — but the at-a-glance readout is gone.
    static func build(into root: SCNNode, amp: GearItem?, cabinet: GearItem?) {
        // A combo is amp and speaker in ONE box, so it gets one box — not a
        // head sitting on a cab. There is no cabinet item to consult: for a
        // combo rig `RigStore.cabinetItem` is nil by construction.
        if amp?.category == .comboAmp {
            let art = GearIconLoader.uiImage(for: amp)
            addCombo(Layout.forCombo(art: art), art: art, to: root)
            return
        }

        let headArt = GearIconLoader.uiImage(for: amp)
        let cabArt  = GearIconLoader.uiImage(for: cabinet)
        let layout  = Layout.forStack(headArt: headArt, cabArt: cabArt)

        addHead(layout.head, art: headArt, knobNames: AmpScene.knobParamNames(for: amp), to: root)
        addCabinet(layout.cab, art: cabArt, to: root)
    }

    // MARK: Layout

    /// One box of the stack, in the amp root's local space (x centred on 0).
    struct Box {
        var width: Float, height: Float, depth: Float, centerY: Float
        var frontZ: Float { depth / 2 }
    }

    /// Where the two boxes sit. The stack always spans the same vertical
    /// envelope — bottom on the floor at `floorY`, top at `floorY + span` —
    /// because the diorama's camera framing, contact shadows and `ampRoot`
    /// offset are all composed around that height. What the ART changes is the
    /// stack's WIDTH: a common width is solved for so that the two drawn aspect
    /// ratios add up to exactly that height budget. Honouring both aspects makes
    /// the stack narrower than the generic one — which is simply what the
    /// artwork is, drawn stacked (512 × 835 px ≈ 0.61, the same as ours).
    enum Layout {
        static let floorY: Float = -2.10        // cabinet bottom rests here
        static let gap: Float = 0.025           // sliver of daylight above the cab
        static let span: Float = 3.675          // cab bottom → head top

        /// The generic boxes, verbatim from the original build. Kept exact: they
        /// are the baseline `ModelExporter` bakes and that `CUSTOMIZING-GEAR.md`
        /// tells a designer to author their `.usdz` against.
        static let genericHead = Box(width: 3.4, height: 1.15, depth: 1.25, centerY: 1.0)
        static let genericCab  = Box(width: 3.7, height: 2.5,  depth: 1.45, centerY: -0.85)

        /// A combo's height budget. It is deliberately NOT the full `span`: a
        /// combo is one box, and standing it as tall as a half-stack would read
        /// as a mislabelled cabinet. Real proportions are roughly a third of a
        /// stack's height at nearly its full width; a third looks lost on the
        /// stage, so this splits the difference and keeps the amp substantial.
        static let comboSpan: Float = span * 0.55

        /// The generic combo, used when a combo has no artwork — squat and a
        /// little wider than tall, the shape of a 2x12 combo.
        static let genericCombo = Box(width: 2.62, height: comboSpan, depth: 1.32,
                                      centerY: floorY + comboSpan / 2)

        /// One box, sized from the drawing but held to `comboSpan` so every
        /// combo stands at a consistent height whatever its aspect.
        static func forCombo(art: UIImage?) -> Box {
            guard let a = aspect(art) else { return genericCombo }
            let height = comboSpan
            let width  = height * a
            let k = width / genericCombo.width       // depth tracks width, as in the stack
            return Box(width: width, height: height, depth: genericCombo.depth * k,
                       centerY: floorY + height / 2)
        }

        static func forStack(headArt: UIImage?, cabArt: UIImage?) -> (head: Box, cab: Box) {
            guard headArt != nil || cabArt != nil else { return (genericHead, genericCab) }

            // Aspect of the drawing, or of the generic box when a piece has none
            // (a mixed stack: art on one, fallback on the other).
            let aHead = aspect(headArt) ?? genericHead.width / genericHead.height
            let aCab  = aspect(cabArt)  ?? genericCab.width  / genericCab.height

            // Solve the shared width from the height budget: h = w/a for each box.
            let width = (span - gap) / (1 / aHead + 1 / aCab)
            let headH = width / aHead, cabH = width / aCab
            // Depth scales with width so a narrower stack doesn't read as a slab.
            let k = width / genericCab.width

            let cab = Box(width: width, height: cabH, depth: genericCab.depth * k,
                          centerY: floorY + cabH / 2)
            let head = Box(width: width, height: headH, depth: genericHead.depth * k,
                           centerY: floorY + cabH + gap + headH / 2)
            return (head, cab)
        }

        /// Width ÷ height of an asset-catalog image. `UIImage.size` is in points
        /// (pixels ÷ scale), so the ratio is resolution-independent either way.
        private static func aspect(_ image: UIImage?) -> Float? {
            guard let image, image.size.height > 0 else { return nil }
            return Float(image.size.width / image.size.height)
        }
    }

    // MARK: Pieces

    private static func addHead(_ box: Box, art: UIImage?, knobNames: [String], to root: SCNNode) {
        if let art {
            addArtBox(box, art: art, to: root)
            return          // knobs, faceplate and jewel are all drawn IN the art
        }

        Studio3D.addBox(CGFloat(box.width), CGFloat(box.height), CGFloat(box.depth),
                        chamfer: 0.06, mat: tolexMat, at: SCNVector3(0, box.centerY, 0), to: root)

        // Everything below is expressed as a fraction of the head box, so the
        // generic head still measures 3.4 × 1.15 while a fitted one stays in
        // proportion. The panel sits a little above the box's centre.
        let panelY = box.centerY + box.height * 0.104
        let z = box.frontZ

        // Gold frame peeking around the cream faceplate.
        Studio3D.addBox(CGFloat(box.width * 0.888), CGFloat(box.height * 0.487), 0.05,
                        chamfer: 0.02, mat: goldMat, at: SCNVector3(0, panelY, z - 0.015), to: root)
        // Cream faceplate (slightly proud of the head front).
        Studio3D.addBox(CGFloat(box.width * 0.853), CGFloat(box.height * 0.383), 0.06,
                        chamfer: 0.015, mat: creamMat, at: SCNVector3(0, panelY, z + 0.005), to: root)

        // ---- Knobs, one per amp parameter, in a row on the faceplate ----
        let names = knobNames
        let span = box.width * 0.735
        let step = names.count > 1 ? span / Float(names.count - 1) : 0
        let knobScale = box.height / Layout.genericHead.height
        for (i, name) in names.enumerated() {
            let knob = makeKnob(body: knobMat, pointer: point)
            knob.name = AmpScene.knobNodeName(name)
            knob.scale = SCNVector3(knobScale, knobScale, knobScale)
            knob.position = SCNVector3(-span / 2 + Float(i) * step, panelY, z + 0.055)
            root.addChildNode(knob)
        }

        // ---- Power jewel: a small dim-red indicator — no light cast, no bloom wash ----
        let jewelDim = UIColor(red: 0.45, green: 0.02, blue: 0.02, alpha: 1)
        let lamp = SCNSphere(radius: CGFloat(0.045 * knobScale))
        lamp.materials = [Studio3D.pbr(jewel, metalness: 0.0, roughness: 0.35, emission: jewelDim)]
        let lampNode = SCNNode(geometry: lamp)
        lampNode.position = SCNVector3(box.width * 0.447, panelY, z + 0.035)
        root.addChildNode(lampNode)
    }

    private static func addCabinet(_ box: Box, art: UIImage?, to root: SCNNode) {
        if let art {
            addArtBox(box, art: art, to: root)
            return          // grille, border and cones are all drawn IN the art
        }

        Studio3D.addBox(CGFloat(box.width), CGFloat(box.height), CGFloat(box.depth),
                        chamfer: 0.05, mat: tolexMat, at: SCNVector3(0, box.centerY, 0), to: root)
        let z = box.frontZ

        // Gold border, then the dark baffle it frames.
        Studio3D.addBox(CGFloat(box.width * 0.924), CGFloat(box.height * 0.888), 0.04,
                        chamfer: 0.03, mat: goldMat, at: SCNVector3(0, box.centerY, z - 0.045), to: root)
        Studio3D.addBox(CGFloat(box.width * 0.865), CGFloat(box.height * 0.808), 0.05,
                        chamfer: 0.02, mat: clothMat, at: SCNVector3(0, box.centerY, z - 0.025), to: root)

        // Four speaker cones (2x2) with dust caps.
        for sx in [-box.width * 0.195, box.width * 0.195] {
            for sy in [box.centerY + box.height * 0.2, box.centerY - box.height * 0.2] {
                let cone = SCNCylinder(radius: CGFloat(box.width * 0.162), height: 0.05)
                cone.materials = [coneMat]
                let coneNode = SCNNode(geometry: cone)
                coneNode.eulerAngles.x = .pi / 2             // face forward (+Z)
                coneNode.position = SCNVector3(sx, sy, z + 0.005)
                root.addChildNode(coneNode)

                let cap = SCNSphere(radius: CGFloat(box.width * 0.035))
                cap.materials = [Studio3D.pbr(UIColor(white: 0.22, alpha: 1), metalness: 0.1, roughness: 0.5)]
                let capNode = SCNNode(geometry: cap)
                capNode.position = SCNVector3(sx, sy, z + 0.045)
                root.addChildNode(capNode)
            }
        }
    }

    /// A combo: one box, grille below and a control panel across the top, which
    /// is what separates it at a glance from a cabinet of the same silhouette.
    /// Art path is identical to the other two pieces — the drawing already has
    /// the grille, the panel and the knobs on it.
    private static func addCombo(_ box: Box, art: UIImage?, to root: SCNNode) {
        if let art {
            addArtBox(box, art: art, to: root)
            return
        }

        Studio3D.addBox(CGFloat(box.width), CGFloat(box.height), CGFloat(box.depth),
                        chamfer: 0.05, mat: tolexMat, at: SCNVector3(0, box.centerY, 0), to: root)
        let z = box.frontZ

        // Control panel across the top third, then the grille below it.
        let panelY = box.centerY + box.height * 0.34
        Studio3D.addBox(CGFloat(box.width * 0.88), CGFloat(box.height * 0.2), 0.05,
                        chamfer: 0.02, mat: creamMat, at: SCNVector3(0, panelY, z + 0.005), to: root)

        let grilleY = box.centerY - box.height * 0.12
        Studio3D.addBox(CGFloat(box.width * 0.9), CGFloat(box.height * 0.56), 0.04,
                        chamfer: 0.03, mat: goldMat, at: SCNVector3(0, grilleY, z - 0.045), to: root)
        Studio3D.addBox(CGFloat(box.width * 0.845), CGFloat(box.height * 0.5), 0.05,
                        chamfer: 0.02, mat: clothMat, at: SCNVector3(0, grilleY, z - 0.025), to: root)

        // Two speakers side by side — a combo, not a 4x12.
        for sx in [-box.width * 0.2, box.width * 0.2] {
            let cone = SCNCylinder(radius: CGFloat(box.width * 0.16), height: 0.05)
            cone.materials = [coneMat]
            let coneNode = SCNNode(geometry: cone)
            coneNode.eulerAngles.x = .pi / 2             // face forward (+Z)
            coneNode.position = SCNVector3(sx, grilleY, z + 0.005)
            root.addChildNode(coneNode)

            let cap = SCNSphere(radius: CGFloat(box.width * 0.035))
            cap.materials = [Studio3D.pbr(UIColor(white: 0.22, alpha: 1), metalness: 0.1, roughness: 0.5)]
            let capNode = SCNNode(geometry: cap)
            capNode.position = SCNVector3(sx, grilleY, z + 0.045)
            root.addChildNode(capNode)
        }
    }

    /// A box wearing the piece's artwork on its front face and tolex everywhere
    /// else. `SCNBox` takes its six materials in the order front, right, back,
    /// left, top, bottom — no chamfer, because a chamfered box does not map that
    /// six-slot order predictably and a mis-slotted face would put the drawing on
    /// the amp's side.
    private static func addArtBox(_ box: Box, art: UIImage, to root: SCNNode) {
        let geometry = SCNBox(width: CGFloat(box.width), height: CGFloat(box.height),
                              length: CGFloat(box.depth), chamferRadius: 0)
        let sides = tolexMat
        geometry.materials = [artMaterial(art), sides, sides, sides, sides, sides]
        let node = SCNNode(geometry: geometry)
        node.position = SCNVector3(0, box.centerY, 0)
        root.addChildNode(node)
    }

    /// The front-face material for a piece of artwork.
    ///
    /// The PNGs have TRANSPARENT backgrounds, which SceneKit would render as a
    /// hole straight through into the box's interior — a translucent amp. So the
    /// drawing is flattened onto the tolex colour first: the margins then read as
    /// the cabinet's own edge, continuous with the four tolex sides, instead of a
    /// window. PBR (not `.constant`) so the piece still takes the studio key
    /// light and sits in the same room as the pedals and the guitar.
    private static func artMaterial(_ image: UIImage) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = flattened(image, onto: tolex)
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.metalness.contents = 0.0
        m.roughness.contents = 0.78
        return m
    }

    /// Composite `image` over an opaque `backing` — i.e. discard the alpha.
    private static func flattened(_ image: UIImage, onto backing: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = image.scale
        let rect = CGRect(origin: .zero, size: image.size)
        return UIGraphicsImageRenderer(size: image.size, format: format).image { ctx in
            backing.setFill()
            ctx.fill(rect)
            image.draw(in: rect)
        }
    }

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
        notch.materials = [Studio3D.pbr(pointer, metalness: 0.0, roughness: 0.4)]
        let notchNode = SCNNode(geometry: notch)
        notchNode.position = SCNVector3(0, 0.05, 0.035)      // near the top edge, on the face
        group.addChildNode(notchNode)

        return group
    }
}

#Preview {
    AmpModel3DView(item: GearItem(name: "Marswell JCM800 2203", category: .amp,
                                  values: ["Gain": 8, "Bass": 6, "Mid": 3,
                                           "Treble": 7, "Presence": 5, "Master": 4]),
                   cabinet: GearItem(name: "Marswell 1960A 4x12", category: .cabinet))
        .frame(width: 240, height: 200)
        .background(RigTheme.background)
        .preferredColorScheme(.dark)
}
