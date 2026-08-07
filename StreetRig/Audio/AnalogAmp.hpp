//
//  AnalogAmp.hpp
//  StreetRig
//
//  GRACEFUL-DEGRADATION amp: a lightweight, always-available analog-style amp
//  stage used when no neural capture is bundled (or when the user selects it).
//  It is a fixed-voicing preamp: input tightening high-pass → 4× OVERSAMPLED
//  asymmetric soft-clip waveshaper (tube-ish, adds even+odd harmonics) → warmth
//  low-pass. It is NOT a specific amp model — it is a good-sounding fallback so
//  StreetRig always makes amp-like tone with zero assets. Drop a real GuitarML /
//  RTNeural capture in and the neural path takes over (see NeuralAmpModel).
//
//  WHY oversample the waveshaper (requirement 6): a static nonlinearity generates
//  harmonics above Nyquist that fold back as inharmonic "digital fizz". Running
//  the clip at 4× with band-limiting FIRs on the way up and down pushes those
//  images out of band before decimation removes them. The linear voicing biquads
//  do not alias, so only the clip is oversampled.
//
//  REAL-TIME CONTRACT: `prepare()` designs the FIR + biquads and allocates all
//  state (setup thread). `process()` is allocation/lock/IO-free. Per-channel
//  state means a stereo path never cross-contaminates. See RealtimeSafety.md.
//

#ifndef STREETRIG_ANALOG_AMP_HPP
#define STREETRIG_ANALOG_AMP_HPP

#include <vector>
#include <cmath>

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

class AnalogAmp {
public:
    static constexpr int kMaxChannels = 2;
    static constexpr int kOversample = 4;         // 4× around the clip.
    static constexpr int kFirTaps = 48;           // multiple of kOversample.
    static constexpr int kPhaseTaps = kFirTaps / kOversample;

    /// Design filters for `sr` and allocate per-channel state. Setup thread.
    void prepare(double sampleRate, int numChannels);

    /// Clear all filter / oversampler state. Real-time safe.
    void reset() noexcept;

    /// Process `n` samples in place for `channel`. `drive` is the linear pre-gain
    /// into the soft clip (higher = more distortion). Real-time safe.
    void process(float *buffer, int n, int channel, float drive) noexcept;

private:
    // Windowed-sinc anti-imaging / anti-aliasing FIR (shared across channels),
    // normalized to unity DC gain.
    float fir_[kFirTaps] = {};
    double sampleRate_ = 48000.0;
    int numChannels_ = 1;
    bool ready_ = false;

    struct ChannelState {
        Biquad pre;                              // tightening high-pass
        Biquad post;                             // warmth low-pass
        float upHist[kPhaseTaps] = {};           // base-rate history for polyphase up
        int upPos = 0;
        float downHist[kFirTaps] = {};           // OS-rate history for decimation FIR
        int downPos = 0;
    };
    ChannelState ch_[kMaxChannels];

    static inline float shape(float x) noexcept {
        // Asymmetric soft clip: bias adds even harmonics (tube-like); subtracting
        // tanh(bias) keeps the DC offset out. tanh bounds the output to ~±1.
        constexpr float bias = 0.12f;
        return std::tanh(x + bias) - std::tanh(bias);
    }
};

} // namespace streetrig

#endif /* STREETRIG_ANALOG_AMP_HPP */
