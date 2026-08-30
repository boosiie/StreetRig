//
//  UserPreset.swift
//  StreetRigEngine
//
//  THE PLAYER'S OWN RIG, KEPT. Four slots, and each one is a photograph of the
//  whole setup at the moment it was taken: the head and its cab (or the combo),
//  every knob on it, the board in the order it is wired, every knob on every one
//  of those pedals, the guitar, and where the three AR footswitches were
//  standing.
//
//  WHY IT EXISTS. `RigPreset` can only describe rigs this app's own source code
//  knows about. Somebody who spends twenty minutes putting a Tube Screamer in
//  front of a Rectifier and dialling a gate to sit under it has, up to now, no
//  way to keep that: load a factory preset, or drag one pedal off, and the work
//  is gone. That is the single most common reason a serious player abandons an
//  amp sim, and four named slots are the difference between a demo and something
//  you could take to a gig.
//
//  IT IS A SNAPSHOT, AND `RigPreset` IS A RECIPE. That one sentence explains
//  every place the two deliberately diverge, and there are four:
//
//    • A recipe names a handful of knobs on purpose and leaves the rest at
//      whatever they were. A snapshot stores the COMPLETE `values` dictionary of
//      every item it names — including the channel the player was not on, which
//      is invisible right now and is the whole tone the moment they flip the
//      switch.
//    • A recipe MERGES its knobs into what is already there. A snapshot REPLACES
//      them. See `RigStore.apply(_ preset: UserPreset)` for why merging would
//      make a saved clean tone come back with last night's metal gain sitting
//      underneath it.
//    • A recipe leaves the AR footswitches alone, because it is somebody else's
//      rig and has no opinion about where your feet go. A snapshot restores
//      them, because it recorded YOUR feet. Both halves of that argument are
//      written out at `RigStore.apply(_ preset: UserPreset)` and in the amended
//      note on `RigStore.apply(_ preset: RigPreset)`; if either changes, both
//      change, in the same commit.
//    • A recipe's pedals are re-sorted into signal-chain order on load, because
//      the order they happen to be typed in the source file means nothing. A
//      snapshot's are not: the board's order IS what the player arranged with
//      `movePedal`, and re-sorting it would quietly undo a deliberate choice.
//
//  NEVER UUIDS. A `GearItem.id` is only meaningful inside the CURRENT collection:
//  remove that pedal from the rail, or let a `catalogVersion` bump re-seed the
//  collection, and every UUID in a saved slot becomes a dangling reference the
//  player can neither see nor repair.
//
//  CATALOG ID FIRST, NAME SECOND. A slot records both: the display name, which is
//  what a human reading this file needs, and the frozen `catalogID` beside it,
//  which is what actually resolves. The reason is the rule the catalog rename
//  established — THE ID IS THE IDENTITY AND THE NAME IS DERIVED FROM IT. `name`
//  is a stored property, so a rename lands in the catalog while every file on
//  disk goes on naming the old string; `RigStore.load` re-derives `rig_state.json`
//  from ids for exactly that reason, and a slot keyed only by name would be the
//  one place left where a rename silently breaks the player's own data.
//
//  THE NINE ARE DIFFERENT, AND THAT IS WHY THEY STILL USE NAMES. `RigPreset`'s
//  names are SOURCE: a rename edits them in the same commit, and
//  `RigPresets.problems()` fails the build if it does not. Nothing renames a file
//  in the player's Documents folder. Same app, opposite guarantees, so the two
//  resolve differently on purpose — see `catalogItem(named:)`, which tries the id,
//  then the retired-name table, then the plain name.
//
//  ITS DATA COMES OFF THE PLAYER'S DISK, NOT OUT OF THIS FILE, which is why the
//  validator below (`missingModels`) is a RUNTIME check and `RigPresets.problems()`
//  is a `#if DEBUG` one. A typo in `RigPresets` is our bug and a developer should
//  trip over it; a slot naming gear a catalog update withdrew is nobody's bug and
//  a player has to be told about it, in the shipping build, in words that do not
//  blame them.
//

import Foundation

// MARK: - The icon set

