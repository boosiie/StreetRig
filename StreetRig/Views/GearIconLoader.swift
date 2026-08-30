//
//  GearIconLoader.swift
//  StreetRig
//
//  The custom-icon seam. Lets a designer give any single gear piece its own
//  bespoke picture — a PNG or vector PDF — that overrides the app's built-in
//  hand-drawn `GearArtView` vector art everywhere that piece is shown (the MY
//  GEAR rail, the GEAR LIBRARY tab, cards, the rig stage, and the zoom detail).
//
//  HOW IT WORKS — no manifest, no in-app UI:
//    A piece is matched to an asset by its CATALOG ID (`GearCatalog.id(for:)`) —
//    the permanent identifier written out beside each model in
//    `RigStore.allModels`. Look for an image of that name in `Assets.xcassets`;
//    if one exists it wins, and if not the caller falls back to the procedural
//    art.
//
//    It used to key off the DISPLAY NAME, slugged. That worked right up until a
//    model was renamed, at which point the picture silently stopped resolving —
//    no error, no log, just the grey procedural box where a drawing had been. It
//    happened twice, and both times the only cure was to throw the player's saved
//    rig away (`RigStore.catalogVersion`). An id cannot be renamed, so it cannot
//    do that; the display name is now ordinary text.
//
//    Gear with no catalog entry — anything hand-named — still resolves by
//    slugging its name, which is the only key it has.
//
//  ALSO THE 3D STAGE. The icon is no longer 2D-only: when no custom `.usdz`
//  exists, `ProceduralAmp` textures the amp head's and cabinet's front faces
//  with this same image (via `uiImage(for:)`) and takes the box proportions
//  from its pixel size — so one correctly-named PNG dresses the cards, the
//  library, the rail AND the diorama.
//
//  TO ADD A CUSTOM ICON (designer workflow — see GearIcons-README.md):
//    1. Take the piece's catalog ID from `RigStore.allModels` ("ProForge SHREW"
//       is filed under "proforge-shrew"). For a NEW model, mint one with
//       `slug(_:)` below, then never change it.
//    2. Create `StreetRig/Assets.xcassets/<slug>.imageset/` on disk, drop in a
//       PNG (or a preserve-vector PDF) and a `Contents.json`. Xcode-16
//       synchronized file groups pick it up automatically — no project.pbxproj
//       edit needed.
//    That's it: the icon now overrides that piece everywhere.
//

import SwiftUI
import StreetRigEngine
import UIKit

/// Resolves a gear piece to a designer-supplied icon, or `nil` when none exists
/// (in which case the caller renders the built-in procedural art). Kept as a
/// tiny, self-contained seam so the resolution strategy — currently the asset
/// catalog — could be swapped later without touching call sites.
enum GearIconLoader {

    /// Turn a name into a slug.
    ///
    /// This is how a catalog ID is MINTED (once, when a model is first added) and
    /// how gear with no catalog entry is resolved. It is NOT how a shipped model
    /// is looked up any more — see `uiImage(for:)`.
    ///
    /// Rule (this MUST stay in lock-step with GearIcons-README.md):
    ///   lowercase, replace every maximal run of characters NOT in `[a-z0-9]`
    ///   with a single "-", then trim leading/trailing "-".
    ///   Regex form: replace `[^a-z0-9]+` with `-`, then trim `-`.
    ///
    /// Examples:
    ///   "Iberon Valve Shrieker"         -> "iberon-valve-shrieker"
    ///   "electro-galvanic BIG MITT Ω" -> "electro-galvanic-big-mitt"
    ///   "Fullbrook Lucid'Vibe"          -> "fullbrook-lucid-vibe"
    ///   "Marswell MSW900 2140"         -> "marswell-msw900-2140"
    ///   "Fandor Bassdude '59"           -> "fandor-bassdude-59"
    static func slug(_ name: String) -> String {
        let dashed = name
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        return dashed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// The custom icon for a piece, or `nil` if it should use procedural art.
    ///
    /// Lookup / fallback chain (first hit wins):
    ///   1. Per-piece:  an asset named `slug(item.name)`        — the bespoke icon.
    ///   2. Category:   an asset named `category-<rawValue>`    — an optional
    ///      shared default for a whole category (e.g. `category-overdrive`).
    ///   3. `nil`       — caller renders today's procedural `GearArtView` art.
    ///
    /// `UIImage(named:)` returns `nil` cleanly when no such asset is compiled in,
    /// which is exactly the fallback signal we want. UIKit already caches the
    /// decoded image, so no custom cache is needed. Supports both PNG and vector
    /// PDF imagesets natively.
    static func image(for item: GearItem?) -> Image? {
        uiImage(for: item).map { Image(uiImage: $0) }
    }

    /// The same resolution, handed back as a `UIImage`.
    ///
    /// Exists because the 3D stage is a second renderer of the very same art:
    /// SceneKit needs a `UIImage` to texture a face, and needs its PIXEL SIZE to
    /// derive the box's proportions from the drawing (see `ProceduralAmp`). One
    /// name rule, two renderers — resolving it twice by two different rules is
    /// exactly the drift this seam exists to prevent.
    static func uiImage(for item: GearItem?) -> UIImage? {
        // Guard: no item, or an empty/blank name (e.g. LibraryView's category
        // header placeholders use `GearItem(name: "", ...)`) -> skip lookup and
        // let the procedural art render, exactly as today.
        guard let item else { return nil }
        // Identity, not the display name: a piece's art is filed under its frozen
        // `catalogID` (see GearCatalog), so re-titling a model no longer orphans
        // its picture. Gear with no catalog entry — anything hand-made — still
        // resolves by slugging its name, which is the only key it has.
        let key = GearCatalog.id(for: item) ?? slug(item.name)
        guard !key.isEmpty else { return nil }

        // 1. Bespoke, per-piece icon.
        if let ui = UIImage(named: key) { return ui }
        // 2. Optional shared per-category default.
        if let ui = UIImage(named: "category-\(item.category.rawValue)") { return ui }
        // 3. No custom asset — signal the caller to use procedural art.
        return nil
    }
}
