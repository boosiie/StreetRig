# GearModels — custom 3D models (`.usdz`)

Dedicated drop-point for designer-supplied 3D models. Drop a `<slug>.usdz` here to
override a gear piece's procedural model — it loads automatically, no code change.

- `"Marswell JCM800 2203"` → `marswell-jcm800-2203.usdz` (the amp head **and** its cab are one model)
- The guitar stand is its own file: `guitar-stand.usdz`
- Shared look for a whole category: `category-<category>.usdz` (e.g. `category-overdrive.usdz`)

Resolution order: `GearItem.modelName` → `<slug>.usdz` → `category-<category>.usdz` →
procedural textured with the piece's `<slug>.imageset` → plain procedural.

Bake editable baselines by running the app with the `STREETRIG_EXPORT=1` env var — it writes
`.usdz` + `.obj` for the amp, a pedal, the guitar, and the stand into the app's Documents
folder. Refine in Blender, export a clean `.usdz`, rename to the slug, drop it here.

Full guide: [`../../CUSTOMIZING-GEAR.md`](../../CUSTOMIZING-GEAR.md).
(This folder is separate from `StreetRig/Models/`, which holds Swift **data** models.)
