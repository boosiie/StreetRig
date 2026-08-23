//
//  PedalArchetypes3D.swift
//  StreetRig
//
//  The pedalboard's ENCLOSURE FAMILIES. Every catalog pedal used to render as
//  the same 1.1 × 0.42 × 1.45 chamfered box with a different colour on it, which
//  put a Cry Baby, a Boss compact, a Phase 90 and a Fuzz Face on the hero screen
//  as four identical bricks — a worse likeness than the app's own 2D art, which
//  already draws a hinged rocker treadle (`WahArt`) and a Boss tread plate. This
//  file is the fix: a small set of parametric archetypes chosen from the pedal's
//  NAME first and its category second, the same dispatch order `GearArt.spec`
//  and `PedalSpec.parameters` already use — so the 3D stage and the collection
//  cards can never disagree about what a piece is.
//
//  WHY A SPEC STRUCT AND NOT JUST BUILDERS. `PedalboardScene` has to lay a row
//  out before anything is built, and a wah is twice a compact's length: it needs
//  the FOOTPRINT without paying for the geometry. `enclosure(for:)` is string
//  matching and arithmetic, so the board can ask every pedal how much room it
//  wants, and `build(_:)` then dresses that same spec. One source of truth for
//  the size means the layout and the model can't drift apart.
//
//  WHAT AN ARCHETYPE IS NOT: a replica. Per research/3d-amp-rendering-options.md
//  §5 these are the shape LANGUAGE of a pedal class — a big hinged tread plate,
//  a round enclosure, a rocker treadle — and carry no logo, script, badge or
//  graphic. The catalog names are deliberately re-badged parodies and the
//  geometry stays in the same register.
//
//  CHEAP ON PURPOSE. The whole board renders in ONE SCNView (see the header of
//  PedalModel3DView), so every archetype is chamfered boxes, cylinders and a
//  single low-segment torus. No mesh files, no booleans, nothing per-pixel.
//

import SceneKit
import StreetRigEngine
import UIKit

// MARK: - The families

/// The enclosure family a pedal belongs to. Named for the real-world CLASS the
/// silhouette comes from, never for a product.
enum PedalArchetype: String, CaseIterable {
    /// 1590B: small, low, flat top, knobs by the back edge, switch at the front.
    case mxrBox
    /// The compact with the signature big hinged tread plate and a recessed
    /// knob shelf above it.
    case bossCompact
    /// 1590BB and the oversized fuzz/EQ boxes: wider, longer, controls in two
    /// rows (or a slider bank once there are more than six of them).
    case bigBox
    /// A hinged rocker with a ridged treadle — the wah.
    case wahRocker
    /// The same rocker family with nothing on top: volume and expression.
    case trebleWedge
    /// A compact whose top face is a display instead of knobs.
    case tunerWedge
    /// The one round enclosure in the catalog.
    case roundFuzz
    /// A wide deck with two footswitches side by side.
    case looperDeck

    /// One catalog pedal that stands for this family. `ModelExporter` bakes
    /// these so a designer refining an archetype in Blender starts from the
    /// shape they are actually replacing, not from a generic box.
    var representativeItem: GearItem {
        switch self {
        case .mxrBox:      return GearItem(name: "MXP phase 90", category: .modulation)
        case .bossCompact: return GearItem(name: "Ibonez Tube Screamer", category: .overdrive)
        case .bigBox:      return GearItem(name: "VOSS Metal Zone", category: .overdrive)
        case .wahRocker:   return GearItem(name: "DUNLAP CRY BABY", category: .wah)
        case .trebleWedge: return GearItem(name: "VOSS FV-500H", category: .volume)
        case .tunerWedge:  return GearItem(name: "VOSS Chromatic Tuner", category: .tuner)
        case .roundFuzz:   return GearItem(name: "DALLAS ARBITOR FUZZ FACE", category: .overdrive)
        case .looperDeck:  return GearItem(name: "VOSS Loop Station", category: .looper)
        }
    }

