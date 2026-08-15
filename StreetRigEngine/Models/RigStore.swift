//
//  RigStore.swift
//  StreetRig
//
//  Owns the user's gear collection and current rig, and persists both to a
//  JSON file in Documents so choices survive logout / app restarts. On first
//  launch it seeds a believable default collection and a starter rig.
//

import SwiftUI
import Combine

@MainActor
public final class RigStore: ObservableObject {
    @Published public var collection: [GearItem]
    @Published public var rig: RigConfiguration
    @Published public var arSlots: [ARSlot] = [ARSlot(), ARSlot(), ARSlot()]

    private let saveURL: URL
    private let persist: Bool
    private var cancellables = Set<AnyCancellable>()

    /// `persist: false` keeps everything in memory (used by SwiftUI previews)
    /// so the preview sandbox never touches the filesystem or the autosave loop.
    public init(persist: Bool = true) {
        self.persist = persist
        saveURL = Self.stateURL()

        if persist, let loaded = Self.load(from: saveURL) {
            collection = loaded.collection
            rig = loaded.rig
            if let slots = loaded.arSlots { arSlots = slots }
        } else {
            let seed = Self.seed()
            collection = seed.collection
            rig = seed.rig
            if persist {
                // Persist the seed immediately so the first launch is durable.
                Self.write(PersistedState(collection: seed.collection, rig: seed.rig, arSlots: arSlots,
                                          catalogVersion: Self.catalogVersion), to: saveURL)
            }
        }

        guard persist else { return }

        // Debounced autosave on any change (covers slider drags, drops, reorders, AR slots).
        Publishers.CombineLatest3($collection, $rig, $arSlots)
            .dropFirst()
            .debounce(for: .seconds(0.4), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &cancellables)
    }

    /// In-memory store for SwiftUI previews (seeded, no disk I/O).
    public static var preview: RigStore { RigStore(persist: false) }

    // MARK: - Lookups

    public func item(_ id: UUID) -> GearItem? { collection.first { $0.id == id } }

    public var guitar: GearItem? { item(rig.guitarId) }

    public var ampItem: GearItem? {
        switch rig.ampSection {
        case .stack(let ampId, _): return item(ampId)
        case .combo(let comboId): return item(comboId)
        }
    }

    public var cabinetItem: GearItem? {
        if case .stack(_, let cabinetId) = rig.ampSection { return item(cabinetId) }
        return nil
    }

    public var isCombo: Bool {
        if case .combo = rig.ampSection { return true }
        return false
    }

    public var pedalItems: [GearItem] { rig.pedalIds.compactMap { item($0) } }

    // MARK: - Mutations

    /// Apply a dropped/selected item to the rig, replacing the matching part.
    public func apply(_ dropped: GearItem) {
        switch dropped.category {
        case .guitar:
            return // guitar isn't customizable
        case .amp:
            switch rig.ampSection {
            case .stack(_, let cabId):
                rig.ampSection = .stack(ampId: dropped.id, cabinetId: cabId)
            case .combo:
                let cab = collection.first { $0.category == .cabinet }?.id ?? dropped.id
                rig.ampSection = .stack(ampId: dropped.id, cabinetId: cab)
            }
        case .cabinet:
            switch rig.ampSection {
            case .stack(let ampId, _):
                rig.ampSection = .stack(ampId: ampId, cabinetId: dropped.id)
            case .combo:
                let amp = collection.first { $0.category == .amp }?.id ?? dropped.id
                rig.ampSection = .stack(ampId: amp, cabinetId: dropped.id)
            }
        case .comboAmp:
            rig.ampSection = .combo(comboId: dropped.id)
        default: // a pedal
            guard !rig.pedalIds.contains(dropped.id) else { return }
            rig.pedalIds.append(dropped.id)
            rig.pedalIds.sort { chainOrder(of: $0) < chainOrder(of: $1) }
        }
    }

    public func removePedal(_ id: UUID) {
        rig.pedalIds.removeAll { $0 == id }
    }

    /// Replace the pedal currently occupying `slotId`'s spot with `dropped`,
    /// keeping the board in signal-chain order and never leaving a duplicate id.
    /// Used by the rig stage's drag-to-replace: drop a pedal onto a specific
    /// pedal to swap that one. Falls back to a plain add for a non-pedal.
    public func replacePedal(_ slotId: UUID, with dropped: GearItem) {
        guard dropped.category.isPedal else { apply(dropped); return }
        var ids = rig.pedalIds
        // Drop any existing copy of the incoming pedal so the chain stays unique.
        ids.removeAll { $0 == dropped.id }
        if let idx = ids.firstIndex(of: slotId) {
            ids[idx] = dropped.id            // swap the hovered pedal in place
        } else if !ids.contains(dropped.id) {
            ids.append(dropped.id)           // slot was the incoming pedal itself (self-drop)
        }
        ids.sort { chainOrder(of: $0) < chainOrder(of: $1) }
        rig.pedalIds = ids
    }

