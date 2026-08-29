# Apple Stratocaster `.usdz` on the rig stage — evaluation

**Status: evaluation, not a ship decision.** The model is wired in and running, and the
asset file is deliberately **left uncommitted** in the working tree
(`StreetRig/GearModels/category-guitar.usdz`, untracked) pending the licensing call in
§1, which is the user's to make.

---

## 1. Licensing — a decision for you, not for me

### Where it came from

| | |
|---|---|
| Gallery page | `https://developer.apple.com/augmented-reality/quick-look/` (redirects to `https://developer.apple.com/quick-look-gallery/`) |
| Asset URL | `https://developer.apple.com/quick-look-gallery/models/stratocaster/fender_stratocaster.usdz` |
| SHA-256 | `3e0ee48cad8f03cb807cf4747be9c4a48023384a5450efbe269d8550bcf9f61e` |
| Bytes | 15,128,024 |
| Authored | payload timestamps 2025-06-12 |

The URL was read off the live gallery page, not recalled — Apple rotates these paths.
The page lists 18 downloadable models; the Stratocaster is one of them, presented with no
caption, no attribution line, and no per-asset licence.

### The terms

Apple attaches **no asset-specific licence** to these models. The only usage text on the
gallery page is the standard Apple developer-site footer notice, which points at Apple's
site Terms of Use and then states that no part of the site and no content provided may be
copied, reproduced, republished, publicly displayed, transmitted or distributed to any
other medium — the notice singles out doing so **"for any commercial enterprise"** —
without Apple's express prior written consent (Apple Developer, *Quick Look Gallery*
footer).

> I have excerpted rather than reproduced the notice in full. It is ~70 words of Apple's
> own legal text; read it verbatim at the two URLs above and at
> `https://www.apple.com/legal/internet-services/terms/site.html` before deciding —
> for a licensing call you want the primary source, not my transcription.

Apple's site Terms of Use, under **Content**, is the operative document the footer defers
to. Its permission to download material is scoped to a **personal, non-commercial
informational purpose**, with proprietary notices retained and no modification. It also
states that site content is protected by trade dress, copyright, patent and trademark law
and is owned, controlled or licensed by or to Apple.

Read plainly, that grant does not cover redistributing the file inside a shipped app.

### The trademark layer, which is separate and additive

Even if Apple's terms permitted redistribution, the *subject* of the model is a Fandor
Stratocaster. "Fandor" and "Stratocaster" are Fandor Musical Instruments Corporation
trademarks, and the guitar's body outline and headstock shape are themselves protected
trade dress. Apple presumably has an arrangement with Fandor for this demo asset. Nothing
on the page suggests that arrangement extends to third parties, and the filename that
ships inside the archive — `fandor_stratocaster.usdc`, plus eight
`fandor_stratocaster_*` textures — carries the mark into the app bundle whatever the file
is renamed to on disk.

### The tension with this codebase

StreetRig has, until now, deliberately gone the other way. Two examples, both explicit:

- `StreetRig/Views/AmpModel3DView.swift:185` describes the generic amp as deliberately
  **not** a replica of any real, trademarked product.
- The old header of `StreetRig/Views/GuitarModel3DView.swift` described the procedural
  guitar as generic, with no brand marks.

The whole catalogue follows the same rule by another route — `Marswell MSW900`,
`Iberon Valve Shrieker`, `ProForge SHREW`, `BRIG` — recognisable homages with the marks filed
off. Dropping a genuine, Fandor-branded, Apple-supplied Stratocaster into the middle of
that is the first branded replica in the app, and it would be the single most prominent
object on the stage.

### The options as I see them

1. **Ship it as-is.** Fastest, best-looking, and takes on both the Apple redistribution
   question and the Fandor trademark question at once. Reasonable only after you have read
   Apple's terms yourself and, realistically, only for a free/non-commercial release — and
   even then the trademark exposure is Fandor's to assert, not Apple's.
2. **Use it as a modelling reference only.** Keep it out of the repo, open it in Blender,
   and author an original generic double-cutaway that matches the house style of the amps
   and pedals. The seam built here does not care where the file came from — any
   `category-guitar.usdz` at any scale drops straight in. This preserves the codebase's
   stated stance and is what the existing naming convention implies.
3. **Licence a different asset.** Buy a royalty-free generic electric guitar from a stock
   3D marketplace with a licence that explicitly permits app redistribution. Costs money,
   removes both questions, keeps today's quality jump.