    /// Export file stem, e.g. `StreetRig_Pedal_WahRocker`.
    var exportName: String {
        "StreetRig_Pedal_" + rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}

/// How an archetype arranges whatever controls the pedal actually has.
enum PedalKnobLayout {
    case none
    case centered
    case row
    case twoRows
    /// Bowed forward at the edges — a Boss compact's knob shelf.
    case arc
    /// Vertical faders. A graphic EQ has bands, not knobs, and drawing eleven
    /// dials on one box is the wrong object.
    case sliders
}

/// The parametric description of one pedal's enclosure: enough to lay it out on
/// the board, and enough to build it.
struct PedalEnclosure {
    var archetype: PedalArchetype
    /// Footprint across the row (x) and front-to-back (z), in board units where
    /// a compact stompbox is `ProceduralPedal.referenceWidth` wide.
    var width: CGFloat
    var length: CGFloat
    /// Height of the main chassis. Detail on top (knobs, treadle, dome) goes
    /// above this; the base always sits at y = 0.
    var height: CGFloat
    var color: UIColor
    var led: UIColor
    var knobs: Int
    var knobLayout: PedalKnobLayout
}

// MARK: - Resolution + assembly

enum PedalArchetypes {

    // MARK: Which family is this pedal?

    /// Name first, then category — the order every other per-model table in the
    /// app already uses, so a re-badged model lands on its real-world shape and
    /// an unknown one still lands somewhere sensible.
    static func archetype(for pedal: GearItem) -> PedalArchetype {
        let n = pedal.name.lowercased()

        // 1. A `Position` control IS a treadle. `.wah` and `.volume` expose it by
        //    category, and the Whammy exposes it by name — all three are pedals
        //    you rock with your foot, whatever drawer the catalog files them in.
        if pedal.category == .wah || pedal.category == .volume
            || pedal.parameters.contains(where: { $0.name == "Position" }) {
            let isWah = pedal.category == .wah || n.contains("wah") || n.contains("cry baby")
            return isWah ? .wahRocker : .trebleWedge
        }
        // 2. Models whose enclosure is the famous part.
        if n.contains("fuzz face") { return .roundFuzz }
        for key in oversizedNames where n.contains(key) { return .bigBox }
        // 3. Categories that are a shape rather than an effect.
        if pedal.category == .tuner  { return .tunerWedge }
        if pedal.category == .looper { return .looperDeck }
        // 4. House styles. The catalog's parody brands track real makers, and a
        //    maker's chassis is the most reliable predictor of a shape there is.
        if n.contains("voss") || n.contains("ibonez")  { return .bossCompact }
        if n.contains("electro-harmonium")             { return .bigBox }
        if n.contains("mxp") || n.contains("dunlap")   { return .mxrBox }
        // 5. Anything unmatched is a 1590B, because most pedals are.
        return .mxrBox
    }

    /// Models that ship in an oversized box regardless of who made them.
    private static let oversizedNames = [
        "metal zone", "big muff", "para", "ten band", "king of tone",
        "centaur", "klon", "procon", "iridium", "deja",
    ]

    // MARK: How many controls, and where

    /// Control count comes from `PedalSpec.parameters(forName:category:)` — the
    /// researched per-model truth the zoom panel already draws — so a Big Muff
    /// gets three and a Metal Zone gets its EQ set without a second table to
    /// maintain. The only overrides left are places where the HARDWARE genuinely
    /// disagrees with the control list.
    static func knobCount(for pedal: GearItem, archetype: PedalArchetype) -> Int {
        switch archetype {
        case .wahRocker, .trebleWedge, .tunerWedge:
            return 0                                    // nothing on top by definition
        default:
            break
        }
        let n = pedal.name.lowercased()
        // Six controls, four shafts: two of a Metal Zone's are dual-concentric.
        if n.contains("metal zone") { return 4 }
        // A Loop Station's level knob is hardware, not a saved parameter — the
        // looper category deliberately exposes none.
        if pedal.category == .looper { return 1 }
        return pedal.parameters.count
    }

    private static func knobLayout(_ archetype: PedalArchetype, knobs: Int) -> PedalKnobLayout {
        guard knobs > 0 else { return .none }
        switch archetype {
        case .wahRocker, .trebleWedge, .tunerWedge: return .none
        case .bossCompact: return knobs >= 7 ? .sliders : (knobs == 1 ? .centered : .arc)
        case .bigBox:      return knobs >= 7 ? .sliders : (knobs >= 4 ? .twoRows : (knobs == 1 ? .centered : .row))
        case .mxrBox:      return knobs >= 4 ? .twoRows : (knobs == 1 ? .centered : .row)
        case .roundFuzz:   return knobs == 1 ? .centered : .row
        case .looperDeck:  return .centered
        }
    }

