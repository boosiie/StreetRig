# StreetRig Pedal Tone Reference — every pedal, every knob

**Status:** working reference + tuning spec · **Date:** 2026-08-11 · **Scope:** the 47 pedals in
`pedals.csv`. For each: its **real-world controls** (what actually turns on the hardware), what
gives it its tone, and how StreetRig should model it. This is the spec the DSP voicing tunes to.

Naming: the catalog re-badges brands (BRIG≈Brig, Iberon≈Iberon, ProForge≈ProForge, Marswell≈Marswell,
Chiron≈Chiron, Fullbrook≈Fullbrook, electro-galvanic≈electro-galvanic, Dunridge≈Dunridge/Maestro,
Keswick≈Keswick, Fornax≈Fornax, QUELL≈QUELL, Exalt≈Exalt, strider≈Strider, Vane≈Vane, Mordant≈Mordant,
DigiVault≈DigiVault, Errol Brass≈Errol Brass, Z.FLUX≈Z.Flux, Emblem≈Emblem). Controls below are the
**real units'** controls.

**Legend — StreetRig status:** ✅ modeled + per-model voiced · 🟡 plays through a generic family
engine (voicing not yet model-specific) · ⛔ silent pass-through (family DSP not built yet).

---

## Overdrive — soft-clipping (✅ per-model voiced this pass)

| Pedal (real) | Real knobs | Tone essence | StreetRig voicing |
|---|---|---|---|
| **ValveShrieker** (TS808/TS9) | Overdrive, Tone, Level | Diodes in the op-amp feedback → **soft, symmetric** clip; signature **mid hump ~720 Hz**; tightened lows | soft clip + 720 Hz/+6 dB pre-hump, mild asymmetry ✅ |
| **BluesBlazer** (Marswell) | Gain, Tone, Volume | **Transparent**, open, low-gain; feedback-diode soft clip, flat mids | soft clip, no hump, low drive, slight clean blend ✅ |
| **Satyr** (Chiron) | Gain, Treble, Output | **Clean path blended with a germanium-clipped path**; active treble (HP >400 Hz); huge headroom | soft-hard blend, **50% clean mix**, treble tilt ✅ |
| **DukeOfDrive** (analogue.smith) | Volume, Tone, Drive (×2 ch; internal Clean/OD/Dist) | BluesBlazer-derived, fuller mids, a touch more gain | soft clip, ~500 Hz/+3 dB, light clean blend ✅ |
| **FIXATION** (Fullbrook) | Volume, Drive, Tone, **HP/LP switch** | **MOSFET** clipping, amp-like, more open & gainy; HP = brighter/gainier | hard/MOSFET clip, asymmetric, brighter, higher drive ✅ |

## Distortion — hard-clipping (✅ per-model voiced this pass)

| Pedal (real) | Real knobs | Tone essence | StreetRig voicing |
|---|---|---|---|
| **DS-1** (Brig) | Tone, Level, **Dist** | Transistor boost → op-amp → **hard clip to ground**, **asymmetric**, mid-forward, buzzy; "tilt" tone | hard clip, asymmetric, mid-forward, bright ✅ |
| **MetalRealm MT-2** (Brig) | Level, **Dist**, Low, **Mid + Mid-Freq (semi-parametric, ±25 dB, 200 Hz–5 kHz)**, High | Two gain stages, **very high gain**, **deep mid scoop**, bright | high-gain hard clip + **post scoop ~500 Hz −12 dB**, bright ✅ (parametric-mid **knobs** = follow-up) |
| **SHREW** (ProForge) | Distortion, **Filter**, Volume | LM308 huge gain, **hard symmetric clip to ground**, **bright/aggressive**; Filter = passive LP (CW = darker) | hard clip, symmetric, bright, high drive ✅ |

## Fuzz (✅ per-model voiced this pass)

