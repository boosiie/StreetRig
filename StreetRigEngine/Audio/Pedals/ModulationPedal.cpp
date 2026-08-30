//
//  ModulationPedal.cpp
//  StreetRig
//
//  Implementation of the modulation family. See ModulationPedal.hpp.
//

#include "ModulationPedal.hpp"

#include <cmath>

namespace streetrig {

void ModulationPedal::prepare(double sampleRate, int numChannels) {
    sampleRate_ = sampleRate > 0 ? sampleRate : 48000.0;
    numChannels_ = std::clamp(numChannels, 1, kMaxChannels);
    reset();
    ready_ = true;
}

void ModulationPedal::reset() noexcept {
    for (int c = 0; c < kMaxChannels; ++c) {
        std::fill(ch_[c].delay, ch_[c].delay + kDelayMax, 0.0f);
        std::fill(ch_[c].apX, ch_[c].apX + kMaxAllpass, 0.0f);
        std::fill(ch_[c].apY, ch_[c].apY + kMaxAllpass, 0.0f);
        ch_[c].writePos = 0;
        lfoPhase_[c] = 0.0f;
    }
}

void ModulationPedal::process(float *buffer, int n, int channel, const float *params) noexcept {
    if (!ready_ || !buffer || n <= 0 || channel < 0 || channel >= numChannels_ || !params) return;
    ChannelState &s = ch_[channel];

    const float rateHz = std::clamp(params[0], 0.02f, 12.0f);
    const float depth  = std::clamp(params[1], 0.0f, 1.0f);
    const float mix    = std::clamp(params[2], 0.0f, 1.0f);
    const float phaseInc = 2.0f * (float)M_PI * rateHz / (float)sampleRate_;

    float phase = lfoPhase_[channel];

    switch (voicing_) {
        case Tremolo: {
            // Amplitude LFO. Depth sets how far the volume dips (0 = none, 1 = to
            // silence at the trough). Mix is unused (tremolo is a 100% effect).
            for (int i = 0; i < n; ++i) {
                const float lfo = 0.5f + 0.5f * std::sin(phase);       // 0..1
                const float amp = 1.0f - depth * lfo;
                buffer[i] *= amp;
                phase += phaseInc; if (phase > 2.0f * (float)M_PI) phase -= 2.0f * (float)M_PI;
            }
            break;
        }
        case Phaser:
        case DeepPhaser:
        case Univibe: {
            // Cascade of first-order all-pass sections whose break frequency is
            // swept by the LFO. Summed with the dry signal -> moving notches.
            //
            // REPORTED TWICE AS "THE PHASER DOES NOTHING", and the second report
            // was right: the first pass retuned stage count, feedback and sweep
            // centre, but every one of those numbers was sitting on the wrong
            // filter. The all-pass was written
            //
            //     y = a*x + xPrev - a*yPrev      ->  H(z) = (a + z^-1)/(1 + a*z^-1)
            //
            // whose pole is at MINUS a. With a in 0.59..0.97 that puts each
            // stage's 90-degree point at 20-24 kHz: the notches formed above the
            // top of the guitar's range, above the top of hearing, and the sum
            // with the dry signal was flat across the whole audible band. It
            // measured 0.5 dB of movement against 0.22 dB for no effect at all.
            //
            // The correct convention for a swept-notch phaser puts the pole at
            // PLUS a, which is what the old comment ("about 1.2 kHz") always
            // described - the prose was right and the sign was wrong:
            //
            //     y = -a*x + xPrev + a*yPrev     ->  H(z) = (-a + z^-1)/(1 - a*z^-1)
            //
            // At a = 0.90 that is a 90-degree point near 900 Hz, sweeping roughly
            // 230 Hz - 2.5 kHz across the LFO: through the mids, where a guitar
            // has body and a phone speaker still works.
            //
            // Cue: sweep the Rate and you should hear the notches WALK. Silence
            // that changes only in level means the sign has been flipped back.
            const int stages = (voicing_ == Univibe) ? 6 : (voicing_ == DeepPhaser ? 12 : 6);
            const float aCenter = 0.90f;                    // ~900 Hz at centre
            const float aSpan   = (voicing_ == DeepPhaser ? 0.16f : 0.12f)
                                * (0.35f + 0.65f * depth);

            // RESONANCE IS THE KNOB, NOT THE WET/DRY BALANCE. `mix` arrives from
            // the one panel dial, and feeding it straight to a dry/wet blend made
            // the effect DISAPPEAR at full travel: an all-pass cascade has flat
            // magnitude, so 100% wet is 100% nothing. Measured, the old mapping
            // peaked around 0.65 and fell away on either side - turning the knob
            // up past six made the phaser weaker, which is not what a knob means.
            //
            // A phaser is a FIXED sum of dry and shifted (that sum is what forms
            // the notches at all), so the blend is pinned at half and the dial
            // drives feedback instead: more knob = more resonant notches = more
            // phaser, monotonically, all the way up.
            const float wet = 0.5f;
            // DeepPhaser is twelve stages -> six notches instead of three, on a
            // wider sweep. Its feedback is held a little BELOW the six-stage
            // phaser's and capped lower: at 0.90 through twelve stages the tank
            // peaked at 0.93, close enough to clipping to matter, and the extra
            // resonance bought nothing measurable because six notches inside one
            // band already average each other out. Its character is notch COUNT
            // and sweep width, not Q.
            //
            // MEASURED, AND WORTH KNOWING BEFORE YOU "FIX" IT: judged by band
            // energy swing across 300 Hz-3 kHz, DeepPhaser reads SHALLOWER than
            // the plain phaser (3.0 dB against 7.3 dB) even though it is
            // audibly the more dramatic effect. That is the metric's limit, not
            // the voicing's - six notches moving through one band cancel in an
            // aggregate energy measure in a way three notches do not. Do not
            // chase that number by piling on feedback; that is what pushed the
            // peak to 0.93 the first time.
            const float fbBase = (voicing_ == Univibe) ? 0.35f
                               : (voicing_ == DeepPhaser ? 0.70f : 0.75f);
            const float fbSpan = (voicing_ == Univibe) ? 0.15f
                               : (voicing_ == DeepPhaser ? 0.14f : 0.18f);
            const float feedback = std::min(0.92f, fbBase + fbSpan * mix);
            for (int i = 0; i < n; ++i) {
                const float lfo = std::sin(phase);                     // -1..1
                const float dry = buffer[i];
                float w = dry + feedback * s.apY[stages - 1];          // resonance
                for (int k = 0; k < stages; ++k) {
                    // Staggered centre per stage for univibe's uneven voicing.
                    // Kept small: at aCenter 0.90 a wide stagger drives the top
                    // stages into the 0.97 clamp and flattens the sweep.
                    float aC = aCenter + (voicing_ == Univibe ? 0.03f * (float)(k - stages / 2) : 0.0f);
                    float a = std::clamp(aC + aSpan * lfo, -0.97f, 0.97f);
                    // First-order all-pass, pole at +a: y = -a*x + xPrev + a*yPrev.
                    float y = -a * w + s.apX[k] + a * s.apY[k];
                    s.apX[k] = w;
                    s.apY[k] = y;
                    w = y;
                }
                float out = (1.0f - wet) * dry + wet * w;
                if (voicing_ == Univibe) {
                    const float amp = 1.0f - 0.15f * depth * (0.5f + 0.5f * lfo);
                    out *= amp;
                }
                buffer[i] = out;
                phase += phaseInc; if (phase > 2.0f * (float)M_PI) phase -= 2.0f * (float)M_PI;
            }
            break;
        }
        case Flanger:
        case Chorus:
        default: {
            // Short modulated delay. Chorus: longer base delay, gentle depth, low
            // feedback → detuned doubling. Flanger: very short delay + feedback →
            // sweeping comb notches.
            // REPORTED AS "CHORUS SOUNDS SAD AND DEPRESSED", which is what ±7 ms
            // of sweep does: that is not a chorus, it is a pitch-bend. A delay
            // line moving that far retunes the note continuously and the ear
            // hears it as seasick and flat. Real chorus lives at ±1–3 ms — the
            // detuning is meant to be felt as thickness, not heard as pitch.
            // 2.2 ms at full depth now, on a slightly shorter base.
            const bool isFlanger = (voicing_ == Flanger);
            const float baseMs = isFlanger ? 2.5f : 11.0f;
            const float modMs  = (isFlanger ? 2.0f : 2.2f) * depth;
            const float feedback = isFlanger ? (0.55f * depth) : 0.10f;
            const float msToSamp = (float)sampleRate_ / 1000.0f;
            for (int i = 0; i < n; ++i) {
                const float lfo = std::sin(phase);                     // -1..1
                const float dry = buffer[i];
                float delaySamples = (baseMs + modMs * lfo) * msToSamp;
                delaySamples = std::clamp(delaySamples, 1.0f, (float)(kDelayMax - 2));
                const float wet = readDelay(s, delaySamples);
                s.delay[s.writePos] = dry + feedback * wet;
                s.writePos = (s.writePos + 1) % kDelayMax;
                buffer[i] = (1.0f - mix) * dry + mix * wet;
                phase += phaseInc; if (phase > 2.0f * (float)M_PI) phase -= 2.0f * (float)M_PI;
            }
            break;
        }
    }

    lfoPhase_[channel] = phase;
}

} // namespace streetrig