4. **Revert to procedural.** Delete the file; the retired `ProceduralGuitar.buildGuitar`
   still draws (see §5). No work lost — the normalisation seam stays useful for whatever
   model eventually lands.
5. **Ask Apple / ask Fandor.** Both notices say "express prior written consent", which
   means there is an address to write to. Slow, but it is the only route that turns
   option 1 into a defensible one.

**I have not made this call and the file is not committed.** Option 2 is the one most
consistent with what the codebase already says about itself, but that is an observation,
not a decision.

---

## 2. Cost

### The file

| | |
|---|---|
| `category-guitar.usdz` | 15,128,024 bytes (14.4 MiB), uncompressed zip, `model/vnd.usdz+zip` |
| Payload | `fandor_stratocaster.usdc` — 9,148,297 bytes |
| Textures | 8 PNGs, 5,977,733 bytes total |

Texture dimensions:

| Map | Pixels |
|---|---|
| `bodywood_bc` | 2048 × 2048 |
| `neckwood_bc` | 2048 × 2048 |
| `buttontone_bc` | 1024 × 1024 |
| `buttonvolume_bc` | 1024 × 1024 |
| `stand_bc` | 1024 × 1024 |
| `stand_n` (normal) | 1024 × 1024 |
| `stand_r` (roughness) | 1024 × 1024 |
| `stand_m` (metallic) | 512 × 512 |

Note the map coverage is lopsided: the **stand** — the mesh this app throws away — is the
only part with normal/roughness/metallic maps. The guitar itself ships base-colour only
and gets its metal and gloss from constant PBR shader values, not textures. So ~1.4 MiB of
the download is texture data for geometry that is deleted on load.

### Geometry

| Mesh | Triangles | Points | Fate in StreetRig |
|---|---|---|---|
| `StratocasterGuitar` | 149,979 | 84,877 | rendered |
| `StratocasterStand` | 7,466 | 3,881 | **stripped on load** |
| **Total in file** | **157,445** | **88,758** | |

All-triangle topology on the guitar; the stand is mostly quads. 13 materials on the
guitar mesh, bound through `GeomSubset`s, plus 1 on the stand.

For scale: the procedural guitar it replaces is roughly a few thousand triangles — an
extruded bezier plus ~25 boxes and cylinders. This is a **~2 orders of magnitude** increase
in triangles for one object on the stage.

### Authoring convention (why normalisation was needed)

`metersPerUnit = 0.01`, `upAxis = "Y"`. The guitar mesh's authored extent is
32.6 × 96.8 × 24.9 **centimetres** — a real Strat, leaning back, at real-world size. The
diorama works in its own unit space where the guitar is ~4.5 units tall. Dropped in raw
through the old code path it would have arrived roughly 20× too large with its pivot in the
wrong place, which is exactly the failure mode requirement 4 exists to prevent.

### `.app` size delta

Debug, iphonesimulator, same DerivedData, measured as the sum of every file in the
product bundle. "Before" is this same branch built with the `.usdz` absent, so the delta
isolates the asset rather than mixing in code changes (the Swift changes add nothing
measurable):

| | Bytes | |
|---|---|---|
| Before | 11,168,711 | 10.65 MiB |
| After | 26,298,608 | 25.08 MiB |
| **Delta** | **+15,129,897** | **+14.43 MiB, +135%** |

The delta is the raw file (15,128,024) plus ~22 KB of signature/plist churn — the asset
is stored, not compressed further, because a `.usdz` is already an uncompressed zip.
**The app's install size more than doubles for one object.**

### Bundle placement — verified, not assumed

The Xcode-16 synchronized file group picked the file up with no `project.pbxproj` edit,
and the resource copy **flattens** it to the bundle root, which is exactly where
`Bundle.main.url(forResource:withExtension:)` looks. From the build log:

```
CpResource .../StreetRig.app/category-guitar.usdz
           .../StreetRig/GearModels/category-guitar.usdz
```

Confirmed present in the product at `StreetRig.app/category-guitar.usdz`, 15,128,024 bytes.

---

## 3. Performance

**I could not measure frame rate.** Stating that plainly rather than quoting a number:
the instrumented run that would have carried SceneKit's on-screen statistics HUD was lost
when the host machine filled its disk (see §6), and a simulator fps figure on a contended
M1 Air would not have predicted device behaviour anyway. What follows is what I actually
measured.

### Load time

From an instrumented Debug run on the iPhone 16 Pro simulator, iOS 26.5:

| Step | Time |
|---|---|
| `SCNScene(url:)` + re-parent (`AmpScene.load`) | **1298.7 ms** |
| Strip stand + recursive bounds + fit | **6.6 ms** |

