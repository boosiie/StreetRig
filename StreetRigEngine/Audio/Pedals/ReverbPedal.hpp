//
//  ReverbPedal.hpp
//  StreetRig
//
//  The reverb family (.reverb) — a DATTORRO PLATE tank, voiced four ways. Like
//  delay, `.reverb` used to map to `typeTransparent`, so VOSS Reverb and
//  electro-harmonium HOLY GRAIL held their chain position and did nothing.
//
//  WHY DATTORRO AND NOT SCHROEDER. The cheap classic (four parallel combs into
//  two all-passes) costs about half as much and rings: on a sustained chord its
//  comb peaks line up into a metallic "boing" that a guitarist notices
//  immediately, because a held chord is exactly the signal that exposes it.
//  Dattorro's figure-of-eight tank replaces the parallel combs with two
//  cross-coupled branches of all-pass diffusers and delays, and MODULATES the
//  first all-pass in each branch so no mode can sit still long enough to ring.
//  It costs roughly two biquad chains more, which is nothing against the board
//  budget, and — the deciding factor — it is a PUBLISHED topology with
//  known-good constants, so building it is transcription rather than invention.
//
//      in → pre-delay → bandwidth LP → AP(142) → AP(107) → AP(379) → AP(277)
//                                                                      │
//        ┌───────────────────────────────────────────────────────────┐ │
//        │  LEFT :  modAP(672) → delay(4453) → damp → ×decay         │ │
//        │          → AP(1800) → delay(3720) → ×decay ──┐            │ │
//        │  RIGHT:  modAP(908) → delay(4217) → damp → ×decay         │ │
//        │          → AP(2656) → delay(3163) → ×decay ──┘ (crossed)  │ │
//        └───────────────────────────────────────────────────────────┘ │
//                                   ↑ each branch is fed by x ─────────┘
//                                     plus the OTHER branch's output
//
//  Output is seven taps read from four points inside the tank — that scatter is
//  what makes the tail sound like a space rather than like a delay line.
//
//  The line lengths above are Dattorro's, specified at his 29761 Hz reference
//  rate; they are SCALED to the running sample rate at `setBuffer()` time so the
//  reverb sounds the same at 44.1, 48 or 96 kHz. Using them unscaled (as many
//  ports do) would make the tank 60 % shorter at 48 kHz and change its character
//  with the audio interface, which is not a thing a plate does.
//
//  FOUR VOICINGS, all the same tank with different pre-delay, diffusion,
//  bandwidth, modulation and decay scaling — plus a dispersion chain the spring
//  voicing alone runs:
//    • PLATE  (0) — VOSS Reverb / RV-6. The reference voicing: bright, dense,
//                   short pre-delay. This is Dattorro's plate as published.
//    • SPRING (1) — electro-harmonium HOLY GRAIL. Darker, less diffuse, longer
//                   pre-delay, deeper modulation, and a cascade of first-order
//                   all-passes in front of the tank so a transient smears
//                   upward the way it does travelling down a spring. It is a
//                   dispersion FLAVOUR, not a true spring model (see the notes).
//    • ROOM   (2) — short, dry-ish, bright: the Katana's ROOM block.
//    • HALL   (3) — long pre-delay, maximum diffusion, longest decay scaling.
//
//  DENORMALS ARE THE REAL HAZARD HERE, more than in any other block in the app.
//  A reverb tail decays exponentially and never reaches zero, so minutes after
//  the last note the tank's states are tiny — and once they fall below ~1.18e-38
//  every multiply in the tank becomes a denormal operation. On the cores where
//  that traps to microcode it is ~100× slower, which presents as the render load
//  spiking on a SILENT rig. Every recursive state in this file is flushed to zero
//  well before it can get there.
//
//  MEMORY: like DelayPedal, this engine owns no buffer — the whole tank is
//  sub-allocated from the slot's span of `PedalChain`'s arena (≈ 59 k floats per
//  channel at 48 kHz, inside a 131 072-float block). See PedalChain.hpp.
//
//  REAL-TIME CONTRACT: `prepare()` / `configure()` / `setBuffer()` are setup
//  thread. `process()` allocates nothing, locks nothing, does no I/O, and keeps
//  per-channel state so a stereo path never crosstalks. See RealtimeSafety.md.
//

#ifndef STREETRIG_REVERB_PEDAL_HPP
#define STREETRIG_REVERB_PEDAL_HPP

#include <atomic>

#include "TimeBlockSupport.hpp"

namespace streetrig {

class ReverbPedal {
public:
    static constexpr int kMaxChannels = 2;
    /// 4 input diffusers + 4 tank all-passes + 4 tank delays + pre-delay.
    static constexpr int kNumLines = 13;
    /// Spring dispersion cascade length (first-order all-passes, no storage).
    static constexpr int kDispersion = 12;

