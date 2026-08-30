//
//  ParameterMap.swift
//  StreetRig
//
//  Prompt 003 — THE ONE AUDITABLE TABLE that maps every on-screen rig knob to a
//  DSP control value. The UI knobs/sliders live on the 0…10 Marswell-style scale
//  (GearParameter.min…max, default 5 = noon); this file turns a (category, param
//  name, 0…10 value) into the concrete DSP unit the kernel wants (gain, dB,
//  cutoff Hz, clip character, cab slot, …) with a musically sensible, documented
//  curve. It is deliberately the SINGLE place these ranges live so they can be
//  ear-tuned on real iRig hardware without hunting through the DSP.
//
//  Everything here is pure + value-typed (no engine, no state) so it is trivially
//  testable and callable from the chain compiler AND the offline harness.
//
//  NOTE: these are a FIRST PASS chosen by ear-reasoning, not measured against a
//  real amp. Noon (knob = 5) is designed to land on sensible unity-ish values
//  (amp drive ≈ 3, master ≈ unity, tone bands ≈ flat/0 dB) so an untouched rig
//  already sounds like an amp. Final feel needs on-device tuning (see report).
//

import Foundation

public enum ParameterMap {

    /// Normalize a 0…10 knob to 0…1 (clamped).
    @inline(__always) static func norm(_ v: Double) -> Float {
        Float(min(max(v / 10.0, 0.0), 1.0))
    }

    // MARK: - Amp head / combo (Gain, Bass, Mid, Treble, Presence, Master)

    /// Amp "Gain" → linear pre-gain into the amp nonlinearity (SRParamAmpDrive).
    /// Exponential so the knob feels even: knob 0 → 0.6, 5 → ≈3.0, 10 → ≈13.6.
    static func ampDrive(gainKnob v: Double) -> Float {
        0.6 * powf(2.0, norm(v) * 4.5)
    }

    /// Amp "Master" → post-amp makeup/master gain (SRParamAmpMakeup). Linear,
    /// unity at noon: knob 0 → 0.2, 5 → 1.0, 10 → 1.8.
    static func ampMaster(masterKnob v: Double) -> Float {
        0.2 + norm(v) * 1.6
    }

    /// Amp tone band → shelf/peak gain in dB. Flat (0 dB) at noon so a centered
    /// EQ is transparent. Bass/Mid/Treble span ±12 dB; Presence a gentler ±9 dB.
    static func ampBandDB(_ paramName: String, knob v: Double) -> Float {
        let bipolar = (norm(v) - 0.5) * 2.0    // -1…+1, 0 at noon
        switch paramName {
        case "Presence", "Cut": return bipolar * 9.0
        case "Mid":
            // ASYMMETRIC, and that is the physics rather than a taste call. A
            // passive TMB stack's mid control is mostly a CUT: turning it down
            // scoops hard, turning it up mostly just stops scooping. It has very
            // little boost above centre because the network cannot make gain.
            //
            // Modelled as a symmetric ±12 dB it was a 10 dB resonant peak at
            // Q 0.85–0.95, and a resonant midrange peak is exactly what a wah
            // pedal is — reported by ear as "the tone sounds like a wah when it's
            // set to the max side". Full cut, a third of the boost.
            return bipolar < 0 ? Float(bipolar) * 12.0 : Float(bipolar) * 4.0
        default:         return bipolar * 12.0 // Bass / Treble
        }
    }

    /// Which SRParameterAddress an amp tone-band name drives (nil if not a band).
    static func ampBandAddress(_ paramName: String) -> SRParameterAddress? {
        switch paramName {
        case "Bass":     return SRParamAmpBass
        case "Mid":      return SRParamAmpMid
        case "Treble":   return SRParamAmpTreble
        // CUT is the HV28's name for the same control, and the profile's negative
        // presenceScale is what makes it run backwards. One destination, two labels.
        case "Presence", "Cut": return SRParamAmpPresence
        default:         return nil
        }
    }

    /// Amp "Volume" → linear gain INTO the power amp (SRParamAmpVolume). Same
    /// shape as `ampMaster`, unity at noon, because it is the same kind of
    /// control — it just sits one stage earlier, which is the whole point: it
    /// decides how hard the character drives the output valves, while Master
    /// sets the room level. Knob 0 → 0.2, 5 → 1.0, 10 → 1.8.
    public static func ampVolume(volumeKnob v: Double) -> Float {
        0.2 + norm(v) * 1.6
    }

    // MARK: - Power control (0.5 W / 50 W / 100 W)

    /// The three power settings, in panel order. Stored on the gear item as an
    /// INDEX (0/1/2), not as watts: it is a 3-position selector, not a dial, so
    /// the same treatment Character and Variation get is the honest one — and it
    /// keeps the knob's stored domain the small integer range the UI renders.
    public static let ampPowerWatts: [Double] = [0.5, 50, 100]
    public static let ampPowerLabels: [String] = ["0.5 W", "50 W", "100 W"]

    /// Power index → the power amp's HEADROOM SCALE on the bus. Physically the
    /// voltage swing goes as √(W/100), i.e. 0.071 at 0.5 W; we ship 0.14, which
    /// is deliberately conservative — a real Kabuto at 0.5 W is heavily
    /// power-saturated but still musical, because the clipping is soft and the OT
    /// plus speaker filter the result. Sag, bass rolloff and level compensation
    /// are derived FROM this one value in C++ (see PowerAmp), so the bus carries
    /// one continuous, rampable number and the switch never clicks.
    ///
    /// Ear-tuning: 0.5 W should sound like a small cranked amp, not a fuzz pedal.
    /// Sounds like a fuzz → raise toward 0.25. Indistinguishable from 50 W →
    /// lower toward the physical 0.071.
    public static func ampPowerScale(powerIndex v: Double) -> Float {
        switch Int(v.rounded()) {
        case 0:  return 0.14     // 0.5 W  (physical √0.005 = 0.071)
        case 1:  return 0.70     // 50 W   (physical √0.5   = 0.707)
        default: return 1.00     // 100 W
        }
    }

    // MARK: - Drive pedals (Drive, Tone, Level)

    /// Pedal "Drive" → linear pre-gain into the clip. Wide range for clean-boost
    /// through to fully-saturated: knob 0 → 0.8, 5 → ≈4.5, 10 → ≈25.6.
    static func pedalDrive(_ v: Double) -> Float {
        0.8 * powf(2.0, norm(v) * 5.0)
    }

