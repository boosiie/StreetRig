//
//  DrivePedal.hpp
//  StreetRig
//
//  Prompt 003 — the one pedal category that needs REAL DSP now: overdrive /
//  distortion / fuzz. It is a gain stage built as
//
//      pre-emphasis (voicing HP + optional mid hump)
//        → 4× OVERSAMPLED nonlinear clip (soft / hard / asymmetric fuzz)
//        → DC block → post tone low-pass → output level
//
//  WHY oversample (requirement 1 + 6): a static nonlinearity manufactures
//  harmonics above Nyquist that fold back as inharmonic aliasing ("digital
//  fizz"). Running the clip at 4× with a windowed-sinc FIR on the way up and down
//  band-limits those images before decimation. The linear voicing/tone biquads do
//  not alias, so only the clip is oversampled. The oversampler reuses the exact
//  proven polyphase structure from AnalogAmp.
//
//  ONE BLOCK PER OWNED DRIVE PEDAL. `character` (soft/hard/fuzz) is a SETUP-time
//  property chosen by the chain compiler from the pedal model (Tube Screamer =
//  soft mid-hump, ProCo RAT = hard/bright, Big Muff / Fuzz Face = asymmetric
//  fuzz). Drive / tone / level are CONTINUOUS knobs pushed live through the
//  lock-free bus and de-zippered here.
//
//  EXTENSION POINT: other pedal categories (comp, mod, delay, …) plug into the
//  same PedalChain as additional block types; only drive needs real DSP for now,
//  so every non-drive slot is a transparent pass-through (see PedalChain).
//
//  REAL-TIME CONTRACT: `prepare()` / `configure()` design filters + allocate
//  (setup thread). `process()` allocates nothing, locks nothing, does no I/O and
//  keeps per-channel state so a stereo path never crosstalks. See RealtimeSafety.md.
//

#ifndef STREETRIG_DRIVE_PEDAL_HPP
#define STREETRIG_DRIVE_PEDAL_HPP

#include <algorithm>
#include "../AnalogAmp.hpp"   // streetrig::Biquad

namespace streetrig {

class DrivePedal {
public:
    static constexpr int kMaxChannels = 2;
    static constexpr int kOversample  = 4;            // 4× around the clip.
    static constexpr int kFirTaps      = 48;          // multiple of kOversample.
    static constexpr int kPhaseTaps    = kFirTaps / kOversample;

    /// Clip character. SETUP-time property of a slot (chosen per pedal model).
    enum Character : int { Soft = 0, Hard = 1, Fuzz = 2 };

    /// Design the shared oversampling FIR and allocate. Setup thread.
    void prepare(double sampleRate, int numChannels);

    /// (Re)voice the block for a clip character — designs the pre/mid/DC filters
    /// for every channel. Setup thread only (called from the reconfigure barrier,
    /// with the render thread parked). Keeps the running oversampler state.
    void configure(int character) noexcept;

    /// Clear all filter / oversampler state. Real-time safe.
    void reset() noexcept;

    /// Process `n` samples in place for `channel`.
    ///   `drive`     linear pre-gain into the clip (higher = more dirt),
    ///   `toneCutHz` post low-pass cutoff in Hz (brightness),
    ///   `level`     linear output gain.
    /// drive/level are de-zippered here; toneCutHz is turned into a one-pole
    /// coefficient once per buffer. Real-time safe.
    void process(float *buffer, int n, int channel,
                 float drive, float toneCutHz, float level) noexcept;

private:
    float  fir_[kFirTaps] = {};
    double sampleRate_ = 48000.0;
    double osRate_ = 192000.0;             // sampleRate_ * kOversample
    int    numChannels_ = 1;
    int    character_ = Soft;
    bool   ready_ = false;
    float  smoothCoeff_ = 0.0f;            // ~5 ms de-zipper one-pole.

    struct ChannelState {
        Biquad pre;                         // voicing high-pass (tighten lows)
        Biquad mid;                         // optional mid emphasis (screamer)
        float upHist[kPhaseTaps] = {};      // base-rate polyphase-up history
        int   upPos = 0;
        float downHist[kFirTaps] = {};      // OS-rate decimation FIR history
        int   downPos = 0;
        float toneState = 0.0f;             // post one-pole low-pass memory
        float dcX1 = 0.0f, dcY1 = 0.0f;     // DC blocker memory
        float smDrive = 1.0f, smLevel = 1.0f;
    };
    ChannelState ch_[kMaxChannels];

    /// Waveshaper — selected by `character_`. Bounded output (~±1).
    static inline float clip(float x, int character) noexcept {
        switch (character) {
            case Hard: {
                // Harder knee, a touch brighter/edgier (RAT-ish): fast-approach
                // tanh then a soft ceiling.
                float y = std::tanh(1.6f * x);
                return 0.85f * y + 0.15f * std::max(-1.0f, std::min(1.0f, 1.3f * x));
            }
            case Fuzz: {
                // Very asymmetric, near-square with a rounded top (Muff/Fuzz-Face
                // flavour): strong even + odd harmonics, gated-ish bottom.
                constexpr float bias = 0.45f;
                float y = std::tanh(3.0f * x + bias) - std::tanh(bias);
                return 0.9f * y;
            }
            case Soft:
            default: {
                // Smooth asymmetric soft clip (tube-screamer flavour): the bias
                // adds even harmonics; subtracting tanh(bias) removes the DC step.
                constexpr float bias = 0.15f;
                return std::tanh(x + bias) - std::tanh(bias);
            }
        }
    }
};

} // namespace streetrig

#endif /* STREETRIG_DRIVE_PEDAL_HPP */
