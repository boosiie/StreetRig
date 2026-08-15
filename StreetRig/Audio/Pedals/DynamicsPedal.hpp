//
//  DynamicsPedal.hpp
//  StreetRig
//
//  The dynamics family — a COMPRESSOR (.compressor: Dyna Comp / CS-3 / Keeley)
//  and a NOISE GATE / downward expander (.noiseGate: NS-2 / Zuul / Decimator).
//  Both are the same machine — an envelope follower driving a gain — so one
//  block serves both, switched by `mode` at configure time. The slot picks the
//  mode from its Type (Compressor vs Gate), so a single preallocated instance
//  per slot covers whichever the user drops in.
//
//  COMPRESSOR: feed-forward, peak-detected, program-dependent. Fast attack,
//  medium release (Dyna-Comp-ish limiter feel). Sustain lowers the threshold and
//  raises the ratio; a gentle auto-makeup + the Level knob restore volume.
//  GATE: below threshold the gain falls to silence with a fast attack (opens
//  instantly) and a knob-set release ("Decay"); above it, unity. Kills hiss/hum
//  and amp-fizz tails without chopping sustained notes.
//
//  REAL-TIME CONTRACT: `prepare()` designs the attack/release coefficients
//  (setup thread). `process()` is per-channel, allocation/lock/IO-free, and
//  de-zippers the gain so it never clicks. See RealtimeSafety.md.
//

#ifndef STREETRIG_DYNAMICS_PEDAL_HPP
#define STREETRIG_DYNAMICS_PEDAL_HPP

#include <algorithm>

namespace streetrig {

class DynamicsPedal {
public:
    static constexpr int kMaxChannels = 2;
    enum Mode : int { Compressor = 0, Gate = 1 };

    void prepare(double sampleRate, int numChannels);
    /// `mode` = Compressor or Gate (chosen from the slot's Type).
    void configure(int mode) noexcept { mode_ = (mode == Gate) ? Gate : Compressor; }
    void reset() noexcept;

    /// Compressor params: [0] sustain 0..1, [1] makeup (linear).
    /// Gate params:       [0] threshold dBFS (≈ -70..-20), [1] release seconds.
    void process(float *buffer, int n, int channel, const float *params) noexcept;

private:
    double sampleRate_ = 48000.0;
    int    numChannels_ = 1;
    int    mode_ = Compressor;
    bool   ready_ = false;

    // Envelope + gain smoothing coefficients (one-pole, per-sample).
    float compAtkCoeff_ = 0.0f, compRelCoeff_ = 0.0f;   // detector ballistics (comp)
    float gateAtkCoeff_ = 0.0f;                          // gate opens fast
    float gainSmoothCoeff_ = 0.0f;                       // gain de-zipper

    struct ChannelState {
        float env  = 0.0f;   // detector state (linear)
        float gain = 1.0f;   // smoothed applied gain
    };
    ChannelState ch_[kMaxChannels];

    void processCompressor(float *buffer, int n, ChannelState &s,
                           float sustain, float makeup) noexcept;
    void processGate(float *buffer, int n, ChannelState &s,
                     float thresholdDB, float releaseSec) noexcept;
};

} // namespace streetrig

#endif /* STREETRIG_DYNAMICS_PEDAL_HPP */
