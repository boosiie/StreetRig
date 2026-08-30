//
//  AmpCabProcessor.hpp
//  StreetRig
//
//  The tonal core wired into the DSP seam: chains PREAMP (neural capture OR the
//  profiled analog cascade) → TONE STACK → POWER AMP → CABINET IR convolver, with
//  per-stage bypass and de-zippered drive/volume/makeup. Owned by the C++ kernel
//  (StreetRigDSPKernel); the kernel handles the parameter bus + input/output gain
//  and calls `process()` per channel.
//
//  ONE AMP IS FIVE SUBSYSTEMS, and three of them arrived with the profile system:
//  the preamp CASCADE (AnalogAmp), the per-amp voiced tone stack, and the power
//  amp with its headroom, sag, negative-feedback loop and output transformer.
//  Which of the five an amp emphasises is what makes a MSW900 not a Tandem — see
//  AmpProfile.hpp.
//
//  MODEL / IR HAND-OFF (the step-1 ready-flag pattern, generalized): the neural
//  model is loaded + built on the setup thread and swapped in through an atomic
//  pointer with a one-generation retire, so the render thread only ever reads a
//  fully-constructed model and no in-use model is ever freed. Cab IRs are stored
//  in slots and prepared (partitioned/FFT'd) off the audio thread; the render
//  path only reads preallocated convolver state. A per-amp neural capture rides
//  that same seam and replaces the PREAMP CASCADE ONLY — the profile's tone
//  stack, power amp and cab pairing still apply.
//
//  REAL-TIME CONTRACT: `process()` allocates nothing, locks nothing, does no I/O
//  and evaluates NO transcendental for filter design. All setup (prepare /
//  configureAmp / installNeuralModel / loadCabIRSlot / setActiveCabSlot) runs on
//  the main/setup thread. See RealtimeSafety.md.
//

#ifndef STREETRIG_AMP_CAB_PROCESSOR_HPP
#define STREETRIG_AMP_CAB_PROCESSOR_HPP

#include <atomic>
#include <vector>

#include "AmpProfile.hpp"
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
    float drive     = 3.0f;    ///< linear pre-gain into the FIRST preamp stage ("Gain")
    float ampOut    = 1.0f;    ///< post-amp makeup gain (amp "Master")
    /// Channel volume INTO the power amp. Unity = 1.0. On a real Kabuto this is
    /// what decides how hard the character drives the output stage, while Master
    /// sets the room level — which is exactly why players talk about the two
    /// knobs the way they do. Legacy amps leave it at unity.
    float ampVolume = 1.0f;
    /// Power-amp headroom scale: 1.0 = 100 W, 0.70 = 50 W, 0.14 = 0.5 W. This is
    /// NOT an output gain — it moves where the output stage starts to clip, so
    /// compression, sag and touch response all change with it. Continuous and
    /// de-zippered, so flipping the switch is a ~5 ms glide, never a rebuild.
    float powerScale = 1.0f;
};

/// The amp's passive TONE STACK, now PER-AMP: Bass low-shelf, Mid peak, Treble
/// high-shelf, Presence high-shelf, in series, placed POST-preamp / PRE-power-amp
/// (the classic voicing position).
///
/// WHAT CHANGED WITH PROFILES, and why it matters more than anything else in the
/// amp path: a real passive TMB network is NOT flat with its knobs at noon. A
/// Fandor scoops ~11 dB at ~400 Hz, a Marswell ~7 dB at ~650 Hz, a Vane barely
/// scoops at all and is mid-FORWARD. This stack used to be flat at noon for
/// every amp, which is precisely why they all sounded the same even before the
/// gain stages were considered. `ToneBand::noonDB` fixes that, the controls
/// interact (`bassEatsMid`), a knob can run backwards (negative `rangeScale` —
/// the Vane Cut), and a band can simply not exist.
///
/// ALL OF THAT ARITHMETIC IS FREE AT RENDER TIME. It happens inside `recompute()`
/// on the main thread; the render path still runs the same four biquads. It is
/// also why the Swift-side `ampBandDB` / `invAmpBandKnob` curves and the AU dB
/// domains did not have to change: per-amp character is applied HERE, in C++, so
/// already-saved host automation lanes resolve to the values they always did.
///
/// COEFFICIENT HAND-OFF (unchanged, and deliberately so — this is the pattern
/// being generalized, not replaced): the band gains come from continuous knobs,
/// so the biquad coefficients are recomputed OFF the audio thread into an
/// inactive coefficient set and published with a single atomic index flip. The
/// render thread reads the active set and runs the filters with its own
/// persistent per-channel state — no locks, no audio-thread trig, and the filter
/// memory survives a coefficient change so knob turns do not click.
class ToneStack {
public:
    static constexpr int kMaxChannels = 2;
    static constexpr int kBands = 4;   // 0=Bass 1=Mid 2=Treble 3=Presence