| Pedal (real) | Real knobs | Tone essence | StreetRig voicing |
|---|---|---|---|
| **BigMitt Pi** (e-g) | Volume, Tone, **Sustain** | 4 transistor stages = **two cascaded soft-clip stages**; thick, singing, **mid-scooped** | **two-stage** soft clip + post scoop ~1 kHz, high sustain, full lows ✅ |
| **FuzzDome** (Dalton Armature) | Volume, **Fuzz** | 2-transistor germanium; round, **asymmetric**; famously cleans up with guitar volume | asymmetric fuzz, full lows, lower gain, dynamic ✅ (guitar-volume cleanup = future, needs input-impedance model) |
| **FuzzFoundry** (Z.Flux) | Volume, **Gate, Comp, Drive, Stab** | Deliberately **unstable / gated / sputtery**; Stab = self-oscillation, Gate = velcro chop | extreme-asymmetry gated fuzz ✅ (Gate/Comp/Stab **knobs** = follow-up) |

## Boost (🟡 — needs a category/`boost` type; see follow-ups)

| Pedal (real) | Real knobs | Tone essence | StreetRig plan |
|---|---|---|---|
| **PREAMP Booster** (Exalt) | Gain (1 knob) + internal DIP: **Bass boost**, **Bright** | ER-3 preamp-style clean/treble boost, up to +20 dB; subtle low bump + sparkle | clean-boost drive voicing (mostly-clean soft clip + high shelf) 🟡 |

## Compressor (🟡 family engine built; per-model ballistics = follow-up)

| Pedal (real) | Real knobs | Tone essence | StreetRig mapping |
|---|---|---|---|
| **DamperComp** (KRX) | Output, **Sensitivity** | OTA, **fast attack / slow release**, limiter-like squash & sustain | Sustain→Sensitivity, Level→Output; fast/limiting ballistics 🟡 |
| **Compression Leveller CS-3** (Brig) | Level, **Tone, Attack, Sustain** | OTA comp with an **attack** control + 1-band tone; snappier or squashed | Sustain, Level today; **Attack + Tone knobs** = follow-up 🟡 |
| **Compressor Plus** (Keswick) | Sustain, Level, **Blend, Tone**, release switch | Ross-circuit, smooth/quiet, **parallel Blend**, brighter | Sustain, Level today; **Blend + Tone** = follow-up 🟡 |

## EQ (🟡 3-band engine built; graphic/parametric layouts = follow-up)

| Pedal (real) | Real knobs | Tone essence | StreetRig mapping |
|---|---|---|---|
| **GE-7** (Brig) | **7 sliders** 100 Hz–6.4 kHz (±15 dB) + Level | Fixed-band graphic EQ | 3-band today; **7 bands** need a wider param layout 🟡 |
| **10-Band M108S** (KRX) | **10 sliders** 31 Hz–16 kHz (±12 dB) + Gain, Volume | Fixed-band graphic EQ | 3-band today; **10 bands** = wider layout 🟡 |
| **Parametric EQ MkII** (Emblem) | **3 parametric bands** (each Freq + Gain ±15 dB, Q), + boost | Sweepable parametric | 3-band fixed today; **sweepable freq + Q** = follow-up 🟡 |

## Noise Gate (🟡 family engine built; extra knobs = follow-up)

| Pedal (real) | Real knobs | Tone essence | StreetRig mapping |
|---|---|---|---|
| **NS-2** (Brig) | **Threshold, Decay** (+ send/return loop) | Gate/expander with a 4-cable loop | Threshold, Decay ✅ mapping; loop routing = N/A |
| **Nullifier II** (QUELL) | **Threshold** (single, −70..−10 dB) | Fast, transparent tracking gate | Threshold (Decay auto) 🟡 |
| **Kraal** (Fornax) | Threshold (+ **Hold, Release** on Kraal+) | Tight metal gate | Threshold, Release→Decay; **Hold** = follow-up 🟡 |

## Modulation (🟡 family engine built; per-model tweaks = follow-up)

