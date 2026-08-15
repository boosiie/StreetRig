//
//  StreetRigDSPKernel.h
//  StreetRig
//
//  C ABI for the real-time DSP core that sits inside the custom AUAudioUnit
//  (`StreetRigDSPUnit`). This header is the *seam*: it is included from Swift
//  (via StreetRig-Bridging-Header.h) and implemented in C++17
//  (StreetRigDSPKernel.cpp). Prompt 002 (neural amp + cabinet IR) and prompt
//  003 (pedal chain + tone stack) extend `SRKernelProcess` and the parameter
//  set below WITHOUT touching the Swift host or the audio-session plumbing.
//
//  Everything reachable from `SRKernelProcess` runs on the real-time audio
//  thread — see RealtimeSafety.md. Keep this ABI free of Objective-C and of
//  any CoreAudio structs so it stays trivially includable from Swift; the
//  buffer lists are passed as opaque `void*` and reinterpreted in the .cpp.
//

#ifndef STREETRIG_DSP_KERNEL_H
#define STREETRIG_DSP_KERNEL_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to a DSP kernel instance.
typedef void *SRKernelRef;

/// Parameter addresses shared with the AUParameterTree (Swift side). These are
/// the `AUParameterAddress` values the host uses to route UI edits to the
/// kernel. Prompt 003 appends amp/pedal parameters here (keep existing values
/// stable so persisted automation still resolves).
typedef enum : uint64_t {
    SRParamInputGain    = 0, ///< Linear gain applied to the incoming DI (unity = 1.0).
    SRParamOutputLevel  = 1, ///< Linear gain applied to the processed output (unity = 1.0).
    // --- Prompt 002: neural amp + cabinet IR ---
    SRParamAmpDrive     = 2, ///< Linear pre-gain into the amp nonlinearity (amp "Gain").
    SRParamAmpMakeup    = 3, ///< Post-amp makeup/master gain (unity = 1.0; amp "Master").
    SRParamAmpBypass    = 4, ///< 0 = amp engaged, >=0.5 = amp stage bypassed.
    SRParamCabBypass    = 5, ///< 0 = cab engaged, >=0.5 = cabinet IR bypassed.
    SRParamAmpUseNeural = 6, ///< >=0.5 = use the loaded neural capture; 0 = analog fallback.
    SRParamCabSelect    = 7, ///< Active cab IR slot index (0..3). Step 3 sets this per amp.
    // --- Prompt 003: amp passive tone stack (values are gains in dB, ~-18..+18) ---
    SRParamAmpBass      = 8,  ///< Tone-stack Bass shelf gain (dB). 0 = flat.
    SRParamAmpMid       = 9,  ///< Tone-stack Mid peak gain (dB). 0 = flat.
    SRParamAmpTreble    = 10, ///< Tone-stack Treble shelf gain (dB). 0 = flat.
    SRParamAmpPresence  = 11  ///< Tone-stack Presence shelf gain (dB). 0 = flat.
} SRParameterAddress;

// --- Prompt 003: structured pedal parameter range (still the SAME lock-free bus) ---
// Continuous pedal knobs are pushed through SRKernelSetParameter with a STRUCTURED
// address that encodes (slot, field): address = SRPedalParamBase + slot*SRPedalParamStride + field.
// Values arrive in DSP units (Drive/Level linear, Tone in Hz); Enabled/Type/Character
// are integer-valued. Structural type/character/count go through the setup calls below.
enum {
    SRMaxPedals        = 8,
    SRPedalParamBase   = 100,
    SRPedalParamStride = 8,
    // field indices (must match streetrig::PedalChain::Field). Fields 3..7 are
    // the generic continuous knobs (Param0..Param4) each family reads in its own
    // DSP units; for a drive pedal Param0/1/2 are Drive/Tone/Level (kept as
    // aliases for source clarity + back-compat). SRPedalFieldCharacter is the
    // slot's VOICING (drive: soft/hard/fuzz; modulation: chorus/…/univibe).
    SRPedalFieldEnabled   = 0,
    SRPedalFieldType      = 1,
    SRPedalFieldCharacter = 2,
    SRPedalFieldDrive     = 3,   // = Param0
    SRPedalFieldTone      = 4,   // = Param1
    SRPedalFieldLevel     = 5,   // = Param2
    SRPedalFieldParam3    = 6,
    SRPedalFieldParam4    = 7
};

