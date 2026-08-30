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
        case ValveShrieker:   // soft clip + signature ~720 Hz mid hump, tight lows
            v = {100.0, 720.0, 0.8, 6.0,  0,0,0, Soft, 0.15f, 1.00f, 1.00f, false, 0.50f}; break;
        case BluesBlazer:     // transparent, open, low-gain
            v = { 80.0,   0,0,0,          0,0,0, Soft, 0.05f, 0.70f, 1.10f, false, 0.50f}; break;
        case Chiron:                 // "transparent" + treble tilt, high headroom (low drive)
            v = { 95.0, 2000.0, 0.7, 3.0, 0,0,0, Soft, 0.10f, 0.60f, 1.15f, false, 0.55f}; break;
        case KingOfTone:     // BluesBlazer-derived, fuller mids
            v = { 85.0, 500.0, 0.8, 3.0,  0,0,0, Soft, 0.10f, 0.90f, 1.05f, false, 0.50f}; break;
        case FIXATION:                // MOSFET, amp-like, brighter, gainier, asymmetric
            v = { 90.0, 2500.0, 0.7, 2.0, 0,0,0, Hard, 0.20f, 1.15f, 0.95f, false, 0.50f}; break;
        case DS1:            // hard asymmetric, mid-forward, buzzy
            v = {110.0, 800.0, 0.7, 2.0,  0,0,0, Hard, 0.25f, 1.00f, 0.95f, false, 0.45f}; break;
        case MetalRealm:        // tight, percussive, upper-mid forward — the Puppets
                             // / Black Album rhythm voicing, not the fizzy stock voicing.
            // RETUNED TOWARD A METALLICA RHYTHM TONE, and every number moved for
            // a reason you can hear:
            //   preHz 120 -> 155   the clipper was being fed low end it could not
            //                      keep tidy; palm mutes flubbed instead of
            //                      stopping dead. Sub-100 Hz share drops.
            //   preMid +5 dB @2.5k the bite. This voicing emphasised nothing
            //                      before the clipper, so it had gain but no
            //                      string attack. 2-4 kHz is where the pick is.
            //   postMid -12 -> -7  a -12 dB notch at 500 Hz with Q 1.2 is the
            //                      caricature scoop: fizz on top, nothing in the
            //                      middle, and it vanishes in a mix. Metallica's
            //                      tone is scooped but keeps real body. Shallower
            //                      and moved up, with a gentler Q.
            //   drive 1.60 -> 1.20 THE ATTACK FIX. A hard clipper at 1.6 flattens
            //                      the leading edge of every note; the pick was
            //                      being squashed into the sustain. Less gain into
            //                      the clip preserves the transient.
            //   outTrim .75 -> .85 makes up the level the smaller drive gives up,
            //                      so the retune is a tone change and not a
            //                      volume change.
            // Cue: a palm mute should stop DEAD and you should hear the pick hit
            // the string. Mush at the bottom means preHz went back down; a tone
            // that disappears behind a band means the scoop went back to -12.
            v = {155.0, 2500.0, 0.7, 5.0, 650.0, 0.9, -7.0, Hard, 0.10f, 1.20f, 0.85f, false, 0.60f}; break;
        case SHREW:                   // LM308 hard symmetric, bright, aggressive
            v = {100.0, 3000.0, 0.7, 3.0, 0,0,0, Hard, 0.00f, 1.30f, 0.85f, false, 0.45f}; break;
        case BigMitt:             // two cascaded soft stages + mid scoop, thick sustain
            v = { 70.0,   0,0,0, 1000.0, 0.8, -8.0, Soft, 0.05f, 1.40f, 0.60f, true, 0.15f};  break;
        case FuzzDome:           // round asymmetric germanium fuzz, full lows, dynamic
            v = { 60.0,   0,0,0,          0,0,0, Fuzz, 0.30f, 0.90f, 0.90f, false, 0.10f}; break;
        case FuzzFoundry:     // extreme-asymmetry gated/sputtery fuzz
            v = { 80.0,   0,0,0,          0,0,0, Fuzz, 0.60f, 1.20f, 0.75f, false, 0.00f}; break;
        case CleanBoost:     // clean/treble boost — mostly clean, sparkle
            v = { 80.0, 3000.0, 0.7, 3.0, 0,0,0, Soft, 0.00f, 0.40f, 1.20f, false, 0.60f}; break;
        case GenericHard:
            v = {110.0,   0,0,0,          0,0,0, Hard, 0.00f, 1.00f, 1.00f, false, 0.30f}; break;
        case GenericFuzz:
            v = { 70.0,   0,0,0,          0,0,0, Fuzz, 0.00f, 1.00f, 1.00f, false, 0.00f}; break;
        case GenericSoft:
        default:
            v = {100.0,   0,0,0,          0,0,0, Soft, 0.15f, 1.00f, 1.00f, false, 0.30f}; break;
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
        ch_[c].envFast = ch_[c].envSlow = 0.0f;
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

    // THE ATTACK, AND WHY IT HAS TO SCALE WITH DRIVE.
    //
    // The pick attack in these voicings came from `preMid` — a fixed EQ lift ahead
    // of the clipper. That works at low gain and is exactly what gets destroyed at
    // high gain: it is applied BEFORE the clip, so the harder the clipper is driven
    // the more of that emphasis it flattens. Turn Distortion up and the attack you
    // set at noon is gone, which is the "drowned out" complaint.
    //
    // So the restoration is POST-clip and DRIVE-SCALED. A fast and a slow envelope
    // are taken on the pre-clip signal; where they differ is the part of the note
    // that is attack rather than body. That difference becomes a gain applied after
    // the waveshaper, handing back the dynamic the shaper removed — and the amount
    // GROWS with how hard the clipper is working, because that is exactly how much
    // it took away. At low drive it does almost nothing (there was little to undo).
    //
    // Post-clip on purpose: boosting transients INTO the clipper would only clip
    // them harder, which is the opposite of the request.
    //
    // Cue: the pick should stay audible as Distortion goes up, not dissolve into
    // the grind. If notes start to spit or the attack cracks, `attack` is too high
    // for that voicing.
    const float atk = v_.attack;
    const float envAtkF = 1.0f - std::exp(-1.0f / (0.0005f * (float)sampleRate_)); // 0.5 ms
    const float envRelF = 1.0f - std::exp(-1.0f / (0.0300f * (float)sampleRate_)); // 30 ms
    const float envAtkS = 1.0f - std::exp(-1.0f / (0.0150f * (float)sampleRate_)); // 15 ms
    const float envRelS = 1.0f - std::exp(-1.0f / (0.1500f * (float)sampleRate_)); // 150 ms

    float d = s.smDrive, lv = s.smLevel;
    for (int i = 0; i < n; ++i) {
        d  = drive + (d  - drive) * smoothCoeff_;
        lv = level + (lv - level) * smoothCoeff_;

        // 1. Voicing pre-filters (base rate, linear → no aliasing).
        float x = s.pre.process(buffer[i]);
        x = s.preMid.process(x);

        // 1b. Transient measurement, on the signal about to be clipped.
        float transGain = 1.0f;
        if (atk > 0.0f) {
            const float a = std::fabs(x);
            s.envFast += (a > s.envFast ? envAtkF : envRelF) * (a - s.envFast);
            s.envSlow += (a > s.envSlow ? envAtkS : envRelS) * (a - s.envSlow);
            // Normalised against the body of the note, so the attack is the same
            // size whether you pick hard or soft — it follows the PLAYING, not the
            // input level, which is what makes it survive the level knob too.
            float t = (s.envFast - s.envSlow) / (s.envSlow + 1.0e-4f);
            t = std::clamp(t, 0.0f, 1.0f);
            // How much the clipper is compressing, 0…1. `d * dScale` is the gain
            // actually reaching the shaper, so this follows the Distortion knob.
            const float hardness = std::clamp(d * dScale / 12.0f, 0.0f, 1.0f);
            const float depth = atk * (0.35f + 0.65f * hardness);
            // LEVEL-NEUTRAL, and that correction is the difference between restoring
            // attack and simply turning the pedal up. Measured, the raw boost added
            // ~1.3 dB of RMS — the crest factor rose more than the level did, so the
            // dynamics really were improving, but a pedal that gets louder whenever
            // you add drive is a worse pedal even if it is a more percussive one.
            //
            // Dividing by the boost's own EXPECTED mean takes the level back out and
            // leaves only the shape. 0.28 is the average normalised transient across
            // the picked-note material these voicings were measured on; it does not
            // have to be exact, because being slightly off moves the level by
            // tenths of a dB while the peak-to-average change it is protecting is
            // several times that.
            transGain = (1.0f + depth * t) / (1.0f + depth * 0.28f);
        }

        // 2. Push into polyphase upsampler history (base rate).
        s.upHist[s.upPos] = x;

        // 3. Produce kOversample sub-samples, clip each (per-model shape + optional
        //    2-stage cascade), feed the nullifier.
        for (int m = 0; m < kOversample; ++m) {
            float up = 0.0f;
            int idx = s.upPos;
            for (int j = 0; j < kPhaseTaps; ++j) {
                up += fir_[m + j * kOversample] * s.upHist[idx];
                idx = (idx == 0) ? (kPhaseTaps - 1) : (idx - 1);
            }
            up *= float(kOversample);
            float shaped = shape(d * dScale * up, clipMode, asym);
            if (twoStage) shaped = shape(2.0f * shaped, clipMode, asym);  // Mitt cascade
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

        // 5. Post-clip mid scoop (Mitt / MetalRealm), DC block, tone low-pass, level.
        float post = s.postMid.process(decimated);
        float dc = post - s.dcX1 + dcR * s.dcY1;
        s.dcX1 = post; s.dcY1 = dc;
        s.toneState += toneA * (dc - s.toneState);
        // Transient gain rides the finished signal — after the tone control, so a
        // rolled-off tone still gets its pick back rather than having the attack
        // filtered away again.
        buffer[i] = s.toneState * transGain * lv * trim;

        s.upPos = (s.upPos + 1) % kPhaseTaps;
    }
    s.smDrive = d; s.smLevel = lv;
}

} // namespace streetrig
