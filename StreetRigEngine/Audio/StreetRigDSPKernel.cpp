//
//  StreetRigDSPKernel.cpp
//  StreetRig
//
//  C++ real-time DSP core behind the StreetRigDSPKernel.h C ABI. Prompt 002 grows
//  the old unity passthrough into the tonal heart of the amp sim:
//
//      input gain → AMP (neural capture or analog fallback) → CABINET IR → output
//
//  The per-sample amp/cab math lives in AmpCabProcessor (+ NeuralAmpModel,
//  AnalogAmp, CabinetConvolver). This file owns the lock-free parameter bus and
//  the input/output gain staging, and drives the processor from the render block.
//
//  REAL-TIME CONTRACT (see RealtimeSafety.md): `SRKernelProcess` and everything it
//  calls do NO heap allocation, NO locking, NO ObjC/ARC, NO file/console I/O, and
//  bounded work. Model/IR building happens on the setup thread via the
//  SRKernelLoad* calls and is handed to the render thread through the processor's
//  atomic model swap + preallocated convolver state.
//

#include "StreetRigDSPKernel.h"
#include "StreetRigDSPKernelInternal.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <new>
#include <vector>
#include <CoreAudioTypes/CoreAudioTypes.h>

using streetrig::DSPKernel;
using streetrig::RampedGain;
using streetrig::AmpCabParams;

namespace {

inline RampedGain *gainForAddress(DSPKernel *k, uint64_t address) noexcept {
    switch (address) {
        case SRParamInputGain:   return &k->inputGain;
        case SRParamOutputLevel: return &k->outputLevel;
        case SRParamAmpDrive:    return &k->ampDrive;
        case SRParamAmpMakeup:   return &k->ampMakeup;
        case SRParamAmpVolume:   return &k->ampVolume;
        case SRParamAmpPower:    return &k->ampPower;
        default:                 return nullptr;
    }
}

} // namespace

// MARK: - Lifecycle

SRKernelRef SRKernelCreate(void) {
    auto *k = new (std::nothrow) DSPKernel();
    if (!k) return nullptr;
    // Sensible amp defaults: enough drive to dirty a clean DI, unity makeup.
    k->ampDrive.target.store(3.0f, std::memory_order_relaxed);
    k->ampDrive.current = 3.0f;
    k->ampMakeup.target.store(1.0f, std::memory_order_relaxed);
    k->ampMakeup.current = 1.0f;
    // Unity volume into the power amp and 100 W of headroom, so an untouched
    // kernel — and every already-saved rig or host session, which carries no
    // value for either — behaves exactly as it did before the power amp existed.
    k->ampVolume.target.store(1.0f, std::memory_order_relaxed);
    k->ampVolume.current = 1.0f;
    k->ampPower.target.store(1.0f, std::memory_order_relaxed);
    k->ampPower.current = 1.0f;
    return k;
}

void SRKernelDestroy(SRKernelRef kernel) {
    delete static_cast<DSPKernel *>(kernel);
}

void SRKernelPrepare(SRKernelRef kernel, double sampleRate, int channelCount, int maxFrames) {
    auto *k = static_cast<DSPKernel *>(kernel);
    if (!k) return;
    k->sampleRate = sampleRate > 0 ? sampleRate : 48000.0;
    k->channelCount = channelCount > 0 ? channelCount : 1;
    k->maxFrames = maxFrames > 0 ? maxFrames : 4096;
    k->inputGain.reset();
    k->outputLevel.reset();
    k->ampDrive.reset();
    k->ampMakeup.reset();
    k->ampVolume.reset();
    k->ampPower.reset();
    k->pedals.prepare(k->sampleRate, k->channelCount);
    k->processor.prepare(k->sampleRate, k->channelCount, k->maxFrames);
    k->chainGain = 1.0f;
}

void SRKernelReset(SRKernelRef kernel) {
    auto *k = static_cast<DSPKernel *>(kernel);
    if (!k) return;
    k->inputGain.reset();
    k->outputLevel.reset();
    k->ampDrive.reset();
    k->ampMakeup.reset();
    k->ampVolume.reset();
    k->ampPower.reset();
    k->pedals.reset();
    k->processor.reset();
}