    /// Pedal "Tone" → post low-pass cutoff in Hz (brightness). Exponential from
    /// dark to bright: knob 0 → 700 Hz, 5 → ≈2.4 kHz, 10 → ≈8.5 kHz.
    static func pedalToneHz(_ v: Double) -> Float {
        700.0 * powf(2.0, norm(v) * 3.6)
    }

    /// Pedal "Level" → linear output gain. Unity near knob 5–6: 0 → 0.1, 5 → ≈1.0,
    /// 10 → ≈2.0.
    static func pedalLevel(_ v: Double) -> Float {
        0.1 + norm(v) * 1.9
    }

    // MARK: - Family parameter maps (0…10 knob → DSP unit for each pedal family)

    /// EQ band gain in dB, flat (0) at noon so a centered EQ is transparent. ±12 dB.
    static func eqBandDB(_ v: Double) -> Float { (norm(v) - 0.5) * 2.0 * 12.0 }

    /// Compressor "Level" → output makeup gain (linear). Unity near noon.
    static func compMakeup(_ v: Double) -> Float { 0.5 + norm(v) * 1.5 }   // 0.5 … 2.0

    /// Gate "Threshold" → open threshold in dBFS. More knob = gates more (higher
    /// threshold): knob 0 → −70 dB (never gates), 10 → −20 dB (aggressive).
    static func gateThreshDB(_ v: Double) -> Float { -70.0 + norm(v) * 50.0 }

    /// Gate "Decay" → release time in seconds (how fast the gate closes).
    static func gateReleaseSec(_ v: Double) -> Float { 0.02 + norm(v) * 0.58 } // 20…600 ms

    /// Modulation "Rate" → LFO frequency in Hz, exponential: 0.1 → ≈6.4 Hz.
    static func modRateHz(_ v: Double) -> Float { 0.1 * powf(2.0, norm(v) * 6.0) }

    // MARK: - Delay (Time / Feedback / Mix / Tone / Mod depth)

    /// Delay "Time" → milliseconds, exponential so the musically useful settings
    /// are spread evenly across the sweep rather than crammed at one end:
    /// knob 0 → 40 ms (slapback), 5 → ≈226 ms, 8 → ≈640 ms (a dotted eighth at
    /// ~94 bpm), 10 → 1280 ms. The engine's line is 2 s, so the whole range fits
    /// with room to spare.
    public static func delayTimeMs(_ v: Double) -> Float { 40.0 * powf(2.0, norm(v) * 5.0) }

    /// Delay "Feedback" → the recirculating gain. Tops out at 0.95, which
    /// self-oscillates the way the hardware does at full repeats and is
    /// controllable just below; 1.0 would grow without bound.
    public static func delayFeedback(_ v: Double) -> Float { norm(v) * 0.95 }

    /// Delay "Mix" → the WET SEND. The dry path is never attenuated (the engine
    /// adds `wet · echo` to it), because that is what a pedal in front of an amp
    /// does — Mix at 10 should be drenched with the played note still present.
    /// Reaches 1.0, not 0.8. Reported by ear: at full Level the repeat should
    /// land as its own note — "two back to back notes" — and 0.8 leaves it
    /// permanently behind the playing, which reads as a delay that will not
    /// commit. The dry path is untouched either way, so 1.0 is a repeat AT the
    /// played level rather than louder than it, and every setting below still
    /// sits under the note.
    public static func delayMix(_ v: Double) -> Float { norm(v) }

    /// Delay "Tone" → the feedback-path low-pass corner in Hz: 1.2 kHz → 9.6 kHz.
    /// Only the models that actually HAVE a tone control send this; the other
    /// three send 0, which tells the engine to use its own voicing's corner
    /// (digital 8 kHz, tape 4 kHz, BBD 2.5 kHz — see DelayPedal::voiceFor).
    public static func delayToneHz(_ v: Double) -> Float { 1200.0 * powf(2.0, norm(v) * 3.0) }

    /// Delay "Depth" → modulation depth 0…1, scaling the voicing's own wobble
    /// (the ReverieMate's chorus section). Tape wow/flutter is NOT scaled by this
    /// — a tape machine's speed variation is the machine, not an effect.
    public static func delayModDepth(_ v: Double) -> Float { norm(v) }

    // MARK: - Reverb (Decay / Tone / Mix)

    /// Reverb "Decay" → the Dattorro tank's feedback coefficient.
    ///
    /// The range is chosen from the MEASURED RT60 of the tank at its shipped
    /// line lengths, not copied from a reference implementation with different
    /// ones: with a ~0.73 s loop and `decay` applied twice per branch, this maps
    /// to roughly 0.55 s at knob 0 and ~6 s at knob 10, which is the musical
    /// range the reverb is specified to cover. Cue: Decay 10 should be a long
    /// wash but must still decay — ringing forever means lower the top.
    public static func reverbDecay(_ v: Double) -> Float { 0.10 + norm(v) * 0.72 }

    /// Reverb "Tone" → the tank's damping low-pass corner: 1.2 kHz → 12 kHz.
    /// Tone 0 = a dark room, Tone 10 = a bright plate.
    public static func reverbToneHz(_ v: Double) -> Float { 1200.0 * powf(2.0, norm(v) * 3.32) }

    /// Reverb "Mix" → wet send, dry fixed at unity (same reasoning as delay).
    public static func reverbMix(_ v: Double) -> Float { norm(v) * 0.7 }

    // MARK: - Structural routing (topology, chosen at compile time)

    /// DSP block type for a pedal category. Mirrors the C++ `PedalChain::Type`.
    /// Categories without DSP yet (tuner / pitch / looper) stay transparent —
    /// they hold their chain position but pass audio through. Pitch is deferred
    /// because it is the only family that genuinely adds LATENCY (a phase
    /// vocoder needs ~50 ms of history), which is a live-monitoring decision,
    /// not a DSP one; tuner and looper are UI features with no tone.
    public static let typeTransparent = 0
    public static let typeDrive = 1
    public static let typeEq   = 2
    public static let typeCompressor = 3
    public static let typeGate = 4
    public static let typeWah  = 5
    public static let typeVolume = 6
    public static let typeModulation = 7
    public static let typeDelay  = 8
    public static let typeReverb = 9
    public static func pedalType(for category: GearCategory) -> Int {
        switch category {
        case .overdrive:  return typeDrive
        case .eq:         return typeEq
        case .compressor: return typeCompressor
        case .noiseGate:  return typeGate
        case .wah:        return typeWah
        case .volume:     return typeVolume
        case .modulation: return typeModulation
        case .delay:      return typeDelay
        case .reverb:     return typeReverb
        default:          return typeTransparent   // tuner / pitch / looper (deferred)
        }
    }

