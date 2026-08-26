//
//  StageEnvironment.swift
//  StreetRig
//
//  The ground the rig stands on: a real modelled club stage — wooden platform,
//  mic stand, stool, coiled cables, a floor box, a lamp overhead — in place of the
//  nothing that used to be there. Before this, gear floated on a flat SwiftUI
//  colour with a radial-gradient blob painted underneath (`Studio3D.addContactShadow`),
//  which is why photoreal gear read as pasted-on: it was asking a fake environment
//  for reflections and contact that did not exist.
//
//  THE ASSET is third-party and attributed — see `Credits.entries` and
//  `CreditsView`. CC BY 4.0 requires the attribution to remain reachable in the
//  shipped app, so the credit is a UI surface, not a comment.
//
//  WHAT GETS STRIPPED — the source scene ships a bass and two combo amps standing
//  on the platform. StreetRig draws its own gear, so those three are removed at
//  load (`propNodeNames`) and only the `Scene` mesh survives. They are separate
//  nodes, so this is a name match, not surgery. Their TEXTURES still ship inside
//  the .usdz (~1.9 MB of the 5.5 MB); reclaiming that would mean re-authoring the
//  file in Blender, which is a bigger change than it is worth and would fork the
//  asset away from the one being credited.
//
//  FITTING — the model arrives in centimetre-ish units (its floor disc is ~318
//  across) with the boards at y ≈ 2.58, NOT at its origin. The diorama expects a
//  floor at y = 0 with gear standing on it. `node()` therefore measures the disc,
//  scales it to `targetDiameter`, and lifts it so the boards — not the bounding
//  box — land on y = 0. Measuring rather than hardcoding means swapping the .usdz
//  for another stage does not silently sink every piece of gear.
//
//  PROPS — the stage is one mesh, so its stool, cables and litter are not nodes
//  you can move; they are runs of triangles. `props` names each one as a cylinder
//  in the asset's own coordinates and `reshape` cuts it out into its own node, so
//  the stool can be resized to something a guitar can lean on and the drink can on
//  the boards can go. See `Prop`.
//

import SceneKit
import simd
import UIKit

enum StageEnvironment {

    // MARK: Tunables

    /// The bundled file, resolved the same flat way as every other model.
    static let fileName = "stage-environment"

    /// Nodes dropped at load: the source scene's own bass and combo amps.
    /// Matched case-insensitively on a substring of the node name.
    private static let propNodeNames = ["bass", "comb"]

    /// How wide the platform reads in diorama units.
    ///
    /// This is a REAL-WORLD calibration, not a taste call. The model's mic stand
    /// runs ~105 units above the deck; a mic stand is about 1.5 m, which puts the
    /// asset at roughly 70 units per metre and makes its disc ~4.5 m across. The
    /// diorama runs about 1.7–1.85 units per metre (the amp stack is 3.0 units for
    /// a ~1.8 m stack; the guitar 1.85 units for a ~1 m guitar), so 4.5 m lands
    /// near 8. Sized by eye instead, the props lie: at 11 the bar stool stood
    /// taller than the guitar.
    ///
    /// 8.5 takes the half-step up from the strict 8.0 because the viewport is wide
    /// and landscape, and the extra stage reads better than the ~10% proportion
    /// error costs.
    private static let targetDiameter: Float = 8.5

    /// Geometry higher than this ABOVE THE DECK is cropped away at load.
    ///
    /// The source scene hangs a tray of drinks near its ceiling. In its own room
    /// that reads fine; lifted onto a bare diorama with no walls it is a plank
    /// floating over the amp, which reads as a bug. The mic stand is the tallest
    /// thing worth keeping (~1.5 m ≈ 2.6 units), and the amp stack is 3.0, so 3.6
    /// clears everything real and drops the tray. Expressed in DIORAMA units and
    /// converted to model units per `scale`, so retuning `targetDiameter` cannot
    /// silently start clipping the mic stand.
    private static let cropHeightAboveDeck: Float = 3.6

