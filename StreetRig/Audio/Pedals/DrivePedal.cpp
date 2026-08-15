//
//  DrivePedal.cpp
//  StreetRig
//
//  Implementation of the per-model overdrive/distortion/fuzz block. See
//  DrivePedal.hpp. The oversampler mirrors AnalogAmp's proven polyphase up /
//  windowed-sinc down design; per-model voicing lives in `voiceFor`.
//

#include "DrivePedal.hpp"

#include <algorithm>
#include <cmath>

namespace streetrig {

// Per-model voice table. Values are a documented first pass grounded in the circuit
// analyses (see research/pedal-tone-reference.md); final feel needs on-device
// ear-tuning with a real iRig.
DrivePedal::Voice DrivePedal::voiceFor(int voicing) noexcept {
    Voice v;
    switch (voicing) {
        case TubeScreamer:   // soft clip + signature ~720 Hz mid hump, tight lows
            v = {100.0, 720.0, 0.8, 6.0,  0,0,0, Soft, 0.15f, 1.00f, 1.00f, false}; break;
        case Bluesbreaker:   // transparent, open, low-gain
            v = { 80.0,   0,0,0,          0,0,0, Soft, 0.05f, 0.70f, 1.10f, false}; break;
        case Klon:           // "transparent" + treble tilt, high headroom (low drive)
            v = { 95.0, 2000.0, 0.7, 3.0, 0,0,0, Soft, 0.10f, 0.60f, 1.15f, false}; break;
        case KingOfTone:     // Bluesbreaker-derived, fuller mids
            v = { 85.0, 500.0, 0.8, 3.0,  0,0,0, Soft, 0.10f, 0.90f, 1.05f, false}; break;
        case OCD:            // MOSFET, amp-like, brighter, gainier, asymmetric
            v = { 90.0, 2500.0, 0.7, 2.0, 0,0,0, Hard, 0.20f, 1.15f, 0.95f, false}; break;
        case DS1:            // hard asymmetric, mid-forward, buzzy
            v = {110.0, 800.0, 0.7, 2.0,  0,0,0, Hard, 0.25f, 1.00f, 0.95f, false}; break;
        case MetalZone:      // very high gain, deep mid scoop, bright
            v = {120.0,   0,0,0, 500.0, 1.2, -12.0, Hard, 0.10f, 1.60f, 0.75f, false}; break;
        case RAT:            // LM308 hard symmetric, bright, aggressive
            v = {100.0, 3000.0, 0.7, 3.0, 0,0,0, Hard, 0.00f, 1.30f, 0.85f, false}; break;
        case BigMuff:        // two cascaded soft stages + mid scoop, thick sustain
            v = { 70.0,   0,0,0, 1000.0, 0.8, -8.0, Soft, 0.05f, 1.40f, 0.60f, true};  break;
        case FuzzFace:       // round asymmetric germanium fuzz, full lows, dynamic
            v = { 60.0,   0,0,0,          0,0,0, Fuzz, 0.30f, 0.90f, 0.90f, false}; break;
        case FuzzFactory:    // extreme-asymmetry gated/sputtery fuzz
            v = { 80.0,   0,0,0,          0,0,0, Fuzz, 0.60f, 1.20f, 0.75f, false}; break;
        case CleanBoost:     // clean/treble boost — mostly clean, sparkle
            v = { 80.0, 3000.0, 0.7, 3.0, 0,0,0, Soft, 0.00f, 0.40f, 1.20f, false}; break;
        case GenericHard:
            v = {110.0,   0,0,0,          0,0,0, Hard, 0.00f, 1.00f, 1.00f, false}; break;
        case GenericFuzz:
            v = { 70.0,   0,0,0,          0,0,0, Fuzz, 0.00f, 1.00f, 1.00f, false}; break;
        case GenericSoft:
        default:
            v = {100.0,   0,0,0,          0,0,0, Soft, 0.15f, 1.00f, 1.00f, false}; break;
    }
    return v;
}

void DrivePedal::prepare(double sampleRate, int numChannels) {
    sampleRate_ = sampleRate > 0 ? sampleRate : 48000.0;
    osRate_ = sampleRate_ * kOversample;
    numChannels_ = std::clamp(numChannels, 1, kMaxChannels);

    // Windowed-sinc anti-imaging / anti-aliasing FIR for the 4× oversampler. Cutoff
    // (cycles/sample at OS rate) just below base Nyquist = 1/(2*kOversample)=0.125;
    // 0.11 leaves a transition band. Hann window, normalized to unity DC gain.
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

    smoothCoeff_ = std::exp(-1.0f / (0.005f * (float)sampleRate_));    // ~5 ms de-zip

    configure(voicing_);
    reset();
    ready_ = true;
}

void DrivePedal::configure(int voicing) noexcept {
    voicing_ = voicing;
    v_ = voiceFor(voicing);
    for (int c = 0; c < kMaxChannels; ++c) {
        ch_[c].pre = Biquad::highpass(sampleRate_, v_.preHz, 0.707);
        ch_[c].preMid = (v_.preMidDB != 0.0)
            ? Biquad::peaking(sampleRate_, v_.preMidHz, v_.preMidQ, v_.preMidDB) : Biquad{};
        ch_[c].postMid = (v_.postMidDB != 0.0)
            ? Biquad::peaking(sampleRate_, v_.postMidHz, v_.postMidQ, v_.postMidDB) : Biquad{};
    }
}

void DrivePedal::reset() noexcept {
    for (int c = 0; c < kMaxChannels; ++c) {
        ch_[c].pre.reset();
        ch_[c].preMid.reset();
        ch_[c].postMid.reset();
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

    double fc = std::clamp((double)toneCutHz, 300.0, sampleRate_ * 0.45);
    const float toneA = 1.0f - std::exp(-2.0f * (float)M_PI * (float)fc / (float)sampleRate_);
    const float dcR = 1.0f - (2.0f * (float)M_PI * 20.0f / (float)sampleRate_);

    const int   clipMode = v_.clip;
    const float asym = v_.asym;
    const float dScale = v_.driveScale;
    const float trim = v_.outTrim;
    const bool  twoStage = v_.twoStage;

    float d = s.smDrive, lv = s.smLevel;
    for (int i = 0; i < n; ++i) {
        d  = drive + (d  - drive) * smoothCoeff_;
        lv = level + (lv - level) * smoothCoeff_;

        // 1. Voicing pre-filters (base rate, linear → no aliasing).
        float x = s.pre.process(buffer[i]);
        x = s.preMid.process(x);

        // 2. Push into polyphase upsampler history (base rate).
        s.upHist[s.upPos] = x;

        // 3. Produce kOversample sub-samples, clip each (per-model shape + optional
        //    2-stage cascade), feed the decimator.
        for (int m = 0; m < kOversample; ++m) {
            float up = 0.0f;
            int idx = s.upPos;
            for (int j = 0; j < kPhaseTaps; ++j) {
                up += fir_[m + j * kOversample] * s.upHist[idx];
                idx = (idx == 0) ? (kPhaseTaps - 1) : (idx - 1);
            }
            up *= float(kOversample);
            float shaped = shape(d * dScale * up, clipMode, asym);
            if (twoStage) shaped = shape(2.0f * shaped, clipMode, asym);  // Muff cascade
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

        // 5. Post-clip mid scoop (Muff / Metal Zone), DC block, tone low-pass, level.
        float post = s.postMid.process(decimated);
        float dc = post - s.dcX1 + dcR * s.dcY1;
        s.dcX1 = post; s.dcY1 = dc;
        s.toneState += toneA * (dc - s.toneState);
        buffer[i] = s.toneState * lv * trim;

        s.upPos = (s.upPos + 1) % kPhaseTaps;
    }
    s.smDrive = d; s.smLevel = lv;
}

} // namespace streetrig
