//
//  PedalChain.hpp
//  StreetRig
//
//  The ordered pedalboard that sits in front of the amp. It is a FIXED POOL of
//  MAX_PEDALS pre-allocated slots (no audio-thread allocation ever). The chain
//  compiler (RigGraphCompiler, Swift) walks the on-screen RigConfiguration and,
//  off the audio thread, publishes:
//     • the ACTIVE slot count (how many pedals are in the chain),
//     • each slot's TYPE (which family) + VOICING (which flavour within it),
//  then the render thread walks slots 0..active-1 IN ORDER — so the audible
//  order matches the on-screen order exactly.
//
//  Each slot preallocates one instance of EVERY family's DSP (drive / EQ /
//  dynamics / modulation / wah / volume). `process()` dispatches on the slot's
//  live Type to whichever engine is active, so a slot can BECOME any pedal with
//  zero audio-thread allocation. Adding a family = a new Type + a new member +
//  one switch case here; delay/reverb/pitch (which need large buffers) are the
//  next extension and will draw their buffers from a preallocated arena.
//
//  Continuous knobs are pushed LIVE through the lock-free parameter bus into a
//  per-slot generic param array (Param0..Param4); the render thread snapshots
//  them per buffer and each engine de-zippers what it needs. Structural edits
//  (add/remove/reorder, change type/voicing) run under the kernel's reconfigure
//  barrier while the render thread is parked (see StreetRigDSPKernel).
//
//  REAL-TIME CONTRACT: `process()` allocates nothing, locks nothing, does no I/O.
//  All setup (prepare / configureSlot / setActiveCount) is setup-thread only.
//

#ifndef STREETRIG_PEDAL_CHAIN_HPP
#define STREETRIG_PEDAL_CHAIN_HPP

#include <atomic>
#include "DrivePedal.hpp"
#include "EqPedal.hpp"
#include "DynamicsPedal.hpp"
#include "ModulationPedal.hpp"
#include "FilterPedals.hpp"

namespace streetrig {

class PedalChain {
public:
    static constexpr int kMaxPedals   = 8;
    static constexpr int kMaxChannels = 2;
    static constexpr int kMaxParams   = 5;   // generic continuous knobs per slot

    /// Slot processing type. Mirrors ParameterMap.type* (Swift). Transparent
    /// slots (tuner / pitch / delay / reverb / looper — not yet implemented) pass
    /// through untouched but still hold their on-screen chain position.
    enum Type : int {
        Transparent = 0, Drive = 1, Eq = 2, Compressor = 3,
        Gate = 4, Wah = 5, Volume = 6, Modulation = 7
    };

    /// Per-slot live parameter fields on the structured param bus (indices must
    /// match the SRPedalField* values in StreetRigDSPKernel.h). Fields 3..3+N are
    /// the generic continuous knobs each family interprets in its own DSP units.
    enum Field : int {
        Enabled = 0, TypeField = 1, Voicing = 2,
        Param0 = 3, Param1 = 4, Param2 = 5, Param3 = 6, Param4 = 7
    };

    void prepare(double sampleRate, int numChannels);
    void reset() noexcept;

    // --- Setup thread (reconfigure barrier — render parked) ---
    void setActiveCount(int n) noexcept;
    /// Set a slot's processing type + voicing and (re)voice + clear its DSP.
    void configureSlot(int slot, int type, int voicing) noexcept;

    // --- Live parameter bus (main thread writes, audio thread reads) ---
    /// Generic setter routed from SRKernelSetParameter's structured pedal range.
    /// `field` is a Field; continuous params (Param0..) arrive already in each
    /// family's DSP units; Enabled/Type/Voicing are integer-valued.
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
        std::atomic<int>   voicing{0};
        std::atomic<float> params[kMaxParams];

        // One preallocated engine per family. Only the one matching `type` runs.
        DrivePedal      drive;
        EqPedal         eq;
        DynamicsPedal   dyn;      // compressor OR gate (mode set from Type)
        ModulationPedal mod;
        WahPedal        wah;
        VolumePedal     vol;
    };

    Slot slots_[kMaxPedals];
    std::atomic<int> active_{0};
    double sampleRate_ = 48000.0;
    int    numChannels_ = 1;
    bool   ready_ = false;
};

} // namespace streetrig

#endif /* STREETRIG_PEDAL_CHAIN_HPP */