// MARK: - Parameter bus

void SRKernelSetParameter(SRKernelRef kernel, uint64_t address, float value) {
    auto *k = static_cast<DSPKernel *>(kernel);
    if (!k) return;
    if (RampedGain *g = gainForAddress(k, address)) {
        g->target.store(value, std::memory_order_relaxed);
        return;
    }

    // Structured pedal range: address = SRPedalParamBase + slot*stride + field.
    // Same lock-free bus; the value is stored into the slot's atomics (or, for
    // Character, revoices the slot). Continuous knobs never trigger a rebuild.
    if (address >= (uint64_t)SRPedalParamBase &&
        address <  (uint64_t)(SRPedalParamBase + SRMaxPedals * SRPedalParamStride)) {
        const uint64_t rel = address - (uint64_t)SRPedalParamBase;
        const int slot  = (int)(rel / SRPedalParamStride);
        const int field = (int)(rel % SRPedalParamStride);
        k->pedals.setParam(slot, field, value);
        return;
    }

    switch (address) {
        case SRParamAmpBypass:    k->ampBypass.store(value >= 0.5f, std::memory_order_relaxed); break;
        case SRParamCabBypass:    k->cabBypass.store(value >= 0.5f, std::memory_order_relaxed); break;
        case SRParamAmpUseNeural: k->useNeural.store(value >= 0.5f, std::memory_order_relaxed); break;
        // Slot selection only records intent; SRKernelSetActiveCabSlot performs the
        // (setup-thread) IR swap so the audio thread never races the convolver.
        case SRParamCabSelect:    k->cabSelect.store((int)std::lround(value), std::memory_order_relaxed); break;
        // Amp tone stack: coefficients are recomputed HERE (main thread) and
        // published to the render thread via the ToneStack's atomic coeff flip.
        case SRParamAmpBass:      k->processor.setToneBandDB(0, value); break;
        case SRParamAmpMid:       k->processor.setToneBandDB(1, value); break;
        case SRParamAmpTreble:    k->processor.setToneBandDB(2, value); break;
        // Presence is routed by the PROFILE, not by the kernel: tone band 3 for
        // the legacy voicing, the power-amp NFB shelf for every profiled amp.
        // Both destinations recompute off the audio thread, so this adds no new
        // threading concern — and the kernel stays profile-agnostic.
        case SRParamAmpPresence:  k->processor.setPresenceDB(value); break;
        default: break;
    }
}

float SRKernelGetParameter(SRKernelRef kernel, uint64_t address) {
    auto *k = static_cast<DSPKernel *>(kernel);
    if (!k) return 0.0f;
    if (RampedGain *g = gainForAddress(k, address)) {
        return g->target.load(std::memory_order_relaxed);
    }
    switch (address) {
        case SRParamAmpBypass:    return k->ampBypass.load(std::memory_order_relaxed) ? 1.0f : 0.0f;
        case SRParamCabBypass:    return k->cabBypass.load(std::memory_order_relaxed) ? 1.0f : 0.0f;
        case SRParamAmpUseNeural: return k->useNeural.load(std::memory_order_relaxed) ? 1.0f : 0.0f;
        case SRParamCabSelect:    return (float)k->cabSelect.load(std::memory_order_relaxed);
        default: return 0.0f;
    }
}

void SRKernelSetBypass(SRKernelRef kernel, bool bypassed) {
    auto *k = static_cast<DSPKernel *>(kernel);
    if (!k) return;
    k->bypassed.store(bypassed, std::memory_order_relaxed);
}

bool SRKernelGetBypass(SRKernelRef kernel) {
    auto *k = static_cast<DSPKernel *>(kernel);
    return k ? k->bypassed.load(std::memory_order_relaxed) : false;
}

// MARK: - Amp model + cabinet IR loading (setup thread)

bool SRKernelHasNeuralModel(SRKernelRef kernel) {
    auto *k = static_cast<DSPKernel *>(kernel);
    return k ? k->processor.hasNeuralModel() : false;
}

