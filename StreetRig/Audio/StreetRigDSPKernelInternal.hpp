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
