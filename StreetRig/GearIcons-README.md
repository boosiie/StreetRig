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

| Display name                    | Asset name (slug)              |
| ------------------------------- | ------------------------------ |
| `Ibonez Tube Screamer`          | `ibonez-tube-screamer`         |
| `electro-harmonium BIG MUFF π`  | `electro-harmonium-big-muff`   |
| `VOSS Chromatic Tuner`          | `voss-chromatic-tuner`         |
| `Fullstone Deja'Vibe`           | `fullstone-deja-vibe`          |
| `Marswell JCM800 2203`          | `marswell-jcm800-2203`         |
| `Marswell 1960A 4x12`           | `marswell-1960a-4x12`          |
| `Fandor Bassman '59`            | `fandor-bassman-59`            |

---

## Add a custom icon (step by step)

1. **Slug the name.** e.g. `ProCon RAT` -> `procon-rat`.
2. **Create the imageset folder** on disk:
   `StreetRig/Assets.xcassets/procon-rat.imageset/`
3. **Add your image** into that folder — either a PNG or a vector PDF.
4. **Add `Contents.json`** next to it.

   Single universal **PNG**:
   ```json
   {
     "images" : [
       { "filename" : "procon-rat.png", "idiom" : "universal" }
     ],
     "info" : { "author" : "xcode", "version" : 1 }
   }
   ```

   Single **vector PDF** (renders crisply at every size — recommended for line art):
   ```json
   {
     "images" : [
       { "filename" : "procon-rat.pdf", "idiom" : "universal" }
     ],
     "info" : { "author" : "xcode", "version" : 1 },
     "properties" : { "preserves-vector-representation" : true }
   }
   ```

That's it. Rebuild and the icon overrides that piece everywhere.

> **Everything the app ships has a bespoke icon**: all 47 pedals (228x330 PNG,
> transparent background) and all 14 amp heads, cabinets and combos. The
> procedural art is now purely the fallback for gear whose name has no matching
> asset. Delete a piece's `.imageset` and it falls straight back to that
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

| Category                         | Frame shape           | Recommended aspect (W:H)   |
| -------------------------------- | --------------------- | -------------------------- |
| Pedals (overdrive, delay, …)     | tall & narrow         | ~0.7 : 1  (e.g. 240x336)   |
| Wah / volume / Whammy (treadles) | near square           | ~0.95 : 1 (e.g. 270x295)   |
| Amp head                         | **wide, ~2:1**        | ~2.05 : 1 (e.g. 500x240)   |
| Cabinet                          | **taller than wide**  | ~0.87 : 1 (e.g. 512x590)   |
| Combo amp                        | near square           | ~1.13 : 1 (e.g. 460x405)   |
| Guitar                           | tall                  | ~0.8 : 1                   |

The amp/cabinet/combo numbers are **measured from the shipped art**, not guessed: the
five heads run 1.68–2.11, the three cabinets 0.80–0.94, and the six combos 1.05–1.21.
A cabinet is *taller than wide* — an earlier version of this table called it "near
square, 1.1:1", which is the wrong way round and sent art back letterboxed.

**The aspect column is now advice, not a constraint.** A bespoke icon takes its width
from its own pixels at render time (`GearArtFrame`), keeping the category's height as
the budget — so art that disagrees with the column is framed correctly anyway, and only
the procedural fallback drawings still depend on these numbers.

That seam exists because a category is not always one shape. `pitch` holds three compact
stompboxes at 0.69:1 *and* a Whammy treadle at 1.07:1; no single per-category frame is
right for both. Before this, the six treadle pedals — three wahs, two volumes and the
Whammy — were framed as tall 0.7:1 compacts and rendered 34–42pt tall where their
neighbours got 54pt.

The frames in code (`GearCategory.artSize`, `LibraryView`'s tile sizes and the rig
stage's) are set to these same proportions, so art authored at them fills the frame.
Drift far from the column and the icon aspect-fits inside the frame with empty bars —
it never stretches, it just gets smaller.

Render PNGs at ~3x the on-screen size (icons range from ~38x54 up to ~112x90 pt) so they
stay crisp on Retina displays — or use a vector PDF and forget about resolution entirely.

---

## Notes / guardrails

- **Data is untouched.** Matching is purely by name at render time; nothing is stored on
  the gear item and `rig_state.json` is unaffected. Saved rigs stay backward-compatible.
- **The 3D stage uses these icons too.** An amp head's and a cabinet's icon are mapped
  onto the front face of their box in the rig diorama, and the box's proportions are
  taken from the image's pixel size — so one PNG dresses the cards, the library, the
  rail *and* the 3D stage. A real `.usdz` still wins over both (see
  [`../CUSTOMIZING-GEAR.md`](../CUSTOMIZING-GEAR.md)); the icon is the middle rung of
  that chain, not a competitor to it.
- **A head's icon replaces its 3D knobs.** The drawn art already has that amp's knob
  row on it, and every model's row sits somewhere different, so the procedural knob
  nodes are dropped when art is applied rather than doubled up. The trade: those knobs
  no longer turn with the values while you look at the diorama. Tap the amp and the
  zoom overlay's knobs and sliders are still the live control surface.
- **Empty/blank names** (used internally for some category-header placeholders) never
  match an asset and always render procedural art.
