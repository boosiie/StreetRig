//
//  ARFloorPedalboard.swift
//  StreetRig
//
//  The board the AR floor pedals stand on: a tiered, raked, open-frame chassis in
//  METRES, parented to the same world anchor the pedals are, plus the deck-mount
//  math that puts a pedal ON it rather than beside it.
//
//  WHY THIS EXISTS. The page is used with the phone propped on the floor aimed at
//  the player's feet, and the player stomps real feet at virtual pedals mid-song.
//  Without a board those pedals are three unrelated objects floating on a carpet:
//  there is no ground plane to judge distance against, nothing that says where the
//  row begins and ends without reading a label, and — worst — an empty slot reads
//  as a rendering failure rather than as an empty mounting spot. A board fixes all
//  three at once, for someone standing up, looking down, in the middle of a song.
//
//  THIS REVERSES A DECISION `ARFloorPedals` DOCUMENTS. That file says "A pedal lies
//  flat on the floor; it does not tip toward the phone." Under a board the first
//  half stops being true and the second half becomes MORE important: a pedal
//  mounted here tilts, but it tilts because the DECK is raked, never because the
//  camera moved. `mountOrientation(facing:)` is the whole of that promise — it is
//  the pedal's own fixed heading, turned into the deck's plane, and there is
//  nowhere in it for a camera position to enter. A pedal that tips to follow the
//  phone stops being an object.
//
//  WHAT IS DERIVED AND WHAT IS CHOSEN. `width` is DERIVED — from
//  `ARPlacementCoordinator.slotSpacing` (0.30 m, an ergonomic choice about FEET,
//  documented at the constant) plus `ARFloorPedals.pedalWidth` plus a frame margin.
//  It is deliberately NOT a catalogue dimension: a real 24" Pedaltrain is ~0.60 m,
//  and a 0.60 m board under centres 0.60 m apart leaves the outer two pedals
//  hanging off its edges — which looks broken, and tells the player the outer
//  targets are not really there. Authenticity here lives in PROPORTION (depth is
//  the Classic 2's 12.5"/24" ratio of the derived width), in tiering, in the slat
//  pattern and in the finish; it does not live in absolute centimetres. `rake`,
//  `frontRailTop`, `mountInsetZ` and `tierStep` are chosen, from the proportions of
//  a raked pro board rather than measured off one.
//
//  WHY NOT `PedalboardScene.boardNode`. That board is authored in the rig diorama's
//  units (a pedal is 1.1 across, spacing 1.5) and is a flat slab with no rake, no
//  tiers and no frame. Reusing it would mean scaling a slab into a room. What IS
//  shared is `Studio3D` — the same `pbr` material family and the same lighting
//  helpers — so this board belongs to the same object family as the rig-stage one
//  without inheriting its geometry.
//
//  THE LOCAL FRAME, ONCE, SO NOTHING HAS TO GUESS IT.
//    +X — along the slot row (the lateral axis `ARPlacementCoordinator.slotOffsets`
//         laid the three centres out on).
//    +Y — up, away from the floor. y = 0 IS the floor: the feet sit a hair below it
//         on purpose (see `floorBite`).
//    +Z — TOWARD the player. So the deck rises toward −Z, i.e. up and AWAY, which
//         is the direction a real board rakes. Get this backwards and the board is
//         a ramp sloping away from the person standing on it.
//
//  FLOOR CONTACT. Real carpet is uneven and ARKit's plane estimate drifts. A board
//  hovering a centimetre above the floor destroys the illusion instantly; a board
//  sunk a millimetre into it is invisible. So the feet are modelled to end just
//  BELOW y = 0 rather than exactly on it.
//

import SceneKit
import UIKit
import simd

// MARK: - Where the board sits, and what everything mounted on it inherits