    func movePedal(fromOffsets: IndexSet, toOffset: Int) {
        rig.pedalIds.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    /// Whether the owned collection already contains this gear (matched by model).
    public func isOwned(_ item: GearItem) -> Bool {
        collection.contains { $0.name == item.name && $0.category == item.category }
    }

    /// Add a copy of a catalog item to the owned collection (fresh id + default knobs).
    public func addToCollection(_ item: GearItem) {
        guard !isOwned(item) else { return }
        collection.append(GearItem(name: item.name, category: item.category))
    }

    // MARK: - AR stomp slots

    /// The pedal assigned to an AR slot, if any.
    public func arPedal(_ index: Int) -> GearItem? {
        guard arSlots.indices.contains(index), let id = arSlots[index].pedalId else { return nil }
        return item(id)
    }

    /// Assign (or clear) the pedal in an AR slot — i.e. put a FOOTSWITCH on a
    /// pedal, or take it off again.
    ///
    /// Two rules the audio path depends on (see `RigGraphCompiler.compile`):
    ///  • Binding defaults the slot to **ON**. An unbound pedal is always enabled,
    ///    so a slot that defaulted to off would instantly bypass a pedal that was
    ///    audibly working the moment you dropped it on a switch.
    ///  • A footswitch only makes sense for a pedal that is IN the chain, so a
    ///    pedal that isn't gets added first. That is a structural rig edit, which
    ///    `RigAudioBridge` applies through the fade/park barrier.
    /// Clearing a slot leaves the pedal in the chain and unbound → enabled again;
    /// it is never stranded in bypass.
    public func setARSlot(_ index: Int, pedalId: UUID?) {
        guard arSlots.indices.contains(index) else { return }
        guard let pedalId else { arSlots[index] = ARSlot(); return }

        if let gear = item(pedalId), gear.category.isPedal, !rig.pedalIds.contains(pedalId) {
            apply(gear)                                   // structural: into the chain
        }
        // One pedal, one footswitch: release any other slot holding it, so the
        // enabled-state rule has a single unambiguous source.
        for i in arSlots.indices where i != index && arSlots[i].pedalId == pedalId {
            arSlots[i] = ARSlot()
        }
        arSlots[index] = ARSlot(pedalId: pedalId, isOn: true)
    }

    /// Toggle an AR slot's pedal on/off (only if a pedal is assigned).
    public func toggleARSlot(_ index: Int) {
        guard arSlots.indices.contains(index), arSlots[index].pedalId != nil else { return }
        arSlots[index].isOn.toggle()
    }

    /// Two-way binding to one knob of one owned item (used by the zoom sliders).
    public func binding(itemId: UUID, param: String) -> Binding<Double> {
        Binding(
            get: { [weak self] in self?.item(itemId)?.values[param] ?? 0 },
            set: { [weak self] newValue in
                guard let self, let idx = self.collection.firstIndex(where: { $0.id == itemId }) else { return }
                self.collection[idx].values[param] = newValue
            }
        )
    }

    private func chainOrder(of id: UUID) -> Int { item(id)?.category.chainOrder ?? Int.max }

    // MARK: - Persistence

    /// Bumped whenever the shipped catalog changes in a way that retires gear a
    /// saved rig might still be holding. A state file stamped with an older
    /// version is discarded and re-seeded, so nobody is left owning a pedal the
    /// app no longer ships (and has no artwork for).
    ///   1 — original placeholder catalog
    ///   2 — the 47 licensed-art pedals
    static let catalogVersion = 2

    struct PersistedState: Codable {
        var collection: [GearItem]
        var rig: RigConfiguration
        var arSlots: [ARSlot]?
        /// Absent in files written before versioning existed → treated as 1.
        var catalogVersion: Int?
    }

    func save() {
        guard persist else { return }
        Self.write(PersistedState(collection: collection, rig: rig, arSlots: arSlots,
                                  catalogVersion: Self.catalogVersion), to: saveURL)
    }

    private static func stateURL() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("rig_state.json")
    }

