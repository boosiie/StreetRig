# Per-Amp Voicing — Phase A Implementation Notes

**Status:** shipped, verified offline · **Date:** 2026-08-19 · **Scope:** Phase A of
`research/amp-emulation-approaches.md` §12 — the profile architecture and the Katana core.
Phase B (shared delay/reverb blocks, the Katana FX section, channel presets) is untouched and
unblocked.

**The problem this closes.** Every amp in StreetRig was the same DSP with different artwork: one
fixed preamp voicing, one fixed 4-band tone stack flat at noon, and the amp's name read only to pick
a cab IR. A Marswell JCM800, a Fandor Twin Reverb, a Volt AC30 and a Rolund JC-120 nulled against
each other. They now do not: the offline harness measures every pair of the six catalog amps as
**at least 28.5 % apart after level matching**, with the differences located in the spectrum rather
than in the gain.

---

## 1. What shipped

### New files

| File | What it is |
|---|---|
| `StreetRigEngine/Audio/AmpProfile.hpp` | The schema: `AmpClip`, `ToneShape`, `PreampStage`, `ToneBand`, `ToneStackVoicing`, `PowerAmpVoicing`, `AmpProfile`, the `AmpVoicing` id enum, `profileFor()` |
| `StreetRigEngine/Audio/AmpProfile.cpp` | **THE ONE AUDITABLE TABLE.** Every hard-coded voicing number in the app's amp path, one amp per `case`, each with its §11 listening cue next to the value it describes |

### Changed — engine

| File | Change |
|---|---|
| `AnalogAmp.hpp` / `.cpp` | One fixed voicing → an N-stage profiled cascade. Added `configure(const AmpProfile&)`, `OnePoleLP` / `OnePoleHP` / `OnePoleShelf` primitives, the `AmpClip` waveshaper family (`ampShapeRaw` / `ampShape`), per-stage constants and per-channel stage state. `Biquad` and its designers are untouched, so `DrivePedal`'s include of this header still works unchanged |
| `AmpCabProcessor.hpp` / `.cpp` | `ToneStack` gained `configure()`, the `noonDB` / `rangeScale` / `bassEatsMid` / `insertionDB` transform and per-band skipping — its double-buffered coefficient publish and per-channel filter memory are **unchanged**. New `PowerAmp` class. `AmpCabParams` gained `ampVolume` and `powerScale`. New `configureAmp(int)` and `setPresenceDB(float)`. `kNumCabSlots` 4 → 8. `process()` split into `processPreamp` / `processPowerAmp` / `processCab` (the seam Phase B needs for a mid-chain FX loop) with `process()` composing them |
| `StreetRigDSPKernel.h` | `SRParamAmpVolume = 12`, `SRParamAmpPower = 13`. New `SRKernelConfigureAmp` / `SRKernelActiveAmpProfile` / `SRKernelAmpProfileBypassesCab` |
| `StreetRigDSPKernelInternal.hpp` | `RampedGain ampVolume`, `RampedGain ampPower` |
| `StreetRigDSPKernel.cpp` | The two addresses join the `RampedGain` family via `gainForAddress`; `SRParamAmpPresence` now routes through `processor.setPresenceDB`; `AmpCabParams` carries the two new values in both the render path and the benchmark |
| `ParameterMap.swift` | `ampProfile(name:values:)`, `ampVolume(volumeKnob:)`, `ampPowerScale(powerIndex:)` and their analytic inverses; `ampProfileCabSlot`, `ampProfileBypassesCab`; the `amp*` id constants mirroring `AmpVoicing`; `ampUsesNeural` is now profile-driven |
| `RigGraphCompiler.swift` | `RigDSPPlan` gained `ampProfile`, `ampVolume`, `ampPower`. `compile` resolves the profile, per-knob defaults for the new keys, the profile's cab pairing and `bypassCab`. The signature grew `ampProfile` and the cab-bypass flag and deliberately did **not** grow `ampPower`. `applyStructure` calls `configureAmp`; `pushValues` pushes 12 and 13 |
| `RigAUParameterBridge.swift` | Volume and Power `ParamLink`s, both with inverses. Every amp link is now **guarded by the amp's own knob list** — see §3.5, this was a real bug waiting to happen |
| `StreetRigDSPUnit.swift` | Two new `AUParameter`s appended to `ampGroup`; `cabSelect` range 0…3 → 0…7; `syncParameterTree` mirrors both; `configureAmp(profile:)` and the `activeAmpProfile` / `configuredAmpProfile` diagnostics; two Katana factory presets appended (numbers 3 and 4 — the existing three keep 0/1/2 forever) |
| `Gear.swift` | `GearParameter` gained `options: [String]?` (nil = a 0–10 dial, non-nil = a discrete selector whose stored value is an index). `PedalSpec` gained amp branches: the Katana's ten controls, and the JC-120's five |

### Changed — app

| File | Change |
|---|---|
| `ComponentDetailView.swift` | Splits the knob list into dials and switches. Dials render exactly as before; switches render as a segmented selector through the same `store.binding(itemId:param:)` |
| `PluginEditorView.swift` | `item.category.parameters` → `item.parameters` |
| `AmpModel3DView.swift` | `AmpScene.knobParamNames` is now `knobParamNames(for:)`; the faceplate builder and the knob-node cache take the item's own list |
| `RigStage3DView.swift` | Same per-item knob cache |
| `AudioEngineController+OfflineRender.swift` | The amp-profile suite (26 checks), the Legacy cross-build null reference, the power-switch click test, the AUv3 state round-trip, and A/B WAV output for the ear-tuning pass |

### The catalog, filled in

Six profiles plus the Katana's ten voicings — sixteen rows, no special cases:

| id | Profile | id | Profile |
|---|---|---|---|
| 0 | `Legacy` (the universal fallback) | 10 / 11 | Katana Acoustic A / B |
| 1 | Marswell JCM800 2203 | 12 / 13 | Katana Clean A / B |
| 2 | Fandor Twin Reverb | 14 / 15 | Katana Crunch A / B |
| 3 | Volt AC30 | 16 / 17 | Katana Lead A / B |
| 4 | Rolund JC-120 Jazz Chorus | 18 / 19 | Katana Brown A / B |
| 5 | Fandor Bassman '59 | 6–9, 20+ | reserved / open |

---

## 2. Adding the seventh amp — the claim, concretely

The success criterion is that a new amp is *a table entry plus a name match, no new DSP*. Here is
the whole of it for **Marswell Plexi Super Lead 1959**, which is already in the catalog and
currently resolves to `Legacy`:

**1. One id** — `AmpProfile.hpp`, in the reserved block:
```cpp
Plexi1959 = 6,
```

**2. One row** — `AmpProfile.cpp`, anywhere in the switch:
```cpp
case Plexi1959:                       // no master volume: it is loud or it is clean
    p.inputHz  = 68.0;
    p.brightHz = 1600.0; p.brightDB = 5.0f;   // the famous bright cap, bigger than the JCM800's
    p.stageCount = 2;                          // two, not three — this is why a Plexi cleans up
    p.stage[0] = st(30.0, 470.0, 7.0f, 16000.0, 2.0f, 0.10f);
    p.stage[1] = st(38.0,   0.0, 0.0f, 11000.0, 1.8f, 0.10f);
    p.tone = tone3( 95.0, 0.70, 1.0f, -1.0f,
                   680.0, 0.85, 0.9f, -6.0f,
                  2400.0, 0.70, 1.1f, +1.0f,
                  -14.0f, 0.35f);
    p.power = PowerAmpVoicing{
        0.60f, AmpClip::ClassAB, 0.06f,        // less headroom than a 2203 — it breaks up early
        0.22f, 50.0,
        2000.0, -2.5f,                          // lighter feedback than the 800
        3200.0, 1.0f,
        60.0, 9500.0
    };
    p.cabSlot = 0;
    p.outTrim = 1.00f;
    break;
```

