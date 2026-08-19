//
//  PedalModel3DView.swift
//  StreetRig
//
//  The rig stage's pedalboard in 3D: every owned pedal as a PBR-lit stompbox on
//  a slightly-raked board, all in a SINGLE SceneKit view (one renderer for the
//  whole board, not one per pedal — see research/3d-amp-rendering-options.md).
//  Enclosure colors, knob counts, and LED colors mirror the vector `PedalArt`
//  so a Tube Screamer still reads green, a Distortion orange, a tuner white, etc.
//  Tap a pedal (hit-tested by node name) to open its control overlay. Gated by
//  `FeatureFlags.amp3D` alongside the 3D amp; every other surface stays vector.
//

import SwiftUI
import StreetRigEngine
import SceneKit
import UIKit

// MARK: - SwiftUI wrapper

struct PedalboardModel3DView: UIViewRepresentable {
    /// The pedals on the board, in signal-chain order.
    var pedals: [GearItem]
    /// Fired with the tapped pedal's id so the stage can zoom into its controls.
    var onTapPedal: ((UUID) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTapPedal) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = PedalboardScene.make(pedals: pedals)
        view.pointOfView = view.scene?.rootNode.childNode(withName: "camera", recursively: false)
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = false        // fixed 3/4 board view; taps only

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)

        context.coordinator.view = view
        context.coordinator.builtIds = pedals.map(\.id)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onTap = onTapPedal
        // Rebuild only when the set of pedals changes (added / removed / reordered).
        let ids = pedals.map(\.id)
        if context.coordinator.builtIds != ids {
            let scene = PedalboardScene.make(pedals: pedals)
            view.scene = scene
            view.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: false)
            context.coordinator.builtIds = ids
        }
    }

    // MARK: Coordinator — hit-tests taps to the pedal under the finger

    final class Coordinator: NSObject {
        var onTap: ((UUID) -> Void)?
        weak var view: SCNView?
        var builtIds: [UUID] = []

        init(onTap: ((UUID) -> Void)?) { self.onTap = onTap }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let view else { return }
            let p = g.location(in: view)
            let hits = view.hitTest(p, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
            for hit in hits {
                var node: SCNNode? = hit.node
                while let n = node {                 // walk up to the pedal group
                    if let name = n.name, name.hasPrefix("pedal_"),
                       let id = UUID(uuidString: String(name.dropFirst("pedal_".count))) {
                        onTap?(id)
                        return
                    }
                    node = n.parent
                }
            }
        }
    }
}

// MARK: - Scene assembly

enum PedalboardScene {
    /// Board + pedals as one flat node (pedals standing on top, no rake). Reused
    /// by the standalone pedalboard view and by the combined rig diorama.
    static func boardNode(pedals: [GearItem]) -> SCNNode {
        let root = SCNNode()
        root.name = "boardRoot"

        let count = max(pedals.count, 1)
        let spacing: Float = 1.5
        let width = boardWidth(pedalCount: pedals.count)

        // The board the pedals sit on — thin, just wider than the pedals.
        let board = SCNBox(width: width, height: 0.16, length: 1.5, chamferRadius: 0.06)
        board.materials = [Studio3D.pbr(UIColor(white: 0.12, alpha: 1), metalness: 0.25, roughness: 0.7)]
        let boardGeo = SCNNode(geometry: board)
        boardGeo.position = SCNVector3(0, -0.08, 0)
        root.addChildNode(boardGeo)

        // Pedals stand on top of the board, in a centered row.
        let startX = -Float(count - 1) * spacing / 2
        for (i, pedal) in pedals.enumerated() {
            // Custom <slug>.usdz for this pedal, else the procedural stompbox.
            let node = GearModelLoader.modelNode(for: pedal) ?? ProceduralPedal.build(for: pedal)
            node.name = "pedal_\(pedal.id.uuidString)"
            node.position = SCNVector3(startX + Float(i) * spacing, 0, 0.02)
            root.addChildNode(node)
        }
        return root
    }

    static func boardWidth(pedalCount: Int) -> CGFloat {
        CGFloat(Float(max(pedalCount, 1) - 1) * 1.5 + 1.7)
    }

    /// Local x of the slot AFTER the last pedal — where a new one would land.
    /// An empty board has no row to sit beside, so the slot takes the middle.
    static func nextSlotX(pedalCount: Int) -> Float {
        guard pedalCount > 0 else { return 0 }
        let spacing: Float = 1.5
        return -Float(pedalCount - 1) * spacing / 2 + Float(pedalCount) * spacing
    }

