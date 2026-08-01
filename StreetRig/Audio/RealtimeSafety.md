# StreetRig — Real-Time Audio Contract

This note is the contract every future DSP addition (prompt 002 neural amp + cab
IR, prompt 003 pedal/EQ chain) must obey. It lives next to the render code on
purpose. **Read it before touching `SRKernelProcess` or `internalRenderBlock`.**

## The two worlds

StreetRig's audio runs on exactly two threads that must never share mutable state
except through the lock-free parameter/metering bus.

| | Runs on | Files | Rules |
|---|---|---|---|
| **Setup / UI** | main actor (`@MainActor`) | `AudioEngineController.swift`, SwiftUI views | May allocate, lock, log, touch the filesystem, call ObjC/Swift freely. Owns the `AVAudioSession`, the `AVAudioEngine`, engine start/stop, parameter *writes*, published UI state. |
| **Render** | Core Audio's high-priority audio thread | `StreetRigDSPUnit.internalRenderBlock` (Swift) → `SRKernelProcess` (C++) | Hard deadline of `frameCount / sampleRate` seconds. See the forbidden list below. |

At 48 kHz with a ~5 ms IO buffer that deadline is on the order of **~240 frames ≈
5 ms** per callback. Miss it and the user hears a click/dropout.

## Forbidden inside the render path (`internalRenderBlock` + everything it calls)

- **No heap allocation** — no `new`/`malloc`/`std::vector` growth, no Swift
  `Array`/`String`/class creation, no autoreleased objects. Pre-allocate in
  `SRKernelPrepare` / `allocateRenderResources` (setup thread).
- **No locks / mutexes / `os_unfair_lock` / `@synchronized`** — never block the
  audio thread waiting on the main thread.
- **No Swift/ObjC ARC traffic** — the render block captures ONLY value types and
  raw pointers (`SRKernelRef`, the input `AudioBufferList*`, the channel base
  pointers, `sampleRate`, `secondsPerTick`). It never captures `self`. The DSP
  itself is C++ with no ObjC objects.
- **No file or console I/O**, no `print`/`NSLog`/`os_log` in the hot path.
- **No syscalls that can block** (no Objective-C messaging that may lazily
  allocate, no dictionary lookups, no notifications).
- **Bounded work** — cost is `O(frameCount × channelCount)` plus fixed overhead.
  Prompt 002's neural inference must stay within the per-buffer budget (watch the
  render-load read-out below); if a model is too heavy, cut layers, not corners.

## The lock-free parameter bus

UI knob moves must reach the render thread without locks:

1. SwiftUI writes `AUParameter.value` on the main thread.
2. `AUParameterTree.implementorValueObserver` fires (main thread) →
   `SRKernelSetParameter(kernel, address, value)` → a **`std::atomic<float>`**
   store (`memory_order_relaxed`).
3. The next `SRKernelProcess` does a relaxed atomic **load** of each target and
   **linearly ramps** the private per-stage `current` value toward it across the
   buffer, so parameter jumps never zipper/click.

This is a single-writer (main) / single-reader (audio) value bus — relaxed
atomics are sufficient and wait-free. Addresses are the `SRParameterAddress`
enum shared between C and Swift via `StreetRigDSPKernel.h`. Prompt 003 appends
new addresses there; keep existing values stable so persisted automation resolves.

## Buffer handling (why it's safe)

- The AU owns one pre-allocated input `AVAudioPCMBuffer` (sized to
  `maximumFramesToRender`) allocated in `allocateRenderResources`.
- Each render: reset the input `AudioBufferList` to point at that stable storage,
  `pullInput` upstream audio into it, and — if the host handed us null output
  buffers — point the output buffers at the input storage (**in-place**).
- `SRKernelProcess` reads `input[ch][i]` and writes `output[ch][i]`; the two may
  alias. With both gains at unity (the default) it is a bit-exact copy — which is
  what the offline null test relies on.

## Latency / CPU read-out (the budget prompts 002–003 spend)