    /// MUST match ParameterMap.reverb* (Swift).
    enum Voicing : int { Plate = 0, Spring = 1, Room = 2, Hall = 3 };

    // --- Setup thread ---
    void prepare(double sampleRate, int numChannels) noexcept;
    void configure(int voicing) noexcept;
    void reset() noexcept;

    /// Hand the engine its slice of `PedalChain`'s arena and lay the tank out
    /// inside it. `base` addresses `kMaxChannels * floatsPerChannel` floats. The
    /// span is zeroed and the pointer published with a RELEASE store, so the
    /// render thread only ever sees a fully-built tank — the same discipline
    /// `AmpCabProcessor` uses to hand over a neural model. Setup thread only;
    /// `nullptr` un-publishes and the engine degrades to a pass-through.
    void setBuffer(float *base, int floatsPerChannel) noexcept;

    bool hasBuffer() const noexcept { return buf_.load(std::memory_order_acquire) != nullptr; }

    /// No reported latency: the dry path is summed un-delayed with the wet send,
    /// so the block's group delay at DC is zero. (The tank's own pre-delay is
    /// inside the WET path only, which is a reverb parameter, not latency.)
    static constexpr int latencySamples() noexcept { return 0; }

    // --- Audio thread ---
    /// params: [0] tank decay 0…0.92, [1] damping low-pass Hz, [2] wet 0…1
    /// (dry stays at 1.0).
    void process(float *buffer, int n, int channel, const float *params) noexcept;

private:
    /// One delay line inside the tank: an offset into the slot's span, a power-
    /// of-two capacity (so the pointer wraps with a mask), the length actually
    /// used, and its own write head.
    struct Line {
        int offset = 0;
        int mask = 0;
        int length = 1;
    };

    /// Per-model constants. THE ONE AUDITABLE TABLE for this family, with the
    /// §11.6 listening cues beside the values — same arrangement as
    /// `DrivePedal::voiceFor` and `AmpProfile::profileFor`.
    struct Voice {
        float preDelayMs = 8.0f;
        float bandwidth = 0.9995f;   ///< input low-pass, as a one-pole coefficient
        float inDiff1 = 0.750f;      ///< first two input diffusers
        float inDiff2 = 0.625f;      ///< second two
        float decayDiff1 = 0.700f;   ///< modulated tank all-passes
        float decayDiff2 = 0.500f;   ///< second tank all-passes
        float excursion = 8.0f;      ///< tank all-pass modulation, in samples @29761
        float modHz = 0.70f;
        /// Multiplies EVERY line length: this is the tank's physical SIZE, and
        /// it is what separates a room from a hall far more than the decay does.
        float sizeScale = 1.0f;
        float decayScale = 1.0f;     ///< multiplies the Decay knob's tank feedback
        float dispersion = 0.0f;     ///< 0 = off; spring's all-pass chain coefficient
        float trim = 1.0f;           ///< wet-path level match across voicings
    };
    static Voice voiceFor(int voicing) noexcept;

    double sampleRate_ = 48000.0;
    int    numChannels_ = 1;
    int    voicing_ = Plate;
    bool   ready_ = false;
    Voice  v_;

    std::atomic<float *> buf_{nullptr};
    int   lineFloats_ = 0;          ///< floats per channel in the slot's span
    Line  lines_[kNumLines];
    int   preDelaySamples_ = 0;
    float modInc_ = 0.0f;           ///< tank all-pass LFO increment (rad/sample)
    float excursionSamples_ = 0.0f;
    /// Output tap offsets, scaled to the running rate (Dattorro's seven taps).
    int   tap_[7] = {};

    struct ChannelState {
        int   write[kNumLines] = {};
        float damp[2] = {};          ///< per-branch damping low-pass state
        float bandwidth = 0.0f;      ///< input low-pass state
        float cross = 0.0f;          ///< the tank's figure-of-eight feedback node
        float disperse[kDispersion] = {};   ///< spring all-pass memory (x[n-1])
        float disperseY[kDispersion] = {};
        float modPhase = 0.0f;
    };
    ChannelState ch_[kMaxChannels];

    // --- Line access (audio thread) ---
    inline float tapAt(float *span, const Line &l, const ChannelState &s, int idx, int back) const noexcept {
        // A tap deeper than the line is clamped rather than wrapped, so a scaled
        // tap position can never read a sample that has not been written yet.
        const int b = back < l.length ? back : (l.length - 1);
        const int p = (s.write[idx] - b) & l.mask;
        return span[l.offset + p];
    }
};

} // namespace streetrig

#endif /* STREETRIG_REVERB_PEDAL_HPP */
