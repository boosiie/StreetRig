//
//  AnalogAmp.cpp
//  StreetRig
//
//  Implementation of the profiled preamp. See AnalogAmp.hpp for the contract and
//  for why the stage filters are one-poles while the output low-pass is not.
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
    osRate_ = sampleRate_ * kOversample;
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

    // Boot on the Legacy voicing so an amp that is never configured (and the
    // benchmark / null-test paths that never touch a profile) behaves exactly as
    // the engine did before profiles existed.
    configure(profileFor(Legacy));
    reset();
    ready_ = true;
}

void AnalogAmp::configure(const AmpProfile &p) noexcept {
    stageCount_ = p.stageCount < 1 ? 1 : (p.stageCount > kMaxStages ? kMaxStages : p.stageCount);

    hasInput_  = (p.inputHz  > 0.0 && p.inputHz  < sampleRate_ * 0.45);
    hasBright_ = (p.brightHz > 0.0 && p.brightDB != 0.0f && p.brightHz < sampleRate_ * 0.45);
    // The LAST stage's Miller pole is the amp's OUTPUT bandwidth and runs at base
    // rate as a biquad — see the header for why, and note that this is exactly
    // what keeps the Legacy voicing byte-identical.
    //
    // A corner AT OR ABOVE the base Nyquist is skipped rather than designed. The
    // RM-140's Miller poles sit at 25 kHz — above 48 kHz Nyquist — which is
    // physically "this stage does not roll off inside the audio band", but which
    // an RBJ design turns into nonsense coefficients (the first build of this
    // produced NaN for the whole amp). Skipping is both the correct filter and
    // the correct behaviour.
    const double outHz = p.stage[stageCount_ - 1].millerHz;
    hasOutLP_ = (outHz > 0.0 && outHz < sampleRate_ * 0.45);

    for (int s = 0; s < stageCount_; ++s) {
        const PreampStage &ps = p.stage[s];
        StageConst &sc = stageConst_[s];
        sc.gain       = ps.gain;
        sc.asym       = ps.asym;
        sc.clip       = ps.clip;
        sc.bypassClip = (ps.clip == AmpClip::Clean);
        // Precompute the DC the clip bias introduces so the audio thread never
        // evaluates a transcendental it does not have to.
        sc.offset     = sc.bypassClip ? 0.0f : ampShapeRaw(0.0f, ps.clip, ps.asym);
    }

    for (int c = 0; c < kMaxChannels; ++c) {
        ChannelState &st = ch_[c];
        st.input  = hasInput_  ? Biquad::highpass(sampleRate_, p.inputHz, 0.707) : Biquad{};
        st.bright = hasBright_ ? Biquad::highShelf(sampleRate_, p.brightHz, 0.707, p.brightDB) : Biquad{};
        st.outLP  = hasOutLP_  ? Biquad::lowpass(sampleRate_, outHz, 0.707) : Biquad{};
        for (int s = 0; s < kMaxStages; ++s) {
            const PreampStage &ps = p.stage[s];
            // Interstage filters live INSIDE the oversampled region, so they are
            // designed at the oversampled rate.
            st.stage[s].coupling.design(osRate_, s < stageCount_ ? ps.couplingHz : 0.0);
            st.stage[s].cathode.design(osRate_, s < stageCount_ ? ps.cathodeHz : 0.0,
                                       s < stageCount_ ? ps.cathodeDB : 0.0f);
            // The last stage's Miller pole is the base-rate output biquad above,
            // so its one-pole is disabled.
            const bool interstage = (s < stageCount_ - 1);
            st.stage[s].miller.design(osRate_, interstage ? ps.millerHz : 0.0);
        }
    }
}

void AnalogAmp::reset() noexcept {
    for (int c = 0; c < kMaxChannels; ++c) {
        ch_[c].input.reset();
        ch_[c].bright.reset();
        ch_[c].outLP.reset();
        for (int s = 0; s < kMaxStages; ++s) {
            ch_[c].stage[s].coupling.reset();
            ch_[c].stage[s].cathode.reset();
            ch_[c].stage[s].miller.reset();
        }
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

    const int stages = stageCount_;

    for (int i = 0; i < n; ++i) {
        // 1. Input voicing (base rate, linear → no aliasing): grid tightening
        //    high-pass, then the bright cap's treble bleed.
        float x = buffer[i];
        if (hasInput_)  x = s.input.process(x);
        if (hasBright_) x = s.bright.process(x);

        // 2. Push into polyphase upsampler history (base rate).
        s.upHist[s.upPos] = x;

        // 3. Produce kOversample sub-samples, run the WHOLE stage cascade on each
        //    (one up/down conversion covers N stages), feed the nullifier.
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

            // THE CASCADE. Per stage, in circuit order: what reaches the grid,
            // how the cathode network shelves it, how hard the valve drives it,
            // the clip, and what the Miller pole lets through to the next grid.
            // `drive` multiplies into stage 0 only — it is the amp's Gain knob,
            // in front of the first valve, exactly where it is on the panel.
            float v = up;
            for (int k = 0; k < stages; ++k) {
                StageState &ss = s.stage[k];
                const StageConst &sc = stageConst_[k];
                v = ss.coupling.process(v);
                v = ss.cathode.process(v);
                v *= (k == 0) ? (drive * sc.gain) : sc.gain;
                if (!sc.bypassClip) v = ampShape(v, sc.clip, sc.asym, sc.offset);
                v = ss.miller.process(v);
            }

            // Push into the OS-rate decimation FIR history.
            s.downHist[s.downPos] = v;
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

        // 5. Output bandwidth — the last stage's Miller pole, at base rate.
        buffer[i] = hasOutLP_ ? s.outLP.process(decimated) : decimated;

        s.upPos = (s.upPos + 1) % kPhaseTaps;
    }
}

} // namespace streetrig
