//
//  UserPresetStore.swift
//  StreetRigEngine
//
//  WHERE THE PLAYER'S FOUR SLOTS LIVE. `UserPreset` says what a saved rig is;
//  this says where it is kept and how it survives a relaunch.
//
//  IT IS A COPY OF `ProfileStore`, ON PURPOSE. An `ObservableObject` over one
//  `Codable` value, JSON in the folder `RigStore` already chose, a debounced
//  autosave, a `schemaVersion` from day one and a `persist: false` mode so
//  previews never touch the filesystem. That shape is now proven twice in this
//  app, and a third persistence story — `@AppStorage` with four JSON strings in
//  it, say — would have saved perhaps thirty lines and cost the app a differently
//  shaped answer to "where is my stuff" for no gain at all.
//
//  BESIDE `rig_state.json` AND `profile.json`, NOT IN A FOLDER OF ITS OWN.
//  `RigStore.stateDirectory()` is `internal static` precisely so a second — and
//  now a third — store can share the one directory; its comment says two
//  locations means two answers to "where is my stuff", and any future "reset
//  everything" would clear one and quietly miss the other. Nothing here creates
//  a directory.
//
//  A CORRUPT FILE COSTS THE PLAYER NOTHING IT DOES NOT HAVE TO. Three levels of
//  give, from the outside in:
//    • the file will not parse at all → four empty slots, no crash;
//    • the file parses but one record is malformed → `UserPreset`'s lenient
//      decoder degrades that record instead of throwing, so it lands in the
//      designed failure path (greyed, honest, deletable) and the other three
//      slots load normally;
//    • the file is from a NEWER or older schema → it is still read.
//  That last one is the important departure from `RigStore`, which discards a
//  state file below its `catalogVersion` and re-seeds. It can afford to: the
//  gear collection is content we ship and can regenerate. These four slots are
//  the player's own work, and throwing them away to be safe is not safe.
//
//  NOTHING LEAVES THE DEVICE. `ProfileStore`'s header calls that a contract
//  rather than decoration, and the profile page prints it in visible text. Four
//  local slots keep it true — there is no account here, no sync and no network
//  call, and a future change that adds one has to revisit that sentence in the
//  UI at the same time.
//

import SwiftUI
import Combine

// MARK: - The file

/// The on-disk shape of `user_presets.json`.
///
/// A SPARSE ARRAY OF FILLED SLOTS rather than four entries with `null`s in the
/// gaps. Each record carries its own `slot`, so the file cannot be broken by
/// having the wrong number of elements in it — which a four-long array with a
/// hand-edited hole absolutely can be — and somebody reading the file sees only
/// the rigs that exist.
///
/// It carries a `schemaVersion` of its OWN, separate from the one on each
/// `UserPreset`. They answer different questions: this one describes the
/// container's shape, the record's describes a record's, and the container can
/// change (a fifth slot, an ordering field) without every saved rig being a
/// different version of itself.
struct UserPresetFile: Codable {
    var schemaVersion: Int
    var presets: [UserPreset]

    static let currentSchemaVersion = 1

    private enum CodingKeys: String, CodingKey { case schemaVersion, presets }

    init(schemaVersion: Int = UserPresetFile.currentSchemaVersion, presets: [UserPreset]) {
        self.schemaVersion = schemaVersion
        self.presets = presets
    }

    /// Lenient for the same reason `Profile`'s decoder is — see the file header.
    /// A missing `presets` key is an empty board of slots, not a thrown error.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = ((try? c.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? nil) ?? 1
        presets = ((try? c.decodeIfPresent([UserPreset].self, forKey: .presets)) ?? nil) ?? []
    }
}

// MARK: - The store

/// Owns the player's four saved rigs and persists them, in the same shape and the
/// same folder as `RigStore` owns the gear and `ProfileStore` owns the name.
@MainActor
public final class UserPresetStore: ObservableObject {

    /// Exactly `UserPreset.slotCount` entries, `nil` for an empty slot.
    ///
    /// ALWAYS FOUR, never a shorter array of "the ones that exist". The list
    /// draws four rows whether or not they are filled, because "you get four" is
    /// legible at a glance in a way an "+ ADD" button is not, and because the
    /// slot NUMBER is stable — which will matter the day a release maps a slot to
    /// a footswitch. Every write below goes through `guard slots.indices.contains`
    /// so the invariant cannot be broken from outside.
    @Published public private(set) var slots: [UserPreset?]

    private let saveURL: URL
    private let persist: Bool
    private var cancellables = Set<AnyCancellable>()

    /// `persist: false` keeps everything in memory (SwiftUI previews), exactly as
    /// `RigStore(persist:)` and `ProfileStore(persist:)` do and for the same
    /// reason: a preview must never touch the player's real files.
    public init(persist: Bool = true) {
        self.persist = persist
        saveURL = Self.stateURL()

        slots = Array(repeating: nil, count: UserPreset.slotCount)
        if persist, let loaded = Self.load(from: saveURL) {
            for preset in loaded where slots.indices.contains(preset.slot) {
                slots[preset.slot] = preset
            }
        }

        guard persist else { return }

        // Debounced autosave, 0.4s — the same window the other two stores use.
        // Renaming is typed one character at a time and a save per keystroke is a
        // file write per keystroke.
        $slots
            .dropFirst()
            .debounce(for: .seconds(0.4), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &cancellables)
    }

