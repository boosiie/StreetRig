//
//  PedalChain.cpp
//  StreetRig
//
//  Implementation of the ordered pedalboard pool, its preallocated arena and the
//  three-span split. See PedalChain.hpp.
//

#include "PedalChain.hpp"

#include <algorithm>
#include <cmath>

namespace streetrig {

void PedalChain::prepare(double sampleRate, int numChannels) {
    sampleRate_ = sampleRate > 0 ? sampleRate : 48000.0;
    numChannels_ = std::clamp(numChannels, 1, kMaxChannels);

    // HAND BACK EVERY SPAN BEFORE THE ARENA MOVES. `prepare` runs again on every
    // stream-format change, and by then a slot may already hold a delay or a
    // reverb pointing into the CURRENT arena. Re-sizing the vector below can
    // relocate it, so any engine still holding a pointer would be holding a
    // dangling one — and `ReverbPedal::configure` re-lays-out through whatever
    // pointer it has, which would write into freed memory. Un-publishing first
    // costs two atomic stores per slot and removes the hazard entirely.
    for (auto &s : slots_) {
        s.delay.setBuffer(nullptr, 0);
        s.reverb.setBuffer(nullptr, 0);
    }

    // THE ONE ALLOCATION. Sized for the worst case — every slot holding a
    // full-length stereo delay — because sizing it for anything less would mean
    // deciding, on the audio thread, that a slot cannot become a delay. A
    // power-of-two block lets every ring pointer wrap with a mask.
    //
    // `assign` both sizes and zeroes; it is the only place this vector ever
    // changes size, and it runs on the setup thread. Note `kMaxChannels`, not
    // `numChannels_`: the block layout must not move if the stream later opens
    // in stereo after being prepared in mono.
    blockFloats_ = nextPowerOfTwo((int)std::ceil(kMaxDelaySeconds * sampleRate_));
    arena_.assign((size_t)kMaxPedals * (size_t)kMaxChannels * (size_t)blockFloats_, 0.0f);

    for (int i = 0; i < kMaxPedals; ++i) {
        Slot &s = slots_[i];
        for (auto &p : s.params) p.store(0.0f, std::memory_order_relaxed);
        s.drive.prepare(sampleRate_, numChannels_);
        s.eq.prepare(sampleRate_, numChannels_);
        s.dyn.prepare(sampleRate_, numChannels_);
        s.mod.prepare(sampleRate_, numChannels_);
        s.wah.prepare(sampleRate_, numChannels_);
        s.vol.prepare(sampleRate_, numChannels_);
        s.delay.prepare(sampleRate_, numChannels_);
        s.reverb.prepare(sampleRate_, numChannels_);
        // A slot that is ALREADY a time-based block when the stream format
        // changes must be re-handed its (now differently sized) span, or it
        // would keep reading a stale length. Re-running configureSlot with the
        // slot's own live type does exactly that.
        const int type = s.type.load(std::memory_order_relaxed);
        if (type == Delay || type == Reverb) {
            configureSlot(i, type, s.voicing.load(std::memory_order_relaxed));
        }
    }
    ready_ = true;
}

float *PedalChain::arenaBlock(int slot) noexcept {
    if (arena_.empty() || blockFloats_ <= 0 || slot < 0 || slot >= kMaxPedals) return nullptr;
    return arena_.data() + (size_t)slot * (size_t)kMaxChannels * (size_t)blockFloats_;
}

void PedalChain::reset() noexcept {
    for (int i = 0; i < kMaxPedals; ++i) {
        Slot &s = slots_[i];
        s.drive.reset();
        s.eq.reset();
        s.dyn.reset();
        s.mod.reset();
        s.wah.reset();
        s.vol.reset();
        s.delay.reset();
        s.reverb.reset();
        // Clearing the engines' scalar state is not enough for the two families
        // whose state IS the buffer: a reset that left the line full would let a
        // removed delay's tail reappear the moment the slot ran again. Only the
        // blocks actually in use are cleared — zeroing the whole 8 MB arena on
        // every structural swap would put a millisecond of memset in a path that
        // runs on every footswitch-adjacent rebuild, for no benefit.
        const int type = s.type.load(std::memory_order_relaxed);
        if (type == Delay || type == Reverb) {
            if (float *block = arenaBlock(i)) {
                std::fill(block, block + (size_t)kMaxChannels * (size_t)blockFloats_, 0.0f);
            }
        }
    }
}

void PedalChain::setActiveCount(int n) noexcept {
    active_.store(std::clamp(n, 0, kMaxPedals), std::memory_order_release);
}

void PedalChain::setSplits(int splitPre, int splitPost) noexcept {
    const int pre = std::clamp(splitPre, 0, kMaxPedals);
    const int post = std::clamp(splitPost, pre, kMaxPedals);
    splitPre_.store(pre, std::memory_order_release);
    splitPost_.store(post, std::memory_order_release);
}

void PedalChain::configureSlot(int slot, int type, int voicing) noexcept {
    if (slot < 0 || slot >= kMaxPedals) return;
    Slot &s = slots_[slot];
    s.type.store(type, std::memory_order_release);
    s.voicing.store(voicing, std::memory_order_release);
    // (Re)voice + clear the engine that matches the new type so a reorder / type
    // swap does not smear the previous pedal's memory into the new one. For the
    // two time-based families the third step is handing over the arena block:
    // `configure` first (the reverb sizes its tank from the voicing), then
    // `setBuffer`, which zeroes the span and publishes the pointer with a
    // release store. A slot that is NOT one of them un-publishes its span, so a
    // parked engine can never be left pointing into memory another type is now
    // using.
    switch (type) {
        case Drive:      s.drive.configure(voicing);                         s.drive.reset(); break;
        case Eq:         s.eq.configure(voicing);                            s.eq.reset();    break;
        case Compressor: s.dyn.configure(DynamicsPedal::Compressor);         s.dyn.reset();   break;
        case Gate:       s.dyn.configure(DynamicsPedal::Gate);               s.dyn.reset();   break;
        case Modulation: s.mod.configure(voicing);                           s.mod.reset();   break;
        case Wah:        s.wah.configure(voicing);                           s.wah.reset();   break;
        case Volume:     s.vol.configure(voicing);                           s.vol.reset();   break;
        case Delay:
            s.reverb.setBuffer(nullptr, 0);
            s.delay.configure(voicing);
            s.delay.setBuffer(arenaBlock(slot), blockFloats_);
            break;
        case Reverb:
            s.delay.setBuffer(nullptr, 0);
            s.reverb.configure(voicing);
            s.reverb.setBuffer(arenaBlock(slot), blockFloats_);
            break;
        default:
            s.delay.setBuffer(nullptr, 0);
            s.reverb.setBuffer(nullptr, 0);
            break;   // Transparent — nothing to voice
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

void PedalChain::processSpan(float *buffer, int n, int channel, int first, int last) noexcept {
    if (!ready_ || !buffer || n <= 0 || channel < 0 || channel >= numChannels_) return;
    const int count = active_.load(std::memory_order_acquire);
    const int lo = std::max(0, first);
    const int hi = std::min(std::min(last, count), kMaxPedals);
    for (int i = lo; i < hi; ++i) {
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
            case Delay:      s.delay.process(buffer, n, channel, p);                break;
            case Reverb:     s.reverb.process(buffer, n, channel, p);               break;
            default:         break;   // Transparent (and not-yet-implemented families)
        }
    }
}

void PedalChain::process(float *buffer, int n, int channel) noexcept {
    processSpan(buffer, n, channel, 0, kMaxPedals);
}

} // namespace streetrig
