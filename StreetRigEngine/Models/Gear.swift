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

/// A tweakable control: a 0–10 Marshall-style dial by default, or — when
/// `options` is set — a DISCRETE SELECTOR whose stored value is an index into
/// those options.
///
/// The distinction is real hardware, not decoration. A Katana's Character is a
/// five-position rotary and its Power switch has three detents; drawing either as
/// a 0–10 dial would invite the player to set "Character 6.3", which is not a
/// thing. `options` lets the same knob list describe both kinds, so every surface
/// that already iterates `GearItem.parameters` picks the right control up for
/// free instead of growing an amp-specific branch.
///
/// `Codable` only for symmetry with the rest of the model — the persisted form of
/// a control is its VALUE in `GearItem.values`, so adding this field changes no
/// saved JSON.
public struct GearParameter: Codable, Hashable, Identifiable {
    public var name: String
    public var min: Double
    public var max: Double
    public var defaultValue: Double
    /// Labels for a discrete selector, in index order. `nil` = a continuous dial.
    public var options: [String]?
    /// Which SECTION of the panel this control belongs to. `nil` = the main
    /// panel (the knob row and the switch strip, exactly as before). A non-nil
    /// group is a named sub-panel — the Katana's five FX blocks are one group
    /// each — so a surface that already iterates `GearItem.parameters` can lay
    /// them out as blocks instead of stringing twenty-six controls across one
    /// row. Adding this changes no saved JSON: the persisted form of a control
    /// is its VALUE in `GearItem.values`, keyed by name.
    public var group: String?
    /// Short label to show inside a group, where the group name already carries
    /// the context ("Level" rather than "Booster Level"). Falls back to `name`.
    public var shortName: String?
    /// Drawn, but greyed and inert. For a control that EXISTS on the hardware and
    /// has no engine behind it yet — the panel stays a faithful picture of the amp
    /// without pretending the knob does something. Distinct from omitting it: the
    /// player can see the amp has a THUMP control and that this build cannot use
    /// it, which is more honest than a gap where a knob should be.
    public var isDisabled: Bool = false
    /// Puts this dial on a NAMED ROW of the knob panel. Amps with two channels
    /// have two rows of the same six controls with the channel's name between
    /// them, which is how the chassis reads and the only way the duplicate labels
    /// make sense. `nil` = the main, unlabelled row. Distinct from `group`, which
    /// makes a separate PANE (the Katana's FX blocks); a row is still the one
    /// panel, just stacked.
    public var rowLabel: String? = nil
    /// Dim this control unless the control named here holds one of `activeValues`.
    /// The JC-120's SPEED and DEPTH do nothing while its effect switch is OFF, and
    /// a panel that says so is easier to read than one that leaves you guessing.
    public var activeWhen: String? = nil
    public var activeValues: [Int]? = nil
    public var id: String { name }

    /// True when this is a switch/selector rather than a dial.
    public var isDiscrete: Bool { options != nil }
    /// What a surface should print next to the control.
    public var displayName: String { shortName ?? name }

    public init(_ name: String, min: Double = 0, max: Double = 10, defaultValue: Double = 5,
                group: String? = nil, shortName: String? = nil, isDisabled: Bool = false,
                rowLabel: String? = nil, activeWhen: String? = nil, activeValues: [Int]? = nil) {
        self.rowLabel = rowLabel
        self.activeWhen = activeWhen
        self.activeValues = activeValues
        self.name = name
        self.min = min
        self.max = max
        self.defaultValue = defaultValue
        self.options = nil
        self.group = group
        self.shortName = shortName
        self.isDisabled = isDisabled
    }

