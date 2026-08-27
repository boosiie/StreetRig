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
//  THEY STAND ON A BOARD NOW, WHICH REVERSES SOMETHING THIS FILE SAID. `update` used
//  to insist "a pedal lies flat on the floor"; with `FeatureFlags.arPedalboard` on it
//  stands on the deck of an `ARFloorPedalboard` and shares that deck's rake. The
//  clause that still holds — and holds harder — is the second one: the tilt comes
//  from the BOARD, never from the camera. Nothing here billboards, and the only
//  camera-derived input is the yaw fixed at lock time. See ARFloorPedalboard.swift.
//
//  AND IT IS ONE OFFSET, NOT THREE. Raising a pedal onto a deck moves where it draws
//  on screen, and the label above it and the stomp binner underneath it have to move
//  with it. They do, because none of the three re-derives a height: the lift is
//  already inside `ARFloorPose.offsets` before this file ever sees them.
//

import ARKit
import SceneKit
import SwiftUI
import StreetRigEngine
import simd

@MainActor
final class ARFloorPedals {

    /// How wide a pedal is drawn on the floor. Every model is scaled to it, whatever
    /// units it arrived in — see the header.
    ///
    /// DELIBERATELY NOT LIFE SIZE, AND THAT IS A REVERSAL. This was 0.075 m, the
    /// width of a real compact stompbox, on the reasoning that a real object should
    /// be its real size. On the floor that was wrong in practice: the phone is
    /// propped at ankle height and the player is reading these from standing, about
    /// five feet up and a metre back, where a 7.5 cm box is a smudge — and it is
    /// competing with a `slotSpacing` of 0.30 m, an ergonomic number about FEET,
    /// which spreads three smudges across three-quarters of a metre of empty deck.
    ///
    /// The page's job is telling a standing player which pedal is which at a glance
    /// mid-song. Legibility wins over scale fidelity, so the pedal is drawn about
    /// 2.7× life size: still clearly a stompbox, now readable from where the eyes
    /// actually are, and it fills the board it is bolted to. The 0.10 m of gap this
    /// leaves between neighbours is what keeps three of them tellable apart by foot.
    ///
    /// Not private: `ARFloorPedalboard` derives the board's width AND its whole
    /// front-to-back layout from it, because a board narrower or shallower than the
    /// pedals standing on it is the one mistake that unmistakably reads as broken.
    /// `nonisolated` so that derivation can happen off the main actor, on the way to
    /// the ARSession's delegate queue.
    nonisolated static let pedalWidth: Float = 0.20       // metres

    /// The marker for a slot with nothing in it: you cannot drop a pedal onto a
    /// spot you can't see, and an empty footswitch is still a place on the floor.
    ///
    /// Derived from `pedalWidth` so it stays the size of the thing that would fill
    /// it — a ring that no longer matches the pedals beside it reads as a different
    /// kind of object rather than as a vacancy.
    private static let emptyRingRadius: CGFloat = CGFloat(pedalWidth) * 0.42

    /// Everything this owns, in one node parented to the scene root. Its transform
    /// IS the anchor's, so a refinement moves the whole row by moving one node.
    private let root = SCNNode()
    /// One container per slot, positioned in the anchor's own space.
    private var slots: [SCNNode] = []
    /// What is currently modelled in each slot, so an unchanged pedal is not rebuilt
    /// 30 times a second.
    private var built: [UUID?] = [nil, nil, nil]
    /// One hover glow per slot, built once and only ever shown or hidden.
    private var halos: [SCNNode] = []
    /// Which slot is currently glowing, so an unchanged hover does not restart the
    /// breathing animation 18 times a second and freeze it at one brightness.
    private var hovered: Int?
    /// One persistent ON marker per slot, shown while that footswitch is engaged.
    private var engagedMarks: [SCNNode] = []
    /// What each marker is currently showing, so an unchanged state does not restart
    /// its animation on every one of `update`'s 60 calls a second.
    private var engagedShown: [Bool] = [false, false, false]

    /// The per-slot flash light a burst drives. Named rather than indexed because it
    /// is looked up under the slot container, beside whatever model is in there.
    private static let flashLightName = "streetrig.slotFlash"

