# Custom Gear Icons

Give any single gear piece its own bespoke picture — a **PNG** or a **vector PDF** —
that overrides StreetRig's built-in hand-drawn art **everywhere** that piece appears:
the **MY GEAR** rail, the **GEAR LIBRARY** tab, gear cards, the rig stage, and the
zoomed-in detail view.

No Swift, no manifest, no `project.pbxproj` edit, no data-model change. You just drop a
correctly-named image into the asset catalog. Pieces you don't customize keep the
existing procedural art, unchanged.

---

## How it works

Every gear icon in the app routes through one SwiftUI view, `GearArtView(item:)`. At
render time it asks `GearIconLoader` for a custom image. The loader turns the piece's
**display name** into an **asset name** (a "slug") and looks it up in
`StreetRig/Assets.xcassets`. If a matching image exists, it wins (fitted, never
stretched); if not, the built-in procedural art renders as the fallback.

Because the Xcode project uses **synchronized file groups**, any valid `.imageset` you
create on disk under `Assets.xcassets/` is compiled and bundled automatically — no need
to open Xcode or touch the project file.

---

## The slug rule

Code (`GearIconLoader.slug`) and this doc must agree exactly:

1. Lowercase the name.
2. Replace every maximal run of characters **not** in `[a-z0-9]` with a single `-`.
3. Trim any leading/trailing `-`.

Regex form: replace `[^a-z0-9]+` with `-`, then trim `-`.

| Display name        | Asset name (slug)   |
| ------------------- | ------------------- |
| `Tube Screamer`     | `tube-screamer`     |
| `Big Muff`          | `big-muff`          |
| `Boss TU-3`         | `boss-tu-3`         |
| `CE-2 Chorus`       | `ce-2-chorus`       |
| `Marshall JCM800`   | `marshall-jcm800`   |
| `1960A`             | `1960a`             |

---

## Add a custom icon (step by step)

1. **Slug the name.** e.g. `Big Muff` -> `big-muff`.
2. **Create the imageset folder** on disk:
   `StreetRig/Assets.xcassets/big-muff.imageset/`
3. **Add your image** into that folder — either a PNG or a vector PDF.
4. **Add `Contents.json`** next to it.

   Single universal **PNG**:
   ```json
   {
     "images" : [
       { "filename" : "big-muff.png", "idiom" : "universal" }
     ],
     "info" : { "author" : "xcode", "version" : 1 }
   }
   ```

   Single **vector PDF** (renders crisply at every size — recommended for line art):
   ```json
   {
     "images" : [
       { "filename" : "big-muff.pdf", "idiom" : "universal" }
     ],
     "info" : { "author" : "xcode", "version" : 1 },
     "properties" : { "preserves-vector-representation" : true }
   }
   ```

That's it. Rebuild and the icon overrides that piece everywhere.

> The shipped example is `tube-screamer.imageset` (a magenta "TS" tile) — proof the
> seam is wired end-to-end. Delete it and the Tube Screamer falls back to its green
> procedural art.

---

## Optional: a shared per-category default

If no per-piece asset is found, the loader next looks for
`category-<rawValue>.imageset` — a single image shared by every piece in that category.
Use the `GearCategory` raw value: `overdrive`, `delay`, `reverb`, `modulation`,
`compressor`, `tuner`, `eq`, `pitch`, `looper`, `volume`, `noiseGate`, `wah`, `amp`,
`cabinet`, `comboAmp`, `guitar`.

Example: `category-overdrive.imageset` would give every overdrive pedal that has no
bespoke icon of its own the same shared picture.

Lookup order (first hit wins):
1. `slug(name)` — the bespoke, per-piece icon.
2. `category-<rawValue>` — the optional shared default.
3. *(none)* — the built-in procedural art.

---

## Art guidelines

Icons are drawn with **aspect-fit** (never stretched), then centered in a per-category
frame. Author your art at the frame's proportions so it fills the space without empty
bars. Use a **transparent background** so the icon sits cleanly on the card.

| Category                         | Frame shape      | Recommended aspect (W:H) |
| -------------------------------- | ---------------- | ------------------------ |
| Pedals (overdrive, delay, …)     | tall & narrow    | ~0.7 : 1  (e.g. 240x336) |
| Wah                              | slightly wide    | ~1.3 : 1                 |
| Amp head                         | wide             | ~1.5 : 1                 |
| Cabinet                          | near square      | ~1.1 : 1                 |
| Combo amp                        | near square/wide | ~1.2 : 1                 |
| Guitar                           | tall             | ~0.8 : 1                 |

Render PNGs at ~3x the on-screen size (icons range from ~38x54 up to ~112x90 pt) so they
stay crisp on Retina displays — or use a vector PDF and forget about resolution entirely.

---

## Notes / guardrails

- **Data is untouched.** Matching is purely by name at render time; nothing is stored on
  the gear item and `rig_state.json` is unaffected. Saved rigs stay backward-compatible.
- **The 3D amp path is separate.** Custom 2D icons apply to `GearArtView` only. The
  feature-flagged 3D amp pipeline has its own asset seam (`GearItem.modelName` -> `.usdz`)
  and is not affected by these files.
- **Empty/blank names** (used internally for some category-header placeholders) never
  match an asset and always render procedural art.
