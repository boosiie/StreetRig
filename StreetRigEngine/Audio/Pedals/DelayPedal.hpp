//
//  DelayPedal.hpp
//  StreetRig
//
//  The delay family (.delay) — ONE recirculating line, THREE genuinely different
//  circuits around it. Until now `.delay` mapped to `typeTransparent`: the pedal
//  held its position in the chain and passed audio through untouched, which made
//  VOSS Digital Delay, DUNLAP ECHOPLEX and electro-harmonium MEMORY MAN mute
//  decorations. This is the engine that makes them audible.
//
//    • DIGITAL (0) — VOSS Digital Delay / DD-8. Clean, full-bandwidth repeats.
//      Linear interpolation, one feedback-path low-pass to stop the repeats from
//      getting BRIGHTER than the dry (which is what an unfiltered loop does), and
//      — the part that makes it digital — a CROSSFADE when the time changes, so
//      the pitch never moves.
//
//    • TAPE (1) — DUNLAP ECHOPLEX / EP-3. Hermite reads, wow (0.5 Hz) and
//      flutter (6 Hz) on the read pointer, a saturating record stage and a
//      two-pole 4.5 kHz roll-off on the RECORD side so every repeat is darker,
//      softer and a
//      little more wobbly than the one before it, plus the EP-3's output preamp
//      — a broad midrange lift, applied once, downstream. Time changes SLEW, so
//      turning the Time knob glides the pitch as dragging a tape head does.
//
//  RECORD SIDE vs PLAYBACK SIDE, and why the difference matters. The colour of a
//  tape or bucket-brigade echo comes from what the MEDIUM does, and the medium is
//  written to once per pass — so the saturation, the bandwidth loss and the
//  companding all sit on the write path, where their effect compounds: repeat six
//  has been through them six times. The machine's output amplifier is downstream
//  of the playback head and colours each repeat exactly ONCE, so it sits outside
//  the loop. Collapsing the two (a natural first cut) puts the EP-3 preamp's
//  upper-mid lift inside the loop, where it cancels the very bandwidth loss that
//  makes tape sound like tape — measurably: with the lift inside, the tape
//  voicing lost only 19 % of its top by repeat three against digital's 17 %.
//
//    • BBD (2) — Deluxe Memory Man. Hermite reads, a bucket-brigade voicing:
//      two-pole 2.5 kHz filtering, COMPANDING (compress in, expand out — the
//      thing that actually makes a BBD sound like a BBD, because it squashes the
//      quiet parts of every repeat and then re-expands them along with the
//      chip's noise), an envelope-tracked noise floor, and a slow chorus on the
//      read pointer. Time changes slew and bend, like the tape voicing.
//
//  THE TWO OPPOSITE CORRECT BEHAVIOURS ON A TIME CHANGE. A naive delay clicks
//  when the Time knob moves, because the read pointer teleports and the waveform
//  steps. There are two right answers and the voicing chooses between them:
//  a digital delay must NOT change pitch (so it crossfades between the old and
//  new read positions over ~30 ms, which is inaudible and pitch-preserving),
//  while a tape or bucket-brigade delay MUST change pitch (so its read pointer is
//  slewed with a ~100 ms one-pole and the repeats glide). Implementing only the
//  first would make the Echoplex sound like a rack unit; only the second would
//  make the DD-8 sound broken. Both are here on purpose.
//
//  MEMORY: this engine OWNS NO BUFFER. Its line is a span of `PedalChain`'s one
//  preallocated arena, handed over by `setBuffer()` on the setup thread inside
//  the reconfigure barrier. That is the whole reason delay was deferred: eight
//  slots × a multi-second stereo line is far too much to embed per slot when most
//  rigs use none. See PedalChain.hpp for the arena's footprint.
//
//  REAL-TIME CONTRACT: `prepare()` / `configure()` / `setBuffer()` are setup
//  thread and are the only places anything is designed or cleared. `process()`
//  allocates nothing, locks nothing, does no I/O, evaluates no filter design, and
//  keeps per-channel state so a stereo path never crosstalks. Every value written
//  into the line passes through `sanitize()` — a NaN in a feedback loop never
//  leaves on its own. See RealtimeSafety.md.
//

#ifndef STREETRIG_DELAY_PEDAL_HPP
#define STREETRIG_DELAY_PEDAL_HPP

#include <atomic>

#include "TimeBlockSupport.hpp"
#include "../AnalogAmp.hpp"   // streetrig::Biquad, OnePoleLP, OnePoleHP

namespace streetrig {

class DelayPedal {
public:
    static constexpr int kMaxChannels = 2;

    /// MUST match ParameterMap.delay* (Swift).
    enum Voicing : int { Digital = 0, Tape = 1, BBD = 2 };

    /// How a time change is resolved. Not a user control — a property of the
    /// circuit being modelled (see the header note).
    enum TimeMode : int { Crossfade = 0, Glide = 1 };

    // --- Setup thread ---
    void prepare(double sampleRate, int numChannels) noexcept;
    void configure(int voicing) noexcept;
    void reset() noexcept;

