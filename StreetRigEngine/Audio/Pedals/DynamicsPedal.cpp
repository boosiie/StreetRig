//
//  DynamicsPedal.cpp
//  StreetRig
//
//  Implementation of the compressor / noise-gate block. See DynamicsPedal.hpp.
//

#include "DynamicsPedal.hpp"

#include <cmath>

namespace streetrig {

// One-pole smoothing coefficient for a time constant `tSec`: the per-sample
// factor the old value is multiplied by (env = c*env + (1-c)*target).
static inline float onePole(double tSec, double sr) noexcept {
    if (tSec <= 0.0) return 0.0f;
    return (float)std::exp(-1.0 / (tSec * sr));
}

void DynamicsPedal::prepare(double sampleRate, int numChannels) {
    sampleRate_ = sampleRate > 0 ? sampleRate : 48000.0;
    numChannels_ = std::clamp(numChannels, 1, kMaxChannels);

    // Compressor ballistics: fast attack (~5 ms, Damper-Comp-like), medium release
    // (~180 ms). Gate opens near-instantly (~1 ms); its release is knob-set.
    compAtkCoeff_    = onePole(0.005, sampleRate_);
    compRelCoeff_    = onePole(0.180, sampleRate_);
    gateAtkCoeff_    = onePole(0.001, sampleRate_);
    gainSmoothCoeff_ = onePole(0.005, sampleRate_);   // ~5 ms gain de-zipper

    reset();
    ready_ = true;
}

void DynamicsPedal::reset() noexcept {
    for (auto &c : ch_) { c.env = 0.0f; c.gain = 1.0f; }
}

void DynamicsPedal::process(float *buffer, int n, int channel, const float *params) noexcept {
    if (!ready_ || !buffer || n <= 0 || channel < 0 || channel >= numChannels_ || !params) return;
    ChannelState &s = ch_[channel];
    if (mode_ == Gate) processGate(buffer, n, s, params[0], params[1]);
    else               processCompressor(buffer, n, s, params[0], params[1]);
}

void DynamicsPedal::processCompressor(float *buffer, int n, ChannelState &s,
                                      float sustain, float makeup) noexcept {
    sustain = std::clamp(sustain, 0.0f, 1.0f);

    // More sustain → lower threshold + higher ratio (squashes harder, sustains
    // longer). A gentle auto-makeup lifts the compressed signal; the Level knob
    // (`makeup`) is the final trim.
    const float thresholdDB = -12.0f - sustain * 28.0f;   // -12 .. -40 dBFS
    const float ratio       = 2.0f + sustain * 6.0f;      //   2:1 .. 8:1
    const float autoMakeup  = 1.0f + sustain * 1.0f;      // up to +6 dB
    const float slope       = 1.0f - 1.0f / ratio;        // dB of GR per dB over
    const float outGain     = makeup * autoMakeup;

    for (int i = 0; i < n; ++i) {
        const float x = buffer[i];
        const float rect = std::fabs(x);

        // Peak detector with attack/release ballistics.
        const float coeff = (rect > s.env) ? compAtkCoeff_ : compRelCoeff_;
        s.env = coeff * s.env + (1.0f - coeff) * rect;

        // Gain computer in dB (hard knee): reduce everything above threshold.
        const float envDB = 20.0f * std::log10(s.env + 1.0e-6f);
        const float overDB = envDB - thresholdDB;
        const float grDB = (overDB > 0.0f) ? (-overDB * slope) : 0.0f;   // ≤ 0
        const float targetGain = std::pow(10.0f, grDB / 20.0f);

        // De-zipper the gain, then apply + makeup.
        s.gain = gainSmoothCoeff_ * s.gain + (1.0f - gainSmoothCoeff_) * targetGain;
        buffer[i] = x * s.gain * outGain;
    }
}

void DynamicsPedal::processGate(float *buffer, int n, ChannelState &s,
                                float thresholdDB, float releaseSec) noexcept {
    const float threshLin = std::pow(10.0f, thresholdDB / 20.0f);
    // Small hysteresis window so the gate doesn't chatter right at the threshold.
    const float openLin  = threshLin;
    const float closeLin = threshLin * 0.5f;
    const float relCoeff = onePole(std::max(0.01f, releaseSec), sampleRate_);

    for (int i = 0; i < n; ++i) {
        const float x = buffer[i];
        const float rect = std::fabs(x);

        // Fast-attack / release-set peak detector.
        const float coeff = (rect > s.env) ? gateAtkCoeff_ : relCoeff;
        s.env = coeff * s.env + (1.0f - coeff) * rect;

        // Target 1 above open, 0 below close, hold in between (hysteresis).
        float target = s.gain >= 0.5f ? 1.0f : 0.0f;
        if (s.env >= openLin)  target = 1.0f;
        if (s.env <  closeLin) target = 0.0f;

        // Open fast, close at the knob-set release rate.
        const float gCoeff = (target > s.gain) ? gateAtkCoeff_ : relCoeff;
        s.gain = gCoeff * s.gain + (1.0f - gCoeff) * target;
        buffer[i] = x * s.gain;
    }
}

} // namespace streetrig