/// The mark that stands for a saved slot in the list.
///
/// Modelled on `AvatarStyle` down to the shape of it, and for the same reasons:
/// `String`-backed so the raw values land legibly in a JSON file a human may well
/// open, and so that reordering the cases cannot silently repoint every saved
/// slot at a different picture the way an `Int`-backed enum would. `systemImage`
/// is `nil` for the drawn marks and `label` is spoken text, so the artwork and
/// the accessibility label can never disagree about what a case is.
///
/// THE SET IS CURATED, NOT EXHAUSTIVE. Nine of these are the exact SF Symbols the
/// nine factory presets already carry, so a slot the player saved sits visually
/// alongside the nine below it rather than announcing itself as a different kind
/// of thing. The other four are StreetRig's own: SF Symbols has no plectrum, no
/// amp knob, no quarter-inch jack and no vacuum tube, and those four are the most
/// StreetRig things in the app. They are drawn by `AvatarView` in the app target —
/// see `drawnStyle` — rather than redrawn here, so a plectrum is one drawing
/// everywhere it appears.
public enum PresetIcon: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    // The nine the factory presets use, in the order the presets use them.
    case drop, flame, bolt, amplifier, waveform, boltFill, stack, haze, cloud
    // StreetRig's own, drawn in-app. See `AvatarStyle`'s note on the same four.
    case pick, knob, jack, tube

    public var id: String { rawValue }

    /// The SF Symbol that draws this icon, or `nil` for the four drawn marks.
    /// Kept on the model rather than in the picker so the grid's ordering, the
    /// list row, the recipe pane and the accessibility label all read one answer.
    public var systemImage: String? {
        switch self {
        case .drop:      return "drop"
        case .flame:     return "flame"
        case .bolt:      return "bolt"
        case .amplifier: return "amplifier"
        case .waveform:  return "waveform.path"
        case .boltFill:  return "bolt.fill"
        case .stack:     return "square.stack.3d.down.right"
        case .haze:      return "aqi.high"
        case .cloud:     return "cloud"
        case .pick, .knob, .jack, .tube: return nil
        }
    }

    /// Which `AvatarStyle` draws this one, for the four that are not symbols.
    /// The app's `AvatarView` takes an `AvatarStyle`, and pointing at it here is
    /// what keeps the plectrum on a preset row identical to the plectrum on the
    /// profile page instead of a second, slightly different plectrum.
    public var drawnStyle: AvatarStyle? {
        switch self {
        case .pick: return .pick
        case .knob: return .knob
        case .jack: return .jack
        case .tube: return .tube
        default:    return nil
        }
    }

    /// Spoken name, for VoiceOver and for the picker's accessibility labels.
    public var label: String {
        switch self {
        case .drop:      return "Drop"
        case .flame:     return "Flame"
        case .bolt:      return "Bolt"
        case .amplifier: return "Amplifier"
        case .waveform:  return "Waveform"
        case .boltFill:  return "Filled bolt"
        case .stack:     return "Stack"
        case .haze:      return "Haze"
        case .cloud:     return "Cloud"
        case .pick:      return "Plectrum"
        case .knob:      return "Amp knob"
        case .jack:      return "Jack plug"
        case .tube:      return "Valve"
        }
    }

    /// What a slot gets when nobody has chosen yet. An amplifier, because the amp
    /// is the one thing every rig in this app has.
    public static let fallback: PresetIcon = .amplifier
}

// MARK: - The shape of a saved slot

/// One saved rig. See the file header for what it is and how it differs from
/// `RigPreset`.
public struct UserPreset: Codable, Hashable, Identifiable, Sendable {

    /// How many slots there are. FOUR, and four is a promise the list makes by
    /// drawing four rows whether or not they are filled — see `PresetsView`.
    public static let slotCount = 4

    /// The longest name the 250pt list column can print at 11.5pt bold without
    /// truncating. Measured, not guessed, and enforced on every write the way
    /// `Profile.usernameLimit` is — a limit that only exists as helper text is
    /// not a limit. See `PresetEditorView.draft`.
    public static let nameLimit = 18

    /// The current schema. See `schemaVersion`.
    public static let currentSchemaVersion = 1

    /// A head + cabinet, or a combo — the two shapes `AmpSection` has, named by
    /// MODEL rather than by id for the reason in the file header.
    ///
    /// The associated values are LABELLED, including the combo's, purely so the
    /// synthesised `Codable` writes `{"combo":{"name":"Vane HV28"}}` instead of
    /// `{"combo":{"_0":"Vane HV28"}}`. This file ends up in the player's Documents
    /// folder and somebody will read it.
    public enum Amp: Codable, Hashable, Sendable {
        case stack(head: String, cab: String)
        case combo(name: String)
    }

    /// One pedal and EVERY knob on it. Not a curated subset — see the file header.
    public struct Pedal: Codable, Hashable, Sendable {
        public let model: String
        public let values: [String: Double]
        public init(model: String, values: [String: Double]) {
            self.model = model
            self.values = values
        }
    }