    /// True for the two families that draw a buffer from `PedalChain`'s arena.
    /// Used by the harness to assert the memory story, and by the compiler to
    /// keep the FX-loop span honest.
    public static func isTimeBased(_ type: Int) -> Bool {
        type == typeDelay || type == typeReverb
    }

    /// Slot "voicing" — the flavour within a family. For drive it is the specific
    /// pedal MODEL; for modulation it is the algorithm. Mirrors the C++
    /// `DrivePedal::Voicing` / `ModulationPedal::Voicing`.
    static let charSoft = 0, charHard = 1
    public static let charFuzz = 2   // generic clip fallbacks (0/1/2)
    // Per-model drive voicings (mirror DrivePedal::Voicing, 3+).
    public static let voiceValveShrieker = 3, voiceBluesBlazer = 4, voiceChiron = 5,
               voiceKingOfTone = 6, voiceFixation = 7, voiceDS1 = 8, voiceMetalRealm = 9,
               voiceShrew = 10, voiceBigMitt = 11, voiceFuzzDome = 12,
               voiceFuzzFoundry = 13, voiceCleanBoost = 14
    public static let modChorus = 0, modFlanger = 1, modPhaser = 2, modTremolo = 3, modUnivibe = 4
    /// Twelve all-pass stages and near-oscillating feedback — the deep sweep.
    /// Mirrors `ModulationPedal::DeepPhaser`; the two tables are hand-mirrored,
    /// exactly as the drive voicings are.
    public static let modDeepPhaser = 5
    /// Delay circuits (mirror `DelayPedal::Voicing`). These are three different
    /// CIRCUITS, not one delay with three tone settings: digital crossfades on a
    /// time change while tape and BBD glide (opposite correct behaviours), and
    /// only the latter two colour the feedback path.
    public static let delayDigital = 0, delayTape = 1, delayBBD = 2
    /// Reverb voicings (mirror `ReverbPedal::Voicing`). One Dattorro tank, four
    /// sizes/characters; Spring additionally runs a dispersion chain.
    public static let reverbPlate = 0, reverbSpring = 1, reverbRoom = 2, reverbHall = 3

    /// Voicing chosen by model NAME (substring match, so it works for both the old
    /// seed names and the re-badged catalog — e.g. "electro-galvanic BIG MITT Ω"
    /// still reads as a BigMitt). Each drive model gets its own circuit voicing in
    /// DrivePedal; modulation picks its algorithm.
    public static func pedalVoicing(name: String, category: GearCategory) -> Int {
        // A RETIRED name is matched as the name it became, so a rig restored from
        // an AUv3 host session keeps the voicing it was saved with -- the same
        // guarantee `ampProfile` gives amps. Resolving through the id is what lets
        // the tokens below name only CURRENT models: matching the old names
        // directly would mean listing the retired makers' model designations as
        // literals, putting those marks straight back into the binary.
        let resolved = GearCatalog.retiredID(forName: name)
            .flatMap { GearCatalog.currentName(forID: $0) } ?? name
        let n = resolved.lowercased()
        switch category {
        case .overdrive:
            // Specific models first, then generic keywords.
            if n.contains("shrieker")                          { return voiceValveShrieker }
            if n.contains("satyr") || n.contains("chiron")     { return voiceChiron }
            if n.contains("duke")                              { return voiceKingOfTone }
            if n.contains("fixation")                          { return voiceFixation }
            if n.contains("blues")                             { return voiceBluesBlazer }  // BLUES BLAZER / blues driver
            if n.contains("metal")                             { return voiceMetalRealm }
            if n.contains("shrew")                             { return voiceShrew }
            if n.contains("distortion")                        { return voiceDS1 }
            if n.contains("mitt")                              { return voiceBigMitt }
            if n.contains("foundry")                           { return voiceFuzzFoundry }
            if n.contains("fuzz")                              { return voiceFuzzDome }
            if n.contains("boost") || n.contains("booster")    { return voiceCleanBoost }
            return voiceValveShrieker   // sensible default OD flavour
        case .modulation:
            if n.contains("trem")                       { return modTremolo }
            if n.contains("vibe") || n.contains("univ") { return modUnivibe }
            if n.contains("flang") || n.contains("siren")     { return modFlanger }
            if n.contains("swirl") || n.contains("slate")    { return modPhaser }   // small slate = phaser
            return modChorus           // chorus / mime / CE-2
        case .delay:
            // Tape first (an ECHOREEL is also a "delay"), then bucket brigade,
            // then the digital default — the same specific-before-generic order
            // the drive table uses, so it survives the catalog re-badging.
            if n.contains("echoreel")
                || n.contains("tape")                          { return delayTape }
            if n.contains("reverie") || n.contains("bbd")
                || n.contains("analog") || n.contains("analogue") { return delayBBD }
            return delayDigital        // VOSS Digital Delay / DD-8
        case .reverb:
            if n.contains("fleece")
                || n.contains("spring")                        { return reverbSpring }
            if n.contains("hall")                              { return reverbHall }
            if n.contains("room")                              { return reverbRoom }
            return reverbPlate         // VOSS Reverb / RV-6
        default:
            return 0
        }
    }

