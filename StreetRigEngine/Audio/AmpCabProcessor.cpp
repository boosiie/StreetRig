//
//  AmpCabProcessor.cpp
//  StreetRig
//
//  Implementation of the preamp → tone stack → power amp → cab chain. See
//  AmpCabProcessor.hpp for the real-time / hand-off contract and for why each
//  stage is shaped the way it is.
//

#include "AmpCabProcessor.hpp"

#include <algorithm>
#include <cmath>

namespace streetrig {

// MARK: - ToneStack (the amp's passive tone stack, per-amp voiced)

void ToneStack::prepare(double sampleRate) noexcept {
    sampleRate_ = sampleRate > 0 ? sampleRate : 48000.0;
    for (int b = 0; b < kBands; ++b) bandDB_[b] = 0.0f;
    // Boot on the Legacy voicing so a stack that is never configured behaves
    // exactly as it did before profiles existed.
    v_ = profileFor(Legacy).tone;
    insertionGain_ = 1.0f;
    for (int b = 0; b < kBands; ++b) bandActive_[b] = true;
    // Populate BOTH coefficient sets so the stack is correct from the very first
    // buffer, even before any tone knob is pushed. Two recomputes write each set
    // once and leave `live_` back where it started.
    live_.store(0, std::memory_order_relaxed);
    recompute();   // writes sets_[1], flips live_ → 1
    recompute();   // writes sets_[0], flips live_ → 0
    reset();
}

void ToneStack::reset() noexcept {
    for (int c = 0; c < kMaxChannels; ++c)
        for (int b = 0; b < kBands; ++b)
            st_[c][b] = {0, 0, 0, 0};
}

void ToneStack::configure(const ToneStackVoicing &voicing) noexcept {
    v_ = voicing;
    // A band with no range AND no noon offset is not part of this amp — skip it
    // rather than run it flat. Every profiled amp skips band 3, because presence
    // is a power-amp control for them; Legacy keeps it, because for Legacy the
    // presence control IS tone band 3.
    for (int b = 0; b < kBands; ++b) {
        bandActive_[b] = (v_.band[b].rangeScale != 0.0f) || (v_.band[b].noonDB != 0.0f);
    }
    insertionGain_ = (v_.insertionDB != 0.0f)
        ? std::pow(10.0f, v_.insertionDB / 20.0f) : 1.0f;
    recompute();
    recompute();   // both sets, so a hot-swap cannot leave a stale one live
}

void ToneStack::recompute() noexcept {
    // Design into the INACTIVE set, then flip the atomic index (release).
    const int inactive = 1 - live_.load(std::memory_order_relaxed);

    // THE PER-AMP TRANSFORM, in one place and on the main thread:
    //   effective dB = noonDB + knob dB × rangeScale
    // plus the Fandor interaction — turning Bass UP deepens the mid notch,
    // because the mid pot's resistance below its wiper adds to the treble
    // filter's. A negative `rangeScale` simply makes the knob run backwards,
    // which is what a Vane Cut control actually does; no special case needed.
    float dB[kBands];
    for (int b = 0; b < kBands; ++b) {
        dB[b] = v_.band[b].noonDB + bandDB_[b] * v_.band[b].rangeScale;
    }
    if (v_.bassEatsMid != 0.0f) {
        const float bassBoost = bandDB_[0] > 0.0f ? bandDB_[0] : 0.0f;
        dB[1] -= v_.bassEatsMid * bassBoost;
    }

    for (int b = 0; b < kBands; ++b) {
        if (!bandActive_[b]) {
            sets_[inactive].c[b] = {1, 0, 0, 0, 0};   // identity; the loop skips it anyway
            continue;
        }
        const ToneBand &band = v_.band[b];
        Biquad q;
        switch (band.shape) {
        case ToneShape::LowShelf:  q = Biquad::lowShelf (sampleRate_, band.hz, band.q, dB[b]); break;
        case ToneShape::Peak:      q = Biquad::peaking  (sampleRate_, band.hz, band.q, dB[b]); break;
        case ToneShape::HighShelf: q = Biquad::highShelf(sampleRate_, band.hz, band.q, dB[b]); break;
        }
        sets_[inactive].c[b] = { q.b0, q.b1, q.b2, q.a1, q.a2 };
    }
    live_.store(inactive, std::memory_order_release);
}

void ToneStack::setBandDB(int band, float dB) noexcept {
    if (band < 0 || band >= kBands) return;
    bandDB_[band] = std::clamp(dB, -18.0f, 18.0f);
    recompute();
}

void ToneStack::process(float *buffer, int n, int channel) noexcept {
    if (!buffer || n <= 0 || channel < 0 || channel >= kMaxChannels) return;
    const CoeffSet &set = sets_[live_.load(std::memory_order_acquire)];
    for (int b = 0; b < kBands; ++b) {
        if (!bandActive_[b]) continue;
        const Coeffs &c = set.c[b];
        BiquadState &s = st_[channel][b];
        float x1 = s.x1, x2 = s.x2, y1 = s.y1, y2 = s.y2;
        for (int i = 0; i < n; ++i) {
            const float x = buffer[i];
            const float y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2;
            x2 = x1; x1 = x; y2 = y1; y1 = y;
            buffer[i] = y;
        }
        s.x1 = x1; s.x2 = x2; s.y1 = y1; s.y2 = y2;
    }
    // The passive network's insertion loss. It is recovered as makeup AFTER the
    // power amp (see PowerAmp::configure), so the only thing it changes is how
    // hard the output stage is driven — which is its whole physical role.
    if (insertionGain_ != 1.0f) {
        const float g = insertionGain_;
        for (int i = 0; i < n; ++i) buffer[i] *= g;
    }
}

// MARK: - PowerAmp

namespace {

/// THE POWER CONTROL, derived. Lowering the wattage lowers the voltage swing the
/// output stage can produce, so the SAME signal hits clipping sooner: it is an
/// attenuator on the output stage, not a gain on the output. Everything below is
/// a function of the one continuous bus value (`headroomScale`), so switching
/// 100 W → 0.5 W is a ~5 ms de-zippered glide rather than a fade/park rebuild —
/// which matters, because on a real Kabuto the switch is instant and silent and
/// a rebuild would be audibly WORSE than the hardware.
///
/// Quadratics, not powers, so the audio thread evaluates no transcendental. They
/// pass exactly through the three specified settings:
///
///   Setting | headroomScale | sagScale | otLowScale | postMakeup
///   --------|---------------|----------|------------|-----------
///    100 W  |     1.00      |   1.00   |    1.00    |    1.00
///     50 W  |     0.70      |   1.15   |    1.05    |    1.43
///    0.5 W  |     0.14      |   1.60   |    1.25    |    7.14
///
/// The 0.5 W row is deliberately conservative: physically it is −23 dB of
/// headroom and we ship −17 dB. A real Kabuto at 0.5 W is heavily power-saturated
/// but still musical, because the clipping is soft and the OT plus speaker filter
/// the result — our first pass errs toward musical.
/// Cue: 0.5 W should sound like a small CRANKED AMP, not a fuzz pedal. Sounds
/// like a fuzz → raise `headroomScale` toward 0.25. Indistinguishable from 50 W →
/// lower it toward the physical 0.071.
inline float sagScaleFor(float s) noexcept {
    const float u = 1.0f - s;
    return 1.0f + 0.394f * u + 0.353f * u * u;      // small supplies droop harder
}
inline float otLowScaleFor(float s) noexcept {
    const float u = 1.0f - s;
    return 1.0f + 0.1002f * u + 0.2215f * u * u;    // small OTs lose bass when pushed
}
/// `postMakeup` exists because this is a MODEL, not an attenuator on a real
/// speaker: the player should hear the saturation change, not the volume
/// collapse. Clamped at 8 so 0.5 W is still modestly quieter than 100 W, which
/// is what a player expects.
inline float postMakeupFor(float s) noexcept {
    if (s <= 0.125f) return 8.0f;
    return 1.0f / s;
}

} // namespace

void PowerAmp::prepare(double sampleRate) noexcept {
    sampleRate_ = sampleRate > 0 ? sampleRate : 48000.0;

    // Windowed-sinc anti-imaging / anti-aliasing FIR for the 2× oversampler.
    // Cutoff (cycles/sample at OS rate) just below base Nyquist = 1/(2·2) = 0.25;
    // 0.22 leaves a transition band. Hann window, normalized to unity DC gain.
    const double fc = 0.22;
    const int N = kFirTaps;
    const double center = (N - 1) / 2.0;
    double sum = 0.0;
    double taps[kFirTaps];
    for (int k = 0; k < N; ++k) {
        const double m = k - center;
        const double sinc = (m == 0.0) ? (2.0 * fc)
                                       : std::sin(2.0 * M_PI * fc * m) / (M_PI * m);
        const double win = 0.5 - 0.5 * std::cos(2.0 * M_PI * k / (N - 1));   // Hann
        taps[k] = sinc * win;
        sum += taps[k];
    }
    for (int k = 0; k < N; ++k) fir_[k] = float(taps[k] / sum);

    smoothCoeff_ = std::exp(-1.0f / (0.005f * (float)sampleRate_));   // ~5 ms de-zip
    configure(profileFor(Legacy));    // boots to a total no-op
    reset();
}

void PowerAmp::reset() noexcept {
    for (int c = 0; c < kMaxChannels; ++c) {
        ch_[c].nfb = {0, 0, 0, 0};
        ch_[c].presence = {0, 0, 0, 0};
        ch_[c].otHPx1 = ch_[c].otHPy1 = 0.0f;
        ch_[c].otLPy = 0.0f;
        ch_[c].sagEnv = 0.0f;
        std::fill(ch_[c].upHist, ch_[c].upHist + kPhaseTaps, 0.0f);
        std::fill(ch_[c].downHist, ch_[c].downHist + kFirTaps, 0.0f);
        ch_[c].upPos = 0;
        ch_[c].downPos = 0;
        ch_[c].smVolume = 1.0f;
        ch_[c].smPower = 1.0f;
        ch_[c].smPrimed = false;
    }
}

void PowerAmp::configure(const AmpProfile &profile) noexcept {
    const PowerAmpVoicing &v = profile.power;

    headroom_ = v.headroom > 1.0e-4f ? v.headroom : 1.0e-4f;
    clip_     = v.clip;
    asym_     = v.asym;
    hasClip_  = (v.clip != AmpClip::Clean);
    clipOffset_ = hasClip_ ? ampShapeRaw(0.0f, v.clip, v.asym) : 0.0f;

    sagDepth_ = std::clamp(v.sagDepth, 0.0f, 1.0f);
    sagA_ = (sagDepth_ > 0.0f && v.sagTauMs > 0.0)
        ? float(1.0 - std::exp(-1000.0 / (v.sagTauMs * sampleRate_))) : 0.0f;
    if (sagA_ <= 0.0f) sagDepth_ = 0.0f;

    hasNfb_ = (v.nfbHz > 0.0 && v.nfbDB != 0.0f && v.nfbHz < sampleRate_ * 0.45);
    nfb_ = hasNfb_ ? coeffsOf(Biquad::highShelf(sampleRate_, v.nfbHz, 0.707, v.nfbDB))
                   : Coeffs{1, 0, 0, 0, 0};

    presenceHz_    = v.presenceHz > 0.0 ? v.presenceHz : 3500.0;
    presenceScale_ = v.presenceScale;

    hasOtHP_ = (v.otLowHz > 0.0 && v.otLowHz < sampleRate_ * 0.45);
    // Stored as the ANGULAR corner, so the power control can scale it per buffer
    // with a multiply instead of an audio-thread exp(). For fc ≤ ~150 Hz at
    // 48 kHz the one-pole coefficient exp(−ω) ≈ 1 − ω to better than 0.1 %, which
    // is far inside the tuning tolerance of the value itself.
    otHPw_ = hasOtHP_ ? float(2.0 * M_PI * v.otLowHz / sampleRate_) : 0.0f;
    // Above the band, a "rolloff" is not a filter — skip it rather than design a
    // one-pole whose coefficient has saturated at 1 (see AnalogAmp::configure).
    hasOtLP_ = (v.otHighHz > 0.0 && v.otHighHz < sampleRate_ * 0.45);
    otLPa_ = hasOtLP_ ? float(1.0 - std::exp(-2.0 * M_PI * v.otHighHz / sampleRate_)) : 0.0f;

    // outTrim levels the profiles against each other; the second term gives back
    // the tone stack's insertion loss AFTER the nonlinearity, so the loss changed
    // how hard the stage was driven without making the amp quiet.
    const float insertionMakeup = (profile.tone.insertionDB != 0.0f)
        ? std::pow(10.0f, -profile.tone.insertionDB / 20.0f) : 1.0f;
    staticTrim_ = profile.outTrim * insertionMakeup;

    presenceLive_.store(0, std::memory_order_relaxed);
    recomputePresence();
    recomputePresence();
}

void PowerAmp::recomputePresence() noexcept {
    const int inactive = 1 - presenceLive_.load(std::memory_order_relaxed);
    const float dB = presenceDB_ * presenceScale_;
    presenceSets_[inactive] = (presenceScale_ != 0.0f && dB != 0.0f)
        ? coeffsOf(Biquad::highShelf(sampleRate_, presenceHz_, 0.707, dB))
        : Coeffs{1, 0, 0, 0, 0};
    presenceLive_.store(inactive, std::memory_order_release);
}

void PowerAmp::setPresenceDB(float dB) noexcept {
    presenceDB_ = std::clamp(dB, -18.0f, 18.0f);
    recomputePresence();
}

void PowerAmp::process(float *buffer, int n, int channel,
                       float volume, float powerScale) noexcept {
    if (!buffer || n <= 0 || channel < 0 || channel >= kMaxChannels) return;
    ChannelState &s = ch_[channel];

    const bool runPresence = (presenceScale_ != 0.0f);
    const Coeffs &pres = presenceSets_[presenceLive_.load(std::memory_order_acquire)];

    // Nothing to do at all — the Legacy profile's entire output stage. Checked
    // against the SMOOTHED values as well as the targets, so a stage that is
    // mid-glide still runs until it has actually arrived.
    if (!hasClip_ && !hasNfb_ && !runPresence && !hasOtHP_ && !hasOtLP_
        && sagDepth_ == 0.0f && staticTrim_ == 1.0f
        && volume == 1.0f && powerScale == 1.0f
        && s.smVolume == 1.0f && s.smPower == 1.0f) {
        return;
    }

    const float ps = std::clamp(powerScale, 0.02f, 4.0f);
    const bool  runSag = (sagDepth_ > 0.0f);

    // FIRST BUFFER SINCE RESET: snap, do not glide. See `ChannelState::smPrimed`.
    if (!s.smPrimed) {
        s.smVolume = volume;
        s.smPower  = ps;
        s.smPrimed = true;
    }

    float vol = s.smVolume, pw = s.smPower;

    for (int i = 0; i < n; ++i) {
        vol = volume + (vol - volume) * smoothCoeff_;
        pw  = ps     + (pw  - ps)     * smoothCoeff_;

        // EVERY derived scalar comes from the SMOOTHED power value, per sample.
        // Deriving the makeup from the target while the headroom still glides
        // would hand a 100 W-sized signal a 0.5 W-sized makeup for the length of
        // the glide — a 17 dB spike exactly at the moment the switch is thrown,
        // which is the click this control was designed to avoid. They have to
        // move together or they are worse than not moving at all. None of these
        // is a transcendental; the OT coefficient in particular is a linearized
        // one-pole precisely so it can be re-derived here.
        const float pwLim     = pw < 1.0f ? pw : 1.0f;
        const float sagAmount = sagDepth_ * sagScaleFor(pwLim);
        const float trim      = staticTrim_ * postMakeupFor(pw);
        const float otHPc     = hasOtHP_
            ? std::clamp(1.0f - otLowScaleFor(pwLim) * otHPw_, 0.0f, 0.99999f) : 0.0f;

        float x = buffer[i] * vol;

        // The global negative-feedback loop: less gain, tighter lows, darker top.
        if (hasNfb_)    x = runBiquad(nfb_, s.nfb, x);
        // Presence lives INSIDE that loop — a frequency-selective reduction of
        // feedback, i.e. a frequency-selective gain increase.
        if (runPresence) x = runBiquad(pres, s.presence, x);

        if (hasClip_) {
            // Sag: the supply droops under load and recovers with a time
            // constant, so a hard chord ducks and blooms back. It lowers the
            // headroom rather than the signal, which is why it sounds like an
            // amp running out of breath and not like a compressor.
            float h = headroom_ * pw;
            if (runSag) {
                const float a = std::fabs(x);
                s.sagEnv += sagA_ * (a - s.sagEnv);
                h *= 1.0f - sagAmount * (s.sagEnv / (s.sagEnv + h + 1.0e-6f));
            }
            if (h < 1.0e-4f) h = 1.0e-4f;
            const float invH = 1.0f / h;
            // Above ~2.0 of headroom the stage physically never reaches clipping,
            // so the shape is the identity — but the OVERSAMPLER KEEPS RUNNING,
            // deliberately. Its group delay must not appear and disappear as the
            // power control sweeps, or the switch would click for exactly the
            // amps this saving was meant to help.
            const bool shapeIt = (h <= 2.0f);

            s.upHist[s.upPos] = x;
            float decimated = 0.0f;
            for (int m = 0; m < kOversample; ++m) {
                float up = 0.0f;
                int idx = s.upPos;
                for (int j = 0; j < kPhaseTaps; ++j) {
                    up += fir_[m + j * kOversample] * s.upHist[idx];
                    idx = (idx == 0) ? (kPhaseTaps - 1) : (idx - 1);
                }
                up *= float(kOversample);
                // h · shape(x / h): transparent below the headroom, saturating
                // above it. Every AmpClip family has unit slope at the origin,
                // which is what makes that identity hold.
                const float y = shapeIt ? h * ampShape(up * invH, clip_, asym_, clipOffset_) : up;
                s.downHist[s.downPos] = y;
                s.downPos = (s.downPos + 1) % kFirTaps;
            }
            {
                int idx = (s.downPos == 0) ? (kFirTaps - 1) : (s.downPos - 1);
                for (int k = 0; k < kFirTaps; ++k) {
                    decimated += fir_[k] * s.downHist[idx];
                    idx = (idx == 0) ? (kFirTaps - 1) : (idx - 1);
                }
            }
            s.upPos = (s.upPos + 1) % kPhaseTaps;
            x = decimated;
        }

        // Output transformer: two first-order rolloffs. The LF corner rides the
        // power control — a small OT under load loses low end.
        if (hasOtHP_) {
            const float y = otHPc * (s.otHPy1 + x - s.otHPx1);
            s.otHPx1 = x; s.otHPy1 = y; x = y;
        }
        if (hasOtLP_) {
            s.otLPy += otLPa_ * (x - s.otLPy);
            x = s.otLPy;
        }

        buffer[i] = x * trim;
    }

    s.smVolume = vol;
    s.smPower = pw;
}

// MARK: - AmpCabProcessor

AmpCabProcessor::~AmpCabProcessor() {
    delete activeModel_.exchange(nullptr, std::memory_order_acq_rel);
    delete retireModel_.exchange(nullptr, std::memory_order_acq_rel);
}

void AmpCabProcessor::prepare(double sampleRate, int numChannels, int maxFrames) {
    sampleRate_ = sampleRate > 0 ? sampleRate : 48000.0;
    numChannels_ = numChannels < 1 ? 1 : (numChannels > kMaxChannels ? kMaxChannels : numChannels);

    analog_.prepare(sampleRate_, numChannels_);
    tone_.prepare(sampleRate_);
    power_.prepare(sampleRate_);
    convolver_.prepare(maxFrames > 0 ? maxFrames : 4096, numChannels_);
    // If a slot IR was loaded before prepare, (re)install the active one.
    if (!cabSlots_[activeCabSlot_].empty())
        setActiveCabSlot(activeCabSlot_);

    // ~5 ms one-pole smoothing coefficient for drive / makeup de-zippering.
    smoothCoeff_ = std::exp(-1.0f / (0.005f * (float)sampleRate_));

    for (int c = 0; c < kMaxChannels; ++c) {
        smDrive_[c] = 3.0f; smAmpOut_[c] = 1.0f; smPrimed_[c] = false;
    }
    // Re-apply whatever profile was selected before the format change, so a
    // sample-rate switch never silently reverts the amp to Legacy.
    configureAmp(profileId_);
    ready_ = true;
}

void AmpCabProcessor::reset() noexcept {
    // UN-PRIME, so the first buffer after a reset SNAPS the de-zippers to
    // whatever the rig is set to rather than gliding into it from the boot
    // values. See `smPrimed_`.
    for (int c = 0; c < kMaxChannels; ++c) smPrimed_[c] = false;
    analog_.reset();
    tone_.reset();
    power_.reset();
    convolver_.reset();
    if (NeuralAmpModel *m = activeModel_.load(std::memory_order_acquire)) m->reset(-1);
}

void AmpCabProcessor::configureAmp(int voicing) noexcept {
    const AmpProfile p = profileFor(voicing);
    profileId_ = voicing;
    profileBypassCab_ = p.bypassCab;
    analog_.configure(p);
    tone_.configure(p.tone);
    power_.configure(p);
    // Re-route the presence knob: the profile decides whether it is tone band 3
    // or the power-amp shelf, so the value has to be re-applied on every change.
    setPresenceDB(presenceDB_);
}

void AmpCabProcessor::setPresenceDB(float dB) noexcept {
    presenceDB_ = dB;
    if (power_.ownsPresence()) {
        power_.setPresenceDB(dB);
        tone_.setBandDB(3, 0.0f);      // never applied twice
    } else {
        power_.setPresenceDB(0.0f);
        tone_.setBandDB(3, dB);
    }
}

void AmpCabProcessor::installNeuralModel(NeuralAmpModel *model) noexcept {
    // Swap in the new model; free whatever was retired a full generation ago
    // (the render thread reads `activeModel_` fresh each buffer, so a pointer
    // replaced two installs ago is guaranteed no longer in use).
    NeuralAmpModel *old = activeModel_.exchange(model, std::memory_order_acq_rel);
    NeuralAmpModel *toFree = retireModel_.exchange(old, std::memory_order_acq_rel);
    delete toFree;
}

void AmpCabProcessor::loadCabIRSlot(int slot, const float *samples, int count) noexcept {
    if (slot < 0 || slot >= kNumCabSlots || !samples || count <= 0) return;
    cabSlots_[slot].assign(samples, samples + count);
}

void AmpCabProcessor::setActiveCabSlot(int slot) noexcept {
    if (slot < 0 || slot >= kNumCabSlots) return;
    activeCabSlot_ = slot;
    const auto &ir = cabSlots_[slot];
    if (ir.empty()) convolver_.setIR(nullptr, 0);          // transparent
    else            convolver_.setIR(ir.data(), (int)ir.size());
}

int AmpCabProcessor::cabIRLength(int slot) const noexcept {
    if (slot < 0 || slot >= kNumCabSlots) return 0;
    return (int)cabSlots_[slot].size();
}

void AmpCabProcessor::processPreamp(float *buffer, int n, int channel, const AmpCabParams &p) noexcept {
    if (!ready_ || !buffer || n <= 0 || channel < 0 || channel >= numChannels_) return;
    if (p.ampBypass) return;

    NeuralAmpModel *model = activeModel_.load(std::memory_order_acquire);
    const bool neural = p.useNeural && model && model->isValid();

    // FIRST BUFFER SINCE RESET: snap, do not glide. See `smPrimed_`.
    if (!smPrimed_[channel]) {
        smDrive_[channel]  = p.drive;
        smAmpOut_[channel] = p.ampOut;
        smPrimed_[channel] = true;
    }

    if (neural) {
        // A capture replaces the PREAMP CASCADE only; the profile's tone stack,
        // power amp and cab pairing below still apply.
        float d = smDrive_[channel];
        for (int i = 0; i < n; ++i) {
            d = p.drive + (d - p.drive) * smoothCoeff_;
            buffer[i] = model->process(buffer[i] * d, channel);
        }
        smDrive_[channel] = d;
    } else {
        // The profiled cascade applies `drive` internally, into stage 0's clip.
        analog_.process(buffer, n, channel, p.drive);
        smDrive_[channel] = p.drive;   // keep the smoother tracking for later switches
    }

    // Passive tone stack, between the preamp and the power amp — the classic
    // voicing position, and where a real amp's FX loop taps off.
    tone_.process(buffer, n, channel);
}

void AmpCabProcessor::processPowerAmp(float *buffer, int n, int channel, const AmpCabParams &p) noexcept {
    if (!ready_ || !buffer || n <= 0 || channel < 0 || channel >= numChannels_) return;
    if (p.ampBypass) return;

    power_.process(buffer, n, channel, p.ampVolume, p.powerScale);

    // Master / makeup gain (de-zippered). It stays HERE, ahead of the cab, rather
    // than after it: the convolver is linear, so the two placements are
    // mathematically identical, and keeping it put is what lets the Legacy
    // voicing null bit-exactly against the pre-profile engine.
    //
    // AND IT IS THE OUTPUT AUTHORITY, which is worth stating because the obvious
    // reading of this function is that it is not. The power amp above is driven
    // by ampVolume, not by Master; Master is applied AFTER the saturation as a
    // plain multiply, so it scales a finished signal and cannot change how hard
    // the valves are working. With `ParameterMap.ampMaster` now reaching 0.0 at
    // knob zero, `buffer[i] *= a` takes the whole rig to silence no matter where
    // Volume, the FX blocks or the boost are set.
    //
    // MOVING IT LATER WAS CONSIDERED AND REJECTED. The only stage it does not
    // already govern is the POST pedal span, which is empty in every stock rig;
    // relocating it there would buy that one case and cost the bit-exact Legacy
    // null above. If a POST-span pedal ever ships with makeup gain of its own,
    // revisit — that is the case that would justify the move.
    float a = smAmpOut_[channel];
    for (int i = 0; i < n; ++i) {
        a = p.ampOut + (a - p.ampOut) * smoothCoeff_;
        buffer[i] *= a;
    }
    smAmpOut_[channel] = a;
}

void AmpCabProcessor::processCab(float *buffer, int n, int channel, const AmpCabParams &p) noexcept {
    if (!ready_ || !buffer || n <= 0 || channel < 0 || channel >= numChannels_) return;
    if (p.cabBypass) return;
    convolver_.process(buffer, n, channel);
}

void AmpCabProcessor::process(float *buffer, int n, int channel, const AmpCabParams &p) noexcept {
    processPreamp(buffer, n, channel, p);
    processPowerAmp(buffer, n, channel, p);
    processCab(buffer, n, channel, p);
}

} // namespace streetrig
