//
//  PedalModel3DView.swift
//  StreetRig
//
//  The rig stage's pedalboard in 3D: every owned pedal as a PBR-lit enclosure on
//  a slightly-raked board, all in a SINGLE SceneKit view (one renderer for the
//  whole board, not one per pedal — see research/3d-amp-rendering-options.md).
//  Each pedal picks an ENCLOSURE ARCHETYPE from its name and category (see
//  PedalArchetypes3D) so a wah is a hinged rocker, a Brig compact wears its
//  tread plate and a FuzzDome is round; colors and LED colors still mirror the
//  vector `PedalArt` so a ValveShrieker reads green and a tuner white either way.
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
        // A `Position` change is a value change, not a gear change — same
        // distinction the amp's knobs make. Move the treadle in place.
        if let root = view.scene?.rootNode {
            PedalboardScene.applyTreadles(pedals, in: root)
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

    // MARK: Row layout

    /// Where a row of pedals actually goes.
    ///
    /// THIS USED TO BE THREE CONSTANTS AND IT NO LONGER CAN BE. The row was a
    /// fixed 1.5 stride with the board sized from the pedal COUNT, both of which
    /// silently assumed every pedal was 1.1 wide. Once a wah (1.2 × 2.5) and a
    /// 1590BB (1.56 wide) are real shapes, a fixed stride means pedals growing
    /// through their neighbours and hanging off the front edge of the board. So
    /// one function derives the whole layout from the archetypes' own footprints
    /// — pedal centres, board size, and the add-slot position together, because
    /// those three only agree by construction.
    struct BoardLayout {
        /// Local x of each pedal, in signal-chain order.
        var centers: [Float]
        var width: CGFloat
        var length: CGFloat
        /// Local x of the slot AFTER the last pedal — where a new one would land.
        var nextSlotX: Float
    }

    /// Air between adjacent pedals. 0.40 is exactly what the old 1.5 stride left
    /// between two 1.1-wide boxes, so a board of plain compacts still lays out
    /// pixel-for-pixel as it did before archetypes existed.
    private static let pedalGap: Float = 0.40
    /// Board overhang past the outermost pedal, per side.
    private static let boardMargin: Float = 0.30
    /// Overhang front and back. Tighter than the sides on purpose: the board is
    /// seen from a low 3/4 angle, so depth it doesn't need reads as empty floor.
    private static let boardDepthMargin: Float = 0.10

    /// Footprints come from the archetype spec, not from the built node, because
    /// `nextSlotX` is needed by the diorama before any pedal is built. A designer's
    /// bespoke `.usdz` is therefore laid out at ITS archetype's footprint — which
    /// is what CUSTOMIZING-GEAR.md already asks them to author against.
    static func layout(for pedals: [GearItem]) -> BoardLayout {
        let sizes = pedals.map { ProceduralPedal.footprint(for: $0) }
        let widths = sizes.map { Float($0.width) }
        let total = widths.reduce(0, +) + pedalGap * Float(max(widths.count - 1, 0))

        var centers: [Float] = []
        var cursor = -total / 2
        for w in widths {
            centers.append(cursor + w / 2)
            cursor += w + pedalGap
        }

        let reference = Float(ProceduralPedal.referenceWidth)
        let width = CGFloat(max(total, reference) + boardMargin * 2)
        let deepest = sizes.map { Float($0.length) }.max() ?? 0
        let length = CGFloat(max(deepest + boardDepthMargin * 2, 1.5))

        // The slot marks where ONE MORE standard pedal would land — not where the
        // last pedal's own width happens to end, so the marker sits the same
        // distance out whether the row ends in a compact or a wah.
        let next: Float = centers.isEmpty ? 0
            : (centers[centers.count - 1] + widths[widths.count - 1] / 2 + pedalGap + reference / 2)

        return BoardLayout(centers: centers, width: width, length: length, nextSlotX: next)
    }

    /// Board + pedals as one flat node (pedals standing on top, no rake). Reused
    /// by the standalone pedalboard view and by the combined rig diorama.
    static func boardNode(pedals: [GearItem]) -> SCNNode {
        let root = SCNNode()
        root.name = "boardRoot"
        let row = layout(for: pedals)

        // The board the pedals sit on — thin, just bigger than what's on it.
        let board = SCNBox(width: row.width, height: 0.16, length: row.length, chamferRadius: 0.06)
        board.materials = [Studio3D.pbr(UIColor(white: 0.12, alpha: 1), metalness: 0.25, roughness: 0.7)]
        let boardGeo = SCNNode(geometry: board)
        boardGeo.position = SCNVector3(0, -0.08, 0)
        root.addChildNode(boardGeo)

        // Pedals stand on top of the board, in a centered row.
        for (i, pedal) in pedals.enumerated() {
            // Custom <slug>.usdz for this pedal, else the procedural archetype.
            let node = GearModelLoader.modelNode(for: pedal) ?? ProceduralPedal.build(for: pedal)
            node.name = "pedal_\(pedal.id.uuidString)"
            node.position = SCNVector3(row.centers[i], 0, 0.02)
            root.addChildNode(node)
        }
        return root
    }

    /// Re-angle every rocker treadle on an ALREADY-BUILT board to match its
    /// pedal's `Position` — the treadle's answer to `applyAmp` turning the amp's
    /// knobs. Rebuilding the scene for a value change would throw away the user's
    /// camera orbit and cost a full assembly per slider tick.
    static func applyTreadles(_ pedals: [GearItem], in root: SCNNode) {
        for pedal in pedals {
            guard let group = root.childNode(withName: "pedal_\(pedal.id.uuidString)", recursively: true),
                  let treadle = group.childNode(withName: ProceduralPedal.treadleNodeName,
                                                recursively: true)
            else { continue }
            treadle.eulerAngles.x = Studio3D.treadleAngle(forValue: pedal.values["Position"] ?? 5)
        }
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

        let row = layout(for: pedals)
        Studio3D.addLighting(to: scene)
        Studio3D.addContactShadow(to: scene.rootNode, width: row.width + 1.0,
                                  height: row.length + 0.5, at: SCNVector3(0, -0.42, 0.2))
        // Front-above 3/4 view; distance widens with the row so it always fits.
        let dist = Float(row.width) * 0.46 + 3.0
        Studio3D.addCamera(to: scene, position: SCNVector3(0, 1.55, dist), tilt: -0.46, fov: 46)
        return scene
    }
}