    /// Spin about the disc centre. At 0° the model's mic stand stands exactly where
    /// the amp goes and the stool hides behind it. 240° swings the stool out to
    /// stage right beside the guitar, sweeps the cables into the empty foreground,
    /// and leaves the mic boom pointed at the cab — which is where you would put a
    /// mic anyway. Changing this rotates the props, never the disc.
    private static let yaw: Float = 240 * .pi / 180

    /// Where the disc centres, in the diorama's x/z. This is the centroid of the
    /// amp (−0.1, −0.9), pedalboard (−0.1, 0.4) and guitar (1.8, −0.3), so the rig
    /// sits mid-platform rather than crowding one edge.
    private static let centre = SIMD2<Float>(0.5, -0.25)

    // MARK: Props modelled into the deck

    /// A prop that has to be treated separately from the boards it is modelled into.
    ///
    /// The stage is ONE mesh with one material, so a prop is not a node you can move
    /// — it is a run of triangles. Each entry names a vertical cylinder in the ASSET'S
    /// OWN coordinates (model units, measured out from the disc centre) plus what to
    /// do with the triangles wholly inside it. Model units on purpose: those numbers
    /// are a fact about the .usdz, so retuning `targetDiameter`, `yaw` or `centre`
    /// cannot quietly point them at the wrong prop.
    ///
    /// Radii are generous — each is roughly half the distance to the nearest prop
    /// that must NOT be caught — because the test is all-three-corners-inside, so a
    /// wide cylinder still cannot swallow a neighbour or a slice of the floor.
    private struct Prop {
        let name: String
        let centre: SIMD2<Float>
        let radius: Float
        /// Ceiling on the prop, in DIORAMA units above the floor. Without it the
        /// cable's cylinder — which has to be wide, because the coil sprawls right
        /// across the boards — reaches up and claims the ceiling tray as well.
        let maxHeightAboveFloor: Float
        let action: Action

        enum Action {
            case remove
            /// Uniform scale about the prop's own footprint centre AT FLOOR LEVEL,
            /// so a shrunk prop keeps its feet on the boards instead of hovering.
            case resize(Float)
        }
    }

    /// Ordered SMALLEST FIRST, and that matters: the floor cable's coil sprawls far
    /// enough that its cylinder encloses the mic stand entirely. First match wins, so
    /// the tight props claim their own components before the sprawling one can.
    private static let props: [Prop] = [
        // A drink can lying on the boards, stage left. It read as litter beside gear
        // the user chose, and at the default camera it was the nearest thing to the
        // lens — nothing else in the scene sits that far forward — so it drew the eye
        // first.
        Prop(name: "can", centre: SIMD2(57.27, 42.27), radius: 14,
             maxHeightAboveFloor: 0.5, action: .remove),

        // A loose pedal-sized floor box with knobs, upstage right. StreetRig draws the
        // user's own pedalboard a few units away; a second, fake one that cannot be
        // tapped or swapped just reads as a bug in the rig.
        Prop(name: "floorPedal", centre: SIMD2(-64.70, 0.42), radius: 12,
             maxHeightAboveFloor: 0.5, action: .remove),

        // Mic stand: tripod, column, boom and mic. It stood between the camera and the
        // cab with its boom across the amp's face, and the rig has no mic in it.
        Prop(name: "micStand", centre: SIMD2(-25.21, 29.23), radius: 42,
             maxHeightAboveFloor: 2.5, action: .remove),

        // The cable dangling from the ceiling to the boards. Runs the full height of
        // the scene, hence the tall limit.
        Prop(name: "hangingCable", centre: SIMD2(-19.27, 5.94), radius: 54,
             maxHeightAboveFloor: 4.5, action: .remove),

        // The coiled cable snaking over the boards. Widest prop on the stage: its own
        // bounding radius is 71, which is why this entry comes last.
        Prop(name: "floorCable", centre: SIMD2(-9.86, 51.60), radius: 80,
             maxHeightAboveFloor: 0.5, action: .remove),

        // The bar stool. The asset models it at 2.05 diorama units to the seat —
        // TALLER than the 1.85-unit guitar standing next to it, which is most of why
        // the stage read like a doll's house. 0.6 puts the seat at 1.23 (≈72 cm at
        // the diorama's ~1.7 units/m) and makes it 0.63 across (≈37 cm): a real bar
        // stool, and low enough that a guitar can lean on it — which is what
        // `RigDiorama` does with `stoolSeat`. The cup and case resting on the seat
        // are inside the cylinder too, so they scale with it and stay put.
        Prop(name: "stool", centre: SIMD2(-45.65, -63.03), radius: 32,
             maxHeightAboveFloor: 3.0, action: .resize(0.6)),
    ]

