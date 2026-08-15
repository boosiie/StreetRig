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

    // MARK: - Structural routing (topology, chosen at compile time)

    /// DSP block type for a pedal category. Only overdrive/distortion/fuzz have
    /// real DSP now (`.drive`); every other category is a transparent pass-through
    /// that still holds its chain position (clean extension point). Mirrors the
    /// C++ `PedalChain::Type` (0 = transparent, 1 = drive).
    static let typeTransparent = 0
    static let typeDrive = 1
    static func pedalType(for category: GearCategory) -> Int {
        category == .overdrive ? typeDrive : typeTransparent
    }

    /// Clip character for a drive pedal, chosen by model. Mirrors the C++
    /// `DrivePedal::Character` (0 = soft, 1 = hard, 2 = fuzz).
    static let charSoft = 0, charHard = 1, charFuzz = 2
    /// Matched on a lowercased *substring* of the model name, not the whole
    /// string: the shipped names are brand-prefixed ("VOSS Distortion",
    /// "electro-harmonium BIG MUFF π"), so an exact-name switch would silently
    /// voice every drive pedal as soft clipping.
    static func pedalCharacter(name: String) -> Int {
        let n = name.lowercased()
        // hard, bright distortion
        if n.contains("procon rat") || n.contains("distortion") || n.contains("metal zone") {
            return charHard
        }
        // asymmetric fuzz
        if n.contains("muff") || n.contains("fuzz") {
            return charFuzz
        }
        return charSoft   // TS / Centaur / King of Tone / OCD / booster
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
