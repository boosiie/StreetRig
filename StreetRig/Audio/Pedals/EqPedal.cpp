//
//  EqPedal.cpp
//  StreetRig
//
//  Implementation of the 3-band EQ pedal. See EqPedal.hpp.
//

#include "EqPedal.hpp"

namespace streetrig {

void EqPedal::prepare(double sampleRate, int numChannels) {
    sampleRate_ = sampleRate > 0 ? sampleRate : 48000.0;
    numChannels_ = std::clamp(numChannels, 1, kMaxChannels);
    reset();
    ready_ = true;
}

void EqPedal::reset() noexcept {
    for (auto &c : ch_) { c.low.reset(); c.mid.reset(); c.high.reset(); }
}

void EqPedal::process(float *buffer, int n, int channel, const float *params) noexcept {
    if (!ready_ || !buffer || n <= 0 || channel < 0 || channel >= numChannels_ || !params) return;

    const double lowDB  = params[0];
    const double midDB  = params[1];
    const double highDB = params[2];

    // Recompute coefficients from the buffer-constant gains, preserving the
    // per-channel filter memory (setCoeffs, not a fresh Biquad) so the state
    // stays continuous across the update — no zipper on a knob turn.
    const Biquad l = Biquad::lowShelf (sampleRate_, kLowHz,  0.707, lowDB);
    const Biquad m = Biquad::peaking  (sampleRate_, kMidHz,  0.9,   midDB);
    const Biquad h = Biquad::highShelf(sampleRate_, kHighHz, 0.707, highDB);

    ChannelState &s = ch_[channel];
    s.low .setCoeffs(l.b0, l.b1, l.b2, l.a1, l.a2);
    s.mid .setCoeffs(m.b0, m.b1, m.b2, m.a1, m.a2);
    s.high.setCoeffs(h.b0, h.b1, h.b2, h.a1, h.a2);

    for (int i = 0; i < n; ++i) {
        float x = buffer[i];
        x = s.low.process(x);
        x = s.mid.process(x);
        x = s.high.process(x);
        buffer[i] = x;
    }
}

} // namespace streetrig