    // MARK: The spec

    static func enclosure(for pedal: GearItem) -> PedalEnclosure {
        let family = archetype(for: pedal)
        let knobs = knobCount(for: pedal, archetype: family)
        let colors = finish(for: pedal)

        // Footprints are relative to a compact stompbox at 1.1 wide, using the
        // real chassis proportions of each class (a wah really is about twice a
        // compact's length, a 1590BB really is about half again as wide).
        let width: CGFloat, length: CGFloat, height: CGFloat
        switch family {
        case .mxrBox:      width = knobs > 3 ? 1.14 : 1.00; length = knobs > 3 ? 1.42 : 1.30; height = 0.36
        case .bossCompact: width = 1.14; length = 1.52; height = 0.46
        case .bigBox:      width = 1.56; length = 1.66; height = 0.44
        case .wahRocker:   width = 1.20; length = 2.50; height = 0.26
        case .trebleWedge: width = 1.10; length = 2.36; height = 0.24
        case .tunerWedge:  width = 1.14; length = 1.52; height = 0.46
        case .roundFuzz:   width = 1.50; length = 1.50; height = 0.42
        case .looperDeck:  width = 1.90; length = 1.66; height = 0.42
        }

        return PedalEnclosure(archetype: family, width: width, length: length, height: height,
                              color: colors.color, led: colors.led,
                              knobs: knobs, knobLayout: knobLayout(family, knobs: knobs))
    }

    // MARK: Build

    /// The dispatch entry point. Returns an UNNAMED group: the caller names it
    /// `pedal_<uuid>`, and tap hit-testing walks up to that name — so everything
    /// built here has to stay a descendant and must never claim the prefix.
    static func build(_ pedal: GearItem) -> SCNNode {
        let spec = enclosure(for: pedal)
        let group = SCNNode()

        switch spec.archetype {
        case .mxrBox:      buildFlatTopBox(spec, into: group)
        case .bossCompact: buildCompactWithTreadPlate(spec, into: group, display: false)
        case .tunerWedge:  buildCompactWithTreadPlate(spec, into: group, display: true)
        case .bigBox:      buildFlatTopBox(spec, into: group)
        case .roundFuzz:   buildRoundFuzz(spec, into: group)
        case .looperDeck:  buildLooperDeck(spec, into: group)
        case .wahRocker, .trebleWedge: buildRocker(spec, into: group)
        }

        // A rocker's treadle carries a live value, exactly like an amp knob:
        // seed it here so a freshly built board is already at the right angle,
        // and `PedalboardScene.applyTreadles` re-applies it without a rebuild.
        if let treadle = group.childNode(withName: ProceduralPedal.treadleNodeName, recursively: true) {
            treadle.eulerAngles.x = Studio3D.treadleAngle(forValue: pedal.values["Position"] ?? 5)
        }
        return group
    }

    // MARK: - Flat-top boxes (1590B and 1590BB)

    private static func buildFlatTopBox(_ e: PedalEnclosure, into group: SCNNode) {
        let top = Float(e.height)
        let bodyMat = Studio3D.pbr(e.color, metalness: 0.35, roughness: 0.42)
        Studio3D.addBox(e.width, e.height, e.length, chamfer: 0.05, mat: bodyMat,
                        at: SCNVector3(0, top / 2, 0), to: group)

        let backZ = -Float(e.length) / 2 + 0.30
        addControls(e, top: top, backZ: backZ, usable: Float(e.width) - 0.22, to: group)

        // Footswitch and LED share the front half, switch nearest the toe —
        // the order your foot meets them.
        addFootswitch(radius: e.archetype == .bigBox ? 0.155 : 0.135,
                      at: SCNVector3(0, top + 0.05, Float(e.length) / 2 - 0.26), to: group)
        addLED(e.led, radius: 0.045, at: SCNVector3(0, top + 0.015, Float(e.length) / 2 - 0.60), to: group)
    }

    // MARK: - Boss-style compact (and the tuner, which is the same shell)