/// The one frame every mounted thing shares: where the board's floor-level origin
/// is in the anchor's space, which way its rails run, and how far the deck is raked.
///
/// Derived from `ARFloorPose` and NOTHING ELSE. That is the point — the pose already
/// carries the deck-lifted slot centres that the SwiftUI chrome projects and that
/// `slotCentersX` bins stomps against, so building the board's placement from the
/// same value is what stops the SceneKit node, the label and the stomp binner from
/// each arriving at their own idea of how high a pedal is.
///
/// THE ROW, NOT `facing`, DECIDES WHICH WAY THE RAILS RUN. `facing` is a yaw toward
/// where the CAMERA stood; the row was laid out along a lateral axis derived from
/// the camera's screen-right. Those two are perpendicular when the player taps near
/// the middle of the frame and drift apart when they tap near its edge. Taking the
/// board's heading from the row itself means the rails can never end up at an angle
/// to the pedals standing on them — the failure that would push the outer two off
/// the board's edge, which is exactly what this board exists to prevent.
nonisolated struct ARDeckFrame {
    /// The board's own origin — floor level, under the centre slot — in anchor space.
    var origin: simd_float3
    /// Rotation about the anchor's +Y that turns the board's local +X onto the row.
    var yaw: Float
    /// That same local +X, expressed in anchor space. The rake turns about THIS, so a
    /// pedal keeping its own heading still lands flush on the deck's plane.
    var lateral: simd_float3
    /// Pitch of the deck, in radians. Zero when the board is switched off, which is
    /// what makes the flag-off path arithmetically identical to the old flat row.
    var rake: Float

    /// Fails rather than guesses: a pose with the wrong number of slots, or a row
    /// collapsed to a point, has no lateral axis and would silently produce a board
    /// pointing in an arbitrary direction.
    init?(_ pose: ARFloorPose) {
        guard pose.offsets.count == 3 else { return nil }
        var row = pose.offsets[2].xyz - pose.offsets[0].xyz
        row.y = 0
        guard simd_length(row) > 1e-4 else { return nil }
        row = simd_normalize(row)

        // A rotation of β about +Y sends local +X to (cos β, 0, −sin β), so this is
        // the β that puts the rails on the row.
        var beta = atan2(-row.z, row.x)
        // …and that leaves TWO answers, β and β + π, because a row has two ends. The
        // board is symmetric in x so either would look identical — except that local
        // +Z has to end up pointing at the PLAYER, or the rake slopes the wrong way
        // and the board becomes a ramp. `facing` is the only thing that knows where
        // the player was, so it settles it. (β + π mirrors the row too, which is
        // harmless precisely because the three slots are evenly spaced.)
        let toPlayer = simd_float2(sin(pose.facing), cos(pose.facing))
        if simd_dot(simd_float2(sin(beta), cos(beta)), toPlayer) < 0 { beta += .pi }

        self.yaw = beta
        self.lateral = simd_float3(cos(beta), 0, -sin(beta))
        self.rake = pose.deckRake
        // The slot centres in the pose are already ON the deck; the board itself is
        // built from its floor origin, so the lift comes back off here. One
        // subtraction, in one place, of a number the pose carried in.
        let centre = pose.offsets[1].xyz
        self.origin = simd_float3(centre.x, centre.y - pose.deckLift, centre.z)
    }

    /// What a pedal standing on the deck is turned by: THE BOARD'S OWN heading, then
    /// the deck's rake about the row axis. Exactly the deck's orientation, so a pedal
    /// is square to the rails it stands on.
    ///
    /// THIS TOOK `facing` AND NO LONGER DOES, WHICH IS THE POINT. Turning each pedal
    /// by `facing` aimed the three of them at the phone individually; whenever the
    /// row and the player's direction disagreed — which was most taps — that showed
    /// up as pedals sitting cocked at an angle on a board pointing somewhere else.
    /// Reading the heading off the deck makes "square on the board" structural
    /// rather than something that happens to be true when you tap dead centre. The
    /// board as a whole is what faces the player now; see `init`, where the row it
    /// gets that heading from is itself laid out across the player's line of sight.
    ///
    /// The ORDER is the reason a pedal sits FLUSH. Yaw alone leaves the base plane
    /// horizontal; tilting the already-yawed pedal about the deck's own lateral axis
    /// lands that base plane exactly in the deck's plane. Tilting about the PEDAL's
    /// local x instead would leave it rocking on one corner.
    var mountOrientation: simd_quatf {
        let heading = simd_quatf(angle: yaw, axis: simd_float3(0, 1, 0))
        guard rake != 0 else { return heading }
        return simd_mul(simd_quatf(angle: rake, axis: lateral), heading)
    }
}

