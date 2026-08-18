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
    <slug>.imageset/             ← 2D icons (flat); the 47 catalog pedals already ship theirs
  Views/
    GearModelLoader.swift        ← resolves the .usdz
    GearIconLoader.swift         ← resolves the icon image
  Models/                        ← Swift DATA models (Gear.swift, RigStore.swift) — NOT assets
  GearIcons-README.md            ← icon deep-dive (art sizes, category defaults)
CUSTOMIZING-GEAR.md              ← this guide
```

Two seams, one rule:

| What | Drop the file into | Resolver |
|------|--------------------|----------|
| **2D icon** | `StreetRig/Assets.xcassets/<slug>.imageset/` | [`GearIconLoader`](StreetRig/Views/GearIconLoader.swift) |
| **3D model** | `StreetRig/GearModels/<slug>.usdz` | [`GearModelLoader`](StreetRig/Views/GearModelLoader.swift) |

## The slug rule

`lowercase`, replace every run of non-`[a-z0-9]` with a single `-`, trim `-`.

`"Ibonez Tube Screamer"` → `ibonez-tube-screamer` · `"ProCon RAT"` → `procon-rat` · `"Marswell 1960A 4x12"` → `marswell-1960a-4x12`

## Fallback chain (first hit wins)

- **Icon:** `<slug>` → `category-<category>` (e.g. `category-overdrive`) → procedural art.
- **Model:** `GearItem.modelName` → `<slug>.usdz` → `category-<category>.usdz` →
  **procedural textured with the piece's `<slug>.imageset`** → plain procedural.

That middle rung is why an amp or cabinet looks like itself on the 3D stage without
anyone modelling it: the same PNG that dresses its card is mapped onto the front of
the procedural box, and the box's width/height are derived from the image's pixel
size so the drawing keeps its proportions. A real `.usdz` still wins outright.

## What's customizable

| Piece | Icon (`Assets.xcassets/`) | Model (`GearModels/`) |
|-------|---------------------------|-----------------------|
| Guitar | `<guitar-slug>.imageset` | `<guitar-slug>.usdz` |
| **Guitar stand** | *(drawn on the guitar)* | `guitar-stand.usdz` |
| Amp **+ cab** (one model) | `<amp-slug>.imageset` | `<amp-slug>.usdz` |
| Cabinet | `<cab-slug>.imageset` | *(part of the amp model)* |
| Combo amp | `<combo-slug>.imageset` | `<combo-slug>.usdz` |
| **Any pedal** | `<pedal-slug>.imageset` | `<pedal-slug>.usdz` |

> **Every piece in the catalog already ships a bespoke icon** — all 47 pedals and all
> 14 amp heads, cabinets and combos (see
> [`StreetRig/GearIcons-README.md`](StreetRig/GearIcons-README.md)); custom **3D models**
> for any piece are the new drop-in below. The amp head + cabinet are one model
> (`<amp-slug>.usdz`), and a model for the amp covers the whole stack; the stand is its
> own file (`guitar-stand.usdz`).

## Getting an editable starting point (3D)

The procedural models bake to real files you can open in Blender:

1. In the Xcode scheme, set env var **`STREETRIG_EXPORT=1`** and run once (Debug).
2. Baselines write to the app's **Documents** folder (the path is printed to the console):
   `StreetRig_Amp`, `StreetRig_Pedal`, `StreetRig_Guitar`, `StreetRig_Stand` — each as
   `.usdz` (keeps PBR materials) **and** `.obj` (opens straight in Blender).
3. Refine in Blender → export a clean `.usdz` → rename it to the target slug
   (e.g. `marswell-jcm800-2203.usdz`, or `guitar-stand.usdz`) → drop it in **`StreetRig/GearModels/`**.
   It loads automatically.

The baked amp baseline is the *plain* procedural stack (head 3.4 × 1.15 × 1.25 at
y = 1.0, cab 3.7 × 2.5 × 1.45 at y = −0.85, bottom resting at y = −2.10) — the export
deliberately skips the art texturing so what you open in Blender is clean geometry.

## Status

- **Icons** — live for every piece (rail, library, cards, stage, detail) and, for amps
  and cabinets, on the 3D stage as well. All 61 catalog pieces — 47 pedals and 14
  amps/cabs/combos — ship bespoke icons today. Author more by dropping `<slug>.imageset`
  into `Assets.xcassets/`.
- **3D models** — the file seam is wired for the **amp + cab, guitar, stand, and every pedal**
  in the rig diorama, plus the amp's zoom-detail view. Author a custom `.usdz` at the baseline's
  scale/origin so it seats into the diorama layout cleanly (the export gives you that for free).