// MARK: - Procedural pedal (thin dispatch onto the enclosure archetypes)

/// The build entry point EVERY caller uses — the board above, the AR floor row,
/// and the exporter. Deliberately thin: the archetype family lives in
/// `PedalArchetypes3D` and can grow without any caller learning about it, and
/// the `GearModelLoader.modelNode(for:) ?? ProceduralPedal.build(for:)` order
/// that lets a designer's bespoke `.usdz` win outright stays exactly where it was.
enum ProceduralPedal {
    /// The status LED's node name. Named so a caller can light it: the AR floor
    /// pedals turn it on when the footswitch is engaged. EVERY archetype has one.
    static let ledNodeName = "led"

    /// The rocker treadle's PIVOT node name — the treadle's answer to a knob
    /// node, so `Position` can be re-applied to a board that is already built.
    static let treadleNodeName = "treadle"

    /// One compact stompbox, in board units. Every other footprint is expressed
    /// against it, and AR scales the whole family relative to it so archetypes
    /// keep their real-world size ratios there too.
    static let referenceWidth: CGFloat = 1.1

    static func build(for pedal: GearItem) -> SCNNode { PedalArchetypes.build(pedal) }

    /// The pedal's footprint WITHOUT building it — what the board has to know
    /// before it can decide how much room to leave for the row.
    static func footprint(for pedal: GearItem) -> (width: CGFloat, length: CGFloat) {
        let spec = PedalArchetypes.enclosure(for: pedal)
        return (spec.width, spec.length)
    }
}

#Preview {
    PedalboardModel3DView(pedals: [
        GearItem(name: "DUNRIDGE WEEPING WILLOW", category: .wah, values: ["Position": 2]),
        GearItem(name: "Iberon Valve Shrieker", category: .overdrive),
        GearItem(name: "KRX swirl 72", category: .modulation),
        GearItem(name: "BRIG Metal Realm", category: .overdrive),
        GearItem(name: "DALTON ARMATURE FUZZ DOME", category: .overdrive),
        GearItem(name: "BRIG Digital Delay", category: .delay),
    ])
    .frame(width: 520, height: 190)
    .background(RigTheme.background)
    .preferredColorScheme(.dark)
}
