//
//  AnalogAmp.cpp
//  StreetRig
//
//  Implementation of the fallback analog amp. See AnalogAmp.hpp for the contract.
//

#include "AnalogAmp.hpp"

#include <algorithm>

namespace streetrig {

Biquad Biquad::highpass(double sr, double fc, double q) {
    const double w0 = 2.0 * M_PI * fc / sr;
    const double cw = std::cos(w0), sw = std::sin(w0);
    const double alpha = sw / (2.0 * q);
    const double a0 = 1.0 + alpha;
    Biquad b;
    b.b0 = float((1.0 + cw) / 2.0 / a0);
    b.b1 = float(-(1.0 + cw) / a0);
    b.b2 = float((1.0 + cw) / 2.0 / a0);
    b.a1 = float((-2.0 * cw) / a0);
    b.a2 = float((1.0 - alpha) / a0);
    return b;
}

Biquad Biquad::lowpass(double sr, double fc, double q) {
    const double w0 = 2.0 * M_PI * fc / sr;
    const double cw = std::cos(w0), sw = std::sin(w0);
    const double alpha = sw / (2.0 * q);
    const double a0 = 1.0 + alpha;
    Biquad b;
    b.b0 = float((1.0 - cw) / 2.0 / a0);
    b.b1 = float((1.0 - cw) / a0);
    b.b2 = float((1.0 - cw) / 2.0 / a0);
    b.a1 = float((-2.0 * cw) / a0);
    b.a2 = float((1.0 - alpha) / a0);
    return b;
}

// RBJ audio-EQ-cookbook shelving / peaking designs, normalized to a0 = 1. Used
// by the amp tone stack (Bass low-shelf, Mid peak, Treble/Presence high-shelf).
Biquad Biquad::lowShelf(double sr, double fc, double q, double gainDB) {
    const double A = std::pow(10.0, gainDB / 40.0);
    const double w0 = 2.0 * M_PI * fc / sr;
    const double cw = std::cos(w0), sw = std::sin(w0);
    const double alpha = sw / (2.0 * q);
    const double tsa = 2.0 * std::sqrt(A) * alpha;
    const double a0 = (A + 1.0) + (A - 1.0) * cw + tsa;
    Biquad b;
    b.b0 = float(A * ((A + 1.0) - (A - 1.0) * cw + tsa) / a0);
    b.b1 = float(2.0 * A * ((A - 1.0) - (A + 1.0) * cw) / a0);
    b.b2 = float(A * ((A + 1.0) - (A - 1.0) * cw - tsa) / a0);
    b.a1 = float(-2.0 * ((A - 1.0) + (A + 1.0) * cw) / a0);
    b.a2 = float(((A + 1.0) + (A - 1.0) * cw - tsa) / a0);
    return b;
}

Biquad Biquad::highShelf(double sr, double fc, double q, double gainDB) {
    const double A = std::pow(10.0, gainDB / 40.0);
    const double w0 = 2.0 * M_PI * fc / sr;
    const double cw = std::cos(w0), sw = std::sin(w0);
    const double alpha = sw / (2.0 * q);
    const double tsa = 2.0 * std::sqrt(A) * alpha;
    const double a0 = (A + 1.0) - (A - 1.0) * cw + tsa;
    Biquad b;
    b.b0 = float(A * ((A + 1.0) + (A - 1.0) * cw + tsa) / a0);
    b.b1 = float(-2.0 * A * ((A - 1.0) + (A + 1.0) * cw) / a0);
    b.b2 = float(A * ((A + 1.0) + (A - 1.0) * cw - tsa) / a0);
    b.a1 = float(2.0 * ((A - 1.0) - (A + 1.0) * cw) / a0);
    b.a2 = float(((A + 1.0) - (A - 1.0) * cw - tsa) / a0);
    return b;
}

Biquad Biquad::peaking(double sr, double fc, double q, double gainDB) {
    const double A = std::pow(10.0, gainDB / 40.0);
    const double w0 = 2.0 * M_PI * fc / sr;
    const double cw = std::cos(w0), sw = std::sin(w0);
    const double alpha = sw / (2.0 * q);
    const double a0 = 1.0 + alpha / A;
    Biquad b;
    b.b0 = float((1.0 + alpha * A) / a0);
    b.b1 = float((-2.0 * cw) / a0);
    b.b2 = float((1.0 - alpha * A) / a0);
    b.a1 = float((-2.0 * cw) / a0);
    b.a2 = float((1.0 - alpha / A) / a0);
    return b;
}

void AnalogAmp::prepare(double sampleRate, int numChannels) {
    sampleRate_ = sampleRate > 0 ? sampleRate : 48000.0;
    numChannels_ = std::clamp(numChannels, 1, kMaxChannels);

    // Windowed-sinc lowpass for 4× oversampling. Cutoff (cycles/sample at the OS
    // rate) sits just below the base Nyquist = 1/(2*kOversample) = 0.125; use 0.11
    // for a transition band. Hann window, normalized to unity DC gain.
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
    for (int k = 0; k < N; ++k) fir_[k] = float(taps[k] / sum);   // unity DC

    for (int c = 0; c < kMaxChannels; ++c) {
        ch_[c].pre  = Biquad::highpass(sampleRate_, 95.0, 0.707);   // tighten lows
        ch_[c].post = Biquad::lowpass(sampleRate_, 8000.0, 0.707);  // tame fizz (cab does the rest)
    }
    reset();
    ready_ = true;
}

void AnalogAmp::reset() noexcept {
    for (int c = 0; c < kMaxChannels; ++c) {
        ch_[c].pre.reset();
        ch_[c].post.reset();
        std::fill(ch_[c].upHist, ch_[c].upHist + kPhaseTaps, 0.0f);
        std::fill(ch_[c].downHist, ch_[c].downHist + kFirTaps, 0.0f);
        ch_[c].upPos = 0;
        ch_[c].downPos = 0;
    }
}

void AnalogAmp::process(float *buffer, int n, int channel, float drive) noexcept {
    if (!ready_ || channel < 0 || channel >= numChannels_ || !buffer || n <= 0) return;
    auto &s = ch_[channel];
    if (drive < 0.0001f) drive = 0.0001f;

    for (int i = 0; i < n; ++i) {
        // 1. Voicing pre-filter (base rate, linear → no aliasing).
        float x = s.pre.process(buffer[i]);

        // 2. Push into polyphase upsampler history (base rate).
        s.upHist[s.upPos] = x;

        // 3. Produce kOversample samples, soft-clip each, feed the decimator.
        //    We only need the ONE decimated output, so accumulate the FIR sum on
        //    the decimation history as we push shaped OS samples.
        float decimated = 0.0f;
        for (int m = 0; m < kOversample; ++m) {
            // Polyphase interpolation for sub-phase m: taps fir_[m + j*kOversample].
            float up = 0.0f;
            int idx = s.upPos;
            for (int j = 0; j < kPhaseTaps; ++j) {
                up += fir_[m + j * kOversample] * s.upHist[idx];
                idx = (idx == 0) ? (kPhaseTaps - 1) : (idx - 1);
            }
            up *= float(kOversample);                 // restore amplitude

            // Soft clip at the oversampled rate.
            float shaped = shape(drive * up);

            // Push into the OS-rate decimation FIR history.
            s.downHist[s.downPos] = shaped;
            s.downPos = (s.downPos + 1) % kFirTaps;
        }

        // 4. Decimation FIR over the OS history (evaluated once per base sample).
        {
            int idx = (s.downPos == 0) ? (kFirTaps - 1) : (s.downPos - 1);
            for (int k = 0; k < kFirTaps; ++k) {
                decimated += fir_[k] * s.downHist[idx];
                idx = (idx == 0) ? (kFirTaps - 1) : (idx - 1);
            }
        }

        // 5. Warmth low-pass (base rate).
        buffer[i] = s.post.process(decimated);

        s.upPos = (s.upPos + 1) % kPhaseTaps;
    }
}

} // namespace streetrig