    /// Per-category continuous knob values → the DSP-unit params[] each C++ engine
    /// expects (Param0…), in order. This is the single table that voices every
    /// family's knobs; it is deliberately here so ranges can be ear-tuned in one place.
    public static func pedalParams(category: GearCategory, values: [String: Double]) -> [Float] {
        // Role extraction: read whichever knob fills each DSP role across the
        // per-model names — so a BigMitt's "Sustain", a Chiron's "Gain" and a SHREW's
        // "Distortion" all drive the gain stage. Keeps the DSP mapping working no
        // matter what a model's knobs are called (see PedalSpec in Gear.swift).
        func role(_ keys: [String], _ d: Double = 5) -> Double {
            for k in keys { if let v = values[k] { return v } }
            return d
        }
        switch category {
        case .overdrive:
            let gain  = role(["Drive", "Overdrive", "Sustain", "Gain", "Distortion", "Dist", "Fuzz"])
            let tone  = role(["Tone", "Treble", "Filter"])
            let level = role(["Level", "Volume", "Output"])
            return [pedalDrive(gain), pedalToneHz(tone), pedalLevel(level)]
        case .eq:
            // 3-band engine — map Low/Mid/High, or representative graphic-EQ bands.
            let low  = role(["Low", "125", "100", "62", "31"])
            let mid  = role(["Mid", "500", "800", "1k"])
            let high = role(["High", "3.2k", "6.4k", "4k", "8k"])
            return [eqBandDB(low), eqBandDB(mid), eqBandDB(high)]
        case .compressor:
            let sustain = role(["Sustain", "Sensitivity"])
            let level   = role(["Level", "Output"])
            return [norm(sustain), compMakeup(level)]
        case .noiseGate:
            let thr = role(["Threshold"])
            let dec = role(["Decay", "Release"])
            return [gateThreshDB(thr), gateReleaseSec(dec)]
        case .modulation:
            let rate  = role(["Rate", "Speed", "Manual"])
            let depth = role(["Depth", "Width", "Intensity", "Range"])
            let mix   = role(["Mix", "Blend", "Color", "Regen"])
            return [modRateHz(rate), norm(depth), norm(mix)]
        case .wah:
            return [norm(role(["Position"]))]
        case .volume:
            return [norm(role(["Position"]))]
        case .delay:
            // All five generic fields are used, and all five fit — no stride
            // extension needed. Aliases cover the three real panels: a DD-8's
            // Time/Feedback/Mix, an Echoreel's Delay/Sustain/Volume and a Memory
            // Man's Delay/Feedback/Blend/Depth.
            let time  = role(["Time", "Delay"])
            let fb    = role(["Feedback", "Sustain", "Repeats", "Regen"])
            let mix   = role(["Mix", "Blend", "E.Level", "Level", "Volume"])
            let depth = role(["Depth", "Mod"], 0)
            // A model with no Tone knob sends 0, which means "use the circuit's
            // own corner". Keeping the per-voicing number in DelayPedal::voiceFor
            // rather than duplicating it here is what stops the two drifting.
            let toneHz: Float = values["Tone"].map { delayToneHz($0) } ?? 0
            return [delayTimeMs(time), delayFeedback(fb), delayMix(mix), toneHz, delayModDepth(depth)]
        case .reverb:
            // The GoldenFleece has ONE knob, called "Reverb" — it maps onto Mix,
            // and Decay/Tone fall back to noon, which is what a single-knob
            // pedal's fixed voicing amounts to.
            let decay = role(["Decay", "Time", "Size"])
            let tone  = role(["Tone", "Color", "Damping"])
            let mix   = role(["Mix", "Reverb", "Blend", "Level"])
            return [reverbDecay(decay), reverbToneHz(tone), reverbMix(mix)]
        default:
            return []   // transparent families carry no params yet
        }
    }

    // MARK: - The Kabuto's onboard FX section (Booster / Mod / FX / Delay / Reverb)
    //
    //  THE ROUTING IS THE POINT. A modelling amp's FX blocks are not "pedals in
    //  front"; each sits at a specific place in the amp, and getting that wrong
    //  is what most Kabuto emulations do:
    //
    //    guitar → [BOOSTER] → [MOD] → PREAMP → TONE STACK → [FX] → [DELAY]
    //             └─────── PRE ─────┘                       └──── MID ────┘ → [REVERB]
    //                                                                            │
    //                                        CAB ← POWER AMP ← VOLUME ←──────────┘
    //
    //  Booster and Mod belong in FRONT of the preamp, where a real pedal sits, so
    //  a boost DRIVES the character into saturation instead of just making it
    //  louder. Delay and reverb belong after the tone stack and BEFORE the power
    //  amp — the amp's FX loop — so their tails pass through the output stage and
    //  compress with the notes rather than floating on top of a finished,
    //  cab-filtered signal. `PedalChain`'s three spans exist for exactly this,
    //  and as a side benefit the whole app gets a real FX loop, not just the
    //  Kabuto.
    //
    //  EVERY BLOCK IS ORDINARY CHAIN MACHINERY. Nothing here is a private effect
    //  inside the amp: each block resolves to the same `PedalChain` type and
    //  voicing a standalone pedal would, so one implementation lights up both.

    /// Where an amp FX block runs relative to the amp's own stages.
    public enum AmpFXSpan: Sendable { case pre, mid }

    /// One resolved block, ready to become a `PedalChain` slot.
    public struct AmpFXSlot: Sendable {
        public let name: String
        public let type: Int
        public let voicing: Int
        public let enabled: Bool
        public let params: [Float]
        public let span: AmpFXSpan
    }

    /// The panel definition of one block: the key its type is stored under in
    /// `GearItem.values`, the detents of its selector, its span, and the extra
    /// dials it owns. The real hardware gives each block a SINGLE panel knob
    /// (deeper editing lives in Brig's editor app), and that is what is modelled
    /// — except Delay, which also gets Time, because the hardware sets delay time
    /// by tap tempo and this app has no tap-tempo surface.
    public struct AmpFXBlockSpec: Sendable {
        public let name: String
        public let options: [String]
        public let dials: [String]      ///< suffixes appended to `name`
        public let span: AmpFXSpan
        /// Type indices whose effect is driven by an LFO and therefore has a
        /// SPEED. The rate used to be pinned at a fixed "musical mid-sweep",
        /// which meant a tremolo you could not slow down and a phaser you could
        /// not sweep — reported by ear, and the obvious gap once you try to use
        /// them. Listed per TYPE rather than per block because a block's options
        /// are a mixed bag: on FX, Tremolo and Phaser have a rate and Comp, EQ
        /// and Wah do not, and drawing a dead Rate dial for a compressor is the
        /// thing this file already refuses to do for OUTPUT.
        public let rateTypes: Set<Int>

        public init(name: String, options: [String], dials: [String],
                    span: AmpFXSpan, rateTypes: Set<Int> = []) {
            self.name = name; self.options = options; self.dials = dials
            self.span = span; self.rateTypes = rateTypes
        }

