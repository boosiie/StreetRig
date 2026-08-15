//
//  Gear.swift
//  StreetRig
//
//  The persisted data model for a rig: the gear the user owns (their
//  collection) and how it's currently wired up. Everything here is Codable
//  so RigStore can round-trip it to JSON — no SwiftData/Core Data.
//

import SwiftUI
import UniformTypeIdentifiers

/// A category of gear. Drives collection sorting (`sectionRank`), signal-chain
/// position for pedals (`chainOrder`), the placeholder icon, and which knobs
/// show up when the component is zoomed in.
enum GearCategory: String, Codable, CaseIterable, Hashable {
    case guitar
    case comboAmp        // amp + speaker in one box
    case amp             // amp head
    case cabinet         // speaker cabinet
    // pedals, in signal-chain order:
    case tuner, wah, compressor, overdrive, eq, noiseGate
    case modulation, pitch, delay, reverb, volume, looper

    var isPedal: Bool {
        switch self {
        case .guitar, .comboAmp, .amp, .cabinet: return false
        default: return true
        }
    }

    /// Collection grouping: 0 = amps/cabinets/combos, 1 = pedals.
    var sectionRank: Int { isPedal ? 1 : 0 }

    /// Position in the guitar signal chain (lower = earlier). Non-pedals = -1.
    var chainOrder: Int {
        switch self {
        case .tuner: return 0
        case .wah: return 1
        case .compressor: return 2
        case .overdrive: return 3
        case .eq: return 4
        case .noiseGate: return 5
        case .modulation: return 6
        case .pitch: return 7
        case .delay: return 8
        case .reverb: return 9
        case .volume: return 10
        case .looper: return 11
        default: return -1
        }
    }

    var displayName: String {
        switch self {
        case .guitar: return "Guitar"
        case .comboAmp: return "Combo Amp"
        case .amp: return "Amp Head"
        case .cabinet: return "Cabinet"
        case .tuner: return "Tuner"
        case .wah: return "Wah"
        case .compressor: return "Compressor"
        case .overdrive: return "Overdrive"
        case .eq: return "EQ"
        case .noiseGate: return "Noise Gate"
        case .modulation: return "Modulation"
        case .pitch: return "Pitch / Octave"
        case .delay: return "Delay"
        case .reverb: return "Reverb"
        case .volume: return "Volume"
        case .looper: return "Looper"
        }
    }

    /// SF Symbol used as the placeholder picture (real art comes later).
    var symbolName: String {
        switch self {
        case .guitar: return "guitars.fill"
        case .comboAmp, .amp: return "hifispeaker.fill"
        case .cabinet: return "hifispeaker.2.fill"
        default: return "square.grid.2x2.fill"
        }
    }

    /// Knobs shown when a component is zoomed in (empty = no adjustable controls).
    var parameters: [GearParameter] {
        switch self {
        case .amp, .comboAmp:
            return ["Gain", "Bass", "Mid", "Treble", "Presence", "Master"].map { GearParameter($0) }
        case .overdrive:
            return ["Drive", "Tone", "Level"].map { GearParameter($0) }
        case .compressor:
            return ["Sustain", "Level"].map { GearParameter($0) }
        case .eq:
            return ["Low", "Mid", "High"].map { GearParameter($0) }
        case .noiseGate:
            return ["Threshold", "Decay"].map { GearParameter($0) }
        case .modulation:
            return ["Rate", "Depth", "Mix"].map { GearParameter($0) }
        case .pitch:
            return ["Shift", "Mix"].map { GearParameter($0) }
        case .delay:
            return ["Time", "Feedback", "Mix"].map { GearParameter($0) }
        case .reverb:
            return ["Decay", "Tone", "Mix"].map { GearParameter($0) }
        case .wah, .volume:
            return ["Position"].map { GearParameter($0) }
        case .cabinet, .guitar, .tuner, .looper:
            return []
        }
    }
}

/// A tweakable knob definition (0–10, Marshall-style dial).
struct GearParameter: Codable, Hashable, Identifiable {
    var name: String
    var min: Double
    var max: Double
    var defaultValue: Double
    var id: String { name }