    /// The distinguishing feature of this whole class is that the top is a big
    /// hinged plate you stand on, with the knobs pushed onto a shelf behind it —
    /// so there is deliberately NO separate chrome footswitch here. The plate is
    /// the switch, and leaving a button on top would read as the wrong pedal.
    private static func buildCompactWithTreadPlate(_ e: PedalEnclosure, into group: SCNNode,
                                                   display: Bool) {
        let top = Float(e.height)
        let halfL = Float(e.length) / 2
        let bodyMat = Studio3D.pbr(e.color, metalness: 0.35, roughness: 0.42)
        Studio3D.addBox(e.width, e.height, e.length, chamfer: 0.05, mat: bodyMat,
                        at: SCNVector3(0, top / 2, 0), to: group)

        var shelfTop = top
        let shelfZ = -halfL + 0.28

        if display {
            // A tuner's back half is a readout, not controls: a dark inset panel
            // with one lit needle. Emissive so it survives the stage's low key
            // light — an unlit black rectangle just reads as a hole.
            let panelMat = Studio3D.pbr(UIColor(white: 0.06, alpha: 1), metalness: 0.1, roughness: 0.25)
            Studio3D.addBox(e.width - 0.26, 0.05, 0.50, chamfer: 0.02, mat: panelMat,
                            at: SCNVector3(0, top + 0.01, shelfZ), to: group)
            let needle = Studio3D.pbr(UIColor(red: 0.3, green: 0.95, blue: 0.45, alpha: 1),
                                      metalness: 0, roughness: 0.4,
                                      emission: UIColor(red: 0.3, green: 0.95, blue: 0.45, alpha: 1))
            Studio3D.addBox(0.05, 0.03, 0.30, chamfer: 0, mat: needle,
                            at: SCNVector3(0, top + 0.04, shelfZ), to: group)
        } else if e.knobLayout == .sliders {
            // A slider bank needs the whole back face; the shelf would crowd it.
            addControls(e, top: top, backZ: shelfZ, usable: Float(e.width) - 0.22, to: group)
        } else if e.knobs > 0 {
            // The shelf: knobs sit recessed ABOVE the plate so a boot on the
            // plate can't reach them, which is the whole reason it exists.
            let shelfMat = Studio3D.pbr(e.color, metalness: 0.35, roughness: 0.5)
            Studio3D.addBox(e.width - 0.10, 0.16, 0.52, chamfer: 0.04, mat: shelfMat,
                            at: SCNVector3(0, top + 0.08, shelfZ), to: group)
            shelfTop = top + 0.16
            addControls(e, top: shelfTop, backZ: shelfZ + 0.04, usable: Float(e.width) - 0.28, to: group)
        }

        // The tread plate: hinged at its BACK edge (under the shelf), free edge
        // toward the player. Tilted a few degrees so the hinge is legible from
        // the stage's fixed 3/4 camera — flat, it reads as a painted panel.
        let plateLength = display ? CGFloat(0.72) : CGFloat(0.94)
        let plateZ = halfL - Float(plateLength) / 2 - 0.10
        let plateMat = Studio3D.pbr(darken(e.color, 0.62), metalness: 0.45, roughness: 0.35)
        let plate = Studio3D.addBox(e.width - 0.18, 0.10, plateLength, chamfer: 0.03, mat: plateMat,
                                    at: SCNVector3(0, top + 0.06, plateZ), to: group)
        plate.eulerAngles.x = 0.10                       // back edge high, free edge low
        plate.name = "treadPlate"

        // Rubber bumper under the free edge — the part that actually stops the
        // plate, and the reason a Boss pedal has a visible gap at the front.
        let bumper = Studio3D.pbr(UIColor(white: 0.08, alpha: 1), metalness: 0, roughness: 0.9)
        Studio3D.addBox(e.width - 0.30, 0.05, 0.08, chamfer: 0.02, mat: bumper,
                        at: SCNVector3(0, top + 0.02, halfL - 0.13), to: group)

        addLED(e.led, radius: 0.05, at: SCNVector3(0, shelfTop + 0.03, -halfL + 0.10), to: group)
    }

    // MARK: - Round fuzz

