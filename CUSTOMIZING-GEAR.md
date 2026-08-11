# Customizing gear — icons & 3D models

Every gear piece resolves its **icon** and its **3D model** from a file by the *same
name convention*. Drop a file in, it wins; drop nothing, the app draws its built-in
procedural art. No code, no manifest, no in-app UI — resolution happens by name at
render time, so already-saved rigs keep working.

## Repo layout

```
StreetRig/
  GearModels/                    ← 3D models: drop <slug>.usdz here
    README.md
  Assets.xcassets/
    GearIcons/                   ← 2D icons: drop <slug>.imageset here
      tube-screamer.imageset/    ← shipped example
  Views/
    GearModelLoader.swift        ← resolves the .usdz
    GearIconLoader.swift         ← resolves the icon image
  Models/                        ← Swift DATA models (Gear.swift, RigStore.swift) — NOT assets
CUSTOMIZING-GEAR.md              ← this guide
```

Two seams, one rule:

| What | Drop the file into | Resolver |
|------|--------------------|----------|
| **2D icon** | `StreetRig/Assets.xcassets/GearIcons/<slug>.imageset/` | [`GearIconLoader`](StreetRig/Views/GearIconLoader.swift) |
| **3D model** | `StreetRig/GearModels/<slug>.usdz` | [`GearModelLoader`](StreetRig/Views/GearModelLoader.swift) |

## The slug rule

`lowercase`, replace every run of non-`[a-z0-9]` with a single `-`, trim `-`.

`"Tube Screamer"` → `tube-screamer` · `"Boss TU-3"` → `boss-tu-3` · `"Marshall 1960A 4x12"` → `marshall-1960a-4x12`

## Fallback chain (first hit wins)

- **Icon:** `<slug>` → `category-<category>` (e.g. `category-overdrive`) → procedural art.
- **Model:** `GearItem.modelName` → `<slug>.usdz` → `category-<category>.usdz` → procedural.

## Every default component

| Component | Category | Icon (in `GearIcons/`) | Model (in `GearModels/`) |
|-----------|----------|------------------------|--------------------------|
| Les Paul Standard | guitar | `les-paul-standard.imageset` | `les-paul-standard.usdz` |
| **Guitar stand** | — (fixed) | *(drawn on the guitar)* | `guitar-stand.usdz` |
| Marshall JCM800 (amp **+ cab**) | amp | `marshall-jcm800.imageset` | `marshall-jcm800.usdz` |
| Marshall 1960A 4x12 | cabinet | `marshall-1960a-4x12.imageset` | *(part of the amp model)* |
| Fender Deluxe | comboAmp | `fender-deluxe.imageset` | `fender-deluxe.usdz` |
| Boss TU-3 | tuner | `boss-tu-3.imageset` | `boss-tu-3.usdz` |
| Cry Baby | wah | `cry-baby.imageset` | `cry-baby.usdz` |
| Dyna Comp | compressor | `dyna-comp.imageset` | `dyna-comp.usdz` |
| Tube Screamer | overdrive | `tube-screamer.imageset` ✅ | `tube-screamer.usdz` |
| Big Muff | overdrive | `big-muff.imageset` | `big-muff.usdz` |
| CE-2 Chorus | modulation | `ce-2-chorus.imageset` | `ce-2-chorus.usdz` |
| Phase 90 | modulation | `phase-90.imageset` | `phase-90.usdz` |
| Carbon Copy | delay | `carbon-copy.imageset` | `carbon-copy.usdz` |
| Boss RV-6 | reverb | `boss-rv-6.imageset` | `boss-rv-6.usdz` |
| Ditto Looper | looper | `ditto-looper.imageset` | `ditto-looper.usdz` |

> The **amp head + 4×12 cabinet are one model** (`<amp-slug>.usdz`) — the cabinet rides
> with the amp. The **stand is its own file** (`guitar-stand.usdz`), separate from the guitar.

## Getting an editable starting point (3D)

The procedural models bake to real files you can open in Blender:

1. In the Xcode scheme, set env var **`STREETRIG_EXPORT=1`** and run once (Debug).
2. Baselines write to the app's **Documents** folder (the path is printed to the console):
   `StreetRig_Amp`, `StreetRig_Pedal`, `StreetRig_Guitar`, `StreetRig_Stand` — each as
   `.usdz` (keeps PBR materials) **and** `.obj` (opens straight in Blender).
3. Refine in Blender → export a clean `.usdz` → rename it to the target slug
   (e.g. `marshall-jcm800.usdz`, or `guitar-stand.usdz`) → drop it in **`StreetRig/GearModels/`**.
   It loads automatically.

## Status

- **Icons** — live for every piece, everywhere it renders (rail, library, cards, stage, detail).
  Grouped under `Assets.xcassets/GearIcons/` (see also the deep-dive in
  [`StreetRig/GearIcons-README.md`](StreetRig/GearIcons-README.md)).
- **3D models** — the file seam is wired for the **amp + cab, guitar, stand, and every pedal**
  in the rig diorama, plus the amp's zoom-detail view. Author a custom `.usdz` at the baseline's
  scale/origin so it seats into the diorama layout cleanly (the export gives you that for free).
