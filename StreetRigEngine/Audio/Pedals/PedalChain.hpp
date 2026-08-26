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
//  dynamics / modulation / wah / volume / delay / reverb). `process()` dispatches
//  on the slot's live Type to whichever engine is active, so a slot can BECOME
//  any pedal with zero audio-thread allocation. Adding a family = a new Type + a
//  new member + one switch case here.
//
//  THE ARENA. The small families embed their state (`ModulationPedal` is the
//  largest at 2 ch × 4096 floats = 32 KB), but a delay line is three orders of
//  magnitude bigger and a reverb tank is not far behind, so the per-slot pattern
//  stops scaling: eight slots × a multi-second stereo line, embedded, would be
//  reserved memory most rigs never use. Instead ONE `std::vector<float>` is
//  allocated in `prepare()` and carved into eight per-slot blocks; a slot that
//  becomes a delay or a reverb is HANDED its block by `configureSlot` (setup
//  thread, inside the reconfigure barrier) and the engine publishes the pointer
//  with a release store once the memory is zeroed. Nothing is ever resized and
//  nothing is ever freed while the chain lives, so the render thread can only
//  ever observe a fully-cleared block or a null pointer (which it passes through).
//
//      WORST-CASE FOOTPRINT: kMaxPedals(8) × kMaxChannels(2) × blockFloats × 4 B
//      where blockFloats = nextPowerOfTwo(ceil(kMaxDelaySeconds × sampleRate)).
//        · 48 kHz  → 131 072 floats/ch → 8.0 MB   (the shipping case)
//        · 44.1kHz → 131 072 floats/ch → 8.0 MB
//        · 96 kHz  → 262 144 floats/ch → 16.0 MB
//      A slot is a delay OR a reverb, never both, so one block serves either;
//      the reverb tank uses ~70 k of its 131 072 floats at 48 kHz. There is no
//      cap on concurrent time-based blocks and therefore no failure mode — all
//      eight slots can be delays. Drop `kMaxDelaySeconds` to 1.0 for 4.0 MB if
//      memory pressure ever shows on an older device (§11.1).
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
#include <vector>
#include "DrivePedal.hpp"
#include "EqPedal.hpp"
#include "DynamicsPedal.hpp"
#include "ModulationPedal.hpp"
#include "FilterPedals.hpp"
#include "DelayPedal.hpp"
#include "ReverbPedal.hpp"

namespace streetrig {

class PedalChain {
public:
    static constexpr int kMaxPedals   = 8;
    static constexpr int kMaxChannels = 2;
    static constexpr int kMaxParams   = 5;   // generic continuous knobs per slot

    /// Longest delay a slot can hold. Sizes the arena, and nothing else — see
    /// the footprint table in the header note.
    static constexpr double kMaxDelaySeconds = 2.0;

    /// Slot processing type. Mirrors ParameterMap.type* (Swift). Transparent
    /// slots (tuner / pitch / looper — not yet implemented) pass through
    /// untouched but still hold their on-screen chain position.
    enum Type : int {
        Transparent = 0, Drive = 1, Eq = 2, Compressor = 3,
        Gate = 4, Wah = 5, Volume = 6, Modulation = 7,
        Delay = 8, Reverb = 9
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
    /// Set a slot's processing type + voicing and (re)voice + clear its DSP. For
    /// the two time-based families this is also where the slot is handed its
    /// block of the arena.
    void configureSlot(int slot, int type, int voicing) noexcept;