    /// The "drop a pedal here" marker that sits beside the board.
    ///
    /// It exists because a pedal dragged onto the stage could only ever REPLACE
    /// the pedal nearest the finger — with a board already occupied there was no
    /// point on screen that meant "and one more", so a fourth pedal was
    /// unreachable. This is that point, and it has to be visible to be usable.
    ///
    /// Unlit and billboarded: it is an instruction rather than a piece of gear, so
    /// it should read identically from every angle the stage can be orbited to,
    /// and should not pick up the studio lighting that makes the real models look
    /// like objects.
    static func addSlotNode() -> SCNNode {
        let container = SCNNode()
        container.name = addSlotName
        container.constraints = [SCNBillboardConstraint()]

        let plane = SCNPlane(width: 1.7, height: 1.7)
        let m = SCNMaterial()
        m.diffuse.contents = addSlotImage()
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        plane.materials = [m]

        let face = SCNNode(geometry: plane)
        face.name = addSlotFaceName
        face.renderingOrder = 20          // in front of the board, never buried in it
        container.addChildNode(face)
        return container
    }

    static let addSlotName = "addPedalSlot"
    static let addSlotFaceName = "addPedalSlotFace"

    /// A dashed amber square with a plus through it. Amber because on this stage
    /// amber already means "let go here and it lands" — the same thing the glow on
    /// a hovered pedal means. Red is the bin, and must not appear next to it.
    private static func addSlotImage() -> UIImage {
        let side: CGFloat = 256
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            let c = ctx.cgContext
            let amber = UIColor(red: 0.878, green: 0.400, blue: 0.118, alpha: 1)
            let inset: CGFloat = 26
            let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)

            c.setStrokeColor(amber.withAlphaComponent(0.9).cgColor)
            c.setLineWidth(7)
            c.setLineDash(phase: 0, lengths: [17, 13])
            c.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 26).cgPath)
            c.strokePath()

            c.setLineDash(phase: 0, lengths: [])
            c.setLineCap(.round)
            c.setLineWidth(15)
            c.setStrokeColor(amber.cgColor)
            let mid = side / 2, arm: CGFloat = 42
            c.move(to: CGPoint(x: mid - arm, y: mid));  c.addLine(to: CGPoint(x: mid + arm, y: mid))
            c.move(to: CGPoint(x: mid, y: mid - arm));  c.addLine(to: CGPoint(x: mid, y: mid + arm))
            c.strokePath()
        }
    }

    static func make(pedals: [GearItem]) -> SCNScene {
        let scene = SCNScene()
        let root = boardNode(pedals: pedals)
        root.eulerAngles.x = -0.30                    // slight rake for the standalone view
        scene.rootNode.addChildNode(root)

        let width = boardWidth(pedalCount: pedals.count)
        Studio3D.addLighting(to: scene)
        Studio3D.addContactShadow(to: scene.rootNode, width: width + 1.0, height: 2.0,
                                  at: SCNVector3(0, -0.42, 0.2))
        // Front-above 3/4 view; distance widens with the row so it always fits.
        let dist = Float(width) * 0.46 + 3.0
        Studio3D.addCamera(to: scene, position: SCNVector3(0, 1.55, dist), tilt: -0.46, fov: 46)
        return scene
    }
}

// MARK: - Procedural stompbox (generic, colored per pedal)

enum ProceduralPedal {
    static func build(for pedal: GearItem) -> SCNNode {
        let group = SCNNode()
        let spec = spec(for: pedal)

        // ---- Enclosure ----
        let bodyMat = Studio3D.pbr(spec.color, metalness: 0.35, roughness: 0.42)
        let body = SCNBox(width: 1.1, height: 0.42, length: 1.45, chamferRadius: 0.05)
        body.materials = [bodyMat]
        let bodyNode = SCNNode(geometry: body)
        bodyNode.position = SCNVector3(0, 0.21, 0)
        group.addChildNode(bodyNode)

        // ---- Knobs across the top (near the back edge) ----
        let knobMat = Studio3D.pbr(UIColor(white: 0.85, alpha: 1), metalness: 0.1, roughness: 0.5)
        let pointerMat = Studio3D.pbr(.black, metalness: 0, roughness: 0.5)
        let n = max(1, spec.knobs)
        let span: Float = min(0.72, Float(n) * 0.26)
        let step = n > 1 ? span / Float(n - 1) : 0
        for i in 0..<n {
            let knob = SCNCylinder(radius: 0.1, height: 0.11)
            knob.materials = [knobMat]
            let kn = SCNNode(geometry: knob)
            kn.position = SCNVector3(-span / 2 + Float(i) * step, 0.47, -0.42)
            group.addChildNode(kn)

            let ptr = SCNBox(width: 0.018, height: 0.12, length: 0.05, chamferRadius: 0)
            ptr.materials = [pointerMat]
            let pn = SCNNode(geometry: ptr)
            pn.position = SCNVector3(0, 0.005, 0.045)
            kn.addChildNode(pn)
        }

        // ---- Status LED (small emissive dot; no glow wash) ----
        let led = SCNSphere(radius: 0.045)
        led.materials = [Studio3D.pbr(spec.led, metalness: 0, roughness: 0.3, emission: spec.led)]
        let ledNode = SCNNode(geometry: led)
        ledNode.position = SCNVector3(0, 0.44, 0.08)
        group.addChildNode(ledNode)

        // ---- Footswitch (front, chrome) ----
        let fs = SCNCylinder(radius: 0.14, height: 0.12)
        fs.materials = [Studio3D.pbr(UIColor(white: 0.62, alpha: 1), metalness: 0.85, roughness: 0.28)]
        let fsNode = SCNNode(geometry: fs)
        fsNode.position = SCNVector3(0, 0.47, 0.48)
        group.addChildNode(fsNode)

        return group
    }