    init(_ name: String, min: Double = 0, max: Double = 10, defaultValue: Double = 5) {
        self.name = name
        self.min = min
        self.max = max
        self.defaultValue = defaultValue
    }
}

/// A single owned piece of gear, with its current knob settings.
/// Transferable so cards can be dragged from the collection into the rig.
struct GearItem: Identifiable, Codable, Hashable, Transferable {
    var id: UUID
    var name: String
    var category: GearCategory
    /// Current values keyed by parameter name.
    var values: [String: Double]

    // MARK: 3D model hooks (optional → backward-compatible with saved JSON)

    /// Opt this specific item in/out of real-time 3D rendering. `nil` (the
    /// value for every already-persisted item) means "use the category default"
    /// — see `uses3DModel`. Optional so old `rig_state.json` files still decode.
    var has3DModel: Bool?
    /// Name of a bundled `.usdz` to load for this item (without extension). When
    /// present, `AmpModel3DView` loads it instead of building the procedural
    /// stand-in — the documented seam for dropping in a real, vetted model.
    var modelName: String?

    /// Whether this item should render with the 3D pipeline. Amps default to 3D;
    /// everything else defaults to vector art. `has3DModel` overrides per item.
    var uses3DModel: Bool { has3DModel ?? (category == .amp) }

    /// The knobs to DISPLAY + persist for this specific item: its real per-model
    /// control set when known (PedalSpec), else the generic per-category set.
    var parameters: [GearParameter] { PedalSpec.parameters(forName: name, category: category) }