    /// One AR footswitch as it stood: the pedal MODEL on it, and whether it was
    /// down. `nil` is an empty switch, which is a real state worth restoring —
    /// three pedals and three switches means it only occurs on a short board, and
    /// the player's short board is still their board.
    public struct ARSlotSnapshot: Codable, Hashable, Sendable {
        public let model: String?
        public let isOn: Bool
        public init(model: String?, isOn: Bool) {
            self.model = model
            self.isOn = isOn
        }
    }

    /// Bumped when the SHAPE of this struct changes in a way a migration has to
    /// know about. Absent in files written before this field existed → treated as
    /// 1, which is what every such file is. Unlike `RigStore.catalogVersion`, a
    /// stale version here must NEVER throw the record away: this is the player's
    /// own work, not seeded content we can regenerate.
    public var schemaVersion: Int
    public var id: UUID
    /// 0…3. Stored on the record as well as implied by its position in the file,
    /// so a record can be read back into the right row without the file having to
    /// keep a sparse array in order.
    public var slot: Int
    /// The player's, clamped to `nameLimit` on every write.
    public var name: String
    public var icon: PresetIcon
    public var savedAt: Date
    public var amp: Amp
    /// The COMPLETE `values` dictionary of the amp item — see the file header.
    public var ampValues: [String: Double]
    /// The guitar's model name.
    ///
    /// Captured even though there is exactly one guitar in this app today, because
    /// the format cannot be changed once players have files: a second guitar added
    /// later would otherwise silently fail to restore, and by then every saved
    /// slot would already lack the field. It is NOT resolved through
    /// `RigStore.catalog` on restore, and that is deliberate — the guitar is
    /// seeded, not offered, so it is in the collection and not in the catalog (see
    /// `RigStore.seed` and `RigStore.allModels`). Restoring it therefore looks in
    /// the collection, and a name that is not there leaves the current guitar
    /// alone rather than failing the whole slot over an item the library never
    /// offered in the first place.
    public var guitar: String
    /// SAVED DISPLAY NAME → the model's FROZEN CATALOG ID, for every piece this
    /// slot names.
    ///
    /// THE ID IS THE IDENTITY AND THE NAME IS DERIVED FROM IT. That rule arrived
    /// with the catalog rename (see `GearItem.catalogID` and
    /// `RigStore.refreshedFromCatalog`), and it exists because `name` is a stored
    /// property: a rename lands in the catalog and every file already on disk goes
    /// on naming the old string, with nothing anywhere to say so. `rig_state.json`
    /// is re-derived from ids on load for exactly that reason.
    ///
    /// A slot keyed only by name would therefore be the one place in the app where
    /// a rename still silently breaks the player's own data — and unlike the nine
    /// factory presets, whose names are source and get renamed in the same commit,
    /// nothing renames a file in the player's Documents folder. So the id travels
    /// with the name, resolution prefers it, and a rename becomes free here too.
    ///
    /// A dictionary rather than an id on each of `Amp`/`Pedal`/`ARSlotSnapshot`
    /// because it is additive: files written before this field decode with it
    /// empty and fall through to the retired-name table, which is exactly the
    /// path `GearItem.init` already takes for the same reason.
    public var catalogIDs: [String: String]
    /// In BOARD order, which is what the player arranged — see the file header.
    public var pedals: [Pedal]
    /// Exactly three, in switch order.
    public var arSlots: [ARSlotSnapshot]