    /// Where the stool's seat came to rest, in DIORAMA space — the point a guitar
    /// leans against, and how wide the seat is.
    ///
    /// `nil` until `node()` has run, and stays `nil` when the asset is missing or
    /// carries no stool, in which case the guitar just stands up straight as it
    /// always did. `RigDiorama.make` reads this AFTER adding the stage, which it
    /// does first so the stage sits behind the gear in the node order.
    private(set) static var stoolSeat: SeatRest?

    struct SeatRest {
        /// Top centre of the seat.
        var centre: SCNVector3
        var radius: Float
    }

    // MARK: Loading

    /// The stage, fitted and placed, or `nil` when the asset is absent — in which
    /// case the diorama simply renders as it always did, on nothing.
    static func node() -> SCNNode? {
        guard let url = Bundle.main.url(forResource: fileName, withExtension: "usdz"),
              let scene = try? SCNScene(url: url, options: nil) else { return nil }

        let env = SCNNode()
        env.name = "stageEnvironmentMesh"
        for child in scene.rootNode.childNodes { env.addChildNode(child) }
        strip(propNodeNames, from: env)

        let verts = worldVertices(of: env)
        guard !verts.isEmpty else { return nil }

        let discWidth = max(extent(verts, \.x), extent(verts, \.z))
        guard discWidth > 0 else { return nil }
        let scale = targetDiameter / discWidth
        let surfaceY = floorSurfaceY(verts)
        let discCentre = SIMD2<Float>(midpoint(verts, \.x), midpoint(verts, \.z))

        // Resize or drop the props modelled into the mesh, BEFORE the crop below —
        // each becomes its own node, and the crop then covers those too.
        let propNodes = reshape(env, discCentre: discCentre, floorY: surfaceY, scale: scale)

        // Cut the ceiling props away before anything is placed. The limit is a
        // diorama height, converted here into the model's own units.
        crop(env, above: surfaceY + cropHeightAboveDeck / scale)

        // Three nested nodes so each transform stays independent and readable:
        // spin about the disc centre, then scale, then place on the floor.
        let spun = SCNNode()
        spun.addChildNode(env)
        env.position = SCNVector3(-discCentre.x, 0, -discCentre.y)   // origin → disc centre
        spun.eulerAngles = SCNVector3(0, yaw, 0)

        let scaled = SCNNode()
        scaled.addChildNode(spun)
        scaled.scale = SCNVector3(scale, scale, scale)

        let root = SCNNode()
        root.name = "stageEnvironment"
        root.addChildNode(scaled)
        root.position = SCNVector3(centre.x, -surfaceY * scale, centre.y)

        // The stage is scenery: it receives the key light's shadow (that contact is
        // most of why gear now looks planted) but never casts one of its own, which
        // would put the stool's shadow across the amp.
        env.enumerateHierarchy { n, _ in
            n.castsShadow = false
            n.renderingOrder = -10          // behind the gear, so alpha edges never fight
        }

        // Read the seat off the finished stool rather than deriving it from the
        // numbers above, so the guitar leaning on it cannot drift out of step with
        // the prop it is leaning on. Measured only now the node tree is assembled,
        // because that is what makes `convertPosition(to: nil)` diorama space.
        stoolSeat = seat(of: propNodes["stool"])
        return root
    }

