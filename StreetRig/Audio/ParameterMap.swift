//
//  ParameterMap.swift
//  StreetRig
//
//  Prompt 003 — THE ONE AUDITABLE TABLE that maps every on-screen rig knob to a
//  DSP control value. The UI knobs/sliders live on the 0…10 Marshall-style scale
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

enum ParameterMap {

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
        case "Presence": return bipolar * 9.0
        default:         return bipolar * 12.0 // Bass / Mid / Treble
        }
    }

    /// Which SRParameterAddress an amp tone-band name drives (nil if not a band).
    static func ampBandAddress(_ paramName: String) -> SRParameterAddress? {
        switch paramName {
        case "Bass":     return SRParamAmpBass
        case "Mid":      return SRParamAmpMid
        case "Treble":   return SRParamAmpTreble
        case "Presence": return SRParamAmpPresence
        default:         return nil
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

    // MARK: - Structural routing (topology, chosen at compile time)

    /// DSP block type for a pedal category. Mirrors the C++ `PedalChain::Type`.
    /// Categories without DSP yet (tuner / pitch / delay / reverb / looper) stay
    /// transparent — they hold their chain position but pass audio through.
    static let typeTransparent = 0
    static let typeDrive       = 1
    static let typeEq          = 2
    static let typeCompressor  = 3
    static let typeGate        = 4
    static let typeWah         = 5
    static let typeVolume      = 6
    static let typeModulation  = 7
    static func pedalType(for category: GearCategory) -> Int {
        switch category {
        case .overdrive:  return typeDrive
        case .eq:         return typeEq
        case .compressor: return typeCompressor
        case .noiseGate:  return typeGate
        case .wah:        return typeWah
        case .volume:     return typeVolume
        case .modulation: return typeModulation
        default:          return typeTransparent   // tuner/pitch/delay/reverb/looper (TBD)
        }
    }

    /// Slot "voicing" — the flavour within a family. For drive it is the specific
    /// pedal MODEL; for modulation it is the algorithm. Mirrors the C++
    /// `DrivePedal::Voicing` / `ModulationPedal::Voicing`.
    static let charSoft = 0, charHard = 1, charFuzz = 2   // generic clip fallbacks (0/1/2)
    // Per-model drive voicings (mirror DrivePedal::Voicing, 3+).
    static let voiceTubeScreamer = 3, voiceBluesbreaker = 4, voiceKlon = 5,
               voiceKingOfTone = 6, voiceOCD = 7, voiceDS1 = 8, voiceMetalZone = 9,
               voiceRAT = 10, voiceBigMuff = 11, voiceFuzzFace = 12,
               voiceFuzzFactory = 13, voiceCleanBoost = 14
    static let modChorus = 0, modFlanger = 1, modPhaser = 2, modTremolo = 3, modUnivibe = 4

    /// Voicing chosen by model NAME (substring match, so it works for both the old
    /// seed names and the re-badged catalog — e.g. "electro-harmonium BIG MUFF π"
    /// still reads as a Big Muff). Each drive model gets its own circuit voicing in
    /// DrivePedal; modulation picks its algorithm.
    static func pedalVoicing(name: String, category: GearCategory) -> Int {
        let n = name.lowercased()
        switch category {
        case .overdrive:
            // Specific models first, then generic keywords.
            if n.contains("screamer") || n.contains("ts808") || n.contains("ts9") || n.contains("tube screamer") { return voiceTubeScreamer }
            if n.contains("centaur") || n.contains("klon")     { return voiceKlon }
            if n.contains("king")                              { return voiceKingOfTone }
            if n.contains("ocd")                               { return voiceOCD }
            if n.contains("blues")                             { return voiceBluesbreaker }  // Bluesbreaker / Blues Driver
            if n.contains("metal") || n.contains("zone") || n.contains("mt-2") || n.contains("mt2") { return voiceMetalZone }
            if n.contains("rat")                               { return voiceRAT }
            if n.contains("ds-1") || n.contains("ds1") || n.contains("distortion") { return voiceDS1 }
            if n.contains("muff")                              { return voiceBigMuff }
            if n.contains("factory")                           { return voiceFuzzFactory }
            if n.contains("fuzz") || n.contains("face")        { return voiceFuzzFace }
            if n.contains("boost") || n.contains("booster") || n.contains("ep ") { return voiceCleanBoost }
            return voiceTubeScreamer   // sensible default OD flavour
        case .modulation:
            if n.contains("trem")                       { return modTremolo }
            if n.contains("vibe") || n.contains("univ") { return modUnivibe }
            if n.contains("flang") || n.contains("mistress") { return modFlanger }
            if n.contains("phase") || n.contains("stone")    { return modPhaser }   // Small Stone = phaser
            return modChorus           // chorus / clone / CE-2
        default:
            return 0
        }
    }

    /// Per-category continuous knob values → the DSP-unit params[] each C++ engine
    /// expects (Param0…), in order. This is the single table that voices every
    /// family's knobs; it is deliberately here so ranges can be ear-tuned in one place.
    static func pedalParams(category: GearCategory, values: [String: Double]) -> [Float] {
        // Role extraction: read whichever knob fills each DSP role across the
        // per-model names — so a Big Muff's "Sustain", a Klon's "Gain" and a RAT's
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
        default:
            return []   // transparent families carry no params yet
        }
    }

    /// Cab IR slot for a cabinet/combo model. Only two IRs are bundled today —
    /// slot 0 = V30 4x12 (dark/big), slot 1 = greenback 1x12 (brighter/smaller).
    /// 4x12/2x12 → slot 0; 1x12 and combos → slot 1. Default slot 0.
    static func cabSlot(name: String) -> Int {
        let n = name.lowercased()
        if n.contains("1x12") || n.contains("deluxe") || n.contains("ac15") || n.contains("ac30") {
            return 1
        }
        return 0
    }

    /// Whether to prefer the neural capture for an amp. Only a single placeholder
    /// capture is bundled (network fetches are forbidden), so this is "use neural
    /// when a model is loaded"; per-amp captures drop in later without touching
    /// this. Returns true — the kernel falls back to the analog amp if no model.
    static func ampUsesNeural(name: String) -> Bool { true }
}