    public init(schemaVersion: Int = UserPreset.currentSchemaVersion,
                id: UUID = UUID(),
                slot: Int,
                name: String,
                icon: PresetIcon = .fallback,
                savedAt: Date = Date(),
                amp: Amp,
                ampValues: [String: Double],
                guitar: String,
                catalogIDs: [String: String] = [:],
                pedals: [Pedal],
                arSlots: [ARSlotSnapshot]) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.slot = slot
        self.name = UserPreset.clamp(name)
        self.icon = icon
        self.savedAt = savedAt
        self.amp = amp
        self.ampValues = ampValues
        self.guitar = guitar
        self.catalogIDs = catalogIDs
        // A hand-edited file is a real input, so the ceiling every other add path
        // in the app obeys is enforced here too rather than trusted.
        self.pedals = Array(pedals.prefix(RigStore.maxPedalsOnBoard))
        self.arSlots = UserPreset.normalise(arSlots)
    }

    /// Truncate-and-flatten, applied on every write so the limit cannot be beaten
    /// by pasting. Mirrors `Profile.clamp` exactly; see its comment.
    public static func clamp(_ raw: String) -> String {
        let flattened = raw.replacingOccurrences(of: "\n", with: " ")
        return String(flattened.prefix(nameLimit))
    }

    /// Always exactly three switches. A file naming two, or five, is normalised
    /// rather than rejected — the AR page indexes these positionally and a short
    /// array is a crash waiting for whoever writes `arSlots[2]`.
    static func normalise(_ slots: [ARSlotSnapshot]) -> [ARSlotSnapshot] {
        var out = Array(slots.prefix(3))
        while out.count < 3 { out.append(ARSlotSnapshot(model: nil, isOn: false)) }
        return out
    }

    // MARK: What it is made of, in words

    /// THE NAMES EXACTLY AS THE RECORD HOLDS THEM. These are what resolution and
    /// wiring key on — never the display names below.
    ///
    /// The distinction is not pedantry; conflating the two cost a real bug. Every
    /// lookup in `apply` (`ids[head]`, `ids[cab]`, `ids[$0.model]`) reads straight
    /// out of the record, so the map has to be keyed by what the record says. Point
    /// `modelNames` at the DISPLAY names instead and a renamed amp resolves fine,
    /// gets its knob values written, and then fails to wire up — returning false
    /// having already mutated the collection, which is precisely the half-applied
    /// state `apply`'s resolve-first contract exists to prevent.
    public var rawAmpName: String {
        switch amp {
        case .stack(let head, _): return head
        case .combo(let name):    return name
        }
    }

    public var rawCabName: String? {
        switch amp {
        case .stack(_, let cab): return cab
        case .combo:             return nil
        }
    }

    /// The amp's name AS THE CATALOG CALLS IT TODAY, not as it was written at
    /// save time — see `currentName`. FOR DISPLAY ONLY: a recipe pane printing a
    /// retired name beside a rig that shows the new one is the same class of lie
    /// the id-keying exists to stop, but resolution must use `rawAmpName`.
    public var ampName: String {
        switch amp {
        case .stack(let head, _): return currentName(head)
        case .combo(let name):    return currentName(name)
        }
    }

    public var cabName: String? {
        switch amp {
        case .stack(_, let cab): return currentName(cab)
        case .combo:             return nil
        }
    }

    /// Every model the RIG needs, amp section first — the mirror of
    /// `RigPreset.modelNames`, and what `RigStore.apply(_ preset: UserPreset)` has
    /// to be able to resolve before it touches anything. The guitar is not in here
    /// on purpose; see `guitar`.
    public var modelNames: [String] {
        var names = [rawAmpName]
        if let rawCabName { names.append(rawCabName) }
        names.append(contentsOf: pedals.map(\.model))
        return names
    }

    /// What to PRINT wherever this slot's name appears. Never empty.
    ///
    /// An unnamed slot is a legitimate state, not an error: saving fills the slot
    /// FIRST and opens the editor second (see `PresetsView.saveCurrentRig`), so
    /// there is a real moment where a rig is saved and not yet named, and a player
    /// who backs out of the editor keeps their rig rather than losing it to a
    /// validation rule. `Profile.displayName` solves the same problem the same
    /// way. The fallback is the slot's own number because that is the one true
    /// thing we know about it.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? UserPreset.fallbackName(forSlot: slot) : trimmed
    }

    /// What an unnamed slot is called. Deliberately the slot's own number rather
    /// than something derived from the amp: a truncated "Mesquite Bootleg Dual R" reads
    /// as a bug, and "SLOT 3" reads as a thing waiting to be named — which it is.
    public static func fallbackName(forSlot slot: Int) -> String { "SLOT \(slot + 1)" }

    /// What the list row prints under the name, e.g. "Fremont GX-140 · 3 pedals".
    public var summary: String {
        let count = pedals.count
        let board = count == 0 ? "no pedals" : "\(count) pedal\(count == 1 ? "" : "s")"
        return "\(ampName) · \(board)"
    }

    /// "Saved 14 Aug, 21:04". Short because it sits in a 250pt column, and dated
    /// rather than relative ("2 days ago") because a slot is a thing you come back
    /// to in three months and a relative date stops meaning anything by then.
    public var savedAtText: String {
        savedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    /// THE SIX THE ENGINE ACTUALLY READS. Shares one implementation with
    /// `RigPreset.ampHeadline` — see `AmpHeadline` for why that is not optional.
    public var ampHeadline: [(label: String, value: Double)] {
        AmpHeadline.resolve(ampValues)
    }

    // MARK: Resolving a saved name against today's catalog

    /// The one place a saved name becomes a catalog item, in the order that keeps
    /// a rename free: FROZEN ID first, the retired-name table second, and a plain
    /// name match last.
    ///
    /// The last step is not dead code — it catches a hand-edited file, and a slot
    /// written before `catalogIDs` existed naming gear that was never renamed.
    /// The middle step is what `GearItem.init` already does with the same table,
    /// and having both here means a slot saved before the rename resolves without
    /// a migration pass over the file.
    public func catalogItem(named savedName: String) -> GearItem? {
        if let id = catalogIDs[savedName],
           let byID = RigStore.catalog.first(where: { $0.catalogID == id }) { return byID }
        if let id = GearCatalog.retiredID(forName: savedName),
           let retired = RigStore.catalog.first(where: { $0.catalogID == id }) { return retired }
        return RigStore.catalog.first { $0.name == savedName }
    }

    /// What to PRINT for a piece this slot named. The name the catalog uses today
    /// when it still resolves, and the saved name when it does not — a slot whose
    /// gear is gone should say what it was, since that is the only fact left that
    /// helps the player understand what changed.
    public func currentName(_ savedName: String) -> String {
        catalogItem(named: savedName)?.name ?? savedName
    }

    /// A pedal's settings IN PANEL ORDER, labelled the way its own faceplate
    /// labels them. Same construction as `RigPreset.settings(for:)`, built from a
    /// throwaway `GearItem` because a dictionary has no order and "Level 7 · Tone
    /// 6 · Overdrive 3" is a Valve Shrieker described backwards.
    public func settings(for pedal: Pedal) -> [(label: String, value: Double)] {
        guard let entry = catalogItem(named: pedal.model) else { return [] }
        let spec = GearItem(name: entry.name, category: entry.category)
        return spec.parameters.compactMap { parameter in
            pedal.values[parameter.name].map { (parameter.displayName, $0) }
        }
    }

    /// How many knob values this slot is carrying, all items together. Printed on
    /// the save pane so "a snapshot of everything" is a number rather than a claim.
    public var knobCount: Int {
        ampValues.count + pedals.reduce(0) { $0 + $1.values.count }
    }

    // MARK: The runtime check

    /// Models this slot names that the catalog does not offer today.
    ///
    /// RUNTIME, NOT DEBUG, and that is the difference between this and
    /// `RigPresets.problems()`. That one guards data written in this repository,
    /// so a developer is the right person to see it. This one guards data that
    /// came off the player's disk: a catalog update can withdraw a model
    /// (`RigStore.withheldModels`) months after a slot was saved, and the player
    /// has to be told, in the shipping build, that the slot cannot load and why —
    /// without being told it is their fault, because it is not.
    public var missingModels: [String] {
        modelNames.filter { catalogItem(named: $0) == nil }
    }

    /// False when this slot names gear that is gone. Such a slot still renders,
    /// still says what it was, and still offers DELETE; what it does not do is
    /// load — see `RigStore.apply(_ preset: UserPreset)`.
    public var isLoadable: Bool { missingModels.isEmpty }

    /// The honest sentence for a slot that cannot load, or `nil` when it can.
    /// Names the gear, because "this preset is broken" tells the player nothing
    /// they can act on and naming the model at least tells them what changed.
    public var loadProblem: String? {
        let missing = missingModels
        guard !missing.isEmpty else { return nil }
        let names = missing.map { "\"\($0)\"" }
        let list = names.count == 1
            ? names[0]
            : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return "This build no longer has \(list), so this slot can't be loaded."
    }

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, slot, name, icon, savedAt, amp, ampValues, guitar, catalogIDs, pedals, arSlots
    }

    /// Hand-written, for exactly the reason `Profile`'s is: the synthesised
    /// decoder throws on any missing or unrecognised key, and a throw here costs
    /// the player a rig they saved. Every field falls back instead, so the worst
    /// case is one slot arriving degraded — and a degraded slot lands in the
    /// designed failure path (greyed, honest, deletable) rather than taking the
    /// other three down with it.
    ///
    /// Add a field → give it a `decodeIfPresent` and a default here.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func lenient<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            ((try? c.decodeIfPresent(type, forKey: key)) ?? nil)
        }
        schemaVersion = lenient(Int.self, .schemaVersion) ?? 1
        id            = lenient(UUID.self, .id) ?? UUID()
        slot          = lenient(Int.self, .slot) ?? 0
        name          = UserPreset.clamp(lenient(String.self, .name) ?? "")
        icon          = PresetIcon(rawValue: lenient(String.self, .icon) ?? "") ?? .fallback
        savedAt       = lenient(Date.self, .savedAt) ?? Date()
        // An unreadable amp section degrades to a pair of empty names, which the
        // catalog cannot resolve — so the slot shows up in the list as broken and
        // refuses to load, which is the truth about it.
        amp           = lenient(Amp.self, .amp) ?? .stack(head: "", cab: "")
        ampValues     = lenient([String: Double].self, .ampValues) ?? [:]
        guitar        = lenient(String.self, .guitar) ?? ""
        // Empty for every file written before ids travelled with the names. That
        // is the designed path, not a degraded one — `catalogItem(named:)` falls
        // through to the retired-name table, which is what such a file needs.
        catalogIDs    = lenient([String: String].self, .catalogIDs) ?? [:]
        pedals        = Array((lenient([Pedal].self, .pedals) ?? []).prefix(RigStore.maxPedalsOnBoard))
        arSlots       = UserPreset.normalise(lenient([ARSlotSnapshot].self, .arSlots) ?? [])
    }
}

