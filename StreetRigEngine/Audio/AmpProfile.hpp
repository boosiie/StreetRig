//
//  AmpProfile.hpp
//  StreetRig
//
//  PER-AMP VOICING as pure data. Before this file every amp in StreetRig was the
//  same DSP with different artwork: one fixed preamp voicing, one fixed 4-band
//  tone stack, and the amp's name used only to pick a cab IR. An `AmpProfile` is
//  the whole-amp analogue of `DrivePedal::Voice` — a `constexpr`-friendly POD
//  resolved ONCE at setup time by `profileFor(int)`, whose shape is deliberately
//  the exact shape of `DrivePedal::voiceFor(int)`. No per-amp subclasses, no
//  virtual dispatch, no audio-thread allocation, and adding the next amp is one
//  row in the table rather than new DSP.
//
//  WHAT THE SCHEMA MODELS, and why each field exists (see
//  research/amp-emulation-approaches.md §1 for the circuit reasoning):
//
//    1. INPUT + BRIGHT CAP        — where the amp tightens the low end, and the
//                                   treble-bleed cap across the volume pot.
//    2. PREAMP CASCADE            — N stages, each a coupling high-pass, a
//                                   cathode-bypass SHELF, a gain, a waveshaper
//                                   and a Miller low-pass. The cathode shelf is
//                                   the differentiator most models omit and is
//                                   most of what makes a Marswell a Marswell.
//    3. TONE STACK                — per-amp centres, Qs, ranges and — the field
//                                   whose absence is why every amp currently
//                                   sounds the same — `ToneBand::noonDB`. A real
//                                   passive TMB network is NOT flat at noon: a
//                                   Fandor scoops ~11 dB at ~400 Hz, a Marswell
//                                   ~7 dB at ~650 Hz, a Vane is mid-FORWARD.
//    4. POWER AMP                 — headroom, clip family, sag, the global
//                                   negative-feedback loop the presence control
//                                   actually lives inside, and the output
//                                   transformer's two rolloffs.
//    5. CAB PAIRING + TRIM        — which IR slot, whether there is a speaker at
//                                   all, and the level match across profiles.
//
//  A DISABLED FIELD IS SKIPPED, NOT RUN FLAT. A "flat" filter is not bit-identical
//  to *no* filter, so per-field skipping is the only way `AmpVoicing::Legacy` can
//  be guaranteed sample-for-sample identical to the pre-profile engine. This is
//  exactly how `DrivePedal::configure` already works
//  (`v_.preMidDB != 0.0 ? Biquad::peaking(...) : Biquad{}`). The neutral values
//  are documented per field below.
//
//  THE NUMBERS ARE THE TUNING CONTRACT. Every hard-coded voicing value lives in
//  ONE auditable place — `profileFor()` in AmpProfile.cpp — the way
//  `DrivePedal.cpp`'s `voiceFor()` holds the pedal numbers and
//  `ParameterMap.swift` holds the knob curves, so the owner can ear-tune them
//  against real hardware through an iRig without hunting through DSP. Each row
//  carries the listening cue from research/amp-emulation-approaches.md §11.
//
//  REAL-TIME CONTRACT: nothing here runs on the audio thread. `profileFor` is a
//  pure function returning a POD by value, called from
//  `AmpCabProcessor::configureAmp` on the setup thread inside the kernel's
//  reconfigure barrier. See RealtimeSafety.md.
//

#ifndef STREETRIG_AMP_PROFILE_HPP
#define STREETRIG_AMP_PROFILE_HPP

