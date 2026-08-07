//
//  AmpCabProcessor.hpp
//  StreetRig
//
//  The tonal core wired into the DSP seam: chains AMP (neural capture OR the
//  analog fallback) → CABINET IR convolver, with per-stage bypass and de-zippered
//  drive/makeup. Owned by the C++ kernel (StreetRigDSPKernel); the kernel handles
//  the parameter bus + input/output gain and calls `process()` per channel.
//
//  MODEL / IR HAND-OFF (the step-1 ready-flag pattern, generalized): the neural
//  model is loaded + built on the setup thread and swapped in through an atomic
//  pointer with a one-generation retire, so the render thread only ever reads a
//  fully-constructed model and no in-use model is ever freed. Cab IRs are stored
//  in slots and prepared (partitioned/FFT'd) off the audio thread; the render
//  path only reads preallocated convolver state. This is exactly the structure
//  step 3 uses to hot-swap the amp + cab per selected amp.
//
//  REAL-TIME CONTRACT: `process()` allocates nothing, locks nothing, does no I/O.
//  All setup (prepare / installNeuralModel / loadCabIRSlot / setActiveCabSlot)
//  runs on the main/setup thread. See RealtimeSafety.md.
//

#ifndef STREETRIG_AMP_CAB_PROCESSOR_HPP
#define STREETRIG_AMP_CAB_PROCESSOR_HPP

#include <atomic>
#include <vector>

#include "AnalogAmp.hpp"
#include "Neural/NeuralAmpModel.hpp"
#include "Convolution/CabinetConvolver.hpp"

namespace streetrig {

/// Snapshot of the amp/cab parameters, taken once per buffer by the kernel from
/// its atomic parameter bus and passed by value into `process()`.
struct AmpCabParams {
    bool  ampBypass = false;
    bool  cabBypass = false;
    bool  useNeural = false;   ///< prefer the neural capture when one is loaded
    float drive     = 3.0f;    ///< linear pre-gain into the amp nonlinearity
    float ampOut    = 1.0f;    ///< post-amp makeup gain (amp "Master")
};

/// The amp's passive TONE STACK (requirement 2): Bass low-shelf, Mid peak,
/// Treble high-shelf, Presence high-shelf, in series, placed POST-amp / PRE-cab
/// (the classic preamp→tone→power-amp position). It is an idealized shelving/
/// peaking approximation of an interacting passive network — good enough to be
/// musically useful and to ear-tune later; the center frequencies below are the
/// first-pass voicing.
///
/// COEFFICIENT HAND-OFF: the band gains (dB) come from continuous knobs, so the
/// biquad coefficients are recomputed OFF the audio thread (`setBandDB`, main
/// thread) into an inactive coefficient set and published with a single atomic
/// index flip. The render thread reads the active set and runs the filters with
/// its own persistent per-channel state — no locks, no audio-thread trig.
class ToneStack {
public:
    static constexpr int kMaxChannels = 2;
    static constexpr int kBands = 4;   // 0=Bass 1=Mid 2=Treble 3=Presence

    void prepare(double sampleRate) noexcept;
    void reset() noexcept;

    /// Set one band's gain in dB and republish the coefficient set. Main thread.
    void setBandDB(int band, float dB) noexcept;

    /// Run the 4-band stack in place for `channel`. Audio thread.
    void process(float *buffer, int n, int channel) noexcept;

private:
    struct Coeffs { float b0, b1, b2, a1, a2; };
    struct CoeffSet { Coeffs c[kBands]; };

    void recompute() noexcept;          // main thread: design → inactive set → flip

    double sampleRate_ = 48000.0;
    float  bandDB_[kBands] = {0, 0, 0, 0};
    CoeffSet sets_[2];
    std::atomic<int> live_{0};

    // Persistent per-channel, per-band filter memory (independent of coeffs).
    struct BiquadState { float x1, x2, y1, y2; };
    BiquadState st_[kMaxChannels][kBands] = {};
};

class AmpCabProcessor {
public:
    static constexpr int kMaxChannels = 2;
    static constexpr int kNumCabSlots = 4;

    AmpCabProcessor() = default;
    ~AmpCabProcessor();

    AmpCabProcessor(const AmpCabProcessor &) = delete;
    AmpCabProcessor &operator=(const AmpCabProcessor &) = delete;

    // --- Setup thread ---
    void prepare(double sampleRate, int numChannels, int maxFrames);
    void reset() noexcept;

    /// Atomically install a new neural model (takes ownership). Passing nullptr
    /// removes the active model (falls back to analog). Setup thread only.
    void installNeuralModel(NeuralAmpModel *model) noexcept;

    /// Store raw IR samples into a slot (copied). Setup thread only.
    void loadCabIRSlot(int slot, const float *samples, int count) noexcept;

    /// Partition/FFT the slot's IR into the live convolver. Setup thread only.
    void setActiveCabSlot(int slot) noexcept;

    /// Set an amp tone-stack band's gain in dB (0=Bass 1=Mid 2=Treble
    /// 3=Presence). Recomputes coefficients off the audio thread. Main thread.
    void setToneBandDB(int band, float dB) noexcept { tone_.setBandDB(band, dB); }

    // --- Queries (main thread) ---
    bool  hasNeuralModel() const noexcept { return activeModel_.load(std::memory_order_acquire) != nullptr; }
    int   activeCabSlot() const noexcept { return activeCabSlot_; }
    int   cabIRLength(int slot) const noexcept;
    int   cabLatencySamples() const noexcept { return convolver_.latencySamples(); }

    // --- Audio thread ---
    /// Process `n` samples in place for `channel` through amp → cab.
    void process(float *buffer, int n, int channel, const AmpCabParams &p) noexcept;

    /// Setup-thread accessor for the active model (benchmark / diagnostics only).
    NeuralAmpModel *debugActiveModel() const noexcept {
        return activeModel_.load(std::memory_order_acquire);
    }

private:
    double sampleRate_ = 48000.0;
    int    numChannels_ = 1;
    bool   ready_ = false;

    AnalogAmp        analog_;
    ToneStack        tone_;
    CabinetConvolver convolver_;

    // Neural model hand-off: active + one-generation retire slot.
    std::atomic<NeuralAmpModel *> activeModel_{nullptr};
    std::atomic<NeuralAmpModel *> retireModel_{nullptr};

    // Cab IR slots (raw samples, at render sample rate).
    std::vector<float> cabSlots_[kNumCabSlots];
    int activeCabSlot_ = 0;

    // Per-channel de-zipper smoothers for drive / makeup.
    float smDrive_[kMaxChannels] = {3.0f, 3.0f};
    float smAmpOut_[kMaxChannels] = {1.0f, 1.0f};
    float smoothCoeff_ = 0.0f;   // one-pole coefficient (~5 ms).
};

} // namespace streetrig

#endif /* STREETRIG_AMP_CAB_PROCESSOR_HPP */