// MARK: - The channel rule, in one place

/// THE SIX AMP KNOBS THE ENGINE ACTUALLY READS, resolved the way
/// `RigGraphCompiler` resolves them: a two-channel amp's controls come from the
/// `" 2"`-suffixed keys when `CHANNEL` is on 1.
///
/// IT IS A FUNCTION BECAUSE THERE ARE NOW TWO CALLERS, and the header of
/// `RigPreset.swift` already warned what a divergence here costs: the preset page
/// prints these numbers as a promise that they are the numbers on the faceplate,
/// so a copy of this expression that drifts makes the page quietly lie about the
/// amp. `RigPreset.ampHeadline` and `UserPreset.ampHeadline` are both one line
/// long for that reason.
///
/// If the compiler's rule ever changes, it changes HERE, in the same commit.
public enum AmpHeadline {

    /// A knob the values do not mention is OMITTED rather than printed at a
    /// guess: the honest answer for it is "whatever that amp's panel defaults
    /// to", which is not a number this function knows.
    public static func resolve(_ values: [String: Double]) -> [(label: String, value: Double)] {
        let onChannelTwo = (values["CHANNEL"] ?? 0) >= 0.5
        func role(_ keys: [String]) -> Double? {
            if onChannelTwo {
                for key in keys { if let v = values[key + " 2"] { return v } }
            }
            for key in keys { if let v = values[key] { return v } }
            return nil
        }
        var out: [(String, Double)] = []
        if let v = role(["Gain", "GAIN"])     { out.append(("GAIN", v)) }
        if let v = role(["Bass", "BASS"])     { out.append(("BASS", v)) }
        if let v = role(["Mid", "MIDDLE"])    { out.append(("MID", v)) }
        if let v = role(["Treble", "TREBLE"]) { out.append(("TREBLE", v)) }
        // CUT and PRESENCE are the same destination under two names (the AC30
        // prints CUT and it runs backwards); print whichever the panel shows.
        if let v = role(["Cut"])              { out.append(("CUT", v)) }
        else if let v = role(["Presence"])    { out.append(("PRESENCE", v)) }
        if let v = role(["Master"])           { out.append(("MASTER", v)) }
        if let v = role(["Volume"])           { out.append(("VOLUME", v)) }
        return out
    }
}