    void prepare(double sampleRate) noexcept;
    void reset() noexcept;

    /// Install a profile's stack voicing (centres, Qs, ranges, noon offsets,
    /// interaction and insertion loss) and republish. Setup thread.
    void configure(const ToneStackVoicing &voicing) noexcept;

    /// Set one band's gain in dB AS THE KNOB SENDS IT — the profile's `noonDB`,
    /// `rangeScale` and `bassEatsMid` are applied here, not by the caller.
    /// Republishes the coefficient set. Main thread.
    void setBandDB(int band, float dB) noexcept;

    /// Run the stack in place for `channel`. Audio thread.
    void process(float *buffer, int n, int channel) noexcept;

private:
    struct Coeffs { float b0, b1, b2, a1, a2; };
    struct CoeffSet { Coeffs c[kBands]; };

    void recompute() noexcept;          // main thread: design → inactive set → flip

    double sampleRate_ = 48000.0;
    ToneStackVoicing v_{};
    float  bandDB_[kBands] = {0, 0, 0, 0};   // raw knob dB, before the voicing
    bool   bandActive_[kBands] = {true, true, true, true};
    float  insertionGain_ = 1.0f;            // linear form of `insertionDB`
    CoeffSet sets_[2];
    std::atomic<int> live_{0};

    // Persistent per-channel, per-band filter memory (independent of coeffs).
    struct BiquadState { float x1, x2, y1, y2; };
    BiquadState st_[kMaxChannels][kBands] = {};
};

/// THE POWER AMP — the subsystem that was missing entirely, and the reason two
/// amps with the same preamp still feel nothing alike.
///
///     × Volume → NFB shelf → presence shelf → sag → [2× output clip] → OT
///
/// • HEADROOM is where the output valves run out of swing. A Tandem's 6L6 pair on
///   a stiff supply has enormous headroom; an HV28's cathode-biased EL84 quartet
///   runs out early, and THAT is the HV28. Expressed as `h · shape(x / h)`, so
///   below `h` the stage is transparent and above it it saturates.
/// • SAG is the supply drooping under load and recovering with a time constant,
///   so a hard chord ducks and blooms back. Tube-rectified amps sag hard; the
///   RM-140 does not sag at all.
/// • THE NEGATIVE-FEEDBACK LOOP reduces gain, tightens the low end and darkens
///   the top. Marswell and Fandor use it heavily; the HV28 has NONE, which is a
///   large part of why it feels loose.
/// • PRESENCE IS NOT AN EQ BAND. It is a control inside that feedback loop that
///   shunts part of the feedback to ground, so the frequencies it removes from
///   the feedback come back as increased gain. A frequency-selective reduction
///   of negative feedback is, to first order, a frequency-selective gain
///   increase — a high shelf. We keep that approximation deliberately: a true
///   loop model needs a delay-free feedback path around a nonlinearity, i.e. an
///   implicit solve on the audio thread, which is the wrong trade. What DID
///   change is that its corner, its range and its very existence now come from
///   the profile instead of being hard-coded at 6 kHz / ±9 dB for everything.
/// • THE OUTPUT TRANSFORMER is two first-order rolloffs — enough to separate a
///   small EL84 OT (80 Hz / 8 kHz) from a big 6L6 OT (45 Hz / 11 kHz) from the
///   RM-140's transformerless direct-coupled output (30 Hz / 14 kHz). The
///   frequency-dependent damping (the true "bloom") needs a speaker impedance
///   model in the feedback path and is deliberately deferred.
///
/// The output clip gets its OWN small 2× oversampled region rather than joining
/// the preamp's 4×: running the tone stack at 4× to share one region would cost
/// ~80 mults/sample, and 2× is sufficient because this stage's input is already
/// band-limited by the tone stack and the Miller poles and is driven far more
/// gently than the preamp.
class PowerAmp {
public:
    static constexpr int kMaxChannels = 2;
    static constexpr int kOversample = 2;
    static constexpr int kFirTaps = 16;
    static constexpr int kPhaseTaps = kFirTaps / kOversample;

    void prepare(double sampleRate) noexcept;
    void reset() noexcept;

    /// Install a profile's output stage. Also takes the profile's `outTrim` and
    /// the tone stack's insertion loss, because this is where the loss is
    /// recovered (after the nonlinearity, so the loss actually decides how hard
    /// the stage is driven). Setup thread.
    void configure(const AmpProfile &profile) noexcept;

