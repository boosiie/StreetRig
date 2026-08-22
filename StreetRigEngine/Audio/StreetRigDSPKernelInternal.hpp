//
//  StreetRigDSPKernelInternal.hpp
//  StreetRig
//
//  C++ definition of the kernel object behind the StreetRigDSPKernel.h C ABI.
//  Split out of the .cpp so the Obj-C++ model-loading bridge (NeuralAmpBridge.mm)
//  can reach `processor` to install a freshly-built neural model. NOT included
//  from Swift — the bridging header only sees the C ABI. C++/Obj-C++ only.
//

#ifndef STREETRIG_DSP_KERNEL_INTERNAL_HPP
#define STREETRIG_DSP_KERNEL_INTERNAL_HPP

#include <atomic>
#include "AmpCabProcessor.hpp"
#include "Pedals/PedalChain.hpp"

namespace streetrig {

/// One de-zippered gain stage. `target` is written by the main thread; the audio
/// thread ramps `current` toward it across each buffer.
struct RampedGain {
    std::atomic<float> target{1.0f};
    float current{1.0f};
    inline void reset() noexcept { current = target.load(std::memory_order_relaxed); }
};

/// The kernel: parameter bus + input/output gain + the amp→cab processor.
struct DSPKernel {
    // Parameter bus.
    RampedGain inputGain;
    RampedGain outputLevel;
    RampedGain ampDrive{ };       // default set in create()
    RampedGain ampMakeup;
    std::atomic<bool> ampBypass{false};
    std::atomic<bool> cabBypass{false};
    std::atomic<bool> useNeural{false};
    std::atomic<int>  cabSelect{0};
    std::atomic<bool> bypassed{false};

    // Tonal core: ordered pedalboard (pre-amp) → amp → tone stack → cab.
    PedalChain      pedals;
    AmpCabProcessor processor;

    // Structural hot-swap barrier. The setup thread sets `reconfiguring`; the
    // render thread fades `chainGain` to 0, then parks (skips DSP, outputs
    // silence) and ticks `parkedBuffers` each buffer so the setup thread knows it
    // is safe to mutate pedal/cab/amp state. `chainGain`/`fadeStep` are audio-
    // thread-private (written only by the render block).
    std::atomic<bool>     reconfiguring{false};
    std::atomic<uint64_t> parkedBuffers{0};
    float chainGain = 1.0f;   // ramped output gain for click-free fade/park

    // OUTPUT CEILING. Measured on device: with the fader up, peaks left this
    // stage 32 dB PAST full scale and the converter flattened every one of them —
    // dynamics moved, loudness didn't, and what got through crackled. The stage
    // now ends in a soft ceiling instead (see the render block), which is also
    // what lets the fader's range be as wide as it is.
    //
    // −1 dBFS, and an algebraic sigmoid rather than `tanh`: same shape, one
    // `sqrt`, no transcendental on the render thread. Below about a third of the
    // ceiling it is within a fraction of a dB of a straight wire, so ordinary
    // playing passes untouched and only the overs are bent.
    static constexpr float kOutputCeiling = 0.891f;   // −1 dBFS

    /// WHERE CLEAN ENDS AND DRIVE BEGINS, in dB of output level. Below this the
    /// output stage is a limiter and nothing else — loud, and the wave is the one
    /// that was played. Above it, saturation is blended in the rest of the way to
    /// the fader's top, so the fader IS the trade: turn it up for the last of the
    /// level and it gets dirtier on the way, exactly like opening up a master
    /// volume into a power amp.
    static constexpr float kCleanUpToDB = 12.0f;
    static constexpr float kFullDirtDB  = 42.0f;   // the fader's own ceiling

    /// INPUT EXPANDER — the quiet answer to a noisy front end.
    ///
    /// A guitar at mic level brings its own hiss, and every dB of gain after it
    /// brings the hiss too. This works only BELOW the threshold, so it is doing
    /// nothing at all while a note is sounding: playing runs from about −20 dBFS,
    /// and this starts 30 dB underneath that. Below the line it is a 3:1 downward
    /// expander (`t·t`), not a gate — the gain slides rather than switching, so a
    /// note decaying through the threshold keeps its tail instead of being cut off
    /// at it, and there is no edge to hear opening and closing.
    static constexpr float kGateThreshold = 0.00316f;   // −50 dBFS
    float gateEnv[8]{};

    /// Limiter state, one set per channel — the render walks a channel at a time,
    /// and the guitar arrives mono and duplicated, so the sets track each other
    /// and no stereo image can shift.
    static constexpr int kLimiterChannels = 8;
    float limiterEnv[kLimiterChannels]{};
    float limiterGain[kLimiterChannels] = {1, 1, 1, 1, 1, 1, 1, 1};

    // Stream configuration.
    double sampleRate{48000.0};
    int channelCount{2};
    int maxFrames{4096};

    // Render-load metering.
    std::atomic<double> lastRenderLoad{0.0};
    std::atomic<double> lastBlockSeconds{0.0};

    // Diagnostics.
    std::atomic<uint64_t> processCallCount{0};
};

} // namespace streetrig

#endif /* STREETRIG_DSP_KERNEL_INTERNAL_HPP */
