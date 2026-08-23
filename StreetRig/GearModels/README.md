# GearModels — custom 3D models (`.usdz`)

Dedicated drop-point for designer-supplied 3D models. Drop a `<slug>.usdz` here to
override a gear piece's procedural model — it loads automatically, no code change.

- `"Marswell JCM800 2203"` → `marswell-jcm800-2203.usdz` (the amp head **and** its cab are one model)
- The guitar stand is its own file: `guitar-stand.usdz` (guitar **detail view** only — the stage leans the guitar on its stool instead)
- Shared look for a whole category: `category-<category>.usdz` (e.g. `category-overdrive.usdz`)

Resolution order: `GearItem.modelName` → `<slug>.usdz` → `category-<category>.usdz` →
procedural textured with the piece's `<slug>.imageset` → plain procedural.

## The guitar is model-first

The guitar no longer has a procedural normal path. `GearModelLoader.guitarNode(for:)`
resolves a `.usdz` by the usual order and **`category-guitar.usdz` is expected to be
present**; the old Les Paul-ish body only draws as a loud last resort (console warning
+ `assertionFailure`) so a missing file can never leave an empty stage.

That file is **not committed** — see [`../../research/strat-model-evaluation.md`](../../research/strat-model-evaluation.md).
Without it a debug build will trap on the rig stage; drop the file in, or delete the
`assertionFailure` in `GearModelLoader.guitarNode`.

Two things happen to a guitar model that don't happen to the other pieces:

- **It's fitted, not trusted.** The loaded node is uniformly scaled so its *height*
  matches the retired procedural body, then centred in x/z and stood on that body's
  floor. So a model authored at real-world scale in metres or centimetres just works —
  but it also means you cannot change a guitar's on-stage size by rescaling the file.
  The envelope comes from `GearModelLoader.proceduralGuitarBounds`, and
  `RigStage3DView`'s `gScale`, its contact shadow and `RigDiorama.minCameraDistance`
  are all tuned against it.
- **A bundled stand is stripped.** Any sub-node whose name contains `stand` is removed
  on load, because StreetRig draws the stand itself through the separate
  `guitar-stand.usdz` seam. Name your guitar's meshes accordingly.

Bake editable baselines by running the app with the `STREETRIG_EXPORT=1` env var — it writes
`.usdz` + `.obj` for the amp, a pedal, the guitar, and the stand into the app's Documents
folder. Refine in Blender, export a clean `.usdz`, rename to the slug, drop it here.
The guitar baseline is now the **loaded, fitted model** at its exact in-app scale and
pivot — the box your replacement has to land in — not the retired procedural body.

Full guide: [`../../CUSTOMIZING-GEAR.md`](../../CUSTOMIZING-GEAR.md).
(This folder is separate from `StreetRig/Models/`, which holds Swift **data** models.)
