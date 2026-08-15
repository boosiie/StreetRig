//
//  FilterPedals.cpp
//  StreetRig
//
//  Implementation of the wah + volume pedals. See FilterPedals.hpp.
//

#include "FilterPedals.hpp"

#include <cmath>

namespace streetrig {

// MARK: - WahPedal

void WahPedal::prepare(double sampleRate, int numChannels) {
    sampleRate_ = sampleRate > 0 ? sampleRate : 48000.0;
    numChannels_ = std::clamp(numChannels, 1, kMaxChannels);
    reset();
    ready_ = true;
}

void WahPedal::reset() noexcept {
    for (auto &c : ch_) c.peak.reset();
}

void WahPedal::process(float *buffer, int n, int channel, const float *params) noexcept {
    if (!ready_ || !buffer || n <= 0 || channel < 0 || channel >= numChannels_ || !params) return;

    const float pos = std::clamp(params[0], 0.0f, 1.0f);
    // Sweep the resonant peak ~450 Hz → ~1.6 kHz (log), the Cry Baby's range.
    const double fc = 450.0 * std::pow(3.5, (double)pos);
    // High-Q peaking with a big boost is the classic wah voicing (~+16 dB, Q≈2.5).
    const Biquad p = Biquad::peaking(sampleRate_, fc, 2.5, 16.0);

    ChannelState &s = ch_[channel];
    s.peak.setCoeffs(p.b0, p.b1, p.b2, p.a1, p.a2);
    for (int i = 0; i < n; ++i) buffer[i] = s.peak.process(buffer[i]);
}

// MARK: - VolumePedal

void VolumePedal::prepare(double sampleRate, int numChannels) {
    sampleRate_ = sampleRate > 0 ? sampleRate : 48000.0;
    numChannels_ = std::clamp(numChannels, 1, kMaxChannels);
    smoothCoeff_ = std::exp(-1.0f / (0.01f * (float)sampleRate_));   // ~10 ms de-zipper
    reset();
    ready_ = true;
}

void VolumePedal::reset() noexcept {
    for (auto &g : gain_) g = 1.0f;
}

void VolumePedal::process(float *buffer, int n, int channel, const float *params) noexcept {
    if (!ready_ || !buffer || n <= 0 || channel < 0 || channel >= numChannels_ || !params) return;

    const float pos = std::clamp(params[0], 0.0f, 1.0f);
    const float target = pos * pos;      // square-law (audio taper)
    float g = gain_[channel];
    for (int i = 0; i < n; ++i) {
        g = target + (g - target) * smoothCoeff_;
        buffer[i] *= g;
    }
    gain_[channel] = g;
}

} // namespace streetrig
