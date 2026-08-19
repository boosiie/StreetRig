//
//  AmpProfile.cpp
//  StreetRig
//
//  THE ONE AUDITABLE TABLE of per-amp voicing numbers — the amp-side peer of
//  `DrivePedal::voiceFor()` (pedal circuits) and `ParameterMap.swift` (knob
//  curves). Everything an amp is, other than its artwork and its cab IR, is a
//  row below.
//
//  HOW TO READ A ROW. Left to right it is the signal path: where the input is
//  tightened, the bright cap, then each preamp stage (what reaches its clipper,
//  how hard it is driven, what leaves it), then the tone stack the stages feed,
//  then the output stage, then the box. Contrast two rows and you can hear the
//  amp before you build it:
//
//    • The TWIN's cathodes are fully bypassed (`cathodeHz 0`) and its couplings
//      are wide open (20–25 Hz) — it amplifies the whole band flat, which is why
//      it stays clean and loud. Its stack then scoops 11 dB at 400 Hz at noon.
//    • The JCM800 shelves +8 dB above 480 Hz in the very FIRST stage and
//      high-passes at 32/40/48 Hz between stages — it distorts the mids and
//      upper mids while keeping the lows out of the clipper, which is why it is
//      tight. Its stack scoops only 7 dB, and at 650 Hz.
//    • The AC30 has NO negative-feedback loop (`nfbDB 0`), the lowest headroom
//      of the six and the highest asymmetry — cathode-biased EL84s, which is
//      what "loose and touch-responsive" actually is. Its presence scale is
//      NEGATIVE: the real control is the Vox Cut, and it works backwards.
//    • The JC-120 is the AC30's opposite in every field: no bright cap, zero
//      asymmetry, `SolidState` clips, 3.0 of headroom, no sag, no NFB, no
//      presence control. Clinically clean, by design.
//
//  CONFIDENCE, and where to spend tuning time. **H** = grounded in published
//  circuit values, **M** = derived from topology, **L** = educated guess. The
//  Katana rows are all **L** — Boss publishes nothing about its models — and are
//  the highest-value rows for the owner's ear-tuning pass. Each block carries
//  the listening cue from research/amp-emulation-approaches.md §11 next to the
//  value it describes, so a tuning session never needs the document open.
//

#include "AmpProfile.hpp"

