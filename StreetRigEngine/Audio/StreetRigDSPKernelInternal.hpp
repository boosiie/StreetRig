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
#include <cmath>
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
    /// Channel volume into the power amp, and the power-amp headroom scale. Both
    /// are RampedGains for the same reason drive and makeup are: the power
    /// control in particular must glide, never step — a rebuild on a power-switch
    /// flip would be a ~60 ms dropout where the hardware is instant and silent.
    RampedGain ampVolume;
    RampedGain ampPower;
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

    /// THE FADER DOES NOT DIRTY THE TONE. It used to: past +12 dB saturation was
    /// blended in the rest of the way to +42, on the reasoning that a master
    /// volume opening into a power amp behaves that way. It does — but a real amp
    /// with that much headroom stays clean, and this made every CLEAN patch break
    /// up as soon as it was loud enough to play against. Amped and Tonebridge get
    /// very loud and stay glassy at the top of their travel, and that is the bar.
    ///
    /// So loudness is the limiter's job alone, and dirt is the AMP's job alone —
    /// gain, character, power-amp headroom, all of which are per-profile and
    /// already voiced. Turn the fader up and you get the same tone, louder. Want
    /// it rough, turn the amp up.
    ///
    /// KNEE, so that "clean" is really clean. The soft ceiling below used to be a
    /// sigmoid applied from zero, which bends the waveform everywhere — at the
    /// ceiling it costs ~3 dB and audibly rounds the peaks, so even the limiter's
    /// "untouched" path was not untouched. Below this knee the stage is now a
    /// literal straight wire, and only the overshoot a fast transient sneaks past
    /// the envelope gets bent at all.
    static constexpr float kCeilingKnee = 0.75f * kOutputCeiling;   // ≈ −3.5 dBFS

    /// Transparent below the knee; smoothly asymptotic to the ceiling above it.
    /// Continuous in value and slope at the knee, so there is no edge to hear.
    static inline float softCeil(float x) noexcept {
        const float a = std::fabs(x);
        if (a <= kCeilingKnee) return x;
        const float span = kOutputCeiling - kCeilingKnee;
        const float over = (a - kCeilingKnee) / span;
        const float bent = kCeilingKnee + span * (over / std::sqrt(1.0f + over * over));
        return (x < 0.0f) ? -bent : bent;
    }

    /// INPUT EXPANDER — the quiet answer to a noisy front end.
    ///
    /// A guitar at mic level brings its own hiss, and every dB of gain after it
    /// brings the hiss too. This works only BELOW the threshold, so it is doing
    /// nothing at all while a note is sounding. Below the line it is a 3:1 downward
    /// expander (`t·t`), not a gate — the gain slides rather than switching, so a
    /// note decaying through the threshold keeps its tail instead of being cut off
    /// at it, and there is no edge to hear opening and closing.
    ///
    /// −62 dBFS, NOT −50. Reported by ear on an iPhone 17e: chords sounded uneven
    /// and dulled and clean tones crackled faintly, and both were this. A guitar
    /// arriving through a headphone adapter is ~40 dB down, which put ordinary
    /// playing — and every chord's decay — right ON the old threshold instead of
    /// 30 dB above it, so the expander was working during notes rather than
    /// between them. 12 dB lower puts real playing clear of it again.
    /// −56 dBFS. It went to −62 to stop the expander chewing chords, and that
    /// worked — but the real culprit was the UNSMOOTHED gain below, not the line
    /// itself, and −62 gave up 6 dB of hiss suppression to fix something the
    /// smoothing had already fixed. Reported back as "there's still some
    /// background noise", which is exactly that 6 dB. Still ~35 dB under a played
    /// note, so a chord's useful decay never reaches it.
    static constexpr float kGateThreshold = 0.0016f;    // −56 dBFS

    /// EXPANSION RATIO below the line: 4:1, was 3:1 (`t·t` → `t·t·t`).
    ///
    /// This is the lever that kills hiss WITHOUT touching playing, and it is
    /// better than raising the threshold further. Above the line `t` clamps to 1
    /// and the exponent is irrelevant — a note is untouched no matter what this
    /// is. Below it, every extra power pushes the quiet stuff down harder: 10 dB
    /// under the line, 3:1 gives −20 dB and 4:1 gives −30 dB. Hiss is steady and
    /// sits well below; that is what makes it hiss, and what makes it the only
    /// thing this reaches.
    static constexpr int kGateRatioPowers = 3;

    /// GAIN SMOOTHING, and the actual cause of the crackle. The computed gain used
    /// to be applied straight from the envelope, per sample. That envelope is a
    /// peak follower with a 1 ms attack, so on a low note it RIPPLES at the
    /// waveform rate — and `t·t` squares the ripple. The result is amplitude
    /// modulation at audio rate: sidebands on a sustained note, and a chord whose
    /// individual strings appear to wobble as the sum decays past the threshold.
    ///
    /// A gain that may only fall slowly cannot modulate at audio rate. Opening
    /// stays fast so no pick attack is ever late — that asymmetry is the whole
    /// design: instant when a note arrives, molasses on the way back down.
    static constexpr double kGateOpenSec  = 0.001;   // 1 ms — never late
    static constexpr double kGateCloseSec = 0.250;   // 250 ms — never rippling

    /// THE THRESHOLD FOLLOWS THE GAIN, because the problem it solves does.
    ///
    /// A fixed threshold cannot serve both ends of this app. Reported by ear: at
    /// −62 dBFS a clean tone is perfect, and a high-gain patch roars between notes
    /// — obviously so, because the preamp cascade amplifies the noise floor by
    /// tens of dB before anyone hears it, and the gate is sitting in front of all
    /// of that judging the raw input. Raise it to suit high gain and clean chords
    /// get chewed again; that is the exact trade that produced the first bug.
    ///
    /// So it scales with amp drive: the more the amp is about to amplify, the
    /// higher the line has to be to hold the same noise DOWNSTREAM. This is also
    /// what a guitarist does by hand — more gain, more gate. It is safe here in a
    /// way it was not before because the gain is smoothed now: a higher threshold
    /// can no longer put ripple on a note, only pull its far tail down sooner.
    ///
    /// Clean stays at −62 dBFS; a cranked amp lands near −45.
    static constexpr float kGateDriveRef = 2.0f;    // drive at/below this = base
    static constexpr float kGateMaxScale = 8.0f;    // ≈ +18 dB at full gain
    float gateEnv[8]{};
    /// The expander's SMOOTHED gain, per channel. Starts open so the very first
    /// buffer after a reset is not faded in.
    float gateGain[8] = {1, 1, 1, 1, 1, 1, 1, 1};

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