| Pedal (real) | Real knobs | Tone essence | StreetRig voicing |
|---|---|---|---|
| **Swirl72** (KRX) | **Speed** (1 knob) | 4-stage all-pass phaser, no feedback, liquid | phaser, 4 stages 🟡 (drop to 1 knob = follow-up) |
| **SmallSlate** (e-g) | **Rate** + **Color** switch | 4-stage phaser, Color = feedback/more notch | phaser + feedback 🟡 |
| **SmallMime** (e-g) | **Rate** + Depth switch | BBD chorus, lush single-voice | chorus 🟡 |
| **CE-2 / CE-2W** (Brig) | Rate, Depth (W adds modes) | BBD chorus, classic | chorus 🟡 |
| **Flanger M117R** (KRX) | Manual, Width, Speed, Regen | BBD flanger, jet/metallic, feedback | flanger 🟡 (4 knobs = follow-up) |
| **ElectricSiren** (e-g) | Rate, Range, Color | Flanger + filter-matrix (flange+chorus) | flanger 🟡 |
| **Tremolo TR-2** (Brig) | Rate, **Wave**, Depth | Amplitude LFO, waveform shape | tremolo 🟡 (Wave = follow-up) |
| **Lucid'Vibe** (Fullbrook) | Volume, Intensity, Speed (+ Chorus/Vibe, Modern/Vintage) | Univibe: staggered all-pass + throb | univibe 🟡 |

## Pitch (⛔ DSP not built — real-time pitch shifting is the hard family)

| Pedal (real) | Real knobs | Tone essence | StreetRig plan |
|---|---|---|---|
| **Octave OC-5** (Brig) | Direct, +1 Oct, −1 Oct, −2 Oct/Range (+ Vintage/Poly) | Poly + mono (OC-2) octaves | poly pitch-shift + analog sub-octave ⛔ |
| **Chorister PS-6** (Brig) | Balance, Shift, Key (+ Harmony/Pitch/Detune/S-Bend) | Diatonic key-aware harmony | pitch-detect + interval ⛔ |
| **Micro STACK** (e-g) | Dry, Sub Octave, Octave Up | Polyphonic octaves | poly pitch-shift ⛔ |
| **Slingshot** (DigiVault) | treadle + interval selector, Classic/Chord | Expression pitch sweep | mono time-domain shift ⛔ |

## Delay (⛔ DSP not built — needs large preallocated buffers)

| Pedal (real) | Real knobs | Tone essence | StreetRig plan |
|---|---|---|---|
| **Digital Delay DD-8** (Brig) | E.Level, Feedback, Time (+ 11 modes) | Clean digital multi-mode | delay line + modes ⛔ |
| **Echoreel ER-3** (Dunridge/Maestro) | Volume, Sustain (repeats), Delay (+ record-level/age) | Tape echo: wow/flutter, saturation, HF loss, EP preamp | delay + tape coloration ⛔ |
| **Deluxe ReverieMate** (e-g) | Blend, Feedback, Delay + Chorus/Vibrato Depth & Rate | BBD analog delay + modulation | BBD delay + chorus ⛔ |

## Reverb (⛔ DSP not built)

| Pedal (real) | Real knobs | Tone essence | StreetRig plan |
|---|---|---|---|
| **RV-6** (Brig) | E.Level, Tone, Time (+ 8 modes) | Digital multi-mode (hall/plate/spring/shimmer…) | FDN/Dattorro + modes ⛔ |
| **GoldenFleece** (e-g) | Reverb (amount) + Spring/Hall/Flerb | Simple lush reverb | spring + hall algorithms ⛔ |

## Wah / Volume (🟡 wah + volume engines built; per-model range = follow-up)

| Pedal (real) | Real controls | Tone essence | StreetRig mapping |
|---|---|---|---|
| **WeepingWillow GCB-95** (Dunridge) | treadle | Peak sweeps ~450 Hz→1.6 kHz, +18 dB, mid-Q | Position→swept peak ✅; per-model peak/Q 🟡 |
| **V921** (Vane) | treadle | Warmer/lower peak than GCB-95 (different inductor) | Position; warmer voicing 🟡 |
| **Wild Pony** (Mordant) | switchless treadle (+ Contour mode: Contour, Level) | Optical, fixed-voiced Vai wah | Position; Contour/Level = follow-up 🟡 |
| **SWELL MINI** (Errol Brass) | treadle (+ min-vol trim) | Passive volume, audio taper | Position→gain ✅ |
| **LV-320H** (Brig) | treadle (+ min vol, tuner out) | Volume + tuner out | Position→gain ✅ |

## Utility (⛔ / N/A — features, not tone)