void SRKernelLoadCabIR(SRKernelRef kernel, int slot, const float *samples, int count, double irSampleRate) {
    auto *k = static_cast<DSPKernel *>(kernel);
    if (!k || !samples || count <= 0) return;

    // Resample to the kernel rate if the IR was authored at a different rate.
    if (irSampleRate > 0.0 && std::abs(irSampleRate - k->sampleRate) > 1.0) {
        const double ratio = k->sampleRate / irSampleRate;
        const int outCount = (int)std::floor(count * ratio);
        std::vector<float> resampled((size_t)std::max(1, outCount), 0.0f);
        for (int i = 0; i < outCount; ++i) {
            const double srcPos = i / ratio;
            const int i0 = (int)std::floor(srcPos);
            const int i1 = std::min(i0 + 1, count - 1);
            const float frac = (float)(srcPos - i0);
            resampled[(size_t)i] = samples[i0] * (1.0f - frac) + samples[i1] * frac;
        }
        k->processor.loadCabIRSlot(slot, resampled.data(), (int)resampled.size());
    } else {
        k->processor.loadCabIRSlot(slot, samples, count);
    }
}

void SRKernelSetActiveCabSlot(SRKernelRef kernel, int slot) {
    auto *k = static_cast<DSPKernel *>(kernel);
    if (!k) return;
    k->processor.setActiveCabSlot(slot);
    k->cabSelect.store(slot, std::memory_order_relaxed);
}

int SRKernelActiveCabSlot(SRKernelRef kernel) {
    auto *k = static_cast<DSPKernel *>(kernel);
    return k ? k->processor.activeCabSlot() : 0;
}

// MARK: - Pedal chain configuration + hot-swap barrier (setup thread)

void SRKernelSetActivePedalCount(SRKernelRef kernel, int count) {
    auto *k = static_cast<DSPKernel *>(kernel);
    if (!k) return;
    k->pedals.setActiveCount(count);
}

void SRKernelConfigurePedal(SRKernelRef kernel, int slot, int type, int character, bool enabled) {
    auto *k = static_cast<DSPKernel *>(kernel);
    if (!k) return;
    k->pedals.configureSlot(slot, type, character);
    k->pedals.setParam(slot, streetrig::PedalChain::Enabled, enabled ? 1.0f : 0.0f);
}

void SRKernelSetPedalSplits(SRKernelRef kernel, int splitPre, int splitPost) {
    auto *k = static_cast<DSPKernel *>(kernel);
    if (!k) return;
    k->pedals.setSplits(splitPre, splitPost);
}

uint64_t SRKernelPedalArenaBytes(SRKernelRef kernel) {
    auto *k = static_cast<DSPKernel *>(kernel);
    return k ? (uint64_t)k->pedals.arenaBytes() : 0;
}

void SRKernelConfigureAmp(SRKernelRef kernel, int profile) {
    auto *k = static_cast<DSPKernel *>(kernel);
    if (!k) return;
    k->processor.configureAmp(profile);
}

int SRKernelActiveAmpProfile(SRKernelRef kernel) {
    auto *k = static_cast<DSPKernel *>(kernel);
    return k ? k->processor.activeAmpProfile() : 0;
}

bool SRKernelAmpProfileBypassesCab(SRKernelRef kernel) {
    auto *k = static_cast<DSPKernel *>(kernel);
    return k ? k->processor.profileBypassesCab() : false;
}

void SRKernelSetReconfiguring(SRKernelRef kernel, bool reconfiguring) {
    auto *k = static_cast<DSPKernel *>(kernel);
    if (!k) return;
    if (reconfiguring) {
        // Reset the parked counter so the setup thread can wait for FRESH parks.
        k->parkedBuffers.store(0, std::memory_order_relaxed);
    }
    k->reconfiguring.store(reconfiguring, std::memory_order_release);
}

uint64_t SRKernelGetParkedBufferCount(SRKernelRef kernel) {
    auto *k = static_cast<DSPKernel *>(kernel);
    return k ? k->parkedBuffers.load(std::memory_order_acquire) : 0;
}