// MARK: - Lifecycle (main / setup thread — allocation permitted here)

/// Create a kernel. Returns NULL on failure. Not real-time safe.
SRKernelRef SRKernelCreate(void);

/// Destroy a kernel created by `SRKernelCreate`. Not real-time safe.
void SRKernelDestroy(SRKernelRef kernel);

/// Configure for a stream format. Called from `allocateRenderResources`
/// (setup thread). May allocate. `channelCount` and `maxFrames` bound the
/// work `SRKernelProcess` will later be asked to do.
void SRKernelPrepare(SRKernelRef kernel, double sampleRate, int channelCount, int maxFrames);

/// Snap all parameter ramps to their targets and clear any tail/history state.
/// Called from `reset`/`deallocateRenderResources`. Real-time safe.
void SRKernelReset(SRKernelRef kernel);

// MARK: - Amp model + cabinet IR loading (SETUP THREAD — allocation permitted)
//
// These build/prepare the neural model and cab IRs OFF the audio thread and hand
// the ready-to-run state to the render thread via an atomic swap (see
// AmpCabProcessor). The render path never calls them. Structured so prompt 003
// can hot-swap a model + IR per selected amp.

/// Load a trained amp capture (GuitarML / RTNeural "SimpleRNN" LSTM JSON) from
/// `path` and install it as the active neural model. Returns true on success; on
/// failure the kernel keeps its previous model (or the analog fallback) and, if
/// `errBuf` is non-NULL, writes a short reason. Implemented in the Obj-C++ bridge.
bool SRKernelLoadAmpModelJSON(SRKernelRef kernel, const char *path, char *errBuf, int errBufLen);

/// True if a valid neural capture is currently installed.
bool SRKernelHasNeuralModel(SRKernelRef kernel);

/// Store a cabinet IR (mono float samples) into `slot` (0..3). If `irSampleRate`
/// differs from the kernel's prepared rate the IR is linearly resampled first.
void SRKernelLoadCabIR(SRKernelRef kernel, int slot, const float *samples, int count, double irSampleRate);

/// Partition/FFT the IR in `slot` into the live convolver (setup thread).
void SRKernelSetActiveCabSlot(SRKernelRef kernel, int slot);
int  SRKernelActiveCabSlot(SRKernelRef kernel);

/// Number of raw IR samples stored in `slot` (0 if empty).
int  SRKernelCabIRLength(SRKernelRef kernel, int slot);

/// Samples of latency the cabinet convolver adds once an IR is active.
int  SRKernelCabLatencySamples(SRKernelRef kernel);

/// Micro-benchmark: run the active neural model forward `iterations` times on the
/// setup thread and return the average nanoseconds PER SAMPLE. Returns 0 if no
/// model is loaded. Used to size the neural cost before trusting it live.
double SRKernelBenchmarkNeuralNsPerSample(SRKernelRef kernel, int iterations);

// MARK: - Pedal chain configuration + hot-swap barrier (SETUP THREAD)
//
// The chain compiler (RigGraphCompiler, Swift) turns the on-screen rig into an
// ordered set of pedal slots. STRUCTURAL edits (add/remove/reorder, change
// character, swap cab/amp) run inside a reconfigure barrier so the render thread
// is muted+parked (not inside any DSP stage) while the setup thread mutates it.
// CONTINUOUS knob turns never touch these — they go through SRKernelSetParameter.

/// How many pedal slots are active (0..SRMaxPedals). The render thread walks
/// slots 0..count-1 in order. Setup thread.
void SRKernelSetActivePedalCount(SRKernelRef kernel, int count);

