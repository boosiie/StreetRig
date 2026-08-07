//
//  PedalChain.hpp
//  StreetRig
//
//  Prompt 003 — the ordered pedalboard that sits in front of the amp. It is a
//  FIXED POOL of MAX_PEDALS pre-allocated slots (no audio-thread allocation
//  ever). The chain compiler (RigGraphCompiler, Swift) walks the on-screen
//  RigConfiguration and, off the audio thread, publishes:
//     • the ACTIVE slot count (how many pedals are in the chain),
//     • each slot's TYPE (drive vs. transparent pass-through) + CHARACTER,
//  then the render thread walks slots 0..active-1 IN ORDER — so the audible
//  order matches the on-screen order exactly.
//
//  Continuous knobs (drive / tone / level) are pushed LIVE through the lock-free
//  parameter bus into per-slot atomics; the render thread snapshots them per
//  buffer and de-zippers inside DrivePedal. Structural edits (add/remove/reorder,
//  change character) run under the kernel's reconfigure barrier while the render
//  thread is parked (see StreetRigDSPKernel). Only overdrive/distortion needs
//  real DSP now; transparent slots are the clean extension point for future
//  categories (comp / mod / delay / …).
//
//  REAL-TIME CONTRACT: `process()` allocates nothing, locks nothing, does no I/O.
//  All setup (prepare / configureSlot / setActiveCount) is setup-thread only.
//

#ifndef STREETRIG_PEDAL_CHAIN_HPP
#define STREETRIG_PEDAL_CHAIN_HPP

#include <atomic>
#include "DrivePedal.hpp"

namespace streetrig {

class PedalChain {
public:
    static constexpr int kMaxPedals   = 8;
    static constexpr int kMaxChannels = 2;

    /// Slot processing type. Extend with new categories as their DSP lands.
    enum Type : int { Transparent = 0, Drive = 1 };

    /// Per-slot live parameter fields (indices on the structured param bus; must
    /// match the SRPedalField* values in StreetRigDSPKernel.h).
    enum Field : int { Enabled = 0, TypeField = 1, Character = 2,
                       DriveAmt = 3, Tone = 4, Level = 5 };

    void prepare(double sampleRate, int numChannels);
    void reset() noexcept;

    // --- Setup thread (reconfigure barrier — render parked) ---
    void setActiveCount(int n) noexcept;
    /// Set a slot's processing type + clip character and (re)voice its DSP.
    void configureSlot(int slot, int type, int character) noexcept;

    // --- Live parameter bus (main thread writes, audio thread reads) ---
    /// Generic setter routed from SRKernelSetParameter's structured pedal range.
    /// `field` is a Field; `value` is already in DSP units (drive/level linear,
    /// tone in Hz), except Enabled/Type/Character which are integer-valued.
    void setParam(int slot, int field, float value) noexcept;

    // --- Queries (main thread) ---
    int  activeCount() const noexcept { return active_.load(std::memory_order_acquire); }

    // --- Audio thread ---
    /// Process the whole enabled chain in place for `channel`, in slot order.
    void process(float *buffer, int n, int channel) noexcept;

private:
    struct Slot {
        std::atomic<int>   type{Transparent};
        std::atomic<int>   enabled{0};
        std::atomic<float> drive{1.0f};      // linear pre-gain
        std::atomic<float> toneHz{4000.0f};  // post low-pass cutoff (Hz)
        std::atomic<float> level{1.0f};      // linear output gain
        DrivePedal pedal;
    };

    Slot slots_[kMaxPedals];
    std::atomic<int> active_{0};
    double sampleRate_ = 48000.0;
    int    numChannels_ = 1;
    bool   ready_ = false;
};

} // namespace streetrig

#endif /* STREETRIG_PEDAL_CHAIN_HPP */
