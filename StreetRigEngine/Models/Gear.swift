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
public enum GearCategory: String, Codable, CaseIterable, Hashable {
    case guitar
    case comboAmp        // amp + speaker in one box
    case amp             // amp head
    case cabinet         // speaker cabinet
    // pedals, in signal-chain order:
    case tuner, wah, compressor, overdrive, eq, noiseGate
    case modulation, pitch, delay, reverb, volume, looper

    public var isPedal: Bool {
        switch self {
        case .guitar, .comboAmp, .amp, .cabinet: return false
        default: return true
        }
    }

    /// Collection grouping: 0 = amps/cabinets/combos, 1 = pedals.
    public var sectionRank: Int { isPedal ? 1 : 0 }

    /// Position in the guitar signal chain (lower = earlier). Non-pedals = -1.
    public var chainOrder: Int {
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

    public var displayName: String {
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
    public var symbolName: String {
        switch self {
        case .guitar: return "guitars.fill"
        case .comboAmp, .amp: return "hifispeaker.fill"
        case .cabinet: return "hifispeaker.2.fill"
        default: return "square.grid.2x2.fill"
        }
    }

    /// Knobs shown when a component is zoomed in (empty = no adjustable controls).
    public var parameters: [GearParameter] {
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
public struct GearParameter: Codable, Hashable, Identifiable {
    public var name: String
    public var min: Double
    public var max: Double
    public var defaultValue: Double
    public var id: String { name }

    public init(_ name: String, min: Double = 0, max: Double = 10, defaultValue: Double = 5) {
        self.name = name
        self.min = min
        self.max = max
        self.defaultValue = defaultValue
    }
}

/// A single owned piece of gear, with its current knob settings.
/// Transferable so cards can be dragged from the collection into the rig.
public struct GearItem: Identifiable, Codable, Hashable, Transferable {
    public var id: UUID
    public var name: String
    public var category: GearCategory
    /// Current values keyed by parameter name.
    public var values: [String: Double]

    // MARK: 3D model hooks (optional → backward-compatible with saved JSON)

    /// Opt this specific item in/out of real-time 3D rendering. `nil` (the
    /// value for every already-persisted item) means "use the category default"
    /// — see `uses3DModel`. Optional so old `rig_state.json` files still decode.
    public var has3DModel: Bool?
    /// Name of a bundled `.usdz` to load for this item (without extension). When
    /// present, `AmpModel3DView` loads it instead of building the procedural
    /// stand-in — the documented seam for dropping in a real, vetted model.
    public var modelName: String?

    /// Whether this item should render with the 3D pipeline. Amps default to 3D;
    /// everything else defaults to vector art. `has3DModel` overrides per item.
    public var uses3DModel: Bool { has3DModel ?? (category == .amp) }

    public init(id: UUID = UUID(), name: String, category: GearCategory,
         values: [String: Double]? = nil,
         has3DModel: Bool? = nil, modelName: String? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.values = values ?? Dictionary(uniqueKeysWithValues: category.parameters.map { ($0.name, $0.defaultValue) })
        self.has3DModel = has3DModel
        self.modelName = modelName
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

/// The amp portion of a rig: either a head + cabinet stack, or a single combo.
public enum AmpSection: Codable, Hashable {
    case stack(ampId: UUID, cabinetId: UUID)
    case combo(comboId: UUID)
}

/// The current rig: a fixed guitar, an amp section, and an ordered pedalboard.
public struct RigConfiguration: Codable, Hashable {
    public var guitarId: UUID
    public var ampSection: AmpSection
    public var pedalIds: [UUID]

    public init(guitarId: UUID, ampSection: AmpSection, pedalIds: [UUID]) {
        self.guitarId = guitarId
        self.ampSection = ampSection
        self.pedalIds = pedalIds
    }
}

/// One of the three AR "stomp" slots: an assigned pedal and its on/off state.
public struct ARSlot: Codable, Hashable {
    public var pedalId: UUID?
    public var isOn: Bool

    public init(pedalId: UUID? = nil, isOn: Bool = false) {
        self.pedalId = pedalId
        self.isOn = isOn
    }
}