    /// The only non-rectangular body in the catalog, and the entire point of it:
    /// a round footprint is recognisable at stage scale from any angle, which no
    /// amount of colour on a box ever was. Built as puck + torus shoulder + cap
    /// rather than a sphere, because a sphere's lower half would dip below the
    /// board and drag the bounding box (and therefore the AR base offset) with it.
    private static func buildRoundFuzz(_ e: PedalEnclosure, into group: SCNNode) {
        let radius = e.width / 2
        let top = Float(e.height)
        let pipe: CGFloat = 0.12
        let mat = Studio3D.pbr(e.color, metalness: 0.4, roughness: 0.38)

        let puck = SCNCylinder(radius: radius, height: e.height - 0.12)
        puck.radialSegmentCount = 36
        puck.materials = [mat]
        let puckNode = SCNNode(geometry: puck)
        puckNode.position = SCNVector3(0, Float(e.height - 0.12) / 2, 0)
        group.addChildNode(puckNode)

        let shoulder = SCNTorus(ringRadius: radius - pipe, pipeRadius: pipe)
        shoulder.ringSegmentCount = 36
        shoulder.pipeSegmentCount = 10
        shoulder.materials = [mat]
        let shoulderNode = SCNNode(geometry: shoulder)
        shoulderNode.position = SCNVector3(0, Float(e.height - 0.12), 0)
        group.addChildNode(shoulderNode)

        let cap = SCNCylinder(radius: radius - pipe, height: 0.12)
        cap.radialSegmentCount = 36
        cap.materials = [mat]
        let capNode = SCNNode(geometry: cap)
        capNode.position = SCNVector3(0, top - 0.06, 0)
        group.addChildNode(capNode)

        addControls(e, top: top, backZ: -0.26, usable: 0.86, pitch: 0.56, to: group)
        addFootswitch(radius: 0.17, at: SCNVector3(0, top + 0.05, 0.34), to: group)
        addLED(e.led, radius: 0.045, at: SCNVector3(0, top + 0.015, 0.04), to: group)
    }

    // MARK: - Looper deck

    private static func buildLooperDeck(_ e: PedalEnclosure, into group: SCNNode) {
        let top = Float(e.height)
        let halfL = Float(e.length) / 2
        let bodyMat = Studio3D.pbr(e.color, metalness: 0.35, roughness: 0.42)
        Studio3D.addBox(e.width, e.height, e.length, chamfer: 0.05, mat: bodyMat,
                        at: SCNVector3(0, top / 2, 0), to: group)

        // The readout a looper needs and a stompbox doesn't.
        let panelMat = Studio3D.pbr(UIColor(white: 0.06, alpha: 1), metalness: 0.1, roughness: 0.25)
        Studio3D.addBox(0.74, 0.05, 0.36, chamfer: 0.02, mat: panelMat,
                        at: SCNVector3(-0.32, top + 0.01, -halfL + 0.32), to: group)

        // Level knob to the right of the readout rather than centred — the panel
        // owns the middle of the back face.
        let knobMat = Studio3D.pbr(UIColor(white: 0.85, alpha: 1), metalness: 0.1, roughness: 0.5)
        let pointerMat = Studio3D.pbr(.black, metalness: 0, roughness: 0.5)
        let knob = knobNode(radius: 0.10, mat: knobMat, pointerMat: pointerMat)
        knob.position = SCNVector3(0.58, top + 0.055, -halfL + 0.32)
        group.addChildNode(knob)

        // Two footswitches side by side — the shape's whole tell.
        addFootswitch(radius: 0.17, at: SCNVector3(-0.46, top + 0.05, halfL - 0.30), to: group)
        addFootswitch(radius: 0.17, at: SCNVector3(0.46, top + 0.05, halfL - 0.30), to: group)

        // ONE status lamp between them, named `led` so `ARFloorPedals.setLED`
        // still finds it: the AR page lights "this pedal is engaged", which is a
        // single fact, and two lamps would only pose the question of which.
        addLED(e.led, radius: 0.055, at: SCNVector3(0, top + 0.02, halfL - 0.30), to: group)
    }

    // MARK: - Rockers (wah and volume/expression)

