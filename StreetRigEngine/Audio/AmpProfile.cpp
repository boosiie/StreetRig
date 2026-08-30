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
//    • The TANDEM's cathodes are fully bypassed (`cathodeHz 0`) and its couplings
//      are wide open (20–25 Hz) — it amplifies the whole band flat, which is why
//      it stays clean and loud. Its stack then scoops 11 dB at 400 Hz at noon.
//    • The MSW900 shelves +8 dB above 480 Hz in the very FIRST stage and
//      high-passes at 32/40/48 Hz between stages — it distorts the mids and
//      upper mids while keeping the lows out of the clipper, which is why it is
//      tight. Its stack scoops only 7 dB, and at 650 Hz.
//    • The HV28 has NO negative-feedback loop (`nfbDB 0`), the lowest headroom
//      of the six and the highest asymmetry — cathode-biased EL84s, which is
//      what "loose and touch-responsive" actually is. Its presence scale is
//      NEGATIVE: the real control is the Vane Cut, and it works backwards.
//    • The RM-140 is the HV28's opposite in every field: no bright cap, zero
//      asymmetry, `SolidState` clips, 3.0 of headroom, no sag, no NFB, no
//      presence control. Clinically clean, by design.
//
//  CONFIDENCE, and where to spend tuning time. **H** = grounded in published
//  circuit values, **M** = derived from topology, **L** = educated guess. The
//  Kabuto rows are all **L** — Brig publishes nothing about its models — and are
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

// MARK: - The Kabuto, built from its shared chassis
//
// All ten Kabuto voicings are ORDINARY rows in the same table as the MSW900 and
// the Tandem — that is the generalization test, and it is the reason the
// characters are top-level profiles rather than a nested "character" field. If a
// character had needed a special case the schema could not express, the schema
// would be wrong. Two came close and both were absorbed by one general field
// each: the Acoustic character's speakerless voicing became `bypassCab`, and the
// Vane Cut became a negative `rangeScale`/`presenceScale`. Both are now available
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
constexpr double kKabutoMiller[4] = {16000.0, 13000.0, 11000.0, 10000.0};
/// Per-stage clip bias. LOW, and that is the Kabuto's whole character.
///
/// Asymmetry is what makes a valve stage CRUNCH: it manufactures even harmonics,
/// and even harmonics track the pick attack, so the ear hears grain and bite that
/// move with how hard you play. Symmetric clipping does the opposite — odd
/// harmonics, a denser and flatter wall that sits still under the note.
///
/// Reported by ear as wanting "less crunch and more static stuff… a more metal
/// like tone", which is exactly that trade, and it is also true to the amp: the
/// Kabuto is a digital modeller and its high-gain characters are far more
/// symmetric than a real valve front end. Was {0.10, 0.12, 0.12, 0.07} — a
/// tube-ish bias copied from the analog rows without asking whether it belonged.
constexpr float  kKabutoAsym[4]   = {0.035f, 0.045f, 0.045f, 0.025f};