    /// Presence, in dB as the knob sends it; the profile's `presenceScale`
    /// (which may be NEGATIVE — the Vane Cut — or zero) is applied here. Designs
    /// into the inactive coefficient set and flips, exactly like ToneStack.
    /// Main thread.
    void setPresenceDB(float dB) noexcept;

    /// True when this profile owns the presence control (i.e. it is a power-amp
    /// shelf rather than tone band 3). Main thread.
    bool ownsPresence() const noexcept { return presenceScale_ != 0.0f; }

    /// Run the output stage in place for `channel`. Audio thread.
    void process(float *buffer, int n, int channel, float volume, float powerScale) noexcept;

private:
    struct Coeffs { float b0, b1, b2, a1, a2; };
    struct BiquadState { float x1, x2, y1, y2; };

    static inline float runBiquad(const Coeffs &c, BiquadState &s, float x) noexcept {
        const float y = c.b0 * x + c.b1 * s.x1 + c.b2 * s.x2 - c.a1 * s.y1 - c.a2 * s.y2;
        s.x2 = s.x1; s.x1 = x; s.y2 = s.y1; s.y1 = y;
        return y;
    }
    static Coeffs coeffsOf(const Biquad &b) noexcept { return {b.b0, b.b1, b.b2, b.a1, b.a2}; }

    void recomputePresence() noexcept;

    double sampleRate_ = 48000.0;
    float  fir_[kFirTaps] = {};

    // Profile constants (setup thread writes, audio thread reads).
    float   headroom_ = 1.0f;
    AmpClip clip_ = AmpClip::Clean;
    float   asym_ = 0.0f, clipOffset_ = 0.0f;
    bool    hasClip_ = false;
    float   sagDepth_ = 0.0f, sagA_ = 0.0f;
    bool    hasNfb_ = false;
    double  presenceHz_ = 3500.0;
    float   presenceScale_ = 0.0f, presenceDB_ = 0.0f;
    bool    hasOtHP_ = false, hasOtLP_ = false;
    float   otHPw_ = 0.0f;      ///< 2π·otLowHz/sr — scaled per buffer, no audio-thread exp()
    float   otLPa_ = 0.0f;
    float   staticTrim_ = 1.0f; ///< outTrim × insertion-loss makeup
    float   smoothCoeff_ = 0.0f;

    Coeffs nfb_{1, 0, 0, 0, 0};
    Coeffs presenceSets_[2] = {{1, 0, 0, 0, 0}, {1, 0, 0, 0, 0}};
    std::atomic<int> presenceLive_{0};

    struct ChannelState {
        BiquadState nfb{}, presence{};
        float otHPx1 = 0, otHPy1 = 0;   // one-pole high-pass (OT low rolloff)
        float otLPy = 0;                // one-pole low-pass  (OT high rolloff)
        float sagEnv = 0;
        float upHist[kPhaseTaps] = {};
        int   upPos = 0;
        float downHist[kFirTaps] = {};
        int   downPos = 0;
        float smVolume = 1.0f, smPower = 1.0f;
        /// See `AmpCabProcessor::smPrimed_` — same rule, one stage earlier. The
        /// power amp's volume de-zipper glides from 1.0f, so a rig compiled with
        /// Volume at 0 still passed the first few ms at full level. `ampMaster`
        /// could not mask it because Master sits AFTER this stage, which is why
        /// "Volume 0 / Master 5" measured about -62 dBFS while "Master 0" went
        /// properly silent once the outer smoother was primed.
        bool  smPrimed = false;
    };
    ChannelState ch_[kMaxChannels];
};

class AmpCabProcessor {
public:
    static constexpr int kMaxChannels = 2;
    /// Six amps want six distinct boxes. Four slots was not enough; the cost of
    /// eight is four extra empty `std::vector<float>` members (~96 bytes). Slots
    /// 2–7 ship EMPTY, and an empty slot installs a unit impulse — i.e. a
    /// transparent cab — which is already `setActiveCabSlot`'s behaviour.
    static constexpr int kNumCabSlots = 8;

    AmpCabProcessor() = default;
    ~AmpCabProcessor();

    AmpCabProcessor(const AmpCabProcessor &) = delete;
    AmpCabProcessor &operator=(const AmpCabProcessor &) = delete;

    // --- Setup thread ---
    void prepare(double sampleRate, int numChannels, int maxFrames);
    void reset() noexcept;