// MARK: - Taking one, and putting one back

extension RigStore {

    /// Photograph the rig as it stands right now.
    ///
    /// EVERYTHING, NOT A SELECTION. The amp's whole `values` dictionary, every
    /// pedal's whole `values` dictionary, the board in the order it is actually
    /// in, the guitar and all three footswitches. A snapshot that curated would be
    /// a second recipe, and the player already has nine of those.
    ///
    /// A rig with NO AMP still snapshots, into an amp section whose names resolve
    /// to nothing. It is the caller's job not to offer SAVE in that state (see
    /// `PresetsView`), but a store method that traps or returns nil for a legal —
    /// and loudly signposted — rig state would be the wrong shape of answer.
    public func snapshot(slot: Int, name: String, icon: PresetIcon) -> UserPreset {
        let amp: UserPreset.Amp
        switch rig.ampSection {
        case .stack:
            amp = .stack(head: ampItem?.name ?? "", cab: cabinetItem?.name ?? "")
        case .combo:
            amp = .combo(name: ampItem?.name ?? "")
        }

        let board = pedalItems.map { UserPreset.Pedal(model: $0.name, values: $0.values) }

        let switches = arSlots.map { slot in
            UserPreset.ARSlotSnapshot(model: slot.pedalId.flatMap { item($0)?.name },
                                      isOn: slot.isOn)
        }

        // THE IDS, CAPTURED AT SAVE TIME, keyed by the name written beside them.
        // Everything the slot names goes in — the amp section, the board, the
        // guitar and whatever is on the footswitches, which can include a pedal
        // that is owned but not currently on the board.
        var ids: [String: String] = [:]
        for piece in [ampItem, cabinetItem, guitar].compactMap({ $0 })
                   + pedalItems
                   + arSlots.compactMap({ $0.pedalId.flatMap(item) }) {
            if let catalogID = piece.catalogID { ids[piece.name] = catalogID }
        }

        return UserPreset(slot: slot,
                          name: name,
                          icon: icon,
                          amp: amp,
                          ampValues: ampItem?.values ?? [:],
                          guitar: guitar?.name ?? "",
                          catalogIDs: ids,
                          pedals: board,
                          arSlots: switches)
    }

