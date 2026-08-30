//
//  ReverbPedal.cpp
//  StreetRig
//
//  Implementation of the Dattorro plate tank. See ReverbPedal.hpp for the
//  topology, why it was chosen over a Schroeder network, and the real-time
//  contract.
//

#include "ReverbPedal.hpp"

#include <algorithm>
#include <cmath>

namespace streetrig {

namespace {

/// Dattorro's line lengths, in samples AT HIS 29761 Hz reference rate. They are
/// scaled to the running rate in `layout()`; the ratios between them are what
/// make the tank diffuse rather than ring, so they are transcribed exactly.
constexpr double kRefRate = 29761.0;

constexpr int kInputDiffuser[4] = { 142, 107, 379, 277 };
/// { modulated all-pass, delay 1, all-pass 2, delay 2 } per branch.
constexpr int kLeftBranch[4]  = { 672, 4453, 1800, 3720 };
constexpr int kRightBranch[4] = { 908, 4217, 2656, 3163 };
/// The seven output taps, in the order they are summed (see `process`).
constexpr int kTaps[7] = { 266, 2974, 1913, 1996, 1990, 187, 1066 };

/// Line indices into `lines_` / `ChannelState::write`.
enum LineIndex : int {
    LPreDelay = 0,
    LInAP1, LInAP2, LInAP3, LInAP4,
    LmodAP, Ldelay1, LAP2, Ldelay2,
    RmodAP, Rdelay1, RAP2, Rdelay2
};

} // namespace

// MARK: - THE ONE AUDITABLE TABLE for the reverb family
//
//  Every number that decides which reverb this is, with the §11.6 listening cue
//  beside it. The 0…10 knob curves live in ParameterMap.swift; the TANK lives
//  here.

ReverbPedal::Voice ReverbPedal::voiceFor(int voicing) noexcept {
    Voice v;
    switch (voicing) {
    case Spring:
        // electro-harmonium HOLY GRAIL. A spring is a dispersive transmission
        // line: high frequencies travel faster than low ones, so a transient
        // arrives smeared into a rising chirp — the "boing". A cascade of
        // first-order all-passes in front of the tank produces that frequency-
        // dependent group delay for a dozen multiply-adds. It is a dispersion
        // FLAVOUR, not a physical spring (a real one needs a hundred-plus
        // sections or a chirp filter), and it is honestly labelled as such.
        v.preDelayMs = 18.0f;      // the drive transducer's own delay
        v.bandwidth  = 0.72f;      // springs are DARK — the transducer rolls off
        v.inDiff1    = 0.60f;      // less input diffusion: a spring is sparser
        v.inDiff2    = 0.50f;      // and more "twangy" than a plate
        v.decayDiff1 = 0.62f;
        v.decayDiff2 = 0.45f;
        v.excursion  = 5.0f;       // was 14 — the sweep that made the comb WALK.
                                   // Cue: the tail should shimmer, not sweep.
        v.modHz      = 0.90f;
        v.sizeScale  = 0.85f;
        v.decayScale = 0.94f;
        v.dispersion = 0.62f;      // cue: a picked note should "sproing", not
                                   // just echo. No boing → raise toward 0.75.
        v.trim       = 0.35f;   // was 1.05
      // Retrimmed once the sweep and the comb were gone: with the dry and
      // the tank no longer cancelling, their powers ADD, and every mode
      // came out too loud instead of too quiet. Set so switching the block
      // on moves broadband level by under a dB — see the level note in
      // `process`. Cue: reverb should add space, not volume.

        break;

    case Room:
        // The Katana's ROOM block. Small, bright, fast — the tail should be over
        // before the next chord.
        v.preDelayMs = 3.0f;
        v.bandwidth  = 0.9990f;
        v.inDiff1    = 0.72f;
        v.inDiff2    = 0.60f;
        v.decayDiff1 = 0.68f;
        v.decayDiff2 = 0.50f;
        v.excursion  = 6.0f;
        v.modHz      = 1.10f;
        v.sizeScale  = 0.55f;      // a small box: every line proportionally short
        v.decayScale = 0.80f;      // …and it dies quickly even at Decay 10
        v.trim       = 0.52f;   // was 1.0
      // FITTED ACROSS PITCHES, NOT ONE NOTE. Trimmed at a single test tone
      // these were out by 3 dB an octave away: the tank's modes line up with
      // some notes' harmonics and not others, so the level a mode adds is
      // pitch-dependent and no fixed trim nulls it everywhere. Set from the
      // AVERAGE across two notes at two mix settings. Residual is a couple of
      // dB at the extremes; see the level note in `process`.

        break;

    case Hall:
        // The Katana's HALL block. The opposite end: a long pre-delay so the dry
        // note speaks first, maximum diffusion, and the longest tail available.
        v.preDelayMs = 38.0f;     // was 32 — see the level note in `process`.
        v.bandwidth  = 0.9950f;
        v.inDiff1    = 0.78f;
        v.inDiff2    = 0.68f;
        v.decayDiff1 = 0.72f;
        v.decayDiff2 = 0.55f;
        v.excursion  = 4.0f;      // was 10 — see the crossfade note in `process`.
        v.modHz      = 0.55f;
        v.sizeScale  = 1.35f;
        v.decayScale = 1.04f;      // clamped downstream — the tank can never be
                                   // driven past the stability ceiling
        v.trim       = 0.32f;   // was 0.95
      // Retrimmed once the sweep and the comb were gone: with the dry and
      // the tank no longer cancelling, their powers ADD, and every mode
      // came out too loud instead of too quiet. Set so switching the block
      // on moves broadband level by under a dB — see the level note in
      // `process`. Cue: reverb should add space, not volume.

        break;

    case Plate:
    default:
        // VOSS Reverb (RV-6). Dattorro's published plate, unmodified: this is
        // the reference row, and the other three are stated departures from it.
        // Cue: Tone 10 should be a bright plate with NO metallic ring. If it
        // rings, the tank all-pass modulation is not running.
        v.preDelayMs = 22.0f;     // was 8 — see the level note in `process`.
        v.bandwidth  = 0.9995f;
        v.inDiff1    = 0.750f;
        v.inDiff2    = 0.625f;
        v.decayDiff1 = 0.700f;
        v.decayDiff2 = 0.500f;
        v.excursion  = 4.0f;      // was 8 — see the crossfade note in `process`.
        v.modHz      = 0.70f;
        v.sizeScale  = 1.0f;
        v.decayScale = 1.0f;
        v.trim       = 0.45f;   // was 1.0
      // Retrimmed once the sweep and the comb were gone: with the dry and
      // the tank no longer cancelling, their powers ADD, and every mode
      // came out too loud instead of too quiet. Set so switching the block
      // on moves broadband level by under a dB — see the level note in
      // `process`. Cue: reverb should add space, not volume.

        break;
    }
    return v;
}

// MARK: - Setup thread

void ReverbPedal::prepare(double sampleRate, int numChannels) noexcept {
    sampleRate_ = sampleRate > 0 ? sampleRate : 48000.0;
    numChannels_ = std::clamp(numChannels, 1, kMaxChannels);
    configure(voicing_);
    reset();
    ready_ = true;
}

void ReverbPedal::configure(int voicing) noexcept {
    voicing_ = std::clamp(voicing, 0, (int)Hall);
    v_ = voiceFor(voicing_);
    modInc_ = 2.0f * (float)M_PI * v_.modHz / (float)sampleRate_;
    // A voicing change resizes the tank, so if a span is already assigned it has
    // to be laid out again — un-publish, rebuild, re-publish, exactly as
    // `setBuffer` does. Making `configure` self-contained means callers cannot
    // get the ordering wrong.
    if (float *base = buf_.load(std::memory_order_acquire)) {
        setBuffer(base, lineFloats_);
    }
}

void ReverbPedal::reset() noexcept {
    for (int c = 0; c < kMaxChannels; ++c) {
        ChannelState &s = ch_[c];
        for (int i = 0; i < kNumLines; ++i) s.write[i] = 0;
        s.damp[0] = s.damp[1] = 0.0f;
        s.bandwidth = 0.0f;
        s.cross = 0.0f;
        for (int i = 0; i < kDispersion; ++i) { s.disperse[i] = 0.0f; s.disperseY[i] = 0.0f; }
        s.modPhase = (float)c * 1.3f;   // decorrelate the two channels' wobble
    }
}

void ReverbPedal::setBuffer(float *base, int floatsPerChannel) noexcept {
    buf_.store(nullptr, std::memory_order_release);
    lineFloats_ = floatsPerChannel;
    if (!base || floatsPerChannel < 4096) return;

    // --- Lay the tank out inside the slot's span ---------------------------
    // Every line gets a POWER-OF-TWO capacity so its pointer wraps with a mask
    // instead of a modulo (thirteen modulos per sample per channel would be the
    // single most expensive thing in the block). The rounding wastes memory, and
    // the arena has plenty: the worst case below is ~70 k of a 131 072-float
    // block at 48 kHz.
    const double scale = (sampleRate_ / kRefRate) * (double)v_.sizeScale;
    excursionSamples_ = (float)(v_.excursion * scale);
    preDelaySamples_ = std::max(1, (int)(v_.preDelayMs * 0.001 * sampleRate_));

    int cursor = 0;
    auto place = [&](int index, int length, int extra) {
        const int need = std::max(4, length) + extra;
        const int cap = nextPowerOfTwo(need);
        lines_[index].offset = cursor;
        lines_[index].mask = cap - 1;
        lines_[index].length = std::max(1, length);
        cursor += cap;
    };

    place(LPreDelay, preDelaySamples_, 4);
    for (int i = 0; i < 4; ++i) place(LInAP1 + i, (int)(kInputDiffuser[i] * scale), 4);
    const int exc = (int)excursionSamples_ + 4;
    place(LmodAP,  (int)(kLeftBranch[0]  * scale), exc);
    place(Ldelay1, (int)(kLeftBranch[1]  * scale), 4);
    place(LAP2,    (int)(kLeftBranch[2]  * scale), 4);
    place(Ldelay2, (int)(kLeftBranch[3]  * scale), 4);
    place(RmodAP,  (int)(kRightBranch[0] * scale), exc);
    place(Rdelay1, (int)(kRightBranch[1] * scale), 4);
    place(RAP2,    (int)(kRightBranch[2] * scale), 4);
    place(Rdelay2, (int)(kRightBranch[3] * scale), 4);

    // If the tank somehow does not fit (a sample rate or size scale nobody has
    // shipped), stay UN-published rather than run off the end of the arena. A
    // silent reverb is a bug report; a buffer overrun is a crash.
    if (cursor > floatsPerChannel) return;

    for (int t = 0; t < 7; ++t) tap_[t] = std::max(1, (int)(kTaps[t] * scale));

    std::fill(base, base + (size_t)kMaxChannels * (size_t)floatsPerChannel, 0.0f);
    reset();
    buf_.store(base, std::memory_order_release);
}

// MARK: - Audio thread

void ReverbPedal::process(float *buffer, int n, int channel, const float *params) noexcept {
    if (!ready_ || !buffer || n <= 0 || channel < 0 || channel >= numChannels_ || !params) return;
    float *base = buf_.load(std::memory_order_acquire);
    if (!base) return;                        // no tank assigned → pass through

    float *span = base + (size_t)channel * (size_t)lineFloats_;
    ChannelState &s = ch_[channel];

    // ---- Buffer-constant parameters -------------------------------------
    // The tank's own ceiling is 0.92 regardless of what arrives on the bus: at
    // 0.95+ the two branches, the four all-passes and the damping filter can sum
    // to a loop gain above unity on some spectra, and a reverb that grows is not
    // a long reverb, it is a broken one.
    const float decay = std::clamp(params[0] * v_.decayScale, 0.0f, 0.92f);
    const float dampHz = std::clamp(params[1], 200.0f, 18000.0f);
    const float wet = std::clamp(params[2], 0.0f, 1.0f) * v_.trim;
    const float dampA = 1.0f - std::exp(-2.0f * (float)M_PI * dampHz / (float)sampleRate_);

    const float g1 = v_.inDiff1, g2 = v_.inDiff2;
    const float gd1 = -v_.decayDiff1, gd2 = v_.decayDiff2;
    const float bw = v_.bandwidth;
    const float disp = v_.dispersion;

    // A Schroeder all-pass over one of the tank's lines, in the canonical
    // H(z) = (-g + z^-L) / (1 - g·z^-L) form. Read the line, form the recursive
    // node, write it back, return the all-pass output.
    auto allpass = [&](int idx, float x, float g) noexcept -> float {
        const Line &l = lines_[idx];
        const float delayed = span[l.offset + ((s.write[idx] - l.length) & l.mask)];
        const float w = sanitize(x + g * delayed);
        span[l.offset + s.write[idx]] = w;
        s.write[idx] = (s.write[idx] + 1) & l.mask;
        return delayed - g * w;
    };
    // The same, with a fractional (LFO-swept) read length — the tank's first
    // all-pass in each branch. Sweeping it is what stops modes standing still
    // and ringing, and it is the single feature that separates this from a
    // Schroeder reverb's metallic tail.
    auto allpassMod = [&](int idx, float x, float g, float lenOffset) noexcept -> float {
        const Line &l = lines_[idx];
        float back = (float)l.length + lenOffset;
        back = std::clamp(back, 2.0f, (float)l.mask - 2.0f);
        float p = (float)s.write[idx] - back;
        while (p < 0.0f) p += (float)(l.mask + 1);
        const float delayed = interpLinear(span + l.offset, l.mask, p);
        const float w = sanitize(x + g * delayed);
        span[l.offset + s.write[idx]] = w;
        s.write[idx] = (s.write[idx] + 1) & l.mask;
        return delayed - g * w;
    };
    // A plain delay line: read the oldest sample, write the newest.
    auto pushDelay = [&](int idx, float x) noexcept -> float {
        const Line &l = lines_[idx];
        const float out = span[l.offset + ((s.write[idx] - l.length) & l.mask)];
        span[l.offset + s.write[idx]] = sanitize(x);
        s.write[idx] = (s.write[idx] + 1) & l.mask;
        return out;
    };

    for (int i = 0; i < n; ++i) {
        const float dry = buffer[i];

        // ---- Pre-delay + input bandwidth ---------------------------------
        float x = pushDelay(LPreDelay, dry);
        s.bandwidth = flushDenormal(s.bandwidth + bw * (x - s.bandwidth));
        x = s.bandwidth;

        // ---- Spring dispersion (Holy Grail only) -------------------------
        // A chain of first-order all-passes: unity magnitude, frequency-
        // dependent group delay. Highs arrive first, lows trail — the chirp.
        if (disp != 0.0f) {
            for (int k = 0; k < kDispersion; ++k) {
                const float y = disp * x + s.disperse[k] - disp * s.disperseY[k];
                s.disperse[k] = x;
                s.disperseY[k] = flushDenormal(y);
                x = s.disperseY[k];
            }
        }

        // ---- Input diffusion: four series all-passes ---------------------
        x = allpass(LInAP1, x, g1);
        x = allpass(LInAP2, x, g1);
        x = allpass(LInAP3, x, g2);
        x = allpass(LInAP4, x, g2);

        // ---- The tank ----------------------------------------------------
        const float lfo = std::sin(s.modPhase);
        s.modPhase += modInc_;
        if (s.modPhase > 2.0f * (float)M_PI) s.modPhase -= 2.0f * (float)M_PI;
        const float exc = excursionSamples_ * lfo;

        // LEFT branch — fed by the input plus the RIGHT branch's output from the
        // previous sample. That one-sample delay in the cross path is inherent
        // to any figure-of-eight tank and is what makes it computable at all.
        float l = allpassMod(LmodAP, x + s.cross, gd1, exc);
        l = pushDelay(Ldelay1, l);
        s.damp[0] = flushDenormal(s.damp[0] + dampA * (l - s.damp[0]));
        l = s.damp[0] * decay;
        l = allpass(LAP2, l, gd2);
        l = pushDelay(Ldelay2, l);
        const float leftOut = l * decay;

        // RIGHT branch — fed by the input plus the left branch's output, this
        // sample, so the figure-of-eight closes.
        float r = allpassMod(RmodAP, x + leftOut, gd1, -exc);
        r = pushDelay(Rdelay1, r);
        s.damp[1] = flushDenormal(s.damp[1] + dampA * (r - s.damp[1]));
        r = s.damp[1] * decay;
        r = allpass(RAP2, r, gd2);
        r = pushDelay(Rdelay2, r);
        s.cross = sanitize(r * decay);

        // ---- Seven taps, scattered across four points in the tank --------
        // This is the difference between a reverb and a delay line: the output
        // is a sum of moments from all over the network, so no single echo is
        // audible as an echo. Signs are Dattorro's.
        const float y =
              tapAt(span, lines_[Rdelay1], s, Rdelay1, tap_[0])
            + tapAt(span, lines_[Rdelay1], s, Rdelay1, tap_[1])
            - tapAt(span, lines_[RAP2],    s, RAP2,    tap_[2])
            + tapAt(span, lines_[Rdelay2], s, Rdelay2, tap_[3])
            - tapAt(span, lines_[Ldelay1], s, Ldelay1, tap_[4])
            - tapAt(span, lines_[LAP2],    s, LAP2,    tap_[5])
            - tapAt(span, lines_[Ldelay2], s, Ldelay2, tap_[6]);

        // Additive wet send: the dry is never attenuated, so Mix at 10 is
        // drenched but the player's own note is still there.
        //
        // A CONSTANT-POWER CROSSFADE WAS TRIED HERE AND IS WRONG. Crossfading
        // assumes the two sides are uncorrelated and comparably loud; the tank's
        // diffuse output is far quieter than the dry, so cos/sin pulled the dry
        // down without the wet replacing it and every mode got QUIETER — Hall by
        // 3.6 dB, worse than the additive send it replaced. The level error this
        // block used to have was never the blend law; it was the SWEEP (see the
        // excursion values above), which walked a comb filter across the dry.
        //
        // `sanitize` on the way out means a poisoned tank can never reach the
        // speakers even for the one buffer it takes the guards above to clear it.
        buffer[i] = dry + wet * sanitize(0.6f * y);
    }
}

} // namespace streetrig