        /// The dials this block shows for `typeIndex`. Passing nil returns the
        /// SUPERSET, which is what building an item's default values needs — a
        /// dial the player has never seen still wants a sane stored default.
        public func dials(forType typeIndex: Int?) -> [String] {
            guard let typeIndex else { return dials + (rateTypes.isEmpty ? [] : ["Rate"]) }
            return dials + (rateTypes.contains(typeIndex) ? ["Rate"] : [])
        }
    }

    /// `Off` is index 0 of every block's type selector, and it is the STRUCTURAL
    /// control: it decides whether the block occupies a chain slot at all. The
    /// separate On switch is CONTINUOUS — it rides `SRPedalFieldEnabled`, the
    /// same lock-free path an AR footswitch stomp takes, so stomping a block
    /// on and off never rebuilds the chain.
    public static let ampFXOff = 0

    public static let kabutoFXBlocks: [AmpFXBlockSpec] = [
        .init(name: "Booster", options: ["Off", "Clean", "Blues", "Crunch", "Tube", "Dist", "Metal", "Fuzz"],
              dials: ["Level"], span: .pre),
        // MOD IS THE PHASE-SHIFT BLOCK. Re-sorted on request: the two phasers and
        // the flanger together, because they are the same family — swept notches —
        // and belong on one selector. Chorus and Vibrato left the block; every
        // remaining option is an LFO effect, so Rate is always live.
        .init(name: "Mod", options: ["Off", "Phaser", "Deep Phaser", "Flanger"],
              dials: ["Level"], span: .pre, rateTypes: [1, 2, 3]),
        // FX IS EVERYTHING ELSE. Re-sorted on request to Wah / Tremolo, with the
        // phasers moved to Mod where they belong. PITCH SHIFTER IS ABSENT ON
        // PURPOSE: pitch was deferred with delay and reverb, and only those two
        // were built, so there is no engine behind it — a menu entry for it would
        // be a control that does nothing, which is the one thing this file already
        // refuses to draw. It goes in when it has DSP. Only Tremolo (2) sweeps.
        .init(name: "FX", options: ["Off", "Wah", "Tremolo"],
              dials: ["Level"], span: .mid, rateTypes: [2]),
        .init(name: "Delay", options: ["Off", "Digital", "Analog", "Tape"],
              dials: ["Level", "Time"], span: .mid),
        .init(name: "Reverb", options: ["Off", "Room", "Plate", "Spring", "Hall"],
              dials: ["Level"], span: .mid),
    ]

    /// Does this amp model expose an onboard FX section? Only the Kabuto does
    /// today; the mechanism is general, so a second modelling amp is a table
    /// entry, not new machinery.
    public static func ampHasFXSection(id: String?, name: String) -> Bool {
        if let id { return id == kabutoID }
        return ampHasFXSection(name: name)
    }

    public static func ampHasFXSection(name: String) -> Bool {
        if let id = GearCatalog.retiredID(forName: name) { return id == kabutoID }
        return name.lowercased().contains("ketana")
    }

    /// Resolve an amp's FX panel into chain slots. Blocks whose type is `Off`
    /// produce nothing (no slot, no CPU); every other block produces a slot
    /// whose `enabled` comes from its On switch.
    ///
    /// ONE KNOB, THREE DSP PARAMETERS. Each block has a single panel dial, so
    /// the two or three values its engine wants are derived from it here, with
    /// the rest pinned at musically sensible fixed points. Which value the dial
    /// drives is chosen per block to match what the hardware's knob does: on the
    /// Booster it is the amount of drive, on Mod the depth, on Delay the echo
    /// level and on Reverb the reverb level.
    public static func ampFXSlots(id: String? = nil, name: String, values: [String: Double]) -> [AmpFXSlot] {
        guard ampHasFXSection(id: id, name: name) else { return [] }
        var out: [AmpFXSlot] = []
        for block in kabutoFXBlocks {
            let typeIndex = Int((values[block.name] ?? Double(ampFXOff)).rounded())
            guard typeIndex > ampFXOff, typeIndex < block.options.count else { continue }
            let on = (values["\(block.name) On"] ?? 1) >= 0.5
            let level = values["\(block.name) Level"] ?? 5

            var type = typeTransparent
            var voicing = 0
            var params: [Float] = []

            switch block.name {
            case "Booster":
                type = typeDrive
                voicing = [0, voiceCleanBoost, voiceBluesBlazer, voiceValveShrieker,
                           voiceFixation, voiceDS1, voiceMetalRealm, voiceFuzzDome][typeIndex]
                // The panel knob is the boost AMOUNT; tone and output level sit
                // where a pedal set for "in front of a modelling amp" would.
                params = [pedalDrive(level), pedalToneHz(6), pedalLevel(6)]
            case "Mod":
                type = typeModulation
                voicing = [0, modPhaser, modDeepPhaser, modFlanger][typeIndex]
                // Rate is the player's now (it was pinned at 4). Level remains
                // depth AND mix, which is what a single "depth" control does.
                params = [modRateHz(values["Mod Rate"] ?? 4), norm(level), norm(level)]
            case "FX":
                switch typeIndex {
                case 1: type = typeWah;  params = [norm(level)]
                default: type = typeModulation; voicing = modTremolo
                         params = [modRateHz(values["FX Rate"] ?? 5), norm(level), norm(level)]
                }
            case "Delay":
                type = typeDelay
                voicing = [0, delayDigital, delayBBD, delayTape][typeIndex]
                let time = values["Delay Time"] ?? 5
                // Feedback is pinned just below "obviously repeating" — the
                // hardware's panel knob is E.Level, and a fixed, musical repeat
                // count is a better default than exposing a fourth control.
                params = [delayTimeMs(time), delayFeedback(4), delayMix(level), 0, 0]
            case "Reverb":
                type = typeReverb
                voicing = [0, reverbRoom, reverbPlate, reverbSpring, reverbHall][typeIndex]
                // Decay comes from the MODE, not the knob: a room is short and a
                // hall is long, which is what choosing between them means. The
                // knob is the reverb level, as on the hardware.
                let decayKnob: Double = [5, 3, 5, 4, 7][typeIndex]
                params = [reverbDecay(decayKnob), reverbToneHz(5), reverbMix(level)]
            default:
                continue
            }
            out.append(AmpFXSlot(name: block.name, type: type, voicing: voicing,
                                 enabled: on, params: params, span: block.span))
        }
        return out
    }

