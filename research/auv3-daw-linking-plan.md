# Linking StreetRig into On-Device DAWs — AUv3 Extension Build Plan

**Status:** decision-ready · **Date:** 2026-08-11 · **Scope:** ship StreetRig's fully
processed guitar signal (iRig → pedals → neural amp → cab IR) as a **real-time Audio Unit v3
audio-effect app extension** (`aufx`) that GarageBand / Logic for iPad / AUM / Cubasis /
apeMatrix load as an insert plugin on a track — on the **same iOS device**. The user drops
"StreetRig" onto a guitar track, hears the amp sim live, automates its knobs from the host,
and saves/recalls the rig with the project.

---

## TL;DR — the recommended path

1. **Build an AUv3 audio-effect app extension (`aufx`).** It is the *only* option that is
   real-time, same-device, and natively hosted by every target DAW — and StreetRig's DSP
   insertion point, `StreetRigDSPUnit`, is **already an `AUAudioUnit` (v3)**. We are packaging
   an engine, not writing one.
2. **The engine is ~80 % there; the gap is packaging, not DSP.** What is missing is a
   `.appex` target, its `NSExtension`/`AudioComponents` `Info.plist`, `fullState` /
   `fullStateForDocument` state, an `AUViewController` UI, factory/user presets, and a
   `channelCapabilities` / `latency` declaration. None require touching `SRKernelProcess`.
