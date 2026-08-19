//
//  ARFloorPedals.swift
//  StreetRig
//
//  The pedals, as objects lying on the floor the player designated — real SceneKit
//  models parented to the world anchor, drawn by the same AR camera that draws the
//  feed behind them. That last part is the whole point: nothing here is projected
//  by hand, so the pedals foreshorten, sit flat, and hold their spot on the carpet
//  as the phone moves, in the way a screen-space rectangle positioned at a
//  projected point never can.
//
//  THIS REVERSES A DECISION THE CODE USED TO DOCUMENT. `ARCameraView` said the
//  scene stays empty and warned that anything adding nodes to it had reversed the
//  design behind the feature. That is exactly what this is, done deliberately:
//  ARKit now supplies tracking AND renders content. Two things that were switched
//  off because there was nothing to render are switched back on with it, in
//  `ARCameraView` where the view is configured — light estimation (a pedal lit for
//  a different room reads as a sticker) and antialiasing (a 7cm object three feet
//  away is mostly edges).
//
//  WHAT STAYED SWIFTUI, AND WHY. The chrome — name, ON/OFF, the lamp, the green
//  placement ring — is still SwiftUI tracking each pedal's projected point. A label
//  lying flat on a floor four feet away, at the angle a propped phone sees it, is
//  the least readable place to put the one word the player needs while standing.
//  So: the OBJECT is in the world, the WRITING about it is on the screen.
//
//  SIZE IS NORMALISED, NOT TRUSTED. A `.usdz` a designer dropped in is authored in
//  whatever units they were working in, and the procedural stand-in is built in the
//  rig diorama's units where a pedal is 1.1 across. Either one placed at face value
//  is a pedal the size of a car or a grain of rice. Every model is measured and
//  scaled to a real pedal's width instead, which is also what makes a bespoke model
//  and the fallback sit at the same size in the same row.
//

import ARKit
import SceneKit
import SwiftUI
import StreetRigEngine
import simd

@MainActor
final class ARFloorPedals {

    /// A compact stompbox is about this wide. Every model is scaled to it, whatever
    /// units it arrived in — see the header.
    private static let pedalWidth: Float = 0.075          // metres

    /// The marker for a slot with nothing in it: you cannot drop a pedal onto a
    /// spot you can't see, and an empty footswitch is still a place on the floor.
    private static let emptyRingRadius: CGFloat = 0.055   // metres

    /// Everything this owns, in one node parented to the scene root. Its transform
    /// IS the anchor's, so a refinement moves the whole row by moving one node.
    private let root = SCNNode()
    /// One container per slot, positioned in the anchor's own space.
    private var slots: [SCNNode] = []
    /// What is currently modelled in each slot, so an unchanged pedal is not rebuilt
    /// 30 times a second.
    private var built: [UUID?] = [nil, nil, nil]

    private weak var attachedTo: ARSCNView?

    init() {
        root.name = "streetrig.floorPedals"
        for index in 0..<3 {
            let slot = SCNNode()
            slot.name = "floorSlot_\(index)"
            root.addChildNode(slot)
            slots.append(slot)
        }
        // A floor is not a light box. ARKit's estimate carries the room, but it can
        // read very dark indoors under a stage light, and a black pedal on a black
        // carpet is indistinguishable from no pedal at all — so a small ambient
        // floor is added under it that the estimate can only add to.
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 260
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        root.addChildNode(ambientNode)
    }

    /// Put the row into (or take it out of) a live AR scene.
    ///
    /// Re-attaching to the same view is a no-op rather than a re-add, because the
    /// camera view hands itself over on every SwiftUI update pass and re-parenting
    /// a node graph 60 times a second is a good way to make the pedals flicker.
    func attach(to view: ARSCNView?) {
        guard view !== attachedTo else { return }
        root.removeFromParentNode()
        attachedTo = view
        guard let view else { return }
        // Lighting and antialiasing are the camera view's to set — it owns the view
        // it makes, and two places writing the same render flags is how one of them
        // silently stops being true.
        view.scene.rootNode.addChildNode(root)
    }