    /// The stool's seat: the widest flat surface inside the prop, converted out to
    /// diorama space. The same rule that finds the boards under the whole stage,
    /// asked of one prop — a seat, like a floor, is the wide flat thing you put
    /// something on. Nil when there is no stool, or nothing flat in it.
    private static func seat(of stool: SCNNode?) -> SeatRest? {
        guard let stool else { return nil }

        // Measured in DIORAMA space, which is the only frame where "flat" means what
        // it sounds like. The .usdz is authored Z-up under a parent that rotates it
        // upright, so in the mesh's own space the stool is on its side and a scan for
        // horizontal surfaces finds nothing but the stool's silhouette.
        var toWorld = matrix_identity_float4x4
        var walker = stool.parent
        while let n = walker { toWorld = simd_float4x4(n.transform) * toWorld; walker = n.parent }
        let world = usedVertices(of: stool).map { p -> SIMD3<Float> in
            let q = toWorld * SIMD4<Float>(p, 1)
            return SIMD3(q.x, q.y, q.z)
        }

        guard let flat = widestFlatSurface(in: world, tolerance: 0.5) else { return nil }
        return SeatRest(centre: SCNVector3(flat.centre.x, flat.y, flat.centre.y), radius: flat.span / 2)
    }

    // MARK: Measuring

    private static func strip(_ needles: [String], from root: SCNNode) {
        var doomed: [SCNNode] = []
        root.enumerateHierarchy { n, _ in
            let name = (n.name ?? "").lowercased()
            if needles.contains(where: { name.contains($0) }) { doomed.append(n) }
        }
        for n in doomed { n.removeFromParentNode() }
    }