    /// Put a saved slot back on the stage, exactly as it was saved.
    ///
    /// RESOLVE EVERYTHING FIRST, MUTATE NOTHING UNTIL IT ALL RESOLVES — the same
    /// rule `apply(_ preset: RigPreset)` obeys, and here it protects against a
    /// different cause: not a typo in our data but a model this app has since
    /// withdrawn from under a file the player wrote months ago. Either way half a
    /// rig is worse than the rig they already had, so a slot naming missing gear
    /// returns `false` having changed nothing. `UserPreset.isLoadable` answers the
    /// same question ahead of time, which is what lets the list grey the row
    /// instead of letting the player press a button that cannot work.
    ///
    /// IT ADDS, IT NEVER DELETES. Gear the slot does not want comes OFF the board
    /// and stays in the collection; nothing is ever disowned.
    ///
    /// KNOBS ARE REPLACED, NOT MERGED — and this is the one place that
    /// deliberately contradicts `apply(_ preset: RigPreset)`, which merges. A
    /// factory preset is a RECIPE that sets nine knobs and leaves the rest alone.
    /// A user slot is a PHOTOGRAPH of a rig and has to reproduce it. If it merged,
    /// loading your own saved clean tone after a metal session would leave the
    /// metal channel's gain sitting underneath it — invisible until you flipped
    /// the channel switch — and the slot would not be the thing you saved.
    ///
    /// IT RESTORES THE AR FOOTSWITCHES, which `apply(_ preset: RigPreset)`
    /// deliberately does not. That is not an oversight in either place, and the
    /// note on the other method has been amended to say so: a factory preset is
    /// somebody else's rig and has no opinion about where the player's feet go, so
    /// silently rewriting the AR page from it would be overreach. A user slot
    /// recorded THAT PLAYER'S OWN footswitch layout at save time, and a snapshot
    /// that came back with the pedals in the right order and the switches in the
    /// wrong ones would not be the rig they saved. If a slot's switch names a
    /// pedal that is not on the board after the restore, the switch is CLEARED
    /// rather than left bound to something silent.
    ///
    /// THE BOARD KEEPS THE SAVED ORDER. `apply(_ preset: RigPreset)` sorts by
    /// `chainOrder` because the order pedals are typed into a source file is
    /// arbitrary; this order is not arbitrary, it is what the player arranged with
    /// `movePedal`, and re-sorting it here would undo a deliberate choice every
    /// time they loaded their own rig back.
    @discardableResult
    public func apply(_ preset: UserPreset) -> Bool {
        // 1. RESOLVE. Nothing below this block mutates, and nothing above it does
        //    either, so an early return here leaves the rig untouched.
        // `saved` rides along because a renamed piece resolves to an entry whose
        // name no longer matches the record — and every wiring lookup below is
        // keyed by what the record says.
        var wanted: [(saved: String, entry: GearItem, values: [String: Double]?)] = []
        for name in preset.modelNames {
            guard let entry = preset.catalogItem(named: name) else { return false }
            let values: [String: Double]?
            switch entry.category {
            case .amp, .comboAmp:  values = preset.ampValues
            // A cabinet has no controls, so there is nothing to replace. `nil`
            // rather than `[:]` on purpose: writing an empty dictionary over a cab
            // would be a no-op today and a data loss the day a cab gains a knob.
            case .cabinet:         values = nil
            default:               values = preset.pedals.first { $0.model == name }?.values
            }
            wanted.append((name, entry, values))
        }

        // 2. OWN IT AND DIAL IT IN. `ownedInstance` matches by MODEL, so a slot
        //    reuses the copy already in the rail rather than adding a second one.
        var ids: [String: UUID] = [:]
        for (saved, entry, values) in wanted {
            let id: UUID
            if let owned = ownedInstance(of: entry) {
                id = owned.id
            } else {
                let fresh = GearItem(name: entry.name, category: entry.category)
                collection.append(fresh)
                id = fresh.id
            }
            // REPLACED, not merged — see the doc comment. A value the saved slot
            // has no key for (a knob added by a later build) is left absent, which
            // `RigStore.binding` already reads as "use the parameter's default"
            // rather than as zero.
            if let values, let index = collection.firstIndex(where: { $0.id == id }) {
                collection[index].values = values
            }
            // KEYED BY THE SAVED NAME, not the catalog's current one. Every
            // lookup below (`head`, `cab`, `$0.model`, the footswitches) comes
            // out of the record, so keying this by `entry.name` would miss on
            // exactly the renamed gear the id lookup just successfully resolved
            // — the restore would resolve everything and then fail to wire it up.
            ids[saved] = id
        }

        // 3. WIRE IT UP.
        switch preset.amp {
        case .stack(let head, let cab):
            guard let headId = ids[head], let cabId = ids[cab] else { return false }
            rig.ampSection = .stack(ampId: headId, cabinetId: cabId)
        case .combo(let name):
            guard let comboId = ids[name] else { return false }
            rig.ampSection = .combo(comboId: comboId)
        }

        let board = preset.pedals.compactMap { ids[$0.model] }
        rig.pedalIds = Array(board.prefix(RigStore.maxPedalsOnBoard))

        // The guitar is resolved against the COLLECTION, not the catalog, and a
        // miss is survivable — see `UserPreset.guitar` for the whole argument.
        // Id first here too, so a renamed guitar restores. Falls back to the name
        // for slots written before ids travelled.
        let guitarID = preset.catalogIDs[preset.guitar] ?? GearCatalog.retiredID(forName: preset.guitar)
        if let owned = collection.first(where: { $0.category == .guitar
                                                && ($0.catalogID != nil && $0.catalogID == guitarID
                                                    || $0.name == preset.guitar) }) {
            rig.guitarId = owned.id
        }

        // 4. STAND THE FEET BACK WHERE THEY WERE. Last, because setting
        //    `rig.pedalIds` above ran `syncARSlotsToRig`, which will have filled
        //    the switches in board order — a reasonable guess, and not what the
        //    player saved.
        restoreARSlots(preset.arSlots, ids: ids)
        return true
    }