    /// Hand the engine its slice of `PedalChain`'s arena: `base` addresses
    /// `kMaxChannels * floatsPerChannel` floats and `floatsPerChannel` MUST be a
    /// power of two (the read/write pointers wrap with a mask, not a modulo).
    /// The span is zeroed here and the pointer is published with a RELEASE store,
    /// so the render thread can only ever observe a fully-cleared buffer — the
    /// same publish discipline `AmpCabProcessor` uses for a neural model. Setup
    /// thread only. Passing `nullptr` un-publishes the line and the engine
    /// degrades to a pass-through rather than touching a dangling pointer.
    void setBuffer(float *base, int floatsPerChannel) noexcept;

    /// True once a line has been assigned (diagnostics / main thread).
    bool hasBuffer() const noexcept { return buf_.load(std::memory_order_acquire) != nullptr; }

    /// This block adds NO reported latency: the dry path is never delayed, only
    /// summed with a wet send, so the group delay at DC is zero. Kept as an
    /// explicit accessor so the latency accounting in the kernel stays honest if
    /// that ever changes. Main thread.
    static constexpr int latencySamples() noexcept { return 0; }

    // --- Audio thread ---
    /// params: [0] time ms, [1] feedback 0…0.95, [2] wet 0…1 (dry stays at 1.0),
    /// [3] feedback-path low-pass Hz (<= 0 → the voicing's own corner),
    /// [4] modulation depth 0…1 (scales the voicing's own wobble).
    void process(float *buffer, int n, int channel, const float *params) noexcept;

private:
    /// Per-model constants. THE ONE AUDITABLE TABLE for this family, with the
    /// research document's listening cue beside the value it describes — the same
    /// arrangement `DrivePedal::voiceFor` and `AmpProfile::profileFor` use, so the
    /// owner can ear-tune through an iRig without reading DSP.
    struct Voice {
        TimeMode timeMode = Crossfade;
        bool  hermite = false;        ///< 4-point read instead of linear
        float fbLowpassHz = 8000.0f;  ///< RECORD-side low-pass when no Tone knob
        float fbHighpassHz = 0.0f;    ///< record-side high-pass (tape head loss)
        float satDrive = 0.0f;        ///< 0 = no record-stage saturation
        /// The EP-3's OUTPUT preamp, as a broad mid PEAK rather than a treble
        /// shelf — see the .cpp for why the obvious shelf is the wrong shape.
        float preampHz = 0.0f;        ///< 0 = no preamp stage
        float preampQ = 0.7f;
        float preampDB = 0.0f;
        bool  twoPoleLP = false;      ///< second pole (tape head loss / BBD filters)
        float compandAmount = 0.0f;   ///< 0 = none; BBD companding depth
        float noiseFloor = 0.0f;      ///< envelope-tracked hiss (BBD only)
        float wowHz = 0.0f, wowDepth = 0.0f;        ///< fraction of the delay time
        float flutterHz = 0.0f, flutterDepth = 0.0f;
        float trim = 1.0f;            ///< wet-path level match across voicings
    };
    static Voice voiceFor(int voicing) noexcept;

    double sampleRate_ = 48000.0;
    int    numChannels_ = 1;
    int    voicing_ = Digital;
    bool   ready_ = false;
    Voice  v_;

    /// The arena span. ATOMIC because a slot can BECOME a delay while the engine
    /// is live: the pointer is published only after the memory is zeroed, and the
    /// render thread bails out to a pass-through on nullptr. Nothing is ever
    /// freed — the arena outlives every assignment — so the one-generation retire
    /// half of the neural-model pattern has nothing to do here.
    std::atomic<float *> buf_{nullptr};
    int  lineLen_ = 0;          ///< floats per channel (power of two)
    int  lineMask_ = 0;
    float maxDelay_ = 0.0f;     ///< usable read distance, in samples

    float slewCoeff_ = 0.0f;    ///< ~100 ms: the glide voicings' pitch bend
    float xfadeStep_ = 0.0f;    ///< 1 / 30 ms: the digital voicing's de-click
    float envCoeff_ = 0.0f;     ///< companding / noise-gating envelope follower
    float dcCoeff_ = 0.0f;      ///< 20 Hz DC blocker in the feedback path

    struct ChannelState {
        int   writePos = 0;
        float delaySamples = 0.0f;      ///< the live read distance
        float pendingDelay = 0.0f;      ///< crossfade target (digital)
        float xfade = 1.0f;             ///< 1 = settled, <1 = crossfading
        float fbLP = 0.0f;              ///< one-pole low-pass state
        float fbLP2 = 0.0f;             ///< BBD's second pole
        float fbHPx1 = 0.0f, fbHPy1 = 0.0f;
        Biquad preamp;                  ///< EP-3 upper-mid lift
        float dcX1 = 0.0f, dcY1 = 0.0f;
        float env = 0.0f;               ///< companding / noise envelope
        float wowPhase = 0.0f, flutterPhase = 0.0f;
        LcgNoise noise;
    };
    ChannelState ch_[kMaxChannels];

    inline float readLine(const float *line, float readPos) const noexcept {
        return v_.hermite ? interpHermite(line, lineMask_, readPos)
                          : interpLinear(line, lineMask_, readPos);
    }
};

} // namespace streetrig

#endif /* STREETRIG_DELAY_PEDAL_HPP */
