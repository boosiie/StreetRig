# Emulating Real Pedals in StreetRig — Approaches & Roadmap

**Status:** decision-ready · **Date:** 2026-08-11 · **Scope:** how to make each of the 47
catalog pedals (a re-badged list of real, famous units) *sound like the real thing* through
the existing real-time DSP engine (`StreetRig/Audio/`), and a phased plan to get there.

> Companion to `research/3d-amp-rendering-options.md` (which does the same for how pedals
> *look*). This doc is about how they *sound*.

**Direction chosen (2026-08-11):** for the **gain pedals**, pursue **circuit models (Wave
Digital Filters) built from public schematics — no neural hardware capture**; use algorithmic
DSP for the structural families. The neural-capture route is **parked** (see §5).

**Implemented (2026-08-11) — Phase 0 + first structural wave (offline-verified):** the
drive-only pedal slot is now an **any-family slot** — `PedalChain` preallocates one engine per
family and dispatches on the slot's Type — and six new real-time DSP engines shipped:
**EQ** (`EqPedal`), **Compressor + Noise Gate** (`DynamicsPedal`), **Wah + Volume**
(`FilterPedals`), and the full **Modulation** family (chorus/flanger/phaser/tremolo/univibe,
`ModulationPedal`). The voicing-name bug is fixed (`ParameterMap.pedalVoicing`, substring
match). ~**22 of the 47** pedals are now audible. All verified through the real AU graph by the
offline harness (per-family loud→quiet/burst tests, amp+cab bypassed) — `PEDAL FAMILIES
OVERALL: PASS`, with the existing amp/cab + full-rig suites still green. **Still deferred**
(big buffers / pitch / latency): **delay, reverb, pitch, tuner, looper**, plus the gain-pedal
WDF upgrade (§3, §7).

---

## TL;DR — the recommended path