    init(id: UUID = UUID(), name: String, category: GearCategory,
         values: [String: Double]? = nil,
         has3DModel: Bool? = nil, modelName: String? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.values = values ?? Dictionary(uniqueKeysWithValues: PedalSpec.parameters(forName: name, category: category).map { ($0.name, $0.defaultValue) })
        self.has3DModel = has3DModel
        self.modelName = modelName
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

/// The amp portion of a rig: either a head + cabinet stack, or a single combo.
enum AmpSection: Codable, Hashable {
    case stack(ampId: UUID, cabinetId: UUID)
    case combo(comboId: UUID)
}

/// The current rig: a fixed guitar, an amp section, and an ordered pedalboard.
struct RigConfiguration: Codable, Hashable {
    var guitarId: UUID
    var ampSection: AmpSection
    var pedalIds: [UUID]
}

/// One of the three AR "stomp" slots: an assigned pedal and its on/off state.
struct ARSlot: Codable, Hashable {
    var pedalId: UUID?
    var isOn: Bool

    init(pedalId: UUID? = nil, isOn: Bool = false) {
        self.pedalId = pedalId
        self.isOn = isOn
    }
}

/// The REAL control set of each pedal MODEL — so a Big Muff shows Sustain/Tone/
/// Volume, a Klon shows Gain/Treble/Output, a Metal Zone shows its full semi-
/// parametric EQ, and so on (see research/pedal-tone-reference.md). Chosen by a
/// substring match on the model name so it works for the re-badged catalog; falls
/// back to the generic per-category knobs when the model isn't specially specified.
///
/// Which knob drives which DSP role is resolved separately, by ALIAS, in
/// ParameterMap.pedalParams — so renaming a knob here never breaks the sound.
enum PedalSpec {
    static func parameters(forName name: String, category: GearCategory) -> [GearParameter] {
        let n = name.lowercased()
        func p(_ names: [String]) -> [GearParameter] { names.map { GearParameter($0) } }

        switch category {
        case .overdrive:   // overdrive / distortion / fuzz / boost all live here
            if n.contains("muff")                                  { return p(["Sustain", "Tone", "Volume"]) }
            if n.contains("klon") || n.contains("centaur")         { return p(["Gain", "Treble", "Output"]) }
            if n.contains("rat")                                   { return p(["Distortion", "Filter", "Volume"]) }
            if n.contains("metal") || n.contains("zone")           { return p(["Level", "Dist", "Low", "Mid", "Mid Freq", "High"]) }
            if n.contains("ds-1") || n.contains("ds1") || n.contains("distortion") { return p(["Tone", "Level", "Dist"]) }
            if n.contains("ocd")                                   { return p(["Volume", "Drive", "Tone"]) }
            if n.contains("king")                                  { return p(["Volume", "Tone", "Drive"]) }
            if n.contains("blues")                                 { return p(["Gain", "Tone", "Volume"]) }
            if n.contains("factory")                               { return p(["Volume", "Gate", "Comp", "Drive", "Stab"]) }
            if n.contains("fuzz") || n.contains("face")            { return p(["Volume", "Fuzz"]) }
            if n.contains("screamer") || n.contains("tube")        { return p(["Overdrive", "Tone", "Level"]) }
            if n.contains("boost") || n.contains("booster") || n.contains("ep ") { return p(["Gain"]) }
            return p(["Drive", "Tone", "Level"])
        case .compressor:
            if n.contains("dyna")                                  { return p(["Sensitivity", "Output"]) }
            if n.contains("cs-3") || n.contains("cs3") || n.contains("sustainer") { return p(["Level", "Tone", "Attack", "Sustain"]) }
            if n.contains("keeley") || n.contains("keenly")        { return p(["Sustain", "Level", "Blend", "Tone"]) }
            return p(["Sustain", "Level"])
        case .eq:
            if n.contains("10") || n.contains("ten")               { return p(["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k", "Volume"]) }
            if n.contains("para")                                  { return p(["Low Freq", "Low Gain", "Mid Freq", "Mid Gain", "High Freq", "High Gain"]) }
            if n.contains("ge-7") || n.contains("ge7") || n.contains("equalizer") { return p(["100", "200", "400", "800", "1.6k", "3.2k", "6.4k", "Level"]) }
            return p(["Low", "Mid", "High"])
        case .noiseGate:
            if n.contains("decimator")                             { return p(["Threshold"]) }
            if n.contains("zuul")                                  { return p(["Threshold", "Hold", "Release"]) }
            return p(["Threshold", "Decay"])
        case .modulation:
            if n.contains("phase 90") || n.contains("phase90")     { return p(["Speed"]) }
            if n.contains("stone")                                 { return p(["Rate", "Color"]) }
            if n.contains("mistress")                              { return p(["Rate", "Range", "Color"]) }
            if n.contains("flang")                                 { return p(["Manual", "Width", "Speed", "Regen"]) }
            if n.contains("trem")                                  { return p(["Rate", "Wave", "Depth"]) }
            if n.contains("vibe")                                  { return p(["Volume", "Intensity", "Speed"]) }
            if n.contains("clone")                                 { return p(["Rate", "Depth"]) }
            if n.contains("ce-2") || n.contains("ce2") || n.contains("chorus") { return p(["Rate", "Depth"]) }
            return p(["Rate", "Depth", "Mix"])
        case .pitch:
            if n.contains("pog")                                   { return p(["Dry", "Sub", "Octave Up"]) }
            if n.contains("oc-5") || n.contains("oc5") || n.contains("octave") { return p(["Direct", "+1 Oct", "-1 Oct", "-2 Oct"]) }
            if n.contains("harmonist") || n.contains("ps-6")       { return p(["Balance", "Shift", "Key"]) }
            if n.contains("whammy")                                { return p(["Position"]) }
            return p(["Shift", "Mix"])
        case .delay:
            if n.contains("echoplex") || n.contains("ep-3") || n.contains("ep103") { return p(["Volume", "Sustain", "Delay"]) }
            if n.contains("memory")                                { return p(["Blend", "Feedback", "Delay", "Depth", "Rate"]) }
            return p(["Time", "Feedback", "Mix"])
        case .reverb:
            if n.contains("holy") || n.contains("grail")           { return p(["Reverb"]) }
            return p(["Decay", "Tone", "Mix"])
        case .wah, .volume, .tuner, .looper, .guitar, .cabinet, .amp, .comboAmp:
            return category.parameters
        }
    }
}