That ~1.3 s is on the main thread, synchronously, while the rig stage's scene is being
built. Caveats in both directions: the host was heavily loaded by concurrent builds, and
this is a simulator; but 15 MB of USD with 2048² PNGs to decode is genuinely not free, and
**the current code path has no async load and no caching** — every rebuild of the stage
scene pays it again. If the model ships, that is the first thing to fix.

The normalisation itself is negligible: 6.6 ms, once.

### Scene cost, procedural vs model

| | Procedural (retired) | Apple Strat (as rendered) | Ratio |
|---|---|---|---|
| Nodes | 30 | 4 | 0.13× |
| Geometries | ~26 | 1 | |
| SceneKit primitives | 2,136 | 149,979 | **70×** |
| Vertices | 3,372 | 84,877 | **25×** |
| Materials (≈ draw calls) | ~26 | 19 | 0.7× |

The shape of the change is worth reading carefully: **triangles go up ~70×, but draw calls
go slightly DOWN.** The Strat is one mesh split by 19 `GeomSubset` material bindings,
where the procedural guitar was ~26 separate primitive nodes. On a modern iPhone GPU,
150k triangles in ~19 batched draws is an unremarkable load; draw-call count and texture
memory usually bite before raw triangle count does.

The real per-frame costs I would watch on device are the two 2048² base-colour textures
(~22 MB of GPU memory once decompressed to RGBA) and the fact that the scene's key light
casts a real shadow at a 2048² shadow-map size — a 150k-triangle object now has to be
rasterised into that map every frame as well.

Numbers from the file archive itself, for cross-reference: 149,979 triangles / 84,877
points on `StratocasterGuitar`; the discarded `StratocasterStand` is 3,897 faces
(7,466 triangles once fully triangulated) / 3,881 points.

### Fit correctness — the camera-framing check

This is the number that decides whether the stage's framing math still holds.

| | Procedural target | Strat, fitted | |
|---|---|---|---|
| Height | 4.4023 | **4.4023** | exact by construction |
| Width | 1.8400 | 1.4815 | 19.5% narrower |
| Depth | 0.6332 | 1.1328 | 79% deeper |
| Scale applied | — | 0.045493 | 96.77 cm → 4.40 units |

Taking the stage's own transform into account (`gScale = 0.42`, `eulerAngles.y = -0.5`),
the guitar's half-extent along x becomes **0.387 units, against the procedural body's
0.403** — so its right edge sits at x ≈ 2.187 instead of 2.203. It moves *inward* by
0.016 units. `RigDiorama.minCameraDistance` and the stage framing are therefore safe with
margin; nothing needed retuning, and nothing was retuned.

The one real difference is depth: Apple's guitar is modelled **leaning back** (that is why
its authored z-extent is 24.9 cm on a 4.5 cm-thick instrument), so the fitted node is
0.50 units deeper than the procedural body was. At stage scale that is ±0.10 units of
extra front-to-back reach, comfortably inside the existing 1.7 × 1.4 contact shadow.

---

## 4. Fidelity

Captured on an iPhone 16 Pro simulator, iOS 26.5, Debug, default camera, no gestures
applied. Screenshots (session scratchpad, not committed):
`after-stage.png` (full stage, 2622 × 1206) and `after-guitar-zoom.png` (the guitar at
native resolution).

### It looks better. Clearly better.

The stage now shows a cherry-sunburst Stratocaster standing in the A-frame stand to the
right of the amp: real wood grain fading through the burst, a white three-ply pickguard,
three single-coil pickups, a rosewood fretboard with dot inlays and individually modelled
frets, a maple headstock with six chrome tuners in a line, and the tremolo arm hanging
off the bridge. Next to it the retired procedural body — an extruded outline with box
pickups and cylinder knobs — is not in the same category. This is the single biggest
visual upgrade available to the stage for one file.

Against the checklist:

| Check | Result |
|---|---|
| Correct size relative to the amp | **Yes.** Reads as a guitar beside a full stack — a little shorter than head + cab together, which is right. |
| Sitting ON the stand, not floating or sunk | **Yes.** The lower bout rests in the cradle arms; base on the same floor line as the board and amp; the contact shadow lands under it. |
| Upright, headstock up | **Yes.** |
| Facing the camera | **Yes** — pickguard, pickups and bridge all face the viewer. |
| Not clipped by the near plane or pushed out of frame | **Yes.** Fully in frame with margin to the right; nothing else moved. |
| Lit consistently with the rest of the diorama | **Partly — see below.** |
| Bundled stand stripped, app's own stand drawing | **Yes.** Loaded tree went from `{Looks, StratocasterGuitar, StratocasterStand}` to `{Looks, StratocasterGuitar}`. |