**3. One name match** — `ParameterMap.swift`, beside the others:
```swift
public static let ampPlexi1959 = 6
…
if n.contains("plexi") || n.contains("super lead") { return ampPlexi1959 }
```

That is the entire change. No new class, no new parameter address, no signature change, no UI work,
no migration, no `catalogVersion` bump. The offline suite picks it up as soon as it is added to the
`catalog` array in `runAmpProfileVerification`.

The Katana is the strongest evidence the schema really is general: it is a *modeling amp*, so
simulating it is simulating a simulator, and all ten of its character × variation voicings are
ordinary rows sitting in the same table as the JCM800 — none of them has a field the JCM800 lacks.
Two came close and both were absorbed by one general field each, now available to every amp:
`AmpProfile::bypassCab` (the Acoustic character has no speaker) and a negative `presenceScale`
(the Vox Cut, which the AC30 also uses).

---

## 3. Deviations from the research document

Seven, each with its reason. None changes the architecture; three are corrections to the document.

### 3.1 `AmpClip::ClassA` does not exist — the AC30 uses `Pentode`

§3.3 gives the AC30 `clip = ClassA`, but the `AmpClip` enum in §2.2 has no such enumerator
(`Clean` / `Triode` / `Pentode` / `ClassAB` / `SolidState`). This is an internal inconsistency in the
document. Resolved in favour of the schema: the AC30 uses **`Pentode`**, which is literally the
EL84 output-valve family, and §1.3 already states that "Class A" is carried by
`clip` + `asym` + `headroom` **together, not by a separate flag** — which the AC30 row does
(`headroom 0.55`, `asym 0.18`, `sagDepth 0.35`, `nfbDB 0`). Nothing about the amp's specified
behaviour is lost.

### 3.2 The last stage's Miller pole is a base-rate biquad, not a one-pole

§2.5's back-compat table requires the Legacy post-clip low-pass to be
`Biquad::lowpass(sr, 8000, 0.707)` and simultaneously says it is carried as the last stage's
`millerHz`. Both are honoured by realizing the **last** stage's Miller pole as the base-rate output
biquad while interstage Miller poles stay one-poles inside the oversampled region. This is also the
better engineering: nothing clips after the final pole, so running it at 4× buys nothing, and it is
the amp's output bandwidth where a steeper slope earns its keep. Without this the bit-exact null test
cannot pass.

### 3.3 `Power` is stored as an index, not as watts

§7.8 suggests defaulting `Power → 100`, i.e. storing watts. Shipped as an **index 0/1/2** with
`options: ["0.5 W", "50 W", "100 W"]`, for the same reason §2.4 gives for Character and Variation:
it is a three-detent selector, not a dial, and a `GearParameter` with `min 0, max 100` would put a
0–100 slider and a numeric keypad in front of a three-position switch. The inverse map is
correspondingly `invAmpPowerIndex` rather than `invAmpPowerWatts`. The *bus* value is unchanged and
still continuous.

### 3.4 The JC-120 ships with no Presence knob and no Bright knob

§7.8 proposes `["Gain","Bass","Mid","Treble","Bright","Master"]`. Shipped without the Bright control:
§3.3 sets the JC-120's `presenceScale` to **0** ("this amp has no presence control"), so a Bright
knob would need either a new parameter address or a structural filter redesign, and §13 Q5 flags the
whole question as an undecided *product* decision. Shipping an inert dial would be worse than
shipping none. The one-line fix when the decision is made is in §5 below.

### 3.5 Amp `ParamLink`s are guarded by the amp's own knob list

Not specified, but required. `RigAUParameterBridge.pushContinuousToParameters` reads
`values[param] ?? 0`, so an unconditional Volume link would have pushed **knob 0 → 0.2× gain into
the power amp** for every amp that is not a Katana. The links are now built from
`amp.parameters`, which is the same per-item list the UI draws.

### 3.6 Master stays ahead of the cab

§6's after-diagram places Master after the cab convolver. It stays where it was, between the power
amp and the cab. The convolver is linear, so the two placements are mathematically identical — and
keeping it put is what allows the Legacy null test to be bit-exact rather than
merely-below-a-threshold.

### 3.7 `insertionDB` is recovered *after* the power amp