    /// Put the three footswitches back, then make sure the result is a legal
    /// arrangement rather than merely a faithful one.
    ///
    /// Three rules, all of them ones `setARSlot` and `syncARSlotsToRig` already
    /// enforce elsewhere, restated here because this writes `arSlots` directly:
    ///  • A switch naming a pedal that is not on the board is CLEARED. A binding
    ///    the graph cannot resolve compiles into a bypass rule for a pedal that
    ///    is not there — a switch that toggles nothing.
    ///  • ONE PEDAL, ONE FOOTSWITCH. A hand-edited file can name the same pedal
    ///    twice; the first switch keeps it.
    ///  • A board pedal left with no switch takes the first free one, ON. That is
    ///    `syncARSlotsToRig`'s rule, and leaving it violated here would only mean
    ///    the next rig edit silently applied it anyway.
    private func restoreARSlots(_ saved: [UserPreset.ARSlotSnapshot], ids: [String: UUID]) {
        let onBoard = Set(rig.pedalIds)
        var next: [ARSlot] = []
        var bound = Set<UUID>()

        for snapshot in UserPreset.normalise(saved) {
            // `ids` already holds every model the slot named — the resolve pass
            // above filled it — so a switch naming anything else is naming
            // something this slot never put on the board.
            guard let model = snapshot.model, let id = ids[model],
                  onBoard.contains(id), !bound.contains(id)
            else { next.append(ARSlot()); continue }
            bound.insert(id)
            next.append(ARSlot(pedalId: id, isOn: snapshot.isOn))
        }

        for id in rig.pedalIds where !bound.contains(id) {
            guard let free = next.firstIndex(where: { $0.pedalId == nil }) else { break }
            next[free] = ARSlot(pedalId: id, isOn: true)
            bound.insert(id)
        }

        guard next != arSlots else { return }
        arSlots = next
    }
}