    // MARK: - Amp voicing profiles (mirrors streetrig::AmpVoicing — keep in lockstep)

    //  These constants and the C++ `AmpVoicing` enum in AmpProfile.hpp are
    //  mirrored BY HAND, exactly as `DrivePedal::Voicing` and `voice*` above
    //  already are. Ids are APPEND-ONLY: they ride in `RigDSPPlan.signature`, and
    //  an amp name resolves to one every time a rig is compiled.
    public static let ampLegacy = 0
    public static let ampMSW900 = 1, ampTandemReverb = 2, ampHV28 = 3,
                      ampRM140  = 4, ampBassdude59  = 5
    public static let ampClearpane1042 = 6, ampGX140 = 7, ampDualReactor = 8,
                      ampRumblecrest = 9
    /// 10…19 are the Kabuto (see `ampKabutoBase`), so the VCX45C — added after
    /// that block was reserved — takes 20. Ids are append-only; 21+ is open.
    public static let ampVCX45C = 20
    /// Kabuto ids are `ampKabutoBase + character*2 + variation`, so the five
    /// characters and the A/B switch collapse into ONE structural field. Turning
    /// the Character selector changes the profile id, which changes the topology
    /// signature, which triggers the rebuild — three controls, one field, no way
    /// for them to drift apart.
    public static let ampKabutoBase = 10
    public static let ampKabutoCharacterCount = 5
    public static let ampKabutoCharacters = ["Acoustic", "Clean", "Crunch", "Lead", "Brown"]
    public static let ampVariationLabels = ["A", "B"]

    /// Which voicing profile an amp MODEL uses. Substring match on the lowercased
    /// name, specific models before generic keywords, exactly like
    /// `pedalVoicing(name:category:)` — so it survives the catalog re-badging and
    /// works for both the seed names and the shipped ones.
    ///
    /// Anything unrecognized resolves to `ampLegacy`, which reproduces the
    /// pre-profile voicing bit-for-bit. That is the back-compat guarantee for a
    /// name this build has never heard of. Rigs carrying a name from an EARLIER
    /// catalog generation do not rely on it: they resolve through
    /// `GearCatalog.id(for:)`, whose legacy table maps every retired name onto the
    /// catalog id it became, so a saved host session keeps its exact voicing
    /// without the retired names surviving as literal strings in this matcher.
    /// THE PROFILE TABLE — catalog id → voicing. Every shipped amp resolves here,
    /// by identity, so a display-name edit can no longer drop one into `ampLegacy`
    /// (which is a real, working voicing, which is exactly why that failure was
    /// inaudible as a bug and audible as the wrong amp).
    ///
    /// The Kabuto is absent on purpose: it is not one profile but ten, chosen by
    /// its Character and Variation knobs, so it is computed below.
    static let profileByID: [String: Int] = [
        "marswell-msw900-2140":                 ampMSW900,
        "marswell-vcx45c":                      ampVCX45C,
        "marswell-clearpane-stellar-lead-1042": ampClearpane1042,
        "fremont-gx-140":                       ampGX140,
        "mesquite-bootleg-dual-reactor":        ampDualReactor,
        "tangerine-rumblecrest-100":            ampRumblecrest,
        "fandor-tandem-reverb":                 ampTandemReverb,
        "vane-hv28":                            ampHV28,
        "rondell-rm-140-velvet-chorus":         ampRM140,
        "fandor-bassdude-59":                   ampBassdude59,
    ]

    /// The one id whose profile is a family rather than a row.
    static let kabutoID = "brig-kabuto-100"

    /// Identity-first: the catalog id decides, and the name matcher below is only
    /// reached by gear that has no id — something the player named, or a rig
    /// restored from a session so old it predates ids and whose name is not even
    /// in `GearCatalog.retiredNames`.
    public static func ampProfile(id: String?, name: String, values: [String: Double]) -> Int {
        if let id {
            if id == kabutoID { return kabutoProfile(values: values) }
            if let p = profileByID[id] { return p }
        }
        return ampProfile(name: name, values: values)
    }

    private static func kabutoProfile(values: [String: Double]) -> Int {
        let character = Int((values["Character"] ?? 2).rounded())
        let variation = Int((values["Variation"] ?? 0).rounded())
        return ampKabutoBase
             + min(max(character, 0), ampKabutoCharacterCount - 1) * 2
             + min(max(variation, 0), 1)
    }

    public static func ampProfile(name: String, values: [String: Double]) -> Int {
        // A name with a catalog identity behind it resolves by identity first.
        if let id = GearCatalog.retiredID(forName: name) {
            if id == kabutoID { return kabutoProfile(values: values) }
            if let p = profileByID[id] { return p }
        }
        let n = name.lowercased()
        if n.contains("ketana") {
            let character = Int((values["Character"] ?? 2).rounded())
            let variation = Int((values["Variation"] ?? 0).rounded())
            return ampKabutoBase
                 + min(max(character, 0), ampKabutoCharacterCount - 1) * 2
                 + min(max(variation, 0), 1)
        }
        if n.contains("msw900") || n.contains("2140")   { return ampMSW900 }
        // The VCX is checked BEFORE the generic Marswell-family keywords below so
        // a future "Marswell VCX … Clearpane-voiced" style name cannot fall through
        // to the Clearpane row. Specific model, then family — the pedals' rule.
        if n.contains("vcx")                            { return ampVCX45C }
        if n.contains("clearpane") || n.contains("stellar lead") { return ampClearpane1042 }
        if n.contains("gx-140") || n.contains("gx140")  { return ampGX140 }
        if n.contains("reactor")                        { return ampDualReactor }
        if n.contains("rumblecrest")                    { return ampRumblecrest }
        if n.contains("tandem")                         { return ampTandemReverb }
        if n.contains("hv28")                           { return ampHV28 }
        if n.contains("rm-140") || n.contains("rm140")
            || n.contains("velvet chorus")              { return ampRM140 }
        if n.contains("bassdude")                       { return ampBassdude59 }
        return ampLegacy
    }

