//
//  PedalChain.cpp
//  StreetRig
//
//  Implementation of the ordered pedalboard pool. See PedalChain.hpp.
//

#include "PedalChain.hpp"

#include <algorithm>
#include <cmath>

namespace streetrig {

void PedalChain::prepare(double sampleRate, int numChannels) {
    sampleRate_ = sampleRate > 0 ? sampleRate : 48000.0;
    numChannels_ = std::clamp(numChannels, 1, kMaxChannels);
    for (auto &s : slots_) {
        for (auto &p : s.params) p.store(0.0f, std::memory_order_relaxed);
        s.drive.prepare(sampleRate_, numChannels_);
        s.eq.prepare(sampleRate_, numChannels_);
        s.dyn.prepare(sampleRate_, numChannels_);
        s.mod.prepare(sampleRate_, numChannels_);
        s.wah.prepare(sampleRate_, numChannels_);
        s.vol.prepare(sampleRate_, numChannels_);
    }
    ready_ = true;
}

void PedalChain::reset() noexcept {
    for (auto &s : slots_) {
        s.drive.reset();
        s.eq.reset();
        s.dyn.reset();
        s.mod.reset();
        s.wah.reset();
        s.vol.reset();
    }
}

void PedalChain::setActiveCount(int n) noexcept {
    active_.store(std::clamp(n, 0, kMaxPedals), std::memory_order_release);
}

void PedalChain::configureSlot(int slot, int type, int voicing) noexcept {
    if (slot < 0 || slot >= kMaxPedals) return;
    Slot &s = slots_[slot];
    s.type.store(type, std::memory_order_release);
    s.voicing.store(voicing, std::memory_order_release);
    // (Re)voice + clear the engine that matches the new type so a reorder / type
    // swap does not smear the previous pedal's memory into the new one.
    switch (type) {
        case Drive:      s.drive.configure(voicing);                         s.drive.reset(); break;
        case Eq:         s.eq.configure(voicing);                            s.eq.reset();    break;
        case Compressor: s.dyn.configure(DynamicsPedal::Compressor);         s.dyn.reset();   break;
        case Gate:       s.dyn.configure(DynamicsPedal::Gate);               s.dyn.reset();   break;
        case Modulation: s.mod.configure(voicing);                           s.mod.reset();   break;
        case Wah:        s.wah.configure(voicing);                           s.wah.reset();   break;
        case Volume:     s.vol.configure(voicing);                           s.vol.reset();   break;
        default:         break;   // Transparent — nothing to voice
    }
}

void PedalChain::setParam(int slot, int field, float value) noexcept {
    if (slot < 0 || slot >= kMaxPedals) return;
    Slot &s = slots_[slot];
    switch (field) {
        case Enabled:   s.enabled.store(value >= 0.5f ? 1 : 0, std::memory_order_relaxed); break;
        case TypeField: s.type.store((int)std::lround(value), std::memory_order_relaxed);  break;
        // Voicing is normally applied structurally via configureSlot (under the
        // barrier); store it here so a live push stays coherent, but do NOT
        // re-voice from the audio-adjacent bus.
        case Voicing:   s.voicing.store((int)std::lround(value), std::memory_order_relaxed); break;
        default:
            if (field >= Param0 && field < Param0 + kMaxParams)
                s.params[field - Param0].store(value, std::memory_order_relaxed);
            break;
    }
}

void PedalChain::process(float *buffer, int n, int channel) noexcept {
    if (!ready_ || !buffer || n <= 0 || channel < 0 || channel >= numChannels_) return;
    const int count = active_.load(std::memory_order_acquire);
    for (int i = 0; i < count && i < kMaxPedals; ++i) {
        Slot &s = slots_[i];
        if (s.enabled.load(std::memory_order_relaxed) == 0) continue;
        const int type = s.type.load(std::memory_order_relaxed);

        // Snapshot the generic params once (audio thread reads only).
        float p[kMaxParams];
        for (int k = 0; k < kMaxParams; ++k) p[k] = s.params[k].load(std::memory_order_relaxed);

        switch (type) {
            case Drive:      s.drive.process(buffer, n, channel, p[0], p[1], p[2]); break;
            case Eq:         s.eq.process(buffer, n, channel, p);                   break;
            case Compressor:
            case Gate:       s.dyn.process(buffer, n, channel, p);                  break;
            case Modulation: s.mod.process(buffer, n, channel, p);                  break;
            case Wah:        s.wah.process(buffer, n, channel, p);                  break;
            case Volume:     s.vol.process(buffer, n, channel, p);                  break;
            default:         break;   // Transparent (and not-yet-implemented families)
        }
    }
}

} // namespace streetrig
