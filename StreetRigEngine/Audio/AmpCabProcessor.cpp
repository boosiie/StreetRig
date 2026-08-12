//
//  AmpCabProcessor.cpp
//  StreetRig
//
//  Implementation of the amp → cab chain. See AmpCabProcessor.hpp for the
//  real-time / hand-off contract.
//

#include "AmpCabProcessor.hpp"

#include <algorithm>
#include <cmath>

namespace streetrig {

// MARK: - ToneStack (amp passive tone stack: Bass/Mid/Treble/Presence)

// First-pass voicing — center frequencies of the four bands. Ear-tune on device.
namespace {
constexpr double kBassHz     = 100.0;   // low shelf
constexpr double kMidHz      = 650.0;   // peaking
constexpr double kMidQ       = 0.70;
constexpr double kTrebleHz   = 3200.0;  // high shelf
constexpr double kPresenceHz = 6000.0;  // high shelf (upper sparkle)
constexpr double kShelfQ     = 0.70;
} // namespace

void ToneStack::prepare(double sampleRate) noexcept {
    sampleRate_ = sampleRate > 0 ? sampleRate : 48000.0;
    for (int b = 0; b < kBands; ++b) bandDB_[b] = 0.0f;
    // Populate BOTH coefficient sets with the (flat) design so the stack is unity
    // from the very first buffer, even before any tone knob is pushed. Two
    // recomputes write each set once and leave `live_` back where it started.
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

void ToneStack::recompute() noexcept {
    // Design into the INACTIVE set, then flip the atomic index (release).
    const int inactive = 1 - live_.load(std::memory_order_relaxed);
    Biquad bands[kBands] = {
        Biquad::lowShelf (sampleRate_, kBassHz,     kShelfQ, bandDB_[0]),
        Biquad::peaking  (sampleRate_, kMidHz,      kMidQ,   bandDB_[1]),
        Biquad::highShelf(sampleRate_, kTrebleHz,   kShelfQ, bandDB_[2]),
        Biquad::highShelf(sampleRate_, kPresenceHz, kShelfQ, bandDB_[3]),
    };
    for (int b = 0; b < kBands; ++b) {
        sets_[inactive].c[b] = { bands[b].b0, bands[b].b1, bands[b].b2,
                                 bands[b].a1, bands[b].a2 };
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
    convolver_.prepare(maxFrames > 0 ? maxFrames : 4096, numChannels_);
    // If a slot IR was loaded before prepare, (re)install the active one.
    if (!cabSlots_[activeCabSlot_].empty())
        setActiveCabSlot(activeCabSlot_);

    // ~5 ms one-pole smoothing coefficient for drive / makeup de-zippering.
    smoothCoeff_ = std::exp(-1.0f / (0.005f * (float)sampleRate_));

    for (int c = 0; c < kMaxChannels; ++c) { smDrive_[c] = 3.0f; smAmpOut_[c] = 1.0f; }
    ready_ = true;
}

void AmpCabProcessor::reset() noexcept {
    analog_.reset();
    tone_.reset();
    convolver_.reset();
    if (NeuralAmpModel *m = activeModel_.load(std::memory_order_acquire)) m->reset(-1);
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

void AmpCabProcessor::process(float *buffer, int n, int channel, const AmpCabParams &p) noexcept {
    if (!ready_ || !buffer || n <= 0 || channel < 0 || channel >= numChannels_) return;

    // AMP stage: preamp (neural OR analog) → TONE STACK → master/makeup.
    if (!p.ampBypass) {
        NeuralAmpModel *model = activeModel_.load(std::memory_order_acquire);
        const bool neural = p.useNeural && model && model->isValid();

        if (neural) {
            // Per-sample de-zippered drive around the neural forward pass.
            float d = smDrive_[channel];
            for (int i = 0; i < n; ++i) {
                d = p.drive + (d - p.drive) * smoothCoeff_;
                buffer[i] = model->process(buffer[i] * d, channel);
            }
            smDrive_[channel] = d;
        } else {
            // Analog fallback applies `drive` internally (into its oversampled clip).
            analog_.process(buffer, n, channel, p.drive);
            smDrive_[channel] = p.drive;   // keep the smoother tracking for later switches
        }

        // Passive tone stack (Bass/Mid/Treble/Presence) sits between the preamp
        // and the power-amp master — the classic voicing position. Flat knobs
        // ≈ unity, so it is transparent when the EQ is centered.
        tone_.process(buffer, n, channel);

        // Master / makeup gain (de-zippered).
        float a = smAmpOut_[channel];
        for (int i = 0; i < n; ++i) {
            a = p.ampOut + (a - p.ampOut) * smoothCoeff_;
            buffer[i] *= a;
        }
        smAmpOut_[channel] = a;
    }

    // CAB stage.
    if (!p.cabBypass) {
        convolver_.process(buffer, n, channel);
    }
}

} // namespace streetrig