    /// A discrete selector: `min` 0 … `max` options.count − 1, stored as an index.
    public init(_ name: String, options: [String], defaultIndex: Int,
                group: String? = nil, shortName: String? = nil, isDisabled: Bool = false,
                rowLabel: String? = nil) {
        self.isDisabled = isDisabled
        self.rowLabel = rowLabel
        self.name = name
        self.min = 0
        self.max = Double(Swift.max(0, options.count - 1))
        self.defaultValue = Double(Swift.min(Swift.max(defaultIndex, 0), Swift.max(0, options.count - 1)))
        self.options = options
        self.group = group
        self.shortName = shortName
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

    /// The knobs to DISPLAY + persist for this specific item: its real per-model
    /// control set when known (PedalSpec), else the generic per-category set.
    /// `values` is passed so a block whose dial set depends on its selected TYPE
    /// can show the right dials — the Katana's FX blocks gain a Rate only for the
    /// LFO effects. Everything else ignores it.
    public var parameters: [GearParameter] {
        PedalSpec.parameters(forName: name, category: category, values: values)
    }

    public init(id: UUID = UUID(), name: String, category: GearCategory,
         values: [String: Double]? = nil,
         has3DModel: Bool? = nil, modelName: String? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.values = values ?? Dictionary(uniqueKeysWithValues: PedalSpec.parameters(forName: name, category: category).map { ($0.name, $0.defaultValue) })
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

/// The REAL control set of each pedal MODEL — so a Big Muff shows Sustain/Tone/
/// Volume, a Klon shows Gain/Treble/Output, a Metal Zone shows its full semi-
/// parametric EQ, and so on (see research/pedal-tone-reference.md). Chosen by a
/// substring match on the model name so it works for the re-badged catalog; falls
/// back to the generic per-category knobs when the model isn't specially specified.
///
/// Which knob drives which DSP role is resolved separately, by ALIAS, in
/// ParameterMap.pedalParams — so renaming a knob here never breaks the sound.
enum PedalSpec {
    static func parameters(forName name: String, category: GearCategory,
                           values: [String: Double]? = nil) -> [GearParameter] {
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
        // AMPS. The shared six knobs are the fallback, but an amp's panel is as
        // model-specific as a pedal's, and the per-item mechanism that already
        // handles that for pedals handles it here with no new machinery.
        case .amp, .comboAmp:
            // The Katana's real panel: the shared EQ, plus a Volume that drives
            // the power section (distinct from Master, which is the room level),
            // plus two DISCRETE selectors. Character and Variation choose the
            // voicing PROFILE — a structural change.
            //
            // NO WATTAGE SELECTOR. The hardware has one (0.5 / 50 / 100 W) and it
            // was modelled here, faithfully, as where the output stage begins to
            // compress. But a power attenuator exists to solve a problem this app
            // does not have: getting a valve amp to break up at a volume that will
            // not deafen a room. There is no room and no valve — the level you
            // hear is a slider — so the control asks the player to pick a wattage
            // for an amp that has no watts, and the honest answer is that the tone
            // they want is the Character and Gain, not a power rating.
            //
            // The power-amp VOICING stays: headroom, sag, feedback and output
            // compression are per-profile and are most of what separates a Twin
            // from a Plexi. What is gone is asking the player to dial the wattage.
            // `SRParamAmpPower` also stays (addresses are append-only, and host
            // sessions carry it) — it is simply pinned to full power now.
            // EVERY AMP GETS ITS OWN PANEL, because they do not share one. Checked
            // model by model rather than assumed; the shared six were a placeholder
            // and several of them were simply wrong.
            //
            //   • Fender Twin Reverb / Bassman — NO presence on the Twin. The panel
            //     is Volume / Treble / Middle / Bass plus Reverb; presence belongs
            //     to the Bassman, which really does have one.
            //   • Vox AC30 — the control is CUT, not Presence, and it works
            //     backwards (turning it up removes top end). The DSP already models
            //     it as a negative presence scale; only the LABEL was wrong.
            //   • Roland JC-120 — no presence, no gain. It is Volume / Treble /
            //     Middle / Bass with the chorus, and it never distorts by design.
            //   • Marshall JCM800 2203 — a master-volume head: Presence, Bass,
            //     Middle, Treble, Master Volume and PREAMP volume. "Gain" is the
            //     modern name for the preamp control.
            //   • Marshall DSL40C — the hardware also has RESONANCE, a low-end
            //     feedback control that mirrors presence. It is NOT here: there is
            //     no DSP behind it (the power amp models one NFB shelf, not two),
            //     and a knob that does nothing is the thing this codebase already
            //     refuses to draw. It goes in when the power amp grows a low shelf.
            //   • Orange Rockerverb — Gain / Bass / Middle / Treble / Master, plus
            //     its reverb. No presence knob on the dirty channel.
            // ROLAND JC-120 — two channels; channel 2 carries the distortion, the
            // reverb and the chorus/vibrato that the amp is named for.
            if n.contains("jc-120") || n.contains("jc120") || n.contains("jazz chorus") {
                return [GearParameter("CHANNEL", options: ["CHANNEL 1", "CHANNEL 2"], defaultIndex: 0),
                        GearParameter("BRIGHT",   options: ["OFF", "ON"], defaultIndex: 0),
                        GearParameter("BRIGHT 2", options: ["OFF", "ON"], defaultIndex: 0,
                                      shortName: "BRIGHT"),
                        GearParameter("EFFECT", options: ["VIBRATO", "OFF", "CHORUS"], defaultIndex: 1),
                        GearParameter("Gain",     shortName: "VOLUME", rowLabel: "CHANNEL 1"),
                        GearParameter("Treble",   shortName: "TREBLE", rowLabel: "CHANNEL 1"),
                        GearParameter("Mid",      shortName: "MIDDLE", rowLabel: "CHANNEL 1"),
                        GearParameter("Bass",     shortName: "BASS",   rowLabel: "CHANNEL 1"),
                        GearParameter("Gain 2",     shortName: "VOLUME",     rowLabel: "CHANNEL 2"),
                        GearParameter("Treble 2",   shortName: "TREBLE",     rowLabel: "CHANNEL 2"),
                        GearParameter("Mid 2",      shortName: "MIDDLE",     rowLabel: "CHANNEL 2"),
                        GearParameter("Bass 2",     shortName: "BASS",       rowLabel: "CHANNEL 2"),
                        GearParameter("DISTORTION", rowLabel: "CHANNEL 2"),
                        GearParameter("REVERB",     rowLabel: "CHANNEL 2"),
                        // Idle unless the effect switch is on VIBRATO (0) or
                        // CHORUS (2) — with it OFF these two drive nothing.
                        GearParameter("SPEED", rowLabel: "CHANNEL 2",
                                      activeWhen: "EFFECT", activeValues: [0, 2]),
                        GearParameter("DEPTH", rowLabel: "CHANNEL 2",
                                      activeWhen: "EFFECT", activeValues: [0, 2])]
            }
            // FENDER BASSMAN — a tweed 5F6-A: presence and the tone stack, then a
            // volume for EACH input, bright and normal. No master, no gain knob;
            // the input volume IS the gain.
            if n.contains("bassman") {
                // Four jacks like the Plexi — two BRIGHT, two NORMAL — and a
                // volume for each pair, jumpered together the same way.
                return [GearParameter("PATCH", options: ["BRIGHT", "NORMAL", "JUMPERED"],
                                      defaultIndex: 2),
                        GearParameter("Presence", shortName: "PRESENCE"),
                        GearParameter("Mid",      shortName: "MIDDLE"),
                        GearParameter("Bass",     shortName: "BASS"),
                        GearParameter("Treble",   shortName: "TREBLE"),
                        GearParameter("Gain",     shortName: "VOL BRIGHT"),
                        GearParameter("Volume",   shortName: "VOL NORMAL")]
            }
            // FENDER TWIN REVERB — two channels, and the reverb and vibrato live
            // on the Vibrato one only, which is why that row is longer.
            if n.contains("twin") {
                return [GearParameter("CHANNEL", options: ["NORMAL", "VIBRATO"], defaultIndex: 0),
                        GearParameter("BRIGHT",   options: ["OFF", "ON"], defaultIndex: 0),
                        GearParameter("BRIGHT 2", options: ["OFF", "ON"], defaultIndex: 0,
                                      shortName: "BRIGHT"),
                        GearParameter("Gain",     shortName: "VOLUME", rowLabel: "NORMAL"),
                        GearParameter("Treble",   shortName: "TREBLE", rowLabel: "NORMAL"),
                        GearParameter("Mid",      shortName: "MIDDLE", rowLabel: "NORMAL"),
                        GearParameter("Bass",     shortName: "BASS",   rowLabel: "NORMAL"),
                        GearParameter("Gain 2",   shortName: "VOLUME", rowLabel: "VIBRATO"),
                        GearParameter("Treble 2", shortName: "TREBLE", rowLabel: "VIBRATO"),
                        GearParameter("Mid 2",    shortName: "MIDDLE", rowLabel: "VIBRATO"),
                        GearParameter("Bass 2",   shortName: "BASS",   rowLabel: "VIBRATO"),
                        GearParameter("REVERB",    rowLabel: "VIBRATO"),
                        GearParameter("SPEED",     rowLabel: "VIBRATO"),
                        GearParameter("INTENSITY", rowLabel: "VIBRATO"),
                        GearParameter("Master", shortName: "MASTER VOLUME")]
            }
            // VOX AC30 — the Normal channel is one volume and nothing else; Top
            // Boost is the tone channel. CUT and MASTER VOLUME are the amp's
            // global pair, and Cut runs backwards (the profile's negative
            // presenceScale is what does that).
            if n.contains("ac30") {
                // Per the manual: NORMAL is a single volume, TOP BOOST adds the
                // tone pair (and only TREBLE and BASS — there is no middle), while
                // REVERB, TREMOLO and the MASTER pair serve BOTH channels and so
                // sit on the global row rather than dimming with a selection.
                return [GearParameter("CHANNEL", options: ["TOP BOOST", "NORMAL"], defaultIndex: 0),
                        GearParameter("Gain",   shortName: "VOLUME", rowLabel: "TOP BOOST"),
                        GearParameter("Treble", shortName: "TREBLE", rowLabel: "TOP BOOST"),
                        GearParameter("Bass",   shortName: "BASS",   rowLabel: "TOP BOOST"),
                        GearParameter("Gain 2", shortName: "VOLUME", rowLabel: "NORMAL"),
                        GearParameter("REVERB TONE"),
                        GearParameter("REVERB LEVEL"),
                        GearParameter("TREMOLO SPEED"),
                        GearParameter("TREMOLO DEPTH"),
                        GearParameter("Cut",    shortName: "TONE CUT"),
                        GearParameter("Master", shortName: "MASTER VOLUME")]
            }
            // THE FRIEDMAN, LEFT TO RIGHT, exactly as it reads on the chassis.
            // Duplicated names (two channels' worth of TREBLE / MIDDLE / BASS) need
            // unique keys because a value dictionary is keyed by name, so the
            // second set is suffixed internally and `shortName` puts the real word
            // back on the panel.
            //
            // WHAT IS LIVE: GAIN, BASS, MIDDLE, TREBLE, VOLUME, PRESENCE and
            // MASTER 1 drive the existing engine. The channel-2 set, the four
            // switches and SYSTEM VOL are drawn because they are on the amp, and
            // they will do nothing until the profile grows a second channel.
            // THUMP is drawn DISABLED, as asked.
            // MARSHALL JCM800 / PLEXI — a master-volume head reads right to left
            // on the chassis, and these are the six it actually has.
            // PLEXI — no master volume. Four jacks (two channels, high and low
            // sensitivity each) and two LOUDNESS controls; the patch lead from one
            // channel's spare jack into the other is how both preamps end up
            // feeding the same signal, which is the sound people are after.
            if n.contains("plexi") || n.contains("super lead") {
                return [GearParameter("PATCH", options: ["HIGH TREBLE", "NORMAL", "JUMPERED"],
                                      defaultIndex: 2),
                        GearParameter("Presence", shortName: "PRESENCE"),
                        GearParameter("Bass",     shortName: "BASS"),
                        GearParameter("Mid",      shortName: "MIDDLE"),
                        GearParameter("Treble",   shortName: "TREBLE"),
                        GearParameter("Gain",     shortName: "LOUDNESS I"),
                        GearParameter("Volume",   shortName: "LOUDNESS II")]
            }
            if n.contains("jcm800") || n.contains("2203") {
                return [GearParameter("Presence", shortName: "PRESENCE"),
                        GearParameter("Bass", shortName: "BASS"),
                        GearParameter("Mid", shortName: "MIDDLE"),
                        GearParameter("Treble", shortName: "TREBLE"),
                        GearParameter("Master", shortName: "MASTER VOLUME"),
                        GearParameter("Gain", shortName: "PRE-AMP VOLUME")]
            }
            // MESA DUAL RECTIFIER — two channels of the same six, one row each
            // with the channel named between them, and the two mode switches to
            // the left. CHANNEL 2's set is stored under suffixed keys because a
            // values dictionary cannot hold two knobs called BASS.
            if n.contains("rectifier") || n.contains("recto") {
                func ch(_ suffix: String, _ row: String) -> [GearParameter] {
                    [("Master", "MASTER"), ("Presence", "PRESENCE"), ("Bass", "BASS"),
                     ("Mid", "MID"), ("Treble", "TREBLE"), ("Gain", "GAIN")].map {
                        GearParameter($0.0 + suffix, shortName: $0.1, rowLabel: row)
                    }
                }
                return [GearParameter("CHANNEL", options: ["CHANNEL 1", "CHANNEL 2"], defaultIndex: 0),
                        GearParameter("MODE", options: ["CLEAN", "PUSHED"], defaultIndex: 0),
                        GearParameter("VOICE", options: ["VINTAGE", "MODERN"], defaultIndex: 1)]
                     + ch("",   "CHANNEL 1")
                     + ch(" 2", "CHANNEL 2")
            }
            if n.contains("be-100") || n.contains("be100") {
                func k(_ label: String, _ key: String? = nil, disabled: Bool = false) -> GearParameter {
                    GearParameter(key ?? label, shortName: label, isDisabled: disabled)
                }
                func sw(_ label: String, _ opts: [String], _ key: String? = nil) -> GearParameter {
                    GearParameter(key ?? label, options: opts, defaultIndex: 0, shortName: label)
                }
                // The two knob sets ARE the two channels: the first is HBE, the
                // second BE, which is what the CHANNEL switch picks between. Naming
                // the rows after the switch's options is what lets the panel dim
                // the one you are not hearing.
                func kr(_ label: String, _ key: String, _ row: String) -> GearParameter {
                    GearParameter(key, shortName: label, rowLabel: row)
                }
                return [
                    sw("CHANNEL", ["BE", "HBE"]),
                    sw("VOICE", ["1", "2"]),
                    sw("STRUCTURE", ["TIGHT", "LOOSE"]),
                    sw("BRIGHT", ["OFF", "ON"]),
                    k("SYSTEM VOL"),
                    k("THUMP", disabled: true),
                    k("PRESENCE"),
                    kr("GAIN",   "Gain",     "BE"),
                    kr("VOLUME", "Volume",   "BE"),
                    kr("TREBLE", "Treble",   "BE"),
                    kr("MIDDLE", "Mid",      "BE"),
                    kr("BASS",   "Bass",     "BE"),
                    kr("MASTER", "Master",   "BE"),
                    kr("GAIN",   "Gain 2",   "HBE"),
                    kr("VOLUME", "Volume 2", "HBE"),
                    kr("TREBLE", "Treble 2", "HBE"),
                    kr("MIDDLE", "Mid 2",    "HBE"),
                    kr("BASS",   "Bass 2",   "HBE"),
                    kr("MASTER", "Master 2", "HBE"),
                ]
            }
            // MARSHALL DSL — two gain channels, a shared tone stack, and its own
            // reverb per channel. RESONANCE is real on this amp and is drawn here,
            // though the power amp models a single feedback shelf so it does
            // nothing yet.
            // MARSHALL DSL — the two gain channels are a BLOCK ON THE LEFT, each a
            // short row of its own controls, with everything shared sitting to
            // their right. Stacking them full-width under the amp made two tiny
            // rows floating in a lot of nothing.
            //
            // ONE MASTER. The panel had two and the amp has one that matters here;
            // the second was me mirroring the channel pair where there is nothing
            // to mirror.
            //
            // Each channel's REVERB rides with its channel, so it dims when the
            // other one is selected — the amp has a reverb level per channel and
            // that is what makes them per-channel rather than one control.
            if n.contains("dsl") {
                return [GearParameter("CHANNEL", options: ["ULTRA GAIN", "CLASSIC GAIN"],
                                      defaultIndex: 0),
                        GearParameter("CLEAN/CRUNCH", options: ["CLEAN", "CRUNCH"], defaultIndex: 1,
                                      rowLabel: "CLASSIC GAIN"),
                        GearParameter("OD1/OD2",      options: ["OD1", "OD2"], defaultIndex: 0,
                                      rowLabel: "ULTRA GAIN"),
                        GearParameter("TONE SHIFT",   options: ["OFF", "ON"], defaultIndex: 0),
                        GearParameter("Gain",     shortName: "GAIN",   rowLabel: "ULTRA GAIN"),
                        GearParameter("Volume",   shortName: "VOLUME", rowLabel: "ULTRA GAIN"),
                        GearParameter("ULTRA REVERB", shortName: "REVERB", rowLabel: "ULTRA GAIN"),
                        GearParameter("Gain 2",   shortName: "GAIN",   rowLabel: "CLASSIC GAIN"),
                        GearParameter("Volume 2", shortName: "VOLUME", rowLabel: "CLASSIC GAIN"),
                        GearParameter("CLASSIC REVERB", shortName: "REVERB", rowLabel: "CLASSIC GAIN"),
                        GearParameter("Treble",   shortName: "TREBLE"),
                        GearParameter("Mid",      shortName: "MIDDLE"),
                        GearParameter("Bass",     shortName: "BASS"),
                        GearParameter("Presence", shortName: "PRESENCE"),
                        GearParameter("RESONANCE", isDisabled: true),
                        GearParameter("Master",   shortName: "MASTER")]
            }
            if n.contains("rockerverb") {
                return [GearParameter("CHANNEL", options: ["DIRTY", "CLEAN"], defaultIndex: 0),
                        GearParameter("REVERB", shortName: "REVERB"),
                        GearParameter("Master",  shortName: "VOLUME", rowLabel: "DIRTY"),
                        GearParameter("Treble",  shortName: "TREBLE", rowLabel: "DIRTY"),
                        GearParameter("Mid",     shortName: "MIDDLE", rowLabel: "DIRTY"),
                        GearParameter("Bass",    shortName: "BASS",   rowLabel: "DIRTY"),
                        GearParameter("Gain",    shortName: "GAIN",   rowLabel: "DIRTY"),
                        GearParameter("Treble 2", shortName: "TREBLE", rowLabel: "CLEAN"),
                        GearParameter("Mid 2",    shortName: "MIDDLE", rowLabel: "CLEAN"),
                        GearParameter("Bass 2",   shortName: "BASS",   rowLabel: "CLEAN"),
                        GearParameter("Volume 2", shortName: "VOLUME", rowLabel: "CLEAN")]
            }
            if n.contains("katana") {
                var p: [GearParameter] = [
                    // NO PRESENCE. Reported from the hardware; the panel is
                    // Gain / Volume / Bass / Middle / Treble / Master plus the
                    // character and FX sections, and a presence knob was carried
                    // over from the shared six by mistake.
                    GearParameter("Gain"), GearParameter("Bass"), GearParameter("Mid"),
                    GearParameter("Treble"),
                    GearParameter("Volume"), GearParameter("Master"),
                    GearParameter("Character", options: ["Acoustic", "Clean", "Crunch", "Lead", "Brown"],
                                  defaultIndex: 2),
                    GearParameter("Variation", options: ["A", "B"], defaultIndex: 0)]
                // THE FX SECTION. Five blocks, each a named group: a type
                // selector (index 0 = Off, and the only STRUCTURAL control here,
                // because it decides whether the block occupies a chain slot at
                // all), an On switch (CONTINUOUS — it rides the same lock-free
                // enable an AR footswitch stomp uses, so toggling a block never
                // rebuilds the chain), and the block's own dial(s).
                //
                // Every default is "Off", so a Katana loaded from a rig saved
                // before this existed compiles to exactly the chain it did
                // before — no keys, no slots, no change.
                for block in ParameterMap.katanaFXBlocks {
                    p.append(GearParameter(block.name, options: block.options, defaultIndex: 0,
                                           group: block.name, shortName: "Type"))
                    p.append(GearParameter("\(block.name) On", options: ["Off", "On"], defaultIndex: 1,
                                           group: block.name, shortName: "On"))
                    // nil values (building an item's defaults) yields the
                    // superset, so every dial has a stored default the first time
                    // its type is selected.
                    let selected = values.map { Int(($0[block.name] ?? 0).rounded()) }
                    for dial in block.dials(forType: selected) {
                        p.append(GearParameter("\(block.name) \(dial)", group: block.name, shortName: dial))
                    }
                }
                return p
            }
            // The JC-120 genuinely has no presence control, so its profile sets
            // `presenceScale = 0` and the knob is not offered. Showing an inert
            // dial would be worse than showing none. (The real amp has a Bright
            // switch instead; whether to model that is a product decision, not a
            // DSP one — see research/amp-emulation-approaches.md §13 Q5.)
            if n.contains("jc-120") || n.contains("jc120") || n.contains("jazz chorus") {
                return p(["Gain", "Bass", "Mid", "Treble", "Master"])
            }
            return category.parameters
        case .wah, .volume, .tuner, .looper, .guitar, .cabinet:
            return category.parameters
        }
    }
}