// MARK: - The board

nonisolated enum ARFloorPedalboard {

    // MARK: Dimensions
    //
    // Every number below is metres or radians. The first three are DERIVED from the
    // page's own ergonomics; the rest are proportions.

    /// Frame either side of the outermost pedal. Small on purpose: it is a frame
    /// rail and a finger's worth of deck, not a shelf.
    static let frameMargin: Float = 0.05

    /// Outer centres sit at ±`slotSpacing`, each pedal is `pedalWidth` across, and
    /// the frame closes over both ends. ≈ 0.78 m — wider than any board you can buy,
    /// and exactly as wide as the row it has to hold. See the header.
    static let width: Float = 2 * ARPlacementCoordinator.slotSpacing
                            + ARFloorPedals.pedalWidth
                            + 2 * frameMargin

    /// A stompbox is about a third again as deep as it is wide — the procedural
    /// model measures close to this, and so does the real thing. EVERY front-to-back
    /// number below is built from the result, so that growing `pedalWidth` grows the
    /// board around the pedal instead of leaving it hanging off the front.
    static let pedalDepthRatio: Float = 1.32
    static let pedalDepth: Float = ARFloorPedals.pedalWidth * pedalDepthRatio

    /// Deck left visible in front of the pedal's leading edge, and behind its
    /// trailing one before the rear tier steps up. Margin the eye can see is what
    /// says "on the board" rather than "balanced on the edge of one".
    static let frontClearance: Float = 0.055
    static let rearClearance: Float = 0.045
    /// Shallowest rear tier that still reads as a tier rather than a lip.
    static let minRearTierDepth: Float = 0.10

    /// Pedaltrain Classic 2 is 24" × 12.5". The RATIO is the authentic part; the
    /// absolute size is not, so the ratio is what gets kept — unless the pedal
    /// standing on it needs more room than the ratio gives, in which case the pedal
    /// wins. A board too shallow for its own gear is not made authentic by having
    /// the right proportions.
    static let depthRatio: Float = 12.5 / 24.0
    private static let ratioDepth: Float = width * depthRatio
    private static let requiredDepth: Float = mountInsetZ + pedalDepth / 2
                                            + rearClearance + minRearTierDepth
    static let depth: Float = max(ratioDepth, requiredDepth)

    /// How far the deck tilts up going away from the player. A raked pro board is
    /// somewhere around 8–12°; at 9° over this depth the back edge lifts ~6.3 cm,
    /// which is enough to read as a slope from standing height without turning the
    /// front lip into a trip hazard.
    static let rake: Float = 9 * .pi / 180

    /// Height of the deck's front lip above the floor. The lowest point of the deck,
    /// and the thing that decides how much of the frame is visible from the front.
    static let frontRailTop: Float = 0.030

    /// How far behind the front edge the pedals mount: half a pedal, plus the deck
    /// the eye needs to see in front of it. DERIVED from the pedal rather than
    /// chosen, so this cannot fall out of step with `pedalWidth`.
    static let mountInsetZ: Float = pedalDepth / 2 + frontClearance

    /// Where a pedal's base lands, straight up from the floor point of its slot.
    ///
    /// DERIVED, not chosen, and this is the number the whole feature turns on: the
    /// deck plane passes through the front lip and climbs at `rake`, so the mount
    /// line's height is fixed the moment those two are. Anything that re-guesses it
    /// somewhere else is the "silent wrongness" the AR files' headers are about.
    static let deckHeight: Float = frontRailTop + mountInsetZ * sin(rake)

    /// How far the rear tier steps up above the deck plane. Nothing mounts up there
    /// — three side-by-side slots do not fill two tiers — but a board without a rear
    /// tier does not look like a board, and this page's whole job is looking like
    /// what it is at a glance.
    static let tierStep: Float = 0.038

    /// How far the feet end BELOW y = 0. A hair of intersection with an uneven real
    /// floor beats any amount of visible float — see the header.
    static let floorBite: Float = 0.0015

    // MARK: The single source of truth for a mounted thing's placement
    //
    // Three consumers read slot position — the SceneKit pedal node, the projected
    // point `FloorSlotChrome` draws its label at, and `slotCentersX`, which decides
    // which slot a detected foot toggles. They agree because the lift is applied
    // ONCE, into `ARFloorPose.offsets` at lock time, and everything downstream
    // projects or positions those same numbers. These two are where that one
    // application reads its value from, and they are the only place the feature flag
    // is consulted.

    /// How far above the floor plane a mounted pedal's base sits — zero when the
    /// board is off, which is what makes flag-off reproduce the old flat row exactly.
    static var mountLift: Float { FeatureFlags.arPedalboard ? deckHeight : 0 }

    /// The deck's pitch, or zero when there is no deck.
    static var mountRake: Float { FeatureFlags.arPedalboard ? rake : 0 }

    /// A hair of clearance for the empty-slot ring, so it lies ON the rails instead
    /// of z-fighting through them. On a bare floor there is no geometry to fight,
    /// which is why this is zero when the board is off.
    static var ringLift: Float { FeatureFlags.arPedalboard ? 0.0008 : 0 }

    // MARK: Geometry

    /// Rail cross-sections. Thin, because the gaps between them are the point.
    private static let railThickness: Float = 0.013      // rails, in y
    private static let sideRailWidth: Float = 0.020      // side frame, in x
    private static let sideRailHeight: Float = 0.032     // side frame, in y

    /// The front lip, and the pair the pedal bridges. In Z, and derived from the
    /// pedal so the pair always lands UNDER it near its edges — a rail pattern that
    /// stopped matching the gear standing on it is just decoration.
    private static let lipThickness: Float = 0.034
    private static let mountRailThickness: Float = 0.032
    private static let mountRailZ: Float = pedalDepth / 2 - 0.022

    /// The deck's near and far edges, in the DECK's own frame (y = 0 is the mounting
    /// plane, +Z is toward the player).
    private static let frontEdgeZ: Float = mountInsetZ
    private static let rearEdgeZ: Float = mountInsetZ - depth

    /// Where the front tier stops and the step up begins: clear of the pedal's
    /// trailing edge. Derived, so a bigger pedal pushes the step back instead of
    /// growing into it.
    private static let tierSplitZ: Float = -(pedalDepth / 2 + rearClearance)

    /// The whole board, in metres, with its origin on the floor under the centre
    /// slot and its +X along the row.
    ///
    /// Built ONCE by the caller and cached — `ARFloorPedals.update` runs at up to
    /// 60 Hz and nothing here depends on which pedals are in the slots.
    @MainActor
    static func node() -> SCNNode {
        let root = SCNNode()
        root.name = "streetrig.pedalboard"

        // Dark powder coat, from the same material family as the rig-stage board
        // (`PedalboardScene.boardNode` uses white 0.12 / metal 0.25 / rough 0.7) so
        // this reads as the same object in a different room, not a new look invented
        // for this page.
        let railMat  = Studio3D.pbr(UIColor(white: 0.13, alpha: 1), metalness: 0.30, roughness: 0.60)
        let frameMat = Studio3D.pbr(UIColor(white: 0.09, alpha: 1), metalness: 0.40, roughness: 0.52)
        let footMat  = Studio3D.pbr(UIColor(white: 0.04, alpha: 1), metalness: 0.00, roughness: 0.92)

        // ---- The raked deck. Everything mounted lives in THIS node's frame, whose
        // y = 0 plane is the mounting plane the pedals' bases land on. Rotating
        // about local x through that origin is what keeps the three slot centres —
        // which lie on the x axis — exactly on the plane after the rake.
        let deck = SCNNode()
        deck.name = "deck"
        deck.simdPosition = simd_float3(0, deckHeight, 0)
        deck.eulerAngles.x = rake                    // +x tips the FAR end up; see the header
        root.addChildNode(deck)

        let halfWidth = width / 2
        let sideCentreX = halfWidth - sideRailWidth / 2
        let innerWidth = width - 2 * sideRailWidth
        let chamfer: CGFloat = 0.0015

        // ---- Side frame rails: the raked structural members, tops flush with the
        // deck so a pedal at the edge of the row still meets deck, not frame.
        for sign in [Float(-1), 1] {
            Studio3D.addBox(CGFloat(sideRailWidth), CGFloat(sideRailHeight), CGFloat(depth),
                            chamfer: chamfer, mat: frameMat,
                            at: SCNVector3(sign * sideCentreX,
                                           -sideRailHeight / 2,
                                           (frontEdgeZ + rearEdgeZ) / 2),
                            to: deck)
        }

        // ---- Front tier: an open slat pattern, not a slab. The gaps ARE the
        // pedalboard — a solid top at this size reads as a doormat.
        //
        // The lip rail closes the front edge; the two mounting rails straddle the
        // pedal about the mount line at z = 0, so a pedal bridges them the way it
        // would be zip-tied to a real board. All three positions come off
        // `pedalDepth`, so the pattern follows the gear when the gear changes size.
        addRail(z: frontEdgeZ - lipThickness / 2, thickness: lipThickness,
                top: 0, width: innerWidth, mat: frameMat, to: deck)
        addRail(z: mountRailZ, thickness: mountRailThickness,
                top: 0, width: innerWidth, mat: railMat, to: deck)
        addRail(z: -mountRailZ, thickness: mountRailThickness,
                top: 0, width: innerWidth, mat: railMat, to: deck)

        // ---- Rear tier: a step up, carried on two side risers plus a full-width
        // step face at its front so the change in level is visible head-on from
        // where the phone is lying rather than only from the sides.
        let rearTierFrontZ = tierSplitZ
        let rearTierCentreZ = (rearTierFrontZ + rearEdgeZ) / 2
        let rearTierDepth = rearTierFrontZ - rearEdgeZ
        for sign in [Float(-1), 1] {
            Studio3D.addBox(0.020, CGFloat(tierStep), CGFloat(rearTierDepth),
                            chamfer: chamfer, mat: frameMat,
                            at: SCNVector3(sign * (halfWidth - sideRailWidth - 0.010),
                                           tierStep / 2, rearTierCentreZ),
                            to: deck)
        }
        Studio3D.addBox(CGFloat(innerWidth), CGFloat(tierStep), 0.014,
                        chamfer: chamfer, mat: frameMat,
                        at: SCNVector3(0, tierStep / 2, rearTierFrontZ - 0.007),
                        to: deck)
        for z in [Float(-0.108), -0.192, -0.276] {
            addRail(z: z, thickness: 0.024, top: tierStep, width: innerWidth, mat: railMat, to: deck)
        }

        // ---- Legs, in the BOARD's frame rather than the deck's, because they have
        // to reach the FLOOR and the floor is not raked. Front pair short, rear pair
        // tall: that wedge silhouette is most of what says "raked" from the side.
        for sign in [Float(-1), 1] {
            addLeg(deckZ: 0.095, depth: 0.026, x: sign * sideCentreX, mat: frameMat, to: root)
            addLeg(deckZ: -0.268, depth: 0.030, x: sign * sideCentreX, mat: frameMat, to: root)
        }

        // ---- Feet. Rubber pads that end just below y = 0, so the board is standing
        // on the carpet rather than printed on it — see the header on floor contact.
        for sign in [Float(-1), 1] {
            for deckZ in [Float(0.095), -0.268] {
                Studio3D.addBox(0.030, CGFloat(footHeight + floorBite), 0.034,
                                chamfer: 0.001, mat: footMat,
                                at: SCNVector3(sign * sideCentreX,
                                               (footHeight - floorBite) / 2,
                                               deckZ * cos(rake)),
                                to: root)
            }
        }
        return root
    }

    /// How far the legs hold the frame off the floor. The feet fill this gap.
    private static let footHeight: Float = 0.006

    /// One slat, running the full inner width with its top face at `top` in the
    /// deck's frame. Top faces are what a pedal's base rests on, so they are given
    /// directly rather than as a centre — a rail whose thickness changes must not
    /// move the surface things are standing on.
    @MainActor
    private static func addRail(z: Float, thickness: Float, top: Float, width: Float,
                                mat: SCNMaterial, to deck: SCNNode) {
        Studio3D.addBox(CGFloat(width), CGFloat(railThickness), CGFloat(thickness),
                        chamfer: 0.0015, mat: mat,
                        at: SCNVector3(0, top - railThickness / 2, z),
                        to: deck)
    }

    /// One leg, from the feet up to the underside of the raked side rail above it.
    ///
    /// `deckZ` is where it meets that rail in the DECK's frame; both its height and
    /// its position come out of the same rotation the deck node applies, so a change
    /// to `rake` moves the rail and the leg together instead of leaving one hanging.
    @MainActor
    private static func addLeg(deckZ: Float, depth: Float, x: Float,
                               mat: SCNMaterial, to root: SCNNode) {
        // The rail's underside at deckZ, brought back into the board's frame.
        let railBottom = deckHeight - sideRailHeight * cos(rake) - deckZ * sin(rake)
        let height = max(railBottom - footHeight, 0.001)
        Studio3D.addBox(CGFloat(sideRailWidth + 0.008), CGFloat(height), CGFloat(depth),
                        chamfer: 0.0015, mat: mat,
                        at: SCNVector3(x, footHeight + height / 2, deckZ * cos(rake)),
                        to: root)
    }
}

