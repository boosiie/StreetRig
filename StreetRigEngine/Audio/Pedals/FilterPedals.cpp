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
    // ~45 ms glide on the treadle position. The foot is sampled by a camera at about
    // 18 Hz, so the value arrives as a staircase roughly 55 ms wide; a filter that
    // jumps to each new step re-tunes in audible lumps, which is the choppiness. This
    // is the same de-zipper the volume pedal already has, for the same reason.
    smoothCoeff_ = std::exp(-1.0f / (0.045f * (float)sampleRate_));
    reset();
    ready_ = true;
}

void WahPedal::reset() noexcept {
    for (auto &c : ch_) { c.peak.reset(); c.shape.reset(); c.body.reset(); c.pos = -1.0f; }
}

void WahPedal::process(float *buffer, int n, int channel, const float *params) noexcept {
    if (!ready_ || !buffer || n <= 0 || channel < 0 || channel >= numChannels_ || !params) return;

    const float target = std::clamp(params[0], 0.0f, 1.0f);
    ChannelState &s = ch_[channel];
    // First block on this channel: start ON the value rather than gliding up from
    // zero, which would sweep the pedal open every time the chain is rebuilt.
    if (s.pos < 0.0f) s.pos = target;
    // Glide across the block, then tune from where it ended up. Per-block rather than
    // per-sample: re-deriving three biquads every sample would cost far more than the
    // smoothness is worth, and a block is short next to 45 ms.
    for (int i = 0; i < n; ++i) s.pos = target + (s.pos - target) * smoothCoeff_;
    const float pos = s.pos;
    // Sweep the resonant peak ~450 Hz → ~2.0 kHz (log). Widened at the top from
    // 1.6 kHz: the toe-down end is where a wah gets its bite, and stopping short of
    // 2 kHz was clipping off the part that reads as "quacky" rather than merely
    // "filtered".
    const double fc = 450.0 * std::pow(4.4, (double)pos);
    // A little sharper and louder than the first pass (2.5 / +16 dB) for bite —
    // but only a little. Q was tried at 4.2 and made the pedal WEAKER: a narrower
    // peak touches less of the spectrum, and the offline check measured exactly that.
    // The strength comes from the lowpass below, not from resonance.
    const Biquad p = Biquad::peaking(sampleRate_, fc, 3.6, 18.0);

    // AND A LOWPASS THAT TRACKS IT, which is the part that was missing.
    //
    // A peaking EQ boosts a band and leaves everything else exactly as it was, so the
    // dry signal still runs underneath the effect and the pedal reads as a hump moving
    // about rather than as a filter sweeping. Raising Q made that WORSE by measurement
    // — a narrower peak touches less of the spectrum — which is the giveaway that the
    // peak was never the whole story.
    //
    // A real wah is a resonant BANDPASS: rolled off above the peak as well as below,
    // so the whole top end moves with the treadle. Heel down puts the corner near
    // 1.1 kHz and the sound goes dark and vocal; toe down opens it to ~5 kHz with a
    // hard 2 kHz peak, which is the quack. Gentle Q on this one — it is shaping the
    // body of the sound, and the peak above is doing the character.
    // 1.3x fc, not 2.5x. At 2.5x the corner sat above where a guitar actually has
    // energy, so it cost the sweep nothing and the measured difference from dry went
    // DOWN. Just above the peak it does the real work: heel down lands the corner
    // near 590 Hz and the sound closes right up, toe down opens it past 2.5 kHz.
    const Biquad lp = Biquad::lowpass(sampleRate_, std::min(fc * 1.3, sampleRate_ * 0.45), 0.707);

    // AND A HIGHPASS BELOW IT, which closes the bandpass and is where the vowel
    // comes from. With only a lowpass above, everything under the peak still ran
    // through untouched, so the pedal had a bright end and a dull end but never
    // really said "wah" — that sound is a formant, a band with air on BOTH sides of
    // it, and a filter open at the bottom cannot make one.
    //
    // Deliberately gentle and well below the peak: at 0.55x it thins the mud without
    // hollowing the heel position out, which should stay bassy the way a real wah's
    // does rather than turning thin. This is tone, not level — no gain was added
    // for it.
    const Biquad hp = Biquad::highpass(sampleRate_, std::max(fc * 0.55, 30.0), 0.707);

    s.peak.setCoeffs(p.b0, p.b1, p.b2, p.a1, p.a2);
    s.shape.setCoeffs(lp.b0, lp.b1, lp.b2, lp.a1, lp.a2);
    s.body.setCoeffs(hp.b0, hp.b1, hp.b2, hp.a1, hp.a2);
    for (int i = 0; i < n; ++i)
        buffer[i] = s.shape.process(s.peak.process(s.body.process(buffer[i])));
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
