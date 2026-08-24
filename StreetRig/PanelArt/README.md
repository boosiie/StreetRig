# PanelArt — the knob panel's surface, as a PNG per component

Every component's **knob panel** — the plate the turnable knobs sit on in the zoomed-in
detail view — is a picture in this folder. Open one, repaint it, save it. That's the
whole workflow: no Swift, no manifest, no `project.pbxproj` edit. The Xcode project uses
synchronized file groups, so a PNG dropped here is bundled on the next build.

```
ibonez-tube-screamer-panel.png     ← the Tube Screamer's faceplate
marswell-jcm800-2203-panel.png     ← the JCM800's
category-overdrive-panel.png       ← every overdrive with no plate of its own
```

## Every amp has its own

The eleven amp heads and combos each bake a **different** faceplate — gold brushed
acrylic on the Marswells, silver on the Fandor Twin, cooler grey on the Rolund, copper on
the Volt, gunmetal on the Mesa, matte black on the Freedman, the DSL40C and the Katana
(told apart by their chassis trim: gold, white, amber), orange on the Tangerine, tweed on
the Bassman. That baseline lives in
[`Faceplate.swift`](../Views/Faceplate.swift), matched by substring on the model name.

**One thing there is not in the PNG: whether the plate is light.** Knob captions are drawn
dark on a light panel and light on a dark one, and that comes from `Faceplate.ampSpec`,
not from the image. So if you repaint the Mesa's gunmetal plate cream, flip its `isLight`
in `Faceplate.swift` too — otherwise you get white labels on a pale plate.

## What a plate is (and isn't)

A plate is the surface **under** the knobs and nothing else. The knobs, their captions,
the channel dividers and the panel's rounded corners and edge stroke are live views drawn
on top — they have to be, because the knobs turn. So paint a faceplate: colour, brushed
metal, tolex, screened branding, screws, wear. Don't paint knobs.

- It is drawn **fill-and-crop**, never stretched. Author at the size the exporter bakes
  and it lands exactly; author at some other aspect and the overflow is trimmed off the
  edges rather than the artwork being squashed.
- The piece's signature colour still sits **underneath**, so a plate with transparency
  tints rather than replaces.
- Knob captions are drawn in black on a light panel and white on a dark one, decided by
  `GearArtView.panelIsLight(for:)` — a plate that inverts a piece's brightness will fight
  its labels.

## Placing the knobs: `<slug>-panel.json`

A plate that is a real faceplate — printed scales, a well drawn for each knob — has to
place the knobs itself, or the app spaces them evenly across the panel and they land
*beside* their markings instead of in them. Drop a sidecar next to the art:

```json
{
  "captions": false,
  "knobs": [
    { "param": "Presence", "x": 0.38088, "y": 0.47608, "d": 0.31944 },
    { "param": "Bass",     "x": 0.44946, "y": 0.47608, "d": 0.31944 }
  ]
}
```

- **`param`** is the control's internal name (`GearParameter.name`) — `"Mid"`, not the
  printed `"MIDDLE"`. Find them in `PedalSpec.parameters` in `Gear.swift`.
- **`x`** is a fraction of the plate's own width; **`y`** and **`d`** (the knob diameter)
  are fractions of its height. Authoring at 2400 × 216? A knob centred at (915, 103) and
  69 px across is `x: 915/2400`, `y: 103/216`, `d: 69/216`.
- **`captions`** defaults to `false`: a plate that places its knobs has the names printed
  on it, and drawing the app's labels again lands text on text. Set `true` if your plate
  has no lettering.
- Anchors go through **exactly the transform the image does**, so a knob stays glued to
  its painted well at any panel size — it scales and moves with the art.
- The layout is used only when it accounts for **every** dial the piece has. Add a knob to
  an amp and forget its anchor and the panel falls back to the automatic rows, rather than
  leaving a control undrawn and unreachable.
- The knob is *drawn* at `d`, but its **touch target** grows to 44 pt where the spacing
  allows, so a small faceplate knob is still draggable.

`marswell-jcm800-2203-panel.json` is the worked example: six knobs measured off the
JCM800 artwork. A piece with a sidecar is also **never re-baked** by the exporter, even
with `=force` — hand art is not something a baseline should bury.

## Naming

`<slug>-panel.png`, where `<slug>` is the same slug the icons and `.usdz` models use —
lowercase, every run of non-`[a-z0-9]` replaced by a single `-`, trimmed:

| Component | Plate |
|---|---|
| `Ibonez Tube Screamer` | `ibonez-tube-screamer-panel.png` |
| `electro-harmonium BIG MUFF π` | `electro-harmonium-big-muff-panel.png` |
| `Fandor Bassman '59` | `fandor-bassman-59-panel.png` |
| *(any overdrive without its own)* | `category-overdrive-panel.png` |

`.jpg` works too, but PNG is what the exporter bakes and the only format that can carry
transparency.

## Resolution order (first hit wins)

1. `Documents/PanelArt/<slug>-panel.png` — the **live override on the device**, see below
2. `<slug>-panel.png` — bundled, i.e. this folder
3. `category-<category>-panel.png` — bundled, one plate for a whole category
4. nothing — the app draws `ProceduralPlate` (the piece's colour + the standing gradient)

## Editing on the device, without a rebuild

The app's Documents folder is visible in **Files → On My iPhone → StreetRig**. A plate in
`PanelArt/` there beats the bundled one, and the cache is dropped whenever the app comes
back to the foreground — so: edit the PNG, switch back to StreetRig, open the panel, see
it. That folder is also where the exporter writes.

## Re-baking the baselines

Every plate here was baked from the app itself, so it is pixel-for-pixel the panel it
replaced — a starting canvas, not a blank one. To regenerate:

1. Set **`STREETRIG_EXPORT_PANELS=1`** in the scheme's launch environment and run once
   (Debug). Plates land in `Documents/PanelArt/`; the path is printed to the console.
   Existing files are **never** overwritten — those are your edits. Use
   `STREETRIG_EXPORT_PANELS=force` to replace them with clean baselines.
2. Copy what you want to ship into this folder.

Sizes come from `KnobPanelLayout.height` — the same math that lays the knobs out — at
`PanelArt.referenceWidth` (800 pt) and `PanelArt.exportScale` (3×). In practice that is
**2400 × 216** for a one-row panel and **2400 × 534** for a full-height multi-row one.

## Which components have plates

Every catalog piece that HAS a knob panel — 55 of them, all eleven amps distinct — plus 12
category fallbacks.
Cabinets, the guitar, the tuner and the loopers have no adjustable controls, so they have
no panel and no plate; give one knobs in `PedalSpec.parameters` and it needs a plate too.

See also [`../../CUSTOMIZING-GEAR.md`](../../CUSTOMIZING-GEAR.md) for the icon and 3D-model
seams, which follow the same naming rule.