// MARK: - Seeing it without ARKit
//
// ARKit does not run in the Simulator, so the AR path cannot be looked at there at
// all — and "it compiled" is not evidence that a board is raked the right way, that
// its tiers are in proportion, or that a pedal is standing on the deck rather than
// through it. This harness drops the REAL board node and the REAL slot contents into
// a plain `SCNScene` with `Studio3D`'s camera and lighting, so all of that can be
// seen on a plain iPhone screenshot. It renders no AR anything and knows nothing
// about anchors.
//
// It goes through `ARDeckFrame` and `ARFloorPedals.slotContent` rather than
// re-deriving a mount, for the obvious reason: a preview that builds its own layout
// verifies the preview.

#if DEBUG
import SwiftUI
import StreetRigEngine

struct ARFloorPedalboardPreview: UIViewRepresentable {
    /// Slot contents, in row order. A nil is an empty mounting spot — which is one
    /// of the things this harness exists to look at.
    var pedals: [GearItem?]
    /// Which slot to show the hover glow on, if any. The other thing that can only be
    /// judged by looking: whether a green pool on a dark deck actually reads as "this
    /// one" from the distance a standing player is at.
    var hovered: Int?
    /// Which slots to show the persistent ON column on. Harness-only.
    var engaged: [Bool] = [false, false, false]

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = Self.scene(pedals: pedals, hovered: hovered, engaged: engaged)
        view.pointOfView = view.scene?.rootNode.childNode(withName: "camera", recursively: false)
        view.backgroundColor = UIColor(white: 0.03, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = true          // a harness; orbiting it is the point
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}