void SRKernelResetChainState(SRKernelRef kernel) {
    auto *k = static_cast<DSPKernel *>(kernel);
    if (!k) return;
    k->pedals.reset();
    k->processor.reset();
}

int SRKernelCabIRLength(SRKernelRef kernel, int slot) {
    auto *k = static_cast<DSPKernel *>(kernel);
    return k ? k->processor.cabIRLength(slot) : 0;
}

int SRKernelCabLatencySamples(SRKernelRef kernel) {
    auto *k = static_cast<DSPKernel *>(kernel);
    return k ? k->processor.cabLatencySamples() : 0;
}

double SRKernelBenchmarkNeuralNsPerSample(SRKernelRef kernel, int iterations) {
    auto *k = static_cast<DSPKernel *>(kernel);
    if (!k || iterations <= 0) return 0.0;
    auto *model = k->processor.debugActiveModel();
    if (!model || !model->isValid()) return 0.0;

    // Warm up, then time a tight forward-pass loop on the setup thread.
    volatile float sink = 0.0f;
    for (int i = 0; i < 256; ++i) sink += model->process(0.01f * (float)(i & 15), 0);
    model->reset(0);

    const auto t0 = std::chrono::high_resolution_clock::now();
    float x = 0.05f;
    for (int i = 0; i < iterations; ++i) {
        x = model->process(x * 0.5f + 0.01f, 0);
        sink += x;
    }
    const auto t1 = std::chrono::high_resolution_clock::now();
    model->reset(0);
    (void)sink;
    const double ns = std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count();
    return ns / (double)iterations;
}

double SRKernelBenchmarkFullNsPerSample(SRKernelRef kernel, int frames, int iterations) {
    auto *k = static_cast<DSPKernel *>(kernel);
    if (!k || frames <= 0 || iterations <= 0) return 0.0;
    if (frames > k->maxFrames) frames = k->maxFrames;

    // Test-tone scratch (setup-thread allocation is fine here).
    std::vector<float> buf((size_t)frames, 0.0f);
    const double sr = k->sampleRate > 0 ? k->sampleRate : 48000.0;
    for (int i = 0; i < frames; ++i)
        buf[i] = 0.2f * std::sin(2.0 * M_PI * 220.0 * i / sr);

    // Snapshot current params (whatever A/B state the caller set).
    AmpCabParams p;
    p.ampBypass = k->ampBypass.load(std::memory_order_relaxed);
    p.cabBypass = k->cabBypass.load(std::memory_order_relaxed);
    p.useNeural = k->useNeural.load(std::memory_order_relaxed);
    p.drive      = k->ampDrive.target.load(std::memory_order_relaxed);
    p.ampOut     = k->ampMakeup.target.load(std::memory_order_relaxed);
    p.ampVolume  = k->ampVolume.target.load(std::memory_order_relaxed);
    p.powerScale = k->ampPower.target.load(std::memory_order_relaxed);

    // Warm caches through the WHOLE board, composed EXACTLY as the render block
    // composes it — the three pedal spans around the amp, not one span in front
    // of it. Measuring a different composition than the one that ships would
    // make the reported CPU a fiction the moment a slot moved into the FX loop.
    const int splitPre = k->pedals.splitPre();
    const int splitPost = k->pedals.splitPost();
    const int slots = streetrig::PedalChain::kMaxPedals;
    auto board = [&]() noexcept {
        k->pedals.processSpan(buf.data(), frames, 0, 0, splitPre);
        k->processor.processPreamp(buf.data(), frames, 0, p);
        k->pedals.processSpan(buf.data(), frames, 0, splitPre, splitPost);
        k->processor.processPowerAmp(buf.data(), frames, 0, p);
        k->processor.processCab(buf.data(), frames, 0, p);
        k->pedals.processSpan(buf.data(), frames, 0, splitPost, slots);
    };
    for (int w = 0; w < 8; ++w) board();
    k->pedals.reset();
    k->processor.reset();

    const auto t0 = std::chrono::high_resolution_clock::now();
    for (int it = 0; it < iterations; ++it) board();
    const auto t1 = std::chrono::high_resolution_clock::now();
    k->pedals.reset();
    k->processor.reset();

    const double ns = std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count();
    return ns / ((double)iterations * (double)frames);
}

