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
        case Univibe: {
            // Cascade of first-order all-pass sections whose break frequency is
            // swept by the LFO. Summed with the dry signal → moving notches.
            // Univibe uses more stages, staggered centres, and a little throb.
            const int stages = (voicing_ == Univibe) ? 6 : 4;
            const float aCenter = 0.55f;
            const float aSpan   = 0.40f * depth;
            const float feedback = (voicing_ == Univibe) ? 0.35f : 0.25f;
            for (int i = 0; i < n; ++i) {
                const float lfo = std::sin(phase);                     // -1..1
                const float dry = buffer[i];
                float w = dry + feedback * s.apY[stages - 1];          // light resonance
                for (int k = 0; k < stages; ++k) {
                    // Staggered centre per stage for univibe's uneven voicing.
                    float aC = aCenter + (voicing_ == Univibe ? 0.06f * (float)(k - stages / 2) : 0.0f);
                    float a = std::clamp(aC + aSpan * lfo, -0.97f, 0.97f);
                    // First-order all-pass: y = a*x + xPrev - a*yPrev.
                    float y = a * w + s.apX[k] - a * s.apY[k];
                    s.apX[k] = w;
                    s.apY[k] = y;
                    w = y;
                }
                float out = (1.0f - mix) * dry + mix * w;
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
            const bool isFlanger = (voicing_ == Flanger);
            const float baseMs = isFlanger ? 2.5f : 14.0f;
            const float modMs  = (isFlanger ? 2.0f : 7.0f) * depth;
            const float feedback = isFlanger ? (0.55f * depth) : 0.12f;
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