    /// Select the amp's VOICING PROFILE (`streetrig::AmpVoicing`) and fan it out
    /// to the preamp cascade, the tone stack and the power amp. Setup thread only
    /// (call inside the reconfigure barrier). Mirrors `PedalChain::configureSlot`.
    void configureAmp(int voicing) noexcept;
    int  activeAmpProfile() const noexcept { return profileId_; }
    /// Does the active profile model an amp with no speaker (Kabuto ACOUSTIC)?
    bool profileBypassesCab() const noexcept { return profileBypassCab_; }

    /// Atomically install a new neural model (takes ownership). Passing nullptr
    /// removes the active model (falls back to the profiled cascade). Setup only.
    void installNeuralModel(NeuralAmpModel *model) noexcept;

    /// Store raw IR samples into a slot (copied). Setup thread only.
    void loadCabIRSlot(int slot, const float *samples, int count) noexcept;

    /// Partition/FFT the slot's IR into the live convolver. Setup thread only.
    void setActiveCabSlot(int slot) noexcept;

    /// Set an amp tone-stack band's gain in dB (0=Bass 1=Mid 2=Treble
    /// 3=Presence). Recomputes coefficients off the audio thread. Main thread.
    void setToneBandDB(int band, float dB) noexcept { tone_.setBandDB(band, dB); }

    /// Route the PRESENCE knob to whichever stage owns it for the active profile.
    ///
    /// This is the one place that knows presence belongs to tone band 3 for
    /// `AmpVoicing::Legacy` and to the power-amp NFB shelf for every profiled
    /// amp. Keeping the decision here — with the profile — is what lets the
    /// kernel, the parameter bus and the AU parameter domain stay completely
    /// profile-agnostic: same address, same ±9 dB, same de-zippering. One
    /// control, exactly one owner, so it can never be applied twice. Main thread.
    void setPresenceDB(float dB) noexcept;

    // --- Queries (main thread) ---
    bool  hasNeuralModel() const noexcept { return activeModel_.load(std::memory_order_acquire) != nullptr; }
    int   activeCabSlot() const noexcept { return activeCabSlot_; }
    int   cabIRLength(int slot) const noexcept;
    int   cabLatencySamples() const noexcept { return convolver_.latencySamples(); }

    // --- Audio thread ---
    /// Preamp cascade (neural OR profiled analog) → tone stack.
    void processPreamp(float *buffer, int n, int channel, const AmpCabParams &p) noexcept;
    /// Power amp → master/makeup gain.
    void processPowerAmp(float *buffer, int n, int channel, const AmpCabParams &p) noexcept;
    /// Cabinet IR.
    void processCab(float *buffer, int n, int channel, const AmpCabParams &p) noexcept;
    /// The whole chain, in order. The three above are exposed separately so a
    /// later FX loop can run pedals BETWEEN the tone stack and the power amp —
    /// which is where a real amp's loop sits, and why reverb through a saturating
    /// output stage sounds different from reverb sprinkled on a finished signal.
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
    PowerAmp         power_;
    CabinetConvolver convolver_;

    int   profileId_ = Legacy;
    bool  profileBypassCab_ = false;
    float presenceDB_ = 0.0f;      ///< last knob value, re-routed when the profile changes

    // Neural model hand-off: active + one-generation retire slot.
    std::atomic<NeuralAmpModel *> activeModel_{nullptr};
    std::atomic<NeuralAmpModel *> retireModel_{nullptr};

    // Cab IR slots (raw samples, at render sample rate).
    std::vector<float> cabSlots_[kNumCabSlots];
    int activeCabSlot_ = 0;

    // Per-channel de-zipper smoothers for drive / makeup.
    float smDrive_[kMaxChannels] = {3.0f, 3.0f};
    float smAmpOut_[kMaxChannels] = {1.0f, 1.0f};
    /// PER-CHANNEL DE-ZIPPER PRIMING. False until that channel has processed one
    /// buffer since the last `reset()`; the first buffer SNAPS the smoothers to
    /// the incoming values instead of gliding from the boot ones.
    ///
    /// A de-zipper exists to ramp between two settings a player moved between. It
    /// has no business ramping from a constructor default into the first setting
    /// the rig was ever compiled with — there was no earlier setting to glide
    /// from. Leaving it to glide meant a rig whose Master is 0 still emitted the
    /// first few ms of a full-gain signal decaying at the 5 ms time constant,
    /// which is a real click on every structural rebuild and, in the offline
    /// harness, the reason "Master 0 is TRUE SILENCE" measured about -62 dBFS
    /// instead of nothing at all.
    bool smPrimed_[kMaxChannels] = {false, false};
    float smoothCoeff_ = 0.0f;   // one-pole coefficient (~5 ms).
};

} // namespace streetrig

#endif /* STREETRIG_AMP_CAB_PROCESSOR_HPP */