    /// How far above the deck the per-slot lamps hang. Comfortably clear of a pedal's
    /// lid — derived from `pedalWidth` so it stays clear when the pedal grows.
    private static let hoverLightHeight: Float = pedalWidth * 1.15

    /// The board the row stands on, or nil when `FeatureFlags.arPedalboard` is off.
    ///
    /// Built ONCE, here, and then only ever moved. Nothing about its geometry depends
    /// on which pedals are in the slots, and `update` runs at up to 60 Hz — the same
    /// discipline as the `built` memo above, for the same reason.
    private let board: SCNNode?

    private weak var attachedTo: ARSCNView?

    init() {
        board = FeatureFlags.arPedalboard ? ARFloorPedalboard.node() : nil
        root.name = "streetrig.floorPedals"
        // First, so the pedals render over it rather than fighting it for depth at
        // the millimetre where a base meets a rail.
        if let board {
            board.isHidden = true
            root.addChildNode(board)
        }
        for index in 0..<3 {
            let slot = SCNNode()
            slot.name = "floorSlot_\(index)"
            root.addChildNode(slot)
            slots.append(slot)

            // Built once and then only shown or hidden — `update` runs at up to 60 Hz
            // and a glow rebuilt per frame is a glow that never finishes animating.
            let halo = Self.makeHalo()
            slot.addChildNode(halo)
            halos.append(halo)

            // The ENGAGED marker, and it is a separate object from the hover on
            // purpose. Hover answers "which pedal will I hit"; this answers "which
            // pedals are ON right now" — a question the player asks constantly,
            // mid-song, from standing height, about a state that persists. A pedal's
            // own 4 mm LED answers it at arm's length and not one inch further.
            // NO 3D STATE MARKER. There was one, briefly: a billboarded disc above
            // each pedal. It is gone because the answer belongs in the SwiftUI chrome
            // instead — that layer is already tracking each pedal's projected point,
            // it is never occluded by the board, and it does not shrink with distance,
            // which is the whole problem with putting a status light on an object a
            // metre away. See `ARFloorSlotView`. The in-world glows stay for what they
            // are good at: hover, which is about a PLACE on the floor.

            // Parked at zero intensity; a burst drives it. An SCNLight costs nothing
            // while it is emitting nothing, and adding it up front means a burst never
            // has to touch the node graph on the frame it needs to be immediate.
            let flash = SCNLight()
            flash.type = .omni
            flash.intensity = 0
            flash.attenuationEndDistance = 0.6
            let flashNode = SCNNode()
            flashNode.name = Self.flashLightName
            flashNode.light = flash
            // Clear of the enclosure, for the same reason as the hover lamp.
            flashNode.simdPosition = simd_float3(0, Self.hoverLightHeight, 0)
            slot.addChildNode(flashNode)
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
    func update(floor: ARFloorPose?, pedals: [GearItem?], engaged: [Bool], hovered: Int?) {
        guard let floor, floor.offsets.count == 3 else {
            root.isHidden = true
            setHover(nil)
            return
        }
        setHover(hovered)
        root.isHidden = false
        root.simdTransform = floor.anchor

        // WHAT EVERY SLOT IS TURNED BY, decided once for the row.
        //
        // THIS REVERSES A LINE THIS FILE USED TO CARRY. It said "Yaw only. A pedal
        // lies flat on the floor; it does not tip toward the phone." Standing on a
        // raked deck it is no longer flat — deliberately, because a pedal that
        // ignores the board it is bolted to is a pedal floating in front of one. The
        // half that survives is the half that matters: the tilt is the BOARD'S RAKE
        // and nothing else. Nothing here billboards; a pedal that tips to follow the
        // phone stops being an object the moment the player moves.
        //
        // AND THE YAW IS THE BOARD'S TOO, WHICH IS THE SECOND REVERSAL. This used to
        // pass `floor.facing` in, so each pedal aimed itself at where the phone had
        // been — three pedals turning independently of the board under them, which
        // read as badly-mounted gear whenever the row and the player's direction did
        // not line up. `mountOrientation` now takes the DECK's heading, so a pedal is
        // square to its rails by construction and the BOARD is the thing that faces
        // the player.
        //
        // Flag off, there is no deck, and this falls back to the plain lock-time yaw
        // — the same quaternion the original line produced.
        let deck = board != nil ? ARDeckFrame(floor) : nil
        let mount = deck?.mountOrientation
            ?? simd_quatf(angle: floor.facing, axis: simd_float3(0, 1, 0))

        if let board {
            if let deck {
                board.isHidden = false
                // Moved, never rebuilt. Position and orientation only — see `board`.
                board.simdPosition = deck.origin
                board.simdOrientation = simd_quatf(angle: deck.yaw, axis: simd_float3(0, 1, 0))
            } else {
                // No usable row axis, so no defensible board heading. Hiding it is
                // the honest answer; a board guessing which way it faces is a ramp.
                board.isHidden = true
            }
        }

        for index in 0..<3 {
            let slot = slots[index]
            // Already lifted onto the deck by `slotOffsets` — this file does not add
            // a height of its own, which is the entire reason the label above the
            // pedal and the stomp bin under it stay where the pedal is.
            slot.simdPosition = floor.offsets[index].xyz
            slot.simdOrientation = mount

            let pedal = pedals.indices.contains(index) ? pedals[index] : nil
            if built[index] != pedal?.id {
                // The halo and the flash light live under the slot too, and they are
                // built once for the life of the row — clearing ALL children here (as
                // this used to) would take them with the old model and leave a slot
                // that can never glow again.
                for child in slot.childNodes
                where child !== halos[index] && child.name != Self.flashLightName {
                    child.removeFromParentNode()
                }
                slot.addChildNode(Self.slotContent(pedal))
                built[index] = pedal?.id
            }
            if pedal != nil {
                setLED(on: engaged.indices.contains(index) && engaged[index], in: slot)
            }
        }
    }

    // MARK: - Telling the player where their foot is
    //
    // TWO SIGNALS, AND THEY MUST NOT BE THE SAME ONE. "Your foot is over this pedal"
    // and "you just switched this pedal" are different facts and the player needs both
    // — the first BEFORE committing, the second as confirmation. A single effect for
    // both would mean the only way to find out whether you were aimed right is to
    // stamp and listen, which is the guessing this is meant to end.
    //
    // So: hover is a STEADY GREEN BREATHING GLOW, and a stamp is a ONE-SHOT BURST that
    // fires and dies. Steady versus transient reads instantly even out of focus, which
    // matters because it is being read from standing height, several feet away, mid
    // song, by someone whose attention is on their hands.
    //
    // GREEN IS NOT A NEW WORD HERE. This page already promises that green means "this
    // position works" — that was about where the BOARD goes, and this is about where
    // the FOOT goes, but it is the same promise: you are in the right place. Amber
    // stays what it has always been, "this pedal is on", which is why the engage burst
    // is amber and the hover never is.

    /// Show or move the hover glow. Nil clears it.
    private func setHover(_ slot: Int?) {
        guard slot != hovered else { return }
        hovered = slot
        for (index, halo) in halos.enumerated() {
            let on = (index == slot)
            guard halo.isHidden == on else { continue }
            halo.isHidden = !on
            halo.removeAllActions()
            if on {
                // Breathing rather than static. A steady glow at this distance can be
                // mistaken for part of the pedal's own art; something that MOVES
                // cannot, and movement is what the eye catches in peripheral vision —
                // which is where this is, for a player looking at their hands.
                halo.opacity = 0.55
                halo.runAction(.repeatForever(.sequence([
                    .fadeOpacity(to: 1.0, duration: 0.42),
                    .fadeOpacity(to: 0.55, duration: 0.42),
                ])))
            }
        }
    }

    /// Show or hide the persistent ON markers.
    ///
    /// AMBER AND STEADY, AGAINST HOVER'S GREEN AND BREATHING. Two signals on the same
    /// three objects have to differ in more than one way or they blur together at
    /// distance: these differ in colour, in motion, and in shape — a tall steady amber
    /// column against a low pulsing green ring. Either one is readable alone, and a
    /// pedal that is BOTH hovered and engaged shows both without either being lost.
    private func setEngaged(_ engaged: [Bool], present: [Bool]) {
        for index in 0..<min(engagedMarks.count, engaged.count) {
            let mark = engagedMarks[index]
            // An empty slot has no state to report — a marker over one would be
            // describing a pedal that is not there.
            let visible = present.indices.contains(index) && present[index]
            mark.isHidden = !visible
            guard visible else { engagedShown[index] = false; continue }

            let on = engaged[index]
            guard engagedShown[index] != on else { continue }
            engagedShown[index] = on
            mark.childNode(withName: Self.onDiscName, recursively: false)?.isHidden = !on
            mark.childNode(withName: Self.offDiscName, recursively: false)?.isHidden = on
        }
    }

    /// The persistent state marker: a big disc riding above the pedal.
    ///
    /// IT SHOWS OFF AS WELL AS ON, and that is the point. The previous version drew
    /// something only when a pedal was engaged, so "off" and "no marker yet" looked
    /// identical and the player had to remember which was which. A control surface
    /// read from standing height mid-song has to answer "what state is this in" for
    /// every pedal at once, not just for the lit ones — so both states are drawn, and
    /// they differ in fill, brightness and colour rather than in mere presence.
    ///
    /// BILLBOARDED, so it is a CIRCLE from wherever the phone is propped. Lying flat
    /// on the deck it would be an ellipse squashed to a sliver at this camera angle —
    /// which is exactly what made the old floor ring hard to read and is why the
    /// column existed at all. A disc that turns to face the lens keeps its full area
    /// no matter how low the phone is sitting.
    static func makeStateMark() -> SCNNode {
        let container = SCNNode()
        container.name = "streetrig.stateMark"
        container.isHidden = true
        // JUST above the lid. Higher up it floated free of the pedal — three discs
        // hanging in a row near the top of the frame, with nothing to say which
        // belonged to which. Close enough to read as sitting ON the pedal is the whole
        // point of putting it there.
        container.simdPosition = simd_float3(0, pedalWidth * 0.80, 0)
        container.constraints = [SCNBillboardConstraint()]

        let size = CGFloat(pedalWidth) * 1.45
        for (index, on) in [false, true].enumerated() {
            let plane = SCNPlane(width: size, height: size)
            let material = SCNMaterial()
            material.diffuse.contents = stateImage(on: on)
            material.lightingModel = .constant
            material.blendMode = on ? .add : .alpha
            material.writesToDepthBuffer = false
            material.isDoubleSided = true
            plane.materials = [material]
            let node = SCNNode(geometry: plane)
            node.name = on ? onDiscName : offDiscName
            node.renderingOrder = 20 + index
            node.isHidden = true
            container.addChildNode(node)
        }
        return container
    }

    private static let onDiscName = "streetrig.stateOn"
    private static let offDiscName = "streetrig.stateOff"

    /// The two faces of the state marker, drawn rather than shipped so both follow the
    /// theme and the pedal's size.
    ///
    /// ON is a filled amber disc with a hot core — additive, so it reads as something
    /// emitting rather than something painted. OFF is a hollow dark ring: same size and
    /// same place, so the eye can compare three of them in a row without re-focusing,
    /// but unmistakably not lit.
    private static func stateImage(on: Bool) -> UIImage {
        let side: CGFloat = 256
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            let cg = ctx.cgContext
            let centre = CGPoint(x: side / 2, y: side / 2)
            if on {
                let tint = UIColor(RigTheme.amber)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                tint.getRed(&r, green: &g, blue: &b, alpha: &a)
                let stops: [(CGFloat, CGFloat)] = [(0, 1.0), (0.42, 0.92), (0.70, 0.62), (0.88, 0.12), (1, 0)]
                let colors = stops.map { UIColor(red: r, green: g, blue: b, alpha: $0.1).cgColor } as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                             colors: colors, locations: stops.map { $0.0 }) {
                    cg.drawRadialGradient(gradient, startCenter: centre, startRadius: 0,
                                          endCenter: centre, endRadius: side / 2, options: [])
                }
                // A rim, so it is a DISC and not a smudge. A pure radial falloff has no
                // edge at all, and at distance an edgeless glow is hard to tell from
                // lens flare or from the hover pool bouncing off the deck.
                let inset: CGFloat = side * 0.13
                let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
                cg.setStrokeColor(UIColor(red: r, green: g, blue: b, alpha: 0.95).cgColor)
                cg.setLineWidth(side * 0.055)
                cg.strokeEllipse(in: rect)
            } else {
                // A ring, not a disc: "off" should not read as a dark object sitting on
                // the pedal, it should read as an empty socket where the light goes.
                let inset: CGFloat = side * 0.13
                let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
                cg.setStrokeColor(UIColor(white: 1, alpha: 0.30).cgColor)
                cg.setLineWidth(side * 0.075)
                cg.strokeEllipse(in: rect)
                cg.setFillColor(UIColor(white: 0, alpha: 0.34).cgColor)
                cg.fillEllipse(in: rect)
            }
        }
    }

