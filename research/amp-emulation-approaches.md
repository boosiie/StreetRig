# Making Every Amp Sound Like a Different Amp — Architecture & Katana Specification

**Status:** decision-ready · **Date:** 2026-08-19 · **Scope:** the per-amp voicing architecture for
StreetRig's DSP engine (`StreetRigEngine/Audio/`), with the **VOSS Katana 100** specified in full as
both the first profile and the template every other amp is expressed in.

> Companion to `research/pedal-emulation-approaches.md` (the same problem for the 47 pedals) and
> `research/pedal-tone-reference.md` (its per-model number table). This document is the amp-side
> equivalent of both: §2–§4 are the architecture and the numbers, §11 is the per-number tuning
> contract. It writes no DSP code.

**The problem, stated honestly.** Today every amp in StreetRig sounds identical. `AnalogAmp` is one
fixed voicing (95 Hz high-pass → asymmetric `tanh` at 4× oversampling → 8 kHz low-pass) and
`ToneStack` is one fixed 4-band EQ with hard-coded centres (100 / 650 / 3200 / 6000 Hz). The amp's
*name* is read in exactly two places — `ParameterMap.cabSlot(name:)` picks one of two cab IRs, and
`ParameterMap.ampUsesNeural(name:)` returns a hard-coded `true`. A Marswell JCM800, a Fandor Twin
Reverb, a Volt AC30 and a Rolund JC-120 are, in the DSP, the same amp with different artwork.

**Direction chosen (decided by the project owner — recorded, not re-litigated):**

1. **Algorithmic, circuit-informed modeling.** Generalize `AnalogAmp` into a data-driven per-amp
   voicing built from public schematic knowledge and known circuit topology — *not* neural capture.
   The neural rail exists (`Neural/NeuralAmpModel`, RTNeural-style `SimpleRNN` LSTM JSON) but ships
   only a synthesized placeholder (`StreetRigEngine/Audio/Resources/StreetRig_amp_placeholder.json`),
   real captures cannot be fetched, and `research/pedal-emulation-approaches.md` §5 already chose
   circuit modeling for the analogous gain-stage problem. **The neural rail is preserved as a slot
   inside the profile** (`AmpProfile::neuralModel`) so a rights-cleared capture can later ride the
   same architecture without rework — see §2.6.
2. **Full Katana panel scope** — five characters, the variation switch, 3-band EQ + presence,
   gain / volume / master, 0.5 W / 50 W / 100 W power control, the Booster / Mod / FX / Delay /
   Reverb section, and channel presets.
3. **Delay and reverb ship as shared `PedalChain` blocks**, not Katana-internal FX. They also
   unblock the five currently-silent catalog pedals (VOSS Digital Delay, DUNLAP ECHOPLEX,
   electro-harmonium MEMORY MAN, VOSS Reverb, electro-harmonium HOLY GRAIL). The Katana's FX section
   *routes through* those shared blocks.
4. **Verification is ear-tuning on real hardware** through an iRig. Every hard-coded number
   therefore ships with a listening cue and a confidence flag — §11.

**The tension, resolved up front.** The Katana is itself a digital modeling amp: simulating it is
simulating a simulator. Its "Brown" is Boss's model of a modded Marshall; its "Clean" is a
Roland/JC-flavoured clean. **This is an asset.** It means the Katana's five characters are a natural
stress test of the schema: each character must be expressible as a profile in *exactly* the same
schema a standalone Marshall or Fender profile uses. §4 does that — all ten Katana character ×
variation voicings are ordinary `AmpProfile` rows sitting in the same table as the JCM800 and the
Twin. **If a character had needed a special case the schema could not express, the schema would be
wrong.** Two came close and both were absorbed by adding one general field each: the Acoustic
character's speakerless voicing became `AmpProfile::bypassCab`, and the Vox Cut control (a knob that
works *backwards*) became a negative `ToneBand::rangeScale`. Both fields are now available to every
amp.

---

## TL;DR — the recommended path

1. **An amp is not one nonlinearity. It is five serial subsystems, and today we model one and a
   half.** Preamp gain staging (N cascaded stages, each with its own coupling/cathode/Miller
   filtering) → tone stack (a *passive interacting network*, not a flat EQ) → power amp (headroom,
   sag, negative feedback, output-stage clipping) → output transformer → cabinet. StreetRig has one
   preamp stage, an idealized flat-at-noon tone stack, no power amp, no transformer, and a cab IR.
   §1 grounds each subsystem in circuit reality and states what the first pass should model.
2. **The single highest-value change is the tone stack's `noonDB`.** A real passive TMB stack is
   *not* flat with the knobs at noon — a Fender scoops ~11 dB at ~400 Hz, a Marshall ~7 dB at
   ~650 Hz, a Vox barely scoops at all and is mid-*forward*. StreetRig's `ToneStack` is flat at
   noon for every amp, which is precisely why they all sound the same even before the gain stages
   are considered. One new field per band fixes the largest audible gap for almost no CPU.
3. **The deliverable is `struct AmpProfile`** (§2) — a `constexpr`-friendly POD resolved once at
   setup time, the whole-amp analogue of `DrivePedal::Voice`, with a `profileFor(int)` table that is
   the exact shape of `DrivePedal::voiceFor(int)`. No per-amp subclasses, no virtual dispatch, no
   audio-thread allocation. Selected from a catalog name by `ParameterMap.ampProfile(...)`, mirroring
   `ParameterMap.pedalVoicing(name:category:)`. `AmpVoicing::Legacy = 0` reproduces today's voicing
   **exactly**, and any amp not in the table resolves to it — that is the back-compat guarantee.
4. **The schema is proved on six catalog amps with concrete numbers** (§3): `Marswell JCM800 2203`,
   `Fandor Twin Reverb`, `Volt AC30`, `Rolund JC-120 Jazz Chorus`, `Fandor Bassman '59`, and the ten
   `VOSS Katana 100` voicings. No Katana-specific special cases exist anywhere in the schema.
5. **Keep one oversampled region, add one small one.** The preamp cascade widens inside `AnalogAmp`'s
   existing 4× region (from one waveshaper to N stages). The tone stack stays exactly where it is, at
   base rate, with its coefficient double-buffer untouched — only the *design inputs* become
   profile-driven. The power amp gets its own cheap **2×** region. This is the minimum-diff route
   through code that already works.
6. **Per-amp voicing is very likely CPU-negative, not positive** (§10). Profiled amps turn the
   neural rail *off* (`ampUsesNeural` returns false when a profile exists), and RealtimeSafety.md
   records that the LSTM forward pass dominates the ≈5.7 % amp→cab cost. Removing ~4–5 % of LSTM and
   adding ~2–3 % of profile chain lands the full Katana panel comfortably inside the ~7.74 %
   full-board budget — probably below it.
7. **Structural vs continuous, decided per control** (§9.2). Character and Variation are structural
   (they redesign filters → fade/park rebuild). **Power is continuous** — it maps to four smoothly
   interpolatable scalars, so switching 100 W → 0.5 W must never click. Gain/EQ/Volume/Master stay
   continuous, as today. The signature grows the profile id and the FX split points, and
   deliberately does **not** grow the power setting.
8. **Delay and reverb are two new `PedalChain::Type` values (8, 9) drawing from one preallocated
   arena** (§5). Reverb is a **Dattorro plate** — chosen because it is a published topology with
   known-good constants, so the implementation is transcription rather than invention, which is this
   document's whole purpose. Neither adds reported latency; the cab convolver's 128 samples stays
   the only latency in the graph.
9. **Ship in two phases** (§12). **Phase A** (prompt 002) is the profile architecture + Katana core
   (characters, variation, EQ, power amp) and is independently shippable: on its own it makes the six
   catalog amps measurably and audibly different. **Phase B** (prompt 003) is the shared delay +
   reverb blocks, the Katana FX section and presets.

---

## 1. What actually makes two guitar amps sound different

Adjectives ("warm", "chimey") are downstream of five physical subsystems. Each row below states what
the subsystem is, why it separates real amps, whether StreetRig models it today, whether Phase A
should, and roughly what it costs.

| # | Subsystem | Models it today? | Phase A? | CPU cost (per sample, per channel) |
|---|---|---|---|---|
| 1 | Preamp gain staging (N cascaded stages, interstage filtering) | ⚠️ one stage, no interstage filters | ✅ yes — the core of the change | ~12 flops + 1 waveshape per stage, ×4 (oversampled). 2–4 stages typical |
| 2 | Tone-stack topology, `noonDB` and interaction | ⚠️ fixed 4 bands, flat at noon, no interaction | ✅ yes — **highest value per flop** | **zero added** (same 4 biquads; only the coefficient *design* changes) |
| 3 | Power amp: headroom, sag, NFB, output-stage clip | ❌ not modeled at all | ✅ yes | ~35 flops + 1 waveshape, ×2 (2× oversampled) |
| 4 | Output transformer / speaker damping | ❌ not modeled | ⚠️ partial — two first-order rolloffs; frequency-dependent damping deferred | ~6 flops |
| 5 | Cabinet | ✅ partitioned-FFT IR convolver | ✅ unchanged; grow the slot count | unchanged (< 0.2 % measured) |

### 1.1 Preamp gain staging — why a JCM800 is tight and a Twin is loud-and-clean

A waveshaper's *character* is set less by its transfer curve than by **what reaches it**. Between two
cascaded valve stages sit three first-order filters, and they are the reason two amps with the same
clipping curve sound nothing alike:

- **The coupling capacitor + next grid leak** form a high-pass. Small coupling caps (Marshall
  0.0022 µF in the cascade) shave bass *before* the next stage distorts, so lows stay articulate under
  gain. Big caps (Fender 0.1 µF) pass everything, so the whole spectrum distorts together and gets
  flubby — which is why Fenders are voiced not to distort at all.