namespace streetrig {
namespace {

/// One preamp stage, in signal order: what reaches the clipper, how hard, what
/// leaves it. Exists so a stage reads as one line in the table below.
constexpr PreampStage st(double couplingHz, double cathodeHz, float cathodeDB,
                         double millerHz, float gain, float asym,
                         AmpClip clip = AmpClip::Triode) noexcept {
    return PreampStage{couplingHz, cathodeHz, cathodeDB, millerHz, gain, asym, clip};
}

/// A three-knob passive stack (Bass low-shelf / Mid peak / Treble high-shelf)
/// with band 3 SKIPPED.
///
/// Presence is specified exactly ONCE, in the power-amp block, because in a real
/// amp presence is not an EQ band — it is a control inside the negative-feedback
/// loop. Every profiled amp therefore leaves tone band 3 inert.
/// `AmpVoicing::Legacy` is the sole exception: its presence IS tone band 3, and
/// its `power.presenceScale` is 0, so the control has exactly one owner per
/// profile and can never be applied twice.
constexpr ToneStackVoicing tone3(double bHz, double bQ, float bScale, float bNoon,
                                 double mHz, double mQ, float mScale, float mNoon,
                                 double tHz, double tQ, float tScale, float tNoon,
                                 float insertionDB, float bassEatsMid) noexcept {
    return ToneStackVoicing{
        {
            ToneBand{bHz, bQ, bScale, bNoon, ToneShape::LowShelf},
            ToneBand{mHz, mQ, mScale, mNoon, ToneShape::Peak},
            ToneBand{tHz, tQ, tScale, tNoon, ToneShape::HighShelf},
            ToneBand{6000.0, 0.70, 0.0f, 0.0f, ToneShape::HighShelf},   // skipped
        },
        insertionDB, bassEatsMid
    };
}

// MARK: - The Katana, built from its shared chassis
//
// All ten Katana voicings are ORDINARY rows in the same table as the JCM800 and
// the Twin — that is the generalization test, and it is the reason the
// characters are top-level profiles rather than a nested "character" field. If a
// character had needed a special case the schema could not express, the schema
// would be wrong. Two came close and both were absorbed by one general field
// each: the Acoustic character's speakerless voicing became `bypassCab`, and the
// Vox Cut became a negative `rangeScale`/`presenceScale`. Both are now available
// to every amp.
//
// Everything the ten share lives here; §4.3's per-voicing table is the argument
// list. THE VARIATION RULE, stated rather than guessed ten separate times:
// A = the base voicing, B = HOTTER AND TIGHTER — more drive, the interstage
// high-passes moved up (less low end into the clipper), slightly more presence
// range. Easy to A/B against hardware, easy to correct per character afterwards.

/// Miller poles descend down the cascade so a high-gain voicing does not turn
/// into fizz: 16 k → 13 k → 11 k → 10 k. Cue: fizz on the top of a high-gain
/// voicing → lower the LAST stage's Miller toward 9 kHz.
constexpr double kKatanaMiller[4] = {16000.0, 13000.0, 11000.0, 10000.0};
/// Per-stage clip bias — even harmonics, tube-like.
constexpr float  kKatanaAsym[4]   = {0.10f, 0.12f, 0.12f, 0.07f};

struct KatanaVoice {
    int     stages;
    float   gain[4];
    double  inputHz;
    double  coupling[4];
    double  cathodeHz[4];
    float   cathodeDB[4];
    float   headroom;
    float   sagDepth;
    float   noonB, noonM, noonT;
    float   presenceScale;
    float   outTrim;
    AmpClip stageClip;
};

AmpProfile katana(const KatanaVoice &k) noexcept {
    AmpProfile p;
    p.inputHz  = k.inputHz;
    p.brightHz = 1800.0;  p.brightDB = 3.0f;
    p.stageCount = k.stages;
    for (int i = 0; i < k.stages; ++i) {
        p.stage[i] = st(k.coupling[i], k.cathodeHz[i], k.cathodeDB[i],
                        kKatanaMiller[i], k.gain[i], kKatanaAsym[i], k.stageClip);
    }
    // The Katana is the ONE amp of the six whose stack really is flat at noon —
    // it is a digital EQ Boss designed to be neutral at centre, so `insertionDB`
    // is 0 and the `noonDB` set averages near zero. Which is also why the
    // pre-profile fixed `ToneStack` already, accidentally, sounded most like a
    // Katana and least like everything else.
    // Cue: if the Katana sounds coloured with the EQ centred, zero these.
    p.tone = tone3(110.0, 0.70, 1.0f, k.noonB,
                   550.0, 0.80, 1.0f, k.noonM,
                   3000.0, 0.70, 1.0f, k.noonT,
                   0.0f, 0.10f);
    p.power = PowerAmpVoicing{
        k.headroom, AmpClip::ClassAB, 0.04f,
        k.sagDepth, 40.0,
        2400.0, -3.0f,
        5000.0, k.presenceScale,
        55.0, 10000.0
    };
    p.cabSlot = 1;
    p.outTrim = k.outTrim;
    return p;
}

/// The Acoustic character is not a guitar amp: an acoustic/DI preamp with no
/// speaker, no output valves and no feedback loop. It is the row that proved
/// `bypassCab` had to be a general field rather than a Katana special case.
AmpProfile katanaAcoustic(double inputHz, double couplingHz,
                          float noonB, float noonM, float noonT,
                          float presenceScale) noexcept {
    AmpProfile p;
    p.inputHz  = inputHz;
    p.brightHz = 0.0;  p.brightDB = 0.0f;          // no bright cap
    p.stageCount = 1;
    p.stage[0] = st(couplingHz, 0.0, 0.0f, 18000.0, 1.0f, 0.0f, AmpClip::Clean);
    p.tone  = tone3(110.0, 0.70, 1.0f, noonB,
                    550.0, 0.80, 1.0f, noonM,
                    3000.0, 0.70, 1.0f, noonT,
                    0.0f, 0.10f);
    // `clip = Clean` skips the output-stage waveshaper and its 2× oversampler.
    // The presence shelf and the OT bandwidth still run — which is correct: an
    // acoustic preamp has no output valves but does have a tone shelf and a
    // finite bandwidth. That per-FIELD skipping is the whole point of the rule.
    p.power = PowerAmpVoicing{
        4.00f, AmpClip::Clean, 0.0f,
        0.0f, 40.0,
        0.0, 0.0f,
        9000.0, presenceScale,
        40.0, 16000.0
    };
    p.cabSlot   = 1;
    p.bypassCab = true;
    p.outTrim   = 0.90f;
    return p;
}

} // namespace

// MARK: - profileFor — the table

AmpProfile profileFor(int voicing) noexcept {
    AmpProfile p;
    switch (voicing) {

    // ---------------------------------------------------------------------
    // Marswell JCM800 2203 — tight, mid-forward, "present". Conf: H (cathode
    // corners, stack centres), M (stage gains, noonDB).
    // ---------------------------------------------------------------------
    case JCM800:
        p.inputHz  = 72.0;
        p.brightHz = 1500.0; p.brightDB = 4.0f;
        p.stageCount = 3;
        // S1's 480 Hz / +8 dB cathode shelf IS the Marshall crunch: everything
        // below 480 Hz gets ~8 dB less gain into the next stage.
        // Cue: FLUBBY PALM MUTES → raise the Hz. Thin and brittle → lower it,
        // or reduce the dB. (350–650 Hz / +5…+11 dB.)
        p.stage[0] = st(32.0, 480.0, 8.0f, 15000.0, 2.2f, 0.10f);
        // Cue: upper-mid "bark" on power chords. Too much = honky and nasal.
        p.stage[1] = st(40.0, 674.0, 6.0f, 12000.0, 2.4f, 0.14f);
        p.stage[2] = st(48.0,   0.0, 0.0f, 10000.0, 1.6f, 0.08f);
        // Cue (couplings 32/40/48): low-E chugs should stay defined under gain.
        // Mushy → raise all three ~10 Hz.
        //
        // Cue (mid noonDB −7): the JCM800 must be noticeably MORE mid-present
        // than the Twin at identical knob settings. If a JCM800 and a Twin still
        // sound alike at noon, this row and the Twin's are the first suspects.
        // Cue (mid 650 Hz): palm-muted riffing should have "bark".
        p.tone = tone3( 90.0, 0.70, 1.0f, -1.0f,
                       650.0, 0.85, 0.9f, -7.0f,
                      2300.0, 0.70, 1.1f, +1.0f,
                      -14.0f, 0.35f);
        p.power = PowerAmpVoicing{
            0.75f, AmpClip::ClassAB, 0.05f,
            0.18f, 45.0,
            2200.0, -3.0f,
            3500.0, 1.0f,
            65.0, 9000.0
        };
        p.cabSlot = 0;                 // 4×12 V30
        p.outTrim = 1.00f;
        break;

    // ---------------------------------------------------------------------
    // Fandor Twin Reverb — enormous headroom, deep scoop, the tightest feel.
    // Conf: H (fully bypassed cathodes, heavy NFB, stack centres), M (rest).
    // ---------------------------------------------------------------------
    case TwinReverb:
        p.inputHz  = 30.0;
        p.brightHz = 2500.0; p.brightDB = 3.0f;
        p.stageCount = 2;
        // Cue: the Twin must amplify bass and treble EQUALLY. Any shelving here
        // (cathodeHz ≠ 0) and it stops being a Twin.
        // Cue (gains 1.5 / 1.4): clean to Gain ≈ 8, then polite breakup.
        // Distorting at 5 → lower.
        p.stage[0] = st(20.0, 0.0, 0.0f, 22000.0, 1.5f, 0.03f);
        p.stage[1] = st(25.0, 0.0, 0.0f, 20000.0, 1.4f, 0.03f);
        // Cue (mid noonDB −11): clean chords with everything at noon should
        // sound scooped and GLASSY, not boxy. Nasal → more negative; chords
        // vanish in a band mix → back off. (−8…−14.)
        // Cue (bassEatsMid 0.55): turn Bass 3 → 8 and the mids must visibly
        // hollow out. That interaction IS the Fender stack. No change → raise.
        p.tone = tone3( 80.0, 0.70, 1.1f,  +1.0f,
                       400.0, 0.90, 0.8f, -11.0f,
                      3200.0, 0.70, 1.2f,  +2.0f,
                      -16.0f, 0.55f);
        // Cue (headroom 1.60): must stay clean with Volume maxed. Any grit → raise.
        // Cue (nfbDB −5.0): should feel the TIGHTEST of the six.
        p.power = PowerAmpVoicing{
            1.60f, AmpClip::ClassAB, 0.02f,
            0.06f, 30.0,
            1800.0, -5.0f,
            4500.0, 0.8f,
            45.0, 11000.0
        };
        p.cabSlot = 1;                 // intended 2×12 Jensen — see the cab gap note
        p.outTrim = 0.95f;
        break;

    // ---------------------------------------------------------------------
    // Volt AC30 — cathode-biased EL84s with NO negative feedback. Conf: H
    // (no NFB, cathode bias, the backwards Cut control), M (numbers).
    // ---------------------------------------------------------------------
    case AC30:
        p.inputHz  = 40.0;
        p.brightHz = 3000.0; p.brightDB = 4.0f;
        p.stageCount = 2;
        p.stage[0] = st(25.0,   0.0, 0.0f, 20000.0, 1.7f, 0.06f);
        // Cue: top-boost chime on open chords. Missing → lower the Hz slightly
        // and raise the dB. (150–400 Hz / +3…+7 dB.)
        p.stage[1] = st(30.0, 250.0, 5.0f, 16000.0, 2.0f, 0.10f);
        // Cue (mid noonDB +2): the AC30 must be the ONLY mid-forward amp of the
        // six. If it sounds scooped, the sign is wrong.
        // `rangeScale 0.35` on the mid is the AC30 barely having a mid control
        // at all — expressed as a range, not as a special case.
        p.tone = tone3(120.0, 0.70, 0.90f,  0.0f,
                       700.0, 0.60, 0.35f, +2.0f,
                      3500.0, 0.70, 1.20f, +2.0f,
                      -12.0f, 0.15f);
        // The row to read carefully: `Pentode` + headroom 0.55 + asym 0.18 +
        // sagDepth 0.35 + nfbDB 0 together ARE "cathode-biased EL84s with no
        // negative feedback". No flag the JC-120 lacks; the JC-120 row is this
        // row's opposite in every field.
        // Cue (headroom 0.55): must compress and bloom noticeably by Volume 6.
        // Still clean at 8 → lower.
        // Cue (nfbDB 0): must feel LOOSE and touch-responsive against the
        // Marshall's tightness. If it feels tight, NFB has leaked in.
        // Cue (presenceScale −0.8): turn Presence UP and the amp must get
        // DARKER. This is the Vox Cut. If it brightens, the sign is wrong.
        p.power = PowerAmpVoicing{
            0.55f, AmpClip::Pentode, 0.18f,
            0.35f, 80.0,
            0.0, 0.0f,
            4000.0, -0.8f,
            80.0, 8000.0
        };
        p.cabSlot = 1;                 // intended 2×12 alnico blue
        p.outTrim = 1.00f;
        break;

    // ---------------------------------------------------------------------
    // Rolund JC-120 Jazz Chorus — transformerless solid state. Conf: H.
    // ---------------------------------------------------------------------
    case JC120:
        p.inputHz  = 25.0;
        p.brightHz = 0.0; p.brightDB = 0.0f;       // no bright cap
        // Cue (asym 0.00): ZERO even harmonics — clinically clean. Any warmth
        // means the asymmetry leaked in.
        p.stageCount = 2;
        p.stage[0] = st(15.0, 0.0, 0.0f, 25000.0, 1.2f, 0.0f, AmpClip::SolidState);
        p.stage[1] = st(18.0, 0.0, 0.0f, 25000.0, 1.2f, 0.0f, AmpClip::SolidState);
        // Cue (insertionDB −6): the JC's EQ is ACTIVE, so it should lose far
        // less level than the passive stacks. If the JC is much quieter than the
        // Twin at matched knobs, raise it.
        p.tone = tone3( 90.0, 0.70, 1.1f,  0.0f,
                       500.0, 0.80, 1.1f, -3.0f,
                      4000.0, 0.70, 1.1f, +1.0f,
                       -6.0f, 0.10f);
        // Cue (headroom 3.00): must NEVER break up. If it does, raise it — and
        // check the clip family is still SolidState.
        // `presenceScale 0` is "this amp has no presence control", expressed in
        // the schema rather than special-cased. The knob list drops it too.
        p.power = PowerAmpVoicing{
            3.00f, AmpClip::SolidState, 0.0f,
            0.0f, 0.0,
            0.0, 0.0f,
            6000.0, 0.0f,
            30.0, 14000.0
        };
        p.cabSlot = 1;                 // intended 2×12 JC (bright)
        p.outTrim = 0.95f;
        break;

    // ---------------------------------------------------------------------
    // Fandor Bassman '59 — GZ34 tube rectifier: the saggiest amp of the six.
    // Conf: H (sag), M (rest).
    // ---------------------------------------------------------------------
    case Bassman59:
        p.inputHz  = 32.0;
        p.brightHz = 1000.0; p.brightDB = 3.0f;
        p.stageCount = 2;
        p.stage[0] = st(22.0, 180.0, 3.0f, 18000.0, 1.9f, 0.08f);
        p.stage[1] = st(28.0,   0.0, 0.0f, 18000.0, 1.8f, 0.12f);
        p.tone = tone3( 85.0, 0.70, 1.1f,  0.0f,
                       420.0, 0.80, 1.3f, -6.0f,
                      2600.0, 0.70, 1.1f, +1.0f,
                      -13.0f, 0.45f);
        // Cue (sagDepth 0.30 / sagTauMs 60): hit a hard chord — it should DUCK
        // then bloom back over ~60 ms. No duck → raise the depth. Pumping and
        // seasick → lower it. Too short a tau makes the duck sound like a click;
        // too long and the amp sounds broken.
        p.power = PowerAmpVoicing{
            0.85f, AmpClip::ClassAB, 0.10f,
            0.30f, 60.0,
            2500.0, -2.0f,
            3000.0, 0.9f,
            70.0, 8500.0
        };
        p.cabSlot = 0;                 // intended 4×10 tweed
        p.outTrim = 1.05f;
        break;

    // ---------------------------------------------------------------------
    // VOSS Katana 100 — five characters × two variations. All Conf: L.
    // Cue (inputHz 40 → 105 across the characters): higher-gain characters need
    // a higher input high-pass. If Brown is flubby on the low string, raise
    // toward 120.
    // ---------------------------------------------------------------------
    case KatanaAcousticA:   // bright, steel-string
        p = katanaAcoustic(40.0, 20.0, +2.0f, -4.0f, +4.0f, 0.60f);
        break;
    case KatanaAcousticB:   // warm, nylon-ish
        p = katanaAcoustic(45.0, 26.0, +3.0f, -2.0f, +1.0f, 0.40f);
        break;

    case KatanaCleanA:      // JC-flavoured — solid-state clips, near-zero asymmetry
        p = katana({2, {1.3f, 1.3f}, 30.0, {18.0, 22.0}, {0.0, 0.0}, {0.0f, 0.0f},
                    2.20f, 0.05f, 0.0f, -2.0f, +1.0f, 0.90f, 1.00f, AmpClip::SolidState});
        p.stage[0].asym = 0.04f;       // the JC voicing keeps almost no even harmonics
        p.stage[1].asym = 0.04f;
        break;
    case KatanaCleanB:      // Fender-ish, earlier breakup, a 300 Hz cathode shelf
        p = katana({2, {1.6f, 1.5f}, 36.0, {24.0, 30.0}, {0.0, 300.0}, {0.0f, 3.0f},
                    1.70f, 0.10f, +1.0f, -4.0f, +2.0f, 1.00f, 1.00f, AmpClip::Triode});
        break;

    case KatanaCrunchA:     // chime, edge of breakup — the reference Katana row
        // Cue (gains 2.0 / 2.1 / 1.5): with Gain at noon it should sit RIGHT AT
        // edge-of-breakup. Already crunchy at 3 → lower. Clean at 7 → raise.
        p = katana({3, {2.0f, 2.1f, 1.5f}, 60.0, {34.0, 42.0, 50.0},
                    {420.0, 600.0, 0.0}, {6.0f, 5.0f, 0.0f},
                    1.00f, 0.20f, 0.0f, -2.0f, 0.0f, 1.00f, 1.00f, AmpClip::Triode});
        break;
    case KatanaCrunchB:     // plexi push
        p = katana({3, {2.4f, 2.5f, 1.6f}, 72.0, {44.0, 54.0, 62.0},
                    {480.0, 674.0, 0.0}, {8.0f, 6.0f, 0.0f},
                    0.90f, 0.22f, -1.0f, 0.0f, +1.0f, 1.10f, 0.95f, AmpClip::Triode});
        break;

    case KatanaLeadA:       // smooth, sustaining
        p = katana({4, {2.3f, 2.5f, 2.4f, 1.4f}, 80.0, {50.0, 60.0, 70.0, 76.0},
                    {500.0, 650.0, 700.0, 0.0}, {6.0f, 6.0f, 5.0f, 0.0f},
                    0.85f, 0.25f, -1.0f, +2.0f, 0.0f, 1.00f, 0.85f, AmpClip::Triode});
        break;
    case KatanaLeadB:       // tighter, more attack
        p = katana({4, {2.6f, 2.8f, 2.6f, 1.4f}, 95.0, {62.0, 74.0, 86.0, 92.0},
                    {560.0, 720.0, 780.0, 0.0}, {7.0f, 7.0f, 6.0f, 0.0f},
                    0.80f, 0.26f, -2.0f, +1.0f, +2.0f, 1.15f, 0.82f, AmpClip::Triode});
        break;

    case KatanaBrownA:      // classic brown
        p = katana({4, {2.5f, 2.7f, 2.6f, 1.5f}, 85.0, {54.0, 66.0, 78.0, 84.0},
                    {450.0, 620.0, 700.0, 0.0}, {7.0f, 7.0f, 6.0f, 0.0f},
                    0.80f, 0.28f, 0.0f, +3.0f, +1.0f, 1.05f, 0.85f, AmpClip::Triode});
        break;
    case KatanaBrownB:      // modern, scooped, tightest
        // Cue (gains 2.9 / 3.1 / 2.9): the most saturated of the ten, and still
        // articulate on fast runs. MUSHY ON FAST PICKING → raise `couplingHz`,
        // do not lower the gain.
        p = katana({4, {2.9f, 3.1f, 2.9f, 1.5f}, 105.0, {70.0, 84.0, 96.0, 104.0},
                    {520.0, 700.0, 780.0, 0.0}, {8.0f, 8.0f, 7.0f, 0.0f},
                    0.75f, 0.30f, -2.0f, -3.0f, +3.0f, 1.20f, 0.80f, AmpClip::Triode});
        break;

    // ---------------------------------------------------------------------
    // Legacy — the pre-profile fixed voicing, reproduced EXACTLY, and the
    // fallback for every amp the name matcher does not recognize. Every field
    // not listed here is at its neutral value, so the whole power stage is a
    // no-op and the signal path is byte-for-byte what it was before profiles
    // existed. Do not "improve" this row: an offline null test asserts it.
    // ---------------------------------------------------------------------
    case Legacy:
    default:
        p.inputHz    = 95.0;           // AnalogAmp::prepare — highpass(sr, 95, 0.707)
        p.brightHz   = 0.0;            // no bright cap before profiles
        p.stageCount = 1;              // one waveshaper before profiles
        // couplingHz / cathodeHz / cathodeDB all 0 → SKIPPED, not run flat.
        // millerHz 8000 is the pre-profile warmth low-pass; as the LAST stage's
        // Miller pole it is realized as the base-rate output biquad, which is
        // exactly `Biquad::lowpass(sr, 8000, 0.707)` — see AnalogAmp.hpp.
        // asym 0.12 reproduces `constexpr float bias = 0.12f`.
        p.stage[0] = st(0.0, 0.0, 0.0f, 8000.0, 1.0f, 0.12f, AmpClip::Triode);
        // The four fixed bands, all live (rangeScale 1.0, noonDB 0) — including
        // band 3, because before profiles the presence control WAS tone band 3.
        p.tone = ToneStackVoicing{
            {
                ToneBand{ 100.0, 0.70, 1.0f, 0.0f, ToneShape::LowShelf},
                ToneBand{ 650.0, 0.70, 1.0f, 0.0f, ToneShape::Peak},
                ToneBand{3200.0, 0.70, 1.0f, 0.0f, ToneShape::HighShelf},
                ToneBand{6000.0, 0.70, 1.0f, 0.0f, ToneShape::HighShelf},
            },
            0.0f, 0.0f
        };
        // Spelled out rather than defaulted, so this row still reads as a no-op
        // if someone ever changes a field default: clip Clean skips the output
        // waveshaper AND its oversampler, and every sub-block is off by its own
        // field. There was no power amp before profiles, and there must not be
        // one here.
        p.power = PowerAmpVoicing{
            1.0f, AmpClip::Clean, 0.0f,
            0.0f, 0.0,
            0.0, 0.0f,
            6000.0, 0.0f,
            0.0, 0.0
        };
        p.cabSlot = 0;                  // ignored: ParameterMap.cabSlot(name:) still wins
        p.outTrim = 1.0f;
        break;
    }
    return p;
}

const char *ampVoicingName(int voicing) noexcept {
    switch (voicing) {
    case JCM800:          return "JCM800";
    case TwinReverb:      return "Twin Reverb";
    case AC30:            return "AC30";
    case JC120:           return "JC-120";
    case Bassman59:       return "Bassman '59";
    case KatanaAcousticA: return "Katana Acoustic A";
    case KatanaAcousticB: return "Katana Acoustic B";
    case KatanaCleanA:    return "Katana Clean A";
    case KatanaCleanB:    return "Katana Clean B";
    case KatanaCrunchA:   return "Katana Crunch A";
    case KatanaCrunchB:   return "Katana Crunch B";
    case KatanaLeadA:     return "Katana Lead A";
    case KatanaLeadB:     return "Katana Lead B";
    case KatanaBrownA:    return "Katana Brown A";
    case KatanaBrownB:    return "Katana Brown B";
    case Legacy:
    default:              return "Legacy";
    }
}

} // namespace streetrig