    /// Draw the row for the current floor pose and the current slot contents.
    ///
    /// Cheap to call often: an unchanged pedal keeps its node, and the pose is
    /// assigned to one transform rather than walked into three.
    func update(floor: ARFloorPose?, pedals: [GearItem?], engaged: [Bool]) {
        guard let floor, floor.offsets.count == 3 else {
            root.isHidden = true
            return
        }
        root.isHidden = false
        root.simdTransform = floor.anchor

        for index in 0..<3 {
            let slot = slots[index]
            slot.simdPosition = floor.offsets[index].xyz
            // Yaw only. A pedal lies flat on the floor; it does not tip toward the
            // phone, and it does not billboard — if it did, the moment the player
            // moved would be the moment it stopped looking like an object.
            slot.simdOrientation = simd_quatf(angle: floor.facing, axis: simd_float3(0, 1, 0))

            let pedal = pedals.indices.contains(index) ? pedals[index] : nil
            if built[index] != pedal?.id {
                slot.childNodes.forEach { $0.removeFromParentNode() }
                slot.addChildNode(pedal.map(Self.pedalNode) ?? Self.emptyRing())
                built[index] = pedal?.id
            }
            if pedal != nil {
                setLED(on: engaged.indices.contains(index) && engaged[index], in: slot)
            }
        }
    }

    /// Let go of the scene — the page is gone, and a node graph left parented to a
    /// session that outlives it would be drawn over the next thing that uses it.
    func detach() {
        root.removeFromParentNode()
        attachedTo = nil
        built = [nil, nil, nil]
    }

    // MARK: - Building

    /// One pedal, scaled to life size and standing on the floor plane.
    private static func pedalNode(_ pedal: GearItem) -> SCNNode {
        // The same resolution order as everywhere else the piece is drawn: a
        // bespoke `<slug>.usdz` if the designer supplied one, else the procedural
        // stompbox. The AR page does not get its own look for the same gear.
        let model = GearModelLoader.modelNode(for: pedal) ?? ProceduralPedal.build(for: pedal)

        let (minBox, maxBox) = model.boundingBox
        let width = max(maxBox.x - minBox.x, 0.0001)
        let scale = pedalWidth / Float(width)

        // Wrapped rather than scaled in place: the model's own transform belongs to
        // whoever authored it, and the sit-on-the-floor offset below has to be
        // applied in the SCALED space to land the base at y=0 rather than near it.
        let holder = SCNNode()
        holder.addChildNode(model)
        holder.simdScale = simd_float3(repeating: scale)
        model.simdPosition = simd_float3(-(minBox.x + maxBox.x) / 2,
                                         -minBox.y,
                                         -(minBox.z + maxBox.z) / 2)
        return holder
    }

    /// An empty slot: a ring drawn on the floor itself. Flat on the plane (hence the
    /// −90° tilt) and unlit, because it is a marking rather than an object — it
    /// should not pick up a highlight that makes it look like something solid.
    private static func emptyRing() -> SCNNode {
        let ring = SCNTube(innerRadius: emptyRingRadius,
                           outerRadius: emptyRingRadius + 0.004,
                           height: 0.001)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor(RigTheme.textMuted).withAlphaComponent(0.85)
        m.isDoubleSided = true
        ring.materials = [m]

        let node = SCNNode(geometry: ring)
        node.name = "emptyRing"
        return node
    }

    /// Light the pedal's own LED when its footswitch is engaged.
    ///
    /// Best-effort by design: the procedural stompbox names its LED, a designer's
    /// `.usdz` has whatever it has. A model with no `led` node simply doesn't light
    /// one — the SwiftUI lamp above it is the answer that always works, which is
    /// why that lamp is the one carrying the state.
    private func setLED(on: Bool, in slot: SCNNode) {
        guard let led = slot.childNode(withName: ProceduralPedal.ledNodeName, recursively: true),
              let material = led.geometry?.firstMaterial else { return }
        material.emission.contents = on
            ? material.diffuse.contents
            : UIColor.black
    }
}