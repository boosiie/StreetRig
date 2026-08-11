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
//    2. <slug(item.name)>.usdz    — the bespoke per-piece model  ("Tube Screamer" → tube-screamer.usdz).
//    3. category-<raw>.usdz       — an optional shared per-category model (e.g. category-overdrive.usdz).
//    4. nil                       — the caller builds the procedural stand-in, exactly as before.
//
//  Files are plain bundled resources dropped into the app target; Xcode-16
//  synchronized file groups pick them up with no project.pbxproj edit. See
//  CUSTOMIZING-GEAR.md for the full round-trip (bake → edit in Blender → drop in).
//

import SceneKit

enum GearModelLoader {

    /// The custom model node for a piece, or `nil` to use the procedural stand-in.
    /// Mirrors `GearIconLoader.image(for:)` so icons and models resolve by one rule.
    static func modelNode(for item: GearItem?) -> SCNNode? {
        guard let item else { return nil }

        // 1. Explicit stored override.
        if let explicit = item.modelName, let node = AmpScene.load(usdzNamed: explicit) {
            return node
        }
        // 2. Bespoke, per-piece model by slugged name.
        let slug = GearIconLoader.slug(item.name)
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