namespace streetrig {

/// Waveshaper families available to an amp stage. Deliberately a separate enum
/// from `DrivePedal::Clip`: the amp side needs `Clean` (no nonlinearity at all —
/// an acoustic preamp, a RM-140's headroom) and the two output-stage families.
enum class AmpClip : int {
    Clean      = 0,  ///< no nonlinearity at all — the stage is a pure gain
    Triode     = 1,  ///< asymmetric tanh — the preamp valve
    Pentode    = 2,  ///< harder knee, more odd harmonics — EL84/EL34 output valve
    ClassAB    = 3,  ///< symmetric push-pull with a crossover knee
    SolidState = 4   ///< hard clip — RM-140 and the Kabuto power section
};

enum class ToneShape : int { LowShelf = 0, Peak = 1, HighShelf = 2 };

/// One cascaded preamp stage.
///
/// EVERY FILTER HERE IS FIRST ORDER because every one of them is first order in
/// the real circuit (coupling cap × grid leak, cathode bypass RC, Miller
/// capacitance). Biquads would cost 3× for no extra truth, and at 4×
/// oversampling a biquad per filter per stage would be 48 biquad-equivalents per
/// base sample on a 4-stage amp. This is a deliberate departure from
/// `DrivePedal`, which uses biquads because its pre/post mid bumps genuinely are
/// resonant.
struct PreampStage {
    double  couplingHz = 0.0;       ///< interstage high-pass (coupling cap × grid leak), Hz. 0 = skipped
    double  cathodeHz  = 0.0;       ///< cathode-bypass shelf corner, Hz. 0 = fully bypassed (flat)
    float   cathodeDB  = 0.0f;      ///< lift ABOVE cathodeHz, dB. 0 = skipped. The Marswell crunch lives here
    double  millerHz   = 0.0;       ///< stage-output low-pass (Miller capacitance), Hz. 0 = skipped
    float   gain       = 1.0f;      ///< linear gain into this stage's nonlinearity
    float   asym       = 0.05f;     ///< clip bias → even harmonics (tube-like)
    AmpClip clip       = AmpClip::Triode;   ///< Clean = this stage's waveshaper is bypassed
};

/// One tone-stack band.
///
/// `noonDB` is what the PASSIVE network does with the knob at NOON — the field
/// the pre-profile `ToneStack` was missing, and the single biggest reason a
/// Fandor and a Marswell sounded the same. It is also the cheapest large win in
/// the whole change: it costs nothing at render time, because only the
/// coefficient *design* (main thread) changes.
struct ToneBand {
    double    hz         = 100.0;
    double    q          = 0.707;
    float     rangeScale = 1.0f;    ///< × the bus dB (1.0 = the ±12 / ±9 swing the knob sends).
                                    ///< NEGATIVE inverts the knob — the Vane "Cut" control.
                                    ///< 0 with noonDB 0 = no such control; the band is skipped
    float     noonDB     = 0.0f;    ///< static contribution with the knob at noon
    ToneShape shape      = ToneShape::LowShelf;
};

struct ToneStackVoicing {
    ToneBand band[4];               ///< 0 = Bass, 1 = Mid, 2 = Treble, 3 = Presence
    /// Static loss of the passive network, dB (negative). Applied at the tone
    /// stack's OUTPUT and recovered as makeup AFTER the power amp — which is the
    /// only placement where the field does anything: it is what decides how hard
    /// the tone stack drives the output valves. A Fandor's ~16 dB of insertion
    /// loss is precisely why its power amp stays clean at settings that would
    /// have an HV28 (~12 dB) compressing.
    float    insertionDB = 0.0f;
    /// 0..1 — how much Bass BOOST deepens the mid notch. On a Fandor, turning
    /// Bass up hollows the mids out, because the mid pot's resistance below its
    /// wiper adds to the treble filter's. One scalar, applied when coefficients
    /// are recomputed, i.e. on the main thread at zero audio-thread cost.
    float    bassEatsMid = 0.0f;
};

/// The output stage. Everything here was absent before this change.
///
/// EVERY DEFAULT IS THE NEUTRAL VALUE, so a default-constructed `PowerAmpVoicing`
/// is a complete no-op — which is what `AmpVoicing::Legacy` needs, and the only
/// way the "an unprofiled amp is bit-identical" guarantee can be stated as an
/// invariant of the type rather than a promise each row has to remember to keep.
/// (The first cut of this struct defaulted `clip` to `ClassAB`, which silently
/// gave the Legacy voicing an output-stage clip at unity and a 2× oversampler's
/// group delay. The null test caught it; the fix is this comment's reason for
/// existing.)
struct PowerAmpVoicing {
    float   headroom      = 1.0f;   ///< linear level at which the output stage begins to clip
    AmpClip clip          = AmpClip::Clean;   ///< Clean = the output clip AND its 2× oversampler are skipped
    float   asym          = 0.0f;
    float   sagDepth      = 0.0f;   ///< 0..1 supply droop under load. 0 = skipped
    double  sagTauMs      = 45.0;   ///< sag recovery time constant, ms
    double  nfbHz         = 0.0;    ///< global negative-feedback shelf corner, Hz
    float   nfbDB         = 0.0f;   ///< NFB damping (negative = tighter/darker). 0 = NO feedback loop
    double  presenceHz    = 3500.0; ///< the presence control's shelf — it lives IN the NFB loop
    float   presenceScale = 0.0f;   ///< × the bus dB. 0 = this amp has no presence control
    double  otLowHz       = 0.0;    ///< output-transformer LF rolloff, Hz. 0 = skipped
    double  otHighHz      = 0.0;    ///< output-transformer HF rolloff, Hz. 0 = skipped
};

/// ONE AMP. Pure data, no virtuals, no allocation — the whole-amp analogue of
/// `DrivePedal::Voice`. Resolved once at setup time by
/// `AmpCabProcessor::configureAmp()`.
struct AmpProfile {
    static constexpr int kMaxStages = 4;

