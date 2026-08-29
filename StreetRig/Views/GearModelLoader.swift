//
//  GearModelLoader.swift
//  StreetRig
//
//  The custom-3D-model seam — the .usdz sibling of GearIconLoader. Lets any gear
//  piece load a designer-supplied `.usdz` in place of the app's procedural model,
//  everywhere the piece is rendered (the rig diorama and the zoom detail view).
//
//  HOW IT WORKS — the SAME name convention as the icons (see GearIconLoader).
//  Resolution order for a piece, first hit wins:
//    1. GearItem.modelName        — an explicit stored override (the original amp seam).
//    2. <slug(item.name)>.usdz    — the bespoke per-piece model  ("ValveShrieker" → tube-shrieker.usdz).
//    3. category-<raw>.usdz       — an optional shared per-category model (e.g. category-overdrive.usdz).
//    4. nil                       — the caller builds the procedural stand-in, exactly as before.
//
//  Files are plain bundled resources dropped into the app target; Xcode-16
//  synchronized file groups pick them up with no project.pbxproj edit. See
//  CUSTOMIZING-GEAR.md for the full round-trip (bake → edit in Blender → drop in).
//

import SceneKit
import simd
import StreetRigEngine

enum GearModelLoader {

    /// The custom model node for a piece, or `nil` to use the procedural stand-in.
    /// Mirrors `GearIconLoader.image(for:)` so icons and models resolve by one rule.
    static func modelNode(for item: GearItem?) -> SCNNode? {
        guard let item else { return nil }

        // 1. Explicit stored override.
        if let explicit = item.modelName, let node = AmpScene.load(usdzNamed: explicit) {
            return node
        }
        // 2. Bespoke, per-piece model, under the same key the icon and the panel
        //    plate use — the frozen `catalogID`, or a slugged name for gear with
        //    no catalog entry.
        let slug = GearCatalog.id(for: item) ?? GearIconLoader.slug(item.name)
        if !slug.isEmpty, let node = AmpScene.load(usdzNamed: slug) {
            return node
        }
        // 3. Optional shared per-category model.
        return AmpScene.load(usdzNamed: "category-\(item.category.rawValue)")
    }

    /// A fixed-name auxiliary model that isn't a `GearItem` — e.g. the guitar
    /// stand (`guitar-stand.usdz`). `nil` falls back to the procedural build.
    static func namedModel(_ name: String) -> SCNNode? {
        AmpScene.load(usdzNamed: name)
    }
}

// MARK: - Fitting a real .usdz into the diorama's unit space

//  A downloaded/authored model does NOT arrive in the app's coordinate system.
//  It is modelled at real-world scale in whatever unit the DCC tool used (the
//  Apple Stratocaster is authored in centimetres, ~97 cm tall), with whatever
//  pivot and facing the artist left on it. The procedural stand-ins, by
//  contrast, were modelled directly in stage units, and the diorama's layout,
//  camera framing and contact shadows are all tuned against THOSE envelopes —
//  see the `gScale`/`minCameraDistance` notes in RigStage3DView.
//
//  So every real model is re-posed on load to occupy exactly the box the
//  procedural piece occupied. One helper, used by every guitar render site,
//  so the stage and the detail view can never disagree about how big a guitar is.

extension GearModelLoader {

    /// An axis-aligned box in a node's own coordinate space.
    struct Bounds {
        var min: SCNVector3
        var max: SCNVector3

        var size: SCNVector3 { SCNVector3(max.x - min.x, max.y - min.y, max.z - min.z) }
        var centerX: Float { (min.x + max.x) / 2 }
        var centerZ: Float { (min.z + max.z) / 2 }
    }

    /// Union of a node's own geometry bounds and every descendant's, expressed in
    /// `node`'s coordinate space (each child's box is pushed through its own
    /// transform on the way up).
    ///
    /// Written out rather than leaning on `SCNNode.boundingBox`, which is
    /// documented as the bounds of the node's OWN geometry — and a freshly loaded
    /// `.usdz` holder has no geometry of its own at all, only children.
    static func recursiveBounds(of node: SCNNode) -> Bounds? {
        var lo = SIMD3<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        var found = false

        func absorb(_ n: SCNNode, _ transform: simd_float4x4) {
            if n.geometry != nil {
                let (bMin, bMax) = n.boundingBox
                // All 8 corners — a rotated child's box is not axis-aligned in our space.
                for xi in [bMin.x, bMax.x] {
                    for yi in [bMin.y, bMax.y] {
                        for zi in [bMin.z, bMax.z] {
                            let p = transform * SIMD4<Float>(Float(xi), Float(yi), Float(zi), 1)
                            let v = SIMD3<Float>(p.x, p.y, p.z)
                            lo = simd_min(lo, v)
                            hi = simd_max(hi, v)
                            found = true
                        }
                    }
                }
            }
            for child in n.childNodes { absorb(child, transform * child.simdTransform) }
        }

        // The root's own transform is deliberately excluded: the result is in
        // `node`'s space, which is what the caller then scales and translates.
        absorb(node, matrix_identity_float4x4)
        guard found else { return nil }
        return Bounds(min: SCNVector3(lo.x, lo.y, lo.z), max: SCNVector3(hi.x, hi.y, hi.z))
    }