    /// A real hinged assembly, not a tilted lid.
    ///
    /// THE PIVOT IS THE POINT. A treadle rotated about its own centre see-saws:
    /// the heel rises as the toe falls and the thing reads as a floating plank.
    /// So the plate is a CHILD of an empty pivot node parked at the hinge (top of
    /// the heel block, at the end nearest the player) and offset half its length
    /// forward from there. Rotating the pivot then swings the plate about the
    /// hinge, with the heel staying put — which is what a rocker does.
    ///
    /// Orientation follows the rest of the board: +z is toward the player, so the
    /// heel is at +z and the toe points away at −z. A POSITIVE x-rotation lifts
    /// the toe, which is what `Studio3D.treadleAngle` returns for a low
    /// `Position`. Change one of those and you must change the other.
    private static func buildRocker(_ e: PedalEnclosure, into group: SCNNode) {
        let isWah = e.archetype == .wahRocker
        let halfL = Float(e.length) / 2
        let halfW = Float(e.width) / 2
        let chassisTop = Float(e.height)

        let bodyMat = Studio3D.pbr(e.color, metalness: 0.45, roughness: 0.4)
        let darkMat = Studio3D.pbr(darken(e.color, 0.45), metalness: 0.35, roughness: 0.45)

        // Chassis: long, low, and tapered by construction — a flat pan with a
        // taller block at the heel, which is the wedge profile a rocker has.
        Studio3D.addBox(e.width, e.height, e.length, chamfer: 0.06, mat: bodyMat,
                        at: SCNVector3(0, chassisTop / 2, 0), to: group)

        let heelHeight: CGFloat = isWah ? 0.30 : 0.40
        let heelLength: CGFloat = 0.70
        let heelZ = halfL - Float(heelLength) / 2 - 0.02
        Studio3D.addBox(e.width, heelHeight, heelLength, chamfer: 0.06, mat: bodyMat,
                        at: SCNVector3(0, chassisTop + Float(heelHeight) / 2, heelZ), to: group)
        let hingeY = chassisTop + Float(heelHeight)

        // Side rails. They frame the treadle and stop it reading as a lid lying
        // loose on a box; on the real thing they are the chassis walls the pot
        // and the rack live between.
        let railLength = e.length - heelLength - 0.14
        let railZ = -halfL + Float(railLength) / 2 + 0.06
        for side in [-1, 1] as [Float] {
            Studio3D.addBox(0.12, 0.22, railLength, chamfer: 0.04, mat: darkMat,
                            at: SCNVector3(side * (halfW - 0.06), chassisTop + 0.11, railZ), to: group)
        }

        // The pivot lives at the hinge; the plate hangs off it toward the toe.
        let pivot = SCNNode()
        pivot.name = ProceduralPedal.treadleNodeName
        pivot.position = SCNVector3(0, hingeY, heelZ - Float(heelLength) / 2)
        group.addChildNode(pivot)

        let plateLength = e.length - heelLength - 0.24
        let plateMat = Studio3D.pbr(UIColor(white: 0.13, alpha: 1), metalness: 0.3, roughness: 0.55)
        let plate = SCNBox(width: e.width - 0.30, height: 0.10, length: plateLength, chamferRadius: 0.03)
        plate.materials = [plateMat]
        let plateNode = SCNNode(geometry: plate)
        plateNode.position = SCNVector3(0, 0.05, -Float(plateLength) / 2 - 0.02)
        pivot.addChildNode(plateNode)

        // Ribbed tread. `WahArt` draws four bars on the 2D card; matching the
        // count keeps the card and the stage describing the same object.
        Studio3D.addGripRidges(count: isWah ? 4 : 5, width: e.width - 0.46,
                               spacing: CGFloat(Float(plateLength) / Float(isWah ? 5 : 6)),
                               atY: 0.055, mat: Studio3D.pbr(UIColor(white: 0.05, alpha: 1),
                                                             metalness: 0.2, roughness: 0.7),
                               to: plateNode)

        // A volume pedal has no lamp in real life, but `ARFloorPedals.setLED`
        // resolves engagement by a node named `led` on EVERY archetype — so it
        // gets one, tucked low on the heel where a real one would be an
        // afterthought rather than a face feature.
        if isWah {
            addLED(e.led, radius: 0.05, at: SCNVector3(0, chassisTop + 0.02, -halfL + 0.16), to: group)
        } else {
            addLED(e.led, radius: 0.04, at: SCNVector3(halfW - 0.04, chassisTop + 0.06, heelZ), to: group)
        }
    }