    /// In-memory store for SwiftUI previews (no disk I/O).
    public static var preview: UserPresetStore { UserPresetStore(persist: false) }

    /// A preview with two slots filled, for checking that a filled row, an empty
    /// row and the group label all sit together in a 250pt column.
    public static var previewFilled: UserPresetStore {
        let store = UserPresetStore(persist: false)
        store.slots[0] = UserPreset(
            slot: 0, name: "MY CRUNCH", icon: .pick,
            amp: .stack(head: "Marswell JCM800 2203", cab: "Marswell 1960A 4x12"),
            ampValues: ["Gain": 7, "Bass": 5, "Mid": 6.5, "Treble": 6.5, "Presence": 6, "Master": 6],
            guitar: "Les Paul Standard",
            pedals: [UserPreset.Pedal(model: "Ibonez Tube Screamer",
                                      values: ["Overdrive": 3.5, "Tone": 6, "Level": 6.5])],
            arSlots: [UserPreset.ARSlotSnapshot(model: "Ibonez Tube Screamer", isOn: true),
                      UserPreset.ARSlotSnapshot(model: nil, isOn: false),
                      UserPreset.ARSlotSnapshot(model: nil, isOn: false)])
        // Deliberately names gear the catalog does not offer, so the greyed
        // "can't load" row is previewable without hand-editing a JSON file.
        store.slots[2] = UserPreset(
            slot: 2, name: "GONE", icon: .cloud,
            amp: .combo(name: "Fender Deluxe"),
            ampValues: ["Gain": 5],
            guitar: "Les Paul Standard",
            pedals: [],
            arSlots: [])
        return store
    }

    // MARK: - Reading

    public func preset(at slot: Int) -> UserPreset? {
        guard slots.indices.contains(slot) else { return nil }
        return slots[slot]
    }

    public func isEmpty(_ slot: Int) -> Bool { preset(at: slot) == nil }

    /// The id this slot is remembered by in `AppPreferences.lastPresetLoaded`.
    /// NAMESPACED so a user slot's id can never collide with a factory preset's
    /// (`"slot:2"` against `"metal"`) — the two live in one key and always will,
    /// because the page only ever loaded one thing last.
    public static func storageID(forSlot slot: Int) -> String { "slot:\(slot)" }

    // MARK: - Writing

    /// Fill (or overwrite) a slot. The caller confirms an overwrite first — a
    /// slot is unrecoverable once replaced, and this method is the point of no
    /// return, not the place to ask.
    public func save(_ preset: UserPreset, to slot: Int) {
        guard slots.indices.contains(slot) else { return }
        var stored = preset
        stored.slot = slot
        stored.schemaVersion = UserPreset.currentSchemaVersion
        slots[slot] = stored
    }

    /// EMPTIES a slot; it does not renumber the others. Slot 3 stays slot 3 when
    /// slot 2 is deleted, because the promise the list makes is four numbered
    /// places, not a list that closes up behind you.
    public func clear(_ slot: Int) {
        guard slots.indices.contains(slot), slots[slot] != nil else { return }
        slots[slot] = nil
    }

    /// Rename in place. Clamped and trimmed here as well as in the editor,
    /// because this is public and the editor is not the only possible caller.
    ///
    /// An EMPTY name is stored as empty rather than rejected. A slot is filled
    /// before it is named, so "saved but not yet named" is a state that really
    /// occurs, and `UserPreset.displayName` — the only thing that ever prints a
    /// name — answers "SLOT 3" for it. Refusing the write instead would mean a
    /// player who cleared the field saw their old name come back.
    public func rename(_ slot: Int, to name: String) {
        guard slots.indices.contains(slot), var preset = slots[slot] else { return }
        preset.name = UserPreset.clamp(name).trimmingCharacters(in: .whitespacesAndNewlines)
        slots[slot] = preset
    }

    public func setIcon(_ icon: PresetIcon, for slot: Int) {
        guard slots.indices.contains(slot), var preset = slots[slot] else { return }
        preset.icon = icon
        slots[slot] = preset
    }

    // MARK: - Persistence

    public func save() {
        guard persist else { return }
        Self.write(slots.compactMap { $0 }, to: saveURL)
    }

    /// Beside `rig_state.json` and `profile.json`, in the folder `RigStore`
    /// already chose — see `RigStore.stateDirectory()` and this file's header.
    private static func stateURL() -> URL {
        RigStore.stateDirectory().appendingPathComponent("user_presets.json")
    }

    private static func load(from url: URL) -> [UserPreset]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A file this cannot parse at all degrades to four empty slots. It is NOT
        // deleted here — the next write will replace it, but until then it is
        // still on disk where somebody could look at it.
        guard let file = try? decoder.decode(UserPresetFile.self, from: data) else { return nil }
        return file.presets
    }

    private static func write(_ presets: [UserPreset], to url: URL) {
        let encoder = JSONEncoder()
        // ISO-8601 and pretty-printed, both for the same reason: this file sits in
        // the player's own Documents folder and the format is one somebody may
        // reasonably open. A `savedAt` written as `776543210.123` seconds since
        // 2001 is not a date a human can read.
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = UserPresetFile(presets: presets)
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
