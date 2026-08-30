//
//  EqPedal.hpp
//  StreetRig
//
//  A 3-band tone-shaping EQ pedal (the .eq category: GE-7 / Parametric EQ / 10-band).
//  This is the EASIEST family to make faithful — an EQ pedal IS a bank of
//  filters, so a cascade of RBJ biquads reproduces its frequency response
//  essentially exactly. This first pass exposes the three knobs the UI already
//  has (Low / Mid / High); a true 7- or 10-band graphic is the same idea with
//  more bands (a documented follow-up that needs a wider param layout).
//
//  Signal: low shelf (≈100 Hz) → mid peak (≈800 Hz) → high shelf (≈3.2 kHz),
//  each ±12 dB, FLAT (unity) at noon so a centered EQ is transparent.
//
//  REAL-TIME CONTRACT: `prepare()` allocates per-channel filter state (setup
//  thread). `process()` recomputes coefficients from the (buffer-constant) band
//  gains WITHOUT touching the running filter memory — same trick the amp
//  ToneStack uses — so a knob move is smooth and click-free. No alloc/lock/IO.
//

#ifndef STREETRIG_EQ_PEDAL_HPP
#define STREETRIG_EQ_PEDAL_HPP

#include <algorithm>
#include "../AnalogAmp.hpp"   // streetrig::Biquad

namespace streetrig {

class EqPedal {
public:
    static constexpr int kMaxChannels = 2;

    void prepare(double sampleRate, int numChannels);
    void configure(int /*voicing*/) noexcept {}   // no sub-voicings yet
    void reset() noexcept;

    /// params: [0] low dB, [1] mid dB, [2] high dB (0 = flat).
    void process(float *buffer, int n, int channel, const float *params) noexcept;

private:
    double sampleRate_ = 48000.0;
    int    numChannels_ = 1;
    bool   ready_ = false;

    // Fixed band centres (Hz). A graphic EQ would fan these out to 7–10 bands.
    static constexpr double kLowHz  = 100.0;
    static constexpr double kMidHz  = 800.0;
    static constexpr double kHighHz = 3200.0;

    struct ChannelState { Biquad low, mid, high; };
    ChannelState ch_[kMaxChannels];
};

} // namespace streetrig

#endif /* STREETRIG_EQ_PEDAL_HPP */
