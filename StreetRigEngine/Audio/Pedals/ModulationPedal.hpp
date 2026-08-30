//
//  ModulationPedal.hpp
//  StreetRig
//
//  The modulation family (.modulation) — ONE engine, five voicings, because they
//  are all an LFO moving a filter or a short delay:
//
//    • Tremolo  (TR-2)                — LFO on AMPLITUDE.
//    • Phaser   (Swirl72, SmallSlate) — LFO on a cascade of first-order ALL-PASS
//                                          filters; dry+wet sum → sweeping notches.
//    • Univibe  (Lucid'Vibe)          — like a phaser but with STAGGERED all-pass
//                                          stages + a touch of amplitude throb.
//    • Chorus   (CE-2, SmallMime)  — LFO on a ~15 ms modulated DELAY, low
//                                          feedback → detuned shimmer.
//    • Flanger  (M117R, El. Siren)— LFO on a ~2 ms modulated delay + feedback
//                                          → moving harmonic notches ("jet").
//
//  Chorus/flanger need a short delay line; phaser/univibe need all-pass state;
//  tremolo needs neither. All are preallocated per slot (a few KB) so a slot can
//  become any voicing with zero audio-thread allocation.
//
//  REAL-TIME CONTRACT: `prepare()` clears the (fixed-size) delay + all-pass state
//  (setup thread). `process()` is per-channel and allocation/lock/IO-free; the
//  LFO phase is per-channel so a stereo path never crosstalks. See RealtimeSafety.md.
//

#ifndef STREETRIG_MODULATION_PEDAL_HPP
#define STREETRIG_MODULATION_PEDAL_HPP

#include <algorithm>

namespace streetrig {

class ModulationPedal {
public:
    static constexpr int kMaxChannels = 2;
    static constexpr int kMaxAllpass  = 12;     // phaser 6, univibe 6, deep phaser 12
    static constexpr int kDelayMax    = 4096;   // ~85 ms @48k — covers chorus

    enum Voicing : int { Chorus = 0, Flanger = 1, Phaser = 2, Tremolo = 3, Univibe = 4,
                         /// Twelve stages instead of four and much more resonance —
                         /// the difference between "there is a phaser somewhere"
                         /// and a sweep you can follow.
                         DeepPhaser = 5 };

    void prepare(double sampleRate, int numChannels);
    void configure(int voicing) noexcept { voicing_ = std::clamp(voicing, 0, (int)DeepPhaser); }
    void reset() noexcept;

    /// params: [0] rate Hz, [1] depth 0..1, [2] mix 0..1.
    void process(float *buffer, int n, int channel, const float *params) noexcept;

private:
    double sampleRate_ = 48000.0;
    int    numChannels_ = 1;
    int    voicing_ = Chorus;
    bool   ready_ = false;

    float lfoPhase_[kMaxChannels] = {};         // radians, per channel

    struct ChannelState {
        float delay[kDelayMax] = {};
        int   writePos = 0;
        float apX[kMaxAllpass] = {};            // all-pass x[n-1] per stage
        float apY[kMaxAllpass] = {};            // all-pass y[n-1] per stage
    };
    ChannelState ch_[kMaxChannels];

    inline float readDelay(ChannelState &s, float delaySamples) const noexcept {
        float readPos = (float)s.writePos - delaySamples;
        while (readPos < 0.0f) readPos += (float)kDelayMax;
        int i0 = (int)readPos;
        float frac = readPos - (float)i0;
        int i1 = i0 + 1; if (i1 >= kDelayMax) i1 = 0;
        return s.delay[i0] * (1.0f - frac) + s.delay[i1] * frac;
    }
};

} // namespace streetrig

#endif /* STREETRIG_MODULATION_PEDAL_HPP */