    /// Cab IR slot for a cabinet/combo model. Only two IRs are bundled today —
    /// slot 0 = V30 4x12 (dark/big), slot 1 = greenback 1x12 (brighter/smaller).
    /// 4x12/2x12 → slot 0; 1x12 and combos → slot 1. Default slot 0.
    static let cabSlotByID: [String: Int] = [
        "marswell-2415a-4x12":              0,
        "mesquite-bootleg-oversized-4x12":  0,
        "tangerine-tsv412":                 0,
        "vane-hv28":                        1,   // the seeded starter combo — its
    ]                                            // brighter 1x12 IR is the point

    /// `cabSlot` is internal (only the compiler routes a cab); the integrity
    /// check in the app target needs to assert on it, so it gets one public door.
    public static func cabSlotForCheck(id: String?, name: String) -> Int {
        cabSlot(id: id, name: name)
    }

    static func cabSlot(id: String?, name: String) -> Int {
        if let id, let s = cabSlotByID[id] { return s }
        return cabSlot(name: name)
    }

    static func cabSlot(name: String) -> Int {
        if let id = GearCatalog.retiredID(forName: name), let s = cabSlotByID[id] { return s }
        let n = name.lowercased()
        if n.contains("1x12") || n.contains("deluxe") || n.contains("hv18") || n.contains("hv28") {
            return 1
        }
        return 0
    }

    /// A PROFILED amp brings its own cab pairing (mirrors `AmpProfile::cabSlot`);
    /// nil means "not profiled", and `cabSlot(name:)` keeps deciding.
    ///
    /// The engine has 8 slots but only 2 bundled IRs (this work may not download
    /// assets), so the six amps currently share two boxes. They still differ
    /// enormously — preamp cascade, tone stack, power amp — and the intended
    /// pairing is recorded in research/amp-emulation-approaches.md §3.4 for when
    /// the other IRs arrive.
    static func ampProfileCabSlot(_ profile: Int) -> Int? {
        switch profile {
        case ampMSW900, ampBassdude59: return 0        // 4×12 V30 · 4×10 tweed
        case ampTandemReverb, ampHV28, ampRM140: return 1   // 2×12 Jensen · alnico · JC
        case ampLegacy: return nil
        default: return 1                              // every Kabuto voicing: 1×12
        }
    }

    /// True when the profile models an amp with NO speaker — the Kabuto's
    /// ACOUSTIC character, which is a DI preamp, not a guitar amp. Mirrors
    /// `AmpProfile::bypassCab`.
    public static func ampProfileBypassesCab(_ profile: Int) -> Bool {
        profile == ampKabutoBase || profile == ampKabutoBase + 1
    }

    /// Whether to prefer the neural capture for an amp.
    ///
    /// A PROFILED amp runs algorithmically: its character is the profile, and
    /// layering the single bundled placeholder capture on top would erase it.
    /// Unprofiled amps keep the previous behaviour (`true` — the kernel falls
    /// back to the analog path when no model loads). When a rights-cleared
    /// per-amp capture exists, it goes in `AmpProfile::neuralModel` and this
    /// becomes a lookup on that field; a capture then UPGRADES a profile rather
    /// than replacing it, because it stands in for the preamp cascade only.
    static func ampUsesNeural(name: String) -> Bool {
        ampProfile(name: name, values: [:]) == ampLegacy
    }

    // MARK: - Inverse maps (bus/DSP value → 0…10 knob) — Phase 4 host→UI bridge

    //  The AUv3 two-way bridge needs to run the forward curves BACKWARDS: when the
    //  host moves an automatable `AUParameter` (a bus-domain value — linear gain,
    //  Hz, dB), the on-screen 0…10 knob must follow. These are the exact analytic
    //  inverses of the forward curves above, clamped to the knob range, so a
    //  round-trip knob → bus → knob is the identity to within float precision.

    /// Clamp a computed knob back into the 0…10 dial range.
    @inline(__always) static func clampKnob(_ v: Double) -> Double { min(max(v, 0), 10) }

    /// Inverse of `ampDrive(gainKnob:)`  (bus = 0.6·2^(norm·4.5)).
    static func invAmpDriveKnob(_ bus: Float) -> Double {
        clampKnob(log2(Double(max(bus, 1e-6)) / 0.6) / 4.5 * 10.0)
    }

    /// Inverse of `ampMaster(masterKnob:)`  (bus = 0.2 + norm·1.6).
    static func invAmpMasterKnob(_ bus: Float) -> Double {
        clampKnob((Double(bus) - 0.2) / 1.6 * 10.0)
    }

    /// Inverse of `ampVolume(volumeKnob:)`  (bus = 0.2 + norm·1.6).
    public static func invAmpVolumeKnob(_ bus: Float) -> Double {
        clampKnob((Double(bus) - 0.2) / 1.6 * 10.0)
    }

    /// Inverse of `ampPowerScale(powerIndex:)`.
    ///
    /// NEAREST-NEIGHBOUR, not a curve, and deliberately so: on screen this is a
    /// 3-position selector, so the inverse is a lookup. The BUS value stays
    /// continuous and ramped — which is what keeps the switch click-free — but
    /// there is no meaningful knob position between two wattages to report back
    /// to a host.
    public static func invAmpPowerIndex(_ bus: Float) -> Double {
        var best = 2, bestErr = Double.greatestFiniteMagnitude
        for i in 0..<ampPowerWatts.count {
            let err = abs(Double(bus) - Double(ampPowerScale(powerIndex: Double(i))))
            if err < bestErr { bestErr = err; best = i }
        }
        return Double(best)
    }

    /// Inverse of `ampBandDB(_:knob:)`  (dB = ((norm−0.5)·2)·range; ±12, Presence ±9).
    static func invAmpBandKnob(_ paramName: String, dB: Float) -> Double {
        if paramName == "Mid" {
            // Mirror of the asymmetric forward curve above.
            let bipolar = Double(dB) < 0 ? Double(dB) / 12.0 : Double(dB) / 4.0
            return clampKnob((bipolar / 2.0 + 0.5) * 10.0)
        }
        let range: Double = (paramName == "Presence" || paramName == "Cut") ? 9.0 : 12.0
        return clampKnob((Double(dB) / (2.0 * range) + 0.5) * 10.0)
    }

    /// Inverse of `pedalDrive(_:)`  (bus = 0.8·2^(norm·5)).
    static func invPedalDriveKnob(_ bus: Float) -> Double {
        clampKnob(log2(Double(max(bus, 1e-6)) / 0.8) / 5.0 * 10.0)
    }