// MARK: - Render (AUDIO THREAD)

void SRKernelProcess(SRKernelRef kernel,
                     const void *inputData,
                     void *outputData,
                     int frameCount) {
    auto *k = static_cast<DSPKernel *>(kernel);
    if (!k || frameCount <= 0) return;

    const auto *in  = static_cast<const AudioBufferList *>(inputData);
    auto       *out = static_cast<AudioBufferList *>(outputData);
    if (!in || !out) return;

    const int channels = static_cast<int>(out->mNumberBuffers);
    const bool bypass = k->bypassed.load(std::memory_order_relaxed);
    const bool reconf = k->reconfiguring.load(std::memory_order_acquire);
    k->processCallCount.fetch_add(1, std::memory_order_relaxed);

    // Snapshot ramped gains once per buffer; ramp `current` toward the targets.
    const float inTarget  = k->inputGain.target.load(std::memory_order_relaxed);
    const float outTarget = k->outputLevel.target.load(std::memory_order_relaxed);
    const float inStart  = k->inputGain.current;
    const float outStart = k->outputLevel.current;
    const float invFrames = 1.0f / static_cast<float>(frameCount);
    const float inStep  = (inTarget  - inStart)  * invFrames;
    const float outStep = (outTarget - outStart) * invFrames;

    // --- Hard bypass: dry passthrough, no DSP stage touched (mutation-safe). ---
    if (bypass) {
        for (int ch = 0; ch < channels; ++ch) {
            const int inIndex = (static_cast<int>(in->mNumberBuffers) == channels)
                                    ? ch : (static_cast<int>(in->mNumberBuffers) > 0 ? 0 : -1);
            auto *dst = static_cast<float *>(out->mBuffers[ch].mData);
            if (!dst) continue;
            const float *src = (inIndex >= 0)
                                   ? static_cast<const float *>(in->mBuffers[inIndex].mData) : nullptr;
            if (src && src != dst) { for (int i = 0; i < frameCount; ++i) dst[i] = src[i]; }
            else if (!src)         { for (int i = 0; i < frameCount; ++i) dst[i] = 0.0f; }
        }
        // Bypass never enters the swappable DSP stages, so it counts as "parked"
        // for a concurrent reconfigure (the setup thread may safely mutate).
        if (reconf) k->parkedBuffers.fetch_add(1, std::memory_order_relaxed);
        k->inputGain.current  = inTarget;
        k->outputLevel.current = outTarget;
        return;
    }

    // --- Structural reconfigure fade/park: once faded to silence, skip ALL DSP
    //     stages so the setup thread can mutate pedal/cab/amp state race-free. ---
    const float cgStart = k->chainGain;
    if (reconf && cgStart <= 1.0e-4f) {
        for (int ch = 0; ch < channels; ++ch) {
            if (auto *dst = static_cast<float *>(out->mBuffers[ch].mData))
                for (int i = 0; i < frameCount; ++i) dst[i] = 0.0f;
        }
        k->chainGain = 0.0f;
        k->parkedBuffers.fetch_add(1, std::memory_order_relaxed);
        k->inputGain.current  = inTarget;
        k->outputLevel.current = outTarget;
        return;
    }
    // Fade out toward silence while reconfiguring, else fade in / hold at unity.
    const float cgTarget = reconf ? 0.0f : 1.0f;
    const float cgStep = (cgTarget - cgStart) * invFrames;

    // Limiter timing, once per buffer rather than per sample: 2 ms to take hold
    // of a transient, 80 ms to let go — slow enough not to chatter on every note,
    // fast enough that a chord doesn't arrive before the gain does.
    const float srF = static_cast<float>(k->sampleRate > 0 ? k->sampleRate : 48000.0);
    const float attackCoef  = 1.0f - std::exp(-1.0f / (0.002f * srF));
    const float releaseCoef = 1.0f - std::exp(-1.0f / (0.080f * srF));

    // Expander timing: open in a millisecond so no pick attack is ever late,
    // close over 150 ms so it never chatters on a decay.
    const float gateAttack  = 1.0f - std::exp(-1.0f / (0.001f * srF));
    const float gateRelease = 1.0f - std::exp(-1.0f / (0.150f * srF));
    constexpr float invGateThreshold = 1.0f / DSPKernel::kGateThreshold;

    // No fader-driven saturation any more: loudness is the limiter's job, dirt is
    // the amp's. See kCeilingKnee in the internal header for why.

    // Amp/cab params (drive + makeup are de-zippered inside the processor).
    AmpCabParams p;
    p.ampBypass = k->ampBypass.load(std::memory_order_relaxed);
    p.cabBypass = k->cabBypass.load(std::memory_order_relaxed);
    p.useNeural = k->useNeural.load(std::memory_order_relaxed);
    p.drive      = k->ampDrive.target.load(std::memory_order_relaxed);
    p.ampOut     = k->ampMakeup.target.load(std::memory_order_relaxed);
    // Volume and the power scale are de-zippered INSIDE the power amp (like
    // drive and makeup), so the targets go across and the ~5 ms one-pole there
    // is what keeps a power-switch flip click-free.
    p.ampVolume  = k->ampVolume.target.load(std::memory_order_relaxed);
    p.powerScale = k->ampPower.target.load(std::memory_order_relaxed);

    // The three pedal spans. Read ONCE per buffer, not per channel, so the two
    // channels can never straddle a split change mid-block.
    const int splitPre = k->pedals.splitPre();
    const int splitPost = k->pedals.splitPost();
    const int slotCount = streetrig::PedalChain::kMaxPedals;

    for (int ch = 0; ch < channels; ++ch) {
        const int inIndex = (static_cast<int>(in->mNumberBuffers) == channels)
                                ? ch
                                : (static_cast<int>(in->mNumberBuffers) > 0 ? 0 : -1);
        auto *dst = static_cast<float *>(out->mBuffers[ch].mData);
        if (!dst) continue;
        const float *src = (inIndex >= 0)
                               ? static_cast<const float *>(in->mBuffers[inIndex].mData)
                               : nullptr;

        if (!src) { for (int i = 0; i < frameCount; ++i) dst[i] = 0.0f; continue; }

        const int limCh = (ch < DSPKernel::kLimiterChannels) ? ch : 0;

        // 1. Input gain ramp (src → dst), through the expander — ahead of the
        //    pedals and the amp, because hiss let through here is hiss the amp
        //    spends the rest of the chain amplifying.
        float g0 = inStart;
        float genv = k->gateEnv[limCh];
        for (int i = 0; i < frameCount; ++i) {
            const float v = src[i] * g0;
            g0 += inStep;
            const float a = std::fabs(v);
            genv += (a > genv ? gateAttack : gateRelease) * (a - genv);
            const float t = std::fmin(1.0f, genv * invGateThreshold);
            dst[i] = v * t * t;
        }
        k->gateEnv[limCh] = genv;

        // 2. PEDAL CHAIN — PRE span: everything in front of the amp, in
        //    on-screen chain order.
        k->pedals.processSpan(dst, frameCount, ch, 0, splitPre);

        // 3. Preamp cascade → tone stack. This is the tap point of a real amp's
        //    FX loop, which is why the processor exposes it separately.
        k->processor.processPreamp(dst, frameCount, ch, p);

        // 4. PEDAL CHAIN — MID span: the FX loop. Delay and reverb belong here,
        //    so their tails go THROUGH the power amp and compress with the notes
        //    instead of floating on top of a finished, cab-filtered signal.
        k->pedals.processSpan(dst, frameCount, ch, splitPre, splitPost);

        // 5. Power amp (+ master) → cabinet IR.
        k->processor.processPowerAmp(dst, frameCount, ch, p);
        k->processor.processCab(dst, frameCount, ch, p);

        // 6. PEDAL CHAIN — POST span: after the speaker, the "post-loop"
        //    position. Empty unless the rig asks for it.
        k->pedals.processSpan(dst, frameCount, ch, splitPost, slotCount);

        // 7. Output level × chain fade ramp (fade covers structural swaps), then
        //    the LIMITER — the last thing between the rig and the converter, and
        //    therefore after every span above, including POST. A block dropped
        //    into the post-loop position is part of the rig and belongs under the
        //    limiter like everything else; putting it after would let it hand the
        //    converter exactly the peaks the limiter exists to catch.
        //
        //    This was a waveshaper first, and a waveshaper is the wrong tool: bend
        //    a full-range signal that hard and you have built a fuzz box, complete
        //    with the harmonics it invents above Nyquist folding back down as the
        //    scratch you can hear underneath the note. A limiter never touches the
        //    shape of the wave — it moves a gain, smoothly, so nothing is added
        //    that wasn't played. Loud costs dynamics here; it no longer costs tone.
        // The limiter aims at the KNEE, not the ceiling. Hold peaks at the knee
        // and the soft ceiling above is a straight wire for everything the limiter
        // caught — the gap between the two is headroom kept in reserve for the
        // transient that outruns a 2 ms envelope. Aiming at the ceiling instead
        // would park the whole signal in the bend and undo the point of the knee.
        constexpr float target = DSPKernel::kCeilingKnee;
        float env = k->limiterEnv[limCh];
        float lim = k->limiterGain[limCh];
        float g1 = outStart, cg = cgStart;
        for (int i = 0; i < frameCount; ++i) {
            const float x = dst[i] * g1 * cg;
            g1 += outStep; cg += cgStep;

            // Follow the peak, down fast and up slow, and ask for whatever gain
            // keeps it under the ceiling.
            const float a = std::fabs(x);
            env += (a > env ? attackCoef : releaseCoef) * (a - env);
            const float want = (env > target) ? (target / env) : 1.0f;
            lim += ((want < lim) ? attackCoef : releaseCoef) * (want - lim);

            // ONE WAY TO FIT UNDER THE CEILING: hold the level, keep the wave.
            // The limiter moves a gain and nothing else, so a clean patch is still
            // the clean patch at the top of the fader — just louder.
            const float clean = x * lim;

            // Whatever still overshoots — a transient that outran the envelope —
            // is bent rather than snapped, and ONLY the overshoot: below the knee
            // this returns its input unchanged. It sees a millisecond at a time.
            dst[i] = DSPKernel::softCeil(clean);
        }
        k->limiterEnv[limCh] = env;
        k->limiterGain[limCh] = lim;
    }

    // Commit ramp end-points for the next buffer (audio thread only).
    k->chainGain          = cgTarget;
    k->inputGain.current  = inTarget;
    k->outputLevel.current = outTarget;
}

// MARK: - Render-load metering

void SRKernelStoreRenderMetrics(SRKernelRef kernel, double blockSeconds, double deadlineSeconds) {
    auto *k = static_cast<DSPKernel *>(kernel);
    if (!k) return;
    k->lastBlockSeconds.store(blockSeconds, std::memory_order_relaxed);
    const double load = (deadlineSeconds > 0.0) ? (blockSeconds / deadlineSeconds) : 0.0;
    k->lastRenderLoad.store(load, std::memory_order_relaxed);
}

double SRKernelGetLastRenderLoad(SRKernelRef kernel) {
    auto *k = static_cast<DSPKernel *>(kernel);
    return k ? k->lastRenderLoad.load(std::memory_order_relaxed) : 0.0;
}

double SRKernelGetLastBlockSeconds(SRKernelRef kernel) {
    auto *k = static_cast<DSPKernel *>(kernel);
    return k ? k->lastBlockSeconds.load(std::memory_order_relaxed) : 0.0;
}

uint64_t SRKernelGetProcessCallCount(SRKernelRef kernel) {
    auto *k = static_cast<DSPKernel *>(kernel);
    return k ? k->processCallCount.load(std::memory_order_relaxed) : 0;
}