struct KabutoVoice {
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

AmpProfile kabuto(const KabutoVoice &k) noexcept {
    AmpProfile p;
    p.inputHz  = k.inputHz;
    p.brightHz = 1800.0;  p.brightDB = 3.0f;
    p.stageCount = k.stages;
    for (int i = 0; i < k.stages; ++i) {
        p.stage[i] = st(k.coupling[i], k.cathodeHz[i], k.cathodeDB[i],
                        kKabutoMiller[i], k.gain[i], kKabutoAsym[i], k.stageClip);
    }
    // The Kabuto is the ONE amp of the six whose stack really is flat at noon —
    // it is a digital EQ Brig designed to be neutral at centre, so `insertionDB`
    // is 0 and the `noonDB` set averages near zero. Which is also why the
    // pre-profile fixed `ToneStack` already, accidentally, sounded most like a
    // Kabuto and least like everything else.
    // Cue: if the Kabuto sounds coloured with the EQ centred, zero these.
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
/// `bypassCab` had to be a general field rather than a Kabuto special case.
AmpProfile kabutoAcoustic(double inputHz, double couplingHz,
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
    // Marswell MSW900 2140 — tight, mid-forward, "present". Conf: H (cathode
    // corners, stack centres), M (stage gains, noonDB).
    // ---------------------------------------------------------------------
    case MSW900:
        p.inputHz  = 72.0;
        p.brightHz = 1500.0; p.brightDB = 4.0f;
        p.stageCount = 3;
        // S1's 480 Hz / +8 dB cathode shelf IS the Marswell crunch: everything
        // below 480 Hz gets ~8 dB less gain into the next stage.
        // Cue: FLUBBY PALM MUTES → raise the Hz. Thin and brittle → lower it,
        // or reduce the dB. (350–650 Hz / +5…+11 dB.)
        p.stage[0] = st(32.0, 480.0, 8.0f, 15000.0, 2.2f, 0.060f);
        // Cue: upper-mid "bark" on power chords. Too much = honky and nasal.
        p.stage[1] = st(40.0, 674.0, 6.0f, 12000.0, 2.4f, 0.084f);
        p.stage[2] = st(48.0,   0.0, 0.0f, 10000.0, 1.6f, 0.048f);
        // Cue (couplings 32/40/48): low-E chugs should stay defined under gain.
        // Mushy → raise all three ~10 Hz.
        //
        // Cue (mid noonDB −7): the MSW900 must be noticeably MORE mid-present
        // than the Tandem at identical knob settings. If a MSW900 and a Tandem still
        // sound alike at noon, this row and the Tandem's are the first suspects.
        // Cue (mid 650 Hz): palm-muted riffing should have "bark".
        p.tone = tone3( 90.0, 0.70, 1.0f, -1.0f,
                       660.0, 0.80, 1.1f, -1.5f,
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
    // Fandor Tandem Reverb — enormous headroom, deep scoop, the tightest feel.
    // Conf: H (fully bypassed cathodes, heavy NFB, stack centres), M (rest).
    // ---------------------------------------------------------------------
    case TandemReverb:
        p.inputHz  = 30.0;
        p.brightHz = 2500.0; p.brightDB = 3.0f;
        p.stageCount = 2;
        // Cue: the Tandem must amplify bass and treble EQUALLY. Any shelving here
        // (cathodeHz ≠ 0) and it stops being a Tandem.
        // Cue (gains 1.5 / 1.4): clean to Gain ≈ 8, then polite breakup.
        // Distorting at 5 → lower.
        p.stage[0] = st(20.0, 0.0, 0.0f, 26000.0, 1.5f, 0.012f);
        p.stage[1] = st(25.0, 0.0, 0.0f, 24000.0, 1.4f, 0.012f);
        // Cue (mid noonDB −11): clean chords with everything at noon should
        // sound scooped and GLASSY, not boxy. Nasal → more negative; chords
        // vanish in a band mix → back off. (−8…−14.)
        // Cue (bassEatsMid 0.55): turn Bass 3 → 8 and the mids must visibly
        // hollow out. That interaction IS the Fandor stack. No change → raise.
        // TWANG AND GLASS, by ear: the treble shelf moves up and gets a real
        // static lift, and the whole top is opened out. Twang is a bright ATTACK
        // that survives — which is why the headroom and the fast NFB stay: the
        // transient has to get through un-squashed to snap.
        p.tone = tone3( 80.0, 0.70, 1.1f,  +1.0f,
                       400.0, 0.90, 0.8f, -11.0f,
                      3800.0, 0.70, 1.3f,  +5.5f,
                      -16.0f, 0.55f);
        // Cue (headroom 1.60): must stay clean with Volume maxed. Any grit → raise.
        // Cue (nfbDB −5.0): should feel the TIGHTEST of the six.
        p.power = PowerAmpVoicing{
            1.60f, AmpClip::ClassAB, 0.015f,
            0.06f, 30.0,
            1800.0, -5.0f,
            4500.0, 0.9f,
            45.0, 14000.0
        };
        p.cabSlot = 1;                 // intended 2×12 Jensen — see the cab gap note
        p.outTrim = 0.95f;
        break;

    // ---------------------------------------------------------------------
    // Vane HV28 — cathode-biased EL84s with NO negative feedback. Conf: H
    // (no NFB, cathode bias, the backwards Cut control), M (numbers).
    // ---------------------------------------------------------------------
    case HV28:
        p.inputHz  = 40.0;
        p.brightHz = 3000.0; p.brightDB = 4.0f;
        p.stageCount = 2;
        p.stage[0] = st(25.0,   0.0, 0.0f, 20000.0, 1.7f, 0.036f);
        // Cue: top-boost chime on open chords. Missing → lower the Hz slightly
        // and raise the dB. (150–400 Hz / +3…+7 dB.)
        p.stage[1] = st(30.0, 250.0, 5.0f, 16000.0, 2.0f, 0.060f);
        // Cue (mid noonDB +2): the HV28 must be the ONLY mid-forward amp of the
        // six. If it sounds scooped, the sign is wrong.
        // `rangeScale 0.35` on the mid is the HV28 barely having a mid control
        // at all — expressed as a range, not as a special case.
        p.tone = tone3(120.0, 0.70, 0.90f,  0.0f,
                       700.0, 0.60, 0.35f, +2.0f,
                      3500.0, 0.70, 1.20f, +2.0f,
                      -12.0f, 0.15f);
        // The row to read carefully: `Pentode` + headroom 0.55 + asym 0.18 +
        // sagDepth 0.35 + nfbDB 0 together ARE "cathode-biased EL84s with no
        // negative feedback". No flag the RM-140 lacks; the RM-140 row is this
        // row's opposite in every field.
        // Cue (headroom 0.55): must compress and bloom noticeably by Volume 6.
        // Still clean at 8 → lower.
        // Cue (nfbDB 0): must feel LOOSE and touch-responsive against the
        // Marswell's tightness. If it feels tight, NFB has leaked in.
        // Cue (presenceScale −0.8): turn Presence UP and the amp must get
        // DARKER. This is the Vane Cut. If it brightens, the sign is wrong.
        p.power = PowerAmpVoicing{
            // DYNAMICS YOU CAN FEEL, by ear. Less headroom so it blooms earlier,
            // deeper and slower sag so the supply visibly ducks and recovers
            // under a chord, and still no feedback loop at all — that combination
            // IS the touch response, and it is why an HV28 answers the pick the
            // way nothing with a tight NFB can.
            0.46f, AmpClip::Pentode, 0.22f,
            0.48f, 95.0,
            0.0, 0.0f,
            4000.0, -0.8f,
            80.0, 8500.0
        };
        p.cabSlot = 1;                 // intended 2×12 alnico blue
        p.outTrim = 1.00f;
        break;

    // ---------------------------------------------------------------------
    // Rondell RM-140 Velvet Chorus — transformerless solid state. Conf: H.
    // ---------------------------------------------------------------------
    case RM140:
        p.inputHz  = 25.0;
        p.brightHz = 0.0; p.brightDB = 0.0f;       // no bright cap
        // Cue (asym 0.00): ZERO even harmonics — clinically clean. Any warmth
        // means the asymmetry leaked in.
        p.stageCount = 2;
        p.stage[0] = st(15.0, 0.0, 0.0f, 25000.0, 1.2f, 0.0f, AmpClip::SolidState);
        p.stage[1] = st(18.0, 0.0, 0.0f, 25000.0, 1.2f, 0.0f, AmpClip::SolidState);
        // Cue (insertionDB −6): the JC's EQ is ACTIVE, so it should lose far
        // less level than the passive stacks. If the JC is much quieter than the
        // Tandem at matched knobs, raise it.
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
    // Fandor Bassdude '59 — GZ34 tube reactor: the saggiest amp of the six.
    // Conf: H (sag), M (rest).
    // ---------------------------------------------------------------------
    case Bassdude59:
        p.inputHz  = 32.0;
        p.brightHz = 1000.0; p.brightDB = 3.0f;
        p.stageCount = 2;
        p.stage[0] = st(22.0, 180.0, 3.0f, 18000.0, 1.9f, 0.048f);
        p.stage[1] = st(28.0,   0.0, 0.0f, 18000.0, 1.8f, 0.072f);
        p.tone = tone3( 85.0, 0.70, 1.1f,  0.0f,
                       420.0, 0.80, 1.3f, -6.0f,
                      3000.0, 0.70, 1.2f, +3.5f,
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
    // Marswell Clearpane Stellar Lead 1042 — the MSW900's ancestor, and the row that
    // shows the schema separating two amps of the SAME lineage. TWO stages, not
    // three: that missing gain stage is the whole difference in feel. A Clearpane
    // does not have a master volume, so it is loud or it is clean, and it cleans
    // up when you roll the guitar back — which falls out of the two-stage
    // cascade plus the bigger bright cap, not out of any special case.
    // Conf: H (two stages, bright cap, no master), M (gains, noonDB).
    // ---------------------------------------------------------------------
    case Clearpane1042:
        p.inputHz  = 68.0;
        // Cue: the famous bright cap, BIGGER than the MSW900's (1500/+4). Roll
        // the guitar volume to 6 — it must clean up and stay bright, not go dull.
        // Dull → raise the dB toward +7.
        p.brightHz = 1600.0; p.brightDB = 5.0f;
        p.stageCount = 2;
        // Cue (470 Hz / +7 dB): a softer, lower crunch shelf than the 800's
        // 480/+8 — the Clearpane should sound OPEN where the 800 sounds tight.
        p.stage[0] = st(30.0, 470.0, 7.0f, 16000.0, 2.0f, 0.060f);
        p.stage[1] = st(38.0,   0.0, 0.0f, 11000.0, 1.8f, 0.060f);
        // Cue (mid noonDB −6 vs the 800's −7): less scooped, and the mid centre
        // sits higher (680 vs 650). A/B against the MSW900 — the Clearpane should be
        // rounder and less barky at identical knobs. Indistinguishable → widen.
        p.tone = tone3( 95.0, 0.70, 1.0f, -1.0f,
                       680.0, 0.80, 1.1f, -1.0f,
                      2400.0, 0.70, 1.1f, +1.0f,
                      -14.0f, 0.35f);
        // Cue (headroom 0.60, below the 800's 0.75): a Stellar Lead breaks up
        // EARLIER because there is no master to hold the output stage back.
        // Cue (nfbDB −2.5 vs the 800's −3.0): looser, more bloom.
        p.power = PowerAmpVoicing{
            0.60f, AmpClip::ClassAB, 0.06f,
            0.22f, 50.0,
            2000.0, -2.5f,
            3200.0, 1.0f,
            60.0, 9500.0
        };
        p.cabSlot = 0;                 // 4×12 V30
        p.outTrim = 1.00f;
        break;

    // ---------------------------------------------------------------------
    // Fremont GX-140 — a hot-rodded Clearpane, which makes it the sharpest test of
    // whether the schema can separate an amp from its own ancestor. Everything
    // that makes it modern is expressed as MORE STAGES and TIGHTER COUPLING, not
    // as more gain on the same circuit: four stages, every interstage high-pass
    // moved up, a stiffer supply. Conf: M (topology is public, values derived).
    // ---------------------------------------------------------------------
    case GX140:
        // Cue (inputHz 80, the highest of the Marswell family): the GX-140's
        // signature is that it stays TIGHT at gain settings where a Clearpane turns
        // to mud. Flubby on the low string → raise toward 95.
        p.inputHz  = 80.0;
        p.brightHz = 1800.0; p.brightDB = 3.0f;    // less bright cap — the gain carries it
        p.stageCount = 4;
        // Cue (520 Hz / +9 dB): a HOTTER, HIGHER crunch shelf than any stock
        // Marswell — this is the "hot-rod" in one field.
        p.stage[0] = st(45.0, 520.0, 9.0f, 15000.0, 2.4f, 0.060f);
        p.stage[1] = st(55.0, 700.0, 7.0f, 13000.0, 2.6f, 0.078f);
        p.stage[2] = st(62.0,   0.0, 0.0f, 11000.0, 2.2f, 0.066f);
        // Cue: the last stage is a follower, not another gain stage. If the amp
        // fizzes on the top end, lower this Miller toward 8500.
        p.stage[3] = st(70.0,   0.0, 0.0f,  9500.0, 1.5f, 0.042f);
        // Cue (couplings 45/55/62/70, the tightest cascade in the table): chugs
        // must stay separated under high gain. Smearing → raise all four ~8 Hz.
        p.tone = tone3(100.0, 0.70, 1.00f, -1.5f,
                       700.0, 0.80, 1.1f, -1.5f,
                      2500.0, 0.70, 1.15f, +2.0f,
                      -14.0f, 0.32f);
        // Cue (sagDepth 0.10, the stiffest of the tube amps): a GX-140 should NOT
        // duck and bloom the way the Clearpane and the Bassdude do. If it sags
        // audibly, this is why.
        // Cue (nfbDB −3.5): the tightest feel of the Marswell family.
        p.power = PowerAmpVoicing{
            0.70f, AmpClip::ClassAB, 0.05f,
            0.10f, 35.0,
            2400.0, -3.5f,
            3600.0, 1.1f,
            70.0, 9500.0
        };
        p.cabSlot = 0;
        p.outTrim = 0.95f;
        break;

    // ---------------------------------------------------------------------
    // Mesquite Bootleg Dual Reactor — the schema's opposite pole from the HV28, and
    // the darkest, loosest, most scooped row in the table. Three fields carry
    // almost all of it: NO bright cap, a −13 dB mid scoop, and sagDepth 0.30 with
    // the LEAST negative feedback of any tube amp here (the tube-reactor
    // looseness). Conf: M (scoop and sag are H by reputation, values derived).
    // ---------------------------------------------------------------------
    case DualReactor:
        // Cue (inputHz 55, the lowest of the high-gain amps): the Reactor low end
        // is the point. Do NOT tighten this to fix flub — lower the gain instead,
        // or the amp stops being a Reactor.
        p.inputHz  = 55.0;
        p.brightHz = 0.0; p.brightDB = 0.0f;       // no bright cap — it is a DARK amp
        p.stageCount = 4;
        p.stage[0] = st(25.0, 400.0, 6.0f, 13000.0, 2.5f, 0.054f);
        p.stage[1] = st(30.0,   0.0, 0.0f, 11000.0, 2.8f, 0.072f);
        p.stage[2] = st(35.0,   0.0, 0.0f,  9500.0, 2.4f, 0.060f);
        p.stage[3] = st(40.0,   0.0, 0.0f,  8500.0, 1.6f, 0.036f);
        // Cue (Millers 13k→8.5k, the darkest cascade in the table): if it sounds
        // fizzy rather than dark, these are too high.
        //
        // Cue (mid noonDB −13, the deepest scoop of any amp here — deeper even
        // than the Tandem's −11): palm mutes at noon must sound SCOOPED and modern.
        // If it sounds like a Marswell, this value is the first suspect.
        p.tone = tone3( 80.0, 0.70, 1.20f,  +3.0f,
                       500.0, 0.95, 0.85f, -13.0f,
                      3000.0, 0.70, 1.20f,  +2.5f,
                      -15.0f, 0.50f);
        // Cue (sagDepth 0.30 / nfbDB −1.5): the Reactor should feel LOOSE and
        // rubbery under the pick — the opposite of the GX-140. If it feels tight,
        // check the NFB first: −1.5 is deliberately the least of any tube amp.
        p.power = PowerAmpVoicing{
            0.85f, AmpClip::ClassAB, 0.04f,
            0.30f, 60.0,
            1600.0, -1.5f,
            3000.0, 1.2f,
            50.0, 8500.0
        };
        p.cabSlot = 0;                 // Mesquite Bootleg oversized 4×12
        p.outTrim = 0.92f;
        break;

    // ---------------------------------------------------------------------
    // Tangerine Rumblecrest 100 — thick and midrange-RICH, and a useful check
    // that "thick" and "mid-forward" are different things in this schema. The
    // HV28 is the only amp with a POSITIVE mid noonDB and must stay that way; the
    // Rumblecrest gets its weight from the least-scooped Marswell-family mid
    // (−4 dB) sitting LOWER (560 Hz), plus a dark top — not from a mid boost.
    // Conf: M.
    // ---------------------------------------------------------------------
    case Rumblecrest:
        p.inputHz  = 60.0;
        p.brightHz = 1400.0; p.brightDB = 2.0f;    // a small, low bright cap
        p.stageCount = 3;
        // SAWTOOTH, and that word is a specification. A square wave carries only
        // ODD harmonics; a SAWTOOTH carries every one, odd and even — and even
        // harmonics come from ASYMMETRIC clipping. So the bias goes up hard, which
        // is the exact opposite of what the Kabuto just got, and it is what makes
        // this amp read as fuzzy and buzzsaw where that one reads as a smooth
        // wall. Pentode on the last stage for a harder knee.
        p.stage[0] = st(28.0, 420.0, 6.5f, 14000.0, 2.6f, 0.30f);
        p.stage[1] = st(34.0, 600.0, 5.0f, 11500.0, 2.8f, 0.34f);
        p.stage[2] = st(42.0,   0.0, 0.0f,  9500.0, 1.9f, 0.26f, AmpClip::Pentode);
        // Cue (mid 560 Hz / noonDB −4): the LEAST scooped of the gain amps. Open
        // chords should sound thick and woody. If it sounds honky, raise the Hz;
        // if it sounds scooped, this row and the MSW900's have drifted together.
        // Cue: it must still measure BELOW the HV28 in the 300–1.2k band. If the
        // "HV28 is the only mid-forward amp" check fails, this is the amp that
        // broke it — lower the noonDB, do not raise the HV28.
        p.tone = tone3( 95.0, 0.70, 1.00f,  0.0f,
                       560.0, 0.80, 0.95f, -4.0f,
                      2200.0, 0.70, 1.00f,  0.0f,
                      -13.0f, 0.28f);
        // Cue (asym 0.06 + OT 8800): warm and slightly compressed, between the
        // Clearpane's openness and the Reactor's darkness.
        p.power = PowerAmpVoicing{
            0.62f, AmpClip::Pentode, 0.16f,
            0.20f, 48.0,
            2000.0, -2.2f,
            3300.0, 1.0f,
            60.0, 9200.0
        };
        p.cabSlot = 0;                 // Tangerine TSV412
        p.outTrim = 0.97f;
        break;

    // ---------------------------------------------------------------------
    // BRIG Kabuto 100 — five characters × two variations. All Conf: L.
    // Cue (inputHz 40 → 105 across the characters): higher-gain characters need
    // a higher input high-pass. If Brown is flubby on the low string, raise
    // toward 120.
    // ---------------------------------------------------------------------
    case KabutoAcousticA:   // bright, steel-string
        p = kabutoAcoustic(40.0, 20.0, +2.0f, -4.0f, +4.0f, 0.60f);
        break;
    case KabutoAcousticB:   // warm, nylon-ish
        p = kabutoAcoustic(45.0, 26.0, +3.0f, -2.0f, +1.0f, 0.40f);
        break;

    case KabutoCleanA:      // JC-flavoured — solid-state clips, near-zero asymmetry
        p = kabuto({2, {1.3f, 1.3f}, 30.0, {18.0, 22.0}, {0.0, 0.0}, {0.0f, 0.0f},
                    2.20f, 0.05f, 0.0f, -2.0f, +1.0f, 0.90f, 1.00f, AmpClip::SolidState});
        p.stage[0].asym = 0.04f;       // the JC voicing keeps almost no even harmonics
        p.stage[1].asym = 0.04f;
        break;
    case KabutoCleanB:      // Fandor-ish, earlier breakup, a 300 Hz cathode shelf
        p = kabuto({2, {1.6f, 1.5f}, 36.0, {24.0, 30.0}, {0.0, 300.0}, {0.0f, 3.0f},
                    1.70f, 0.10f, +1.0f, -4.0f, +2.0f, 1.00f, 1.00f, AmpClip::Triode});
        break;

    // GAINS PULLED BACK TWICE, by ear on an iPhone 17e: Crunch, Lead and Brown
    // were "too extreme", and still too extreme after the first −15%. Down another
    // −15% here, so roughly −28% from where they started. Every one of these rows
    // was Conf: L — Brig publishes nothing
    // about its models and they were reasoned, not measured — so a player's ear
    // outranks them. Roughly −15% on the saturating stages of each; the follower
    // stage is left alone because it sets level, not dirt. Brown B stays the most
    // saturated of the ten and Crunch A the least, so the ORDER is intact.
    // THE GAIN KNOB HAD NOTHING LEFT TO DO. Caught by a check comparing Brown B
    // against ITSELF: 35.1% harmonics at Gain 1 and 32.1% at Gain 9 — turning it
    // up made it measurably LESS distorted, which is impossible unless the amp is
    // already flat out at the bottom of the dial. It was: four stages at ~2.2×
    // each is ~25× baked into the profile before the knob is consulted, so Gain 1
    // was already fully saturated and Gain 9 only pushed it into a squarer wave
    // whose harmonics stop growing.
    //
    // That is also the honest explanation of the original "too extreme": the amp
    // was maxed wherever the knob sat. A profile should set the amp's CHARACTER
    // and leave the dial the range to go from clean to wall. Stage gains cut to
    // roughly 1.3–1.7 so the knob reaches saturation instead of starting there —
    // the density stays, because it comes from the near-symmetric bias and the
    // tight interstage filters, not from brute gain.
    //
    // SATURATION IS NOT LOUDNESS, and the first pass at "filled" confused them.
    // Dropping the clip bias to near-symmetric was right for the character — even
    // harmonics are what crunch IS — but symmetric clipping also makes LESS total
    // harmonic energy at a given drive, so the high-gain rows came out cleaner
    // rather than denser. Brown B cranked measured only 4.7 points of harmonics
    // above a clean amp; it should tower over one.
    //
    // So the clippers are driven harder again and `outTrim` is pulled down by the
    // same amount. More saturation, identical loudness — which is what "filled"
    // asks for, and the opposite of the "too extreme" that got the gains cut in
    // the first place. Extreme was LEVEL. Filled is DENSITY.
    //
    // THE "A" VARIATIONS ARE THE FILLED ONES NOW. Reported by ear that the Brig
    // wants a more filled, metal-leaning voice "especially on variation A".
    // Filled is not more gain — the gains were pulled back twice on request — it
    // is less low end reaching each clipper, so the distortion is dense and even
    // instead of loose and crunchy. Every A row's input and interstage high-passes
    // move up ~10 Hz, which takes the flub out of the clipper without touching how
    // hard it is driven. Combined with the near-symmetric bias above, that is a
    // wall rather than a chew.
    case KabutoCrunchA:     // chime, edge of breakup — the reference Kabuto row
        // Cue (gains 2.0 / 2.1 / 1.5): with Gain at noon it should sit RIGHT AT
        // edge-of-breakup. Already crunchy at 3 → lower. Clean at 7 → raise.
        p = kabuto({3, {1.30f, 1.38f, 1.15f}, 68.0, {44.0, 54.0, 62.0},
                    {420.0, 600.0, 0.0}, {6.0f, 5.0f, 0.0f},
                    1.00f, 0.20f, 0.0f, -2.0f, 0.0f, 1.00f, 1.00f, AmpClip::Triode});
        break;
    case KabutoCrunchB:     // clearpane push
        p = kabuto({3, {1.45f, 1.55f, 1.22f}, 72.0, {44.0, 54.0, 62.0},
                    {480.0, 674.0, 0.0}, {8.0f, 6.0f, 0.0f},
                    0.90f, 0.22f, -1.0f, 0.0f, +1.0f, 1.10f, 0.95f, AmpClip::Triode});
        break;

    case KabutoLeadA:       // smooth, sustaining
        p = kabuto({4, {1.42f, 1.50f, 1.42f, 1.15f}, 88.0, {60.0, 72.0, 82.0, 88.0},
                    {500.0, 650.0, 700.0, 0.0}, {6.0f, 6.0f, 5.0f, 0.0f},
                    0.85f, 0.25f, -1.0f, +2.0f, 0.0f, 1.00f, 0.70f, AmpClip::Triode});
        break;
    case KabutoLeadB:       // tighter, more attack
        p = kabuto({4, {1.55f, 1.62f, 1.55f, 1.15f}, 95.0, {62.0, 74.0, 86.0, 92.0},
                    {560.0, 720.0, 780.0, 0.0}, {7.0f, 7.0f, 6.0f, 0.0f},
                    0.80f, 0.26f, -2.0f, +1.0f, +2.0f, 1.15f, 0.68f, AmpClip::Triode});
        break;

    case KabutoBrownA:      // classic brown
        p = kabuto({4, {1.50f, 1.60f, 1.55f, 1.18f}, 95.0, {66.0, 78.0, 88.0, 94.0},
                    {450.0, 620.0, 700.0, 0.0}, {7.0f, 7.0f, 6.0f, 0.0f},
                    0.80f, 0.28f, 0.0f, +3.0f, +1.0f, 1.05f, 0.70f, AmpClip::Triode});
        break;
    case KabutoBrownB:      // modern, scooped, tightest
        // Cue (gains 2.9 / 3.1 / 2.9): the most saturated of the ten, and still
        // articulate on fast runs. MUSHY ON FAST PICKING → raise `couplingHz`,
        // do not lower the gain.
        p = kabuto({4, {1.62f, 1.70f, 1.62f, 1.18f}, 122.0, {84.0, 96.0, 108.0, 116.0},
                    {520.0, 700.0, 780.0, 0.0}, {8.0f, 8.0f, 7.0f, 0.0f},
                    0.75f, 0.30f, -2.0f, -3.0f, +3.0f, 1.20f, 0.66f, AmpClip::Triode});
        break;

    // ---------------------------------------------------------------------
    // Marswell VCX45C — the modern Marswell, and the only profiled amp that is a
    // 1×12 COMBO rather than a head into a 4×12, so it is the one row where
    // `cabSlot` carries real voicing weight (slot 1, the brighter small box).
    // Four stages against the MSW900's three: more gain, smoother, a little
    // darker. Conf: M.
    // ---------------------------------------------------------------------
    case VCX45C:
        p.inputHz  = 75.0;
        p.brightHz = 1600.0; p.brightDB = 3.5f;
        p.stageCount = 4;
        // Cue (500 Hz / +8 dB): the same crunch shelf idea as the MSW900, one
        // stage earlier in a longer cascade — which is what makes the VCX smoother
        // at high gain rather than just louder.
        p.stage[0] = st(35.0, 500.0, 8.0f, 15000.0, 2.3f, 0.060f);
        p.stage[1] = st(42.0, 690.0, 6.5f, 12500.0, 2.5f, 0.078f);
        p.stage[2] = st(50.0,   0.0, 0.0f, 10500.0, 2.0f, 0.060f);
        p.stage[3] = st(56.0,   0.0, 0.0f,  9500.0, 1.4f, 0.042f);
        // Cue (mid noonDB −7.5): a shade more scooped than the MSW900's −7 — the
        // VCX's "modern" voicing. A/B the two: same family, the VCX smoother and
        // slightly hollower. If they are indistinguishable, widen this gap first.
        p.tone = tone3( 92.0, 0.70, 1.00f, -1.0f,
                       670.0, 0.80, 1.1f, -2.0f,
                      2350.0, 0.70, 1.10f, +1.5f,
                      -14.0f, 0.35f);
        p.power = PowerAmpVoicing{
            0.68f, AmpClip::ClassAB, 0.05f,
            0.20f, 45.0,
            2200.0, -3.0f,
            3500.0, 1.0f,
            65.0, 9000.0
        };
        // The one combo in the profiled set — a 1×12, not a 4×12.
        p.cabSlot = 1;
        p.outTrim = 0.98f;
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
    case MSW900:          return "MSW900";
    case TandemReverb:      return "TandemReverb";
    case HV28:            return "HV28";
    case RM140:           return "RM-140";
    case Bassdude59:       return "Bassdude '59";
    case Clearpane1042:       return "Clearpane Stellar Lead";
    case GX140:           return "GX-140";
    case DualReactor:        return "Dual Reactor";
    case Rumblecrest:      return "Rumblecrest 100";
    case VCX45C:          return "VCX45C";
    case KabutoAcousticA: return "Kabuto Acoustic A";
    case KabutoAcousticB: return "Kabuto Acoustic B";
    case KabutoCleanA:    return "Kabuto Clean A";
    case KabutoCleanB:    return "Kabuto Clean B";
    case KabutoCrunchA:   return "Kabuto Crunch A";
    case KabutoCrunchB:   return "Kabuto Crunch B";
    case KabutoLeadA:     return "Kabuto Lead A";
    case KabutoLeadB:     return "Kabuto Lead B";
    case KabutoBrownA:    return "Kabuto Brown A";
    case KabutoBrownB:    return "Kabuto Brown B";
    case Legacy:
    default:              return "Legacy";
    }
}

} // namespace streetrig