    // MARK: - Shared detail

    /// `pitch` caps how far apart adjacent knobs are allowed to sit, so two
    /// controls on a big enclosure cluster like real ones instead of hugging the
    /// edges — except on the round fuzz, whose two knobs genuinely do span it.
    private static func addControls(_ e: PedalEnclosure, top: Float, backZ: Float,
                                    usable: Float, pitch: Float = 0.30, to group: SCNNode) {
        guard e.knobs > 0 else { return }
        let knobMat = Studio3D.pbr(UIColor(white: 0.85, alpha: 1), metalness: 0.1, roughness: 0.5)
        let pointerMat = Studio3D.pbr(.black, metalness: 0, roughness: 0.5)

        switch e.knobLayout {
        case .none:
            return
        case .centered:
            let knob = knobNode(radius: 0.11, mat: knobMat, pointerMat: pointerMat)
            knob.position = SCNVector3(0, top + 0.055, backZ)
            group.addChildNode(knob)
        case .row, .arc:
            placeRow(count: e.knobs, usable: usable, top: top, z: backZ,
                     bow: e.knobLayout == .arc ? 0.08 : 0, pitch: pitch,
                     knobMat: knobMat, pointerMat: pointerMat, to: group)
        case .twoRows:
            let back = (e.knobs + 1) / 2
            placeRow(count: back, usable: usable, top: top, z: backZ, bow: 0, pitch: pitch,
                     knobMat: knobMat, pointerMat: pointerMat, to: group)
            placeRow(count: e.knobs - back, usable: usable, top: top, z: backZ + 0.36, bow: 0,
                     pitch: pitch, knobMat: knobMat, pointerMat: pointerMat, to: group)
        case .sliders:
            placeSliders(count: e.knobs, usable: usable, top: top, z: backZ, to: group)
        }
    }

    private static func placeRow(count: Int, usable: Float, top: Float, z: Float, bow: Float,
                                 pitch: Float, knobMat: SCNMaterial, pointerMat: SCNMaterial,
                                 to group: SCNNode) {
        guard count > 0 else { return }
        let radius = min(0.105, CGFloat(usable / Float(count)) * 0.42)
        let span = count > 1 ? min(usable - 2 * Float(radius), Float(count - 1) * pitch) : 0
        let step = count > 1 ? span / Float(count - 1) : 0
        for i in 0..<count {
            let x = -span / 2 + Float(i) * step
            let knob = knobNode(radius: radius, mat: knobMat, pointerMat: pointerMat)
            // Bow the outer knobs toward the player: a Boss shelf is an arc, and
            // a dead-straight row on a curved shelf is the tell that it isn't one.
            let curve = span > 0 ? bow * (x / (span / 2)) * (x / (span / 2)) : 0
            knob.position = SCNVector3(x, top + Float(radius) * 0.55, z + curve)
            group.addChildNode(knob)
        }
    }

    private static func placeSliders(count: Int, usable: Float, top: Float, z: Float, to group: SCNNode) {
        let trackMat = Studio3D.pbr(UIColor(white: 0.07, alpha: 1), metalness: 0.1, roughness: 0.6)
        let capMat = Studio3D.pbr(UIColor(white: 0.82, alpha: 1), metalness: 0.15, roughness: 0.45)
        let span = usable - 0.14
        let step = count > 1 ? span / Float(count - 1) : 0
        let capWidth = min(CGFloat(step) * 0.7, 0.13)
        for i in 0..<count {
            let x = -span / 2 + Float(i) * step
            Studio3D.addBox(0.045, 0.03, 0.44, chamfer: 0.01, mat: trackMat,
                            at: SCNVector3(x, top + 0.01, z), to: group)
            Studio3D.addBox(capWidth, 0.055, 0.10, chamfer: 0.02, mat: capMat,
                            at: SCNVector3(x, top + 0.045, z), to: group)
        }
    }

