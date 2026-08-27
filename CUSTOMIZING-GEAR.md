# Customizing gear — icons, knob panels & 3D models

Every gear piece resolves its **icon**, its **knob panel** and its **3D model** from a
file by the *same name convention*. Drop a file in, it wins; drop nothing, the app draws
its built-in procedural art. No code, no manifest, no in-app UI — resolution happens by
name at render time, so already-saved rigs keep working.

## Repo layout

```
StreetRig/
  GearModels/                    ← 3D models: drop <slug>.usdz here
    README.md
  Environments/                  ← the STAGE the gear stands on (scenery, not gear)
    README.md                      stage-environment.usdz — see StageEnvironment.swift
  PanelArt/                    ← knob panels: <slug>-panel.png — every piece with knobs ships one
    README.md
  Assets.xcassets/
    <slug>.imageset/             ← 2D icons (flat); the 47 catalog pedals already ship theirs
  Views/
    GearModelLoader.swift        ← resolves the .usdz
    GearIconLoader.swift         ← resolves the icon image
    PanelArtLoader.swift         ← resolves the knob panel's faceplate
    KnobPanelLayout.swift        ← the panel's rows and height (what a plate is baked to)
  PanelArtExporter.swift         ← bakes the panels to editable PNGs (STREETRIG_EXPORT_PANELS=1)
  Models/                        ← Swift DATA models (Gear.swift, RigStore.swift) — NOT assets
  GearIcons-README.md            ← icon deep-dive (art sizes, category defaults)
CUSTOMIZING-GEAR.md              ← this guide
```

Three seams, one rule:

| What | Drop the file into | Resolver |
|------|--------------------|----------|
| **2D icon** | `StreetRig/Assets.xcassets/<slug>.imageset/` | [`GearIconLoader`](StreetRig/Views/GearIconLoader.swift) |
| **Knob panel** | `StreetRig/PanelArt/<slug>-panel.png` | [`PanelArtLoader`](StreetRig/Views/PanelArtLoader.swift) |
| **3D model** | `StreetRig/GearModels/<slug>.usdz` | [`GearModelLoader`](StreetRig/Views/GearModelLoader.swift) |

## The slug rule

`lowercase`, replace every run of non-`[a-z0-9]` with a single `-`, trim `-`.

`"Ibonez Tube Screamer"` → `ibonez-tube-screamer` · `"ProCon RAT"` → `procon-rat` · `"Marswell 1960A 4x12"` → `marswell-1960a-4x12`

## Fallback chain (first hit wins)