    /// Inverse of `pedalToneHz(_:)`  (hz = 700·2^(norm·3.6)).
    static func invPedalToneKnob(_ hz: Float) -> Double {
        clampKnob(log2(Double(max(hz, 1e-6)) / 700.0) / 3.6 * 10.0)
    }

    /// Inverse of `pedalLevel(_:)`  (bus = 0.1 + norm·1.9).
    static func invPedalLevelKnob(_ bus: Float) -> Double {
        clampKnob((Double(bus) - 0.1) / 1.9 * 10.0)
    }

    // --- The time-based blocks. Every forward curve above has its analytic
    //     inverse here, because `RigAUParameterBridge` cannot use half of one: a
    //     bus-backed knob needs BOTH closures or host automation moves the sound
    //     without moving the on-screen control. This has been a shipped bug once.

    /// Inverse of `delayTimeMs(_:)`  (ms = 40·2^(norm·5)).
    public static func invDelayTimeKnob(_ ms: Float) -> Double {
        clampKnob(log2(Double(max(ms, 1e-6)) / 40.0) / 5.0 * 10.0)
    }
    /// Inverse of `delayFeedback(_:)`  (bus = norm·0.95).
    public static func invDelayFeedbackKnob(_ bus: Float) -> Double {
        clampKnob(Double(bus) / 0.95 * 10.0)
    }
    /// Inverse of `delayMix(_:)`  (bus = norm·0.8).
    public static func invDelayMixKnob(_ bus: Float) -> Double {
        clampKnob(Double(bus) * 10.0)
    }
    /// Inverse of `delayToneHz(_:)`  (hz = 1200·2^(norm·3)).
    public static func invDelayToneKnob(_ hz: Float) -> Double {
        clampKnob(log2(Double(max(hz, 1e-6)) / 1200.0) / 3.0 * 10.0)
    }
    /// Inverse of `delayModDepth(_:)`  (bus = norm).
    public static func invDelayModDepthKnob(_ bus: Float) -> Double {
        clampKnob(Double(bus) * 10.0)
    }
    /// Inverse of `reverbDecay(_:)`  (bus = 0.10 + norm·0.72).
    public static func invReverbDecayKnob(_ bus: Float) -> Double {
        clampKnob((Double(bus) - 0.10) / 0.72 * 10.0)
    }
    /// Inverse of `reverbToneHz(_:)`  (hz = 1200·2^(norm·3.32)).
    public static func invReverbToneKnob(_ hz: Float) -> Double {
        clampKnob(log2(Double(max(hz, 1e-6)) / 1200.0) / 3.32 * 10.0)
    }
    /// Inverse of `reverbMix(_:)`  (bus = norm·0.7).
    public static func invReverbMixKnob(_ bus: Float) -> Double {
        clampKnob(Double(bus) / 0.7 * 10.0)
    }

    // MARK: - Automatable pedal knobs (host → UI, per family)

    /// One automatable pedal knob: which DSP ROLE it fills (matched against the
    /// model's own knob names by alias, so a BigMitt's "Sustain" and a Chiron's
    /// "Gain" both find the gain stage), which generic slot field it drives, and
    /// the forward/inverse pair.
    ///
    /// This exists so `RigAUParameterBridge` does not have to grow a hard-coded
    /// branch per family — and so the curves stay in this one file, where they
    /// can be ear-tuned, rather than being copied into the bridge.
    public struct PedalLink {
        public let roles: [String]
        public let field: Int              // 0…4 → SRPedalFieldDrive + field
        public let toBus: (Double) -> Float
        public let toKnob: (Float) -> Double
    }

    /// The automatable knobs of each family, in field order. Families whose
    /// blocks are still transparent return nothing.
    public static func pedalLinks(for category: GearCategory) -> [PedalLink] {
        switch category {
        case .overdrive:
            return [PedalLink(roles: ["Drive", "Overdrive", "Sustain", "Gain", "Distortion", "Dist", "Fuzz"],
                              field: 0, toBus: { pedalDrive($0) }, toKnob: { invPedalDriveKnob($0) }),
                    PedalLink(roles: ["Tone", "Treble", "Filter"],
                              field: 1, toBus: { pedalToneHz($0) }, toKnob: { invPedalToneKnob($0) }),
                    PedalLink(roles: ["Level", "Volume", "Output"],
                              field: 2, toBus: { pedalLevel($0) }, toKnob: { invPedalLevelKnob($0) })]
        case .delay:
            return [PedalLink(roles: ["Time", "Delay"],
                              field: 0, toBus: { delayTimeMs($0) }, toKnob: { invDelayTimeKnob($0) }),
                    PedalLink(roles: ["Feedback", "Sustain", "Repeats", "Regen"],
                              field: 1, toBus: { delayFeedback($0) }, toKnob: { invDelayFeedbackKnob($0) }),
                    PedalLink(roles: ["Mix", "Blend", "E.Level", "Level", "Volume"],
                              field: 2, toBus: { delayMix($0) }, toKnob: { invDelayMixKnob($0) }),
                    PedalLink(roles: ["Tone"],
                              field: 3, toBus: { delayToneHz($0) }, toKnob: { invDelayToneKnob($0) }),
                    PedalLink(roles: ["Depth", "Mod"],
                              field: 4, toBus: { delayModDepth($0) }, toKnob: { invDelayModDepthKnob($0) })]
        case .reverb:
            return [PedalLink(roles: ["Decay", "Time", "Size"],
                              field: 0, toBus: { reverbDecay($0) }, toKnob: { invReverbDecayKnob($0) }),
                    PedalLink(roles: ["Tone", "Color", "Damping"],
                              field: 1, toBus: { reverbToneHz($0) }, toKnob: { invReverbToneKnob($0) }),
                    PedalLink(roles: ["Mix", "Reverb", "Blend", "Level"],
                              field: 2, toBus: { reverbMix($0) }, toKnob: { invReverbMixKnob($0) })]
        default:
            // The remaining audible families (EQ / dynamics / modulation / wah /
            // volume) drive their fields from knobs whose bus domains do not
            // match the AU tree's published Drive/Tone/Level ranges, so linking
            // them would advertise automation lanes that clip. Recorded as a gap
            // rather than half-wired.
            return []
        }
    }
}
