//
//  AnalogAmp.hpp
//  StreetRig
//
//  The PROFILED PREAMP. Originally a single fixed voicing (95 Hz high-pass → 4×
//  oversampled asymmetric tanh → 8 kHz low-pass) that every amp in the app
//  shared; it is now a data-driven cascade whose entire character comes from an
//  `AmpProfile` applied at setup time:
//
//      input high-pass → bright-cap shelf
//        ┌─ 4× OVERSAMPLED ───────────────────────────────────────────────┐
//        │  for each of N stages:                                         │
//        │     coupling high-pass → cathode shelf → × gain → clip         │
//        │       → interstage Miller low-pass                             │
//        └────────────────────────────────────────────────────────────────┘
//      → output low-pass (the LAST stage's Miller pole)
//
//  WHY THE STAGE FILTERS ARE ONE-POLES. A waveshaper's character is set less by
//  its transfer curve than by WHAT REACHES IT, and the three things that shape
//  that between two cascaded valve stages — the coupling cap into the next grid
//  leak, the cathode-bypass network, the Miller pole — are all FIRST ORDER in the
//  real circuit. Biquads would cost 3× for no extra truth, and inside a 4×
//  oversampled region on a 4-stage amp that is 48 biquad-equivalents per base
//  sample. This is a deliberate departure from `DrivePedal`, which uses biquads
//  because its pre/post mid bumps genuinely are resonant. The cathode shelf in
//  particular is the differentiator most models omit: a partially-bypassed
//  Marshall cathode lifts roughly +8 dB above ~480 Hz, so everything below that
//  gets ~8 dB LESS gain into the next stage — which is most of the "crispy
//  crunchy" character, and none of it was modelled before.
//
//  WHY THE CASCADE WIDENS THE EXISTING OVERSAMPLED REGION rather than adding
//  one: a static nonlinearity manufactures harmonics above Nyquist that fold back
//  as inharmonic "digital fizz". Running the clips at 4× with band-limiting FIRs
//  on the way up and down pushes those images out of band before decimation
//  removes them — and one up/down conversion covers N stages, regardless of N.
//  The linear voicing filters do not alias, so only the clips need to be inside.
//
//  WHY THE LAST STAGE'S MILLER POLE IS A BASE-RATE BIQUAD. Nothing clips after
//  it, so running it at 4× buys nothing; it is the amp's OUTPUT bandwidth, where
//  a steeper slope earns its keep; and it is literally the pre-profile warmth
//  low-pass, which is what keeps `AmpVoicing::Legacy` byte-for-byte identical to
//  the engine before profiles existed. Interstage Miller poles stay inside the
//  oversampled region because they shape what reaches the NEXT clipper.
//
//  REAL-TIME CONTRACT: `prepare()` designs the FIR and allocates all state;
//  `configure()` re-designs every filter for a new profile (setup thread, called
//  under the kernel's reconfigure barrier) WITHOUT allocating. `process()` is
//  allocation/lock/IO-free. Per-channel state means a stereo path never
//  cross-contaminates. See RealtimeSafety.md.
//

#ifndef STREETRIG_ANALOG_AMP_HPP
#define STREETRIG_ANALOG_AMP_HPP

#include <cmath>

#include "AmpProfile.hpp"

namespace streetrig {

/// Direct-Form-I biquad with per-instance state. Coefficients are normalized
/// (a0 = 1). Used for the fixed voicing filters.
struct Biquad {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    float x1 = 0, x2 = 0, y1 = 0, y2 = 0;

    inline float process(float x) noexcept {
        float y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
        x2 = x1; x1 = x;
        y2 = y1; y1 = y;
        return y;
    }
    inline void reset() noexcept { x1 = x2 = y1 = y2 = 0; }

    /// Set the five coefficients without touching the running state (used by the
    /// tone stack, which recomputes coefficients off the audio thread but keeps
    /// the per-channel filter memory continuous). See ToneStack.
    inline void setCoeffs(float nb0, float nb1, float nb2, float na1, float na2) noexcept {
        b0 = nb0; b1 = nb1; b2 = nb2; a1 = na1; a2 = na2;
    }

