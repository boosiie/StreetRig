//
//  DrivePedal.cpp
//  StreetRig
//
//  Implementation of the oversampled overdrive/distortion/fuzz block. See
//  DrivePedal.hpp for the contract. The oversampler mirrors AnalogAmp's proven
//  polyphase up / windowed-sinc down design.
//

#include "DrivePedal.hpp"

#include <algorithm>
#include <cmath>

namespace streetrig {

void DrivePedal::prepare(double sampleRate, int numChannels) {
    sampleRate_ = sampleRate > 0 ? sampleRate : 48000.0;
    osRate_ = sampleRate_ * kOversample;
    numChannels_ = std::clamp(numChannels, 1, kMaxChannels);

    // Windowed-sinc anti-imaging / anti-aliasing FIR for the 4× oversampler.
    // Cutoff (cycles/sample at the OS rate) sits just below the base Nyquist
    // = 1/(2*kOversample) = 0.125; 0.11 leaves a transition band. Hann window,
    // normalized to unity DC gain.
    const double fc = 0.11;
    const int N = kFirTaps;
    const double center = (N - 1) / 2.0;
    double sum = 0.0;
    double taps[kFirTaps];
    for (int k = 0; k < N; ++k) {
        double m = k - center;
        double sinc = (m == 0.0) ? (2.0 * fc)
                                 : std::sin(2.0 * M_PI * fc * m) / (M_PI * m);
        double win = 0.5 - 0.5 * std::cos(2.0 * M_PI * k / (N - 1));   // Hann
        taps[k] = sinc * win;
        sum += taps[k];
    }
    for (int k = 0; k < N; ++k) fir_[k] = float(taps[k] / sum);        // unity DC

    // ~5 ms one-pole smoothing for drive / level de-zippering.
    smoothCoeff_ = std::exp(-1.0f / (0.005f * (float)sampleRate_));

    configure(character_);
    reset();
    ready_ = true;
}

void DrivePedal::configure(int character) noexcept {
    character_ = character;
    // Per-character voicing. Only the linear (non-aliasing) filters differ by
    // character; the clip shape itself is chosen in clip().
    double preHz = 90.0;      // input tightening high-pass
    double midHz = 0.0;       // 0 = no mid hump
    double midQ  = 0.7;
    double midDB = 0.0;
    switch (character) {
        case Hard:  preHz = 110.0; midHz = 0.0;                     break;  // RAT: tight, flat pre
        case Fuzz:  preHz = 70.0;  midHz = 0.0;                     break;  // Fuzz: let lows in
        case Soft:
        default:    preHz = 100.0; midHz = 720.0; midQ = 0.8; midDB = 6.0;  break; // TS mid hump
    }
    for (int c = 0; c < kMaxChannels; ++c) {
        ch_[c].pre = Biquad::highpass(sampleRate_, preHz, 0.707);
        ch_[c].mid = (midHz > 0.0) ? Biquad::peaking(sampleRate_, midHz, midQ, midDB)
                                   : Biquad{};   // identity (b0=1)
    }
}

void DrivePedal::reset() noexcept {
    for (int c = 0; c < kMaxChannels; ++c) {
        ch_[c].pre.reset();
        ch_[c].mid.reset();
        std::fill(ch_[c].upHist, ch_[c].upHist + kPhaseTaps, 0.0f);
        std::fill(ch_[c].downHist, ch_[c].downHist + kFirTaps, 0.0f);
        ch_[c].upPos = 0;
        ch_[c].downPos = 0;
        ch_[c].toneState = 0.0f;
        ch_[c].dcX1 = ch_[c].dcY1 = 0.0f;
    }
}

void DrivePedal::process(float *buffer, int n, int channel,
                         float drive, float toneCutHz, float level) noexcept {
    if (!ready_ || channel < 0 || channel >= numChannels_ || !buffer || n <= 0) return;
    auto &s = ch_[channel];
    if (drive < 0.0001f) drive = 0.0001f;

    // Post tone: one-pole low-pass, coefficient from the (buffer-constant) cutoff.
    double fc = std::clamp((double)toneCutHz, 300.0, sampleRate_ * 0.45);
    const float toneA = 1.0f - std::exp(-2.0f * (float)M_PI * (float)fc / (float)sampleRate_);
    // DC blocker pole (~20 Hz) — asymmetric clips add DC that must not stack up.
    const float dcR = 1.0f - (2.0f * (float)M_PI * 20.0f / (float)sampleRate_);

    float d = s.smDrive, lv = s.smLevel;
    for (int i = 0; i < n; ++i) {
        d  = drive + (d  - drive) * smoothCoeff_;
        lv = level + (lv - level) * smoothCoeff_;

        // 1. Voicing pre-filters (base rate, linear → no aliasing).
        float x = s.pre.process(buffer[i]);
        x = s.mid.process(x);

        // 2. Push into polyphase upsampler history (base rate).
        s.upHist[s.upPos] = x;

        // 3. Produce kOversample sub-samples, clip each, feed the decimator.
        for (int m = 0; m < kOversample; ++m) {
            float up = 0.0f;
            int idx = s.upPos;
            for (int j = 0; j < kPhaseTaps; ++j) {
                up += fir_[m + j * kOversample] * s.upHist[idx];
                idx = (idx == 0) ? (kPhaseTaps - 1) : (idx - 1);
            }
            up *= float(kOversample);                     // restore amplitude
            float shaped = clip(d * up, character_);       // clip at OS rate
            s.downHist[s.downPos] = shaped;
            s.downPos = (s.downPos + 1) % kFirTaps;
        }

        // 4. Decimation FIR over the OS history (once per base sample).
        float decimated = 0.0f;
        int idx = (s.downPos == 0) ? (kFirTaps - 1) : (s.downPos - 1);
        for (int k = 0; k < kFirTaps; ++k) {
            decimated += fir_[k] * s.downHist[idx];
            idx = (idx == 0) ? (kFirTaps - 1) : (idx - 1);
        }

        // 5. DC block (one-pole high-pass) then post tone low-pass, then level.
        float dc = decimated - s.dcX1 + dcR * s.dcY1;
        s.dcX1 = decimated; s.dcY1 = dc;
        s.toneState += toneA * (dc - s.toneState);
        buffer[i] = s.toneState * lv;

        s.upPos = (s.upPos + 1) % kPhaseTaps;
    }
    s.smDrive = d; s.smLevel = lv;
}

} // namespace streetrig