    /// Re-poses `node` so it fills the same envelope the procedural stand-in did:
    /// uniformly scaled to `target`'s HEIGHT, centred on `target` in x/z, and
    /// sitting with its base on `target`'s floor.
    ///
    /// Uniform (not per-axis) scaling on purpose — matching all three extents would
    /// stretch the model to the procedural silhouette's proportions, and a Strat is
    /// not a Les Paul. Height is the axis that matters: it is what the eye compares
    /// against the amp, and the guitar is the tallest thing on the stage.
    ///
    /// `yaw` is applied BEFORE measuring, so the fit accounts for the turned
    /// footprint rather than boxing the model at its authored facing.
    ///
    /// - Returns: the scale factor applied, for logging.
    @discardableResult
    static func fit(_ node: SCNNode, into target: Bounds, yaw: Float = 0) -> Float {
        node.position = SCNVector3Zero
        node.scale = SCNVector3(1, 1, 1)
        node.eulerAngles = SCNVector3(0, yaw, 0)

        guard let local = recursiveBounds(of: node), local.size.y > 1e-6 else { return 1 }

        // Push the local box through the node's own (rotation-only) transform so
        // the measurement is in the parent's space — the space `target` is in.
        let rotated = transformed(local, by: node.simdTransform)
        let s = target.size.y / rotated.size.y
        node.scale = SCNVector3(s, s, s)

        // Uniform scale commutes with rotation, so the posed box is just `rotated * s`.
        node.position = SCNVector3(target.centerX - rotated.centerX * s,
                                   target.min.y   - rotated.min.y   * s,
                                   target.centerZ - rotated.centerZ * s)
        return s
    }

    private static func transformed(_ b: Bounds, by m: simd_float4x4) -> Bounds {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for xi in [b.min.x, b.max.x] {
            for yi in [b.min.y, b.max.y] {
                for zi in [b.min.z, b.max.z] {
                    let p = m * SIMD4<Float>(xi, yi, zi, 1)
                    lo = simd_min(lo, SIMD3(p.x, p.y, p.z))
                    hi = simd_max(hi, SIMD3(p.x, p.y, p.z))
                }
            }
        }
        return Bounds(min: SCNVector3(lo.x, lo.y, lo.z), max: SCNVector3(hi.x, hi.y, hi.z))
    }

    /// Recursively drops descendants whose name contains any of `needles`
    /// (case-insensitive).
    ///
    /// Needed because a downloaded model may bundle an accessory the app already
    /// supplies through its own seam: Apple's Stratocaster ships the guitar AND a
    /// floor stand as two meshes in one file, while StreetRig draws the stand
    /// separately in the detail view (`guitar-stand.usdz` →
    /// `ProceduralGuitar.buildStand`). Loading the file whole would put a guitar in
    /// two stands at once — and on the stage, where the guitar leans on the stool
    /// with no stand at all, it would put it back in one.
    static func removeNodes(in root: SCNNode, whereNameContains needles: [String]) {
        for child in root.childNodes {
            let name = child.name?.lowercased() ?? ""
            if needles.contains(where: { name.contains($0.lowercased()) }) {
                child.removeFromParentNode()
            } else {
                removeNodes(in: child, whereNameContains: needles)
            }
        }
    }
}

// MARK: - The guitar: one load path for every 3D render site

extension GearModelLoader {

    /// Sub-node names dropped from a loaded guitar model — the app owns the stand.
    private static let guitarAccessoryNames = ["stand"]

    /// The envelope the procedural guitar occupied, measured from the procedural
    /// builder itself rather than transcribed, so the two can never drift apart.
    ///
    /// This is load-bearing well beyond looks: `RigStage3DView`'s `gScale = 0.42`,
    /// its contact-shadow size and `RigDiorama.minCameraDistance` are all tuned
    /// against this box. A guitar that resolves at a different size doesn't just
    /// read wrong, it breaks the stage's framing.
    ///
    /// Measured value at time of writing: 1.840 × 4.402 × 0.633, base at y = −1.281.
    /// The literal below is only a belt-and-braces fallback for a probe that somehow
    /// builds no geometry; the live path is the measurement.
    static let proceduralGuitarBounds: Bounds = {
        let probe = SCNNode()
        ProceduralGuitar.buildGuitar(into: probe)
        return recursiveBounds(of: probe)
            ?? Bounds(min: SCNVector3(-0.92, -1.2807813, -0.36),
                      max: SCNVector3(0.92, 3.1215446, 0.27322766))
    }()

    /// THE guitar node — the single path every 3D guitar render site goes through.
    ///
    /// Resolves through the normal `.usdz` seam (`modelName` → `<slug>.usdz` →
    /// `category-guitar.usdz`), strips any stand the file bundles, and fits the
    /// result into the procedural guitar's envelope.
    ///
    /// Never returns an empty node. If nothing resolves it logs loudly, asserts,
    /// and falls back to the retired procedural body — because an invisible guitar
    /// reads as a layout bug and costs hours, while a guitar that is merely the
    /// OLD guitar plus a console line names its own cause immediately.
    ///
    /// > Note: if the bundled model is ever removed deliberately (e.g. the Apple
    /// > asset is dropped over licensing), delete the `assertionFailure` below —
    /// > it is here to catch an asset that went missing by accident, and it traps
    /// > debug builds. The procedural fallback keeps release builds drawing.
    static func guitarNode(for item: GearItem?) -> SCNNode {
        if let loaded = modelNode(for: item) ?? namedModel("category-\(GearCategory.guitar.rawValue)") {
            removeNodes(in: loaded, whereNameContains: guitarAccessoryNames)
            if recursiveBounds(of: loaded) != nil {
                fit(loaded, into: proceduralGuitarBounds)
                return loaded
            }
        }

        let message = """
            StreetRig: no guitar 3D model resolved. Expected \
            `category-\(GearCategory.guitar.rawValue).usdz` (or a per-piece <slug>.usdz) \
            in the app bundle — see CUSTOMIZING-GEAR.md. Drawing the retired \
            procedural body instead.
            """
        print("⚠️ \(message)")
        assertionFailure(message)

        let fallback = SCNNode()
        ProceduralGuitar.buildGuitar(into: fallback)
        return fallback
    }
}
