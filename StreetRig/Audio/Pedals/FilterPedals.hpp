//
//  FilterPedals.hpp
//  StreetRig
//
//  Two small, expression-controlled pedals that are really just a filter and a
//  gain:
//
//    • WahPedal (.wah: Cry Baby / V847 / Bad Horsie) — a resonant peak that the
//      treadle ("Position") sweeps. The Cry Baby is a bandpass boosting ~+18 dB
//      at a peak that sweeps ~450 Hz→1.6 kHz; a single high-Q peaking biquad with
//      a swept centre reproduces the classic vocal "wah".
//
//    • VolumePedal (.volume: VP JR / FV-500H) — a smoothed, treadle-controlled
//      gain with an audio (square-law) taper.
//
//  Both are driven by the "Position" knob today; a real expression pedal / auto-
//  wah envelope is a later refinement (the DSP is identical — only what moves the
//  Position changes).
//
//  REAL-TIME CONTRACT: `prepare()` sets up per-channel state (setup thread).
//  `process()` is allocation/lock/IO-free; the wah recomputes its biquad from the
//  buffer-constant Position without disturbing filter memory, and the volume
//  de-zippers its gain. See RealtimeSafety.md.
//

#ifndef STREETRIG_FILTER_PEDALS_HPP
#define STREETRIG_FILTER_PEDALS_HPP

#include <algorithm>
#include "../AnalogAmp.hpp"   // streetrig::Biquad

namespace streetrig {

class WahPedal {
public:
    static constexpr int kMaxChannels = 2;

    void prepare(double sampleRate, int numChannels);
    void configure(int /*voicing*/) noexcept {}
    void reset() noexcept;

    /// params: [0] position 0..1 (heel → toe).
    void process(float *buffer, int n, int channel, const float *params) noexcept;

private:
    double sampleRate_ = 48000.0;
    int    numChannels_ = 1;
    bool   ready_ = false;
    struct ChannelState { Biquad peak; };
    ChannelState ch_[kMaxChannels];
};

class VolumePedal {
public:
    static constexpr int kMaxChannels = 2;

    void prepare(double sampleRate, int numChannels);
    void configure(int /*voicing*/) noexcept {}
    void reset() noexcept;

    /// params: [0] position 0..1 (heel = silent → toe = unity).
    void process(float *buffer, int n, int channel, const float *params) noexcept;

private:
    double sampleRate_ = 48000.0;
    int    numChannels_ = 1;
    bool   ready_ = false;
    float  smoothCoeff_ = 0.0f;
    float  gain_[kMaxChannels] = {};
};

} // namespace streetrig

#endif /* STREETRIG_FILTER_PEDALS_HPP */