1. **There is no single "emulate a pedal" technique — the list splits into two physically
   different problems.**
   - **Gain pedals** (overdrive / distortion / fuzz / compressor / boost) get their identity
     from a **nonlinear circuit** — how a specific clipping stage distorts, and how it reacts
     to your pickups and pick attack. These need **circuit modeling** or **neural capture**.
   - **Everything else** (delay, reverb, chorus/phaser/flanger/tremolo/vibe, pitch, wah, EQ,
     volume, gate, tuner, looper) gets its identity from a **signal-flow structure** —
     delay lines, all-pass filters, LFOs, envelope followers. These are **hand-built
     algorithmic DSP**, and you can get them *exact*. Neural nets are the **wrong tool** here
     (they don't model long delay memory or time-varying modulation well).
2. **Recommended overall: a hybrid, tier-by-family strategy** — build one good *engine per
   effect family* for the structural effects (covers ~30 of the 47 pedals cheaply and
   accurately), and reserve the expensive per-pedal modeling (circuit/neural) for the
   marquee gain pedals where character really is the circuit.
3. **Reuse what already exists.** The engine already ships (a) an oversampled waveshaper
   drive block (`DrivePedal`) that is a crude stand-in for ~9 of the drive/dist/fuzz pedals
   *today*, and (b) a **neural LSTM runtime** on the amp path (`Neural/NeuralAmpModel`,
   RTNeural-style `SimpleRNN` JSON). Pedal captures ride the *same* neural rail — no new
   runtime, just more models. Delay/reverb/mod/etc. slot into the *same* `PedalChain` pool
   as new block types (the code is already commented for exactly this extension).
4. **Sequence for maximum audible progress per unit effort:**
   **(a)** generalize the pedal slot from "drive-only" to "any family" (framework),
   **(b)** ship the *structural* families first — EQ, wah, volume, tremolo, delay, chorus,
   phaser, flanger, compressor, gate, reverb (mostly textbook DSP, huge coverage),
   **(c)** upgrade the *gain* pedals from the shared waveshaper to per-circuit models (WDF)
   or neural captures, marquee units first (ValveShrieker, SHREW, BigMitt, Chiron, FuzzDome),
   **(d)** tackle the hard/latency-sensitive ones last — polyphonic pitch (STACK/OC-5),
   Chorister, Slingshot, Freeze, looper.
5. **Legal, same posture as the 3D doc.** Circuits and the *sound* of an effect are not
   themselves copyrightable — you may model behavior from public schematics, and you may
   neural-capture hardware **you own**. But **never ship captures or impulse responses you
   don't have the rights to**, and keep the generic names. Circuit/algorithmic models
   sidestep the capture-IP question entirely.

---

## 1. The three emulation paradigms

| Paradigm | What it is | Best at | Weak at | Per-pedal cost | Knob realism | Fit to StreetRig |
|---|---|---|---|---|---|---|
| **Algorithmic / analytical DSP** | Build the effect from signal-flow primitives (delay lines, biquads, all-pass, LFOs, envelope followers) and *voice* it with parameters | Time-based & linear effects: delay, reverb, mod, EQ, wah, comp, gate, volume | Capturing the *exact* nonlinear grit of a specific gain circuit | **Low–med** (one engine covers a whole family) | Perfect (knobs are the real DSP controls) | **Native** — this is what `DrivePedal`/`ToneStack`/`CabinetConvolver` already are |
| **Circuit modeling** (Wave Digital Filters, nonlinear state-space, nodal analysis) | Solve the actual analog circuit's equations in real time from its schematic | Nonlinear gain circuits with *dynamic* behavior (FuzzDome cleanup, BigMitt stages, Chiron blend) | CPU per stage; each pedal is a modeling project; implicit nonlinear solves | **High** (per circuit) | **Excellent** — continuous, reacts like the real circuit | Additive C++ block; `chowdsp_wdf` is a header-only lib built for exactly this |
| **Neural capture** (black/grey-box: LSTM, WaveNet/TCN, GRU) | Train a small net to imitate a real unit from recorded input/output audio | Nonlinear "static-ish" pedals: OD/dist/fuzz/comp — matches SPICE-quality accuracy in real time | Time-varying & long-memory effects (delay/reverb/mod/pitch); needs the **real hardware** + capture rig; one net ≈ one knob setting unless conditioned | **Med** (capture + train) but **needs hardware/data** | **Good**, and knob-conditioning (FiLM / hypernetworks) can cover the knob space | **Runtime already exists** on the amp path — reuse RTNeural-style `SimpleRNN`/LSTM |

**Key point:** these are complementary, not competing. The state of the art in commercial
modelers (and in research like Chowdhury DSP's Chiron, which mixes **nodal analysis + WDF +
RNN** in one pedal) is to **pick the right paradigm per stage**. StreetRig should do the same.

---

## 2. What actually makes a pedal "sound like the real one"

Sort the 47 pedals by *where their character lives* — this dictates the paradigm:

- **Memoryless-ish nonlinearity (character = the clipping circuit).** OD/dist/fuzz/boost and
  (dynamically) compressors. The waveform is reshaped sample-by-sample, but the *voicing*
  filters around the clipper and the *circuit's reaction to source impedance and level* are
  what separate a ValveShrieker from a SHREW from a BigMitt. → **circuit model or neural
  capture.** A static waveshaper (what we have) gets you in the neighborhood but misses the
  dynamic feel (esp. fuzz).
- **Linear, time-invariant (character = a fixed filter).** EQ, wah (a swept filter), volume,
  clean boost's tone. → **biquads.** These can be made *bit-for-bit* faithful to the real
  frequency response; they're the easiest and most exact.
- **Linear, time-*varying* (character = an LFO moving a filter/delay).** Chorus, phaser,
  flanger, tremolo, univibe. → **all-pass/comb + LFO.** Exact once you match the topology
  (stage count, delay range, feedback, LFO shape/rate) and any analog coloration (BBD).
- **Long-memory (character = a delay/decay network).** Delay, reverb, looper, Freeze. →
  **delay lines + feedback / reverb networks.** Needs big preallocated buffers; the coloration
  (tape wow/flutter, BBD darkness, spring dispersion) is added on top.
- **Pitch (character = resampling/spectral).** Octave, Slingshot, Chorister, STACK. → **pitch
  shifting** — the hardest real-time class; mono time-domain (low latency) vs polyphonic
  phase-vocoder (needs ~50 ms history → latency). A defining trade-off, not a bug.

**Neural nets belong only in the first bucket.** Trying to LSTM a delay or a chorus is a known
dead end (they can't hold seconds of delay memory or a free-running LFO); those want DSP.

---

## 3. Per-category playbook (the 47 pedals)

For each family: what the real circuit does (grounded in the circuit analyses cited), the
recommended emulation approach, the core DSP block, and difficulty. Pedals from *your* list
are named.

### Overdrive — *ValveShrieker, BluesBlazer, Satyr/Chiron, DukeOfDrive, FIXATION* (5)
- **Circuit:** op-amp with **diodes in the feedback loop** → *soft, symmetric-ish* clipping,
  with a mid-hump from the feedback high-pass (the TS "720 Hz" bump) and a post low-pass. Chiron
  is special: a **parallel clean path blended with a germanium-clipped path** + charge-pump
  headroom + active tone — *not* a single clipper. DukeOfDrive ≈ two BluesBlazer-voiced
  channels. FIXATION is MOSFET-ish, more open/asymmetric.
- **Approach:** **circuit model (WDF)** or **neural capture** for authenticity; the current
  soft waveshaper is a decent stand-in for TS/BluesBlazer/FIXATION. **Chiron must have the
  clean+clip blend** modeled explicitly (a single waveshaper can't sound like a Chiron).
- **Block:** feedback-diode clipper (already oversampled) + per-model voicing filters; Chiron =
  dual-path sum. **Difficulty:** low (stand-in) → high (faithful Chiron).

### Distortion — *DS-1, MetalRealm MT-2, SHREW* (3)
- **Circuit:** **harder clipping** — diodes to *ground* after a high-gain stage. SHREW = LM308
  op-amp, huge gain, hard clip, a "filter" (low-pass) knob, bright/aggressive. DS-1 =
  transistor boost → op-amp → hard clip → tone. **MT-2 = two gain stages + an active
  *parametric mid* EQ** (sweepable mid freq + level, deep scoop) — **the EQ is its identity**.
- **Approach:** circuit/neural for the clipper (current "hard" character ≈ SHREW/DS-1 stand-in);
  **MT-2's 3-band w/ sweepable mid is analytical filtering and is mandatory**, not optional.
- **Block:** hard-clip waveshaper + tone; MT-2 adds a parametric-EQ block. **Difficulty:** low
  (SHREW/DS-1 stand-in) → med (MT-2 with real EQ).

### Fuzz — *BigMitt Pi, FuzzDome, FuzzFoundry* (3)
- **Circuit:** **BigMitt** = 4 transistor stages (input boost → **two cascaded soft-clip
  stages** → passive *scooped* tone → output boost) — thick, sustained, mid-scooped. **Fuzz
  Face** = 2 transistors, **extremely interactive with guitar volume & pickup impedance**
  (cleans up as you roll back the guitar) — that interaction *is* the pedal. **FuzzFoundry**
  = 5 knobs, deliberately **unstable / gated / self-oscillating** ("starve" the voltage →
  sputter).
- **Approach:** **circuit model (WDF)** captures the dynamic interaction and instability a
  static waveshaper cannot; neural capture with input-level conditioning also works but the
  FuzzDome's *impedance* interaction lives upstream of the box. BigMitt's cascaded-stages +
  scoop is the key voicing. Current "fuzz" character is a crude single-stage stand-in.
- **Block:** multi-stage clipper (Mitt) / interactive 2-transistor model (FuzzDome) /
  bias-starve model (FuzzFoundry). **Difficulty:** med → high.

### Compressor — *CS-3, DamperComp, Keswick Compressor* (3)
- **Circuit:** OTA/VCA dynamics. DamperComp ≈ **5 ms attack / ~1 s release**, limiter-like,
  2-knob (Sustain/Level). CS-3 adds Attack + 2-band tone. Keswick ≈ smoother, quieter Ross
  (Ross shares the DamperComp topology).
- **Approach:** **algorithmic** — envelope detector → gain computer (threshold/ratio/knee) →
  smoothed gain, with the model's attack/release curve and program-dependent release. Add a
  touch of makeup + soft-knee for feel.
- **Block:** feedforward (or feedback, Damper-style) compressor. **Difficulty:** low–med.

### EQ — *GE-7 (7-band), KRX 10-band M108S, Emblem Parametric EQ* (3)
- **Circuit:** graphic EQ = a **bank of fixed-frequency peaking filters**; parametric = a few
  **sweepable** peaking filters.
- **Approach:** **biquads — this family can be made literally exact** (it's just filters).
- **Block:** N cascaded peaking/shelving biquads. **Difficulty:** low. *(Data-model note: the
  app's `.eq` only exposes Low/Mid/High — a 7/10-band graphic and a parametric need more
  bands; see §4 model gaps.)*

### Noise Gate — *NS-2, Kraal, Nullifier II* (3)
- **Circuit:** **downward expander/gate** — envelope detector → threshold → gain reduction
  with attack/hold/release. NS-2 adds a send/return loop (gates the *input* pre-noise);
  Nullifier is fast with a side-chain ("G-String") key input.
- **Approach:** **algorithmic** dynamics (sibling of the compressor detector).
- **Block:** gate/expander. **Difficulty:** low.

### Modulation — *chorus (CE-2W, SmallMime), phaser (Swirl72, SmallSlate), flanger (M117R, ElectricSiren), tremolo (TR-2), univibe (Lucid'Vibe)* (8)
- **Circuit / structure (one engine, five voicings):**
  - **Phaser** = cascade of first-order **all-pass** filters (Swirl72 = 4 stages, 1 knob;
    SmallSlate = 4 stages + feedback "color") + LFO → sweeping notches.
  - **Flanger** = **short modulated delay (<~10 ms) + feedback** summed with dry → moving
    harmonic notches ("jet"). ElectricSiren = flange+filter-matrix.
  - **Chorus** = **longer modulated delay (~10–30 ms)**, low feedback, often **BBD-voiced**
    (SmallMime) → detuned shimmer.
  - **Tremolo** = **amplitude** modulation by an LFO (TR-2's specific curve/waveform).
  - **Univibe** (Lucid'Vibe) = **4 *unevenly staggered* all-pass stages** (photocell-driven)
    → throbbing phase+slight-amplitude wobble; distinct from an even phaser.
- **Approach:** **algorithmic** — one shared LFO + { all-pass chain | modulated delay |
  amplitude } engine, voiced per model (stage count, delay range, feedback, LFO shape, BBD
  coloration, stagger).
- **Block:** modulation engine. **Difficulty:** low–med (univibe stagger + BBD voicing are the
  fiddly bits).

### Delay — *DD-8 (digital), Echoreel ER-3 (tape), Deluxe ReverieMate (BBD)* (3)
- **Circuit:** a delay line + feedback + mix, plus **per-type coloration**: DD-8 = clean
  digital; **Echoreel** = tape echo → saturation, **wow & flutter** (pitch wobble), HF loss
  per repeat, the famed ER-3 preamp; **ReverieMate** = **BBD** → bandwidth-limited/dark
  repeats, companding, bucket leakage, + a chorus/vibrato section.
- **Approach:** **algorithmic** — one delay-line engine + a coloration stage per voicing
  (clean / tape / BBD). Emulate BBD/tape *voicing*, not literal bucket physics.
- **Block:** fractional-delay line (preallocated ring buffer) + saturation + modulation +
  filtering. **Difficulty:** med. Needs the biggest preallocated buffers (see §4).

### Reverb — *RV-6, GoldenFleece* (2)
- **Circuit:** algorithmic reverbs. RV-6 = multi-mode (hall/plate/spring/room/shimmer/…). Holy
  Grail = spring/hall/flerb.
- **Approach:** **algorithmic** — a **Dattorro plate / FDN** for plate/hall/room, a dedicated
  **dispersive all-pass chain** for the spring mode; optionally **convolution** (we already
  have a partitioned-FFT convolver for cabs) for "real space" IRs.
- **Block:** reverb network (reuse/extend `CabinetConvolver` for IR modes). **Difficulty:**
  med.

### Pitch — *OC-5 (octave), PS-6 Chorister, Micro STACK, Slingshot* (4)
- **Circuit / method:** OC-2-style mono sub-octave = analog frequency division (cheap, mono,
  authentic for the sub-octave); **STACK / OC-5 poly** = digital **polyphonic** pitch shift;
  **Slingshot** = **mono, fast, expression-swept** pitch shift (time-domain, "nasty on chords" by
  design); **Chorister** = **diatonic** (key/scale-aware) harmony → needs pitch detection.
- **Approach:** **algorithmic**, but the **hardest real-time family**: mono time-domain
  (low latency) for Slingshot/mono-octave; **phase-vocoder** (higher latency, ~50 ms history) for
  polyphonic STACK/OC-5; pitch-detection for diatonic Chorister.
- **Block:** pitch shifter (+ octave divider for the analog sub-octave). **Difficulty:** high;
  **flag the latency trade-off** for live monitoring.

### Wah — *WeepingWillow GCB-95, Vane V921, Mordant Wild Pony* (3)
- **Circuit:** an **LC resonant bandpass** — peak ~750 Hz sweeping **~450 Hz→1.6 kHz**, ~18 dB
  boost, moderate Q, moved by the treadle. GCB-95 vs V921 differ in inductor/voicing (peak &
  Q); Wild Pony is switchless with a different (fixed-voiced) sweep.
- **Approach:** **algorithmic** — a swept resonant bandpass (state-variable/biquad) with center
  frequency mapped from the "Position" knob; Q + gain + sweep range per model.
- **Block:** swept bandpass. **Difficulty:** low. *(Expression-controlled; the app's `.wah`
  already exposes "Position".)*

### Volume — *Errol Brass SWELL MINI, LV-320H* (2)
- **Circuit:** an audio-taper potentiometer → gain controlled by the treadle (LV-320H adds a
  tuner out + min-volume).
- **Approach:** **algorithmic** — a smoothed gain × Position. **Difficulty:** trivial.

### Tuner — *Chromatic Tuner (TU-3)* (1)
- **Not a tone effect** — a **pitch detector** (YIN/autocorrelation or FFT) + note/cents
  display + optional output mute on bypass. **Approach:** utility DSP + UI.
  **Difficulty:** low (detection) + UI work.

### Looper — *RC-5 Loop Depot* (1)
- **A feature, not tone** — record/overdub/play/stop into a big preallocated buffer, with
  tempo/quantize. **Approach:** buffer management (RT-safe record/playback). **Difficulty:**
  med (mostly plumbing + UI).

### Misc — *PREAMP Booster, Freeze, Beryllium* (3)
- **PREAMP Booster** = clean/treble **boost** — a gain stage + gentle high-shelf + optional ER-3
  preamp saturation/low-bump at high settings. **Algorithmic**, trivial–low.
- **Freeze** = **infinite sustain** — grab a slice and granular/spectrally hold it as a pad
  under your playing. **Algorithmic** (granular hold buffer); med.
- **Beryllium** = **an amp + cab modeler in a pedal** (3 amps × 9 IR cabs). This **overlaps
  StreetRig's own amp engine** — the right move is to **reuse the neural-amp + cab-IR path**
  and expose it as an "amp-in-a-box" pedal, not to build a new thing. Interesting signal that
  the amp and pedal engines should share infrastructure.

**Coverage math:** ~**30** pedals (EQ, wah, volume, tremolo, chorus, phaser, flanger, delay,
comp, gate, reverb, boost, tuner) are **algorithmic DSP you can make accurate** with a handful
of reusable engines. ~**14** gain pedals want circuit/neural per-unit work. ~**3** (poly
pitch, Chorister, Freeze/looper) are the hard, latency-sensitive stragglers.

---

## 4. How this plugs into StreetRig's engine

The engine is *already architected* for this — the pedal slot was built as a fixed pool with
"drive now, other families later" called out in the code. Concrete seams:

**Slot types (`PedalChain::Type`, C++).** Today `{ Transparent=0, Drive=1 }`. Add
`Comp, EQ, Mod, Delay, Reverb, Pitch, Wah, Gate, Volume, Boost, Tuner, Looper`. Each of the 8
slots must be able to *be* any family. Two ways to keep the **no-audio-thread-alloc** contract:
- **(A)** every slot preallocates one instance of every processor type (simple; memory-heavy
  because delay/reverb/pitch/looper need big buffers × 8 slots), or
- **(B) recommended:** preallocate a **fixed arena** in `prepare()` sized for the worst case
  (at most 8 slots, so at most 8 delay/reverb buffers), and *assign* a processor to a slot at
  `configureSlot()` — which already runs on the setup thread inside the **reconfigure
  barrier**. No allocation ever touches the audio thread.

**Parameter bus (`SRPedalField*` / `SRPedalParamStride`).** Today the stride is **8** with
fields 0–5 used (`Enabled/Type/Character/Drive/Tone/Level`) and **2 spare**. Families need up
to ~3 continuous knobs (Rate/Depth/Mix, Time/Feedback/Mix, Decay/Tone/Mix, Threshold/Decay,
Sustain/Level…). Plan:
- Keep `Enabled/Type/Character(→Voicing)` structural; **generalize `Drive/Tone/Level` into
  generic `paramA/B/C`** (already three continuous de-zippered floats — most families fit).
- The **outlier is the graphic EQ** (7–10 continuous bands). Either **widen
  `SRPedalParamStride`** to carry a band vector for that slot, or pack bands into a small
  side-channel. Widening the stride is safe (the pedal bus isn't persisted as automation —
  knob values live in `GearItem.values`), just do it before anyone depends on the addresses.

**Compiler & map (Swift).**
- `RigDSPPlan.PedalSlot` hard-codes `drive/tone/level` → generalize to
  `type`, `voicing`, `params:[Float]` (or fixed `p0…pN`). `RigGraphCompiler.compile` already
  walks pedals in chain order; have it read `item.category.parameters` and map each knob via
  `ParameterMap`.
- `ParameterMap.pedalType(for:)` returns `.drive` only for `.overdrive` → extend to map every
  category to its block type.
- **`ParameterMap.pedalCharacter(name:)` is currently broken for the renamed catalog** — it
  matches `"ProForge SHREW"`/`"BigMitt"`/`"FuzzDome"`, but the catalog ships `"ProForge SHREW"`,
  `"electro-galvanic BIG MITT Ω"`, `"DALTON ARMATURE FUZZ DOME"`, so **every renamed pedal
  falls through to soft overdrive**. Replace it with a `pedalVoicing(name:)` table keyed off
  the **actual catalog names (or a stable model id)** that returns a per-model voicing struct
  for whatever family — this is the single "which real pedal is this" lookup.
- Add per-family knob→DSP mappings (LFO Hz, depth, mix; delay ms, feedback, RT60; gate
  threshold dB; comp ratio/attack/release; wah sweep Hz; EQ band dB; pitch interval).

**Real-time safety — unchanged contract.** All buffers allocated in `prepare()`; structural
swaps go through the existing fade/park **reconfigure barrier**; continuous knobs go through
the lock-free bus and are de-zippered. Delay/reverb/pitch simply add *more preallocated state*
under the same rules. **Latency:** pitch shifters (and any look-ahead limiter) add latency — the
engine already accounts for cab-IR latency (`SRKernelCabLatencySamples`); extend that
accounting and mind the live-monitoring budget for iRig play.

**Data-model gaps to close (in `Gear.swift`).**
- No `.distortion`/`.fuzz`/`.boost` categories — the list's distortion & fuzz pedals collapse
  into `.overdrive` (fine for chain order, but voicing must come from the per-model table, not
  the category). Consider adding categories or a `voicing`/`modelId` field on `GearItem`.
- `.eq` exposes only Low/Mid/High — real graphic/parametric EQs need a richer, per-model
  parameter set. Parameter lists may need to become **per-model**, not just per-category.

---

## 5. Neural vs circuit for the gain pedals (the one real fork)

For the ~14 OD/dist/fuzz/comp pedals, both routes are "physically real." Choose per your
constraints:

| | **Circuit model (WDF / state-space)** | **Neural capture (LSTM/TCN)** |
|---|---|---|
| Needs the real hardware? | **No** — public schematics suffice | **Yes** — you must record the actual unit (or license captures) |
| Knob coverage | Continuous & free (knobs are real circuit params) | One net per setting **unless** knob-conditioned (FiLM/hypernetwork) |
| Dynamic feel (cleanup, sag, instability) | **Best** — it *is* the circuit (FuzzDome, FuzzFoundry shine) | Good for static grit; upstream-impedance interactions are hard to capture |
| CPU | Per-stage nonlinear solves (moderate) | **Very cheap** at runtime (a 40-unit LSTM ≈ ~2% CPU, RTNeural) |
| Effort | Per-circuit modeling project | Capture rig + training pipeline, then it's data |
| StreetRig readiness | New C++ blocks (add `chowdsp_wdf`) | **Runtime already exists** on the amp path — reuse it |

**Recommendation:** since the engine already has the neural runtime, **neural capture is the
cheaper path to "just like the real one" — *if* you can get the hardware or licensed captures**
(the honest gating question). Where you can't (or for the pedals whose magic is dynamic
interaction — FuzzDome, FuzzFoundry, Chiron's blend), **circuit modeling (WDF)** is the better
tool. A pragmatic split: **neural-capture the ones you own; circuit-model the icons you don't;
keep the analytical waveshaper as the instant fallback for everything.**

> **Decision (2026-08-11):** go **circuit-model-only (WDF) from public schematics** — the
> no-hardware path — for all gain pedals; **neural capture is parked** (revisit only if
> rights-cleared hardware captures become available). The oversampled waveshaper stays as the
> instant fallback until each WDF model lands.

---

## 6. Legal / IP posture (a real consideration — not legal advice)

- **Circuits and the *sound* of an effect aren't copyrightable.** Modeling behavior from public
  schematics (ElectroSmash et al.) and DIY analyses is the well-trodden, low-risk path — it's
  what boutique clones and every modeler do. **Algorithmic and circuit models carry no capture
  IP.**
- **Neural captures / IRs are recordings.** Capturing hardware **you own** for your own product
  is broadly what NAM/ToneX/etc. enable — but **do not ship captures or IRs you don't have the
  rights to** (don't redistribute someone else's NAM/IR pack). This is the one place the
  "sounds like" path can create a rights problem; keep it clean.
- **Names:** keep the re-badged generic names (as the catalog already does). Same "recognizable
  but not counterfeit" stance as the 3D doc — model the *behavior*, not the trademark.

---

## 7. Phased rollout

| Phase | Goal | Paradigm | Pedals unlocked | Exit criteria |
|---|---|---|---|---|
| **0 — Framework** | Turn the drive-only slot into an "any family" slot | (plumbing) | none yet | New `PedalChain::Type`s + arena preallocation; generalized `RigDSPPlan.PedalSlot`, `paramA/B/C` bus, `pedalVoicing(name:)` keyed to real catalog names; existing drive pedals unchanged; offline render still matches |
| **1 — Structural families I (filters & dynamics)** | Biggest coverage per effort | Algorithmic | **EQ, wah, volume, tremolo, compressor, gate, boost** (~13) | Each is audible & correct in the offline render; knobs live via the bus; RT-safe |
| **2 — Structural families II (time-based)** | The lush stuff | Algorithmic | **chorus, phaser, flanger, delay, reverb** (~13) | Preallocated delay/reverb buffers; BBD/tape/spring voicings; no audio-thread alloc; latency reported |
| **3 — Gain pedals, faithful** | Marquee OD/dist/fuzz beyond the stand-in | WDF and/or neural | **TS, SHREW, DS-1, MT-2, BigMitt, FuzzDome, Chiron, DukeOfDrive, FIXATION, BluesBlazer, FuzzFoundry** | Per-model voicing/capture; A/B vs reference; Chiron blend + MT-2 EQ modeled; on-device ear-tuning |
| **4 — Hard/latency-sensitive** | Finish the list | Algorithmic (spectral) | **poly pitch (STACK/OC-5), Chorister, Slingshot, Freeze, looper, tuner** | Pitch latency within monitoring budget; tuner detection accurate; looper RT-safe |

Phases 1–2 are where the **audible** win is largest (≈26 pedals from a small set of reusable
engines); Phase 3 is where StreetRig earns "sounds *just* like it" on the hero gain pedals.

---

## Sources

Circuit analyses (how the real pedals work):
- [ElectroSmash — Ibanez Tube Screamer analysis](https://www.electrosmash.com/tube-screamer-analysis)
- [ElectroSmash — Big Muff Pi analysis](https://www.electrosmash.com/big-muff-pi/pedals/distortion/big-muff-pi-analysis.html)
- [ElectroSmash — Klon Centaur analysis](https://www.electrosmash.com/klon-centaur-analysis)
- [ElectroSmash — Dunlop Cry Baby GCB-95 analysis](https://www.electrosmash.com/crybaby-gcb95/pedals/filter/dunlop-crybaby-gcb-95-cicuit-analysis.html)
- [LTSpice — simulating the MXR Dyna Comp compressor](https://cushychicken.github.io/ltspice-mxr-dyna-comp-compressor/)
- [Coda Effects — Big Muff circuit analysis](https://www.coda-effects.com/p/big-muff-circuit-analysis.html)

Modeling techniques:
- [Chowdhury et al. — *A Comparison of Virtual Analog Modelling Techniques* (Klon, nodal+WDF+RNN), CCRMA](https://ccrma.stanford.edu/~jatin/papers/Klon_Model.pdf)
- [chowdsp_wdf — real-time Wave Digital Filter C++ library](https://github.com/Chowdhury-DSP/chowdsp_wdf)
- [Holmes — *Guitar Effects-Pedal Emulation and Identification* (thesis, DAFx)](https://bholmesqub.github.io/DAFx19/thesis.pdf)
- [*Simplified, physically-informed models of distortion and overdrive pedals* (Yeh/Smith)](https://www.researchgate.net/publication/238619930_Simplified_physically-informed_models_of_distortion_and_Overdrive_guitar_effects_pedals)

Neural / differentiable modeling:
- [Neural Amp Modeler (NAM)](https://www.neuralampmodeler.com/)
- [GuitarML — GuitarLSTM](https://github.com/GuitarML/GuitarLSTM) · [NeuralPi (RTNeural on Raspberry Pi)](https://github.com/GuitarML/NeuralPi)
- [*Differentiable Black-box and Gray-box Modeling of Nonlinear Audio Effects* (2025)](https://www.frontiersin.org/journals/signal-processing/articles/10.3389/frsip.2025.1580395/full) · [NablAFx framework](https://github.com/mcomunita/nablafx)
- [*Comparative Study of State-based Neural Networks for Virtual Analog Audio Effects Modeling* (arXiv)](https://arxiv.org/pdf/2405.04124)
- [CONMOD — *Controllable Neural Frame-based Modulation Effects* (arXiv)](https://arxiv.org/pdf/2406.13935)

Time-based effect DSP:
- [Wikipedia — Bucket-brigade device (BBD)](https://en.wikipedia.org/wiki/Bucket-brigade_device) · [MusicRadar — a brief history of BBD delays](https://www.musicradar.com/news/a-brief-history-of-bucket-brigade-delays-and-4-great-plugin-emulations)
- [Dattorro — *Effect Design Part 1: Reverberator and Other Filters* (via Valhalla DSP's reverb papers guide)](https://valhalladsp.com/2021/09/22/getting-started-with-reverb-design-part-2-the-foundations/)
- [Faust Libraries — reverbs (Freeverb, Dattorro, FDN)](https://faustlibraries.grame.fr/libs/reverbs/)
- [*Low latency audio pitch shifting in the frequency domain* (phase vocoder)](https://www.researchgate.net/publication/261078164_Low_latency_audio_pitch_shifting_in_the_frequency_domain)