3. **Refactor first: extract the engine into a shared framework** (an "Audio Unit host
   framework") linked by **both** the standalone app and the new extension, so the C++ kernel
   is compiled once. This is the single biggest piece of work, because the app currently uses
   a **bridging header** (extension-incompatible) and a **file-system-synchronized folder**
   that maps every source file into the one app target.
4. **Resolve the dynamic-rig ⇄ fixed-tree tension by exposing a fixed *superset* parameter
   tree** built from the existing `SRParameterAddress` enum and the structured pedal-address
   scheme (both already on the lock-free kernel bus), and moving **gear *identity* / topology
   into serialized state** (`fullState`), not into automatable params. The kernel already has
   a fixed 8-slot pedal pool — the parameter surface mirrors that pool.
5. **Reuse, don't reinvent:** `SRParameterAddress` (host automation addresses),
   `RigConfiguration` + `GearItem` Codable (preset state), and the offline-render harness in
   `AudioEngineController+OfflineRender.swift` (the A/B null-test oracle) are the load-bearing
   pieces — the plan builds on all three.
6. **Keep both modes working.** Standalone stays exactly as-is (its own `AVAudioEngine` +
   iRig, `.playAndRecord`); the plugin is host-driven render. The render block already pulls
   input through the host-supplied `pullInputBlock`, so the *same kernel* serves both — only
   the hosting layer differs.
7. **"Link to your laptop" = the macOS/Catalyst build of the same plugin** in Logic Pro /
   GarageBand for Mac. It is out of the same-device iOS scope but is the natural Phase-6
   horizon and is also how you run `auval`.

---

## 1. Executive summary & recommendation

**Build an AUv3 audio-effect app extension.** StreetRig's real-time core is already wrapped
in a v3 Audio Unit: `nonisolated final class StreetRigDSPUnit: AUAudioUnit`
(`StreetRig/Audio/StreetRigDSPUnit.swift`) implements `internalRenderBlock`, input/output
`AUAudioUnitBusArray`s, `allocateRenderResources` / `deallocateRenderResources`, a fixed
`AUParameterTree`, `canProcessInPlace`, and an in-process `AUAudioUnit.registerSubclass`
registration under the component description `aufx` / `srds` / `Strg`. An AUv3 *effect*
extension is exactly this class, packaged as a `.appex` the OS can discover and a host in a
**different process** can load as a track insert. No competing mechanism (Inter-App Audio,
Audiobus, network audio, stem export) is simultaneously real-time, same-device, and supported
by GarageBand — and each is either deprecated, additive-only, or off-device. The work is
**target topology and packaging**, not DSP: extract the engine into a shared framework built
once and linked by both the app and a new extension target, stand up the `.appex` with its
`AudioComponents` `Info.plist`, expose a stable superset parameter tree, serialize the rig
into `fullState`, and host the existing SwiftUI knobs in an `AUViewController`. Every
recommendation below honors `StreetRig/Audio/RealtimeSafety.md`: nothing new runs on the audio
thread, because the render path (`internalRenderBlock` → `SRKernelProcess`) does not change.

---

## 2. Option comparison

| Option | Real-time? | Same device? | GarageBand / Logic / AUM support | Effort | Verdict |
|---|---|---|---|---|---|
| **AUv3 audio-effect extension (`aufx`)** | **Yes** — host's render thread calls `internalRenderBlock` | **Yes** | **Native** — the plugin model all three use | **Medium** — packaging + refactor, DSP already done | ✅ **Recommended.** The only path that is real-time *and* same-device *and* first-class in every target host; the engine is already an `AUAudioUnit`. |
| **Inter-App Audio (IAA)** | Yes | Yes | Being removed | Medium | ❌ **Rejected.** Apple-**deprecated** since iOS 13; GarageBand/Logic/AUM have moved to AUv3. Dead on arrival — see §2.1. |
| **Audiobus SDK** | Yes | Yes | Via Audiobus app (complements AUv3) | Low–Med (3rd-party SDK + license) | 🟡 **Optional later.** Real-time inter-app routing, but it *routes* AUv3/apps rather than replacing the plugin; adds an SDK + licensing dependency. Ship AUv3 first; Audiobus compatibility largely comes for free once you are an AU. |
| **Network / virtual audio to a laptop** | Yes (with latency) | **No** (off-device) | N/A (not a plugin) | High | 🟡 **Out of scope / niche.** Answers the literal "your laptop" wording, but iOS cannot easily present as a USB audio-class device; needs AVB/NDI/RTP or a helper app. Note it for completeness; the real desktop answer is the Catalyst build (§5.I). |
| **File / stem export** | **No** (offline) | Yes | Any DAW (import a WAV) | **Low** — foothold exists | 🟢 **Fast MVP adjunct.** `AudioEngineController+OfflineRender.swift` already renders the real graph to a WAV. Not live, but a same-week "print your rig to a stem" feature that pairs with AUv3. |

### 2.1 Why Inter-App Audio is rejected

IAA (the `AudioComponent` `aurg`/`auri` "remote" node model plus the `inter-app-audio`
entitlement) is **formally deprecated by Apple** and is being phased out of the host
ecosystem: GarageBand, Logic, AUM, Cubasis and apeMatrix all host **AUv3** and are dropping or
have dropped IAA node support. Adopting it would mean shipping on a sunset API that hosts are
actively removing, with none of the AUv3 benefits (in-project state, host automation of an
`AUParameterTree`, sandboxed discovery). The constraint in the brief is correct: do **not**
propose IAA. We also explicitly **avoid the `inter-app-audio` entitlement** (§5.H).

---

## 3. Baseline: what already exists vs. the gap

### 3.1 Already built (cited to real symbols)

`StreetRigDSPUnit` is a functioning v3 Audio Unit today. Concretely:

| AUv3 requirement | Where it already lives |
|---|---|
| `AUAudioUnit` subclass | `nonisolated final class StreetRigDSPUnit: AUAudioUnit` (`StreetRigDSPUnit.swift`) |
| Component identity | `static let componentDescription = AudioComponentDescription(type: kAudioUnitType_Effect, subType: fourCharCode("srds"), manufacturer: fourCharCode("Strg"), …)` |
| Real-time render | `override var internalRenderBlock: AUInternalRenderBlock` → `SRKernelProcess(kernel, inputABL, outputData, frames)` |
| Input/output buses | `inputBusArray` / `outputBusArray` as `AUAudioUnitBusArray`; `override var inputBusses` / `outputBusses` |
| Resource lifecycle | `override func allocateRenderResources()` / `deallocateRenderResources()`, sized to `maximumFramesToRender` |
| In-place processing | `override var canProcessInPlace: Bool { true }` (with a null-output fallback in the render block) |
| Parameter tree | `_parameterTree = AUParameterTree.createTree(withChildren: […8 params…])`, `override var parameterTree` |
| Host-automatable addresses | Params keyed by `AUParameterAddress(SRParam….rawValue)` from the append-only `SRParameterAddress` enum (`StreetRigDSPKernel.h`) |
| Lock-free automation bus | `implementorValueObserver` → `SRKernelSetParameter(kernel, address, value)` (a `std::atomic<float>` store, ramped on the audio thread — see `RealtimeSafety.md`); `implementorValueProvider` → `SRKernelGetParameter` |
| Value formatting | `implementorStringFromValueCallback` |
| In-process registration | `AUAudioUnit.registerSubclass(…)` via `registerIfNeeded()`, instantiated by `AVAudioUnit.instantiate(with: componentDescription…)` in `AudioEngineController.instantiateDSPUnit()` |
| Latency/CPU read-out | `SRKernelStoreRenderMetrics` + `lastRenderLoad` / `lastBlockSeconds` (the render budget meter) |
| A correctness oracle | `AudioEngineController+OfflineRender.swift` renders the real AU graph in manual `.offline` mode and runs a null test (`analyze(...)`, `nullRMS < 1e-3`) |

Just as important, the render block is **already host-agnostic**: it pulls upstream audio
through the passed-in `pullInputBlock` (not a hard-wired `AVAudioEngine` input node) and
handles null host output buffers by aliasing input storage in place. That is precisely the
contract a DAW insert uses.

### 3.2 The gap (what "packaged, host-loadable extension" needs)

| Missing piece | Why a host needs it | Note |
|---|---|---|
| **A `.appex` extension target** | The OS discovers out-of-process AUs from installed app-extension bundles, not from `registerSubclass` (which is in-process only) | New target; §4 |
| **`NSExtension` → `AudioComponents` `Info.plist`** | The discovery record: `type aufx`, `subtype`, `manufacturer`, `name`, `tags`, `version`, `sandboxSafe`, `factoryFunction` | Cannot be fully expressed via `GENERATE_INFOPLIST_FILE`; needs a real plist (§5.B) |
| **`fullState` / `fullStateForDocument`** | Host saves/recalls plugin state with the project; the dynamic rig must ride along | Not overridden today; §5.D |
| **`requestViewController` / `AUViewController`** | The host embeds the plugin's editor UI | Not present today; §5.E |
| **Factory + user presets** | `factoryPresets`, `supportsUserPresets`, preset save/restore | Not present today; §5.D |
| **`channelCapabilities` + `latency`** | The host queries supported I/O channel configs and does plugin-delay-compensation for the cab convolver | Not overridden today; §5.G |
| **App Group + resource copy** | `Bundle.main` inside a `.appex` is the *extension* bundle; tone assets and shared rigs must reach it | §5.D / §5.H |

**Grounding correction to the brief:** the AUParameterTree today exposes **8** params
(`inputGain, outputLevel, ampDrive, ampMakeup, ampBypass, cabBypass, useNeural, cabSelect`).
The `SRParameterAddress` enum *also* defines the amp tone stack (`SRParamAmpBass=8`,
`SRParamAmpMid=9`, `SRParamAmpTreble=10`, `SRParamAmpPresence=11`) and a structured pedal
range (`SRPedalParamBase=100 + slot*SRPedalParamStride(8) + field`), and `RigGraphCompiler`
drives all of them via `dsp.setParameter(...)` / `dsp.setPedalParam(...)`. So the amp EQ and
every pedal knob are **already on the kernel bus but are *not* in the AUParameterTree** — a
host cannot automate them today. Expanding the tree to include them (§5.C) is therefore
low-risk: the addresses, the atomics, and the ramping already exist. Also note the engine
builds at **`gnu++20`** (`CLANG_CXX_LANGUAGE_STANDARD` in `project.pbxproj`), not C++17 as some
header comments say — the shared framework must set the same standard.

---

## 4. Architecture & target-topology plan

### 4.1 The current layout (from `project.pbxproj`)

- **One** `PBXNativeTarget`: `StreetRig` (`com.apple.product-type.application`), bundle id
  `streetrig.StreetRig`, team `HHM5CMKKMJ`, deployment target **iOS 26.2**, `TARGETED_DEVICE_FAMILY = 1,2`.
- Sources are attached via a **`PBXFileSystemSynchronizedRootGroup`** (`path = StreetRig`) —
  Xcode 16+ "synchronized folders": every file under `StreetRig/` is compiled into the app
  target automatically. There is no per-file target membership to hand-edit.
- **No** Swift packages (`packageProductDependencies = ()`), **empty** Frameworks build phase,
  `OTHER_LDFLAGS = -framework Accelerate` (the `CabinetConvolver` uses vDSP).
- **`SWIFT_OBJC_BRIDGING_HEADER = StreetRig/StreetRig-Bridging-Header.h`** imports
  `Audio/StreetRigDSPKernel.h` — this is how Swift sees the C ABI today.
- `GENERATE_INFOPLIST_FILE = YES` (Info.plist synthesized from `INFOPLIST_KEY_*`); no
  `.entitlements`, no App Group.

Two of these are hard constraints for extensions: **(a)** an app-extension *and* a
framework cannot use a Swift **bridging header** — the C ABI must be exposed as a **Clang
module** (module map / umbrella header) instead; **(b)** the synchronized root group maps
files into the *app* target, so the engine files must be relocated into a folder owned by the
new framework target.

### 4.2 Target map after the refactor

```
StreetRig.xcodeproj
│
├── StreetRigEngine.framework   ← NEW shared framework (built ONCE)
│     • C++/Obj-C++ DSP core: StreetRigDSPKernel.{h,cpp}, StreetRigDSPKernelInternal.hpp,
│         AmpCabProcessor, AnalogAmp, Convolution/CabinetConvolver, Neural/* (.mm bridge),
│         Pedals/*                                         [links Accelerate here]
│     • Swift AU host: StreetRigDSPUnit.swift
│     • Rig model + compiler: Models/Gear.swift, Models/RigStore.swift,
│         RigGraphCompiler.swift, ParameterMap.swift
│     • Resources: StreetRig_amp_placeholder.json, cab_*.wav, StreetRig_DI_placeholder.wav
│     • module.modulemap  ← replaces the bridging header; exposes StreetRigDSPKernel.h
│           to Swift as `import StreetRigEngineC` (or an umbrella header)
│
├── StreetRig.app             ← existing app; UI stays, links StreetRigEngine.framework
│     • StreetRigApp, ContentView, Views/*, RigTheme, FeatureFlags, ModelExporter
│     • AudioEngineController(+OfflineRender)  ← standalone hosting stays here (or in the
│           framework as host-side utilities); iRig / AVAudioSession stay app-side
│
└── StreetRig AUv3.appex      ← NEW audio-effect extension; links StreetRigEngine.framework
      • Info.plist  → NSExtension.NSExtensionAttributes.AudioComponents = [{ aufx / srds /
            Strg / sandboxSafe / factoryFunction }]
      • StreetRigAUFactory: AUViewController & AUAudioUnitFactory
            → createAudioUnit(with:) returns StreetRigDSPUnit(componentDescription:…)
            → requestViewController(...) returns the SwiftUI editor (UIHostingController)
      • Copies the tone-asset Resources so Bundle(for:) inside the appex can load them
```

**What moves into the framework:** the entire `StreetRig/Audio/*` C++/Obj-C++/Swift engine
(kernel, amp/cab, convolver, neural bridge, pedals), plus the rig data model and mapping that
the plugin needs to be self-contained: `Models/Gear.swift`, `Models/RigStore.swift`,
`RigGraphCompiler.swift`, `ParameterMap.swift`, and the audio `Resources/`.

**What stays in the app:** all SwiftUI views, theming, feature flags, the 3D stage, the model
exporter, and the standalone hosting layer (`AudioEngineController`) that owns
`AVAudioSession` `.playAndRecord`, the iRig route, and live monitoring. `AudioEngineController`
depends on the framework, not vice-versa.

**Shared UI without duplication:** the knob/rig SwiftUI components the plugin editor reuses
(e.g. `ControlBoardView`, `InteractiveKnob`, the rig-strip views) should move into the
framework too, or into a small second framework (`StreetRigUI`) both app and appex link, so
the editor is not copy-pasted. Keep the *3D stage* and camera/AR views app-only — the plugin
editor is a compact 2D control surface.

**Registration:** keep `StreetRigDSPUnit.registerIfNeeded()` for the app's **in-process**
instantiation (fast, no sandbox hop, unchanged standalone behavior). The **host** discovers
the *extension* through its `Info.plist`; the extension's factory returns the same class. Both
can coexist; the app should continue to instantiate in-process so it never accidentally loads
its own `.appex` out-of-process (§8).

---

## 5. Design resolutions (A–I)

### A. Target topology / code sharing — *extract a shared framework*

**Recommendation.** Create **`StreetRigEngine.framework`** and link it from both the app and
the new appex. Move the engine + rig model + audio resources into it (§4.2). Replace the
**bridging header** with a **Clang module map** (or umbrella header) so Swift in the framework
imports the C ABI as a module; drop `SWIFT_OBJC_BRIDGING_HEADER` for framework sources. Set the
framework's `CLANG_CXX_LANGUAGE_STANDARD = gnu++20` and add `-framework Accelerate` to its link
step. Because the project uses a synchronized root group, the cleanest mechanic is to give the
framework its **own** synchronized folder (e.g. move files under `StreetRigEngine/`) so target
membership follows the folder.

**Trade-off.** A framework (vs. a local Swift package) is the lower-friction choice *here*
because the code mixes C++, Obj-C++ (`NeuralAmpBridge.mm`), a `.modulemap`, an asset bundle,
and `@MainActor` Swift — all first-class in an Xcode framework target and awkward in a
`Package.swift` (SwiftPM's C++/Obj-C++ interop + resource + bridging story is fiddlier). The
cost is a one-time, error-prone Xcode surgery (module map, moving files out of the app's synced
group, re-resolving `#include "Audio/…"` paths now that `HEADER_SEARCH_PATHS` changes). The
exit test is cheap and already written: the app builds and the **offline render still passes**.

### B. Extension packaging & registration — *`aufx` with the codes already in the source*

**Recommendation.** Add an **Audio Unit Extension** target. Its `Info.plist` carries:

```
NSExtension
  NSExtensionPointIdentifier = com.apple.AudioUnit-UI     (UI-bearing effect)
  NSExtensionPrincipalClass  = StreetRigAUFactory          (AUViewController + AUAudioUnitFactory)
  NSExtensionAttributes
    AudioComponents = [{
      type            = "aufx"          # kAudioUnitType_Effect
      subtype         = "srds"          # already in StreetRigDSPUnit.componentDescription
      manufacturer    = "Strg"          # already chosen; has an uppercase → not Apple-reserved
      name            = "StreetRig: StreetRig"   # "Manufacturer: Name" convention
      version         = 65536           # (1<<16)|(0<<8)|0  == 1.0.0; keep in sync w/ MARKETING_VERSION
      sandboxSafe     = true
      tags            = ["Effects", "Distortion", "Guitar"]
      factoryFunction = "StreetRigAUFactory"      # class conforming to AUAudioUnitFactory
    }]
```

Reuse the **exact codes already in `componentDescription`**: `aufx` / `srds` / `Strg`. The
factory's `createAudioUnit(with:)` returns `try StreetRigDSPUnit(componentDescription: desc)`.
Hosts discover it via `AVAudioUnitComponentManager.shared().components(matching:)` (and the
app can show "installed?" state with the same call). The appex bundle id must be the app id
plus a suffix, e.g. `streetrig.StreetRig.AUv3`.

**Trade-off.** The `AudioComponents` array **cannot** be produced by
`GENERATE_INFOPLIST_FILE` alone, so the extension needs a checked-in `Info.plist` (a small
divergence from the app's generated-plist convention — acceptable and unavoidable). Manufacturer
`Strg` is fine (Apple reserves *all-lowercase* four-char manufacturer codes; `Strg` has an
uppercase), but the code is only guaranteed unique on the user's device by convention — see the
registration note in §8.

### C. Parameter surface vs. dynamic rig — **the crux**

**The tension.** A host automates a **stable, fixed** `AUParameterTree` (fixed addresses,
fixed count, persistent across launches). StreetRig's rig is **structural**: 8 swappable pedal
slots, a swappable amp/cab (or combo), and per-item knobs. You cannot expose "the current rig's
knobs" as a tree that changes shape when the user swaps a fuzz for a delay — the host's saved
automation would dangle.

**Recommendation — expose a fixed *superset* tree that mirrors the kernel's fixed pool;
serialize *identity* as state.** The kernel already has a **fixed** capacity (`SRMaxPedals = 8`
slots; one amp; one cab) and a **stable address scheme**. Build the tree to match it, in
groups:

- **Global / amp group** — the existing 8 params **plus** the four amp EQ addresses that are
  already on the bus but missing from the tree: `SRParamAmpBass/Mid/Treble/Presence` (8–11).
  These are continuous, musical, and worth automating.
- **Eight pedal-slot groups** — for each slot `s ∈ 0..7`, expose the continuous fields at the
  **existing** structured addresses `SRPedalParamBase + s*SRPedalParamStride + field` for
  `field ∈ {Enabled, Drive, Tone, Level}`. That is 8×4 = 32 stable params ("Slot 3 · Drive",
  …), present even when a slot is empty (an empty slot's params are inert — the render thread
  only walks `activePedalCount` slots).
- **Do *not*** expose as automatable params: **gear identity** (which pedal model / amp / cab
  occupies a slot), **pedal type/character**, **slot count**, **stack vs. combo**. These are
  *structural* — they change the graph shape and go through the reconfigure barrier
  (`SRKernelConfigurePedal`, `SRKernelSetActivePedalCount`, `SRKernelSetActiveCabSlot`), not the
  continuous bus. They live in serialized **state** (§D) and are chosen in the **plugin UI**.

Use `AUParameterGroup`s (an amp group + eight pedal-slot groups) so hosts show a tidy
hierarchy. Keep every existing address value stable (the enum is append-only by contract in
`RealtimeSafety.md`), so persisted automation always resolves. `ParameterMap` stays the single
0–10 → DSP-unit table; the plugin UI's 0–10 knobs map through it exactly as the app does.

**Trade-off.** A fixed 40-ish-parameter surface shows "Slot 5 · Tone" for slots the user may
never fill — mild clutter in the host's generic view, and automation is bound to a *slot
position*, not to "the Tube Screamer" (reorder the board and a lane now drives whatever sits in
that slot). The alternative — a dynamically rebuilt tree — is **worse**: it breaks host
automation persistence and is fragile across hosts. Slot-indexed, fixed, and stable is the
correct plugin idiom, and it maps 1:1 onto the kernel's existing fixed slot pool, so it adds
*no* new audio-thread machinery. (Future nicety: expose the eight slots but let the UI label a
group with the resident pedal's name via `AUParameter`'s display name, kept in sync from state.)

### D. State & preset portability — *serialize a self-contained `RigConfiguration` snapshot*

**Recommendation.**

- **`fullState` / `fullStateForDocument`.** Override both to `super`'s dictionary (which
  already carries the AUParameterTree values) **augmented** with a `Data` blob under a custom
  key (e.g. `"streetrig.rig"`) containing a **self-contained snapshot**: the `RigConfiguration`
  *plus the referenced `GearItem`s* (amp/cab/combo + the pedals actually in the chain, with
  their `values`). Both `RigConfiguration` and `GearItem` are already `Codable`, so this is a
  tiny `Codable` wrapper — `struct RigSnapshot: Codable { var rig: RigConfiguration; var gear:
  [GearItem] }` — no parallel model. On restore, decode the snapshot, rebuild the plan with
  `RigGraphCompiler` and apply it via the existing barrier path, then let the tree values load
  as usual. Snapshotting the *resolved gear* (not just UUIDs) is essential: the plugin has no
  access to the app's `rig_state.json` collection, so UUID-only state would not resolve.
  `fullStateForDocument` = `fullState` today; keep the seam in case a document needs to *embed*
  the neural capture later.
- **Presets.** Set `supportsUserPresets = true` and implement `saveUserPreset` /
  `presetState(for:)` / `userPresets` (persist snapshots under the App Group). Provide a small
  `factoryPresets` array (`AUAudioUnitPreset` list — e.g. "Clean Combo", "British Crunch",
  "High-Gain Stack") whose states are built from seed `RigConfiguration`s (mirroring
  `RigStore.seed()`), and wire `currentPreset`.
- **Getting a rig from the app into the plugin.** Recommend an **App Group** shared container
  (`group.streetrig.shared`): the standalone app writes a "hand-off" snapshot (reuse the
  `RigStore` JSON encoder, same shape as `rig_state.json`) there, and the plugin editor offers
  **"Load current rig from StreetRig"**. This is the simplest same-device, no-account bridge.
  **iCloud** (ubiquitous container) is a later cross-device upgrade; **rebuild-in-plugin** (the
  editor is a full rig builder) is the always-available fallback and should exist regardless.

**Trade-off.** Serializing resolved gear makes the state a few KB larger and means a rig edited
in the app is a *copy* in the plugin (they don't stay live-linked — by design, since the host
owns the plugin's state once it's on a track). The App Group hand-off is one-directional and
manual ("Load from app"); true bidirectional sync is out of scope and unnecessary for the core
use case (build/adjust in the plugin; the host saves it with the song).

### E. Plugin UI — *reuse the SwiftUI knobs behind an `AUViewController`*

**Recommendation.** The extension's principal class is a `StreetRigAUFactory: AUViewController,
AUAudioUnitFactory`. Its `createAudioUnit(with:)` builds the `StreetRigDSPUnit`;
`requestViewController(completionHandler:)` (or the AUv3 `AUAudioUnitViewConfiguration` path)
returns an `AUViewController` that embeds a SwiftUI editor via `UIHostingController`. The editor
is driven by a plugin-side `RigStore` (in-memory, `persist: false` — the same initializer the
previews and offline harness already use), reusing the app's knob/rig components (moved into the
shared framework, §4.2).

**Two-way `store.binding(itemId:param:)` ⇄ `AUParameter` bridge.** This is the extension of the
existing `RigAudioBridge`:

- **UI → host:** when a knob writes through `store.binding(itemId:param:)`, also set the matching
  `AUParameter.value` (mapped via `ParameterMap`), so the host **records automation** and shows
  knob moves. The current bridge already pushes values to the kernel; add the `AUParameter`
  write so the host sees them (setting `.value` triggers `implementorValueObserver` →
  `SRKernelSetParameter`, so the kernel path is unchanged).
- **Host → UI:** register `parameterTree.token(byAddingParameterObserver:)` and, on host
  automation, write back into the `RigStore` (main-actor hop) so the on-screen knob animates.
  Guard against feedback loops with a "programmatic update" flag.

**Compact vs. full layout.** Honor the host-provided view size: a **compact** strip (amp knobs
+ active-pedal row) when the host gives a short view, the **full** rig editor (add/remove/swap
gear, all slots) when expanded. AUv3's `supportedViewConfigurations` lets the host request a
size; return a compact and a full config.

**Trade-off.** SwiftUI in an `AUViewController` inside a *host* process is well-trodden but has
sharp edges (the view runs in the extension's sandbox; keep it self-contained, no app-only
singletons). Reusing the 2D `InteractiveKnob`/control views is clean; the **3D stage is
deliberately excluded** from the plugin editor (cost and complexity, and it is app hero UI, not
a mixing-desk control surface).

### F. Hosting-model shift — *host supplies input; the same kernel serves both modes*

**Recommendation.** Keep **both** hosting layers over **one** kernel:

- **Standalone (unchanged):** `AudioEngineController` owns `AVAudioSession` `.playAndRecord`
  `.measurement`, connects `inputNode → StreetRigDSPUnit → mainMixerNode`, and the iRig feeds
  the input node. This is the user's existing live-monitoring experience — untouched.
- **Plugin:** the **host** owns the audio graph and the input. It calls the AU's
  `internalRenderBlock`, passing a `pullInputBlock` that pulls the track's audio; StreetRig
  processes it. The iRig connects to the **host** (e.g. GarageBand's input), not to StreetRig.

The render block **already** supports this: it pulls through the supplied `pullInputBlock` and
never assumes an `AVAudioEngine` input node, and `allocateRenderResources` reads its format /
`maximumFramesToRender` from the buses the host configures. So the shared kernel is genuinely
mode-agnostic; only the surrounding hosting object differs. The plugin must **not** touch
`AVAudioSession` category/activation — that is the host's job.

**Trade-off.** None structural — this is the payoff of the existing "pull input + in-place"
design. The only care item: any standalone-only assumptions (session config, route
enumeration, mic-permission) must stay in `AudioEngineController` and out of the shared engine,
so the appex never calls them.

### G. Real-time integrity — *the render path does not change; add the host-facing declarations*

**Recommendation.** Re-validate the `RealtimeSafety.md` contract under host conditions and add
the two host-facing properties the AU is missing:

- **No new audio-thread work.** `SRKernelProcess` and `internalRenderBlock` are unchanged, so
  the "no alloc / no lock / no ARC / no IO on the audio thread" contract still holds verbatim.
  The lock-free `SRKernelSetParameter` atomic bus is exactly the mechanism host automation
  needs.
- **`maximumFramesToRender`.** The host sets it before `allocateRenderResources`; the AU already
  sizes its input buffer to it — keep that, and ensure nothing assumes a specific block size.
- **Override `channelCapabilities`** to advertise supported configs (`[[1,1],[2,2]]` — mono→mono
  and stereo→stereo) so `auval` and hosts route correctly (guitar tracks are frequently mono).
- **Override `latency`** to report the cabinet convolver's delay
  (`cabLatencySamples / sampleRate`, from `SRKernelCabLatencySamples`) so the host performs
  plugin-delay-compensation. This is currently unreported — a real bug for an insert on a
  multitrack session.
- **Neural cost fits at host buffer sizes.** The offline benchmark measures **≈1.18 µs/sample**
  for the full amp→cab chain (Debug ‑O0). Because that is a *per-sample* figure and the deadline
  is `frames / sampleRate` (also per-sample once divided out), the **fraction of the deadline is
  buffer-size-independent** to first order (~5.7 %); a host using 64- or 128-frame buffers still
  fits with wide headroom, and Release (`-Os`, `SWIFT_COMPILATION_MODE = wholemodule`) is faster.
  Re-run `benchmarkFullNsPerSample` on-device and watch `lastRenderLoad` when a heavier real
  capture is dropped in.

**Trade-off.** Reporting `latency` is correct but means the plugin adds reported delay; that is
the honest, host-compensated behavior and strictly better than silent misalignment. Confirm the
`CabinetConvolver`'s internal partition (B=128) handles host buffers that are **not** multiples
of 128 (it is FIFO-based and designed for arbitrary block sizes — verify in `auval`'s varying
buffer-size tests).

### H. Entitlements & capabilities — *App Group yes, IAA never*

**Recommendation.**

- **App Group** (`group.streetrig.shared`) on **both** the app and the appex (same team
  `HHM5CMKKMJ`), for the preset/rig hand-off container (§D) and shared user presets.
- **Background audio** (`UIBackgroundModes = audio`) belongs to the **standalone app** (live
  monitoring in the background); the **appex does not need it** — the host owns the audio
  session and its background behavior.
- **Explicitly do not add** the deprecated `inter-app-audio` entitlement anywhere.
- The appex inherits the app's team and must be code-signed together; its bundle id is
  `streetrig.StreetRig.AUv3`.

**Trade-off.** Adding an App Group touches provisioning (a new capability on the App ID); it is
the standard, minimal footprint for same-device sharing and avoids an iCloud dependency.

### I. Platform reach — *iOS first; Catalyst is the "laptop" answer and the `auval` path*

**Recommendation.** Ship **iOS/iPadOS first**: GarageBand (iOS/iPadOS), **Logic for iPad**, AUM,
Cubasis, apeMatrix. Then bring the **same app + appex to macOS via Mac Catalyst** so the plugin
loads in **Logic Pro / GarageBand for Mac** — this is what actually satisfies "link the amp sim
to your laptop," and it is also the only way to run Apple's **`auval`** validator (macOS-only).
For a validated desktop AU: build both targets for "My Mac (Mac Catalyst)", confirm the
`AudioComponents` plist and `sandboxSafe` survive, re-check `channelCapabilities` /`latency`,
and pass `auval -v aufx srds Strg`. A native (non-Catalyst) AppKit AU is a larger lift and
unnecessary for v1.

**Trade-off.** Catalyst is low-effort reach for the desktop DAW, but its UI polish and some
audio edge-cases need their own QA pass; treat macOS as a fast-follow (§6, Phase 6), not a v1
gate.

---

## 6. Phased implementation plan

| Phase | Goal | Key work | Exit criteria | Rough effort |
|---|---|---|---|---|
| **1 — Extract the shared engine** | DSP compiled once, linked by app (and future appex) | New `StreetRigEngine.framework`; move `Audio/*` + `Models/Gear.swift` + `Models/RigStore.swift` + `RigGraphCompiler` + `ParameterMap` + audio `Resources/` into it; **replace bridging header with a module map**; `gnu++20` + link Accelerate in the framework; app links the framework | App builds; **offline render harness still PASSES** (its null test is the regression oracle); standalone live monitoring unchanged | **2–4 days** (Xcode surgery: module map, synced-group move, header paths) |
| **2 — Stand up an empty `.appex` that loads** | The extension is discoverable and instantiable | New Audio Unit Extension target; `Info.plist` `AudioComponents` (`aufx`/`srds`/`Strg`, `sandboxSafe`, `factoryFunction`); `StreetRigAUFactory.createAudioUnit` returns `StreetRigDSPUnit`; **copy tone assets into the appex bundle** and switch asset loading to `Bundle(for:)`; App Group capability | `auval -a` / `AVAudioUnitComponentManager` lists it; it loads in AUM and passes audio (unity/current default rig) | **1–2 days** |
| **3 — Parameters + state** | Host automation + save/recall | Expand `AUParameterTree` to the fixed superset (§C: amp EQ 8–11 + 8×4 pedal grid, grouped); `channelCapabilities`; `latency`; `fullState`/`fullStateForDocument` with the `RigSnapshot` blob; `factoryPresets` + `supportsUserPresets` + user-preset save/restore | Move a param from the host → tone changes; save project, reopen → rig recalls; `auval` parameter + state tests pass | **2–3 days** |
| **4 — Plugin UI** | Embedded editor, reused knobs | `requestViewController` → `AUViewController` + `UIHostingController`; plugin-side `RigStore(persist:false)`; two-way `binding ⇄ AUParameter` bridge (extend `RigAudioBridge`); compact + full `supportedViewConfigurations`; "Load rig from StreetRig" via App Group | Editor shows in GarageBand; knob moves record as automation and follow host automation; App-Group hand-off works | **3–4 days** |
| **5 — Verify in real hosts** | Ship-confidence on device | Discovery + load in **GarageBand iOS** and **AUM**; automate a knob from the host; save/recall; **A/B null test** plugin output vs. the standalone offline render (§7) | All §7 checks pass on device; null test ≈ bit-identical | **2–3 days + iteration** |
| **6 — macOS via Catalyst (fast-follow)** | The "laptop" story | Build app + appex for Mac Catalyst; run `auval -v aufx srds Strg`; load in Logic Pro / GarageBand macOS | `auval` clean; loads and automates in a desktop DAW | **2–4 days** |

Phase 1 is startable immediately and is the critical path; Phases 2–4 are sequential; Phase 5
runs continuously once Phase 2 lands.

---

## 7. Verification plan

- **`auval` (macOS/Catalyst).** `auval -a` to confirm discovery; `auval -v aufx srds Strg` for
  the full conformance suite (parameter tree, state round-trip, render at multiple sample
  rates/buffer sizes, channel configs, in-place, latency). This is the gold-standard gate and
  requires the Phase-6 Catalyst build.
- **Component discovery (in-app + host).**
  `AVAudioUnitComponentManager.shared().components(matching: <aufx/srds/Strg>)` returns the
  extension; the standalone app can surface "plugin installed" with the same call.
- **Load in real hosts.** AUM and GarageBand (iOS): insert StreetRig on a guitar track, confirm
  live processing through the iRig-into-host path (§5.F).
- **Automate a parameter from the host.** Record an automation lane on, e.g., "Amp · Drive"
  (`SRParamAmpDrive`) and "Slot 3 · Tone"; confirm audible change and that the editor knob
  follows (the §5.E host→UI bridge).
- **Save / recall `fullState`.** Save the host project, reopen; confirm the whole rig (topology
  + gear + knob values) restores from the `RigSnapshot` blob, not just the 8 legacy params.
- **A/B null test against the offline oracle (the decisive correctness check).** Render the same
  DI (`StreetRig_DI_placeholder.wav`) two ways: (1) the standalone `runOfflineRender()` path,
  and (2) the **plugin instance** hosted in an offline `AVAudioEngine` graph with the *same*
  `RigConfiguration` applied. Null the two with the existing `analyze(...)` /
  `difference(...)` / `nullRMS` utilities and require **`nullRMS < 1e-3`** (the harness's own
  passthrough threshold). Because both paths run the *identical* `SRKernelProcess`, the outputs
  should be sample-accurate — any divergence localizes a packaging/state bug, not a DSP one.
  This reuses `AudioEngineController+OfflineRender.swift` verbatim as the oracle.

---

## 8. Risks & open decisions

- **Manufacturer / subtype registration (product call).** `Strg` / `srds` are already in the
  source and are valid (`Strg` has an uppercase, so not Apple-reserved). Codes are unique only
  by convention; decide whether to keep `Strg`/`srds` permanently (recommended — changing them
  later orphans saved automation/presets) and record them as the project's canonical AU
  identity. There is no formal Apple registry, but avoid collision with well-known plugins.
- **How much rig to expose as automatable params (product/UX call).** The plan recommends the
  full fixed superset (amp + EQ + 8×4 pedal grid ≈ 40 params). If that is too noisy for casual
  GarageBand users, a curated subset (amp + a "focused pedal" macro set) is the alternative —
  but pick one and keep the addresses stable forever. Flag for a product decision.
- **Preset-sharing mechanism (recommended: App Group).** App Group is the v1 pick; confirm the
  provisioning/App-ID capability is acceptable. iCloud (cross-device) and a full
  rebuild-in-plugin flow are follow-ups; the plugin must be usable with *no* app installed
  regardless.
- **Tone-asset duplication (decision).** `Bundle.main` inside a `.appex` is the extension
  bundle, so the amp-capture JSON + cab WAVs must ship **in the appex** (copy the `Resources/`)
  or be read from the App Group. Duplicating ~a few hundred KB in the appex is simplest;
  loading real, larger captures later may argue for the shared container.
- **Registration coexistence (minor).** With the appex installed, `AVAudioUnit.instantiate`
  could resolve either the in-process subclass or the out-of-process appex. Keep the standalone
  app instantiating **in-process** (via `registerIfNeeded()`) so it never loads its own
  extension; verify no double-registration warning.
- **Real brand names in `RigStore.catalog` (already flagged by the team).** Gear names
  ("Marshall JCM800", "Tube Screamer", …) currently used as data would surface **publicly** in a
  third-party DAW's preset/parameter/plugin browser. This raises the visibility of the existing
  trademark question (see the 3D research doc's §5). Decide whether the plugin uses generic
  archetype names before shipping to hosts. **Product/legal call.**
- **macOS/Catalyst scope (product call).** Is the desktop plugin a launch goal or a fast-follow?
  It is the true "link to your laptop" deliverable and the only `auval` path, but carries its
  own QA. Recommended as Phase 6, not a v1 gate.
- **C++ standard discrepancy (low).** Header comments say "C++17"; the build is `gnu++20`. Match
  `gnu++20` in the framework to avoid subtle ABI/feature drift.

---

## Sources

- [Audio Unit v3 — creating custom audio effects (Apple Developer)](https://developer.apple.com/documentation/audiotoolbox/creating-custom-audio-effects)
- [AUAudioUnit (Apple Developer)](https://developer.apple.com/documentation/audiotoolbox/auaudiounit)
- [AUParameterTree / AUParameter (Apple Developer)](https://developer.apple.com/documentation/audiotoolbox/auparametertree)
- [Handling parameters and state — fullState / presets (Apple Developer)](https://developer.apple.com/documentation/audiotoolbox/auaudiounit/fullstate)
- [AUViewController & requestViewController (Apple Developer)](https://developer.apple.com/documentation/coreaudiokit/auviewcontroller)
- [AVAudioUnitComponentManager — discovering installed Audio Units (Apple Developer)](https://developer.apple.com/documentation/avfaudio/avaudiounitcomponentmanager)
- [Inter-App Audio is deprecated (Apple Developer — AudioToolbox release notes / WWDC guidance)](https://developer.apple.com/documentation/audiotoolbox)
- [Technical Note — auval Audio Unit Validation Tool](https://developer.apple.com/library/archive/technotes/tn2247/_index.html)
- [App Groups — sharing data between an app and its extensions (Apple Developer)](https://developer.apple.com/documentation/xcode/configuring-app-groups)
- [Mac Catalyst (Apple Developer)](https://developer.apple.com/documentation/uikit/mac-catalyst)
- [Audiobus SDK (developer overview)](https://developer.audiob.us/)
- Internal: `StreetRig/Audio/RealtimeSafety.md`, `StreetRig/Audio/StreetRigDSPUnit.swift`,
  `StreetRig/Audio/StreetRigDSPKernel.h`, `StreetRig/Audio/RigGraphCompiler.swift`,
  `StreetRig/Audio/AudioEngineController+OfflineRender.swift`, `StreetRig/Models/Gear.swift`,
  `StreetRig/Models/RigStore.swift`, `StreetRig.xcodeproj/project.pbxproj`,
  `research/3d-amp-rendering-options.md` (format precedent).