    /// Every vertex in `root`, in `root`'s own space. The bounding box alone cannot
    /// locate the platform surface — the box's floor is the underside of the slab,
    /// and gear standing there sinks into the wood.
    private static func worldVertices(of root: SCNNode) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        func walk(_ n: SCNNode, _ m: simd_float4x4) {
            let w = m * simd_float4x4(n.transform)
            if let g = n.geometry {
                for src in g.sources(for: .vertex) where src.componentsPerVector >= 3 {
                    src.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                        for i in 0..<src.vectorCount {
                            let b = i * src.dataStride + src.dataOffset
                            guard b + 12 <= raw.count else { continue }
                            let p = w * SIMD4<Float>(raw.loadUnaligned(fromByteOffset: b,     as: Float.self),
                                                     raw.loadUnaligned(fromByteOffset: b + 4, as: Float.self),
                                                     raw.loadUnaligned(fromByteOffset: b + 8, as: Float.self),
                                                     1)
                            out.append(SIMD3(p.x, p.y, p.z))
                        }
                    }
                }
            }
            for c in n.childNodes { walk(c, w) }
        }
        walk(root, matrix_identity_float4x4)
        return out
    }

    /// The vertices a node actually DRAWS, in `root`'s own space.
    ///
    /// Not the same as every vertex in its sources. Props cut out of the stage keep
    /// the deck's vertex source untouched and carry only their own indices (see
    /// `reshape`), so a prop's SOURCE still describes the whole stage — measure that
    /// and you measure the stage, which is how the stool's "seat" first came back
    /// four times too wide.
    private static func usedVertices(of root: SCNNode) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        func walk(_ n: SCNNode, _ m: simd_float4x4) {
            let w = m * simd_float4x4(n.transform)
            if let g = n.geometry, let src = g.sources(for: .vertex).first, src.componentsPerVector >= 3 {
                var used = Set<UInt32>()
                for e in g.elements where e.primitiveType == .triangles {
                    let width = e.bytesPerIndex
                    guard width == 2 || width == 4 else { continue }
                    e.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                        for i in 0..<(e.primitiveCount * 3) {
                            used.insert(width == 2
                                ? UInt32(raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                                : raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                        }
                    }
                }
                src.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    for i in used where Int(i) < src.vectorCount {
                        let b = Int(i) * src.dataStride + src.dataOffset
                        guard b + 12 <= raw.count else { continue }
                        let p = w * SIMD4<Float>(raw.loadUnaligned(fromByteOffset: b,     as: Float.self),
                                                 raw.loadUnaligned(fromByteOffset: b + 4, as: Float.self),
                                                 raw.loadUnaligned(fromByteOffset: b + 8, as: Float.self),
                                                 1)
                        out.append(SIMD3(p.x, p.y, p.z))
                    }
                }
            }
            for c in n.childNodes { walk(c, w) }
        }
        walk(root, matrix_identity_float4x4)
        return out
    }

    private static func extent(_ v: [SIMD3<Float>], _ axis: KeyPath<SIMD3<Float>, Float>) -> Float {
        guard let lo = v.map({ $0[keyPath: axis] }).min(),
              let hi = v.map({ $0[keyPath: axis] }).max() else { return 0 }
        return hi - lo
    }

    private static func midpoint(_ v: [SIMD3<Float>], _ axis: KeyPath<SIMD3<Float>, Float>) -> Float {
        guard let lo = v.map({ $0[keyPath: axis] }).min(),
              let hi = v.map({ $0[keyPath: axis] }).max() else { return 0 }
        return (lo + hi) / 2
    }

    /// The height gear stands on — the boards, found as the widest flat surface in
    /// the lower half of the model.
    ///
    /// Deliberately NOT the densest band, which is what this used to do. That rule
    /// assumed a raised deck on open ground and went looking for the highest bin
    /// still carrying vertices; on this asset it lands on the clutter around the
    /// boards at ≈10.6 instead of the boards at ≈2.58, and since the stage is then
    /// dropped by that much, EVERY piece of gear floats a fifth of a unit above the
    /// floor. Small on the amp, obvious on the pedalboard, and the reason the rig
    /// read as pasted onto the stage rather than standing on it.
    ///
    /// A floor is the one thing in a room that is both flat and WIDE, so measure
    /// exactly that. Props are flat too, but none of them are 4.5 m across.
    private static func floorSurfaceY(_ v: [SIMD3<Float>]) -> Float {
        let ys = v.map(\.y)
        guard let lo = ys.min(), let hi = ys.max(), hi > lo else { return ys.min() ?? 0 }
        // Only the lower half is a candidate — a ceiling is flat and wide as well.
        return widestFlatSurface(in: v, below: lo + (hi - lo) * 0.5)?.y ?? lo
    }

    /// The widest horizontal plane in `v`: its height, footprint and centre.
    ///
    /// Used for the two "what does a thing rest on?" questions the stage has to
    /// answer — where the boards are under the whole model, and where the stool's
    /// seat is within the stool. Same shape of question, same rule.
    ///
    /// `v` must be in a space where +y is up. That is not a formality: the .usdz is
    /// authored Z-up under a parent that rotates it upright, so asked in the mesh's
    /// own space this finds the stool's silhouette rather than any surface of it.
    ///
    /// Ties break UPWARD — of the surfaces within `tolerance` of the widest, the
    /// HIGHEST wins — because the thing you rest something on is the top face, and a
    /// slab's two faces are the same width. How loose that tolerance should be
    /// depends on what the runner-up is, so each caller sets it:
    ///
    /// * The boards use 0.8. The only real competitor is the underside of the same
    ///   surface, so anything much narrower is a prop and must not win.
    /// * The stool's seat uses 0.5, because a stool's legs SPLAY: their footprint at
    ///   the feet (0.80) out-spans the seat itself (0.63), and at 0.8 the seat misses
    ///   the cut and the "seat" comes back as a rung a fifth of the way up. What sits
    ///   above a seat is a cup, so a loose threshold costs nothing here.
    private static func widestFlatSurface(in v: [SIMD3<Float>],
                                          below limit: Float = .greatestFiniteMagnitude,
                                          tolerance: Float = 0.8)
        -> (y: Float, span: Float, centre: SIMD2<Float>)? {
        let ys = v.map(\.y)
        guard let lo = ys.min(), let hi = ys.max(), hi > lo else { return nil }

        // One pass: bucket by height, accumulating each bucket's x/z footprint.
        //
        // 1000 buckets — about 0.18 model units here — sits in the gap between the two
        // ways this goes wrong. Too coarse and a bucket spans more than one surface, so
        // the mean height below is dragged off the real plane: at 200 the boards came
        // back as 2.96 instead of 2.576, floating every piece of gear again, which is
        // the exact bug this method exists to fix. Too fine and mesh rounding splits
        // one surface across neighbouring bins. The thinnest thing that must stay
        // resolved is the stool's seat slab, ~2.5 model units thick, so this leaves an
        // order of magnitude of headroom on the side that matters.
        let quantum = max((hi - lo) / 1000, .ulpOfOne)
        struct Footprint {
            var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
            var sumY: Float = 0
            var count = 0
        }
        var buckets: [Int: Footprint] = [:]
        for p in v where p.y < limit {
            let bin = Int((p.y - lo) / quantum)
            var f = buckets[bin, default: Footprint()]
            f.lo = simd_min(f.lo, SIMD2(p.x, p.z))
            f.hi = simd_max(f.hi, SIMD2(p.x, p.z))
            f.sumY += p.y
            f.count += 1
            buckets[bin] = f
        }
        // A surface, not an edge: a handful of collinear vertices can span the room.
        let spans = buckets.filter { $0.value.count >= 8 }
                           .mapValues { min($0.hi.x - $0.lo.x, $0.hi.y - $0.lo.y) }
        guard let widest = spans.values.max(), widest > 0 else { return nil }
        guard let bin = spans.filter({ $0.value >= widest * tolerance }).keys.max() else { return nil }

        // The bucket's MEAN height, not the bucket's centre: gear stands on the
        // surface, and a coarse bucket would otherwise sink it by up to half a bin.
        let f = buckets[bin]!
        return (f.sumY / Float(f.count), spans[bin]!, (f.lo + f.hi) / 2)
    }

    // MARK: Prop surgery

    /// Applies `props` to the stage mesh, returning the node made for each prop that
    /// survived. Removals return nothing; they simply stop being drawn.
    ///
    /// Same trick as `crop`: the vertex sources are shared untouched between the deck
    /// and every prop cut out of it, and only the INDEX buffers are rebuilt. So a prop
    /// becoming its own node costs a draw call and a few hundred indices, not a copy
    /// of the mesh — and because the prop's vertices stay in the mesh's coordinates,
    /// its node can be given a transform without re-baking a single position.
    ///
    /// Selection is by CONNECTED COMPONENT, all-or-nothing: a component joins a prop
    /// only when every one of its vertices is inside the cylinder. Classifying loose
    /// triangles instead — which this did at first — cuts objects in half. Removing
    /// the drink can took 78 triangles of the floor cable with it, because the cable
    /// happened to pass through the can's cylinder, and the cable was left with a bite
    /// out of it. Whole components also make the floor safe for free: it is one piece
    /// 318 units across, so it cannot fit inside any cylinder small enough to name a
    /// prop.
    private static func reshape(_ root: SCNNode,
                                discCentre: SIMD2<Float>,
                                floorY: Float,
                                scale: Float) -> [String: SCNNode] {
        guard !props.isEmpty else { return [:] }
        var made: [String: SCNNode] = [:]

        // Prop limits are authored in diorama units above the floor; the mesh is in
        // model units. Convert once, here, so the entries stay readable.
        let ceilings = props.map { floorY + $0.maxHeightAboveFloor / scale }

        // Collected first: the loop below adds sibling nodes, and mutating the
        // hierarchy inside `enumerateHierarchy` is asking for trouble.
        var meshes: [SCNNode] = []
        root.enumerateHierarchy { n, _ in if n.geometry != nil { meshes.append(n) } }

        for node in meshes {
            guard let geometry = node.geometry,
                  let vertexSource = geometry.sources(for: .vertex).first,
                  vertexSource.componentsPerVector >= 3,
                  let element = geometry.elements.first,
                  element.primitiveType == .triangles,
                  let parent = node.parent else { continue }

            // Two transforms, because the prop nodes are siblings of this mesh: one
            // to read vertices in `root`'s space (where `props` is measured), and the
            // parent's alone to express a root-space scale in the siblings' space.
            var parentToRoot = matrix_identity_float4x4
            var walker = node.parent
            while let p = walker, p !== root.parent {
                parentToRoot = simd_float4x4(p.transform) * parentToRoot
                walker = p.parent
            }
            let toRoot = parentToRoot * simd_float4x4(node.transform)

            var position = [SIMD3<Float>](repeating: .zero, count: vertexSource.vectorCount)
            vertexSource.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for i in 0..<vertexSource.vectorCount {
                    let b = i * vertexSource.dataStride + vertexSource.dataOffset
                    guard b + 12 <= raw.count else { continue }
                    let p = toRoot * SIMD4<Float>(raw.loadUnaligned(fromByteOffset: b,     as: Float.self),
                                                  raw.loadUnaligned(fromByteOffset: b + 4, as: Float.self),
                                                  raw.loadUnaligned(fromByteOffset: b + 8, as: Float.self),
                                                  1)
                    position[i] = SIMD3(p.x, p.y, p.z)
                }
            }

            let width = element.bytesPerIndex
            guard width == 2 || width == 4 else { continue }
            var indices = [UInt32]()
            indices.reserveCapacity(element.primitiveCount * 3)
            element.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for i in 0..<(element.primitiveCount * 3) {
                    indices.append(width == 2
                        ? UInt32(raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                        : raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                }
            }

            // Connected components. Vertices are welded by rounded position first,
            // because an exported mesh splits them at every UV and normal seam — a
            // stool leg is one solid in the file and a dozen islands by raw index.
            var welded = [SIMD3<Int32>: Int32](minimumCapacity: position.count)
            var representative = [Int32](repeating: 0, count: position.count)
            for i in 0..<position.count {
                let key = SIMD3<Int32>(Int32((position[i].x * 100).rounded()),
                                       Int32((position[i].y * 100).rounded()),
                                       Int32((position[i].z * 100).rounded()))
                if let first = welded[key] { representative[i] = first }
                else { welded[key] = Int32(i); representative[i] = Int32(i) }
            }
            var parentOf = Array(0..<position.count)
            func find(_ a: Int) -> Int {
                var a = a
                while parentOf[a] != a { parentOf[a] = parentOf[parentOf[a]]; a = parentOf[a] }
                return a
            }
            func union(_ a: Int, _ b: Int) {
                let x = find(a), y = find(b)
                if x != y { parentOf[x] = y }
            }
            for t in 0..<element.primitiveCount {
                let a = Int(representative[Int(indices[t * 3])])
                let b = Int(representative[Int(indices[t * 3 + 1])])
                let c = Int(representative[Int(indices[t * 3 + 2])])
                union(a, b)
                union(b, c)
            }
            var components: [Int: [UInt32]] = [:]
            for t in 0..<element.primitiveCount {
                let key = find(Int(representative[Int(indices[t * 3])]))
                components[key, default: []].append(contentsOf: indices[(t * 3)..<(t * 3 + 3)])
            }

            var deck: [UInt32] = []
            var taken = [[UInt32]](repeating: [], count: props.count)
            for (_, triangles) in components {
                let vertices = Set(triangles)
                let owner = props.indices.first { i in
                    vertices.allSatisfy {
                        let p = position[Int($0)]
                        return simd_distance(SIMD2(p.x, p.z), discCentre + props[i].centre) <= props[i].radius
                            && p.y <= ceilings[i]
                    }
                }
                if let owner { taken[owner].append(contentsOf: triangles) }
                else { deck.append(contentsOf: triangles) }
            }
            guard deck.count < element.primitiveCount * 3 else { continue }   // nothing here

            func rebuilt(_ indices: [UInt32]) -> SCNGeometry {
                let e = SCNGeometryElement(data: Data(bytes: indices, count: indices.count * 4),
                                           primitiveType: .triangles,
                                           primitiveCount: indices.count / 3,
                                           bytesPerIndex: 4)
                let g = SCNGeometry(sources: geometry.sources, elements: [e])
                g.materials = geometry.materials
                g.name = geometry.name
                return g
            }
            node.geometry = deck.isEmpty ? nil : rebuilt(deck)

            for (i, prop) in props.enumerated() where !taken[i].isEmpty {
                guard case .resize(let factor) = prop.action else { continue }

                // Scale about the prop's footprint centre at floor level, expressed
                // in root space and then pushed back into the siblings' space.
                let pivot = SIMD3<Float>(discCentre.x + prop.centre.x, floorY, discCentre.y + prop.centre.y)
                var about = matrix_identity_float4x4
                about.columns.0.x = factor
                about.columns.1.y = factor
                about.columns.2.z = factor
                about.columns.3 = SIMD4(pivot * (1 - factor), 1)

                let holder = SCNNode()
                holder.name = "stageProp_\(prop.name)"
                holder.geometry = rebuilt(taken[i])
                holder.simdTransform = simd_inverse(parentToRoot) * about * toRoot
                parent.addChildNode(holder)
                made[prop.name] = holder
            }
        }
        return made
    }

    // MARK: Cropping

    /// Drops every triangle sitting above `limit` (in `root`'s space).
    ///
    /// The stage is a SINGLE mesh with one element and one material — the props are
    /// not separate nodes, so there is nothing to `removeFromParentNode`. Rebuilding
    /// the INDEX buffer without those triangles is the cheap way in: the vertex
    /// sources are reused untouched (a few orphaned vertices cost some bytes and no
    /// draw time), and unlike a fragment-discard shader this removes the work
    /// permanently rather than paying for it every frame.
    private static func crop(_ root: SCNNode, above limit: Float) {
        root.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry,
                  let vertexSource = geometry.sources(for: .vertex).first,
                  vertexSource.componentsPerVector >= 3,
                  let element = geometry.elements.first,
                  element.primitiveType == .triangles else { return }

            // Vertex positions in root space — the limit is measured there.
            var toRoot = simd_float4x4(node.transform)
            var walker = node.parent
            while let p = walker, p !== root.parent {
                toRoot = simd_float4x4(p.transform) * toRoot
                walker = p.parent
            }
            var ys = [Float](repeating: 0, count: vertexSource.vectorCount)
            vertexSource.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for i in 0..<vertexSource.vectorCount {
                    let b = i * vertexSource.dataStride + vertexSource.dataOffset
                    guard b + 12 <= raw.count else { continue }
                    let p = toRoot * SIMD4<Float>(raw.loadUnaligned(fromByteOffset: b,     as: Float.self),
                                                  raw.loadUnaligned(fromByteOffset: b + 4, as: Float.self),
                                                  raw.loadUnaligned(fromByteOffset: b + 8, as: Float.self),
                                                  1)
                    ys[i] = p.y
                }
            }

            // Keep a triangle when any corner is at or below the limit, so the cut
            // straddles the boundary instead of leaving a gap at it.
            let width = element.bytesPerIndex
            guard width == 2 || width == 4 else { return }
            var kept: [UInt32] = []
            kept.reserveCapacity(element.primitiveCount * 3)
            element.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                func index(_ i: Int) -> UInt32 {
                    width == 2 ? UInt32(raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                               : raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                }
                for t in 0..<element.primitiveCount {
                    let a = index(t * 3), b = index(t * 3 + 1), c = index(t * 3 + 2)
                    let corners = [a, b, c].map { Int($0) }
                    guard corners.allSatisfy({ $0 < ys.count }) else { continue }
                    if corners.contains(where: { ys[$0] <= limit }) { kept.append(contentsOf: [a, b, c]) }
                }
            }
            guard kept.count < element.primitiveCount * 3, !kept.isEmpty else { return }

            let trimmed = SCNGeometryElement(data: Data(bytes: kept, count: kept.count * 4),
                                             primitiveType: .triangles,
                                             primitiveCount: kept.count / 3,
                                             bytesPerIndex: 4)
            let rebuilt = SCNGeometry(sources: geometry.sources, elements: [trimmed])
            rebuilt.materials = geometry.materials
            rebuilt.name = geometry.name
            node.geometry = rebuilt
        }
    }
}