§2.2 says the insertion loss is "recovered as makeup" without saying where. Recovered after the
output stage, which is the only placement where the field does anything at all: the loss then decides
how hard the tone stack drives the output valves (a Fender's ~16 dB is precisely why its power amp
stays clean where an AC30's ~12 dB has it compressing), without making the amp 16 dB quieter.

### Plus two schema hardenings the verification forced

- **`PowerAmpVoicing`'s defaults are now all neutral.** The document defaults `clip` to `ClassAB`,
  which silently gave the Legacy voicing an output-stage clip at unity gain and a 2× oversampler's
  group delay. The null test caught it (max |Δ| 0.71). Every default is now the neutral value, so
  "a default-constructed voicing is a no-op" is an invariant of the type rather than something each
  row has to remember.
- **Filter corners at or above Nyquist are skipped, not designed.** The JC-120's Miller poles sit at
  25 kHz — above 48 kHz Nyquist — and an RBJ design at that corner produces nonsense coefficients:
  the first build rendered the entire JC-120 as NaN. `inputHz`, `brightHz`, the output low-pass,
  `nfbHz`, `otLowHz` and `otHighHz` all now skip above `0.45 · sr`, which is both the correct filter
  and the correct behaviour ("this stage does not roll off inside the audio band").

---

## 4. Verification

Offline harness, real AU graph, iOS 26.5 Simulator, Debug −O0. **Every suite green**, including the
four that existed before this work:

```
OVERALL       : PASS      (prompt 002 — neural amp + cabinet IR)
PROMPT 003 OVERALL: PASS  (full compiled-rig chain)
PEDAL FAMILIES OVERALL: PASS
SIGNAL METERS OVERALL: PASS
AR FOOTSWITCH OVERALL: PASS
AMP PROFILES OVERALL: PASS      ← new, 26 checks
LEGACY REFERENCE OVERALL: PASS  ← new, the cross-build null test
```

### The six amps, same DI, same knobs, cab bypassed

`mid` and `hi>` are RMS **fractions**, so they are level-independent: an amp cannot score
differently just by being louder.

```
  amp                    profile  RMS       crest  |  mid300-1.2k  hi>500  hi>1k  hi>2k  hi>4k  hi>8k
  Marswell JCM800 2203    1     -5.4 dB   1.92  |      38.8%   28.5%  18.7%  10.8%   4.9%   1.6%
  Fandor Twin Reverb      2     -7.9 dB   2.19  |      26.5%   16.0%   8.9%   3.9%   1.4%   0.4%
  Volt AC30               3     -3.5 dB   2.58  |      44.6%   31.7%  16.7%   7.3%   2.8%   0.9%
  Rolund JC-120 Jazz Cho  4     -4.8 dB   2.05  |      32.5%   19.5%   9.8%   4.3%   1.6%   0.5%
  Fandor Bassman '59      5     -5.3 dB   2.12  |      33.4%   23.2%  14.0%   7.0%   2.9%   0.9%
  VOSS Katana 100        14     -6.2 dB   2.13  |      41.3%   30.7%  18.2%   9.0%   3.6%   1.1%
```

The `noonDB` claims land: the AC30 is the only mid-forward amp of the six (44.6 %), the Twin is the
most scooped (26.5 %) and the JCM800 sits between them (38.8 %) — at *identical* knob settings, which
is exactly the difference that did not exist before.

### The Katana's ten voicings

```
  Acoustic A             10     -4.1 dB   4.38  |      34.3%   18.4%   6.4%   1.8%   0.5%   0.2%
  Acoustic B             11     -3.6 dB   4.39  |      35.9%   20.0%   7.1%   1.9%   0.5%   0.2%
  Clean A                12     -4.2 dB   2.25  |      34.8%   21.2%  10.5%   4.5%   1.5%   0.4%
  Clean B                13     -5.6 dB   1.87  |      33.4%   20.3%  10.4%   4.8%   1.8%   0.5%
  Crunch A               14     -6.2 dB   2.13  |      41.3%   30.7%  18.2%   9.0%   3.6%   1.1%
  Crunch B               15     -6.8 dB   2.12  |      49.6%   40.0%  24.6%  12.7%   5.5%   1.9%
  Lead A                 16     -8.1 dB   2.07  |      54.0%   43.3%  26.2%  13.5%   5.9%   2.1%
  Lead B                 17     -8.8 dB   2.01  |      58.3%   47.2%  28.8%  15.6%   7.7%   3.1%
  Brown A                18     -7.9 dB   1.95  |      58.4%   47.4%  28.5%  15.1%   7.2%   2.9%
  Brown B                19     -9.6 dB   1.97  |      59.5%   49.7%  32.1%  18.5%   9.6%   4.0%
```

Saturation climbs monotonically Acoustic → Clean → Crunch → Lead → Brown, and every B is hotter than
its A — the stated variation rule, visible in the numbers.

### The power control

```
  power 100 W : RMS -5.3 dB  crest 2.04  hi>3k  8.7%  loud/quiet 1.56
  power  50 W : RMS -4.8 dB  crest 2.05  hi>3k  9.8%  loud/quiet 1.38
  power 0.5 W : RMS -5.9 dB  crest 2.38  hi>3k 15.0%  loud/quiet 1.15
```

At matched level, 0.5 W leaves a **25.8 % residual** against 100 W, its high-band energy nearly
doubles, and a loud→quiet burst comes out **1.15** apart instead of **1.56**. It is not a volume knob.

### All 26 amp-profile checks

```
  six amps resolve to six profiles               PASS   (ids [1, 2, 3, 4, 5, 14] (0 = legacy fallback, must not appear))
  every amp pair differs (level-matched)         PASS   (closest pair 2/4 still 28.5% residual after level matching)
  …and differs SPECTRALLY, not just in level     PASS   (closest pair 3/14 still 1.7 pp apart in a band)
  AC30 is the only mid-FORWARD amp               PASS   (AC30 44.6% vs next-highest 41.3%)
  Twin is more mid-scooped than the JCM800       PASS   (mid 300–1.2k: Twin 26.5% < JCM800 38.8% (noonDB −11 vs −7))
  JC-120 keeps its headroom; the JCM800 does not PASS   (crest: JC-120 2.05 > JCM800 1.92 (headroom 3.00 vs 0.75))
  JCM800 Presence 0→10 brightens                 PASS   (hi>3k 5.3% → 10.8%)
  AC30 Presence 0→10 DARKENS (the Vox Cut)       PASS   (hi>3k 4.8% → 3.8% (presenceScale −0.8))
  ten Katana voicings, ten profile ids           PASS   (ids [10, 11, 12, 13, 14, 15, 16, 17, 18, 19])
  all ten Katana voicings are distinct           PASS   (closest pair Acoustic A vs Acoustic B still 10.6% residual)
  Variation B differs from A on every character  PASS   (weakest: Acoustic 10.6% residual)
  Brown B is tighter than Brown A (less low end) PASS   (20–150 Hz: A 51.9% → B 46.6% (inputHz 85 → 105))
  power 0.5 W ≠ 100 W AT MATCHED LEVEL           PASS   (25.8% residual after level matching — not a gain change)
  0.5 W changes HARMONIC content                 PASS   (hi>3k 8.7% → 15.0%)
  0.5 W COMPRESSES harder (loud→quiet burst)     PASS   (loud/quiet 1.56 → 1.15)
  50 W sits between the two                      PASS   (loud/quiet 100 W 1.56 ≥ 50 W 1.38 ≥ 0.5 W 1.15)
  Power is CONTINUOUS (signature unchanged)      PASS   (0.5 W and 100 W compile to P[]|amp:14/a|cab:1|combo:true)
  Gain/EQ/Volume are CONTINUOUS (signature uncha PASS   (knob turns never rebuild the chain)
  Character is STRUCTURAL (signature moves)      PASS   (Crunch P[]|amp:14/a|cab:1|combo:true → Brown P[]|amp:18/a|cab:1|combo:true)
  Variation is STRUCTURAL (signature moves)      PASS   (A → B changes the profile id)
  power switch mid-render is click-free          PASS   (max |Δsample| 0.6489 across the switch vs 0.6546 steady (×0.99))
  ampVolume knob → bus → knob is identity        PASS   (max error 8.64e-07 over 0…10 in 0.5 steps)
  ampPower index → bus → index is identity       PASS   (0.5 W / 50 W / 100 W all resolve back to their own detent)
  a rig saved before this change loads with sane PASS   (no Character/Variation/Power/Volume keys → profile 14 (Crunch A), power 1.0, volume 1.0)
  AUv3 fullState round-trips the new addresses   PASS   (volume 1.400 → 1.400, power 0.140 → 0.140)
  a host blob with NO new params loads on defaul PASS   (rig-only blob → resolved profile 14 (Katana Crunch A), volume 1.000, power 1.000 (both at their defaults))
```

### The AUv3 extension, out of process

`-VerifyAUv3` (the packaging + two-way-bridge self-test) is green end to end with the new
parameters and presets:

```
  OUT-OF-PROCESS render null vs in-process oracle : PASS  (null -180.0 dBFS @ lag 0)
  factoryPresets non-empty                 PASS   (5 presets)          ← 3 existing + 2 Katana
  factory preset changes audio             PASS   (diff RMS -5.9 dBFS)
  fullState round-trip nulls (whole rig)   PASS   (null -180.0 dBFS @ lag 0)
  srds out-of-process param consistency    PASS   (srds↔srdi null -180.0 dBFS)
  bridge: automatable knobs mapped         PASS   (count 9; amp Marswell JCM800 2203, pedals 3)
  host→UI / UI→host on addr 8 and 103      PASS
  no feedback oscillation                  PASS
  PHASE 3 (Simulator gates) : PASS
  PHASE 4 (Simulator gates) : PASS
```

The "count 9" is the §3.5 guard doing its job: a JCM800 gets its six knobs plus three pedal fields
and **no** Volume or Power link, because it has no such knobs.

### The Legacy null test — bit-exact, across builds

The harness renders a pinned plan (an amp name no profile matches, no pedals, cab bypassed, neural
off, generated test signal, off-centre EQ) to `Documents/StreetRig_legacy_reference.wav` on every
run. A render captured from the **pre-change** build was placed alongside it as
`StreetRig_legacy_baseline.wav`, and the post-change build nulls against it:

```
  baseline null test: BIT-EXACT  (103200 samples compared, max |Δ| 0.000e+00, null RMS -180.0 dBFS)
```

Not "below a threshold" — **zero**, over every one of 103 200 samples. An amp with no profile is the
same amp it was.

---

## 5. CPU — the one exit criterion that is not met

Full-board seed rig (3 pedals → JCM800 → 4×12, Debug −O0), measured with
`SRKernelBenchmarkFullNsPerSample` before and after on the same simulator:

| | ns/sample | µs per 128-frame block | % of the ~2667 µs budget |
|---|---|---|---|
| **Before** (JCM800 on the neural rail) | 1603.4 | 205.2 | **7.70 %** |
| **After** (JCM800 profiled, 3 stages + power amp) | 1742–1776 | 223.0–227.4 | **8.3 – 8.5 %** |

**≈ +0.7 percentage points** (three runs: 8.31 %, 8.36 %, 8.53 % — Debug −O0 measurements carry a
few tenths of run-to-run spread). Per profile, amp only (no pedals, cab included):

| Profile | Debug ns/sample | Debug % | Release ns/sample | Release % |
|---|---|---|---|---|
| Legacy, unprofiled (neural rail ON) | 1181.1 | 5.67 % | 257.6 | 1.24 % |
| JCM800 — 3 stages + Class AB power amp | 1356.4 | 6.51 % | 295.0 | 1.42 % |
| Katana Brown B — 4 stages + power amp | 1648.8 | 7.91 % | 372.9 | 1.79 % |

**§10 predicted the change would be CPU-*negative*, and it is not.** The prediction assumed the LSTM
forward pass was 4.5–5 % of the board, so that turning the neural rail off for a profiled amp would
buy more than the cascade costs. The measurement says the bundled *placeholder* capture is far
cheaper than that — swapping it for a 3-stage profiled cascade plus a power amp costs **+0.84 pp**
rather than saving 3 pp. The document's estimate was made against `RealtimeSafety.md`'s recorded
"amp→cab ≈ 5.7 %, the LSTM dominates", which was measured with that same placeholder; the arithmetic
in §10 attributed too much of it to the LSTM.

**This misses §12's Phase A exit criterion (4), "at or below today's 7.74 %", and is reported as a
miss rather than reframed.** What it is not is a problem. The same harness in a **Release** build
puts the whole board at **1.79 %** (371.9 ns/sample → 47.6 µs per block), with the JCM800 at 1.42 %
and Katana Brown B at 1.79 % — so the shipping configuration has ~98 % headroom, and the Debug
figure is a −O0 artefact of the measurement, not the cost a player pays. §10's own framing is
"fallback **if it does not fit**", and it fits with room to spare.

Release also re-runs every suite green, including the bit-exact Legacy null — so the back-compat
guarantee is not an artefact of unoptimized floating point either.

The cheap fix is on the shelf and deliberately not taken: §10 caveat 1 specifies swapping `std::tanh`
for the Padé approximation `x(27 + x²)/(27 + 9x²)`, worth roughly 1 pp — but it changes the waveform,
which downgrades the Legacy null test from bit-exact to residual-below-a-threshold. **Phase A ships
`std::tanh` and a bit-exact null test**, exactly as §10 instructs. If a heavier real capture or a
loaded FX board later pushes the budget, the order to apply the fallbacks is §10's list, starting
there.

---

## 6. The values most in need of ear-tuning

Spend the iRig session in this order. Every value below lives in `AmpProfile.cpp`'s `profileFor()`
with its listening cue in the comment beside it.

1. **All ten Katana rows** (`katana(...)` argument lists). Confidence **L** — Boss publishes nothing,
   and the variation rule ("B = hotter and tighter") is one stated guess applied consistently rather
   than ten separate ones. Highest value per minute of listening.
2. **Katana Crunch A stage gains `2.0 / 2.1 / 1.5`.** With Gain at noon it should sit *right at*
   edge-of-breakup. Already crunchy at 3 → lower; clean at 7 → raise. Everything else Katana is
   calibrated relative to this row.
3. **0.5 W `headroomScale = 0.14`** (`ParameterMap.ampPowerScale`). Physically it should be 0.071;
   we ship the conservative 0.14. Should sound like a small cranked amp, not a fuzz pedal.
4. **Twin `mid.noonDB = −11`** and **JCM800 `mid.noonDB = −7`.** If a Twin and a JCM800 still sound
   alike at noon, these two rows are the first suspects — they are the single largest lever in the
   whole change.
5. **JCM800 S1 cathode `480 Hz / +8 dB`.** Flubby palm mutes → raise the Hz. Thin and brittle →
   lower it or reduce the dB.
6. **AC30 `presenceScale = −0.8`.** Verified as *inverted* by measurement (hi>3k 4.8 % → 3.8 % as
   Presence goes 0 → 10); the magnitude is still a guess.
7. **Bassman `sagDepth 0.30 / sagTauMs 60`.** Hit a hard chord: duck, then bloom back over ~60 ms.
8. **The Class AB crossover knee** (`ampShapeRaw`, width 0.03 / dip 12 %) — confidence **L**, and it
   applies to four of the six amps. A faint grainy edge on note decays is right; buzzy is not.
9. **`insertionDB` per amp.** Now audible as *how hard the power stage is driven*, not as level
   (§3.7), so its effect is subtler than the table implies and worth an explicit A/B.

---

## 7. On-device (Simulator) check of the panel

The one part of this change no offline test covers is the zoomed-in control panel, so it was driven
by hand in the Simulator with a Katana in the rig:

- The panel renders **seven dials** — Gain, Bass, Mid, Treble, Presence, **Volume**, Master — and a
  strip of **three discrete selectors** below them: CHARACTER (Acoustic / Clean / Crunch / Lead /
  Brown), VARIATION (A / B), POWER (0.5 W / 50 W / 100 W), each with its current detent lit. Every
  other amp's panel is untouched, because the switch strip only appears when the item has discrete
  parameters.
- Tapping **Brown** and **0.5 W** moved the selection, persisted to `rig_state.json`
  (`"Character": 4, "Power": 0`, `catalogVersion` still **3**), and drove a live structural rebuild
  of the amp (profile 14 → 18) through the fade/park barrier with the engine running — no crash, no
  hang.
- One layout fix came out of that pass: the first cut stacked the three selectors as three rows,
  which in a landscape-only app squeezed the slider dock underneath to nothing. They now share one
  fixed-height strip, weighted by detent count so every button comes out the same size.

## 8. What I could not verify

- **No listening pass.** The Simulator does forward the Mac's microphone, so the engine can be
  engaged live — but this harness has no ears, and a subjective "does the JCM800 sound like a
  JCM800" judgement was not made. What is proved is that the amps are *measurably* different and
  that the differences sit where the profile says they should. To make the ear pass cheap, the suite
  now writes two A/B files to the app's Documents:
  `StreetRig_amp_ab.wav` (the six amps back to back on the same DI, same knobs, half a second apart)
  and `StreetRig_katana_ab.wav` (all ten Katana voicings). Pull them with
  `xcrun simctl get_app_container <sim> streetrig.StreetRig data`.
- **No real iRig DI levels.** Everything here is the bundled DI placeholder. Gain staging against a
  real pickup through a real interface is the thing the tuning table exists for.
- **Nothing on a physical device.** Simulator only; the live render-load read-out on hardware is
  still unmeasured for the profiled path.

---

## 9. What Phase B inherits

Nothing is blocked, and two seams were added ahead of it:

- **`AmpCabProcessor::processPreamp` / `processPowerAmp` / `processCab` are separate public entry
  points**, with `process()` composing them. That is precisely the split the mid-chain FX loop needs:
  Phase B runs `PedalChain::processSpan(splitPre, splitPost)` between the first two, which is where a
  real amp's loop sits — and why reverb that then passes through a saturating output stage compresses
  with the notes instead of floating above them.
- **`AmpProfile::neuralModel`** is a `const char *` slot on every profile, currently `nullptr`
  everywhere. A rights-cleared capture replaces the preamp cascade only; the profile's tone stack,
  power amp, OT rolloffs and cab pairing still apply, so a capture *upgrades* a profile rather than
  replacing it.

Still to do in Phase B, unchanged from §12: the `DelayPedal` / `ReverbPedal` engines and the
preallocated arena, `PedalChain::Type` 8 and 9, the three-span split, `Param3` / `Param4` on the AU
tree, and the Katana FX section wiring. The two Katana factory presets added here already round-trip
through `fullState`, so channel presets need no further schema work.

### Known gaps recorded, not silently absorbed

- **Cab inventory.** `kNumCabSlots` is 8 but only two IRs are bundled (assets may not be downloaded),
  so the six amps currently pair across slots 0 and 1. `ParameterMap.ampProfileCabSlot` carries the
  Phase A pairing; §3.4 of the research document carries the intended one. The amps still differ
  enormously — preamp, tone stack, power amp — they just share two boxes.
- **The JC-120's Bright switch.** One line when the product decision is made: give the profile
  `presenceHz 6000 / presenceScale ~0.7` and put `"Bright"` back in its knob list; the existing
  presence address and shelf do the rest, with no new DSP. (`ampBandAddress` would need `"Bright"`
  mapped to `SRParamAmpPresence`.)
- **`RigStore.catalogVersion` is still 3, deliberately.** Every new key is additive inside
  `GearItem.values` and defaults cleanly, and bumping it would make `RigStore.load` return `nil` for
  the player's saved rig and re-seed. The harness proves the defaults: a Katana carrying only the
  original six keys compiles to profile 14 (Crunch A) at 100 W and unity volume.

---
---

# Shared Time Blocks — Phase B Implementation Notes

**Status:** shipped, verified offline · **Date:** 2026-08-19 · **Scope:** Phase B of
`research/amp-emulation-approaches.md` §12 — the shared delay and reverb blocks, the preallocated
arena, the three-span FX loop, the Katana's FX section and its channel memories.

**The problem this closes.** `ParameterMap.pedalType` mapped `.delay` and `.reverb` to
`typeTransparent`, so five catalog pedals held their place in the chain and passed audio through
untouched: VOSS Digital Delay, DUNLAP ECHOPLEX, electro-harmonium MEMORY MAN, VOSS Reverb and
electro-harmonium HOLY GRAIL were mute decorations — two of them in the **seed rig**, which every
new player starts with. They are now audible, voiced as three different delay circuits and four
different reverb spaces, and the Katana's Booster / Mod / FX / Delay / Reverb blocks route through
the same engines rather than through a private copy inside the amp.

---

## 10. What shipped

### New files

| File | What it is |
|---|---|
| `StreetRigEngine/Audio/Pedals/TimeBlockSupport.hpp` | The vocabulary the two recirculating blocks share and nothing else needs: `sanitize` (the NaN/Inf/clamp gate every write into a feedback loop passes through), `flushDenormal`, linear + 4-point Hermite interpolation, a deterministic xorshift noise source, `nextPowerOfTwo` |
| `StreetRigEngine/Audio/Pedals/DelayPedal.hpp` / `.cpp` | One recirculating line, three circuits. **THE ONE AUDITABLE TABLE** for the family is `voiceFor()`, with §11.6's listening cue beside each value |
| `StreetRigEngine/Audio/Pedals/ReverbPedal.hpp` / `.cpp` | The Dattorro plate tank, four voicings. Its `voiceFor()` is the auditable table |
| `StreetRigEngine/Models/KatanaChannels.swift` | Channel memories: a `KatanaChannelStore` beside the AUv3's `.srpreset` directory, plus `RigStore.applyValues/saveKatanaChannel/recallKatanaChannel` |

### Changed — engine

| File | Change |
|---|---|
| `PedalChain.hpp` / `.cpp` | `Type` gained `Delay = 8`, `Reverb = 9`. **The arena**: one `std::vector<float>` sized in `prepare()`, carved into eight per-slot blocks, handed out by `configureSlot`. `setSplits/splitPre/splitPost` and `processSpan(buffer, n, ch, first, last)`; `process()` is now `processSpan(0, kMaxPedals)`. `reset()` clears the blocks of slots that are actually time-based, not the whole 8 MB |
| `StreetRigDSPKernel.h` / `.cpp` | New `SRKernelSetPedalSplits` and `SRKernelPedalArenaBytes`. `SRKernelProcess` composes **three spans** around the amp; `SRKernelBenchmarkFullNsPerSample` composes them identically, so the reported CPU is the shipping graph |
| `ParameterMap.swift` | `typeDelay`/`typeReverb`; `pedalType` maps `.delay`/`.reverb`; delay and reverb voicing ids + `pedalVoicing` branches; eight new curves and **all eight analytic inverses**; `pedalParams` cases; `pedalLinks(for:)` — the per-family automatable-knob table; the whole Katana FX section (`AmpFXSpan`, `AmpFXSlot`, `AmpFXBlockSpec`, `katanaFXBlocks`, `ampHasFXSection`, `ampFXSlots`) |
| `RigGraphCompiler.swift` | `RigDSPPlan` gained `splitPre`/`splitPost`. `compile` assembles PRE and MID lists, appends the amp's FX blocks into their spans, caps at eight slots and sets the splits. The signature grew `\|split:pre/post`. `applyStructure` calls `setPedalSplits` |
| `RigAUParameterBridge.swift` | The pedal loop is no longer `where pedal.category == .overdrive` with hard-coded knob names: it walks `ParameterMap.pedalLinks(for:)` and matches each DSP role against **the pedal's own knob list** — the pedal-side twin of Phase A §3.5. This fixed a live bug (below) |
| `StreetRigDSPUnit.swift` | `setPedalSplits`, `pedalArenaBytes`; `exposedPedalFields` grew `Param3`/`Param4` (tree 44 → 62) and the three existing fields widened to generic domains (below) |
| `Gear.swift` | `GearParameter` gained `group` and `shortName`. The Katana's `PedalSpec` branch appends the five FX blocks: a type selector (0 = Off), an On switch and the block's dial(s) |

### Changed — app

| File | Change |
|---|---|
| `ComponentDetailView.swift` | The lower pane became a **paged** dock for items with grouped controls: LEVELS / FX / CHANNELS. The FX page is a horizontally-scrolling card per block (type cycler, On switch, level); the CHANNELS page is four tap-to-recall / hold-to-store buttons. Fixed furniture is trimmed only for those items. **Every other amp's panel is byte-for-byte the layout it had** |
| `AmpModel3DView.swift` | `knobParamNames(for:)` skips grouped controls, so the 3D faceplate does not grow fifteen rotaries |
| `AudioEngineController+OfflineRender.swift` | The time-block suite (30 checks) plus `delayTimeSweepTest`, `reverbDenormalTest`, `katanaChannelRoundTrip`, `channelSwitchClickTest`, `auv3FXStateRoundTrip`, `latencyAndArenaProbe`, and the analysis helpers `allFinite` / `peakIn` / `zeroCrossHz` / `rt60` / `pluckThenSilence` |
| `AudioEngineController+VerifyAUv3.swift` | The bridge test now drives the pedal's OWN gain knob name instead of assuming "Drive" (see deviation 11.6) |

---

## 11. Deviations from the research document

Six, each with its reason and its measurement. Two are corrections to the document.

### 11.1 The EP-3 preamp is on the OUTPUT, and it is a mid peak, not a treble shelf

§5.2 lists the tape voicing's feedback-path colour as "`tanh` soft-clip at 0.85 + one-pole LP @
4 kHz + high shelf +3 dB @ 3 kHz (the EP-3 preamp)". Shipped with the preamp **outside** the loop
and **re-shaped**, for two measured reasons:

- **Inside the loop it cancels the thing it is next to.** A +3 dB shelf above 3 kHz applied once per
  pass very nearly undoes a 4 kHz one-pole applied once per pass. Measured: the tape voicing lost
  **19 %** of its energy above 2 kHz between repeat 1 and repeat 3, against digital's **17 %** — i.e.
  the two were indistinguishable on the document's own listening cue ("each repeat noticeably darker
  than the last"). The physics agrees with the ear: the *medium* colours every pass, the machine's
  *output amplifier* colours each repeat once. Record-side losses now compound; the preamp does not.
- **A treble shelf is the wrong shape for that amplifier.** With the shelf outside the loop the first
  repeat came out **brighter at 2 kHz than a DD-8's**, which is the opposite of every Echoplex ever
  made. What an EP-3 adds to a chain is midrange girth. Shipped as a peaking filter, 1.2 kHz, Q 0.7,
  +3 dB.

### 11.2 The tape roll-off is two poles at 4.5 kHz, not one at 4 kHz

Still §5.2. One pole at 4 kHz against the digital voicing's one pole at 8 kHz is ~2 dB per pass
across the band a listener judges "darker" by, and it measured as 0.3 pp — inside the noise. Tape's
HF loss is not first order (head-gap loss, playback-head response and self-erasure stack), so it
ships as two poles a little higher up. Measured after the change: **digital 22.4 % > tape 20.1 % >
BBD 13.2 %** of energy above 2 kHz on the first repeat, and **11.3 % / 19.8 % / 42.0 %** of that
energy lost between repeat 1 and repeat 3.

### 11.3 The reverb decay range is set by MEASURED RT60, not by the document's coefficients

§5.3 gives `Param0` = `0.30 + norm · 0.62` and says it produces "RT60 ≈ 0.4 s → 6 s". Those two
statements are inconsistent for Dattorro's published line lengths: the tank's loop is ~0.73 s with
`decay` applied twice per branch, so 0.92 is an RT60 near 15 s — "ringing forever", which §11.6's own
cue forbids. Shipped as **`0.10 + norm · 0.72`**, chosen from the arithmetic
(`RT60 = 43.5 / (80 · log₁₀(1/d))`) so the *musical contract* holds, and the tank is hard-clamped at
0.92 in C++ regardless of what arrives on the bus. Measured broadband: **Decay 2 → 0.88 s,
Decay 8 → 2.04 s** (damping shortens the measured figure against the pure-tank arithmetic).

### 11.4 Dattorro's line lengths are SCALED to the running sample rate

Not specified either way; many ports use the numbers unscaled. They are scaled by `sr / 29761`, so
the reverb sounds the same at 44.1, 48 and 96 kHz. Unscaled, the tank would be 60 % shorter at
48 kHz and its character would change with the player's audio interface, which is not a thing a
plate does. `sizeScale` per voicing (Room 0.55 → Hall 1.35) rides on the same multiply.

### 11.5 The exposed per-slot AU parameter domains had to become generic

§5.4 says only that `Param3`/`Param4` need adding. Adding them exposed an existing fault: the three
original fields were typed for the only family that existed when they were written
(`.linearGain` 0.8…25.6, `.hertz` 700…8500, `.linearGain` 0.1…2.0), and every other family that
reached the parameter tree was silently **clamped** — a 226 ms delay time arrived at the kernel as
25.6, an EQ's −12 dB as +0.8. The ranges are widened and the units dropped to `.generic`. Widening is
safe for saved host sessions in exactly the sense Phase A used for `cabSelect`: every previously
stored value is still in range, and the address, identifier and ordering are untouched.

`Param3` accepts **0**, which is the "use the circuit's own corner" sentinel a delay with no Tone
knob sends. That keeps the per-voicing feedback-filter corner in `DelayPedal::voiceFor` — where the
ear tuning happens — instead of duplicating it in Swift.

### 11.6 `RigAUParameterBridge` links the pedal's OWN knob names (a live bug, found by the harness)

Not specified, and required — the exact pedal-side twin of Phase A §3.5. `buildLinks` created links
named "Drive", "Tone" and "Level" for every `.overdrive` pedal, but a Tube Screamer's knobs are
**Overdrive**/Tone/Level, a Big Muff's are Sustain/Tone/Volume and a RAT's are
Distortion/Filter/Volume. `pushContinuousToParameters` reads `values[param] ?? 0`, so in the plugin
editor turning *any* knob pushed **drive = 0.8** for those models and the real gain knob was not
automatable at all. Links are now built from `ParameterMap.pedalLinks(for:)` matched against
`pedal.parameters`, so a role nothing matches gets no link.

`-VerifyAUv3` asserted the old behaviour, and its two failures are what surfaced this. The assertions
now drive the pedal's own gain knob and read **`slot-0 Overdrive knob → AUParameter 25.60 / 0.80`**
and **`automation 0.8 lin → knob 0.00`**. Automatable-knob count went 9 → 15 (amp 6 + TS 3 + delay 3
+ reverb 3).

### Plus three product decisions the document left open

- **§4.5 lists the Katana's Delay block as "Digital / Analog / Tape / Reverse".** Reverse is not
  shipped: it is a different algorithm (a windowed, back-to-front read), not a voicing of this one.
  The block offers Off / Digital / Analog / Tape.
- **Each block gets the hardware's SINGLE panel knob — except Delay, which gets two.** On the real
  amp, delay time is set by tap tempo; this app has no tap-tempo surface, so a delay with no time
  control would be unusable. Delay has Level and Time; every other block has Level, and everything
  deeper is a voicing constant.
- **§13 Q1 (channel count) is answered as four**, in one constant (`KatanaChannelStore.channelCount`).

---

## 12. The arena

```
kMaxPedals(8) × kMaxChannels(2) × blockFloats × 4 B
    blockFloats = nextPowerOfTwo(ceil(kMaxDelaySeconds(2.0) × sampleRate))

  44.1 kHz →  88 200 → 131 072 floats/ch →  8.0 MB
  48   kHz →  96 000 → 131 072 floats/ch →  8.0 MB   ← the shipping case
  96   kHz → 192 000 → 262 144 floats/ch → 16.0 MB
```

**Worst case at 48 kHz: 8 388 608 bytes, asserted by the harness against the kernel's own
`SRKernelPedalArenaBytes`.** One `std::vector<float>`, one owner, allocated in
`PedalChain::prepare()` and **never resized** — `configureSlot` only ever hands out a pointer. A slot
is a delay *or* a reverb, never both, so one block serves either; the reverb tank uses ~70 k of its
131 072 floats at 48 kHz (thirteen power-of-two sub-lines, so every pointer wraps with a mask instead
of a modulo). There is no cap on concurrent time-based blocks and therefore no failure mode: all
eight slots can be delays.

**The publish discipline.** A slot can *become* a delay while the engine is live. `setBuffer`
un-publishes the old span, zeroes the new one, then publishes the pointer with a
`memory_order_release` store; `process()` acquires it and passes audio through unchanged on nullptr.
That is `AmpCabProcessor::installNeuralModel`'s pattern with its second half removed on purpose:
the retire slot exists to defer *freeing*, and nothing here is ever freed while the chain lives, so
there is nothing to retire.

---

## 13. Verification

Offline harness, real AU graph, iOS 26.5 Simulator. **Every suite green in BOTH Debug and Release**,
including the six that existed before this work:

```
OVERALL       : PASS      (prompt 002 — neural amp + cabinet IR)
PROMPT 003 OVERALL: PASS  (full compiled-rig chain)
PEDAL FAMILIES OVERALL: PASS
SIGNAL METERS OVERALL: PASS
AR FOOTSWITCH OVERALL: PASS
AMP PROFILES OVERALL: PASS
TIME BLOCKS OVERALL: PASS       ← new, 30 checks
LEGACY REFERENCE OVERALL: PASS
```

### The 30 time-block checks

```
  delay: repeats land at the set time                    PASS   (offsets from k·15360 samples: 0, 0, 1, 1; peaks 0.5179 → 0.0576)
  delay: feedback sets the decay rate                    PASS   (repeat2/repeat1 = 0.431 at fb 0.66 vs 0.185 at fb 0.28)
  delay voicings differ in repeat BANDWIDTH              PASS   (digital 22.4% > tape 20.1% > BBD 13.2% (record-side LP 8k / 4k / 2.5k×2))
  …and in PER-REPEAT degradation                         PASS   (hi>2k lost from repeat 1 to 3: digital 11.3%, tape 19.8%, BBD 42.0%)
  …and are not each other (level-matched)                PASS   (residual dig/tape 124%, tape/BBD 82%)
  digital time change is CLICK-FREE                      PASS   (max |Δsample| 0.0325 across the change vs 0.0382 steady (×0.85))
  digital time change does NOT bend pitch                PASS   (repeats stay at 460 Hz (2.2% drift) — the crossfade preserves pitch)
  tape time change DOES bend pitch (opposite, on purpose PASS   (repeats glide 447 Hz → 760 Hz (70.0%) — the read pointer slews)
  reverb is audible and its tail decays                  PASS   (tail peak 0.4909, first 0.5 s RMS -14.1 → last 0.5 s RMS -125.6)
  reverb RT60 is in the specified range and tracks Decay PASS   (Decay 2 → 0.88 s, Decay 8 → 2.04 s (spec: ~0.4 s … ~6 s))
  CPU returns to baseline after the tail decays          PASS   (49.3 µs → 42.8 µs per block (×0.87); a denormal stall is 10–100×)
  …and the decayed tank is EXACTLY zero, not merely smal PASS   (every sample of the last block is 0.0 — states are flushed at 1e-20, far above the 1.18e-38 denormal threshold)
  max feedback does not run away                         PASS   (peak 1.390, finite, RMS -6.2 → -17.3 over the ring-out)
  a feedback coefficient of 1.6 is clamped, not obeyed   PASS   (peak 1.390 and still decaying with fb pushed to 1.6)
  a NaN injected into the input does not poison the loop PASS   (delay and reverb both finite over the second half, after 8 NaN input samples)
  all five formerly-silent pedals are audible            PASS   (VOSS Digital Delay Δ-15.4 · DUNLAP ECHOPLEX Δ-18.2 · electro-harmonium MEMO Δ-15.2 · VOSS Reverb Δ-13.8 · electro-harmonium HOLY Δ-13.8)
  …and the models are voiced distinctly                  PASS   (DD/EP 50%, EP/MM 48%, RV/Grail 97% residual)
  Booster + Mod route PRE-preamp; FX/Delay/Reverb route  PASS   (PRE [1, 7] (drive 1, mod 7); MID [8, 9] (delay 8, reverb 9))
  the same block sounds different in each span           PASS   (pre-preamp vs loop 76%, loop vs post-cab 28% (level-matched))
  a block's ON/OFF does NOT move the topology signature  PASS   (stomping a block takes the same lock-free path an AR footswitch does)
  a block's LEVEL knob does not move it either           PASS   (knob turns never rebuild the chain)
  a block's TYPE selection IS structural                 PASS   (changing type re-voices a slot; turning a block Off frees it)
  a channel memory stores and recalls the whole panel    PASS   (CH1 exact, CH2 exact, cross-amp recall refused: true, and the two compile to different chains: true)
  switching channels mid-render is click-free            PASS   (max |Δsample| 0.3528 across the switch vs 0.4371 steady (×0.81))
  the FX panel survives an AUv3 fullState round-trip     PASS   (restored profile 17 (Katana Lead B), FX blocks ["Delay/1", "Reverb/3"] — tape delay + hall reverb, both still in the loop span)
  neither block adds reported latency                    PASS   (cab convolver 128 samples is still the whole of it — both blocks sum a wet send against an UNDELAYED dry path, so their group delay at DC is zero)
  the host-reported latency matches the composed total   PASS   (AUAudioUnit.latency 2.667 ms == 128 samples @ 48000 Hz)
  the arena is the documented worst case, allocated once PASS   (8388608 bytes = 8 slots × 2 ch × 131072 floats × 4 B (8.0 MB) @ 48 kHz)
  every new curve round-trips knob → bus → knob          PASS   (max error 1.00e-06 (worst: reverbDecay))
  a rig saved before the FX section loads unchanged      PASS   (no FX keys → 0 slots, split 0/0 — every block defaults to Off, so the chain is the one it always was)
```

### The Legacy null test survives the three-span restructure — bit-exact

Phase A's baseline WAV did not survive the Simulator container being reinstalled, so the fixed pole
was rebuilt from source: the working tree was copied, `SRKernelProcess` was patched back to the
**pre-Phase-B single-call composition** (`pedals.process` → `processor.process`), that build's legacy
reference was captured, and the shipping build was nulled against it.

```
  baseline null test: BIT-EXACT  (103200 samples compared, max |Δ| 0.000e+00, null RMS -180.0 dBFS)
```

Not "below a threshold" — zero, over every one of 103 200 samples, in **both Debug and Release**.
Splitting one `process()` call into three spans around it changed nothing about the amp.

### The AUv3 extension, out of process

`-VerifyAUv3` green end to end with the widened parameter domains and the new links:

```
  OUT-OF-PROCESS render null vs in-process oracle : PASS  (null -180.0 dBFS @ lag 0)
  latency > 0 == cabLatency/sr             PASS   (latency 0.002667 s, expected 0.002667 s)
  factoryPresets non-empty                 PASS   (5 presets)
  fullState round-trip nulls (whole rig)   PASS   (null -180.0 dBFS @ lag 0)
  srds out-of-process param consistency    PASS
  bridge: automatable knobs mapped         PASS   (count 15; amp Marswell JCM800 2203, pedals 3)
  UI→host: slot-0 Overdrive knob → AUParameter records the move   PASS   (knob10→25.60, knob0→0.80)
  host→UI: automation (addr 103) moves the Overdrive knob         PASS   (0.8 lin → knob 0.00)
  no feedback oscillation                  PASS
  PHASE 3 (Simulator gates) : PASS
  PHASE 4 (Simulator gates) : PASS
```

### Builds

`xcodebuild`, DerivedData in a scratch directory, iOS 26.5 Simulator. **`StreetRig`,
`StreetRig AUv3` and `StreetRigEngine` all build clean in Debug and Release**, and the Release
`StreetRig.app` embeds `StreetRig AUv3.appex`.

---

## 14. CPU — measured, with the whole panel lit

Debug −O0 first, because that is the number Phase A reported and the only honest comparison:

| Configuration | Debug ns/sample | Debug % | Release ns/sample | Release % |
|---|---|---|---|---|
| Katana Crunch A, no FX | 1390.9 | **6.68 %** | 311.9 | **1.50 %** |
| + Delay block only | 1409.7 | 6.77 % | 305.9 | 1.47 % |
| + Reverb block only | 1637.8 | 7.86 % | 329.1 | 1.58 % |
| **FULL FX panel — all five blocks** | **2251.1** | **10.81 %** | **456.9** | **2.19 %** |

Per block, in Debug: **delay ≈ +0.1 pp, reverb ≈ +1.2 pp**, the whole five-block panel
**≈ +4.1 pp** (the Booster and the Mod between them account for the rest). Debug −O0 carries a few
tenths of run-to-run spread — across four runs the delay column moved between 6.77 % and 6.95 %, i.e.
the delay's own cost is at the edge of what this measurement can resolve, which is itself the answer.
§10 estimated +0.15…0.25 pp for a delay and +0.2…0.3 pp for the reverb: the delay lands inside its
estimate even at −O0, and the **reverb is ~4× the estimate in Debug** — Dattorro's thirteen
interpolated line reads and four all-pass recursions do not vectorize, and −O0 pays for every one of
them. In Release the same block costs **+0.08 pp**, comfortably inside what §10 predicted.

The seed rig's own full-board figure moved too, and for a real reason: the seed rig ships a delay and
a reverb on the board, and until this change **they were silent**.

| | ns/sample | µs / 128-frame block | % of the ~2667 µs budget |
|---|---|---|---|
| Phase A (delay + reverb transparent) | 1742–1776 | 223.0–227.4 | 8.3 – 8.5 % |
| **Phase B (both audible), Debug** | 2095.1 | 268.2 | **10.06 %** |
| **Phase B (both audible), Release** | 400.4 | 51.2 | **1.92 %** |

**This is over §10's ~7.74 % reference, and it is reported as over rather than reframed.** What it is
not is a reason to take a fallback. §10's fallback list exists "if it does not fit", and the shipping
configuration is Release, where the worst case in the whole document — a Katana with all five FX
blocks live — is **2.19 % of the buffer deadline, i.e. ~98 % headroom**, and the seed rig with its
delay and reverb finally audible is **1.92 %**. The Debug figure is a −O0
artefact of the measurement, not a cost a player pays, and every suite including the bit-exact Legacy
null re-runs green in Release, so the Release numbers are not an artefact of optimized floating point
either. §10's step 1 (the Padé `tanh`) remains on the shelf, unused, for the same reason Phase A left
it there: it would downgrade the bit-exact null test to a threshold test, and nothing needs it.

**Denormals, measured rather than asserted.** The probe renders a burst into a reverb, times 400
blocks with the tail live, renders ~10 s of silence, and times 400 more. Debug **49.2 µs → 42.7 µs
(×0.87)**, Release **5.1 µs → 5.0 µs (×0.98)** — a denormal stall is 10–100×. The stronger form of
the same check: after the tail decays the tank's output is **exactly 0.0f**, because every recursive
state is flushed at 1e-20, twenty-two orders of magnitude above the 1.18e-38 denormal threshold.

---

## 15. The values most in need of ear-tuning

Spend the iRig session in this order. Everything below lives in `DelayPedal::voiceFor` /
`ReverbPedal::voiceFor` with its cue in the comment beside it, or in `ParameterMap`'s curves.

1. **Tape's two-pole 4.5 kHz roll-off and the 1.2 kHz / +3 dB output preamp** (deviations 11.1, 11.2).
   Confidence **L** — both are corrections derived from measurement against a cue, not from a
   measured EP-3. Repeat six should be a soft dark ghost; an Echoplex in the chain should thicken
   the note even with Sustain at 0.
2. **`reverbDecay` = `0.10 + norm·0.72`** (deviation 11.3). Decay 10 must be a long wash that still
   ends. If it rings past ten seconds, lower the top; if Decay 10 sounds like a room, raise it.
3. **BBD `compandAmount 0.60` and `noiseFloor 0.00025`.** The pumping IS the analog-delay sound, and
   the hiss should breathe with it. Squashy and seasick → lower the compand; sterile → raise it.
4. **The spring voicing's `dispersion 0.62` over twelve all-pass sections.** A picked note should
   "sproing", not just echo. No boing → raise toward 0.75, or accept that twelve sections is a
   flavour and a real spring needs a hundred (see the gaps below).
5. **Delay-time slew 100 ms / crossfade 30 ms** (`DelayPedal::prepare`). Turn Time with repeats
   running: the tape voicing should glide musically and the digital one should be silent about it.
6. **The one-knob FX block mappings** in `ParameterMap.ampFXSlots` — the Booster's fixed tone/level,
   the Mod's fixed rate, the Delay block's fixed feedback, the per-mode reverb decays. These are the
   difference between "the Katana's knob does something sensible" and "the Katana's knob does what
   the hardware's does", and only an A/B settles them.
7. **Reverb `bandwidth` per voicing** (Spring 0.72 vs Plate 0.9995). Tone 10 on the plate must be
   bright with no metallic ring; if it rings, the tank all-pass modulation is not running.

---

## 16. What I could not verify

- **No listening pass.** The Simulator forwards the Mac's microphone so the engine can be engaged
  live, but this harness has no ears. What is proved is that the repeats land where the Time knob
  says, that the three delay circuits are measurably three circuits, that the tail decays like a
  reverb and that nothing runs away. Whether an Echoplex sounds like an Echoplex needs an iRig, a
  guitar and real speakers — as do all seven rows in §15.
- **Nothing on a physical device.** Simulator only. The 8 MB arena in particular is an allocation an
  older device's memory pressure has never been asked about here, and the live render-load read-out
  on hardware is unmeasured.
- **No DAW.** `-VerifyAUv3` exercises the appex out of process, but a real host's automation lanes
  against the widened `Param0…Param2` domains (deviation 11.5) have not been driven.

---

## 17. What is still deferred

| Deferred | Why |
|---|---|
| **Pitch** (OC-5, PS-6 Harmonist, micro POG, WHAMMY, and the Katana's Octave / Harmonist / Defretter / Ring Mod / Humanizer) | Explicitly out of scope, and the only family that genuinely adds **latency** — a phase vocoder needs ~50 ms of history, which is a live-monitoring product decision, not a DSP one. Still `typeTransparent`; `research/pedal-emulation-approaches.md` §7 Phase 4 |
| **Tuner and looper** | UI features with no tone. Still `typeTransparent` |
| **A true spring model** | The Holy Grail voicing ships twelve first-order all-passes, which is a dispersion *flavour*; a real spring's chirp needs a hundred-plus sections or a dedicated chirp filter. Labelled as such in the header |
| **Reverse delay** | A different algorithm, not a voicing (deviation, §11) |
| **The Katana's "post-reverb loop" as a user control** | The POST span exists, is exercised by the routing check and measurably differs — but nothing in the UI moves a block into it. §13 Q9 flags exposing the three-span routing as an undecided product decision |
| **Slot overflow surfacing** | Eight slots. A full pedalboard plus a fully-loaded FX panel can ask for more; the player's own board wins and the amp's blocks fill what is left, in panel order. The drop is deterministic but **silent** — nothing tells the player a block did not fit |
| **A stereo reverb** | Every pedal engine in this app is per-channel with no cross-channel state, deliberately (a stereo path must never crosstalk). The tank is therefore mono-in/mono-out per channel, using Dattorro's left tap set |
