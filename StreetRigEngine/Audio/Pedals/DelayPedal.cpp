//
//  DelayPedal.cpp
//  StreetRig
//
//  Implementation of the delay family. See DelayPedal.hpp for the circuit notes
//  and the real-time contract.
//

#include "DelayPedal.hpp"

#include <algorithm>
#include <cmath>

namespace streetrig {

// MARK: - THE ONE AUDITABLE TABLE for the delay family
//
//  Every hard-coded number that decides which pedal this is lives here, with the
//  listening cue from research/amp-emulation-approaches.md §11.6 beside it. The
//  0…10 knob curves live in ParameterMap.swift; the CIRCUIT lives here.

DelayPedal::Voice DelayPedal::voiceFor(int voicing) noexcept {
    Voice v;
    switch (voicing) {
    case Tape:
        // DUNLAP ECHOPLEX (EP-3). A tape loop is a record head, a moving piece
        // of oxide and a playback head, and all three colour EVERY pass: the
        // record amp saturates, the tape loses top and bottom, and the motor
        // never runs at exactly one speed. Because all of it is inside the
        // feedback path, repeat six is a soft, dark, wobbly ghost of repeat one
        // — which is the entire reason people still buy these.
        v.timeMode      = Glide;      // dragging the head bends the pitch
        v.hermite       = true;
        // TWO poles, not one. A single 4 kHz pole is only ~2 dB darker than the
        // digital voicing's 8 kHz pole across the band a listener judges
        // "darker" by, and measurement bore that out: the first repeats of the
        // two came out 0.3 pp apart. Tape's HF loss is not first order — head-gap
        // loss, playback-head response and the tape's own self-erasure stack —
        // so it is modelled as two poles a little higher up, which lands the
        // first repeat where an Echoplex's actually sits.
        v.fbLowpassHz   = 4500.0f;    // cue: each repeat noticeably darker than
        v.twoPoleLP     = true;       // the last, gone by ~6 repeats
        v.fbHighpassHz  = 90.0f;      // head-gap loss at the bottom; also keeps
                                      // LF energy from stacking up in the loop
        v.satDrive      = 0.85f;      // record-stage soft clip (tanh knee)
        // The famous EP-3 preamp, on the OUTPUT and applied once — and modelled
        // as a broad MIDRANGE peak, not a treble shelf. The obvious reading
        // (+3 dB above 3 kHz) makes the tape voicing measure BRIGHTER at 2 kHz
        // than the digital one on the very first repeat, which contradicts every
        // ear and the spec's own cue; what an EP-3 in a signal chain actually
        // adds is midrange girth, and its top end is limited by the tape, not
        // lifted by the amplifier.
        v.preampHz      = 1200.0f;
        v.preampQ       = 0.70f;
        v.preampDB      = 3.0f;       // cue: an Echoplex in the chain should
                                      // thicken the note even with Sustain at 0
        v.wowHz         = 0.5f;   v.wowDepth     = 0.0030f;  // ±0.30 % — cue:
        v.flutterHz     = 6.0f;   v.flutterDepth = 0.0005f;  // just perceptible.
                                      // Seasick → lower the WOW depth first.
        v.trim          = 1.0f;
        break;

    case BBD:
        // Deluxe Memory Man. A bucket-brigade chip is an analog shift register:
        // the signal is clocked bucket to bucket, losing bandwidth and gaining
        // hiss the whole way, so the manufacturer wraps it in a COMPANDER —
        // squash going in, expand coming out — to keep the noise down. That
        // compander is what people hear as "the analog delay sound": repeats
        // that bloom and then squash, with the hiss breathing along with them.
        v.timeMode      = Glide;      // the clock slews, so the pitch does too
        v.hermite       = true;
        v.fbLowpassHz   = 2500.0f;    // cue: distinctly darker and more "analog"
        v.twoPoleLP     = true;       // …than tape, because a BBD's anti-alias
                                      // and reconstruction filters are steep
        v.fbHighpassHz  = 60.0f;
        v.compandAmount = 0.60f;      // cue: repeats should squash, then bloom
        // −86 dBFS, not −72. Reported by ear as "the delay creates a loud
        // background sound", and it is generated INSIDE the feedback loop, so
        // every repeat adds another helping and the running sum is roughly
        // 1/(1−feedback) times one pass — at the Katana's pinned 0.38 that is
        // 1.6×, and higher on a pedal set for long repeats. The compander then
        // EXPANDS it further on the way out, which is the mechanism that made a
        // number chosen as "a chip's quiet hiss" arrive as an audible wash.
        // A BBD should whisper under the repeats, not sit behind the playing.
        v.noiseFloor    = 0.00005f;   // gated by the envelope, so a dead tail
                                      // is still truly dead
        v.satDrive      = 0.0f;
        v.wowHz         = 0.4f;   v.wowDepth = 0.0080f;   // the Memory Man's own
                                      // chorus section, riding the read pointer
        v.trim          = 1.0f;
        break;

    case Digital:
    default:
        // VOSS Digital Delay (DD-8). The point of a digital delay is that the
        // repeat is the SAME as what you played, so almost everything above is
        // deliberately absent. The one thing that is not is the feedback-path
        // low-pass: an unfiltered digital loop makes each repeat marginally
        // BRIGHTER than the last (the wet path adds no loss but the dry does),
        // which sounds wrong and eventually shrill at high feedback.
        v.timeMode    = Crossfade;    // pitch must NOT move — see the header
        v.hermite     = false;
        v.fbLowpassHz = 8000.0f;      // cue: repeats stay clear but never get
                                      // brighter than the dry. Brighter → lower.
        v.trim        = 1.0f;
        break;
    }
    return v;
}

// MARK: - Setup thread

void DelayPedal::prepare(double sampleRate, int numChannels) noexcept {
    sampleRate_ = sampleRate > 0 ? sampleRate : 48000.0;
    numChannels_ = std::clamp(numChannels, 1, kMaxChannels);

    // §11.1: the delay-time slew is 100 ms. Cue: turn Time with repeats running
    // — clicking means raise it, no tape-style glide means raise it, sluggish
    // means lower it. The crossfade is 30 ms, which is long enough to be
    // inaudible on a step and short enough that a sweep does not smear.
    slewCoeff_ = onePoleCoeff(sampleRate_, 0.100);
    xfadeStep_ = 1.0f / std::max(1.0f, (float)(0.030 * sampleRate_));
    envCoeff_  = onePoleCoeff(sampleRate_, 0.015);
    dcCoeff_   = std::exp(-2.0f * (float)M_PI * 20.0f / (float)sampleRate_);

    configure(voicing_);
    reset();
    ready_ = true;
}

void DelayPedal::configure(int voicing) noexcept {
    voicing_ = std::clamp(voicing, 0, (int)BBD);
    v_ = voiceFor(voicing_);
    // The EP-3 preamp is the only biquad in the block; everything else is first
    // order, because everything else it models is. Designed HERE, on the setup
    // thread — the render path evaluates no trigonometry.
    for (int c = 0; c < kMaxChannels; ++c) {
        if (v_.preampDB != 0.0f) {
            ch_[c].preamp = Biquad::peaking(sampleRate_, v_.preampHz, v_.preampQ, v_.preampDB);
        } else {
            ch_[c].preamp = Biquad{};   // identity
        }
        ch_[c].noise.reset(0x9E3779B9u + (unsigned int)c * 0x85EBCA6Bu);
    }
}

void DelayPedal::reset() noexcept {
    for (int c = 0; c < kMaxChannels; ++c) {
        ChannelState &s = ch_[c];
        s.writePos = 0;
        s.delaySamples = 0.0f;
        s.pendingDelay = 0.0f;
        s.xfade = 1.0f;
        s.fbLP = s.fbLP2 = 0.0f;
        s.fbHPx1 = s.fbHPy1 = 0.0f;
        s.preamp.reset();
        s.dcX1 = s.dcY1 = 0.0f;
        s.env = 0.0f;
        s.wowPhase = s.flutterPhase = 0.0f;
    }
    // Clearing the line itself belongs to whoever owns the arena; PedalChain
    // zeroes the span in `configureSlot`. Doing it here as well would mean the
    // audio thread's `reset()` path touched a buffer it does not own.
}

void DelayPedal::setBuffer(float *base, int floatsPerChannel) noexcept {
    // Un-publish FIRST, so the render thread cannot be reading the old span
    // while we clear the new one. It sees nullptr and passes audio through.
    buf_.store(nullptr, std::memory_order_release);
    if (!base || floatsPerChannel < 64) {
        lineLen_ = lineMask_ = 0;
        maxDelay_ = 0.0f;
        return;
    }
    lineLen_ = floatsPerChannel;
    lineMask_ = floatsPerChannel - 1;
    // Leave four samples of margin: the Hermite read touches readPos-1 … +2, and
    // the write head must never be overtaken by its own read.
    maxDelay_ = (float)(floatsPerChannel - 4);
    std::fill(base, base + (size_t)kMaxChannels * (size_t)floatsPerChannel, 0.0f);
    reset();
    // RELEASE: everything above (the zeroing, the lengths) happens-before any
    // acquire load of this pointer on the render thread.
    buf_.store(base, std::memory_order_release);
}

// MARK: - Audio thread

void DelayPedal::process(float *buffer, int n, int channel, const float *params) noexcept {
    if (!ready_ || !buffer || n <= 0 || channel < 0 || channel >= numChannels_ || !params) return;
    float *base = buf_.load(std::memory_order_acquire);
    if (!base) return;                       // no line assigned → pass through

    float *line = base + (size_t)channel * (size_t)lineLen_;
    ChannelState &s = ch_[channel];

    // ---- Buffer-constant parameters -------------------------------------
    const float msToSamp = (float)sampleRate_ / 1000.0f;
    float target = std::clamp(params[0], 1.0f, 4000.0f) * msToSamp;
    target = std::clamp(target, 4.0f, maxDelay_);
    // Feedback is hard-limited at 0.95 no matter what arrives on the bus. At
    // 0.95 the loop self-oscillates the way the hardware does at full repeats;
    // at 1.0 it would grow without bound, and the sanitizer would be papering
    // over a design error rather than catching a stray NaN.
    const float feedback = std::clamp(params[1], 0.0f, 0.95f);
    const float wet = std::clamp(params[2], 0.0f, 1.0f) * v_.trim;
    // A Tone value of 0 means "this pedal has no Tone knob" — use the circuit's
    // own corner. That keeps the per-model number in this file (where the ear
    // tuning happens) instead of duplicating it in Swift.
    const float toneHz = (params[3] > 0.0f) ? std::clamp(params[3], 200.0f, 16000.0f)
                                            : v_.fbLowpassHz;
    const float modDepth = std::clamp(params[4], 0.0f, 1.0f);

    // Filter coefficients from buffer-constant values. `exp` per BUFFER is fine
    // (it is not per sample, and the block is bounded); the ~5 ms figure the rest
    // of the engine uses for de-zippering does not apply — a low-pass corner
    // moving once per 128 samples is inaudible.
    const float lpA = 1.0f - std::exp(-2.0f * (float)M_PI * toneHz / (float)sampleRate_);
    const float hpC = (v_.fbHighpassHz > 0.0f)
        ? std::exp(-2.0f * (float)M_PI * v_.fbHighpassHz / (float)sampleRate_) : 0.0f;

    // Modulation. The tape voicing's wow and flutter are ALWAYS on (they are the
    // machine, not an effect); the BBD's chorus depth follows the pedal's own
    // Depth knob, and the base depth is what a Memory Man does with Depth at
    // noon. Both are expressed as a FRACTION of the delay time, because that is
    // how a real speed variation behaves — a 0.3 % wow on a 600 ms echo wobbles
    // six times as far as on a 100 ms slap.
    const float wowDepth = (voicing_ == BBD) ? v_.wowDepth * (0.25f + 0.75f * modDepth)
                                             : v_.wowDepth;
    const float wowInc = 2.0f * (float)M_PI * v_.wowHz / (float)sampleRate_;
    const float flutInc = 2.0f * (float)M_PI * v_.flutterHz / (float)sampleRate_;

    // ---- Time change: crossfade (digital) or slew (tape / BBD) -----------
    if (s.delaySamples <= 0.0f) {           // first buffer after a reset
        s.delaySamples = target;
        s.pendingDelay = target;
        s.xfade = 1.0f;
    } else if (v_.timeMode == Crossfade) {
        // Start a new crossfade only when the previous one has finished, so the
        // fades chain cleanly during a knob sweep instead of stacking. Each is
        // 30 ms of equal-power-ish linear blend between two read positions —
        // inaudible, and the pitch never moves, which is the whole point of a
        // digital delay.
        if (s.xfade >= 1.0f && std::abs(target - s.delaySamples) > 1.0f) {
            s.pendingDelay = target;
            s.xfade = 0.0f;
        }
    }
    // The Glide voicings do their slewing per SAMPLE (below), so the read pointer
    // moves continuously and the repeats bend in pitch.

    float writePos = (float)s.writePos;

    for (int i = 0; i < n; ++i) {
        const float dry = buffer[i];

        // --- Where to read -------------------------------------------------
        if (v_.timeMode == Glide) {
            s.delaySamples += slewCoeff_ * (target - s.delaySamples);
        }
        float d = s.delaySamples;

        // Wow / flutter / chorus, as a fraction of the delay length.
        if (wowDepth != 0.0f) {
            d *= 1.0f + wowDepth * std::sin(s.wowPhase);
            s.wowPhase += wowInc;
            if (s.wowPhase > 2.0f * (float)M_PI) s.wowPhase -= 2.0f * (float)M_PI;
        }
        if (v_.flutterDepth != 0.0f) {
            d *= 1.0f + v_.flutterDepth * std::sin(s.flutterPhase);
            s.flutterPhase += flutInc;
            if (s.flutterPhase > 2.0f * (float)M_PI) s.flutterPhase -= 2.0f * (float)M_PI;
        }
        d = std::clamp(d, 2.0f, maxDelay_);

        float readPos = writePos - d;
        while (readPos < 0.0f) readPos += (float)lineLen_;
        float echo = readLine(line, readPos);

        // --- The digital crossfade -----------------------------------------
        if (s.xfade < 1.0f) {
            float dp = std::clamp(s.pendingDelay, 2.0f, maxDelay_);
            float rp = writePos - dp;
            while (rp < 0.0f) rp += (float)lineLen_;
            const float other = readLine(line, rp);
            echo = echo + s.xfade * (other - echo);
            s.xfade += xfadeStep_;
            if (s.xfade >= 1.0f) {          // the fade landed: adopt the new time
                s.xfade = 1.0f;
                s.delaySamples = s.pendingDelay;
            }
        }

        // --- PLAYBACK SIDE: what comes off the head, once per pass ----------
        if (v_.noiseFloor > 0.0f) {
            // The chip's own hiss, added where it is generated — INSIDE the
            // bucket brigade, so the expander below shapes it exactly as it
            // shapes the signal. Gated by the envelope so a decayed tail really
            // is silent; an ungated floor would recirculate for ever at feedback
            // 0.9 and the "tail decays to silence" contract would be a lie.
            echo += s.noise.next() * v_.noiseFloor * std::clamp(s.env * 20.0f, 0.0f, 1.0f);
        }
        if (v_.compandAmount > 0.0f) {
            // EXPAND. The manufacturer's answer to the chip's noise floor: squash
            // going in, stretch coming out, so the hiss is pushed down along with
            // the quiet parts of the signal. It is also why an analog delay's
            // repeats seem to bloom and then squash — that pumping IS the
            // compander, and it is the single most recognisable thing about a BBD.
            s.env = flushDenormal(s.env + envCoeff_ * (std::abs(echo) - s.env));
            const float e = std::clamp(s.env * 4.0f, 0.0f, 1.0f);
            echo *= 1.0f - v_.compandAmount * (1.0f - e);
        }

        // The EP-3 preamp: the machine's OUTPUT amplifier, downstream of the
        // playback head, so it colours each repeat exactly ONCE. It deliberately
        // does not sit in the loop — the tape's losses compound, an amplifier's
        // gain does not, and putting the lift inside the loop had it cancelling
        // the very bandwidth loss that makes a tape echo sound like tape.
        const float wetOut = (v_.preampDB != 0.0f) ? s.preamp.process(echo) : echo;

        // --- RECORD SIDE: everything the medium does to what is stored, so its
        //     effect COMPOUNDS pass after pass. -----------------------------
        float rec = dry + feedback * echo;

        if (v_.satDrive > 0.0f) {
            // Record amplifier + tape magnetics: transparent below the knee,
            // softly compressed above it. `k · tanh(x/k)` keeps unit slope at the
            // origin, so quiet repeats are untouched and only loud ones squash.
            const float k = v_.satDrive;
            rec = k * std::tanh(rec / k);
        }

        // Bandwidth loss — one pole, or two for the BBD's much steeper
        // anti-alias / reconstruction filtering. This is on the RECORD side, so
        // the first repeat is already filtered (it has been through the medium
        // once) and every later one is filtered again.
        s.fbLP = flushDenormal(s.fbLP + lpA * (rec - s.fbLP));
        rec = s.fbLP;
        if (v_.twoPoleLP) {
            s.fbLP2 = flushDenormal(s.fbLP2 + lpA * (rec - s.fbLP2));
            rec = s.fbLP2;
        }

        // Head-gap / coupling loss at the bottom.
        if (hpC != 0.0f) {
            const float y = hpC * (s.fbHPy1 + rec - s.fbHPx1);
            s.fbHPx1 = rec;
            s.fbHPy1 = flushDenormal(y);
            rec = s.fbHPy1;
        }

        if (v_.compandAmount > 0.0f) {
            // COMPRESS on the way in, the mirror of the expander above.
            const float e = std::clamp(s.env * 4.0f, 0.0f, 1.0f);
            rec *= 1.0f + v_.compandAmount * 0.5f * (1.0f - e);
        }

        // DC blocker. Asymmetric saturation and companding both leak a little
        // DC, and in a recirculating loop "a little" integrates into an offset
        // that eats headroom and eventually the whole signal.
        {
            const float y = dcCoeff_ * (s.dcY1 + rec - s.dcX1);
            s.dcX1 = rec;
            s.dcY1 = flushDenormal(y);
            rec = s.dcY1;
        }

        // --- Write, then output --------------------------------------------
        // `sanitize` is the gate: NaN and Inf become silence and the value is
        // bounded, so nothing that could poison the loop ever gets stored.
        line[s.writePos] = sanitize(rec);
        s.writePos = (s.writePos + 1) & lineMask_;
        writePos = (float)s.writePos;

        // Additive wet send — the dry is never attenuated, which is how a pedal
        // in front of an amp actually behaves and is what keeps Mix at 10 from
        // sucking the player's own note out of the mix.
        buffer[i] = dry + wet * wetOut;
    }
}

} // namespace streetrig