| Pedal (real) | Real controls | StreetRig plan |
|---|---|---|
| **Chromatic Tuner TU-3** (Brig) | Mode, mute switch | pitch-detect + mute UI ⛔ |
| **Loop Depot RC-5** (Brig) | Level, tempo, mode | record/overdub buffer ⛔ |
| **Freeze** (e-g) | Effect Level + Fast/Slow/Latch | granular infinite-hold ⛔ |
| **Beryllium** (Strider) | Drive, Bass, Mid, Treble, Level, Room + 3 amps × 3 cabs | **reuse StreetRig's own neural amp + cab-IR engine** (amp-in-a-box) ⛔ |

---

## Knob → DSP mapping (how a turned knob reaches the sound)

Continuous knobs ride the lock-free param bus into the slot's engine (`ParameterMap.pedalParams`
→ `PedalChain` `Param0..4`). Structural choices (which model, i.e. **voicing**) come from
`ParameterMap.pedalVoicing(name:)` and are applied under the reconfigure barrier. Today every
family maps its **generic** knobs (Drive/Tone/Level, Rate/Depth/Mix, …). Giving each pedal its
**real** knob set (BigMitt → Sustain/Tone/Volume, MetalRealm → Level/Dist/Low/Mid/Mid-Freq/High,
Swirl72 → Speed only) is the **per-model-knobs** follow-up below.

## Follow-ups to fully honor "every knob"

1. **Per-model parameter sets** (`PedalSpec` keyed by model name) so the UI shows each pedal's
   real controls, replacing the generic per-category list. Most pedals fit the current 5-param
   slot; **MetalRealm (6), GE-7 (7), 10-Band (10), Parametric EQ (parametric)** need a **wider param
   stride** (the bus is currently 5 continuous fields).
2. **Semi-parametric / graphic EQ** knobs (sweepable Mid-Freq, N bands).
3. **Per-model voicing for comp / wah / modulation** (ballistics, peak range, stage count).
4. **Delay, reverb, pitch, tuner, looper, Freeze, Beryllium** engines (see
   `research/pedal-emulation-approaches.md` §7).

## Sources
- [ElectroSmash — Tube Screamer](https://www.electrosmash.com/tube-screamer-analysis) · [DS-1](https://www.electrosmash.com/boss-ds1-analysis) · [Big Muff](https://www.electrosmash.com/big-muff-pi-analysis) · [Klon](https://www.electrosmash.com/klon-centaur-analysis) · [Cry Baby](https://www.electrosmash.com/crybaby-gcb95/pedals/filter/dunlop-crybaby-gcb-95-cicuit-analysis.html)
- [Boss MT-2 analysis (Electric Druid)](https://electricdruid.net/boss-mt-2-metal-zone-pedal-analysis/) · [Boss CS-3 manual](https://static.roland.com/assets/media/pdf/CS-3_eng03_W.pdf)
- [Fulltone OCD (HP/LP)](https://www.amazon.com/fulltone-obsessive-compulsive-drive-pedal/dp/b01k601wbe) · [Analogman King of Tone](https://en.wikipedia.org/wiki/King_of_Tone) · [Z.Vex Fuzz Factory controls](https://loopydemos.com/demos/zvex-effects-fuzz-factory/)
- [EHX Micro POG](https://www.ehx.com/products/micro-pog/) · [Boss OC-5](https://www.sweetwater.com/store/detail/OC5--boss-oc-5-octave-pedal) · [Boss PS-6](https://www.premierguitar.com/gear/boss-ps-6-harmonist-pedal-review) · [DigiTech Whammy](https://en.wikipedia.org/wiki/DigiTech_Whammy)
- [Strymon Iridium](https://www.strymon.net/product/iridium/) · [Empress ParaEq MkII](https://empresseffects.com/products/paraeq-mkii-deluxe) · [Xotic EP Booster](https://xotic.us/effects/ep-booster/) · [EHX Freeze](https://www.ehx.com/products/freeze/) · [ISP Decimator II](https://reverb.com/p/isp-technologies-decimator-ii-noise-reduction) · [Fortin Zuul+](https://fortinamps.com/products/zuul-plus) · [Keeley Compressor Plus](https://robertkeeley.com/product/keeley-compressor-plus/) · [Morley Bad Horsie](https://www.morleyproducts.com/bad-horsie/)