    /// Fire the one-shot burst for a footswitch that just changed state.
    ///
    /// Called from the page when a stomp actually toggles a pedal, rather than from
    /// the detection itself: what deserves confirming is the pedal CHANGING, not the
    /// foot moving. A stamp that was rejected downstream must not light anything up.
    func burst(slot: Int, engaged: Bool) {
        guard slots.indices.contains(slot) else { return }
        let container = slots[slot]

        // Engage throws a ring OUTWARD in amber — the page's colour for "this pedal is
        // on". Bypass collapses INWARD in a cold white. Same gesture, opposite
        // direction and opposite temperature, so which one happened is legible without
        // reading anything or remembering which colour meant what.
        let tint: UIColor = engaged ? UIColor(RigTheme.amber) : UIColor(white: 0.85, alpha: 1)
        let size = CGFloat(Self.pedalWidth) * 3.4

        let plane = SCNPlane(width: size, height: size)
        let material = SCNMaterial()
        material.diffuse.contents = Self.glowImage(tint: tint, ring: true)
        material.lightingModel = .constant
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        plane.materials = [material]

        let ring = SCNNode(geometry: plane)
        ring.eulerAngles.x = -.pi / 2
        ring.simdPosition = simd_float3(0, 0.004, 0)      // clear of the deck it sits on
        ring.renderingOrder = 30
        ring.simdScale = simd_float3(repeating: engaged ? 0.25 : 1.5)
        ring.opacity = 1
        container.addChildNode(ring)

        // Fast. A confirmation that lingers is still on screen when the next chord
        // needs the next pedal, and two of them overlapping says nothing at all.
        let grow = SCNAction.scale(to: engaged ? 1.6 : 0.3, duration: 0.42)
        grow.timingMode = .easeOut
        ring.runAction(.sequence([
            .group([grow, .sequence([.wait(duration: 0.12), .fadeOut(duration: 0.30)])]),
            .removeFromParentNode(),
        ]))

        // A hard flash on the pedal itself, so the burst is not the only thing that
        // moved — from a distance the ring reads as "something happened HERE" and the
        // flash reads as "…to THIS", and only together do they name the pedal.
        if let flash = container.childNode(withName: Self.flashLightName, recursively: false),
           let light = flash.light {
            light.color = tint
            flash.removeAllActions()
            light.intensity = 0
            flash.runAction(.sequence([
                .customAction(duration: 0.10) { _, t in light.intensity = 1600 * CGFloat(t / 0.10) },
                .customAction(duration: 0.34) { _, t in light.intensity = 1600 * (1 - CGFloat(t / 0.34)) },
                .run { _ in light.intensity = 0 },
            ]))
        }
    }