    static Biquad highpass(double sr, double fc, double q);
    static Biquad lowpass(double sr, double fc, double q);
    // Prompt 003 — passive-tone-stack building blocks (RBJ cookbook forms).
    static Biquad lowShelf(double sr, double fc, double q, double gainDB);
    static Biquad highShelf(double sr, double fc, double q, double gainDB);
    static Biquad peaking(double sr, double fc, double q, double gainDB);
};

// MARK: - First-order primitives (the profiled amp's interstage + OT filters)
//
// `a`/`c` of 0 means the filter is DISABLED and `process` is the identity — the
// per-field skip rule the whole back-compat guarantee rests on. A "flat" filter
// is not bit-identical to NO filter, so a disabled field must be skipped, never
// run at unity.

/// One-pole low-pass. `a = 0` → identity (disabled).
struct OnePoleLP {
    float a = 0.0f, y = 0.0f;
    inline float process(float x) noexcept {
        if (a == 0.0f) return x;
        y += a * (x - y);
        return y;
    }
    inline void reset() noexcept { y = 0.0f; }
    /// `fc <= 0` disables. Designed at whatever rate the filter runs at.
    inline void design(double sr, double fc) noexcept {
        y = 0.0f;
        a = (fc > 0.0 && sr > 0.0)
            ? float(1.0 - std::exp(-2.0 * M_PI * fc / sr)) : 0.0f;
    }
};

/// One-pole high-pass (the coupling-cap / grid-leak form). `c = 0` → identity.
struct OnePoleHP {
    float c = 0.0f, x1 = 0.0f, y1 = 0.0f;
    inline float process(float x) noexcept {
        if (c == 0.0f) return x;
        const float y = c * (y1 + x - x1);
        x1 = x; y1 = y;
        return y;
    }
    inline void reset() noexcept { x1 = y1 = 0.0f; }
    inline void design(double sr, double fc) noexcept {
        x1 = y1 = 0.0f;
        c = (fc > 0.0 && sr > 0.0)
            ? float(std::exp(-2.0 * M_PI * fc / sr)) : 0.0f;
    }
};

/// First-order shelf that LIFTS everything above `fc` by `dB` and leaves
/// everything below it at unity — the cathode-bypass network, and the shape the
/// output transformer's damping is approximated with. `g == 1` → identity.
struct OnePoleShelf {
    OnePoleLP lp;
    float g = 1.0f;
    inline float process(float x) noexcept {
        if (g == 1.0f) return x;
        const float low = lp.process(x);
        return low + g * (x - low);
    }
    inline void reset() noexcept { lp.reset(); }
    inline void design(double sr, double fc, float dB) noexcept {
        if (fc <= 0.0 || dB == 0.0f) { g = 1.0f; lp.a = 0.0f; lp.y = 0.0f; return; }
        lp.design(sr, fc);
        g = std::pow(10.0f, dB / 20.0f);
    }
};

// MARK: - Waveshapers
//
// One family per `AmpClip`. Every one has UNIT SLOPE at the origin, which is
// what lets the power amp express headroom as `h · shape(x / h)` — below `h` the
// stage is transparent, above it it saturates.

/// Raw (biased) transfer curve. `shapeAmp` below removes the DC the bias adds.
inline float ampShapeRaw(float x, AmpClip clip, float asym) noexcept {
    const float b = x + asym;
    switch (clip) {
    case AmpClip::Clean:
        return b;
    case AmpClip::SolidState:
        // Hard clip — no even harmonics, no valve warmth. Exactly the point.
        return b < -1.0f ? -1.0f : (b > 1.0f ? 1.0f : b);
    case AmpClip::Pentode: {
        // Harder knee than a triode, saturating to ±1: x / (1 + x⁴)^¼. Two
        // cheap sqrts, no `pow`. This is the output-valve family (EL84 / EL34).
        const float b2 = b * b;
        return b / std::sqrt(std::sqrt(1.0f + b2 * b2));
    }
    case AmpClip::ClassAB: {
        // Push-pull: symmetric soft clip with a CROSSOVER KNEE — the gain dips
        // slightly as the signal passes through zero, because the two output
        // valves hand over there. Audible as a faint grainy edge on note decays,
        // which is what a real Class AB stage sounds like; present but not buzzy
        // is right (crossover width 0.03, dip 12%).
        const float ab = std::fabs(b);
        const float g  = 0.88f + 0.12f * (ab / (ab + 0.03f));
        return std::tanh(b * g);
    }
    case AmpClip::Triode:
    default:
        // Asymmetric soft clip: the bias adds even harmonics (tube-like) and
        // tanh bounds the output to ~±1.
        return std::tanh(b);
    }
}

/// DC-corrected shape. `offset` is `ampShapeRaw(0, clip, asym)`, precomputed on
/// the setup thread so the audio thread never re-evaluates it.
inline float ampShape(float x, AmpClip clip, float asym, float offset) noexcept {
    return ampShapeRaw(x, clip, asym) - offset;
}

// MARK: - AnalogAmp

class AnalogAmp {
public:
    static constexpr int kMaxChannels = 2;
    static constexpr int kOversample = 4;         // 4× around the clips.
    static constexpr int kFirTaps = 48;           // multiple of kOversample.
    static constexpr int kPhaseTaps = kFirTaps / kOversample;
    static constexpr int kMaxStages = AmpProfile::kMaxStages;