    private static func load(from url: URL) -> PersistedState? {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return nil }
        // Stale catalog generation → nil, which makes the caller re-seed.
        guard (state.catalogVersion ?? 1) >= catalogVersion else { return nil }
        return state
    }

    private static func write(_ state: PersistedState, to url: URL) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    // MARK: - Seed

    // `nonisolated` so the `nonisolated` AUv3 unit (StreetRigDSPUnit) can seed its
    // owned default rig from `init` without a main-actor hop — it only builds value
    // types (GearItem / RigConfiguration), touching no `@MainActor` state.
    nonisolated static func seed() -> (collection: [GearItem], rig: RigConfiguration) {
        let guitar   = GearItem(name: "Les Paul Standard", category: .guitar)
        let amp      = GearItem(name: "Marshall JCM800",   category: .amp, values: ["Gain": 0, "Bass": 2, "Mid": 5, "Treble": 5, "Presence": 8, "Master": 10])
        let cab      = GearItem(name: "Marshall 1960A 4x12", category: .cabinet)
        let combo    = GearItem(name: "Fender Deluxe",     category: .comboAmp)
        let tuner    = GearItem(name: "VOSS Chromatic Tuner", category: .tuner)
        let wah      = GearItem(name: "DUNLAP CRY BABY",   category: .wah)
        let comp     = GearItem(name: "MXP dyna comp",     category: .compressor)
        let ts       = GearItem(name: "Ibonez Tube Screamer", category: .overdrive)
        let muff     = GearItem(name: "electro-harmonium BIG MUFF π", category: .overdrive)
        let chorus   = GearItem(name: "VOSS Chorus",       category: .modulation)
        let phaser   = GearItem(name: "MXP phase 90",      category: .modulation)
        let delay    = GearItem(name: "VOSS Digital Delay", category: .delay)
        let reverb   = GearItem(name: "VOSS Reverb",       category: .reverb)
        let looper   = GearItem(name: "VOSS Loop Station", category: .looper)

        let collection = [guitar, amp, cab, combo, tuner, wah, comp, ts, muff, chorus, phaser, delay, reverb, looper]
        let rig = RigConfiguration(
            guitarId: guitar.id,
            ampSection: .stack(ampId: amp.id, cabinetId: cab.id),
            pedalIds: [ts.id, delay.id, reverb.id]
        )
        return (collection, rig)
    }

    // MARK: - Catalog (the full library to add gear from)

    public static let catalog: [GearItem] = {
        func mk(_ name: String, _ category: GearCategory) -> GearItem {
            GearItem(name: name, category: category)
        }
        return [
            // Amp heads
            mk("Marshall JCM800", .amp), mk("Fender Twin Reverb", .amp), mk("Vox AC30", .amp),
            mk("Mesa Dual Rectifier", .amp), mk("Orange Rockerverb", .amp),
            // Cabinets
            mk("Marshall 1960A 4x12", .cabinet), mk("Marshall 1936 2x12", .cabinet), mk("Fender 1x12", .cabinet),
            // Combo amps
            mk("Fender Deluxe", .comboAmp), mk("Vox AC15", .comboAmp),
            // ---- Pedals ------------------------------------------------------
            // The 47 shipped models. Every one has a bespoke icon in
            // Assets.xcassets keyed off `GearIconLoader.slug(name)`, so these
            // names are load-bearing: renaming a pedal orphans its artwork.
            // Within a category the first entry is the one LibraryView shows on
            // that category's card, so it leads with the best-fitting model.

            // Tuner
            mk("VOSS Chromatic Tuner", .tuner),
            // Wah / filter
            mk("DUNLAP CRY BABY", .wah), mk("VOLT V847", .wah), mk("MORLEE BAD HORSIE", .wah),
            // Compressor
            mk("MXP dyna comp", .compressor), mk("VOSS Compression Sustainer", .compressor),
            mk("Keenly Compressor", .compressor),
            // Overdrive / distortion / fuzz / boost (one category in the model)
            mk("VOSS Distortion", .overdrive), mk("Ibonez Tube Screamer", .overdrive),
            mk("ProCon RAT", .overdrive), mk("VOSS Metal Zone", .overdrive),
            mk("Chiron CENTAUR", .overdrive), mk("analogue.man KING of TONE", .overdrive),
            mk("Marswell BLUES BREAKER", .overdrive), mk("Fullstone OCD", .overdrive),
            mk("electro-harmonium BIG MUFF π", .overdrive),
            mk("DALLAS ARBITOR FUZZ FACE", .overdrive), mk("Z.HEX FUZZ FACTORY", .overdrive),
            mk("Exotiq EP booster", .overdrive), mk("strymo IRIDIUM", .overdrive),
            // EQ
            mk("VOSS Equalizer", .eq), mk("MXP ten band eq", .eq), mk("EMPRISS ParaEq", .eq),
            // Noise gate
            mk("VOSS Noise Suppressor", .noiseGate), mk("ITP DECIMATOR II", .noiseGate),
            mk("FORTIS ZUUL", .noiseGate),
            // Modulation (chorus / flanger / phaser / tremolo / vibe)
            mk("VOSS Chorus", .modulation), mk("MXP phase 90", .modulation),
            mk("MXP flanger", .modulation), mk("VOSS Tremolo", .modulation),
            mk("electro-harmonium SMALL CLONE", .modulation),
            mk("electro-harmonium small stone", .modulation),
            mk("electro-harmonium electric mistress", .modulation),
            mk("Fullstone Deja'Vibe", .modulation),
            // Pitch / octave
            mk("VOSS Octave", .pitch), mk("VOSS Harmonist", .pitch),
            mk("electro-harmonium micro POG", .pitch), mk("DigiTek WHAMMY", .pitch),
            // Delay
            mk("VOSS Digital Delay", .delay), mk("DUNLAP ECHOPLEX", .delay),
            mk("electro-harmonium MEMORY MAN", .delay),
            // Reverb
            mk("VOSS Reverb", .reverb), mk("electro-harmonium HOLY GRAIL", .reverb),
            // Volume
            mk("VOSS FV-500H", .volume), mk("ERNIE BELL VP JR", .volume),
            // Looper / sustain
            mk("VOSS Loop Station", .looper), mk("electro-harmonium FREEZE", .looper),
        ]
    }()
}
