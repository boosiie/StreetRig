//
//  DrivePedal.hpp
//  StreetRig
//
//  The overdrive / distortion / fuzz gain stage — now PER-MODEL voiced. It is
//
//      pre-emphasis (voicing HP + optional pre-clip mid)
//        → 4× OVERSAMPLED nonlinear clip (soft / hard / fuzz, per-model asymmetry,
//          optional 2-stage cascade for Big-Muff-style sustain)
//        → optional post-clip mid (Muff / Metal-Zone scoop)
//        → DC block → post tone low-pass → output level × per-model trim
//
//  WHY oversample (requirement 1 + 6): a static nonlinearity manufactures harmonics
//  above Nyquist that fold back as inharmonic aliasing. Running the clip at 4× with
//  a windowed-sinc FIR up and down band-limits those images before decimation. Only
//  the clip is oversampled; the linear voicing biquads do not alias.
//
//  Each pedal MODEL is a `Voicing` (Tube Screamer, RAT, Big Muff, Klon, …). The
//  chain compiler picks it from the model name (ParameterMap.pedalVoicing) and it is
//  applied at SETUP time (configure, under the reconfigure barrier). `Voicing`
//  chooses the pre/post filters, clip shape, asymmetry, drive scaling, cascade and
//  output trim — so a Tube Screamer, a RAT and a Big Muff sound like different
//  circuits, not one waveshaper with three presets. Drive / tone / level stay
//  CONTINUOUS knobs pushed live and de-zippered here.
//
//  REAL-TIME CONTRACT: `prepare()` / `configure()` design filters + allocate (setup
//  thread). `process()` allocates nothing, locks nothing, does no I/O, keeps
//  per-channel state so a stereo path never crosstalks. See RealtimeSafety.md.
//

#ifndef STREETRIG_DRIVE_PEDAL_HPP
#define STREETRIG_DRIVE_PEDAL_HPP

#include <algorithm>
#include <cmath>
#include "../AnalogAmp.hpp"   // streetrig::Biquad

namespace streetrig {

class DrivePedal {
public:
    static constexpr int kMaxChannels = 2;
    static constexpr int kOversample  = 4;
    static constexpr int kFirTaps      = 48;
    static constexpr int kPhaseTaps    = kFirTaps / kOversample;

    /// Raw waveshaper families.
    enum Clip : int { Soft = 0, Hard = 1, Fuzz = 2 };

    /// Per-model voicings. 0/1/2 stay the generic soft/hard/fuzz fallbacks (back-
    /// compat); models are 3+. MUST match ParameterMap.voice* (Swift).
    enum Voicing : int {
        GenericSoft = 0, GenericHard = 1, GenericFuzz = 2,
        TubeScreamer = 3, Bluesbreaker = 4, Klon = 5, KingOfTone = 6, OCD = 7,
        DS1 = 8, MetalZone = 9, RAT = 10, BigMuff = 11, FuzzFace = 12,
        FuzzFactory = 13, CleanBoost = 14
    };

    void prepare(double sampleRate, int numChannels);

    /// (Re)voice the block for a pedal MODEL — designs the pre/mid/post filters for
    /// every channel and sets the clip/gain profile. Setup thread only (called from
    /// the reconfigure barrier). Keeps the running oversampler state.
    void configure(int voicing) noexcept;

    void reset() noexcept;

    /// Process `n` samples in place for `channel`. drive/level de-zippered here;
    /// toneCutHz → one-pole coefficient once per buffer. Real-time safe.
    void process(float *buffer, int n, int channel,
                 float drive, float toneCutHz, float level) noexcept;

private:
    /// Per-model constants resolved by `voiceFor`. dB = 0 means "filter disabled".
    struct Voice {
        double preHz = 100.0;                            // input tightening high-pass
        double preMidHz = 0.0, preMidQ = 0.8, preMidDB = 0.0;   // pre-clip mid/treble
        double postMidHz = 0.0, postMidQ = 0.8, postMidDB = 0.0; // post-clip scoop
        int    clip = Soft;
        float  asym = 0.15f;                             // clip bias (even harmonics)
        float  driveScale = 1.0f;                        // extra gain into the clip
        float  outTrim = 1.0f;                           // level match across models
        bool   twoStage = false;                         // Big-Muff cascade
    };
    static Voice voiceFor(int voicing) noexcept;

    float  fir_[kFirTaps] = {};
    double sampleRate_ = 48000.0;
    double osRate_ = 192000.0;
    int    numChannels_ = 1;
    int    voicing_ = TubeScreamer;
    bool   ready_ = false;
    float  smoothCoeff_ = 0.0f;
    Voice  v_;

    struct ChannelState {
        Biquad pre;                         // voicing high-pass
        Biquad preMid;                      // pre-clip mid / treble emphasis
        Biquad postMid;                     // post-clip mid scoop (Muff / Metal Zone)
        float upHist[kPhaseTaps] = {};
        int   upPos = 0;
        float downHist[kFirTaps] = {};
        int   downPos = 0;
        float toneState = 0.0f;
        float dcX1 = 0.0f, dcY1 = 0.0f;
        float smDrive = 1.0f, smLevel = 1.0f;
    };
    ChannelState ch_[kMaxChannels];

    /// Waveshaper with per-model asymmetry. Bounded output (~±1); DC from the bias
    /// is removed by subtracting the shape at x = 0 (plus the downstream DC blocker).
    static inline float shape(float x, int clip, float asym) noexcept {
        switch (clip) {
            case Hard: {
                float y   = std::tanh(1.6f * (x + asym)) - std::tanh(1.6f * asym);
                float lin = std::max(-1.0f, std::min(1.0f, 1.3f * (x + asym)))
                          - std::max(-1.0f, std::min(1.0f, 1.3f * asym));
                return 0.85f * y + 0.15f * lin;
            }
            case Fuzz: {
                float b = 0.45f + asym;
                return 0.9f * (std::tanh(3.0f * x + b) - std::tanh(b));
            }
            case Soft:
            default: {
                float b = 0.15f + asym;
                return std::tanh(x + b) - std::tanh(b);
            }
        }
    }
};

} // namespace streetrig

#endif /* STREETRIG_DRIVE_PEDAL_HPP */