/// Configure one pedal slot's processing type + clip character (0=soft,1=hard,
/// 2=fuzz) and (re)voice + clear its DSP. `type`: 0=transparent, 1=drive.
/// Setup thread only (call inside the reconfigure barrier).
void SRKernelConfigurePedal(SRKernelRef kernel, int slot, int type, int character, bool enabled);

/// Begin/end a structural reconfiguration. Between these the render thread fades
/// to silence and parks (skips all DSP), so setup-thread mutation of pedal/cab/
/// amp state cannot race a render. Lock free; the audio thread never blocks.
void SRKernelSetReconfiguring(SRKernelRef kernel, bool reconfiguring);

/// Number of buffers the render thread has processed while fully parked (muted)
/// since the last reconfigure began. The setup thread waits for this to advance
/// (proof the audio thread is out of the DSP stages) before mutating. Lock free.
uint64_t SRKernelGetParkedBufferCount(SRKernelRef kernel);

/// Clear all pedal + tone-stack + amp/cab running state (setup thread) — used at
/// the end of a structural swap so the new chain starts clean under the fade-in.
void SRKernelResetChainState(SRKernelRef kernel);

/// Micro-benchmark the WHOLE amp→cab chain at the current parameter state:
/// process `frames`-sample blocks `iterations` times on the setup thread and
/// return the average nanoseconds PER SAMPLE. This is the definitive live-cost
/// estimate (multiply by the live block size for per-block µs). Setup thread only.
double SRKernelBenchmarkFullNsPerSample(SRKernelRef kernel, int frames, int iterations);

// MARK: - Parameter bus (main thread writes, audio thread reads — lock free)

/// Set a parameter target. Called by the AUParameterTree's value observer on
/// the main thread; stored atomically and picked up (and ramped to) by the
/// next `SRKernelProcess` on the audio thread. Lock free.
void SRKernelSetParameter(SRKernelRef kernel, uint64_t address, float value);

/// Read a parameter's current target. Called by the value provider on the main
/// thread. Lock free.
float SRKernelGetParameter(SRKernelRef kernel, uint64_t address);

/// Hard bypass: when true, `SRKernelProcess` copies input to output verbatim
/// and skips all DSP. Lock free; safe to toggle from the main thread.
void SRKernelSetBypass(SRKernelRef kernel, bool bypassed);
bool SRKernelGetBypass(SRKernelRef kernel);

// MARK: - Render (AUDIO THREAD — hard real-time, see RealtimeSafety.md)

/// Process one buffer in place-friendly fashion: writes `output[ch][i]` from
/// `input[ch][i]`. `inputData`/`outputData` are `AudioBufferList*` passed
/// opaquely; both are non-interleaved float32 with `channelCount` buffers.
/// input and output may alias (in-place). NO allocation, NO locks, NO I/O.
void SRKernelProcess(SRKernelRef kernel,
                     const void *inputData,
                     void *outputData,
                     int frameCount);

// MARK: - Render-load metering (audio thread stores, main thread reads)

/// Record how long the last render block took vs. its deadline. Called at the
/// end of the render block. `blockSeconds` = wall time spent; `deadlineSeconds`
/// = frameCount / sampleRate. Lock free.
void SRKernelStoreRenderMetrics(SRKernelRef kernel, double blockSeconds, double deadlineSeconds);

/// Fraction of the render deadline consumed by the last block (0…1+, where
/// >1 means an overrun / probable dropout). Main-thread read for the UI.
double SRKernelGetLastRenderLoad(SRKernelRef kernel);

/// Wall-clock seconds spent in the last render block. Main-thread read.
double SRKernelGetLastBlockSeconds(SRKernelRef kernel);

// MARK: - Diagnostics

/// Number of buffers `SRKernelProcess` has handled since creation. A single
/// relaxed atomic increment per buffer — cheap enough for the hot path, and a
/// handy "is the render thread actually running?" signal for the UI/tests.
uint64_t SRKernelGetProcessCallCount(SRKernelRef kernel);

#ifdef __cplusplus
} // extern "C"
#endif

#endif /* STREETRIG_DSP_KERNEL_H */