    private static func knobNode(radius: CGFloat, mat: SCNMaterial, pointerMat: SCNMaterial) -> SCNNode {
        let knob = SCNCylinder(radius: radius, height: 0.11)
        knob.radialSegmentCount = 18
        knob.materials = [mat]
        let node = SCNNode(geometry: knob)

        let pointer = SCNBox(width: radius * 0.18, height: 0.12, length: radius * 0.52, chamferRadius: 0)
        pointer.materials = [pointerMat]
        let pointerNode = SCNNode(geometry: pointer)
        pointerNode.position = SCNVector3(0, 0.005, Float(radius) * 0.45)
        node.addChildNode(pointerNode)
        return node
    }

    private static func addFootswitch(radius: CGFloat, at p: SCNVector3, to group: SCNNode) {
        let fs = SCNCylinder(radius: radius, height: 0.12)
        fs.radialSegmentCount = 18
        fs.materials = [Studio3D.pbr(UIColor(white: 0.62, alpha: 1), metalness: 0.85, roughness: 0.28)]
        let node = SCNNode(geometry: fs)
        node.position = p
        group.addChildNode(node)
    }

    /// Every archetype gets exactly one node named `led`: `ARFloorPedals` looks
    /// it up BY NAME to light the pedal when its footswitch is engaged, so an
    /// archetype without one silently loses a shipped feature.
    private static func addLED(_ color: UIColor, radius: CGFloat, at p: SCNVector3, to group: SCNNode) {
        let led = SCNSphere(radius: radius)
        led.segmentCount = 12
        led.materials = [Studio3D.pbr(color, metalness: 0, roughness: 0.3, emission: color)]
        let node = SCNNode(geometry: led)
        node.name = ProceduralPedal.ledNodeName
        node.position = p
        group.addChildNode(node)
    }

    private static func darken(_ color: UIColor, _ factor: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return color }
        return UIColor(red: r * factor, green: g * factor, blue: b * factor, alpha: a)
    }

    // MARK: - Finish (mirrors GearArt's PedalArt spec)

    private static func finish(for pedal: GearItem) -> (color: UIColor, led: UIColor) {
        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
            UIColor(red: r, green: g, blue: b, alpha: 1)
        }
        let amber = c(1.0, 0.72, 0.2)
        let green = c(0.3, 0.9, 0.35)
        let n = pedal.name.lowercased()

        if n.contains("tube screamer") { return (c(0.36, 0.55, 0.20), amber) }
        if n.contains("big muff")      { return (c(0.85, 0.84, 0.80), amber) }
        if n.contains("dyna")          { return (c(0.70, 0.16, 0.14), amber) }
        if n.contains("phase")         { return (c(0.92, 0.46, 0.09), amber) }
        if n.contains("distortion")    { return (c(0.93, 0.50, 0.10), amber) }
        if n.contains("metal zone")    { return (c(0.20, 0.20, 0.22), amber) }
        if n.contains("procon rat")    { return (c(0.18, 0.18, 0.20), amber) }
        if n.contains("centaur")       { return (c(0.62, 0.14, 0.13), amber) }
        if n.contains("king of tone")  { return (c(0.62, 0.44, 0.76), amber) }
        if n.contains("memory man")    { return (c(0.15, 0.15, 0.17), amber) }
        if n.contains("fuzz face")     { return (c(0.16, 0.30, 0.55), amber) }
        if n.contains("loop station")  { return (c(0.80, 0.13, 0.13), green) }
        if n.contains("chromatic tuner") { return (c(0.88, 0.88, 0.86), green) }

        switch pedal.category {
        case .delay:      return (c(0.20, 0.45, 0.30), amber)
        case .reverb:     return (c(0.10, 0.44, 0.48), amber)
        case .modulation: return (c(0.16, 0.40, 0.70), amber)
        case .compressor: return (c(0.70, 0.16, 0.14), amber)
        case .tuner:      return (c(0.62, 0.64, 0.66), green)
        case .eq:         return (c(0.62, 0.64, 0.66), amber)
        case .pitch:      return (c(0.16, 0.40, 0.70), amber)
        case .looper:     return (c(0.88, 0.88, 0.86), green)
        // Wahs and volume pedals are black castings almost without exception —
        // and `GearArtView.panelColor` already draws them at white 0.16.
        case .wah:        return (c(0.15, 0.15, 0.16), amber)
        case .volume:     return (c(0.13, 0.13, 0.14), amber)
        default:          return (c(0.30, 0.30, 0.32), amber)
        }
    }
}
