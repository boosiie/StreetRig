# Real-Time 3D Amps for StreetRig — Rendering & Asset Research

**Status:** decision-ready · **Date:** 2026-08-06 · **Scope:** replace the flat SwiftUI
vector art (`GearArtView`) on the rig stage with real-time, interactive 3D amps modeled on
their real-world counterparts, starting with the hero amp and expanding to the catalog.

---

## TL;DR — the recommended path

1. **Rendering, now (the spike that ships this quarter): SceneKit via `SCNView` wrapped in
   `UIViewRepresentable`.** It reaches a great-looking, orbit-able PBR result with the least
   code, and — critically — it is only *soft*-deprecated on iOS 26, so it **compiles with
   zero deprecation warnings** (verified against this project's iOS 26.2 SDK build). This is
   what the prototype in this PR uses.
2. **Rendering, strategic (the full-catalog horizon): RealityKit / `RealityView`.** SceneKit
   is on a maintenance-only track; RealityKit is Apple's supported, USDZ-native future.
   `AmpModel3DView` is deliberately a thin abstraction so the renderer backend can be
   swapped without touching the rest of the app.
3. **Assets, now: procedural/parametric 3D** (what the prototype does) — zero licensing or
   trademark risk, full control, matches the app's existing "draw gear from a category spec"
   paradigm.
4. **Assets, realism upgrade: a curated set of ~6–10 *generic archetype* models** ("British
   stack", "American combo", "boutique 1x12", …), authored by **AI image-to-3D (Meshy or
   Tripo) from reference photos of generic amps, then cleaned/retopo'd**, with a **freelance
   3D artist** for the hero/"signature" models. **Fallback:** royalty-free marketplace
   models (TurboSquid/CGTrader) converted to USDZ. All *generic*, never brand replicas.
5. **Budget:** ≤ 40–60k triangles and one 2K PBR texture set per amp on screen; ≤ 4–6 MB per
   USDZ; keep to **one live hero model at a time**, pre-render everything else to 2D
   thumbnails.
6. **Legal:** ship "recognizable but not counterfeit" generic archetypes; **never** bake in
   real logos, control-panel scripts, or distinctive grille-cloth trade dress. Pursue
   licensing only if/when specific branded models become a priority.

---

## 1. Real-time 3D rendering technology

The project today links **no** 3D framework. The "AR" pedal page (`ARPedalSetupView` +
`CameraStompDetector`) is **AVFoundation + Vision** (camera body-pose detection) — *not*
ARKit or RealityKit. So there is **no existing RealityKit dependency to lean on**; every
option below is a fresh link. Deployment target is **iOS 26.2**, Xcode 26.3, Swift 5 mode.

### The WWDC 2025 context that frames this decision

At WWDC 2025 (session 288, *"Bring your SceneKit project to RealityKit"*), Apple announced
**SceneKit is soft-deprecated**: it stays in the OS and receives **critical-bug fixes only**,
with no new features, and developers are steered to RealityKit for anything new. Importantly,
there is **no *hard* deprecation** — the API symbols are **not** annotated
`@available(..., deprecated:)`, so **using SceneKit against the iOS 26 SDK does not emit
compiler deprecation warnings.** (Confirmed empirically: the prototype's SceneKit code builds
clean against the 26.2 SDK — zero warnings.) The SwiftUI `SceneView` wrapper is the weak link
(it never conformed to `SCNSceneRenderer`, so it lacks the render loop and hit-testing) — the
right SceneKit entry point is a `UIViewRepresentable` around **`SCNView`**, which is what we
use.

### Head-to-head

| Criterion | **SceneKit** (`SCNView`) | **RealityKit** (`RealityView`) | **Metal** (custom) | **QuickLook** (`ARQuickLook`) |
|---|---|---|---|---|
| SwiftUI integration | `UIViewRepresentable` around `SCNView` (small, proven) | `RealityView` is native SwiftUI (iOS 18+); `Model3D` for trivial cases | `MTKView` via representable — you own everything | `.quickLookPreview` / `QLPreviewController` |
| Effort to first orbit-able PBR amp | **Lowest** — `allowsCameraControl` gives orbit+pinch **for free**; primitives + PBR in a few lines | Medium — camera/orbit gestures are **manual** on iOS; IBL needs an `EnvironmentResource` | **Highest** — write the whole pipeline, lighting, PBR, camera | Near-zero code, but **you don't control the UX at all** |
| Realism ceiling | High (PBR, IBL, HDR, emissive, shadows) | **Highest on Apple's roadmap** (PBR, IBL, post-processing, ECS, gets the new features) | Unbounded (bespoke shaders) | High but **canned** full-screen viewer |
| Performance | Very good for a single hero model | Very good; built for modern GPUs & spatial | Best possible, if you invest | Good; system-tuned |
| Asset workflow | USDZ/USD/DAE/OBJ/etc. import; Model I/O | **USDZ-native** (USD is the first-class format) | Bring your own loader | **USDZ only**, system-driven |
| Animation (emissive tubes, turning knobs) | `SCNAction`/`CAAnimation`, per-node euler; trivial to bind a knob to data | ECS components/systems; entity transforms; also easy | Manual | **None** — static preview only |
| Fit with this codebase | **Excellent** — one small representable, isolated | Good, but a heavier paradigm shift (ECS) | Poor for a lightweight app | Poor for an *inline hero*; fine as a "view in your room" extra |
| Longevity | **Soft-deprecated** (maintenance-only) | **Apple's go-forward** 3D framework | Evergreen but costly | Evergreen |
| Warnings on iOS 26 SDK | **None** (not hard-deprecated) — verified | None | None | None |

### Recommendation

- **Primary for the prototype / near-term hero: SceneKit `SCNView`.** The effort-to-realism
  ratio is unbeatable for an inline, interactive hero view: free camera controls, primitives
  for the procedural stand-in, one-line PBR materials, `lightingEnvironment` IBL, and
  data-bound `eulerAngles` for the knobs. Soft-deprecation is a real but *manageable* risk
  because (a) it compiles warning-free today and (b) our renderer is isolated behind
  `AmpModel3DView`.
- **Strategic migration target: RealityKit `RealityView`.** When we move to a real USDZ
  catalog (Phase 3), re-implement `AmpModel3DView`'s body on RealityKit. USDZ authored for
  RealityKit also loads in SceneKit, so **assets are not wasted** by starting on SceneKit.
- **QuickLook**: keep as a *complementary* "View in AR / view life-size in your room" action
  on the detail screen — it's free and delightful — but it is **not** the inline hero
  renderer (no custom UX, no live knobs).
- **Metal**: not justified for a lightweight SwiftUI app; revisit only if we ever need bespoke
  shading (e.g., animated tube filaments, custom grille moiré) beyond PBR.

---

## 2. Asset format & pipeline

- **Format: USDZ** — the only sane choice on Apple platforms. It's a zipped USD payload that
  RealityKit consumes natively, SceneKit imports, and QuickLook previews. Author in USD/USDC;
  ship USDZ.
- **Authoring / conversion:**
  - **Reality Composer Pro** (bundled with Xcode) — assemble scenes, assign PBR materials,
    author variants, and export USDZ. The place to wire "knob" node names and material slots.
  - **Reality Converter** / **`usdzconvert`** — turn OBJ/FBX/glTF/GLB (what marketplaces and
    AI tools emit) into USDZ.
  - **Model I/O** (`MDLAsset`) — programmatic import/inspect/convert; also how you'd bake or
    fix up materials in a build step.
- **Texture compression: ASTC.** iOS GPUs decode ASTC natively; USDZ texture payloads should
  be ASTC-compressed (Reality Converter can do this on export). Keep a **single 2K PBR set**
  (base color, normal, roughness, metallic, optional AO/emissive) per amp. **4K "chokes"
  QuickLook and wastes memory** — 2K is the ceiling.
- **LODs & decimation:** author a high-poly source, then decimate to a **real-time LOD**
  (target below). For the list/thumbnail surface we don't ship a lower LOD — we ship a
  **pre-rendered PNG** (see §6), which is cheaper than any 3D LOD.
- **Bundling & lazy-loading:**
  - Ship the small curated set **in-app** (asset catalog or a `Models/` bundle folder). At
    ~4–6 MB each, ~8 archetypes ≈ 30–50 MB — acceptable in-bundle, or better via **On-Demand
    Resources / a lightweight download** so first install stays lean.
  - Load the hero USDZ **lazily and one at a time** (only the focused amp), release when it
    scrolls off. `AmpScene.load(usdzNamed:)` is the seam; a small `LRU`/single-slot cache is
    the natural next step.

---

## 3. Realistic-asset sourcing

| Route | Quality ceiling | Cost | Effort / time | Topology & UVs | Licensing / legal | USDZ readiness |
|---|---|---|---|---|---|---|
| **Buy (TurboSquid / CGTrader / Sketchfab)** | High | $10–150/model | Low to find, med to fix | Variable (often game-ready) | Royalty-free **but** many are **branded replicas** → trademark risk; check per-asset license | Usually OBJ/FBX/MAX → **convert** |
| **Commission a freelance 3D artist** | **Highest / on-brief** | $300–1,500+/model | High (days–weeks) | **Clean, controlled** | You spec "generic, no logos" → **lowest legal risk**, you own it | Delivered as USDZ on request |
| **Photogrammetry (Apple Object Capture)** | High realism, messy topology | Free (your own amps) | **High** (capture rig + cleanup + retopo) | **Poor raw** (dense, needs retopo/UV) | Fine for amps **you own**, but the scan *captures the real logos/trade dress* → must be scrubbed | RealityKit outputs USDZ directly |
| **AI image-to-3D / text-to-3D** (Meshy, Tripo, Rodin, Hunyuan3D) | Good & rising fast | $0–60/mo subs | **Low–med** (minutes + cleanup) | **Improving but variable** (often needs retopo/UV pass) | **Output licensing varies per tool/plan — read terms**; feed *generic* references to stay clean | Most export OBJ/GLB/**USDZ**; Meshy/Tripo export broadly |
| **Procedural / parametric in code** | Stylized, not photoreal | Free | Med (one-time build) | **Perfect & tiny** | **Zero** IP risk, fully owned | Native (build the scene directly) |

**Landscape notes (2025–26):** **Tripo** is widely rated best overall image-to-3D (fast,
20–30 s) and **Meshy** the best mainstream self-serve (mature workflow, PBR texturing,
topology controls, broad exports including USDZ, 40–60 s). **Rodin** targets max fidelity
(60–180 s); **Hunyuan3D** is the leading open model. For *simple, hard-surface* objects like
amps, ~70–80% of first generations are usable with minor cleanup. **Object Capture**
(`PhotogrammetrySession`, RealityKit) wants 100+ overlapping photos and **struggles with the
shiny metal / dark tolex / cloth** typical of amps — usable but the most labor-intensive path.

### Recommendation

- **Primary (ship): procedural** for the first production wave (already the app's paradigm;
  zero risk).
- **Realism upgrade (curated): AI-generated generic archetypes** (Meshy/Tripo from
  *generic* reference imagery) **+ a freelance artist** for a few hero/"signature" models.
  Author/clean in Reality Composer Pro, decimate to budget, export USDZ.
- **Fallback: marketplace** royalty-free *generic* amps converted to USDZ — fastest to a
  library, but vet each license and strip any brand marks.
- **Photogrammetry: opportunistic only** — good for a one-off "scan your own amp" feature
  later, not the catalog pipeline.

---

## 4. On-device realism budget

Anchored to Apple's AR Quick Look / RealityKit guidance and current iPhone GPUs:

| Budget item | Per amp (recommended) | Hard ceiling |
|---|---|---|
| Triangles (real-time LOD on screen) | **40–60k** | ~150k practical; runtimes throttle **>200k** |
| Texture set | **one 2K PBR set** (base/normal/rough/metal, +AO/emissive optional), ASTC | 2K (**4K chokes QuickLook**) |
| Draw calls | **< 12** (merge materials) | < 20 |
| USDZ file size | **4–6 MB** | 8–10 MB before load times suffer |
| Live models on screen | **1 hero at a time** | list/other surfaces use pre-rendered PNGs |
| Total shipped 3D (curated set) | ~8 archetypes × ~5 MB ≈ **30–50 MB** | consider On-Demand Resources beyond this |

At those numbers a modern iPhone holds **60 fps** comfortably for a single hero amp with PBR +
IBL + a soft shadow. The discipline that keeps it there: **one live model**, everything else
2D (§6).

---

## 5. Legal / trademark posture (a real consideration — not legal advice)

Real amp **exteriors, logos, control-panel scripts, and grille-cloth patterns** can be
protected **trademark / trade dress**. A photoreal, named replica (e.g., a specific British
head or American combo, logo and all) is the highest-risk artifact this feature could produce.

- **Recommended stance: "recognizable but not counterfeit."** Model *generic archetypes* that
  read as "a British-voiced stack" or "a blackface American combo" via **silhouette,
  proportion, and material** — **without** the logo, the exact faceplate script, or a
  trademarked grille-cloth weave. This is exactly what the procedural stand-in does.
- **Never bake real logos or trademarked scripts into shipped models.** The prototype's
  procedural amp is deliberately unbranded (blank cream faceplate, generic gold trim, plain
  baffle).
- Note that `RigStore.catalog` already uses **real brand names** as *data* (was already
  flagged as an open question by the team). Names-as-text is a lower-risk surface than a 3D
  *replica of the product's dress*; keep the two decisions separate, and if the catalog moves
  to generic names, the 3D archetypes are already aligned.
- **Licensing path** (optional, later): if specific branded models become a priority, pursue
  a brand/licensing agreement or an official partnership before shipping a faithful replica.

---

## 6. Integration strategy across the three surfaces

The vector system (`GearArtView`) must remain intact — it powers **collection cards, the rig
stage, the zoom overlay, and the AR slots**, across **every** gear category. 3D is additive.

| Surface | Approach | Why |
|---|---|---|
| **Collection cards** (`GearCardView`, tiny thumbnails, many on screen) | **Pre-rendered PNG** snapshot of the same 3D model (or keep vector art) | Never run N live `SCNView`s in a scroll list — kills perf/battery. A `SCNView.snapshot()` (or offline render) baked to an image keeps the list cheap while looking consistent with the hero. |
| **Rig stage hero** (`RigStageView`, one focal amp) | **Live 3D** (`AmpModel3DView`) behind `FeatureFlags.amp3D`, amp slot only | The one place a live, rotatable model earns its cost. Everything else on the stage (pedals, cab-in-combo, guitar) stays vector. |
| **Zoom / detail** (`ComponentDetailView`) | Keep the vector control panel for knob-turning **for now**; optionally add a live 3D header + a QuickLook "view in your room" action later | The zoom view's job is *precise knob editing*; the 2D `InteractiveKnob` panel is better for that. 3D there is a Phase-3 polish, not a requirement. |

**Thumbnail pipeline (recommended):** a build-time or first-launch step renders each 3D amp
once via `SCNView.snapshot()` into a cached PNG keyed by `modelName`; cards read the cache.
This is the "pre-render thumbnails from the same models so the list stays cheap while the hero
is live" strategy called for in the brief.

**Prototype's interaction wiring (already handled):** `allowsCameraControl` gives drag-orbit +
pinch-zoom on the hero; a single-tap recognizer (coexisting with the camera controller) fires
`onTap` to open the existing zoom overlay, preserving tap-to-focus. Drag-to-swap
(`.dropDestination`) still works because it lives on the whole stage, and `store.apply` routes
a dropped cabinet to the cab slot regardless of drop location.

---

## 7. Phased rollout

| Phase | Goal | Rendering | Assets | Data-model | Exit criteria |
|---|---|---|---|---|---|
| **0 — Spike (this PR)** | Prove the pipeline on the hero amp | SceneKit `SCNView` | Procedural stand-in | `has3DModel?`, `modelName?` added (optional, back-compat); `uses3DModel` computed | Rotatable PBR amp on the stage; ≥1 knob live from `values`; flag toggles it off; vector art + saved JSON intact |
| **1 — One real production amp** | Ship a single, polished, *generic* archetype | SceneKit `SCNView` | One AI-generated + cleaned **or** commissioned generic USDZ; bundle it; set `modelName` on that item | none new (seam already exists) | Real USDZ renders via `AmpScene.load(usdzNamed:)`; hits budget (§4); knob nodes named `knob_<Param>` stay live |
| **2 — Curated archetype set** | ~6–10 archetypes covering the catalog's amp voices | SceneKit `SCNView` + **pre-rendered card thumbnails** | AI + freelance for heroes; per-item `modelName` | map catalog amps → archetype `modelName`; thumbnail cache | Cards show baked thumbnails; hero swaps per selected amp; total 3D ≤ budget |
| **3 — RealityKit migration + full polish** | Future-proof renderer; optional 3D in zoom + QuickLook AR | **RealityKit `RealityView`** (re-implement `AmpModel3DView` body) | Same USDZ assets (load in RealityKit unchanged) | none | Feature parity on RealityKit; SceneKit retired from the app |

### Data-model changes (backward-compatible)

Added to `GearItem` (all optional so existing `rig_state.json` still decodes):

```swift
var has3DModel: Bool?   // nil = use category default (amps → 3D); overrides per item
var modelName: String?  // bundled ".usdz" name (no extension); nil = procedural stand-in
var uses3DModel: Bool { has3DModel ?? (category == .amp) }  // computed, not stored
```

Because they're optional, **already-saved rigs decode with these as `nil`** and behave
exactly as before (amps get the procedural 3D, everything else stays vector). No migration.

---

## What the prototype in this PR actually does

- **`StreetRig/FeatureFlags.swift`** — single toggle `FeatureFlags.amp3D` (default `true`);
  set to `false` to instantly restore the original vector amp everywhere.
- **`StreetRig/Views/AmpModel3DView.swift`** — a `UIViewRepresentable` over `SCNView` plus a
  procedural amp builder (`AmpScene` + `ProceduralAmp`): generic head + gold-framed 4x12 cab,
  cream faceplate, a row of PBR knobs, an emissive amber "tube glow" lamp, image-based
  lighting from a generated gradient, a fake contact shadow, drag-orbit + pinch-zoom, and a
  gentle idle spin. **All six amp knobs turn live from `GearItem.values`** (0–10 →
  −135°…+135°, matching the 2D `InteractiveKnob`).
- **`AmpScene.load(usdzNamed:)`** — the documented **swap seam**: bundle `Foo.usdz`, set the
  amp's `modelName = "Foo"`, name its knob nodes `knob_Gain` … `knob_Master`, and the
  procedural build is bypassed with the data binding preserved.
- **`StreetRig/Views/RigStageView.swift`** — renders `AmpModel3DView` at the amp slot **only**
  when `FeatureFlags.amp3D && !isCombo && ampItem.uses3DModel`; otherwise the original vector
  head+cab. Everything else (pedals, guitar, combo, cards, zoom, AR) is untouched.
- **`StreetRig/Models/Gear.swift`** — the optional `has3DModel` / `modelName` fields above.

No external assets are downloaded; the prototype is fully self-contained and unbranded.

---

## Sources

- [Bring your SceneKit project to RealityKit — WWDC25 (session 288)](https://developer.apple.com/videos/play/wwdc2025/288/)
- [WWDC 2025 — SceneKit Deprecation and RealityKit Migration (DEV Community)](https://dev.to/arshtechpro/wwdc-2025-scenekit-deprecation-and-realitykit-migration-a-comprehensive-guide-for-ios-developers-o26)
- [Apple Developer Forums — Alternatives to SceneView](https://developer.apple.com/forums/thread/788524)
- [Apple Developer Forums — Is migrating from ARView to RealityView recommended?](https://developer.apple.com/forums/thread/788284)
- [Introduction to RealityView (Create with Swift)](https://www.createwithswift.com/introduction-to-realityview/)
- [Take SwiftUI to the next dimension — WWDC23 (RealityView / Model3D)](https://developer.apple.com/videos/play/wwdc2023/10113/)
- [AR Quick Look & USDZ — model size / poly / texture guidance (Netguru)](https://www.netguru.com/blog/ar-quick-look-and-usdz)
- [How to Optimize 3D Models for iPhone, iPad, and Mac (uMake)](https://www.umake.com/blog/how-to-optimize-3d-models-for-iphone-ipad-and-mac)
- [Apple Developer Forums — Triangle count & texture size budget for RealityKit](https://developer.apple.com/forums/thread/751764)
- [Apple — Object Capture / PhotogrammetrySession](https://developer.apple.com/documentation/realitykit/photogrammetrysession)
- [Create 3D models with Object Capture — WWDC21](https://developer.apple.com/videos/play/wwdc2021/10076/)
- [Best AI 3D Model Generators 2026 — Tripo vs Meshy vs Rodin vs Kaedim (Ideas With Wings)](https://medium.com/ideas-with-wings/best-image-to-3d-tools-7eea7b05eb11)
- [Best AI 3D Model Generators 2026 — TRELLIS vs Meshy vs Tripo vs Hitem3D (trellis2)](https://trellis2.app/blog/best-ai-3d-model-generator)
- [TurboSquid — Amplifier 3D models (royalty-free licensing)](https://www.turbosquid.com/Search/3D-Models/amplifier)
- [CGTrader — Amplifier 3D models](https://www.cgtrader.com/3d-models/amplifier)