    /// Let go of the scene — the page is gone, and a node graph left parented to a
    /// session that outlives it would be drawn over the next thing that uses it.
    func detach() {
        root.removeFromParentNode()
        attachedTo = nil
        built = [nil, nil, nil]
        setHover(nil)
    }

    // MARK: - Building

    /// What goes in one slot: the pedal, or the marker for the absence of one.
    ///
    /// Internal rather than private so the board's non-AR preview harness can mount
    /// the REAL contents on the REAL deck. ARKit does not run in the Simulator, so
    /// that harness is the only way to look at this geometry before a device pass —
    /// and a harness that builds its own look-alike pedal verifies the look-alike.
    static func slotContent(_ pedal: GearItem?) -> SCNNode {
        guard let pedal else {
            let ring = emptyRing()
            // Flush ON the deck rather than half inside it. Zero on a bare floor,
            // which has no geometry to z-fight with — see `ARFloorPedalboard`.
            ring.simdPosition.y = ARFloorPedalboard.ringLift
            return ring
        }
        return pedalNode(pedal)
    }

    /// One pedal, scaled to life size and standing on the surface it is parented to
    /// — the floor plane, or the board's deck.
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

    /// An empty slot: a ring drawn on whatever the row is standing on. Flat on that
    /// surface (an `SCNTube`'s axis is already y, so it needs no tilt) and unlit,
    /// because it is a marking rather than an object — it should not pick up a
    /// highlight that makes it look like something solid.
    ///
    /// On a board the ring is doing more work than it was on carpet: it is the
    /// difference between "this mounting spot is free" and "that pedal failed to
    /// render", which is why it lies on the deck and rakes with it rather than
    /// staying behind on the floor.
    private static func emptyRing() -> SCNNode {
        let ring = SCNTube(innerRadius: emptyRingRadius,
                           outerRadius: emptyRingRadius + emptyRingRadius * 0.09,
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

    /// The hover glow: a pool of green light on the deck plus a real light above it.
    ///
    /// BOTH HALVES ARE NEEDED AT THIS DISTANCE. The disc alone is a bright shape that
    /// could be anything painted on the board; the light alone tints a small dark
    /// object that is already hard to pick out. Together the pedal is lit FROM the pool
    /// it is standing in, which is what makes it read as the one being pointed at
    /// rather than the one that happens to be brighter.
    /// Internal rather than private so the non-AR harness in `ARFloorPedalboard` can
    /// show the glow. ARKit does not run in the Simulator, so a preview is the only
    /// place its size and brightness can be judged before it reaches a device.
    static func makeHalo() -> SCNNode {
        let container = SCNNode()
        container.name = "streetrig.hoverHalo"
        container.isHidden = true

        // MUST STAY INSIDE THE SLOT SPACING, and a first pass at 2.8× did not: at a
        // 0.20 m pedal that is a 0.56 m pool against centres 0.30 m apart, so it
        // covered its neighbours and lit the floor under the whole board. It said
        // "the board" when the entire job is to say "THIS ONE". 1.45× is 0.29 m —
        // just under the spacing, so the glow ends before the next pedal begins.
        let size = CGFloat(pedalWidth) * 1.7
        let plane = SCNPlane(width: size, height: size)
        let material = SCNMaterial()
        material.diffuse.contents = glowImage(tint: UIColor(RigTheme.ready), ring: false)
        material.lightingModel = .constant       // a light source, not a lit surface
        material.blendMode = .add                // stacks on the deck instead of hiding it
        material.writesToDepthBuffer = false     // never occludes the pedal standing in it
        material.isDoubleSided = true
        plane.materials = [material]

        let disc = SCNNode(geometry: plane)
        disc.eulerAngles.x = -.pi / 2            // flat, on the deck
        disc.simdPosition = simd_float3(0, 0.002, 0)
        disc.renderingOrder = 10
        container.addChildNode(disc)

        // Tint, not floodlight. At 700 with a 0.45 m reach this washed all three
        // pedals to white — additive light on a pale enclosure saturates fast, and a
        // blown-out pedal is LESS identifiable than an unlit one, not more. The reach
        // now stops short of `slotSpacing` (0.30 m) by construction.
        // THE HOVER SHAFT IS GONE, and the state disc is why. The shaft existed
        // because a mark on the FLOOR is nearly edge-on from a propped phone and hard
        // to see; the answer at the time was to put something vertical above the
        // pedal. There is now a big billboarded disc in exactly that space, and two
        // objects competing for it read as clutter rather than as two signals — the
        // shaft ran straight through the disc. Hover keeps the pool and the lamp,
        // which were already legible, and the airspace above the pedal belongs to
        // the thing that has to be readable for all three pedals at once.

        let light = SCNLight()
        light.type = .omni
        light.color = UIColor(RigTheme.ready)
        // 220 still flooded: the enclosure's top face saturated to pure white, which
        // took the pedal's colour and its knobs with it. A hovered pedal you can no
        // longer IDENTIFY is a worse outcome than no highlight — the point of the
        // glow is to say which one you are about to hit. The ring carries the drama;
        // this only has to tint.
        // BOTH NUMBERS ARE ABOUT ONE PEDAL. The lamp hangs ~0.12 m above the lid, and
        // an omni falls off with the square of that — so what looks like a modest
        // intensity at arm's length is a floodlight at this range, which is why 150
        // still burned the top face white. And the reach has to stay UNDER
        // `slotSpacing` (0.30 m) or the pool lights the pedals either side, which is
        // the opposite of naming one.
        light.intensity = 32
        light.attenuationEndDistance = 0.24
        let lightNode = SCNNode()
        lightNode.light = light
        // ABOVE THE LID, NOT UNDER IT. At 0.20 m wide the enclosure stands about
        // 0.11 m tall, so the first pass at 0.09 put the lamp INSIDE the pedal: it lit
        // the interior faces, saturated the top from beneath, and left a hard dark
        // patch where the footswitch shell blocked it. Dropping the intensity did
        // nothing, which is what said the problem was position rather than power.
        lightNode.simdPosition = simd_float3(0, Self.hoverLightHeight, 0)
        container.addChildNode(lightNode)

        return container
    }

    /// A radial glow, drawn rather than shipped as an asset so its colour follows the
    /// theme and its size follows `pedalWidth`.
    ///
    /// `ring: true` puts the energy in a band at the edge instead of the middle — a
    /// shockwave rather than a pool, which is what makes an expanding burst read as
    /// moving outward rather than merely getting bigger.
    /// A vertical shaft: solid at the base, gone by the top. Drawn rather than shipped
    /// so it follows the theme colour and the pedal's size.
    static func beamImage(tint: UIColor) -> UIImage {
        let width: CGFloat = 64, height: CGFloat = 256
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { ctx in
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            tint.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            // The fade has to FINISH inside the plane, not merely be heading toward
            // zero at its edge. A shaft still 12% opaque where the geometry stops has
            // a hard horizontal cut across it, and against a dark room that cut is the
            // most visible thing on screen — it reads as a rectangle, not as light.
            let stops: [(CGFloat, CGFloat)] = [(0, 0.90), (0.22, 0.46), (0.52, 0.11), (0.78, 0), (1, 0)]
            let colors = stops.map { UIColor(red: red, green: green, blue: blue, alpha: $0.1).cgColor } as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: colors, locations: stops.map { $0.0 }) else { return }
            // Image top maps to the plane's top, so stop 0 goes at the image's BOTTOM
            // — solid where the shaft meets the pedal, gone before its far end.
            // (Verified by looking: drawn the other way round the shaft was solid at
            // the top of the frame and faded out at the pedal, anchored to nothing.)
            ctx.cgContext.drawLinearGradient(gradient,
                                             start: CGPoint(x: 0, y: height),
                                             end: CGPoint(x: 0, y: 0),
                                             options: [])
        }
    }

    static func glowImage(tint: UIColor, ring: Bool) -> UIImage {
        let side: CGFloat = 256
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            let centre = CGPoint(x: side / 2, y: side / 2)
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            tint.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

            // Stops walk outward from the centre. The falloff is deliberately soft:
            // a hard edge on an additive sprite looks like a decal, and the whole
            // point is that this looks like light.
            // A BAND, NOT A BLOB, in both cases. A filled pool at full alpha goes
            // white the moment it is added to anything, and white says nothing about
            // which pedal. Putting most of the energy in a ring near the edge draws
            // the OUTLINE of the target — which is the thing that has to be legible
            // from standing height — and leaves a low fill inside so the deck under
            // the pedal still reads as lit rather than as a sticker with a hole in it.
            let stops: [(CGFloat, CGFloat)] = ring
                ? [(0, 0), (0.62, 0.05), (0.82, 0.90), (0.94, 0.22), (1, 0)]
                : [(0, 0.20), (0.52, 0.28), (0.80, 0.85), (0.93, 0.30), (1, 0)]
            let colors = stops.map {
                UIColor(red: red, green: green, blue: blue, alpha: $0.1).cgColor
            } as CFArray
            let locations = stops.map { $0.0 }

            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: colors, locations: locations) else { return }
            ctx.cgContext.drawRadialGradient(gradient,
                                             startCenter: centre, startRadius: 0,
                                             endCenter: centre, endRadius: side / 2,
                                             options: [])
        }
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