- **The cathode-bypass network** is the differentiator most models omit. A fully bypassed cathode
  (Fender's 1.5 k + 25 µF ≈ 4 Hz corner) amplifies the entire band flat. A *partially* bypassed
  cathode (Marshall's 2.7 k + 0.68 µF) is a **shelf**: the corner is not `1/(2πR_k C_k)` but
  `1/(2π (R_k ∥ 1/g_m) C_k)`, which for a 12AX7 (`1/g_m ≈ 600 Ω`) lands near **480 Hz, lifting
  roughly +8 dB above it**. Everything below 480 Hz gets ~8 dB *less* gain into the next stage. That
  single shelf is most of the "crispy-crunchy" Marshall high-treble character — and StreetRig models
  none of it today.
- **The Miller pole** (stage output low-pass, ~15–25 kHz) rolls the top before the next stage's clip,
  keeping cascaded gain from turning into fizz.

**Phase A models all three as first-order filters, because all three are first-order in the real
circuit.** Using biquads here would cost 3× for no extra truth. This is a deliberate departure from
`DrivePedal`, which uses biquads because its pre/post mid bumps genuinely are resonant.

### 1.2 Tone stack — the real differentiator, and the one currently wrong

Fender, Marshall and Vox all use the same **TMB** network Fender shipped in the 1957 5F6-A Bassman.
They differ in component values, and those values move three things that matter:

| | Slope resistor | Mid pot | Mid-notch centre | Scoop at noon | Character |
|---|---|---|---|---|---|
| **Fender** (AB763 / 5F6-A) | 100 k | 10 k (blackface) / 250 k (tweed) | **~400 Hz** | **deep** | scooped, big clean headroom |
| **Marshall** (JTM45 → JCM800) | **33 k** | 25 k | **~650–700 Hz** | shallow | mid-forward, "present" |
| **Vox** (AC30 top boost) | — (2-band + post-PI Cut) | none | ~700 Hz nominal | **none — mid-forward** | chime; the Cut control works *backwards* |

Three consequences for the schema:

1. **A passive stack is not flat at noon.** It is a fixed scoop plus a large insertion loss (roughly
   −12 to −16 dB, recovered by the following stage). `ToneStack` today is flat at noon for every amp.
   **`ToneBand::noonDB` is the field that fixes this**, and it is the cheapest large win available.
2. **The controls interact.** On a Fender, turning Bass up *deepens* the mid notch, because the mid
   pot's resistance below its wiper is added to the treble filter's resistance. This is captured by
   one scalar, `ToneStackVoicing::bassEatsMid`, applied when coefficients are recomputed — i.e. on the
   main thread, at **zero audio-thread cost**.
3. **A knob can run backwards.** The Vox Cut attenuates treble as you turn it *up*. Expressed as a
   negative `ToneBand::rangeScale`, with no special case.

We keep the idealized shelf/peak/shelf/shelf realization (four RBJ biquads) rather than digitizing
the 3rd-order analog transfer function via bilinear transform (the Yeh/Smith CCRMA approach). The
reasons: the existing double-buffered coefficient hand-off in `ToneStack` already works and is
RT-safe; four parametric bands with per-amp centres, Qs, ranges, noon offsets and one interaction
term capture the *audible* differences; and the exact-network route would need per-amp component
values we cannot verify to the precision it demands. Recorded as a known approximation, not an
oversight — §13 Open Question 7.

### 1.3 Power amp — and why presence is not an EQ band

Four behaviours, all currently absent:

- **Headroom / output-stage clipping.** Where the output valves run out of swing. A Twin's 6L6 pair
  with a stiff supply has enormous headroom; an AC30's cathode-biased EL84 quartet runs out early and
  *that* is the AC30. Modeled as `PowerAmpVoicing::headroom` — the linear level at which the output
  stage begins to clip — plus a clip family (`ClassAB` symmetric with a crossover knee, `ClassA`
  asymmetric and early, `SolidState` hard, `Clean` bypassed).
- **Sag.** The supply droops under load and recovers with a time constant, so a hard chord ducks and
  blooms back. Tube-rectified amps (Bassman '59, GZ34) sag hard; solid-state-rectified amps (Twin)
  barely do; the JC-120 does not at all. Modeled as an envelope follower reducing `headroom`:
  `sagDepth` (0–1) and `sagTauMs`. Five flops.
- **The negative-feedback loop.** A global NFB loop from the output transformer back to the phase
  inverter reduces gain, tightens the low end and *darkens* the top. Marshall and Fender use it
  heavily; **the AC30 has none**, which is a large part of why it feels loose and touch-responsive.
  Modeled as a static shelf `nfbHz` / `nfbDB` (negative dB = more feedback = tighter and darker),
  with `nfbDB = 0` meaning no NFB at all.
- **Presence.** In a real amp presence is **not an EQ band** — it is a control *inside the NFB loop*
  that shunts a portion of the feedback signal to ground, so the frequencies it removes from the
  feedback come back as *increased gain*. StreetRig models it as a high shelf.

  **Decision: keep the high-shelf approximation, and say why.** A frequency-selective reduction of
  negative feedback is, to first order, a frequency-selective gain increase — a high shelf. The two
  behaviours the shelf misses are (a) presence also loosens damping in that band, and (b) at high
  presence with the amp clipping, the extra loop gain interacts with the output-stage nonlinearity.
  (a) is folded into the OT/damping rolloffs; (b) matters only at extremes. A true loop model would
  need a delay-free feedback path around a nonlinearity — an implicit solve on the audio thread,
  which is the wrong trade for the audible gain. What *does* change is that presence becomes
  **per-amp**: its corner (`presenceHz`), its range (`presenceScale`), and its very existence
  (`presenceScale = 0` — the JC-120 has no presence control) now come from the profile instead of
  being hard-coded at 6 kHz / ±9 dB for everything.

- **Class A vs Class AB.** Class A (AC30) compresses early and asymmetrically, generating even
  harmonics; Class AB (Marshall, Fender) stays linear longer, then clips symmetrically with a
  crossover artefact. Captured by `PowerAmpVoicing::clip` + `asym` + `headroom` together, not by a
  separate flag.

### 1.4 Output transformer / speaker interaction

A real OT is a bandpass with load-dependent behaviour: it rolls off below ~60–80 Hz and above
~8–11 kHz, and its LF response *depends on the speaker's impedance curve*, which is what makes a
cranked amp "bloom". Phase A models the two rolloffs (`otLowHz`, `otHighHz`) as first-order filters —
six flops, and enough to separate a small EL84 OT (80 Hz / 8 kHz) from a big 6L6 OT (45 Hz / 11 kHz)
from the JC-120's transformerless direct-coupled output (30 Hz / 14 kHz). **The frequency-dependent
damping — the true bloom — is deliberately deferred**; it needs a speaker impedance model in the
feedback path and belongs with the cab work, not the amp work. Recorded in §12 as a Phase C item.

### 1.5 Cabinet — and the IR slot budget

Handled correctly today by `CabinetConvolver` (uniformly-partitioned overlap-add on vDSP,
`kPartition = 128`, up to 8192 taps, 128 samples of latency). The problem is **inventory, not
algorithm**: `AmpCabProcessor::kNumCabSlots = 4` and only **two** IRs ship
(`cab_v30_4x12.wav`, `cab_greenback_1x12.wav`), loaded into slots 0 and 1 by
`StreetRigDSPUnit.loadToneAssets`.

Six amps want six distinct boxes (4×12 V30, 2×12 alnico, 2×12 Jensen, 4×10 tweed, 1×12 JC, 1×12
Katana). **Four slots is not enough — grow `kNumCabSlots` to 8.** The cost is four extra empty
`std::vector<float>` members (≈96 bytes); the IRs themselves are not bundled by this work (the
constraint forbids downloading assets), so slots 2–7 ship **empty**, and an empty slot installs a
unit impulse, i.e. a transparent cab — already the behaviour of `AmpCabProcessor::setActiveCabSlot`.
Phase A therefore pairs the six amps across the *two* IRs we actually have (§3.4) and records the
intended pairing for when more arrive.

One host-visible consequence: `cabSelect`'s `AUParameter` range is currently `0…3`. **Widening a max
is safe** for already-saved host sessions (every previously stored value 0–3 remains in range);
narrowing would not be. Noted in §7.9.

---

## 2. The profile schema — the actual deliverable

### 2.1 Design constraints, and how each is met

| Constraint (from `RealtimeSafety.md` and the existing code) | How the schema meets it |
|---|---|
| Pure data, `constexpr`-friendly POD | Plain structs of `double`/`float`/`int`/`bool`/`const char*`. No virtuals, no containers, no constructors that allocate |
| Resolved at setup time | `AmpCabProcessor::configureAmp(int)` runs on the setup thread inside the reconfigure barrier, exactly as `PedalChain::configureSlot` does |
| No allocation / locks / I/O in `process()` | The profile only *designs coefficients* and sets scalars into preallocated per-channel state. Same pattern as `DrivePedal::configure` |
| Expressible from a name | `ParameterMap.ampProfile(name:values:)`, mirroring `ParameterMap.pedalVoicing(name:category:)` |
| Swift and C++ enums in lockstep | `AmpVoicing` (C++) ↔ `ParameterMap.amp*` (Swift), the same discipline as `DrivePedal::Voicing` ↔ `ParameterMap.voice*` |
| Backward compatible | `AmpVoicing::Legacy = 0` reproduces today's voicing bit-for-bit; unknown names resolve to it |

### 2.2 The structures

Proposed file: `StreetRigEngine/Audio/AmpProfile.hpp` / `.cpp`, included by `AnalogAmp.hpp` the way
`DrivePedal.hpp` includes `AnalogAmp.hpp` for `Biquad`.

```cpp
namespace streetrig {

/// Waveshaper families available to an amp stage. Deliberately a separate enum
/// from DrivePedal::Clip: the amp side needs Clean (bypass the nonlinearity
/// entirely) and the two output-stage families.
enum class AmpClip : int {
    Clean      = 0,  ///< no nonlinearity at all — acoustic voicing, JC-120 headroom
    Triode     = 1,  ///< asymmetric tanh — the preamp valve
    Pentode    = 2,  ///< harder knee, more odd harmonics — EL84/EL34 output valve
    ClassAB    = 3,  ///< symmetric push-pull with a crossover knee
    SolidState = 4   ///< hard clip — JC-120 and the Katana power section
};

enum class ToneShape : int { LowShelf = 0, Peak = 1, HighShelf = 2 };

/// One cascaded preamp stage. Every filter here is FIRST ORDER because every one
/// of them is first order in the real circuit (coupling cap × grid leak, cathode
/// bypass RC, Miller pole). Biquads would cost 3× for no extra truth.
struct PreampStage {
    double  couplingHz = 20.0;      ///< interstage high-pass (coupling cap × grid leak), Hz
    double  cathodeHz  = 0.0;       ///< cathode-bypass shelf corner, Hz. 0 = fully bypassed (flat)
    float   cathodeDB  = 0.0f;      ///< lift ABOVE cathodeHz, dB. The Marshall crunch lives here
    double  millerHz   = 20000.0;   ///< stage-output low-pass (Miller capacitance), Hz
    float   gain       = 1.0f;      ///< linear gain into this stage's nonlinearity
    float   asym       = 0.05f;     ///< clip bias → even harmonics (tube-like)
    AmpClip clip       = AmpClip::Triode;
};

/// One tone-stack band. `noonDB` is what the PASSIVE network does with the knob at
/// noon — the field today's ToneStack is missing, and the single biggest reason a
/// Fender and a Marshall currently sound the same.
struct ToneBand {
    double    hz         = 100.0;
    double    q          = 0.707;
    float     rangeScale = 1.0f;    ///< × the bus dB (1.0 = today's ±12 / ±9 swing).
                                    ///< NEGATIVE inverts the knob — the Vox "Cut" control.
                                    ///< 0 = this amp has no such control (knob is inert).
    float     noonDB     = 0.0f;    ///< static contribution with the knob at noon
    ToneShape shape      = ToneShape::LowShelf;
};

struct ToneStackVoicing {
    ToneBand band[4];               ///< 0 = Bass, 1 = Mid, 2 = Treble, 3 = Presence
    float    insertionDB = 0.0f;    ///< static loss of the passive network (recovered as makeup)
    float    bassEatsMid = 0.0f;    ///< 0..1 — how much Bass boost deepens the mid notch
};

struct PowerAmpVoicing {
    float   headroom      = 1.0f;   ///< linear level at which the output stage begins to clip
    AmpClip clip          = AmpClip::ClassAB;
    float   asym          = 0.03f;
    float   sagDepth      = 0.15f;  ///< 0..1 supply droop under load
    double  sagTauMs      = 45.0;   ///< sag recovery time constant, ms
    double  nfbHz         = 2000.0; ///< global negative-feedback shelf corner, Hz
    float   nfbDB         = -3.0f;  ///< NFB damping (negative = tighter/darker). 0 = NO feedback loop
    double  presenceHz    = 3500.0; ///< the presence control's shelf — it lives IN the NFB loop
    float   presenceScale = 1.0f;   ///< × the bus dB. 0 = this amp has no presence control
    double  otLowHz       = 60.0;   ///< output-transformer LF rolloff, Hz
    double  otHighHz      = 9000.0; ///< output-transformer HF rolloff, Hz
};

/// ONE AMP. Pure data, no virtuals, no allocation — the whole-amp analogue of
/// DrivePedal::Voice. Resolved once at setup time by AmpCabProcessor::configureAmp().
struct AmpProfile {
    static constexpr int kMaxStages = 4;

    double inputHz    = 95.0;       ///< input / grid tightening high-pass, Hz
    double brightHz   = 0.0;        ///< bright-cap high shelf, Hz. 0 = no bright cap
    float  brightDB   = 0.0f;

    int         stageCount = 1;     ///< 1..kMaxStages
    PreampStage stage[kMaxStages];

    ToneStackVoicing tone;
    PowerAmpVoicing  power;

    int   cabSlot   = 0;            ///< preferred IR slot
    bool  bypassCab = false;        ///< true = no speaker in the model (Katana ACOUSTIC)
    float outTrim   = 1.0f;         ///< level match across profiles

    /// Optional per-amp neural capture (resource base name, static storage).
    /// nullptr = fully algorithmic. See §2.6 — this is the seam that lets a
    /// rights-cleared capture ride the same profile with no architectural change.
    const char *neuralModel = nullptr;
};

/// Profile ids. APPEND-ONLY. MUST match ParameterMap.amp* (Swift).
enum AmpVoicing : int {
    Legacy      = 0,   ///< today's fixed voicing — the universal fallback
    JCM800      = 1,
    TwinReverb  = 2,
    AC30        = 3,
    JC120       = 4,
    Bassman59   = 5,
    // 6..9 reserved for four of the five remaining catalog amps (Marswell Plexi Super
    // Lead 1959, Freedman BE-100, Mesa Boogey Dual Rectifier, Tangerine Rockerverb 100);
    // Marswell DSL40C and anything later take 20+, which is open.
    KatanaAcousticA = 10, KatanaAcousticB = 11,
    KatanaCleanA    = 12, KatanaCleanB    = 13,
    KatanaCrunchA   = 14, KatanaCrunchB   = 15,
    KatanaLeadA     = 16, KatanaLeadB     = 17,
    KatanaBrownA    = 18, KatanaBrownB    = 19
};

/// THE ONE AUDITABLE TABLE — the exact shape of DrivePedal::voiceFor(int).
AmpProfile profileFor(int voicing) noexcept;

} // namespace streetrig
```

**Why the Katana characters are top-level profiles and not a nested "character" field.** Because the
generalization test demands it. `KatanaBrownA` is an ordinary row in `profileFor` sitting between
`Bassman59` and nothing special; it has no field the JCM800 lacks. If characters were a sub-structure
the schema would be admitting that a modeling amp's voicing is a different *kind* of thing from a
real amp's voicing — which is exactly the failure this document exists to avoid.

### 2.3 Where each field is consumed

| Field group | Consumed by | Thread |
|---|---|---|
| `inputHz`, `brightHz/DB`, `stage[]`, `stageCount` | `AnalogAmp::configure(const AmpProfile&)` — designs one-pole coefficients per channel | setup |
| `tone` | `ToneStack::configure(const ToneStackVoicing&)` then the existing `recompute()` → atomic index flip | setup + main (knob turns) |
| `power` | new `PowerAmp::configure(const PowerAmpVoicing&)` | setup |
| `cabSlot`, `bypassCab` | `RigGraphCompiler` → `RigDSPPlan.cabSlot` / `.cabBypass` → `SRKernelSetActiveCabSlot` / `SRParamCabBypass` | setup |
| `outTrim` | folded into the amp makeup path in `AmpCabProcessor::process` | audio (read-only scalar) |
| `neuralModel` | `StreetRigDSPUnit.loadToneAssets` → `SRKernelLoadAmpModelJSON` | setup |

### 2.4 The Swift-side selector

Mirrors `ParameterMap.pedalVoicing(name:category:)` exactly — substring match on the lowercased
catalog name, so it survives the re-badging, and specific models before generic keywords.

```
// ParameterMap.swift — mirrors streetrig::AmpVoicing (C++). Keep in lockstep.
public static let ampLegacy = 0
public static let ampJCM800 = 1, ampTwinReverb = 2, ampAC30 = 3,
                  ampJC120  = 4, ampBassman59  = 5
public static let ampKatanaBase = 10        // + character*2 + variation

static func ampProfile(name: String, values: [String: Double]) -> Int
```

Resolution rules, in order:

| Match on lowercased name | Returns |
|---|---|
| contains `"katana"` | `ampKatanaBase + character*2 + variation`, where `character = Int(values["Character"] ?? 2)` clamped 0…4 and `variation = Int(values["Variation"] ?? 0)` clamped 0…1 |
| contains `"jcm800"` or `"2203"` | `ampJCM800` |
| contains `"twin"` | `ampTwinReverb` |
| contains `"ac30"` | `ampAC30` |
| contains `"jc-120"` or `"jc120"` or `"jazz chorus"` | `ampJC120` |
| contains `"bassman"` | `ampBassman59` |
| anything else | **`ampLegacy`** |

`Character` is stored 0–4 (Acoustic, Clean, Crunch, Lead, Brown) and `Variation` 0–1 — deliberately
**not** on the 0–10 knob scale, because they are index selectors, not dials. §7.8 covers how they are
persisted and defaulted.

### 2.5 The backward-compatibility guarantee, and how it is proved

`profileFor(Legacy)` returns exactly today's voicing:

| Field | Legacy value | Matches today's code |
|---|---|---|
| `inputHz` | `95.0` | `AnalogAmp::prepare` — `Biquad::highpass(sr, 95.0, 0.707)` |
| `brightHz` | `0.0` (disabled) | no bright cap today |
| `stageCount` | `1` | one waveshaper today |
| `stage[0].couplingHz` / `cathodeHz` / `millerHz` | `0` = **skipped, not run flat** | no interstage filters today |
| `stage[0].gain` | `1.0` (the bus `drive` multiplies on top) | `shape(drive * up)` |
| `stage[0].asym` | `0.12f` | `constexpr float bias = 0.12f` in `AnalogAmp::shape` |
| `stage[0].clip` | `Triode` — `tanh(x + b) − tanh(b)` | identical expression |
| post-clip low-pass | `8000.0`, Q 0.707 | `Biquad::lowpass(sr, 8000.0, 0.707)` (carried as the *last* stage's `millerHz`) |
| `tone.band[0..3].hz` | `100 / 650 / 3200 / 6000` | `kBassHz / kMidHz / kTrebleHz / kPresenceHz` |
| `tone.band[1].q` | `0.70`; all others `0.70` | `kMidQ` / `kShelfQ` |
| `tone.band[*].rangeScale` | `1.0` **on all four bands, band 3 included** | today's dB arrives unscaled, and today's presence *is* tone band 3 |
| `tone.band[*].noonDB` | `0.0` | today's stack is flat at noon |
| `tone.insertionDB`, `tone.bassEatsMid` | `0.0`, `0.0` | no loss, no interaction today |
| `power.clip` | `Clean` | no power amp today |
| `power.presenceScale` | **`0.0`** — presence stays in tone band 3 | prevents double-applying presence; see §3.2 |
| `power.nfbDB`, `sagDepth`, `otLowHz`, `otHighHz` | **all `0`** → with `clip = Clean`, the entire power stage is a no-op | no power amp today |
| `cabSlot` | ignored — `ParameterMap.cabSlot(name:)` still wins for Legacy | unchanged |
| `outTrim` | `1.0` | unchanged |

Two guarantees follow, and both are mechanically checkable:

1. **A disabled field is skipped, not run flat** — per field, independently. A "flat" filter is not
   bit-identical to *no* filter, so skipping is the only way to guarantee the Legacy path is
   unchanged sample-for-sample. This is exactly how `DrivePedal::configure` already works
   (`v_.preMidDB != 0.0 ? Biquad::peaking(...) : Biquad{}`). **The full skip rule, which several
   later sections rely on:**

   | Field | Neutral value → skipped |
   |---|---|
   | `inputHz`, `brightHz` | `0` |
   | `stage[i].couplingHz`, `millerHz` | `0` |
   | `stage[i].cathodeDB` | `0` |
   | `stage[i].clip` | `AmpClip::Clean` → the stage's waveshaper (and only it) is bypassed |
   | `tone.band[b].rangeScale` **and** `noonDB` both `0` | that band's biquad |
   | `tone.bassEatsMid` | `0` → no cross-term arithmetic |
   | `power.clip` | `AmpClip::Clean` → the output-stage waveshaper **and its 2× oversampler** are bypassed. **The NFB, presence, sag and OT sub-blocks are unaffected** — each is skipped by its own field below |
   | `power.nfbDB` | `0` |
   | `power.presenceScale` | `0` |
   | `power.sagDepth` | `0` |
   | `power.otLowHz`, `otHighHz` | `0` |

   For `Legacy`, **every** one of these is at its neutral value except the input HP, the single
   stage, the last stage's 8 kHz `millerHz` and the four tone bands — so the power stage is a total
   no-op and the signal path is byte-for-byte today's. For Katana Acoustic, `power.clip == Clean`
   skips the output clip while `presenceScale 0.6` and the OT rolloffs still run, which is correct:
   an acoustic preamp has no output valves but does have a tone shelf and a bandwidth.
2. **Unknown amps resolve to Legacy.** `ampProfile(name:values:)` returns `ampLegacy` for anything
   it does not recognize, so every already-owned rig, every factory preset (which reference
   pre-rename names like `"Marshall JCM800"` and `"Fender Deluxe"`, see
   `StreetRigDSPUnit.makeFactoryRigs`), and every saved host session sounds exactly as it does now.

**Exit test for Phase A:** the offline harness
(`StreetRig/Audio/AudioEngineController+OfflineRender.swift`) renders the current seed rig through
the Legacy profile and null-tests it against a pre-change render. Bit-exact, or the fallback is
wrong. This is the same harness that already runs the `PROMPT 003 — FULL COMPILED-RIG CHAIN
VERIFICATION` suite.

### 2.6 Where a neural capture rides later, without rework

`AmpProfile::neuralModel` is a `const char *` resource base name (static storage → still POD, still
`constexpr`-friendly). When non-null:

- `StreetRigDSPUnit.loadToneAssets` resolves it in the framework bundle and calls
  `SRKernelLoadAmpModelJSON`, which installs it through the existing one-generation atomic retire in
  `AmpCabProcessor::installNeuralModel`. That path already exists and already obeys the contract.
- `RigGraphCompiler` sets `plan.useNeural = true` for that amp; the capture replaces **the preamp
  cascade only**.
- **The profile's tone stack, power amp, OT rolloffs and cab pairing still apply.** This is the point:
  a capture of a preamp is a capture of a preamp, and the rest of the profile is still the truth about
  that amp. A capture therefore *upgrades* a profile rather than replacing it.

`ParameterMap.ampUsesNeural(name:)` changes from `return true` to
`profileFor(id).neuralModel != nullptr` (mirrored in Swift as a small name→bool table), so Legacy
keeps today's behaviour (`true`, falling back to analog when no model loads) and every profiled amp
runs algorithmically until a capture is dropped in for it.

---

## 3. Proving the schema generalizes — six catalog amps, filled in

Every cell is a concrete number or enum value. Confidence: **H** = grounded in published circuit
values, **M** = derived from topology, **L** = educated guess (these are what §11 exists to fix).

### 3.1 Input and preamp cascade

| Amp | `inputHz` | `brightHz` / `brightDB` | Stages | Stage detail — `couplingHz`, `cathodeHz`/`cathodeDB`, `millerHz`, `gain`, `asym`, `clip` | Conf |
|---|---|---|---|---|---|
| **Marswell JCM800 2203** | 72 | 1500 / +4 | **3** | S1 `32, 480/+8, 15000, 2.2, 0.10, Triode`<br>S2 `40, 674/+6, 12000, 2.4, 0.14, Triode`<br>S3 `48, 0/0, 10000, 1.6, 0.08, Triode` | H (cathode corners), M (gains) |
| **Fandor Twin Reverb** | 30 | 2500 / +3 | **2** | S1 `20, 0/0, 22000, 1.5, 0.03, Triode`<br>S2 `25, 0/0, 20000, 1.4, 0.03, Triode` | H (fully bypassed cathodes), M |
| **Volt AC30** | 40 | 3000 / +4 | **2** | S1 `25, 0/0, 20000, 1.7, 0.06, Triode`<br>S2 `30, 250/+5, 16000, 2.0, 0.10, Triode` | M |
| **Rolund JC-120** | 25 | 0 / 0 | **2** | S1 `15, 0/0, 25000, 1.2, 0.00, SolidState`<br>S2 `18, 0/0, 25000, 1.2, 0.00, SolidState` | H (no bright cap, no bias asymmetry), M |
| **Fandor Bassman '59** | 32 | 1000 / +3 | **2** | S1 `22, 180/+3, 18000, 1.9, 0.08, Triode`<br>S2 `28, 0/0, 18000, 1.8, 0.12, Triode` | M |
| **VOSS Katana 100** (Crunch A) | 60 | 1800 / +3 | **3** | S1 `34, 420/+6, 16000, 2.0, 0.10, Triode`<br>S2 `42, 600/+5, 13000, 2.1, 0.12, Triode`<br>S3 `50, 0/0, 11000, 1.5, 0.07, Triode` | L (Boss publishes nothing) |

Read the differences: the Twin's cathodes are fully bypassed (`cathodeHz = 0`) and its couplings are
wide open (20–25 Hz) — it amplifies the whole band flat, which is why it stays clean and loud. The
JCM800 shelves +8 dB above 480 Hz in the very first stage and high-passes at 32/40/48 Hz between
stages — it distorts the mids and upper mids while keeping the lows out of the clipper, which is why
it is tight. The JC-120 uses `SolidState` clips with zero asymmetry — no even harmonics, no tube
warmth, by design.

### 3.2 Tone stack

Bands are `hz / q / rangeScale / noonDB`. Shapes are fixed by band index: 0 LowShelf, 1 Peak,
2 HighShelf, 3 HighShelf.

**Presence is specified exactly once, in §3.3.** In a real amp presence is an NFB-loop control, so in
this architecture it lives in the power-amp stage (`power.presenceHz` / `presenceScale`), *not* in the
tone stack. Every profiled amp therefore sets **`tone.band[3].rangeScale = 0`**, which skips the band.
`AmpVoicing::Legacy` is the one exception: it keeps band 3 live at `6000 Hz / ±9 dB` and sets
`power.presenceScale = 0`, because today's presence *is* tone band 3 and the Legacy path must not
change. One control, one owner, per profile.

| Amp | Bass (0) | Mid (1) | Treble (2) | Presence (3) | `insertionDB` | `bassEatsMid` | Conf |
|---|---|---|---|---|---|---|---|
| **Marswell JCM800 2203** | `90 / 0.70 / 1.0 / −1` | `650 / 0.85 / 0.9 / **−7**` | `2300 / 0.70 / 1.1 / +1` | *skipped* (`rangeScale 0`) | −14 | 0.35 | H (centres), M (noon) |
| **Fandor Twin Reverb** | `80 / 0.70 / 1.1 / +1` | `400 / 0.90 / 0.8 / **−11**` | `3200 / 0.70 / 1.2 / +2` | *skipped* | −16 | **0.55** | H (centres), M (noon) |
| **Volt AC30** | `120 / 0.70 / 0.9 / 0` | `700 / 0.60 / **0.35** / **+2**` | `3500 / 0.70 / 1.2 / +2` | *skipped* | −12 | 0.15 | M |
| **Rolund JC-120** | `90 / 0.70 / 1.1 / 0` | `500 / 0.80 / 1.1 / −3` | `4000 / 0.70 / 1.1 / +1` | *skipped* | **−6** | 0.10 | M |
| **Fandor Bassman '59** | `85 / 0.70 / 1.1 / 0` | `420 / 0.80 / **1.3** / −6` | `2600 / 0.70 / 1.1 / +1` | *skipped* | −13 | 0.45 | M |
| **VOSS Katana 100** (all characters) | `110 / 0.70 / 1.0 / †` | `550 / 0.80 / 1.0 / †` | `3000 / 0.70 / 1.0 / †` | *skipped* | **0** | 0.10 | M |
| **`Legacy`** (today, unchanged) | `100 / 0.70 / 1.0 / 0` | `650 / 0.70 / 1.0 / 0` | `3200 / 0.70 / 1.0 / 0` | `6000 / 0.70 / **1.0** / 0` | 0 | 0.00 | — (matches the code) |

† The Katana shares all four band centres, Qs and ranges across its ten voicings, but each voicing
carries its own `noonDB` set — the "Tone `noonDB` B/M/T/P" column of §4.3. They average close to zero,
which is the point (see below).

Three things this table proves:

- **The Vox Cut is expressible with no special case** — `power.presenceScale = −0.8` (§3.3), and the
  knob works backwards, which is what the real control does. The same negative-scale mechanism is
  available on any of the four tone bands too.
- **"This amp has no such control" is expressible** — `power.presenceScale = 0.0` on the JC-120. The
  shelf still exists in the DSP, contributes nothing, and the per-item knob list (§7.8) simply does
  not show a Presence knob for that amp.
- **The Katana is the one amp whose stack really is flat at noon** (`noonDB ≈ 0`, `insertionDB = 0`),
  because it is a digital EQ Boss designed to be neutral at centre. Which is exactly why StreetRig's
  current fixed `ToneStack` already, accidentally, sounds most like a Katana — and least like
  everything else.

### 3.3 Power amp and output transformer

| Amp | `headroom` | `clip` | `asym` | `sagDepth` / `sagTauMs` | `nfbHz` / `nfbDB` | `presenceHz` / `presenceScale` | `otLowHz` / `otHighHz` | Conf |
|---|---|---|---|---|---|---|---|---|
| **Marswell JCM800 2203** | 0.75 | `ClassAB` | 0.05 | 0.18 / 45 | 2200 / −3.0 | 3500 / 1.0 | 65 / 9000 | M |
| **Fandor Twin Reverb** | **1.60** | `ClassAB` | 0.02 | **0.06** / 30 | 1800 / **−5.0** | 4500 / 0.8 | 45 / 11000 | H (heavy NFB, stiff supply), M |
| **Volt AC30** | **0.55** | **`ClassA`** | **0.18** | **0.35** / 80 | **0 / 0.0** | 4000 / **−0.8** | 80 / 8000 | H (cathode bias, no NFB), M |
| **Rolund JC-120** | **3.00** | **`SolidState`** | 0.00 | **0.00** / 0 | 0 / 0.0 | 6000 / **0.0** | 30 / 14000 | H |
| **Fandor Bassman '59** | 0.85 | `ClassAB` | 0.10 | **0.30** / 60 | 2500 / −2.0 | 3000 / 0.9 | 70 / 8500 | H (GZ34 sag), M |
| **VOSS Katana 100** | per voicing, §4.3 (× power scale, §4.4) | `ClassAB` | 0.04 | per voicing / 40 | 2400 / −3.0 | 5000 / per voicing | 55 / 10000 | L |

The AC30 row is the one to read carefully: `ClassA` + `headroom 0.55` + `asym 0.18` + `sagDepth 0.35`
+ **`nfbDB = 0`** together *are* "cathode-biased EL84s with no negative feedback". The JC-120 row is
its opposite in every field. Neither needed a flag the other lacks.

### 3.4 Cab pairing, trim and engine

| Amp | Intended box | Phase A slot (only 2 IRs bundled) | Target slot when IRs exist | `bypassCab` | `outTrim` | `neuralModel` |
|---|---|---|---|---|---|---|
| **Marswell JCM800 2203** | 4×12 V30 | **0** | 0 | false | 1.00 | `nullptr` |
| **Fandor Twin Reverb** | 2×12 Jensen | **1** | 2 | false | 0.95 | `nullptr` |
| **Volt AC30** | 2×12 alnico blue | **1** | 3 | false | 1.00 | `nullptr` |
| **Rolund JC-120** | 2×12 JC (bright) | **1** | 4 | false | 0.95 | `nullptr` |
| **Fandor Bassman '59** | 4×10 tweed | **0** | 5 | false | 1.05 | `nullptr` |
| **VOSS Katana 100** | 1×12 | **1** | 6 | false (Acoustic: **true**) | 1.00 | `nullptr` |

`ParameterMap.cabSlot(name:)` keeps its current substring behaviour for Legacy amps; for profiled
amps `AmpProfile::cabSlot` wins. The Phase A column is what actually ships — with two IRs, the six
amps still differ enormously (preamp, tone stack, power amp) but share two boxes. That is a known,
recorded limitation, not a design flaw.

---

## 4. The Katana in full

### 4.1 What the panel is, and how it decomposes

| Panel element | Kind | StreetRig realization |
|---|---|---|
| Amp character (Acoustic / Clean / Crunch / Lead / Brown) | 5-position selector | 5 × 2 `AmpProfile` rows, §4.2 |
| Variation | 2-position switch | the second of each pair, §4.3 |
| Gain | continuous | `SRParamAmpDrive` (exists) |
| Bass / Middle / Treble | continuous | `SRParamAmpBass/Mid/Treble` (exist) |
| Presence | continuous | `SRParamAmpPresence` (exists) |
| **Volume** | continuous | **`SRParamAmpVolume` (new, address 12)** — drives the power stage |
| Master | continuous | `SRParamAmpMakeup` (exists) — final output, post power amp |
| **Power Control** (0.5 / 50 / 100 W) | 3-position, but **continuous** | **`SRParamAmpPower` (new, address 13)**, §4.4 |
| Booster / Mod / FX / Delay / Reverb | 5 effect blocks | `PedalChain` slots across three spans, §4.5 |
| Channel memories | preset recall | `RigStore.PersistedState` / AUv3 presets, §4.6 |

**Volume vs Master is not cosmetic.** On a real Katana, Volume sets how hard the character drives the
power section and Master sets the room level — which is exactly why Katana players talk about the two
knobs the way they do. StreetRig has only had `ampDrive` (into the preamp) and `ampMakeup` (final
out). Adding `SRParamAmpVolume` *between the tone stack and the power amp* makes the topology correct
and gives every amp — not just the Katana — a working master-volume architecture. Legacy amps default
it to unity, so nothing changes for them.

### 4.2 The five characters as five profiles

Each character is Boss's model of something. Voiced accordingly — exact per-variation numbers are in
§4.3; this table is the intent behind them.

| Character | What Boss is modeling | Preamp shape | The fields that carry the character |
|---|---|---|---|
| **Acoustic** | An acoustic / DI preamp, **not a guitar amp** | 1 stage, `AmpClip::Clean` — no nonlinearity at all | **`bypassCab = true`**, `power.clip = Clean`, `headroom 4.0`, `sagDepth 0`, `nfbDB 0`, `otHighHz 16000` |
| **Clean** | Roland JC-120 (Var A) / Fender (Var B) | 2 stages. **A** fully bypassed cathodes + `SolidState` clip; **B** shelves stage 2 at 300 Hz and uses `Triode` | high `headroom` (2.20 / 1.70), `sagDepth` 0.05 / 0.10 |
| **Crunch** | A driven tube amp — Vox chime (A) into plexi push (B) | 3 stages, partially bypassed cathodes | `headroom` 1.00 / 0.90, `sagDepth` ~0.20. This is the reference row in §3 |
| **Lead** | Thick, saturated modern high gain | **4 stages**, aggressive interstage high-pass | `headroom` 0.85 / 0.80, `sagDepth` ~0.25, mid-forward `noonDB` |
| **Brown** | Modded Marshall / EVH "brown sound" | **4 stages**, hottest gains, tightest lows (`inputHz` up to 105) | `headroom` 0.80 / 0.75, `sagDepth` ~0.29, the highest stage gains in the table |

### 4.3 All ten voicings — character × variation

**The variation rule.** Boss does not publish what Variation changes per character, and it differs
per character on the real amp. Rather than guess ten unrelated things, Phase A adopts one *stated,
consistent* rule that is easy to A/B against hardware and easy to correct per character afterwards:

> **A = the base voicing. B = hotter and tighter** — one more effective gain stage's worth of drive,
> the interstage high-passes moved up (less low end into the clipper), and slightly more presence
> range.

Every B row below is that rule applied. All ten are marked **L** confidence in §11 and are the
highest-value rows for the owner's ear-tuning pass.

| Id | Voicing | Stages | Stage gains | `inputHz` | Coupling Hz (per stage) | Cathode Hz/dB (per stage) | `headroom` | `sagDepth` | Tone `noonDB` B/M/T | `presenceScale` | `bypassCab` | `outTrim` |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 10 | **Acoustic A** (bright, steel-string) | 1 | `1.0` | 40 | `20` | `0/0` | 4.00 | 0.00 | `+2 / −4 / +4` | 0.60 | **true** | 0.90 |
| 11 | **Acoustic B** (warm, nylon-ish) | 1 | `1.0` | 45 | `26` | `0/0` | 4.00 | 0.00 | `+3 / −2 / +1` | 0.40 | **true** | 0.90 |
| 12 | **Clean A** (JC-flavoured) | 2 | `1.3, 1.3` | 30 | `18, 22` | `0/0`, `0/0` | 2.20 | 0.05 | `0 / −2 / +1` | 0.90 | false | 1.00 |
| 13 | **Clean B** (Fender-ish, earlier breakup) | 2 | `1.6, 1.5` | 36 | `24, 30` | `0/0`, `300/+3` | 1.70 | 0.10 | `+1 / −4 / +2` | 1.00 | false | 1.00 |
| 14 | **Crunch A** (chime, edge of breakup) | 3 | `2.0, 2.1, 1.5` | 60 | `34, 42, 50` | `420/+6`, `600/+5`, `0/0` | 1.00 | 0.20 | `0 / −2 / 0` | 1.00 | false | 1.00 |
| 15 | **Crunch B** (plexi push) | 3 | `2.4, 2.5, 1.6` | 72 | `44, 54, 62` | `480/+8`, `674/+6`, `0/0` | 0.90 | 0.22 | `−1 / 0 / +1` | 1.10 | false | 0.95 |
| 16 | **Lead A** (smooth, sustaining) | 4 | `2.3, 2.5, 2.4, 1.4` | 80 | `50, 60, 70, 76` | `500/+6`, `650/+6`, `700/+5`, `0/0` | 0.85 | 0.25 | `−1 / +2 / 0` | 1.00 | false | 0.85 |
| 17 | **Lead B** (tighter, more attack) | 4 | `2.6, 2.8, 2.6, 1.4` | 95 | `62, 74, 86, 92` | `560/+7`, `720/+7`, `780/+6`, `0/0` | 0.80 | 0.26 | `−2 / +1 / +2` | 1.15 | false | 0.82 |
| 18 | **Brown A** (classic brown) | 4 | `2.5, 2.7, 2.6, 1.5` | 85 | `54, 66, 78, 84` | `450/+7`, `620/+7`, `700/+6`, `0/0` | 0.80 | 0.28 | `0 / +3 / +1` | 1.05 | false | 0.85 |
| 19 | **Brown B** (modern, scooped, tightest) | 4 | `2.9, 3.1, 2.9, 1.5` | 105 | `70, 84, 96, 104` | `520/+8`, `700/+8`, `780/+7`, `0/0` | 0.75 | 0.30 | `−2 / −3 / +3` | 1.20 | false | 0.80 |

`noonDB` is three values because tone band 3 is skipped on every profiled amp — presence is a
power-amp control (§3.2), which is why `presenceScale` gets its own column here.

**Every field not in the table above, so nothing has to be invented.** Shared across all ten
voicings:

| Field | Value |
|---|---|
| `brightHz` / `brightDB` | `1800` / `+3` (Acoustic: `0` / `0` — no bright cap) |
| `stage[i].millerHz` | `16000`, `13000`, `11000`, `10000` for `i = 0…3` (Acoustic's single stage: `18000`) |
| `stage[i].asym` | `0.10`, `0.12`, `0.12`, `0.07` for `i = 0…3` (Acoustic: `0.00`; Clean A: `0.04`, `0.04`) |
| `stage[i].clip` | `AmpClip::Triode` for Clean B, Crunch, Lead, Brown · `AmpClip::SolidState` for **Clean A** (it is the JC-flavoured voicing) · `AmpClip::Clean` for **Acoustic** |
| `tone.band[0…3]` `hz / q / rangeScale` | `110 / 0.70 / 1.0` · `550 / 0.80 / 1.0` · `3000 / 0.70 / 1.0` · band 3 **`rangeScale 0` — skipped** (§3.2) |
| `tone.insertionDB` / `bassEatsMid` | `0.0` / `0.10` |
| `power.clip` / `asym` / `sagTauMs` | `ClassAB` / `0.04` / `40` (Acoustic: `Clean` — the output-stage clip is skipped; its presence and OT filters still run, per the per-field skip rule in §2.5) |
| `power.nfbHz` / `nfbDB` | `2400` / `−3.0` (Acoustic: `0` / `0.0` — skipped) |
| `power.presenceHz` | `5000` (Acoustic: `9000`). `presenceScale` is per-voicing — see the table above |
| `power.otLowHz` / `otHighHz` | `55` / `10000` (Acoustic: `40` / `16000`) |
| `cabSlot` | `1` (irrelevant for Acoustic, which sets `bypassCab`) |
| `neuralModel` | `nullptr` |

### 4.4 The power control as a power-amp transformation

**It is a power-amp attenuator, not an output gain.** Lowering the wattage lowers the voltage swing
the output stage can produce, so the *same* signal level hits clipping sooner. Compression, sag and
touch response all change; the preamp does not.

Specified as a **transformation applied to the resolved `PowerAmpVoicing`**, not as a separate profile:

```
headroomScale = sqrt(W / 100)                  // voltage swing ∝ sqrt(power)
power.headroom *= headroomScale
power.sagDepth *= sagScale                     // small supplies droop harder
power.otLowHz  *= otLowScale                   // small OTs lose bass when pushed
postMakeup      = min(1 / headroomScale, 8.0)  // keep perceived LOUDNESS roughly constant
```

| Setting | `headroomScale` (physical) | `headroomScale` (**first pass**) | `sagScale` | `otLowScale` | `postMakeup` |
|---|---|---|---|---|---|
| **100 W** | 1.000 | **1.00** | 1.00 | 1.00 | 1.00 |
| **50 W** | 0.707 | **0.70** | 1.15 | 1.05 | 1.43 |
| **0.5 W** | 0.071 | **0.14** | 1.60 | 1.25 | 7.14 |

The 0.5 W row is deliberately **conservative**: physically it is −23 dB of headroom, and we ship
−17 dB. A real Katana at 0.5 W is heavily power-saturated but still musical because the clipping is
soft and the OT plus speaker filter the result; our first pass errs toward musical. §11 carries the
row with the listening cue for pushing it either way.

`postMakeup` exists because this is a *model*, not an attenuator on a real speaker: the player should
hear the saturation change, not the volume collapse. It is clamped at 8.0 so 0.5 W is still modestly
quieter than 100 W, which matches expectation.

**This is a continuous control** (§9.2): the bus carries `headroomScale` directly on
`SRParamAmpPower`, `sagScale` / `otLowScale` / `postMakeup` are derived from it in C++, and every one
of them is de-zippered with the existing ~5 ms one-pole. Switching 100 W → 0.5 W is a smooth 5 ms
glide, not a fade/park rebuild. This matters: on a real Katana the power switch is instant and
click-free, and a rebuild would be audibly worse than the hardware.

### 4.5 The FX section, and the routing that most sims get wrong

The five blocks and where each actually sits:

```
guitar → [BOOSTER] → [MOD] → PREAMP(character) → TONE STACK(EQ) → [FX] → [DELAY] → [REVERB]
                                                                                       ↓
                                                          POWER AMP ← VOLUME ←─────────┘
                                                               ↓
                                                        CAB IR → MASTER → out
```

Two things sims routinely get wrong, both of which this routing fixes:

1. **Delay and reverb belong post-preamp and *pre-power-amp*** — that is where a real amp's FX loop
   is. Reverb that then passes through a saturating power stage sounds materially different from
   reverb sprinkled on the finished, cab-filtered signal: the tails compress with the notes instead
   of floating above them.
2. **Booster and Mod belong pre-preamp**, where a real pedal in front of the amp sits, so the boost
   actually drives the character into saturation instead of just making it louder.

Boss's Tone Studio also allows a *post-everything* placement (the "post-reverb" loop position). To
support all three, `PedalChain` gains **two split points and three spans**:

| Span | Slots | Where the kernel runs it | Katana blocks |
|---|---|---|---|
| **PRE** | `0 … splitPre−1` | before `AmpCabProcessor::processPreamp` | Booster, Mod |
| **MID** | `splitPre … splitPost−1` | after the tone stack, before the power amp | FX, Delay, Reverb |
| **POST** | `splitPost … active−1` | after the cab convolver | (the "post-reverb loop" position) |

That is two integers and a `processSpan(buffer, n, channel, first, last)` refactor of
`PedalChain::process`. No new slots, no new allocation. As a side benefit the whole app gets a real
FX loop, not just the Katana.

Per-block engine mapping — every one either already exists or is Phase B:

| Katana block | Selected effect | StreetRig engine | Type / voicing | Span | Status |
|---|---|---|---|---|---|
| **Booster** | Boost / Clean Boost | `DrivePedal` | `typeDrive` / `voiceCleanBoost` (14) | PRE | ✅ exists |
| | Blues Drive | `DrivePedal` | `typeDrive` / `voiceBluesbreaker` (4) | PRE | ✅ exists |
| | OD-1 / Crunch | `DrivePedal` | `typeDrive` / `voiceTubeScreamer` (3) | PRE | ✅ exists |
| | Tube Drive | `DrivePedal` | `typeDrive` / `voiceOCD` (7) | PRE | ✅ exists |
| | Distortion | `DrivePedal` | `typeDrive` / `voiceDS1` (8) | PRE | ✅ exists |
| | Metal / Metal Zone | `DrivePedal` | `typeDrive` / `voiceMetalZone` (9) | PRE | ✅ exists |
| | Fuzz | `DrivePedal` | `typeDrive` / `voiceFuzzFace` (12) | PRE | ✅ exists |
| **Mod** | Chorus | `ModulationPedal` | `typeModulation` / `modChorus` (0) | PRE | ✅ exists |
| | Flanger | `ModulationPedal` | `typeModulation` / `modFlanger` (1) | PRE | ✅ exists |
| | Phaser | `ModulationPedal` | `typeModulation` / `modPhaser` (2) | PRE | ✅ exists |
| | Tremolo | `ModulationPedal` | `typeModulation` / `modTremolo` (3) | PRE | ✅ exists |
| | Vibrato / Rotary | `ModulationPedal` | `typeModulation` / `modUnivibe` (4) | PRE | 🟡 stand-in (true rotary deferred) |
| | Pedal Bend / Harmonist / Slicer | — | `typeTransparent` | PRE | ⛔ deferred (pitch family) |
| **FX** | Compressor | `DynamicsPedal` | `typeCompressor` (3) | MID | ✅ exists |
| | EQ | `EqPedal` | `typeEq` (2) | MID | ✅ exists |
| | Wah | `WahPedal` | `typeWah` (5) | MID | ✅ exists |
| | Tremolo / Phaser / Chorus | `ModulationPedal` | `typeModulation` (7) | MID | ✅ exists |
| | Octave / Pitch Shifter / Defretter / Ring Mod / Humanizer | — | `typeTransparent` | MID | ⛔ deferred (pitch family) |
| **Delay** | Digital / Analog / Tape / Reverse | **new** `DelayPedal` | **`typeDelay` (8)** | MID | 🔜 Phase B, §5 |
| **Reverb** | Room / Hall / Plate / Spring | **new** `ReverbPedal` | **`typeReverb` (9)** | MID | 🔜 Phase B, §5 |

**Nothing in the Booster/Mod/FX columns needs new DSP.** Phase B builds exactly two engines and the
Katana FX section is complete except the pitch family, which is already the deferred item in
`research/pedal-emulation-approaches.md` §7 Phase 4 — no contradiction introduced.

### 4.6 Channel presets

A Katana channel memory is "the whole panel, stored". StreetRig already round-trips exactly that:

| Layer | Existing mechanism | What changes |
|---|---|---|
| **In-app** | `RigStore.PersistedState { collection, rig, arSlots, catalogVersion }` written to `rig_state.json` | **nothing structural.** A channel is a stored snapshot of the Katana `GearItem.values` dictionary. `values` is `[String: Double]`, so `Character`, `Variation`, `Power` and the FX knobs ride along automatically |
| **AUv3 host** | `StreetRigDSPUnit.fullState` / `fullStateForDocument` carry the serialized snapshot under the stable key `"streetrig.rig.v1"`, alongside `super`'s parameter dictionary | **nothing.** The key is stable; new `values` entries are additive inside the blob |
| **Factory presets** | `StreetRigDSPUnit.factoryRigs` → `makeFactoryRigs()`, self-contained `PersistedState`s | **add Katana rigs** — e.g. "Katana Crunch", "Katana Brown Lead". Appending presets is safe; existing preset *numbers* must not be reordered, because a host may have stored `preset.number` |
| **User presets** | `saveUserPreset` / `presetState(for:)`, `.srpreset` plists in Application Support | **nothing** |

**Recommendation: model Katana channels as AUv3 user presets plus one in-app addition** — a
`channels: [[String: Double]]?` array on the Katana `GearItem` would require a `GearItem` schema
change and therefore a `catalogVersion` bump, which **discards the player's saved rig**
(`RigStore.load` returns `nil` for a stale generation and the caller re-seeds). Not worth it. Instead
store channels as four named user presets, which already works end to end, and expose them in the app
as a Katana-specific preset strip reading the same `.srpreset` store. Zero schema risk.

The exact channel count on the hardware (4 vs 8 across generations) is §13 Open Question 1; the
mapping above is count-agnostic.

---

## 5. The shared delay and reverb blocks

Two new `PedalChain::Type` values. `PedalChain.hpp`'s own header note already anticipates this:
*"delay/reverb/pitch (which need large buffers) are the next extension and will draw their buffers
from a preallocated arena."*

```
enum Type : int {
    Transparent = 0, Drive = 1, Eq = 2, Compressor = 3,
    Gate = 4, Wah = 5, Volume = 6, Modulation = 7,
    Delay = 8, Reverb = 9                    // NEW
};
```
Mirrored in Swift as `ParameterMap.typeDelay = 8`, `typeReverb = 9`, with `pedalType(for:)` extended
so `.delay` and `.reverb` stop falling through to `typeTransparent`.

### 5.1 The preallocated arena

Every existing family preallocates one instance *per slot* (`PedalChain::Slot` holds a `DrivePedal`,
`EqPedal`, `DynamicsPedal`, `ModulationPedal`, `WahPedal`, `VolumePedal`). That works because they are
small — `ModulationPedal` is the largest at `2 ch × 4096 floats = 32 KB`. A delay line is three
orders of magnitude bigger, so the per-slot pattern stops scaling.

**Design: one arena owned by `PedalChain`, allocated once in `prepare()`, handed out as raw spans at
`configureSlot()` time.**

| Property | Value | Rationale |
|---|---|---|
| Owner | `PedalChain::arena_` — a single `std::vector<float>` | one allocation, one owner |
| Allocated in | `PedalChain::prepare(sampleRate, numChannels)` (setup thread) | already the allocation point for every engine |
| **Never** resized after | enforced by sizing for the worst case | `prepare()` is the only allocation site; `configureSlot` only assigns pointers |
| `kMaxDelaySeconds` | **2.0 s** | covers Echoplex (~0.7 s), Memory Man (~0.55 s), DD-8's musically useful range |
| Per-slot block | `ceil(2.0 × sampleRate)` floats **per channel**, rounded up to a power of two → `131072` @ 48 kHz | power-of-two lets the read/write pointers use a mask instead of a modulo |
| Total | `8 slots × 2 ch × 131072 × 4 B` = **8.0 MB** @ 48 kHz | acceptable on iOS; drop `kMaxDelaySeconds` to 1.0 for 4.0 MB if profiling says otherwise (§11) |
| Reverb draws from the same block | Dattorro's whole tank is ≈ 0.35 s of line | one block serves either engine — a slot is a delay **or** a reverb, never both |
| Assignment | `configureSlot(slot, type, voicing)` sets `engine.setBuffer(arena_.data() + slot*blockFloats, blockFloats)` and zeroes it | setup thread, inside the reconfigure barrier, exactly where `s.drive.configure()` already runs |

No cap on concurrent time-based blocks, therefore no failure mode: all eight slots can be delays.

**Why not `std::vector` inside each engine?** Because `configureSlot` is called under the barrier but
`PedalChain::prepare` is the documented allocation point, and keeping every byte in one arena makes
the memory story auditable in one line rather than eight.

### 5.2 Delay

| Voicing | Catalog pedals | Read interpolation | Feedback-path colour | Modulation |
|---|---|---|---|---|
| **Digital** (0) | VOSS Digital Delay | linear | one-pole LP @ **8 kHz** (stops runaway brightness) | none |
| **Tape** (1) | DUNLAP ECHOPLEX | **Hermite (cubic)** | `tanh` soft-clip at 0.85 + one-pole LP @ **4 kHz** + high shelf +3 dB @ 3 kHz (the EP-3 preamp) | wow 0.5 Hz ±0.30 %, flutter 6.0 Hz ±0.05 % |
| **BBD** (2) | electro-harmonium MEMORY MAN | **Hermite (cubic)** | soft compress-in / expand-out (companding), one-pole LP @ **2.5 kHz** | chorus 0.4 Hz ±0.8 % on the read pointer |

**Why a naive time change clicks, and the two fixes.** The read pointer is `writePos − delaySamples`.
If `delaySamples` jumps between buffers, the read pointer teleports and the output waveform has a step
discontinuity — an audible click, and a nasty one at high feedback because it recirculates. Two
independent fixes, both required:

1. **Fractional reads.** Never round the read pointer; interpolate between samples. `ModulationPedal`
   already does this with linear interpolation (`readDelay`), which is fine for a static or slowly
   swept short delay. For tape and BBD, whose read pointers sweep fast enough for linear
   interpolation's low-pass error and aliasing to be audible on the repeats, use **4-point Hermite**
   — about 8 extra multiplies per read, and worth it.
2. **Slew the delay *time*, not just the output.** Feed `delaySamples` through a one-pole with a
   ~100 ms time constant so the read pointer moves *continuously*. This is not merely a de-click: a
   continuously moving read pointer produces the correct tape-style **pitch glide** when the Time
   knob is turned, which is what the hardware does and what players expect.

Parameter mapping on the existing per-slot generic params (all five used, all within budget):

| Field | Knob (`PedalSpec` aliases) | DSP unit | Curve | First pass |
|---|---|---|---|---|
| `Param0` | Time / Delay | ms | exponential `40 · 2^(norm·5.0)` | 40 ms → 1280 ms |
| `Param1` | Feedback / Sustain / Repeats | 0…1 | `norm · 0.95` | 0 → 0.95 (self-oscillates near the top, as the hardware does) |
| `Param2` | Mix / Blend / E.Level | wet 0…1 | `norm · 0.8`, dry fixed at 1.0 | additive wet send, matching pedal behaviour |
| `Param3` | Tone (voicing default when the pedal has no Tone knob) | Hz | `1200 · 2^(norm·3.0)` | 1.2 kHz → 9.6 kHz feedback-path LP |
| `Param4` | Mod Depth (Memory Man's Depth; 0 for others) | 0…1 | `norm` | 0 → 1 |

### 5.3 Reverb

**Algorithm choice — Dattorro plate.**

| Candidate | Cost/sample/ch | Quality | Why not / why yes |
|---|---|---|---|
| Schroeder (4 comb + 2 all-pass) | ~30 flops | metallic, obvious comb ring on sustained chords | cheapest, but the ring is exactly what a guitar player notices |
| **Dattorro plate** | **~60 flops** (12 delay reads, 8 one-poles, ~10 adds) | lush, diffuse, no metallic ring | **chosen** |
| FDN 8×8 Householder | ~70 flops | excellent, and mode-flexible | more tuning freedom than we can spend; keep as the upgrade path if per-mode (spring/hall) variety is wanted later |

**Dattorro wins on the criterion this whole document is written to satisfy: it is a published, fixed
topology with known-good constants, so the implementation is transcription rather than invention.**
Its input diffusion chain plus modulated tank all-passes remove the metallic ring for roughly twice
Schroeder's cost — about two biquad chains' worth, which is nothing against the ~7.74 % board budget.
It needs ≈ 0.35 s of total line length, comfortably inside a 2.0 s arena block.

Parameter mapping on the existing Decay / Tone / Mix knobs (`GearCategory.reverb.parameters`, and
`PedalSpec` maps HOLY GRAIL's single `"Reverb"` knob onto Mix):

| Field | Knob | DSP unit | Curve | First pass |
|---|---|---|---|---|
| `Param0` | Decay | tank feedback | `0.30 + norm · 0.62` | 0.30 → 0.92 (RT60 ≈ 0.4 s → 6 s) |
| `Param1` | Tone | damping LP Hz | `1200 · 2^(norm·3.32)` | 1.2 kHz → 12 kHz |
| `Param2` | Mix / Reverb | wet 0…1 | `norm · 0.7`, dry fixed at 1.0 | additive wet send — never sucks out the dry |

### 5.4 Parameter-bus budget

`SRPedalParamStride = 8` with fields 0–7; fields 3–7 are `Param0…Param4` = **five** generic continuous
knobs per slot. Delay uses all five; reverb uses three. **Both fit — no stride extension is needed**,
and `research/pedal-emulation-approaches.md` §4's warning about widening the stride still applies only
to the graphic-EQ outlier, which is untouched here.

One change is needed on the AU surface: `StreetRigDSPUnit.exposedPedalFields` currently exposes only
four fields per slot (`Enabled`, `Drive`, `Tone`, `Level` — i.e. `Param0…Param2`). Delay needs
`Param3`/`Param4` automatable. Add two `PedalFieldSpec` rows at `SRPedalFieldParam3` (6) and
`SRPedalFieldParam4` (7). **The addresses already exist and are already reserved**, so nothing moves
and persisted host automation still resolves. Tree size goes 44 → 62 (§7.9).

### 5.5 Latency

**Neither block adds reported latency.** Both are wet paths summed against a sample-aligned dry path
— the dry signal is never delayed, so the block's group delay at DC is zero. `CabinetConvolver`'s
`latencySamples()` (128, one partition) therefore remains the only reported latency in the graph, and
`SRKernelCabLatencySamples` needs no change.

This is worth stating explicitly because it is the opposite of the pitch family, which genuinely does
add latency and is deferred partly for that reason
(`research/pedal-emulation-approaches.md` §3 Pitch, §7 Phase 4).

---

## 6. Signal flow, before and after

**Today** (`SRKernelProcess`, per channel):
```
input gain → PedalChain.process(all slots) → AmpCabProcessor.process:
                                                 AnalogAmp (95 Hz HP → 4× tanh → 8 kHz LP)
                                                 → ToneStack (4 fixed bands)
                                                 → ampOut
                                                 → CabinetConvolver
             → output level
```

**After Phase A + B:**
```
input gain
  → PedalChain.processSpan(0, splitPre)                 [PRE: Booster, Mod]
  → AmpCabProcessor.processPreamp:
        input HP (profile.inputHz)  ·  bright shelf (profile.brightHz/DB)
        ┌─ 4× OVERSAMPLED REGION ─────────────────────────────────────┐
        │  for s in 0..<stageCount:                                   │
        │     coupling HP → cathode shelf → × gain → clip(s) → Miller │
        └─────────────────────────────────────────────────────────────┘
        → ToneStack (profile-voiced: hz, q, rangeScale, noonDB, bassEatsMid, insertionDB)
  → PedalChain.processSpan(splitPre, splitPost)         [MID: FX, Delay, Reverb]
  → AmpCabProcessor.processPowerAmp:
        × ampVolume  ·  NFB shelf  ·  presence shelf  ·  sag envelope
        ┌─ 2× OVERSAMPLED REGION ─┐
        │  output-stage clip       │
        └──────────────────────────┘
        → OT low/high rolloff  ·  × outTrim  ·  × postMakeup
  → CabinetConvolver (unless profile.bypassCab)
  → PedalChain.processSpan(splitPost, active)           [POST: post-loop FX]
  → × ampMaster → output level
```

**Three deliberate restructuring decisions:**

1. **The preamp cascade widens inside the *existing* 4× oversampled region.** `AnalogAmp` already
   owns a proven polyphase-up / windowed-sinc-down design; growing its interior from one waveshaper
   to N stages costs one up/down conversion regardless of stage count. This is why the stage filters
   must be one-poles: at 4× oversampling, a biquad per filter per stage would be 48 biquad-equivalents
   per base sample for a 4-stage amp.
2. **The tone stack does not move and does not change rate.** It stays at base rate between the
   preamp and the power amp — the classic voicing position, and where it already is. Its
   double-buffered coefficient hand-off (`sets_[2]` + `std::atomic<int> live_`) is untouched. Only
   `recompute()`'s *inputs* change: per-band `hz`/`q` come from the profile, and the incoming bus dB
   becomes `noonDB + busDB × rangeScale`, minus `bassEatsMid × max(0, bassDB)` on the mid band. **All
   of that arithmetic happens on the main thread inside the existing `recompute()`, at zero
   audio-thread cost.**
3. **The power amp gets its own small 2× region rather than joining the preamp's.** Running the tone
   stack at 4× to share one region would cost ≈ 80 mults/sample (4 biquads × 4); a dedicated 2× stage
   with a 16-tap FIR costs ≈ 48. It is cheaper, it leaves `ToneStack` alone, and 2× is sufficient
   because the power stage's input is already band-limited by the tone stack and Miller poles and it
   is driven far more gently than the preamp.

---

## 7. Integration seams — file by file, symbol by symbol

Every symbol below was read in the repo, not recalled.

### 7.1 `StreetRigEngine/Audio/StreetRigDSPKernel.h` — new addresses and one new setup call

`SRParameterAddress` is **append-only** and currently ends at `SRParamAmpPresence = 11`.

```c
    // --- Prompt 004: per-amp voicing ---
    SRParamAmpVolume = 12, ///< Channel volume INTO the power amp (unity = 1.0). Katana "Volume".
    SRParamAmpPower  = 13  ///< Power-amp headroom scale (1.0 = 100 W, 0.70 = 50 W, 0.14 = 0.5 W).
```

Two, and only two. Everything else is either structural (a setup call, not an address) or already on
the structured pedal bus.

**The profile itself is NOT an address.** It redesigns filters, which means trigonometry, which must
not happen on or near the audio thread. It gets a setup call mirroring `SRKernelConfigurePedal`:

```c
/// Select the amp's VOICING PROFILE (streetrig::AmpVoicing) and (re)design its
/// preamp cascade, tone-stack centres and power-amp stage. Setup thread only
/// (call inside the reconfigure barrier). Mirrors SRKernelConfigurePedal.
void SRKernelConfigureAmp(SRKernelRef kernel, int profile);
int  SRKernelActiveAmpProfile(SRKernelRef kernel);

/// PedalChain span split points (see §4.5). Setup thread only.
void SRKernelSetPedalSplits(SRKernelRef kernel, int splitPre, int splitPost);
```

This matches the precedent exactly: pedal Type and Character are also structural and also live in
setup calls rather than the `AUParameterTree` (`StreetRigDSPUnit` comment: *"Type / Character are
structural → serialized state, not here"*).

`PedalChain::Type` gains `Delay = 8, Reverb = 9` (§5).

### 7.2 `StreetRigEngine/Audio/StreetRigDSPKernel.cpp`

- `SRKernelSetParameter`: two new cases. `SRParamAmpVolume` and `SRParamAmpPower` are **ramped
  gains**, so they join the `RampedGain` family via `gainForAddress` — the same treatment
  `SRParamAmpDrive` / `SRParamAmpMakeup` already get, which is what makes the power switch
  click-free.
- `SRKernelSetParameter`, `SRParamAmpPresence` case: today it is unconditionally
  `k->processor.setToneBandDB(3, value)`. It becomes one call into the processor
  (`k->processor.setPresenceDB(value)`) which routes to tone band 3 or to the power-amp shelf
  depending on the resolved profile (§3.2). The kernel stays profile-agnostic; the routing decision
  lives with the profile, in `AmpCabProcessor`.
- `SRKernelGetParameter`: the matching readback (the `RampedGain` branch handles it automatically).
- `SRKernelProcess`: `AmpCabParams` gains `ampVolume` and `powerScale`; the single
  `processor.process(...)` call becomes `processPreamp(...)` → `pedals.processSpan(mid)` →
  `processPowerAmp(...)` → cab → `pedals.processSpan(post)`.
- New `SRKernelConfigureAmp` / `SRKernelActiveAmpProfile` / `SRKernelSetPedalSplits` implementations.

### 7.3 `StreetRigEngine/Audio/AnalogAmp.hpp` / `.cpp`

- New `void configure(const AmpProfile &p) noexcept` — designs per-channel one-poles for
  `stageCount` stages plus the input HP and bright shelf. Setup thread. Mirrors
  `DrivePedal::configure(int)`.
- `ChannelState` gains a `Stage[kMaxStages]` array of one-pole states. Fixed size, no allocation.
- `process()` gains the stage loop inside the existing oversampled region; the `drive` argument
  multiplies into stage 0's gain exactly as today, so the Legacy path is unchanged.
- `Biquad`'s `highpass` / `lowpass` / `lowShelf` / `highShelf` / `peaking` designers are unchanged
  and are what the tone stack and the NFB/presence/OT shelves use.

### 7.4 `StreetRigEngine/Audio/AmpCabProcessor.hpp` / `.cpp`

- `AmpCabParams` gains `float ampVolume = 1.0f;` and `float powerScale = 1.0f;`.
- `ToneStack` gains `void configure(const ToneStackVoicing &v) noexcept` (stores the voicing, calls
  the existing `recompute()`), and `setBandDB` applies `noonDB + dB × rangeScale` and the
  `bassEatsMid` cross-term before designing. **The `sets_[2]` / `live_` double buffer, the
  `memory_order_release` publish and the per-channel `BiquadState` are all unchanged** — this is the
  pattern being generalized, not replaced.
- New `class PowerAmp` in the same header, alongside `ToneStack`, with the same shape:
  `prepare(sampleRate)`, `configure(const PowerAmpVoicing&)`, `reset()`,
  `process(buffer, n, channel, volume, powerScale, presenceDB)`. Per-channel state = NFB shelf,
  presence shelf, OT high-pass, OT low-pass, sag envelope, 2× oversampler history. All fixed-size.
- `AmpCabProcessor::process` splits into `processPreamp` and `processPowerAmp`.
- New `void configureAmp(int voicing) noexcept` — resolves `profileFor(voicing)` and fans it out to
  `analog_.configure`, `tone_.configure`, `power_.configure`. Setup thread.
- New `void setPresenceDB(float dB) noexcept` — the one place that knows whether presence belongs to
  tone band 3 (`Legacy`) or to the power-amp shelf (every profiled amp). Replaces the kernel's
  unconditional `setToneBandDB(3, …)`. Both destinations already recompute off the audio thread, so
  this adds no new threading concern. Main thread. `setToneBandDB` itself is unchanged for bands
  0–2.
- `kNumCabSlots` 4 → 8 (§1.5).
- **The neural hand-off is untouched**: `installNeuralModel`'s
  `std::atomic<NeuralAmpModel*>` exchange with one-generation retire stays exactly as it is, and is
  the pattern §2.6's per-amp captures ride on.

### 7.5 `StreetRigEngine/Audio/Pedals/PedalChain.hpp` / `.cpp`

- `enum Type` gains `Delay = 8, Reverb = 9`.
- `Slot` gains `DelayPedal delay;` and `ReverbPedal reverb;` — but **their buffers come from
  `arena_`**, not from members, so `Slot` grows by only the engines' scalar state.
- `PedalChain` gains `std::vector<float> arena_;` sized in `prepare()`, plus
  `std::atomic<int> splitPre_{kMaxPedals}, splitPost_{kMaxPedals};` (defaults put every slot in the
  PRE span — i.e. today's behaviour exactly).
- `configureSlot` gains two `case`s that assign the arena span, configure the voicing and zero the
  buffer — the same three-step shape every other family's case already has.
- `process(buffer, n, channel)` becomes `processSpan(buffer, n, channel, first, last)`, with the
  old signature kept as `processSpan(buf, n, ch, 0, activeCount())` for callers that do not split.

### 7.6 `StreetRigEngine/Audio/ParameterMap.swift`

Additions, all in the same style as what is there:

```
// Structural: which amp profile (mirrors streetrig::AmpVoicing)
static func ampProfile(name: String, values: [String: Double]) -> Int    // §2.4

// Continuous: two new forward curves
static func ampVolume(volumeKnob v: Double) -> Float { 0.2 + norm(v) * 1.6 }
static func ampPowerScale(_ watts: Double) -> Float  // 100 → 1.00, 50 → 0.70, 0.5 → 0.14

// Structural routing
static let typeDelay = 8, typeReverb = 9
// pedalType(for:) — .delay → typeDelay, .reverb → typeReverb
// pedalParams(category:values:) — .delay and .reverb cases per §5.2 / §5.3
```

**Inverse maps — the AUv3 host→UI bridge requirement.** `RigAUParameterBridge`
(`StreetRigEngine/Audio/RigAUParameterBridge.swift:50`) needs every forward curve to have an analytic
inverse so `knob → bus → knob` is the identity. Its `buildLinks(collection:rig:)` builds a
`[ParamLink]` where each link is `{ itemId, param, address, toBus, toKnob }` — so adding a bus-backed
knob means adding one `ParamLink` with **both** closures. There is no way to add half of one.

| Forward | Inverse | Notes |
|---|---|---|
| `ampVolume(volumeKnob:)` = `0.2 + norm·1.6` | `invAmpVolumeKnob(bus)` = `clampKnob((bus − 0.2) / 1.6 × 10)` | identical form to the existing `invAmpMasterKnob`, so it is a copy |
| `ampPowerScale(watts)` | `invAmpPowerWatts(bus)` — nearest of {1.00, 0.70, 0.14} → {100, 50, 0.5} | **indexed, not continuous in the UI**: the knob is a 3-position selector, so the inverse is a nearest-neighbour lookup, not a curve. The *bus* value is still continuous and ramped, which is what keeps the switch click-free |
| `ampBandDB(_:knob:)` | `invAmpBandKnob(_:dB:)` | **unchanged** — see below |
| delay `Param0…4`, reverb `Param0…2` | needed only if exposed as automatable AU params (they are, §5.4) — all are `a · 2^(norm·k)` or `a + norm·k`, both trivially invertible | same two forms already used throughout the file |

**The EQ curves deliberately do not change.** The per-amp tone character (`noonDB`, `rangeScale`,
`bassEatsMid`, per-band `hz`/`q`) is applied **in C++, inside `ToneStack::recompute()`**, not in
Swift. Three consequences, all good:

- `ampBandDB` and `invAmpBandKnob` are untouched, so no new inverse is needed and none can drift.
- The `AUParameter` domains stay `±12 dB` / `±9 dB`, so already-saved host automation lanes resolve
  to the same values they always did.
- The per-amp numbers live in **one** place (`AmpProfile.cpp`) rather than being split across two
  languages — which is the same reason `ParameterMap.swift` exists at all.

**One filter in `buildLinks` must widen.** Its pedal loop is guarded
`where pedal.category == .overdrive`, so only drive pedals currently get host→UI links. Phase B must
extend it to `.delay` and `.reverb` (and, while there, the other already-audible families), or the
Katana's Delay/Reverb knobs will move the sound from the app but will not follow host automation.
`Character`, `Variation` and `Power` do **not** get `ParamLink`s for the first two — they are
structural, and structural state travels in the rig blob, not on the parameter bus. `Power` does get
one, using the nearest-neighbour inverse above.

`ampUsesNeural(name:)` changes from `return true` to a profile-driven lookup (§2.6).
`cabSlot(name:)` keeps its current behaviour for Legacy amps.

### 7.7 `StreetRigEngine/Audio/RigGraphCompiler.swift`

`RigDSPPlan` gains:

```
public var ampProfile: Int = 0          // streetrig::AmpVoicing
public var ampVolume:  Float = 1.0
public var ampPower:   Float = 1.0      // headroom scale
public var splitPre:   Int = 8          // default: every pedal PRE (today's behaviour)
public var splitPost:  Int = 8
```

`compile(collection:rig:arSlots:)` sets them from the amp item's `values`;
`applyStructure` calls `dsp.configureAmp(plan.ampProfile)` and
`dsp.setPedalSplits(plan.splitPre, plan.splitPost)`; `pushValues` pushes `SRParamAmpVolume` and
`SRParamAmpPower`.

**The topology signature.** Currently:

```swift
plan.signature = "P[\(pedalSig)]|amp:\(plan.useNeural ? "n" : "a")|cab:\(plan.cabSlot)|combo:\(isCombo)"
```

Becomes:

```swift
plan.signature = "P[\(pedalSig)]|split:\(plan.splitPre)/\(plan.splitPost)"
               + "|amp:\(plan.ampProfile)/\(plan.useNeural ? "n" : "a")"
               + "|cab:\(plan.cabSlot)|combo:\(isCombo)"
```

`ampProfile` is added rather than replacing the neural flag, so the existing behaviour is a strict
subset and nothing that used to rebuild stops rebuilding.

### 7.8 `StreetRigEngine/Models/Gear.swift` — per-item amp knobs

**The per-item mechanism already exists and does not need inventing.** `GearItem.parameters` is
already `PedalSpec.parameters(forName: name, category: category)` — a per-*model* lookup. Amps simply
fall through its last case to `category.parameters` (the six fixed knobs). So the change is to add
amp branches to `PedalSpec`, not to restructure anything:

```
case .amp, .comboAmp:
    if n.contains("katana") {
        return p(["Gain","Bass","Mid","Treble","Presence","Volume","Master",
                  "Character","Variation","Power"])
    }
    if n.contains("jc-120") || n.contains("jazz chorus") {
        return p(["Gain","Bass","Mid","Treble","Bright","Master"])   // no Presence — §3.2
    }
    return category.parameters                                        // the existing six
```

Two consumers still take the **category** route and must be switched to `item.parameters`, or they
will show the wrong knobs for a Katana:

| File:line | Current | Required |
|---|---|---|
| `StreetRigEngine/UI/PluginEditorView.swift:240` | `ForEach(item.category.parameters)` | `ForEach(item.parameters)` |
| `StreetRig/Views/AmpModel3DView.swift:122` | `GearCategory.amp.parameters.map { $0.name }` | derive per item — the 3D faceplate must draw the amp's *own* knobs |

Three consumers are already correct and need no change: `ControlBoardView.swift:27,65`,
`ComponentDetailView.swift:42`, and `GearItem.init`'s default-values construction.

**Saved-JSON compatibility.** `GearItem.values` is `[String: Double]`, so new keys are purely
additive: an old `rig_state.json` simply lacks them.

- `RigGraphCompiler.compile` already reads with a default:
  `let v: (String) -> Double = { ampItem?.values[$0] ?? 5 }`. **A default of 5 is wrong for the new
  index-valued knobs**, so they need explicit per-key defaults: `Character → 2` (Crunch),
  `Variation → 0` (A), `Power → 100`, `Volume → 5`, `Bright → 0`.
- **Do NOT bump `RigStore.catalogVersion`.** It is currently `3`, and `RigStore.load` returns `nil`
  for any state older than the current version, which makes the caller **re-seed and discard the
  player's rig**. The comment in `RigStore.swift` is explicit that the bump exists for *renames*,
  because the icon seam matches on name. Adding knobs renames nothing and defaults cleanly, so the
  version must stay at 3. This is the single most damaging mistake available in this change.

### 7.9 The AUv3 surface — `StreetRigDSPUnit.swift`

| Item | Today | After | Stability |
|---|---|---|---|
| `AUParameterTree` size | **44** (12 amp/global + 8 slots × 4 fields) | **62** (14 + 8 × 6) | every existing address is unchanged; both growths are appends |
| New amp params | — | `ampVolume` (addr 12, `.linearGain`, 0…4, def 1.0), `ampPower` (addr 13, `.linearGain`, 0.05…1.0, def 1.0) | appended to `ampGroup` |
| New pedal fields | `exposedPedalFields` = Enabled, Drive, Tone, Level | `+ Param3, Param4` at `SRPedalFieldParam3` (6), `SRPedalFieldParam4` (7) | addresses already reserved by `SRPedalParamStride = 8` |
| `cabSelect` range | `0…3` | `0…7` | widening a max is safe; every stored 0–3 stays valid |
| `fullState` / `fullStateForDocument` | key `"streetrig.rig.v1"` + `super`'s params | unchanged key | new `GearItem.values` entries ride inside the blob; new params ride in `super`'s dictionary |
| `syncParameterTree(from:)` | sets 10 amp addresses + per-slot fields | `+ SRParamAmpVolume`, `+ SRParamAmpPower`, and `maxParams` already computes `stride − Drive = 5`, so `Param3/4` flow with no change | — |
| `factoryPresets` | `makeFactoryRigs()` | append Katana rigs | **never reorder** — a host may have stored `preset.number` |
| `applyRig` → `applyHotSwap` | fade/park barrier | unchanged; `configureAmp` and `setPedalSplits` join `applyStructure` | — |

**What must stay stable for already-saved host sessions:** every existing `SRParameterAddress` value
(0–11), the `SRPedalParamBase`/`Stride` layout, the `"streetrig.rig.v1"` key, and the existing factory
preset numbering. All four are preserved.

### 7.10 Verification harness

`StreetRig/Audio/AudioEngineController+OfflineRender.swift` already runs the full compiled-rig suite
through the real AU graph. Phase A adds:

- **Legacy null test** — the seed rig rendered through `AmpVoicing::Legacy` must be bit-identical to a
  pre-change render. This is the back-compat proof from §2.5.
- **Six-amp differentiation test** — render the same DI through each of the six profiles and assert
  that every pair differs by more than a threshold in per-octave RMS. "They sound different" becomes
  a measurement, not an opinion, and it is the exit criterion for Phase A.
- **Power-switch click test** — sweep `SRParamAmpPower` 1.00 → 0.14 mid-render and assert
  `max |Δsample|` stays under the existing barrier test's threshold. Reuses `barrierFadeTest`'s
  machinery.

---

## 8. Real-time safety — how each new thing obeys the contract

`RealtimeSafety.md` forbids allocation, locks, ARC and I/O on the render thread. Every proposal above
maps onto one of the two existing patterns.

| New thing | Pattern | Where it runs |
|---|---|---|
| Profile resolution (`profileFor`) | pure function returning a POD by value | setup thread, inside the reconfigure barrier |
| Preamp stage coefficients | designed in `AnalogAmp::configure`, written into preallocated per-channel state | setup thread (`SRKernelConfigureAmp`) |
| Tone-stack coefficients | **the existing double-buffer**: design into `sets_[inactive]`, publish with one `memory_order_release` store to `live_` | main thread (`setBandDB` on a knob turn) |
| Power-amp coefficients | designed in `PowerAmp::configure` into preallocated state | setup thread |
| Presence / Volume / Power values | plain `RampedGain` atomics, linearly ramped across the buffer | main writes, audio reads + ramps |
| Sag envelope | per-channel one-pole over preallocated state | audio thread, no allocation |
| Cab slot growth 4 → 8 | `std::vector<float> cabSlots_[8]`, filled by `loadCabIRSlot`; `setActiveCabSlot` re-partitions | setup thread only — unchanged from today |
| Neural per-amp capture | **the existing one-generation atomic retire** in `installNeuralModel` | setup thread installs; audio thread only ever reads a fully-constructed model |
| Delay / reverb buffers | **one arena `std::vector<float>` sized in `PedalChain::prepare`**, never resized; spans assigned in `configureSlot` | setup thread |
| Span splits | two `std::atomic<int>` | main writes, audio reads |
| Profile / character / variation / split changes | fade/park **reconfigure barrier** (`SRKernelSetReconfiguring` + `SRKernelGetParkedBufferCount`) | background reconfigure queue, never main or audio |

Nothing on the audio thread allocates, locks, does I/O, or computes a transcendental for filter design.
The only `tanh` calls are the waveshapers, which are already there (§10 flags replacing `std::tanh`
with a rational approximation as an optimization, not a correctness issue).

---

## 9. Structural vs continuous — the decision that keeps knobs from clicking

### 9.1 The rule

A control is **structural** (fade/park rebuild) if changing it redesigns filters or changes the graph
shape. It is **continuous** (lock-free bus, de-zippered) if it only moves a scalar. Getting this wrong
is audible in both directions: a knob on the structural path clicks and drops out; a switch on the
continuous path either does nothing or zippers.

The precedent to follow is recorded in `RigGraphCompiler.compile`: `enabled` was **deliberately
removed** from the signature so AR footswitch stomps stay on the continuous path.

### 9.2 Per Katana control

| Control | Path | Why |
|---|---|---|
| **Character** (Acoustic…Brown) | **Structural** | A different profile: different `stageCount`, clip families and filter corners. Cannot be interpolated. A 5-position rotary — nobody sweeps it |
| **Variation** (A / B) | **Structural** | Same reason — it *is* a second profile (§4.3) |
| **Power** (0.5 / 50 / 100 W) | **CONTINUOUS** | Maps to `headroomScale`, `sagScale`, `otLowScale`, `postMakeup` — four scalars, all interpolatable. A rebuild here would be audibly *worse* than the hardware, which switches instantly and silently. **Deliberately excluded from the signature** |
| Gain | Continuous | `SRParamAmpDrive`, unchanged |
| Bass / Mid / Treble | Continuous | tone-stack coefficient double-buffer, unchanged |
| Presence | Continuous | still `SRParamAmpPresence` (addr 11) and still a dB value on the bus, but for a profiled amp the kernel routes it to the power-amp shelf instead of tone band 3 (§3.2). Same address, same domain, same de-zippering — the routing is a profile property, not a bus change |
| **Volume** | Continuous | new `RampedGain` at address 12 |
| Master | Continuous | `SRParamAmpMakeup`, unchanged |
| Booster / Mod / FX **on-off** | Continuous | `SRPedalFieldEnabled` — the AR-footswitch precedent applies exactly |
| Booster / Mod / FX / Delay / Reverb **knobs** | Continuous | `Param0…Param4`, de-zippered per family |
| Booster / Mod / FX / Delay / Reverb **type selection** | **Structural** | Changes a slot's `Type`/`Voicing` → `configureSlot` under the barrier, as today |
| **FX routing position** (pre/mid/post) | **Structural** | Reorders the graph; `splitPre`/`splitPost` are in the signature |
| Cab pairing | **Structural** | `setActiveCabSlot` re-partitions the convolver — already structural today |

### 9.3 What the signature must and must not contain

**Must:** pedal type/voicing per slot (already), `splitPre`/`splitPost`, `ampProfile`, `useNeural`,
`cabSlot`, `isCombo`.

Note that **Character and Variation need no signature fields of their own.** They are already baked
into `ampProfile` by `ampProfile(name:values:)` = `ampKatanaBase + character*2 + variation` (§2.4), so
turning the Character selector changes the profile id, which changes the signature, which triggers the
rebuild. One field, three controls, no way for them to drift apart.

**Must not:** any knob value, `enabled` (existing precedent), and **`ampPower`**. If the power scale
entered the signature, flipping the power switch would fade the amp to silence, park the render
thread, rebuild and fade back in — a ~60 ms dropout in place of a 5 ms glide.

---

## 10. CPU budget

**Baseline, measured.** Full-board render (pedals + amp + tone + cab, seed rig) ≈ **7.74 %** of the
~2667 µs 128-frame deadline, Debug −O0 (`AudioEngineController+OfflineRender.swift`). Within that,
`RealtimeSafety.md` records amp→cab ≈ 5.7 % with *"the LSTM forward pass dominates; the vDSP
convolution adds < 0.2 %"*. So roughly: LSTM ≈ 4.5–5 %, analog amp + tone stack ≈ 0.5–1 %,
convolver ≈ 0.2 %, pedals ≈ 2 %.

**Estimated deltas.** Per base sample per channel, taking the current `AnalogAmp` (~106 multiplies +
4 `tanh`) as the unit:

| Addition | Cost estimate | vs. baseline board |
|---|---|---|
| Per-amp preamp cascade, 3 stages | ~250 mults + 12 `tanh` (≈ 2.4× today's `AnalogAmp`) | **+0.7 … +1.5 %** |
| Per-amp preamp cascade, 4 stages (Lead / Brown) | ~300 mults + 16 `tanh` | **+1.0 … +2.0 %** |
| Richer tone stack | **±0 %** — same 4 biquads; only coefficient *design* changes, and that is main-thread | **0 %** |
| Power-amp stage (NFB + presence + sag + 2× clip + OT) | ~90 mults + 2 `tanh` | **+0.3 … +0.5 %** |
| **Removing the LSTM** for profiled amps | −(LSTM cost) | **−4.5 … −5 %** |
| Dattorro reverb, one slot | ~60 flops | **+0.2 … +0.3 %** |
| Delay, one slot (Hermite + tape colour) | ~40 flops | **+0.15 … +0.25 %** |

**Verdict: the full Katana panel fits, and Phase A is very likely net *cheaper* than today.** A
profiled amp replaces ~4.5–5 % of LSTM with ~1.5–2.5 % of profile chain. Even loading every FX block
(booster + mod + FX + delay + reverb, five slots) the board should land near or below the current
7.74 %.

**Two caveats, both actionable:**

1. **`std::tanh` is the hot spot, not the filters.** Twelve to sixteen `tanh` calls per sample per
   channel at 20–40 cycles each dominates the stage cascade. The available fix is a rational
   approximation — `x·(27 + x²)/(27 + 9x²)` (Padé 3/2, accurate to ~0.5 % for |x| < 3, saturating
   beyond) or the cheaper `x/(1 + |x|)` family — inside the stage loop, worth roughly a 3× speedup of
   the dominant term.

   **But it is a *conditional* optimization, not a default, because it interacts with the Phase A
   exit criteria.** Swapping the shape function changes the waveform, so the Legacy null test
   (§2.5) stops being bit-exact and becomes a residual-tolerance test. **Phase A ships `std::tanh`
   and a bit-exact null test.** Only if `SRKernelBenchmarkFullNsPerSample` says the board does not
   fit does the approximation go in — and then the exit criterion is explicitly restated as
   "Legacy residual below −90 dBFS" rather than silently weakened. Correctness contract first,
   cycles second.
2. **Measure, do not trust this table.** `SRKernelBenchmarkFullNsPerSample(kernel, frames,
   iterations)` already exists and is the definitive number. Run it per profile.

**Fallback if it does not fit** (in the order to apply them):

| Step | Saves | Costs |
|---|---|---|
| 1. Rational `tanh` approximation (above) | ~1 % | negligible audible difference |
| 2. Drop the preamp oversampling 4× → 2× for `Clean`-family stages (they barely clip) | ~0.4 % | nothing — a clean stage generates no images to fold |
| 3. Cap `stageCount` at 3, fold Lead/Brown's fourth stage into a higher gain on stage 3 | ~0.5 % | slightly less compound saturation on the two highest-gain voicings |
| 4. Run the power stage at base rate (no 2× region) | ~0.3 % | mild aliasing on the output-stage clip; masked by the OT low-pass and the cab IR |
| 5. Skip the output-stage **clip and its 2× oversampler** when `headroom > 2.0` (Acoustic, JC-120, Twin); the NFB/presence/OT sub-blocks still run | ~0.4 % on those amps | none — those stages never reach clipping anyway. **Do this unconditionally; it is free** |

---

## 11. The tuning table — the contract between the spec and the ear

**This table is the contract.** The implementation must place every value below in **one auditable
location** — `StreetRigEngine/Audio/AmpProfile.cpp`'s `profileFor()`, exactly as
`DrivePedal.cpp`'s `voiceFor()` holds the pedal numbers and `ParameterMap.swift` holds the knob
curves — so the owner can adjust them against a real amp through an iRig without hunting through DSP.

Confidence: **H** grounded in published circuit values · **M** derived from topology · **L** educated
guess. Spend tuning time on the L rows first.

### 11.1 Architecture constants

| Parameter | First pass | Plausible range | What to listen for | Conf |
|---|---|---|---|---|
| Preamp oversampling | 4× | 2× … 8× | Play a high open chord with Gain past 7. Harsh non-musical "gravel" that changes pitch with the note = aliasing; go up. No change from 4× to 8× = go down to 2× and take the CPU back | H |
| Power-amp oversampling | 2× | 1× … 4× | Same test with Gain low and Volume high. If 1× and 2× are indistinguishable, drop to 1× | M |
| Stage waveshaper | **`std::tanh`** (Phase A default) | vs Padé `x(27+x²)/(27+9x²)` | Only swap if the CPU measurement demands it (§10 caveat 1). A/B the same riff: if the approximation sounds fizzier on the top end, revert and pay the cycles | M |
| Tone-stack sample rate | base rate | base or 4× | Sweep Treble hard with Gain high. Any "graininess" that tracks the knob = move it into the oversampled region | M |
| De-zipper time constant | 5 ms | 2 … 20 ms | Turn Master fast. Stepping/zippering = raise. Knob feels laggy = lower. **Reuses the existing `smoothCoeff_`** | H |
| Delay-time slew | 100 ms | 30 … 400 ms | Turn Time with repeats running. Clicking = raise. No tape-style pitch glide = raise. Sluggish = lower | M |
| `kMaxDelaySeconds` | 2.0 s | 1.0 … 4.0 s | Only a memory decision: 8.0 MB @ 2.0 s, 4.0 MB @ 1.0 s. Drop to 1.0 if memory pressure shows on older devices | H |

### 11.2 Tone stack — the highest-value rows in the document

| Parameter | First pass | Plausible range | What to listen for | Conf |
|---|---|---|---|---|
| Twin `mid.noonDB` | **−11 dB** | −8 … −14 | Clean chords with everything at noon. Should sound scooped and glassy, *not* boxy. If it sounds nasal, go more negative; if chords vanish in a band mix, back off | M |
| Twin `mid.hz` | 400 Hz | 350 … 500 | The scoop should sit under the low strings' body. Too high = thin; too low = muddy | H |
| Twin `bassEatsMid` | 0.55 | 0.3 … 0.8 | Turn Bass from 3 to 8. Mids should visibly hollow out — that interaction *is* the Fender stack. No change = raise | M |
| JCM800 `mid.noonDB` | **−7 dB** | −4 … −10 | Should be noticeably *more* mid-present than the Twin at identical knob settings. If a JCM800 and a Twin still sound alike at noon, this row and the Twin's are the first suspects | M |
| JCM800 `mid.hz` | 650 Hz | 600 … 750 | Palm-muted riffing should have "bark". Too low = woolly; too high = honky | H |
| AC30 `mid.noonDB` | **+2 dB** | 0 … +4 | The AC30 must be the *only* mid-forward amp of the six. If it sounds scooped, the sign is wrong | M |
| AC30 `power.presenceScale` | **−0.8** | −0.5 … −1.2 | Turn Presence **up**: the amp must get *darker* (this is the Vox Cut). If it brightens, the sign is wrong | H |
| JC-120 `insertionDB` | −6 dB | −3 … −10 | JC's EQ is active, so it should lose far less level than the passive stacks. If the JC is much quieter than the Twin at matched knobs, raise | M |
| Katana all-band `noonDB` | ≈ 0 | −2 … +2 | The Katana must be the flattest-at-noon of the six. If it sounds coloured with the EQ centred, zero these | M |
| `power.presenceScale` (default) | 1.0 | 0.6 … 1.4 | Presence should add air and edge without hiss. Hissy = lower; inaudible = raise | M |

### 11.3 Preamp cascade

| Parameter | First pass | Plausible range | What to listen for | Conf |
|---|---|---|---|---|
| JCM800 S1 `cathodeHz` / `cathodeDB` | **480 Hz / +8 dB** | 350–650 Hz / +5…+11 dB | Palm mutes should be tight and percussive. **Flubby palm mutes = raise the Hz.** Thin and brittle = lower it or reduce the dB | H |
| JCM800 S2 `cathodeHz` / `cathodeDB` | 674 Hz / +6 dB | 500–850 Hz / +4…+9 dB | Upper-mid "bark" on power chords. Too much = honky and nasal | H |
| JCM800 stage `couplingHz` | 32 / 40 / 48 Hz | 20–70 Hz | Low E chugs should stay defined under gain. Mushy = raise all three ~10 Hz | M |
| Twin stage `cathodeHz` | **0 (fully bypassed)** | keep at 0 | The Twin must amplify bass and treble equally. Any shelving here and it stops being a Twin | H |
| Twin stage `gain` | 1.5 / 1.4 | 1.2 … 2.0 | Should stay clean to Gain ≈ 8 and only then break up politely. Distorting at 5 = lower | M |
| AC30 S2 `cathodeHz`/`dB` | 250 Hz / +5 dB | 150–400 Hz / +3…+7 dB | Top-boost chime on open chords. Missing = lower Hz slightly and raise dB | M |
| JC-120 stage `asym` | **0.00** | keep at 0 | Zero even harmonics — clinically clean. Any warmth means the asymmetry leaked in | H |
| Katana Crunch A stage gains | 2.0 / 2.1 / 1.5 | ±30 % | With Gain at noon it should sit *right at* edge-of-breakup. Already crunchy at 3 = lower; clean at 7 = raise | L |
| Katana Brown B stage gains | 2.9 / 3.1 / 2.9 | ±25 % | Should be the most saturated of the ten and still articulate on fast runs. Mushy on fast picking = raise `couplingHz`, not lower the gain | L |
| Katana `inputHz` per character | 40 → 105 Hz | 30 … 120 | Higher-gain characters need a higher input HP. If Brown is flubby on the low string, raise toward 120 | L |
| Stage `millerHz` (all amps) | 10–25 kHz descending | 8 … 30 kHz | Fizz on the top of a high-gain voicing = lower the last stage's Miller to ~9 kHz | M |

### 11.4 Power amp

| Parameter | First pass | Plausible range | What to listen for | Conf |
|---|---|---|---|---|
| AC30 `headroom` | **0.55** | 0.4 … 0.8 | Must compress and bloom noticeably by Volume 6. Still clean at 8 = lower | M |
| Twin `headroom` | **1.60** | 1.2 … 2.5 | Must stay clean with Volume maxed. Any grit = raise | H |
| JC-120 `headroom` | **3.00** | 2.5 … 4.0 | Must *never* break up. If it does, raise — and check `power.clip` is `SolidState` | H |
| Bassman `sagDepth` | **0.30** | 0.15 … 0.45 | Hit a hard chord: it should duck then bloom back over ~60 ms. No duck = raise; pumping/seasick = lower | H |
| Bassman `sagTauMs` | 60 ms | 30 … 120 | Too short = the duck sounds like a click. Too long = the amp sounds broken | M |
| AC30 `nfbDB` | **0 (no NFB)** | keep at 0 | Must feel loose and touch-responsive vs the Marshall's tightness. If it feels tight, NFB leaked in | H |
| Twin `nfbDB` | **−5.0 dB** | −3 … −8 | Should feel the *tightest* of the six. Loose or woofy = go more negative | M |
| Class AB crossover knee | 0.02 asym | 0 … 0.08 | A faint "grainy" edge as notes decay to silence = the crossover artefact. Present but not buzzy is right | L |
| `otLowHz` (EL84 / 6L6) | 80 / 45 Hz | 35 … 100 | The AC30 should sound smaller than the Twin on the low string even through the same cab | M |
| `otHighHz` (EL84 / 6L6 / SS) | 8 k / 11 k / 14 k | 7 … 16 kHz | The JC should be the brightest and the AC30 the most rolled-off | M |

### 11.5 Katana power control

| Parameter | First pass | Plausible range | What to listen for | Conf |
|---|---|---|---|---|
| 0.5 W `headroomScale` | **0.14** | **0.071** (physical) … 0.25 | 0.5 W should sound like a small cranked amp, not a fuzz pedal. **Sounds like a fuzz = raise toward 0.25. Sounds identical to 50 W = lower toward the physical 0.071** | M |
| 50 W `headroomScale` | 0.70 | 0.6 … 0.8 | Should sit audibly between the other two. Indistinguishable from 100 W = lower | H |
| `sagScale` at 0.5 W | 1.60 | 1.2 … 2.2 | The small setting should breathe and pump more. Seasick = lower | L |
| `postMakeup` clamp | 8.0 | 4 … 14 | 0.5 W should be a *little* quieter than 100 W, not silent and not equal. Perceived level collapses = raise the clamp | M |
| `otLowScale` at 0.5 W | 1.25 | 1.0 … 1.5 | The small setting should lose a little low end, like a small OT under load | L |

### 11.6 Delay and reverb

| Parameter | First pass | Plausible range | What to listen for | Conf |
|---|---|---|---|---|
| Delay time range | 40 … 1280 ms | 20 … 2000 ms | Slapback should be reachable near the bottom of the sweep, dotted-eighth near the middle | M |
| Max feedback | 0.95 | 0.90 … 0.99 | Should self-oscillate at the very top like the hardware, and be controllable just below | M |
| Digital feedback LP | 8 kHz | 6 … 12 kHz | Repeats should stay clear but not get *brighter* than the dry. Brighter = lower | M |
| Tape feedback LP | 4 kHz | 3 … 6 kHz | Each repeat noticeably darker than the last, gone by ~6 repeats | H |
| Tape wow / flutter | 0.5 Hz ±0.30 % / 6 Hz ±0.05 % | ±0.1…0.6 % / ±0.02…0.1 % | Repeats should waver just perceptibly. Seasick = lower the wow depth first | M |
| BBD feedback LP | 2.5 kHz | 2 … 4 kHz | Distinctly darker and more "analog" than the tape voicing | M |
| Reverb tank feedback range | 0.30 … 0.92 | up to 0.96 | Decay 10 should be a long wash but must still decay. Ringing forever = lower the top | M |
| Reverb damping range | 1.2 … 12 kHz | 800 Hz … 16 kHz | Tone 0 = dark room, Tone 10 = bright plate. Metallic ring at Tone 10 = lower the top and check the tank all-pass modulation is on | M |
| Reverb wet max | 0.70 | 0.5 … 1.0 | Mix 10 should be drenched but the dry must still be audible | M |

---

## 12. Phased rollout

| Phase | Prompt | Scope | Exit criteria |
|---|---|---|---|
| **A — Profile architecture + Katana core** | **002** | `AmpProfile` schema + `profileFor` table; `AnalogAmp` stage cascade; profile-voiced `ToneStack`; new `PowerAmp`; `SRParamAmpVolume`/`SRParamAmpPower`; `SRKernelConfigureAmp`; `ParameterMap.ampProfile`; `RigDSPPlan` + signature; per-item amp knobs in `PedalSpec`; `kNumCabSlots` 4 → 8; the six profiles + all ten Katana voicings; power control | **(1)** Legacy null test bit-exact. **(2)** Six-amp differentiation test passes: every pair differs measurably in per-octave RMS. **(3)** Power switch click-free under the sweep test. **(4)** `SRKernelBenchmarkFullNsPerSample` at or below today's 7.74 %. **(5)** No saved rig or host session changes behaviour |
| **B — Shared time-based blocks + Katana FX** | **003** | `PedalChain::Delay`/`Reverb` + the arena; three-span split (`splitPre`/`splitPost`); the three delay voicings; the Dattorro plate; `ParameterMap` type/param mapping; `Param3`/`Param4` on the AU tree; Katana FX block mapping; Katana factory presets | **(1)** All five silent catalog pedals audible. **(2)** Zero audio-thread allocation (arena sized in `prepare`). **(3)** No reported-latency change. **(4)** FX routing audibly differs pre vs mid vs post. **(5)** Katana presets round-trip through `fullState` |
| **C — deferred** | later | Frequency-dependent OT/speaker damping (true bloom); authored or licensed IRs for slots 2–7; per-amp neural captures; the pitch family (Katana's Octave/Harmonist/Defretter/Ring Mod, and the four catalog pitch pedals); true rotary; looper/tuner | — |

**Phase A is independently shippable and audibly meaningful on its own.** It is the phase that fixes
the stated problem: after Phase A, and with no FX work at all, a JCM800 and a Twin Reverb and an AC30
and a JC-120 are four different amps in the DSP — different cascade depths, different interstage
filtering, different tone-stack topologies and noon curves, different power-amp headroom, sag and
feedback. The Katana arrives complete except its FX section, which is exactly the part that is
supposed to be shared blocks anyway.

**Explicitly deferred, and why:**

| Deferred | Why |
|---|---|
| Frequency-dependent OT/speaker damping | Needs a speaker impedance model in the feedback path; belongs with cab work. The two static rolloffs get most of the audible benefit |
| IRs for cab slots 2–7 | This task may not download or bundle assets. The slots exist and are empty (transparent); the intended pairing is recorded in §3.4 |
| Per-amp neural captures | No rights-cleared captures exist. The slot (`AmpProfile::neuralModel`) is specified so they drop in later with no architectural change |
| Exact-network tone stack (bilinear-transformed 3rd-order transfer function) | Needs per-amp component values we cannot verify to the precision it demands. Four parametric bands + `noonDB` + one interaction term capture the audible differences. §13 Open Question 7 |
| Katana pitch-family FX | Already Phase 4 in `research/pedal-emulation-approaches.md` §7. No contradiction |
| Katana "Pushed" character (Gen 3's sixth) | Out of the stated five-character scope. It slots in as ids 20/21 with no schema change — which is itself a small proof the schema generalizes. §13 Open Question 2 |

---

## 13. Open questions

Things that could not be determined from the repo or from public technical knowledge, listed rather
than silently guessed.

1. **Katana channel-memory count.** Sources vary across generations (4 channel buttons; some
   generations bank them). §4.6's mapping is count-agnostic, but the UI needs a number.
2. **Whether the Gen-3 "Pushed" character is in scope.** The stated scope is five characters; current
   hardware has six. Ids 20/21 are free.
3. **What Variation actually changes per character.** Boss publishes nothing. §4.3 adopts one stated
   rule (B = hotter and tighter) applied consistently; the real amp may vary the rule per character.
   All ten rows are confidence **L** and are the top priority for the ear-tuning pass.
4. **Who authors or licenses the four to six additional cab IRs.** Slots 2–7 exist and are empty.
   Until they are filled, six amps share two boxes.
5. **Whether the JC-120 should expose a Bright switch instead of Presence.** §7.8 proposes it (the
   real amp has no presence control), but it is a product decision, and it is the first amp in the
   catalog whose knob set differs from the standard six.
6. **Whether any amp should keep the neural rail once profiles exist.** §2.6 proposes
   profile-driven (`neuralModel != nullptr`), with Legacy keeping today's `true`. If the placeholder
   capture is ever replaced by a real one, this needs revisiting.
7. **Measured insertion loss and mid-notch depth per stack.** The `noonDB` and `insertionDB` values
   in §3.2 are derived from topology, not measured with Duncan's Tone Stack Calculator or SPICE
   against verified component values. Running the real networks through a tone-stack calculator would
   promote most of §11.2 from **M** to **H** — the single highest-value follow-up research task.
8. **Whether the 0.5 W headroom scale should be the physical 0.071 or the conservative 0.14.**
   §11.5 carries the row with cues in both directions; only an A/B against the hardware settles it.
9. **Whether the three-span FX routing should be exposed in the app UI** or stay Katana-internal.
   The mechanism is general (any rig gets an FX loop); the UI cost is a new control.
10. **Whether `AmpProfile::bypassCab` should be user-overridable.** The Katana's Acoustic character
    sets it, but a player might reasonably want a cab on an acoustic voicing.

---

## 14. Legal / IP posture (a real consideration — not legal advice)

Same posture as `research/pedal-emulation-approaches.md` §6 and `research/3d-amp-rendering-options.md`:

- **Circuits and the *sound* of an amplifier are not themselves copyrightable.** Modeling behaviour
  from public schematics and published circuit analyses is the well-trodden, low-risk path — it is
  what boutique clones and every commercial modeler do. **Everything specified in this document is an
  algorithmic model built from public technical knowledge, so it carries no capture IP at all.**
- **Captures and impulse responses are recordings.** Capturing hardware **you own** for your own
  product is broadly what NAM / ToneX and similar enable, but **do not ship captures or IRs you do
  not have the rights to**. This is the one place the "sounds like" path can create a rights problem,
  and it is exactly why §2.6 keeps the neural slot empty and why §1.5 leaves cab slots 2–7 unfilled
  rather than sourcing IRs from somewhere convenient.
- **The Katana is a special case worth naming.** We are modeling a *modeling amp*. That does not
  change the analysis: the behaviour being modeled — cascaded gain staging, tone-stack response,
  power-amp compression — is the same physics whether the original implemented it in valves or in
  DSP. What must not happen is shipping Boss's own captures, IRs, presets or trademarks.
- **Names:** keep the re-badged catalog (VOSS / Marswell / Fandor / Volt / Rolund / Ibonez / …) as it
  already is. Model the behaviour, not the trademark. Note that `RigStore.catalogVersion`'s comment
  makes these names load-bearing for artwork, so renaming is a coordinated change, not a cosmetic one.

*This is not legal advice.*

---

## Sources

Tone stacks and amp circuits:
- [Rob Robinette — How the TMB Tone Stack Works](https://robrobinette.com/How_The_TMB_Tone_Stack_Works.htm) — 5F6-A / AB763 / JTM-45 component values, slope resistors, mid-pot wiring, the ~500 Hz noon scoop
- [Yeh & Smith — Guitar Effects Research @ CCRMA: Tone Stack](https://ccrma.stanford.edu/~dtyeh/tonestack/) — the 3rd-order transfer function and its bilinear digitization (the exact-network route §1.2 declines for now)
- [Modelling of the Fender Bassman 5F6-A Tone Stack (arXiv)](https://arxiv.org/pdf/2110.02285)
- [Texas Instruments TIPD186 — Tone Stack for Guitar Amplifier Reference Design](https://www.ti.com/lit/ug/tidu887/tidu887.pdf)
- [The Vox Tone Stack (Modified) — warpedmusician](https://warpedmusician.wordpress.com/2014/06/17/the-vox-tone-stack-modified/)
- [AmpBooks — Circuit Analysis of the Vox AC30](https://www.ampbooks.com/mobile/classic-circuits/vox-ac30/)
- [Steve's Amps — Voxiness: what makes the Vox AC30 sound that way?](https://www.stevesamps.co.uk/?page_id=287) — top boost gain stage + cathode follower, cathode bias, no NFB
- [Dr. Tube — Marshall JCM800 schematics](https://www.drtube.com/marshall-jcm800/)
- [Tone Lizard — The Ultimate JCM800](https://tone-lizard.com/the-ultimate-jcm800/) — cascaded V1a/V1b, the 0.68 µF cathode bypass
- [Vintage Guitar — Marshall JCM800 2203](https://www.vintageguitar.com/19826/marshall-jcm800-2203/)

Power amps, negative feedback and presence:
- [DDSP Guitar Amp: Interpretable Guitar Amplifier Modeling (arXiv 2408.11405)](https://arxiv.org/html/2408.11405) — differentiable push/pull power amp with a phase splitter, NFB loop and presence control; the linear-filter treatment of feedback that §1.3 follows
- [Aiken Amps — What is Negative Feedback?](https://www.aikenamps.com/index.php/what-is-negative-feedback)
- [Mojotone — Negative Feedback Loops: Taming Tone or Letting It Roar](https://mojotone.com/blogs/news/negative-feedback-loops-taming-tone-or-letting-it-roar)

Boss Katana:
- [Wikipedia — Boss Katana](https://en.wikipedia.org/wiki/Boss_Katana) — reactive Class AB analog power section, Variable Power Control, the Variation button, the Brown character's EVH lineage
- [BOSS — Katana: What's New in the Gen 3 Amplifier Series](https://articles.boss.info/boss-katana-whats-new-in-the-gen-3-amplifier-series/)
- [BOSS — Advanced Tips and Tricks for the BOSS Katana](https://articles.boss.info/advanced-tips-and-tricks-for-the-boss-katana/)
- [BOSS — Getting Started: BOSS Tone Studio and Katana](https://articles.boss.info/getting-started-boss-tone-studio-and-katana/) — the Booster / Mod / FX / Delay / Reverb categories
- [Using BOSS TONE STUDIO for KATANA (Roland PDF)](https://static.roland.com/assets/media/pdf/BTS_KATANA_eng03_W.pdf) — the Chain tab: effect order and pre/post-preamp placement
- [Guitar Chalk — Boss Katana 100 Settings and Tone Tips](https://www.guitarchalk.com/boss-katana-100-settings/)

Roland JC-120:
- [Roland — JC-120: The Clean Sound Revolution](https://articles.roland.com/roland-jc-120-the-clean-sound-revolution/)
- [Guitar World — How Roland's JC-120 became the king of solid-state guitar amps](https://www.guitarworld.com/features/how-rolands-jc-120-became-the-king-of-solid-state-guitar-amps)

Time-based effect DSP (shared with `research/pedal-emulation-approaches.md`):
- [Dattorro — Effect Design Part 1: Reverberator and Other Filters (via Valhalla DSP)](https://valhalladsp.com/2021/09/22/getting-started-with-reverb-design-part-2-the-foundations/)
- [Faust Libraries — reverbs (Freeverb, Dattorro, FDN)](https://faustlibraries.grame.fr/libs/reverbs/)
- [Wikipedia — Bucket-brigade device (BBD)](https://en.wikipedia.org/wiki/Bucket-brigade_device)

Modeling technique (shared):
- [Chowdhury et al. — A Comparison of Virtual Analog Modelling Techniques, CCRMA](https://ccrma.stanford.edu/~jatin/papers/Klon_Model.pdf)
- [GuitarML — GuitarLSTM](https://github.com/GuitarML/GuitarLSTM) · [NeuralPi (RTNeural)](https://github.com/GuitarML/NeuralPi)