    static func scene(pedals: [GearItem?], hovered: Int? = nil,
                      engaged: [Bool] = [false, false, false]) -> SCNScene {
        let scene = SCNScene()

        // A pose the AR page would have produced: identity anchor, the row along the
        // anchor's +X at the deck's own lift, and a player standing at +Z.
        let lift = ARFloorPedalboard.mountLift
        let spacing = ARPlacementCoordinator.slotSpacing
        let pose = ARFloorPose(anchor: matrix_identity_float4x4,
                               offsets: [simd_float4(-spacing, lift, 0, 1),
                                         simd_float4(0, lift, 0, 1),
                                         simd_float4(spacing, lift, 0, 1)],
                               facing: 0,
                               deckLift: lift,
                               deckRake: ARFloorPedalboard.mountRake)

        // The carpet. Not part of the board — it is here so floor contact and the
        // board's shadow can be judged at all, which is impossible against a void.
        let floor = SCNPlane(width: 3, height: 3)
        floor.materials = [Studio3D.pbr(UIColor(white: 0.14, alpha: 1), metalness: 0, roughness: 0.95)]
        let floorNode = SCNNode(geometry: floor)
        floorNode.eulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(floorNode)

        if let frame = ARDeckFrame(pose), FeatureFlags.arPedalboard {
            let board = ARFloorPedalboard.node()
            board.simdPosition = frame.origin
            board.simdOrientation = simd_quatf(angle: frame.yaw, axis: simd_float3(0, 1, 0))
            scene.rootNode.addChildNode(board)
        }

        let mount = ARDeckFrame(pose)?.mountOrientation
            ?? simd_quatf(angle: pose.facing, axis: simd_float3(0, 1, 0))
        for index in 0..<3 {
            let slot = SCNNode()
            slot.simdPosition = pose.offsets[index].xyz
            slot.simdOrientation = mount
            slot.addChildNode(ARFloorPedals.slotContent(pedals.indices.contains(index) ? pedals[index] : nil))
            if index == hovered {
                let halo = ARFloorPedals.makeHalo()
                halo.isHidden = false
                slot.addChildNode(halo)
            }
            if pedals.indices.contains(index), pedals[index] != nil {
                let mark = ARFloorPedals.makeStateMark()
                mark.isHidden = false
                let on = engaged.indices.contains(index) && engaged[index]
                mark.childNodes.forEach {
                    $0.isHidden = ($0.name == "streetrig.stateOn") != on
                }
                slot.addChildNode(mark)
            }
            scene.rootNode.addChildNode(slot)
        }

        Studio3D.addLighting(to: scene)
        // About 40 cm up and 84 cm out — a shallow ~20° look down the row, which is
        // roughly what a phone propped on its case sees from a metre away. Height
        // was traded down deliberately: from directly above, a 9° rake is invisible
        // and the rear tier flattens into the front one, so a comfortable three-
        // quarter view would verify the least interesting thing about this geometry.
        //
        // Pulled back with the board: `width` grew by about a sixth when the pedals
        // did, and a harness that crops the frame rails is a harness that cannot see
        // the one failure it exists to catch — a pedal hanging off the end.
        Studio3D.addCamera(to: scene, position: SCNVector3(0, 0.40, 0.84), tilt: -0.36, fov: 42)
        return scene
    }
}

#Preview("Board · three pedals") {
    ARFloorPedalboardPreview(pedals: [
        GearItem(name: "Iberon Valve Shrieker", category: .overdrive),
        GearItem(name: "VOSS Digital Delay", category: .delay),
        GearItem(name: "VOSS Reverb", category: .reverb),
    ])
    .background(RigTheme.background)
    .preferredColorScheme(.dark)
}

#Preview("Board · foot hovering slot 1") {
    ARFloorPedalboardPreview(pedals: [
        GearItem(name: "Iberon Valve Shrieker", category: .overdrive),
        GearItem(name: "VOSS Digital Delay", category: .delay),
        GearItem(name: "VOSS Reverb", category: .reverb),
    ], hovered: 1, engaged: [false, false, true])
    .background(RigTheme.background)
    .preferredColorScheme(.dark)
}

#Preview("Board · one slot empty") {
    ARFloorPedalboardPreview(pedals: [
        GearItem(name: "Iberon Valve Shrieker", category: .overdrive),
        nil,
        GearItem(name: "VOSS Reverb", category: .reverb),
    ])
    .background(RigTheme.background)
    .preferredColorScheme(.dark)
}
#endif