    /// THE THREE-SPAN SPLIT. A pedalboard is not the only place effects go: a
    /// real amp has an FX LOOP between its preamp and its power amp, and that is
    /// where delay and reverb belong — reverb that then passes through a
    /// saturating output stage compresses WITH the notes instead of floating
    /// above them, which is the single thing most modelling-amp emulations get
    /// wrong. Two integers turn the one chain into three:
    ///
    ///     PRE  = slots [0, splitPre)          before the preamp   (boost, mod)
    ///     MID  = slots [splitPre, splitPost)  after the tone stack, before the
    ///                                          power amp          (fx/delay/verb)
    ///     POST = slots [splitPost, active)    after the cab        (post loop)
    ///
    /// Defaults put every slot in PRE, which is exactly today's behaviour. The
    /// splits are STRUCTURAL (they reorder the graph) and travel in the topology
    /// signature. Setup thread.
    void setSplits(int splitPre, int splitPost) noexcept;
    int  splitPre() const noexcept { return splitPre_.load(std::memory_order_acquire); }
    int  splitPost() const noexcept { return splitPost_.load(std::memory_order_acquire); }

    /// Neither time-based block delays the DRY path, so neither adds reported
    /// latency and the composed total is unchanged. Exposed so the kernel's
    /// latency accounting is derived rather than assumed. Main thread.
    int  latencySamples() const noexcept { return 0; }

    /// Bytes the arena reserves (diagnostics / the harness's footprint check).
    size_t arenaBytes() const noexcept { return arena_.size() * sizeof(float); }
    /// Floats per channel in one slot's block (0 before `prepare`).
    int  arenaBlockFloats() const noexcept { return blockFloats_; }

    // --- Live parameter bus (main thread writes, audio thread reads) ---
    /// Generic setter routed from SRKernelSetParameter's structured pedal range.
    /// `field` is a Field; continuous params (Param0..) arrive already in each
    /// family's DSP units; Enabled/Type/Voicing are integer-valued.
    void setParam(int slot, int field, float value) noexcept;

    // --- Queries (main thread) ---
    int  activeCount() const noexcept { return active_.load(std::memory_order_acquire); }

    // --- Audio thread ---
    /// Process slots [first, last) in place for `channel`, in slot order.
    /// Out-of-range bounds are clamped to the active chain, so a caller can pass
    /// a split point larger than the chain and get "everything from here on".
    void processSpan(float *buffer, int n, int channel, int first, int last) noexcept;
    /// The whole enabled chain, in order — i.e. `processSpan(0, activeCount())`.
    /// Kept for callers that do not split (and for the benchmark's warm-up).
    void process(float *buffer, int n, int channel) noexcept;

private:
    struct Slot {
        std::atomic<int>   type{Transparent};
        std::atomic<int>   enabled{0};
        std::atomic<int>   voicing{0};
        std::atomic<float> params[kMaxParams];

        // One preallocated engine per family. Only the one matching `type` runs.
        // The two time-based engines hold no buffer of their own — they are
        // handed a span of `arena_` — so adding them grew `Slot` by scalars only.
        DrivePedal      drive;
        EqPedal         eq;
        DynamicsPedal   dyn;      // compressor OR gate (mode set from Type)
        ModulationPedal mod;
        WahPedal        wah;
        VolumePedal     vol;
        DelayPedal      delay;
        ReverbPedal     reverb;
    };

    Slot slots_[kMaxPedals];
    std::atomic<int> active_{0};
    /// Defaults put every slot in the PRE span — today's behaviour exactly.
    std::atomic<int> splitPre_{kMaxPedals};
    std::atomic<int> splitPost_{kMaxPedals};

    /// THE ARENA: one allocation, one owner, never resized. Sized in `prepare()`
    /// for the worst case (every slot a 2 s stereo delay) so `configureSlot`
    /// only ever hands out pointers.
    std::vector<float> arena_;
    int    blockFloats_ = 0;      ///< floats per channel per slot (power of two)

    double sampleRate_ = 48000.0;
    int    numChannels_ = 1;
    bool   ready_ = false;

    /// Base of slot `i`'s block, or nullptr if the arena was never allocated.
    float *arenaBlock(int slot) noexcept;
};

} // namespace streetrig

#endif /* STREETRIG_PEDAL_CHAIN_HPP */