Two numbers are surfaced so heavy DSP can be added without guessing:

- **Latency** — `AudioEngineController` reads back the OS-**granted**
  `AVAudioSession.sampleRate`, `ioBufferDuration`, `inputLatency`, `outputLatency`
  after configuring the session, and logs/publishes them (`latencyLine()`). One
  IO buffer of added round-trip latency ≈ `ioBufferDuration`. The OS may refuse
  the requested 5 ms / 48 kHz — the *granted* values are the truth.
- **Render load** — the render block times `SRKernelProcess` with
  `mach_absolute_time` and stores `blockSeconds` and
  `load = blockSeconds / (frameCount / sampleRate)` into kernel atomics
  (`SRKernelStoreRenderMetrics`). `AudioEngineController` polls
  `lastRenderLoad` / `lastBlockSeconds` (0…1+, where >1 means an overrun) on a
  0.25 s main-thread timer for the UI. Passthrough sits near 0; the headroom
  between that and 1.0 is the CPU budget for the amp/cab/pedal DSP.

> Note: the offline harness also drives the same render block, but faster than
> real time, so its block time is **not** the real-time budget — only the live
> device figure is. The Simulator has no audio input, so live monitoring is a
> physical-device-only measurement; the offline render verifies correctness.

## Prompt 002 addition — neural amp + cabinet IR (how it obeys the contract)

The seam now runs `input gain → AMP → CAB → output` inside `SRKernelProcess`
(the amp/cab math is in `AmpCabProcessor` → `NeuralAmpModel` / `AnalogAmp` /
`CabinetConvolver`). Everything on the audio thread is still allocation/lock/IO
free:

- **All buffers preallocated at setup.** `AmpCabProcessor::prepare` (called from
  `SRKernelPrepare`) sizes the LSTM state, the analog oversampler, the FFT setup,
  the IR partition spectra, the frequency-delay-line and the output FIFOs. The
  render path only *reads/updates* that storage.
- **Model / IR hand-off = the ready-flag pattern, generalized.** The neural model
  is parsed + built on the setup thread (`SRKernelLoadAmpModelJSON` in the Obj-C++
  bridge, called from `allocateRenderResources` **before** `ready` is flipped) and
  published to the render thread through a lock-free `std::atomic<NeuralAmpModel*>`
  with a **one-generation retire** (the pointer replaced two swaps ago is the only
  one freed, and the audio thread re-reads the atomic every buffer, so a live model
  is never deleted). Cab IRs are partitioned/FFT'd off-thread; the convolver's
  render state is preallocated. This is what step 3 uses to **hot-swap amp + cab
  per selected amp** — call `SRKernelLoadAmpModelJSON` / `SRKernelLoadCabIR` +
  `SRKernelSetActiveCabSlot` on the main thread; never on the render thread.
- **Cab-IR content swaps are setup-thread only.** `SRParamCabSelect` merely records
  intent on the parameter bus; the actual `setIR` (which rewrites convolver state)
  happens in `SRKernelSetActiveCabSlot` on the main thread. Bypasses
  (`SRParamAmpBypass` / `SRParamCabBypass`) and `SRParamAmpUseNeural` are plain
  relaxed-atomic bools, safe to toggle live.
- **Shared transient scratch is fine because the render thread is single.** The
  LSTM gate scratch and the convolver FFT scratch are shared across channels; the
  kernel processes channels sequentially, so there is no concurrent access. Only
  the *state* that must persist across buffers (LSTM `h`/`c`, convolver FDL/carry,
  analog filters) is kept per-channel/"voice".
- **Measured cost (Debug -O0, offline benchmark):** full amp→cab ≈ 1.18 µs/sample
  ≈ 152 µs per 128-frame block ≈ **5.7 % of the ~2667 µs live deadline** (the LSTM
  forward pass dominates; the vDSP convolution adds < 0.2 %). Release (-Os) is
  faster. If a heavier real capture is dropped in, re-check the render-load
  read-out and, if needed, drop LSTM layers/units or move to block inference.