- **Icon:** `<slug>` → `category-<category>` (e.g. `category-overdrive`) → procedural art.
- **Knob panel:** `Documents/PanelArt/<slug>-panel.png` (the on-device override, see below)
  → bundled `<slug>-panel.png` → bundled `category-<category>-panel.png` → the flat
  procedural plate (the piece's colour + the standing gradient).
- **Model:** `GearItem.modelName` → `<slug>.usdz` → `category-<category>.usdz` →
  **procedural textured with the piece's `<slug>.imageset`** → plain procedural.

That middle rung is why an amp or cabinet looks like itself on the 3D stage without
anyone modelling it: the same PNG that dresses its card is mapped onto the front of
the procedural box, and the box's width/height are derived from the image's pixel
size so the drawing keeps its proportions. A real `.usdz` still wins outright.

### The guitar is the exception: model-first

The guitar has **no procedural normal path** any more. Every 3D guitar render site
goes through one call, `GearModelLoader.guitarNode(for:)`, which resolves a `.usdz`
by the order above and expects `category-guitar.usdz` to be there. The old Les
Paul-ish body is retired: it draws only as a last resort, with a console warning and
an `assertionFailure`, so a missing file shows the *wrong* guitar rather than *no*
guitar. (An empty `guitarRoot` reads as a layout bug and costs hours; a guitar plus a
console line names its own cause.)

The bundled `category-guitar.usdz` is **not committed** — see
[`research/strat-model-evaluation.md`](research/strat-model-evaluation.md) for why.
Without it, a Debug build traps on the rig stage.

Two rules apply to a guitar model and to no other piece:

- **It is fitted, not trusted.** `GearModelLoader.fit(_:into:)` uniformly scales the
  loaded node so its *height* matches the retired procedural body, then centres it in
  x/z and stands it on that body's floor. So a file authored at real-world scale in
  metres or centimetres just works — and equally, **rescaling the file will not change
  the guitar's on-stage size**. Uniform scale on purpose: matching all three extents
  would squash a Strat into a Les Paul's proportions.
  `RigStage3DView`'s `gScale`, its guitar contact shadow and
  `RigDiorama.minCameraDistance` are all tuned against that envelope
  (`GearModelLoader.proceduralGuitarBounds`), which is measured from the procedural
  builder at runtime so the two can't drift.
- **A bundled stand is stripped.** Any sub-node whose name contains `stand` is removed
  on load. Downloaded guitars often ship a floor stand in the same file, and StreetRig
  draws its own through the independent `guitar-stand.usdz` seam — keeping both would
  put the guitar in two stands at once. Name your meshes with that in mind.
  **On the stage there is no stand at all any more:** the guitar stands on the boards
  and leans against the stool that the stage model supplies. The stand seam still
  applies to the guitar *detail* view, and the strip above still applies everywhere.

## What's customizable

| Piece | Icon (`Assets.xcassets/`) | Knob panel (`PanelArt/`) | Model (`GearModels/`) |
|-------|---------------------------|--------------------------|-----------------------|
| Guitar | `<guitar-slug>.imageset` | *(no knobs, no panel)* | `<guitar-slug>.usdz` — or `category-guitar.usdz` for every guitar (**required**, see above) |
| **Guitar stand** | *(drawn on the guitar)* | *(n/a)* | `guitar-stand.usdz` — detail view only; on the stage the guitar leans on the stool |
| Amp **+ cab** (one model) | `<amp-slug>.imageset` | `<amp-slug>-panel.png` | `<amp-slug>.usdz` |
| Cabinet | `<cab-slug>.imageset` | *(no knobs, no panel)* | *(part of the amp model)* |
| Combo amp | `<combo-slug>.imageset` | `<combo-slug>-panel.png` | `<combo-slug>.usdz` |
| **Any pedal** | `<pedal-slug>.imageset` | `<pedal-slug>-panel.png` | `<pedal-slug>.usdz` |
| **The stage itself** | *(n/a)* | *(n/a)* | `Environments/stage-environment.usdz` — scenery, not gear; see [that README](StreetRig/Environments/README.md) |

> **Every piece in the catalog already ships a bespoke icon** — all 47 pedals and all
> 14 amp heads, cabinets and combos (see
> [`StreetRig/GearIcons-README.md`](StreetRig/GearIcons-README.md)); custom **3D models**
> for any piece are the new drop-in below. The amp head + cabinet are one model
> (`<amp-slug>.usdz`), and a model for the amp covers the whole stack; the stand is its
> own file (`guitar-stand.usdz`), drawn in the guitar detail view only.

## Knob panels — a PNG per component

The plate the turnable knobs sit on in the zoom-detail view is a **picture**, one file per
component: `StreetRig/PanelArt/<slug>-panel.png`. Every catalog piece that has knobs ships
one (55 of them, plus 12 `category-<category>-panel.png` fallbacks), baked from the app so
each is pixel-for-pixel the panel it replaced — a starting canvas, not a blank one.

A plate is the surface **under** the knobs and nothing else: the knobs, their captions and
the panel's rounded corners and edge stroke stay live views on top, because the knobs turn.
Paint colour, metal, tolex, branding, screws, wear — not knobs.

- Drawn **fill-and-crop**, never stretched: author at the size the exporter bakes and it
  lands exactly, author at another aspect and the overflow is trimmed off the edges.
- The piece's signature colour sits underneath, so a plate with transparency **tints**.
- Sizes come from `KnobPanelLayout.height` — the same math that lays the knobs out — at
  800 pt wide, 3×. In practice **2400 × 216** for a one-row panel and **2400 × 534** for a
  full-height multi-row one.

### Re-baking, and editing on the device

1. Set **`STREETRIG_EXPORT_PANELS=1`** in the scheme's launch environment, run once
   (Debug). Plates land in the app's `Documents/PanelArt/`; the path is printed to the
   console. Existing files are never overwritten — those are edits. `=force` replaces them.
2. Edit them **in place**: the Documents folder is visible in **Files → On My iPhone →
   StreetRig**, a plate there beats the bundled one, and the cache is dropped when the app
   returns to the foreground. Edit, switch back, open the panel — no rebuild.
3. Copy what you want to ship into **`StreetRig/PanelArt/`**. Synchronized file groups
   bundle it on the next build.

See [`StreetRig/PanelArt/README.md`](StreetRig/PanelArt/README.md) for the full seam.

## Pedal enclosure archetypes (3D)

A pedal with no `<slug>.usdz` no longer renders as one generic box. It resolves to an
**enclosure archetype** — a parametric shape for its real-world class — picked from its
name first and its category second, exactly the way its icon and its knob set already
are. Colours, LED colour and knob count come from the same tables as everywhere else
(`PedalSpec.parameters(forName:category:)` supplies the control count), so the archetype
only decides the *shape*.

| Archetype | Real-world class | Catalog examples | What makes it that shape |
|---|---|---|---|
| `mxrBox` | 1590B compact | `MXP phase 90`, `MXP dyna comp`, `Fullstone OCD`, `FORTIS ZUUL`, `DUNLAP ECHOPLEX` | Small, low, flat top; knobs by the back edge; footswitch at the front |
| `bossCompact` | Compact with a tread plate | every `VOSS *` pedal, `Ibonez Tube Screamer` | Big hinged tread plate over the front, knobs recessed on a shelf above it, no separate footswitch |
| `bigBox` | 1590BB / oversized fuzz + EQ | `VOSS Metal Zone`, `electro-harmonium BIG MUFF π`, `EMPRISS ParaEq`, `Chiron CENTAUR`, `ProCon RAT`, all `electro-harmonium *` | Wider and longer; two rows of knobs, or a slider bank past six controls |
| `wahRocker` | Wah | `DUNLAP CRY BABY`, `VOLT V847`, `MORLEE BAD HORSIE` | Long tapered chassis, side rails, a ridged treadle **hinged at the heel** |
| `trebleWedge` | Volume / expression treadle | `VOSS FV-500H`, `ERNIE BELL VP JR`, `DigiTek WHAMMY` | The same rocker with nothing on top and a steeper heel |
| `tunerWedge` | Compact tuner | `VOSS Chromatic Tuner` | Compact shell whose back half is a dark display with a lit needle |
| `roundFuzz` | Fuzz Face | `DALLAS ARBITOR FUZZ FACE` | The one **round** enclosure; two widely-spaced knobs |
| `looperDeck` | Loop station | `VOSS Loop Station`, `electro-harmonium FREEZE` | Wide deck with **two footswitches** side by side and a readout |

Two things every archetype guarantees, because shipped features look them up by name:

- exactly one node called **`led`** (`ARFloorPedals` lights it when the footswitch is engaged);
- for the rockers, a pivot node called **`treadle`** whose x-rotation tracks the pedal's
  `Position` value (`Studio3D.treadleAngle(forValue:)`), so the treadle moves with the knob.

The board sizes itself from these footprints rather than from a pedal count, so a row that
holds a wah still lays out without overlap. **A bespoke `<slug>.usdz` still wins outright** —
drop one in and the archetype is never consulted for that piece. Author it at the footprint
of the archetype it replaces (bake that archetype below to get exactly that) so it seats into
the row cleanly.

Archetypes are geometry only: no logos, brand scripts or trade dress, per
[`research/3d-amp-rendering-options.md`](research/3d-amp-rendering-options.md) §5.

## Getting an editable starting point (3D)

The procedural models bake to real files you can open in Blender:

1. In the Xcode scheme, set env var **`STREETRIG_EXPORT=1`** and run once (Debug).
2. Baselines write to the app's **Documents** folder (the path is printed to the console) —
   each as `.usdz` (keeps PBR materials) **and** `.obj` (opens straight in Blender):
   `StreetRig_Amp`, `StreetRig_Guitar`, `StreetRig_Stand`, plus **one file per pedal
   archetype**: `StreetRig_Pedal_MxrBox`, `StreetRig_Pedal_BossCompact`,
   `StreetRig_Pedal_BigBox`, `StreetRig_Pedal_WahRocker`, `StreetRig_Pedal_TrebleWedge`,
   `StreetRig_Pedal_TunerWedge`, `StreetRig_Pedal_RoundFuzz`, `StreetRig_Pedal_LooperDeck`.
   `StreetRig_Guitar` is the odd one out: since the procedural guitar is retired, it
   bakes the **loaded, fitted model** at its exact in-app scale, pivot and facing —
   i.e. the box your replacement has to land in — rather than clean primitive geometry.
   It is also much the slowest and heaviest of them to write.
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
- **Knob panels** — live for every component that HAS knobs: all 55 catalog pieces with
  controls ship a baked plate, and 12 category plates cover anything added later. Cabinets,
  the guitar, the tuner and the loopers have no adjustable controls, so no panel and no
  plate; give one knobs in `PedalSpec.parameters` and it needs a plate too.
- **3D models** — the file seam is wired for the **amp + cab, guitar, stand, and every pedal**
  in the rig diorama, plus the amp's zoom-detail view. Author a custom `.usdz` at the baseline's
  scale/origin so it seats into the diorama layout cleanly (the export gives you that for free).
- **Pedal archetypes** — every one of the 47 catalog pedals resolves to one of the eight shapes
  above, so a pedal with no bespoke `.usdz` still reads as its real-world class on the stage
  and in AR. Refining an archetype means baking it, editing it, and dropping the result back in
  under the slug of the piece you want it for.