    /// Design the oversampling FIR for `sr`, allocate per-channel state and
    /// install `AmpVoicing::Legacy`. Setup thread.
    void prepare(double sampleRate, int numChannels);

    /// (Re)voice the preamp for one amp PROFILE — designs the input high-pass,
    /// the bright shelf, every stage's one-poles and the output low-pass, for
    /// every channel, and caches the per-stage clip constants. Setup thread only
    /// (call inside the reconfigure barrier). Mirrors `DrivePedal::configure`.
    /// Allocates nothing; the running oversampler state is left alone.
    void configure(const AmpProfile &profile) noexcept;

    /// Clear all filter / oversampler state. Real-time safe.
    void reset() noexcept;

    /// Process `n` samples in place for `channel`. `drive` is the linear pre-gain
    /// into the FIRST stage (higher = more distortion), multiplying on top of
    /// that stage's profile gain. Real-time safe.
    void process(float *buffer, int n, int channel, float drive) noexcept;

private:
    // Windowed-sinc anti-imaging / anti-aliasing FIR (shared across channels),
    // normalized to unity DC gain.
    float fir_[kFirTaps] = {};
    double sampleRate_ = 48000.0;
    double osRate_ = 192000.0;
    int numChannels_ = 1;
    bool ready_ = false;

    /// Per-stage constants resolved once by `configure` — read-only on the audio
    /// thread, so they live outside the per-channel state.
    struct StageConst {
        float   gain = 1.0f;
        float   asym = 0.0f;
        float   offset = 0.0f;        // ampShapeRaw(0, clip, asym)
        AmpClip clip = AmpClip::Triode;
        bool    bypassClip = false;   // AmpClip::Clean → the waveshaper is skipped
    };
    StageConst stageConst_[kMaxStages];
    int  stageCount_ = 1;
    bool hasInput_ = false;
    bool hasBright_ = false;
    bool hasOutLP_ = false;

    struct StageState {
        OnePoleHP    coupling;        // coupling cap × next grid leak
        OnePoleShelf cathode;         // cathode-bypass shelf
        OnePoleLP    miller;          // interstage Miller pole (last stage: unused)
    };

    struct ChannelState {
        Biquad input;                            // input tightening high-pass
        Biquad bright;                           // bright-cap high shelf
        Biquad outLP;                            // last stage's Miller pole (base rate)
        StageState stage[kMaxStages];
        float upHist[kPhaseTaps] = {};           // base-rate history for polyphase up
        int upPos = 0;
        float downHist[kFirTaps] = {};           // OS-rate history for decimation FIR
        int downPos = 0;
    };
    ChannelState ch_[kMaxChannels];
};

} // namespace streetrig

#endif /* STREETRIG_ANALOG_AMP_HPP */
