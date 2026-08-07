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
    for (auto &s : slots_) s.pedal.prepare(sampleRate_, numChannels_);
    ready_ = true;
}

void PedalChain::reset() noexcept {
    for (auto &s : slots_) s.pedal.reset();
}

void PedalChain::setActiveCount(int n) noexcept {
    active_.store(std::clamp(n, 0, kMaxPedals), std::memory_order_release);
}

void PedalChain::configureSlot(int slot, int type, int character) noexcept {
    if (slot < 0 || slot >= kMaxPedals) return;
    slots_[slot].type.store(type, std::memory_order_release);
    slots_[slot].pedal.configure(character);
    // A freshly (re)voiced slot starts from clean state so a reorder/character
    // swap does not smear the previous pedal's memory into the new one.
    slots_[slot].pedal.reset();
}

void PedalChain::setParam(int slot, int field, float value) noexcept {
    if (slot < 0 || slot >= kMaxPedals) return;
    Slot &s = slots_[slot];
    switch (field) {
        case Enabled:   s.enabled.store(value >= 0.5f ? 1 : 0, std::memory_order_relaxed); break;
        case TypeField: s.type.store((int)std::lround(value), std::memory_order_relaxed);  break;
        case Character: s.pedal.configure((int)std::lround(value));                        break;
        case DriveAmt:  s.drive.store(value,  std::memory_order_relaxed);                  break;
        case Tone:      s.toneHz.store(value, std::memory_order_relaxed);                  break;
        case Level:     s.level.store(value,  std::memory_order_relaxed);                  break;
        default: break;
    }
}

void PedalChain::process(float *buffer, int n, int channel) noexcept {
    if (!ready_ || !buffer || n <= 0 || channel < 0 || channel >= numChannels_) return;
    const int count = active_.load(std::memory_order_acquire);
    for (int i = 0; i < count && i < kMaxPedals; ++i) {
        Slot &s = slots_[i];
        if (s.enabled.load(std::memory_order_relaxed) == 0) continue;
        const int type = s.type.load(std::memory_order_relaxed);
        if (type == Drive) {
            const float drive = s.drive.load(std::memory_order_relaxed);
            const float tone  = s.toneHz.load(std::memory_order_relaxed);
            const float level = s.level.load(std::memory_order_relaxed);
            s.pedal.process(buffer, n, channel, drive, tone, level);
        }
        // Transparent slots (and future not-yet-implemented categories) pass
        // through untouched — they still occupy their on-screen chain position.
    }
}

} // namespace streetrig