    // MARK: Per-pedal look (mirrors GearArt's PedalArt spec)

    private struct PedalSpec { var color: UIColor; var knobs: Int; var led: UIColor }

    private static func spec(for pedal: GearItem) -> PedalSpec {
        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
            UIColor(red: r, green: g, blue: b, alpha: 1)
        }
        let amber = c(1.0, 0.72, 0.2)
        let green = c(0.3, 0.9, 0.35)
        let n = pedal.name.lowercased()

        if n.contains("tube screamer") { return .init(color: c(0.36, 0.55, 0.20), knobs: 3, led: amber) }
        if n.contains("big muff")      { return .init(color: c(0.85, 0.84, 0.80), knobs: 3, led: amber) }
        if n.contains("dyna")          { return .init(color: c(0.70, 0.16, 0.14), knobs: 2, led: amber) }
        if n.contains("phase")         { return .init(color: c(0.92, 0.46, 0.09), knobs: 1, led: amber) }
        if n.contains("distortion")    { return .init(color: c(0.93, 0.50, 0.10), knobs: 3, led: amber) }
        if n.contains("metal zone")    { return .init(color: c(0.20, 0.20, 0.22), knobs: 4, led: amber) }
        if n.contains("procon rat")    { return .init(color: c(0.18, 0.18, 0.20), knobs: 3, led: amber) }
        if n.contains("centaur")       { return .init(color: c(0.62, 0.14, 0.13), knobs: 3, led: amber) }
        if n.contains("king of tone")  { return .init(color: c(0.62, 0.44, 0.76), knobs: 4, led: amber) }
        if n.contains("memory man")    { return .init(color: c(0.15, 0.15, 0.17), knobs: 3, led: amber) }
        if n.contains("loop station")  { return .init(color: c(0.80, 0.13, 0.13), knobs: 1, led: green) }
        if n.contains("chromatic tuner") { return .init(color: c(0.88, 0.88, 0.86), knobs: 1, led: green) }

        switch pedal.category {
        case .delay:      return .init(color: c(0.20, 0.45, 0.30), knobs: 3, led: amber)
        case .reverb:     return .init(color: c(0.10, 0.44, 0.48), knobs: 3, led: amber)
        case .modulation: return .init(color: c(0.16, 0.40, 0.70), knobs: 2, led: amber)
        case .compressor: return .init(color: c(0.70, 0.16, 0.14), knobs: 2, led: amber)
        case .tuner:      return .init(color: c(0.62, 0.64, 0.66), knobs: 1, led: green)
        case .eq:         return .init(color: c(0.62, 0.64, 0.66), knobs: 3, led: amber)
        case .pitch:      return .init(color: c(0.16, 0.40, 0.70), knobs: 2, led: amber)
        case .looper:     return .init(color: c(0.88, 0.88, 0.86), knobs: 1, led: green)
        default:          return .init(color: c(0.30, 0.30, 0.32), knobs: 2, led: amber)
        }
    }
}

#Preview {
    PedalboardModel3DView(pedals: [
        GearItem(name: "Ibonez Tube Screamer", category: .overdrive),
        GearItem(name: "VOSS Digital Delay", category: .delay),
        GearItem(name: "VOSS Reverb", category: .reverb),
    ])
    .frame(width: 320, height: 150)
    .background(RigTheme.background)
    .preferredColorScheme(.dark)
}
