# Environments — the stage the rig stands on

Separate from [`../GearModels/`](../GearModels/README.md) on purpose. That folder holds
**gear**, resolved per piece by slug. This folder holds the **scenery** the gear stands
on: one file, loaded by a fixed name, owned by
[`StageEnvironment`](../Views/StageEnvironment.swift).

| | |
|---|---|
| File | `stage-environment.usdz` |
| Loader | `StageEnvironment.node()` |
| Used by | `RigStage3DView` (the 3D diorama) |
| Absent | the diorama renders on nothing, exactly as it did before this existed |

## Attribution — do not remove

The shipped file is **"Before concert" by LP Cupcake**, https://skfb.ly/oDS96, licensed
**CC BY 4.0** (http://creativecommons.org/licenses/by/4.0/). StreetRig modifies it:
the source scene's bass and combo amps are stripped, the ceiling props are cropped, the
drink can, loose floor pedal, mic stand and both cables are removed, the bar stool is
scaled down, and the platform is rescaled and rotated.

That licence is conditional on the attribution staying **reachable in the shipped app** —
it lives in [`CreditsView`](../Views/CreditsView.swift), behind the ⓘ in the top nav, and
is not decoration. Replacing the asset means updating `Credits.all` in the same commit.

## Why the loader does work at load time

A stage authored for its own room does not drop into a diorama unchanged. `StageEnvironment`
solves four things, each of which was a visible bug before it did:

1. **The floor is not at the origin.** The boards sit at y ≈ 2.58 in model units, above
   a bounding-box floor of 2.45. Placing gear against the box buried the pedalboard,
   which is only 0.086 units tall. The loader finds the floor as **the widest flat
   surface** in the lower half of the model — a floor being the one thing in a room
   that is both flat and 4.5 m across.

   This replaced a rule that took the highest vertex band still carrying surface area,
   which assumed a raised deck on open ground. On this asset that lands on the clutter
   at y ≈ 10.6 instead of the boards at 2.58, and since the stage is then dropped by the
   difference, every piece of gear floated 0.21 units above the floor — barely visible
   on the amp, obvious on the pedalboard, and the reason the rig read as pasted onto the
   stage rather than standing on it.
2. **Scale has to be calibrated, not eyeballed.** The mic stand is ~105 model units for a
   real ~1.5 m stand, so the asset runs ~70 units/metre and its disc is ~4.5 m. Sized by
   eye at 11 diorama units, the bar stool stood taller than the guitar.
3. **Props authored against a ceiling float without one.** A hanging tray of drinks sat
   over the amp with nothing holding it. The mesh is a single element with a single
   material, so there is no node to remove — the loader rebuilds the index buffer without
   those triangles, from what step 4 leaves behind.
4. **Some props needed to change, and none of them are nodes.** Same single-mesh problem,
   so `StageEnvironment.props` names each one as a cylinder in the asset's own
   coordinates and `reshape` cuts its triangles into their own node:

   | Prop | Tris | What happens |
   |---|---|---|
   | Drink can on the boards | 906 | dropped — it read as litter, and it is the nearest thing to the lens at the default camera |
   | Loose floor pedal + knobs | 2,094 | dropped — StreetRig draws the user's real pedalboard a few units away, and a second one that cannot be tapped reads as a bug |
   | Mic stand (tripod, column, boom, mic) | 2,552 | dropped — it stood between the camera and the cab, and the rig has no mic in it |
   | Cable hanging from the ceiling | 6,200 | dropped |
   | Cable coiled over the boards | 4,440 | dropped — the widest prop on the stage, which is why it is matched last |
   | Bar stool (+ the cup and case on its seat) | 1,162 | scaled to **0.6** about its own footprint at floor level |

   What is left on the boards is the floor and the stool. Selection is by CONNECTED
   COMPONENT, all-or-nothing — a component joins a prop only if every vertex of it is
   inside the cylinder. Classifying loose triangles instead cuts objects in half:
   removing the can took 78 triangles of the coiled cable with it, because the cable
   passed through the can's cylinder. It also makes the floor safe for nothing: it is
   one piece 318 units across, so no cylinder small enough to name a prop can hold it.

   The stool was modelled 2.05 diorama units to the seat — taller than the 1.85-unit
   guitar beside it, which is most of why the stage read like a doll's house. At 0.6 the
   seat lands at 1.23 (≈72 cm) and 0.63 across (≈37 cm), and it is low enough that
   `RigDiorama` can lean the guitar on it: the stand is gone, and the guitar now rests on
   the boards against the stool. `StageEnvironment.stoolSeat` publishes where the seat
   ended up so that lean is solved against the measurement, not a hand-picked angle.

## Swapping in a different stage

Drop a replacement at `stage-environment.usdz` and it loads. The measuring is generic, so
a different floor height or unit scale is handled — but check `yaw` and `targetDiameter` in
`StageEnvironment`, which are tuned to *this* model's prop layout, and **update the credit**.

`props` is the one part that is *specifically* about this file: each entry is a position
measured out of this .usdz, so against another stage they resolve to empty cylinders and
do nothing. That is the intended failure — nothing breaks, the props simply stay as the
new asset authored them. With no stool found, `stoolSeat` is `nil` and the guitar stands
up straight instead of leaning.