    double inputHz    = 0.0;        ///< input / grid tightening high-pass, Hz. 0 = skipped
    double brightHz   = 0.0;        ///< bright-cap high shelf, Hz. 0 = skipped
    float  brightDB   = 0.0f;

    int         stageCount = 1;     ///< 1..kMaxStages
    PreampStage stage[kMaxStages];

    ToneStackVoicing tone;
    PowerAmpVoicing  power;

    int   cabSlot   = 0;            ///< preferred IR slot
    bool  bypassCab = false;        ///< true = no speaker in the model (Kabuto ACOUSTIC)
    float outTrim   = 1.0f;         ///< level match across profiles

    /// Optional per-amp neural capture (resource base name, STATIC storage — so
    /// the profile stays POD and `constexpr`-friendly). nullptr = fully
    /// algorithmic. This is the seam that lets a rights-cleared capture ride the
    /// same profile with no architectural change: a capture replaces the PREAMP
    /// CASCADE ONLY, and the profile's tone stack, power amp, OT rolloffs and cab
    /// pairing still apply — because a capture of a preamp is a capture of a
    /// preamp, and the rest of the profile is still the truth about that amp.
    const char *neuralModel = nullptr;
};

/// Profile ids. APPEND-ONLY — they are persisted indirectly (a saved rig's amp
/// name resolves to one) and they appear in `RigDSPPlan.signature`.
/// MUST match `ParameterMap.amp*` (Swift). The two tables are mirrored by hand,
/// exactly as `DrivePedal::Voicing` ↔ `ParameterMap.voice*` already are.
enum AmpVoicing : int {
    Legacy      = 0,   ///< the pre-profile fixed voicing — the universal fallback
    MSW900      = 1,
    TandemReverb  = 2,
    HV28        = 3,
    RM140      = 4,
    Bassdude59   = 5,
    // 6..9 were reserved for four of the five remaining catalog amps and are now
    // filled. Marswell VCX45C took 20; 21+ is open for anything later.
    Clearpane1042   = 6,
    GX140      = 7,
    DualReactor    = 8,
    Rumblecrest  = 9,
    KabutoAcousticA = 10, KabutoAcousticB = 11,
    KabutoCleanA    = 12, KabutoCleanB    = 13,
    KabutoCrunchA   = 14, KabutoCrunchB   = 15,
    KabutoLeadA     = 16, KabutoLeadB     = 17,
    KabutoBrownA    = 18, KabutoBrownB    = 19,
    VCX45C          = 20
};

/// THE ONE AUDITABLE TABLE — the exact shape of `DrivePedal::voiceFor(int)`.
/// Pure; returns `profileFor(Legacy)` for any id it does not know. Setup thread.
AmpProfile profileFor(int voicing) noexcept;

/// Human-readable id → name. DEBUGGER AID: profile ids appear in
/// `RigDSPPlan.signature` and in `SRKernelActiveAmpProfile`, and reading "14"
/// off a breakpoint is not the same as reading "Kabuto Crunch A". Not on any
/// audio or setup path.
const char *ampVoicingName(int voicing) noexcept;

} // namespace streetrig

#endif /* STREETRIG_AMP_PROFILE_HPP */