### Two things that are honestly wrong

**1. The headstock blooms.** The maple headstock is the brightest surface in the diorama
and the camera's grade latches onto it — there is a visible halo around it in the stage
shot, so the top of the neck reads as if it is *emitting* light rather than catching it.
This is exactly the lighting mismatch to expect: `Studio3D.addCamera` sets
`bloomIntensity 0.55` / `bloomThreshold 0.82`, tuned against the procedural materials'
muted palette, and the Apple asset's light woods and polished chrome sail past that
threshold. The white pickguard is close to clipping too. Fixable (raise the threshold, or
tone the model's specular) but it is not right as it stands.

**2. It hangs in the stand at the wrong angle.** Apple modelled the guitar leaning back
in *its own* stand, which the app throws away. In StreetRig's A-frame the inherited lean
puts the body forward of the cradle and tilts the neck a few degrees off vertical, so it
reads less like "resting in the stand" and more like it is about to slide out of it. The
fit is geometrically correct — the numbers in §3 are exact — but the *pose* was authored
for different furniture. The clean fix is a small counter-rotation on load, or replacing
`ProceduralGuitar.buildStand` with a stand shaped for this lean. I did not do either:
requirement 3 said the stand is not part of this change, and the tilt is a judgement call
you should see before I tune it away.

### Not captured, because it does not exist

There is **no in-app guitar detail view to screenshot.** Two independent reasons:

- `GuitarModel3DView` / `GuitarScene` — the prompt's render site 2 — is referenced only by
  its own `#Preview`. Nothing in the app instantiates it.
- The stage refuses to focus the guitar *by design*. `RigStage3DView.swift:279`:
  `case .guitar: break // no controls to adjust`. I confirmed this is not a regression
  from this change by tapping the amp with the same injected-tap path — the amp's detail
  overlay opens normally; the guitar's tap is simply discarded.

So the closest thing to a "zoomed detail view" is the native-resolution crop of the stage
render, which is what §4's assessment above is based on. If you want a real guitar detail
view, that is a separate feature — the loader work here is what it would need, and
`GuitarScene.make(item:)` is already wired for it.

---

## 5. What changed in the code

| File | Change |
|---|---|
| `StreetRig/Views/GearModelLoader.swift` | New: `Bounds`, `recursiveBounds(of:)`, `fit(_:into:yaw:)`, `removeNodes(in:whereNameContains:)`, `proceduralGuitarBounds`, `guitarNode(for:)`. |
| `StreetRig/Views/RigStage3DView.swift` | Stage guitar now `GearModelLoader.guitarNode(for: guitar)`. Stand block untouched. |
| `StreetRig/Views/GuitarModel3DView.swift` | `GuitarScene.make(item:)` uses the same call; header rewritten; `ProceduralGuitar` doc-commented as retired-body + live-stand. |
| `StreetRig/ModelExporter.swift` | Guitar baseline now bakes the loaded, fitted model instead of the retired procedural body. |
| `CUSTOMIZING-GEAR.md`, `StreetRig/GearModels/README.md` | Fallback chain updated for the guitar's model-first behaviour, the fitting rule, and stand-stripping. |

Three design points worth knowing:

**One code path.** Both 3D guitar render sites call `GearModelLoader.guitarNode(for:)`.
Nothing else builds a guitar body. That is what keeps the stage and the detail view from
disagreeing about size.

**Fitted, not trusted.** `fit(_:into:)` scales the loaded node uniformly so its *height*
matches the retired procedural body, centres it in x/z, and stands it on that body's floor.
Uniform rather than per-axis on purpose — matching all three extents would squash a Strat
into a Les Paul's proportions. The target box is measured from
`ProceduralGuitar.buildGuitar` at runtime rather than transcribed, so the envelope
`RigStage3DView.gScale`, the guitar contact shadow and `RigDiorama.minCameraDistance` are
tuned against can never silently drift.

**The stand is stripped.** Apple's file is *two* meshes — the guitar and a floor stand.
StreetRig draws its own stand through the separate `guitar-stand.usdz` seam, so loading
the file whole put the guitar in two stands at once. `guitarNode` removes any sub-node
whose name contains `stand`. `ProceduralGuitar.buildStand` and its override are untouched.

**Missing-asset behaviour.** `guitarNode` never returns an empty node. If nothing
resolves it prints a `⚠️` line naming the expected filename, calls `assertionFailure`, and
draws the retired procedural body. Note the trade-off: **`assertionFailure` traps Debug
builds**, and the asset is deliberately uncommitted, so a fresh clone without the file will
trap on the rig stage. That is intentional — it names its own cause instantly rather than
showing a mystery — but if you settle on option 4 above, delete that one line and the
procedural body simply becomes the guitar again.

---

## 6. Loose ends

### The 2D guitar is still a Les Paul

`StreetRig/Views/GuitarOnStandView.swift` is SwiftUI vector art — `Shape`-based drawing,
not 3D — used by the non-3D stage (`RigStageView.swift:214`) and by `GearArtView`. A
`.usdz` cannot replace a `Shape`. **It was left alone, and it still draws a single-cutaway
Les Paul silhouette**, so with `FeatureFlags.amp3D` off, and anywhere `GearArtView` draws
the guitar, the app now shows two different instruments for the same piece of gear.
Reconciling it means either rendering a still from the model into an imageset or redrawing
the vector art as a double-cutaway. Neither was in scope.

### The guitar has no detail view at all

Worth knowing, because it changes what "render site 2" means:

- `GuitarModel3DView` / `GuitarScene` is referenced only by its own `#Preview`. Nothing in
  the app instantiates it. It was updated anyway — it is a guitar render site and it now
  goes through the same `GearModelLoader.guitarNode(for:)` call — but it is currently dead
  code, and `GuitarScene.make(item:)` gained an `item` parameter so it can be wired up.
- The stage deliberately does not focus the guitar: `RigStage3DView.swift:279` is
  `case .guitar: break // no controls to adjust`. Pre-existing, and verified not to be a
  regression from this change (the amp focuses normally through the same path).

### Not touched, deliberately

- AR surfaces (`ARFloorPedals.swift`, the AR pedal page) — pedal-only, and unverified on
  device regardless.
- Amp, pedal, lighting and camera tuning — untouched beyond what the fit required, which
  turned out to be nothing.

### Not done

1. **Frame rate, before or after.** Not measured; see §3. The run that would have carried
   SceneKit's on-screen statistics HUD was lost when the host filled its disk, and a
   simulator fps figure on a contended M1 Air would not have predicted device behaviour
   anyway. I would rather report the load time and scene counts I actually have than
   quote a number I made up.
2. **A "before" screenshot** of the procedural guitar for side-by-side comparison. The
   host was in no state to spare another build cycle; the procedural body is unchanged in
   the tree if you want to render one (`ProceduralGuitar.buildGuitar`).
3. **The two fidelity problems in §4** — the headstock bloom and the stand lean — are
   reported, not fixed. Both are judgement calls that change how the diorama looks, and
   the second would mean touching the stand, which was explicitly out of scope.

Note on the host, since it shaped the above: three other worktree sessions were building
on this Mac concurrently. The APFS container hit 0 bytes free and the machine ran out of
process slots — `xcodebuild`, `simctl` and eventually every shell command failed
(`ENOSPC`, then `EAGAIN` on fork) for an extended stretch. To get moving again I deleted
`~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex` and `SymbolCache.noindex`
(pure compiler caches, regenerated on the next Xcode build) and ran
`xcrun simctl delete unavailable`. Nothing else of the user's was touched.

To reproduce the screenshots:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project StreetRig.xcodeproj -scheme StreetRig -configuration Debug \
  -sdk iphonesimulator -destination "id=<UDID>" -derivedDataPath <scratch>/dd build
xcrun simctl install <UDID> <scratch>/dd/Build/Products/Debug-iphonesimulator/StreetRig.app
xcrun simctl launch  <UDID> streetrig.StreetRig
# the rig stage is page 2 of 3 ("MY RIG"); the chevrons at the screen edges page between them
xcrun simctl io <UDID> screenshot shot.png && sips -r -90 shot.png
```

### Also worth knowing

- **The load is synchronous and uncached.** 1.3 s on the main thread every time the stage
  scene is built. Not addressed here; it would be the first change if the model ships.
- **`assertionFailure` traps Debug builds when the asset is absent**, and the asset is
  deliberately uncommitted. Documented at the call site with the one line to delete.
- **~1.4 MiB of the download is textures for the stand**, which is stripped on load. A
  re-export without that mesh would shrink the file meaningfully.
- **The Apple guitar is modelled leaning back** (authored to sit in its own stand). It
  inherits that lean in StreetRig's A-frame, which is plausible but unconfirmed by eye.
