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
final class RigStore: ObservableObject {
    @Published var collection: [GearItem]
    @Published var rig: RigConfiguration

    private let saveURL: URL
    private let persist: Bool
    private var cancellables = Set<AnyCancellable>()

    /// `persist: false` keeps everything in memory (used by SwiftUI previews)
    /// so the preview sandbox never touches the filesystem or the autosave loop.
    init(persist: Bool = true) {
        self.persist = persist
        saveURL = Self.stateURL()

        if persist, let loaded = Self.load(from: saveURL) {
            collection = loaded.collection
            rig = loaded.rig
        } else {
            let seed = Self.seed()
            collection = seed.collection
            rig = seed.rig
            if persist {
                // Persist the seed immediately so the first launch is durable.
                Self.write(PersistedState(collection: seed.collection, rig: seed.rig), to: saveURL)
            }
        }

        guard persist else { return }

        // Debounced autosave on any change (covers slider drags, drops, reorders).
        Publishers.CombineLatest($collection, $rig)
            .dropFirst()
            .debounce(for: .seconds(0.4), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &cancellables)
    }

    /// In-memory store for SwiftUI previews (seeded, no disk I/O).
    static var preview: RigStore { RigStore(persist: false) }

    // MARK: - Lookups

    func item(_ id: UUID) -> GearItem? { collection.first { $0.id == id } }

    var guitar: GearItem? { item(rig.guitarId) }

    var ampItem: GearItem? {
        switch rig.ampSection {
        case .stack(let ampId, _): return item(ampId)
        case .combo(let comboId): return item(comboId)
        }
    }

    var cabinetItem: GearItem? {
        if case .stack(_, let cabinetId) = rig.ampSection { return item(cabinetId) }
        return nil
    }

    var isCombo: Bool {
        if case .combo = rig.ampSection { return true }
        return false
    }

    var pedalItems: [GearItem] { rig.pedalIds.compactMap { item($0) } }

    // MARK: - Mutations

    /// Apply a dropped/selected item to the rig, replacing the matching part.
    func apply(_ dropped: GearItem) {
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

    func removePedal(_ id: UUID) {
        rig.pedalIds.removeAll { $0 == id }
    }

    func movePedal(fromOffsets: IndexSet, toOffset: Int) {
        rig.pedalIds.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    /// Whether the owned collection already contains this gear (matched by model).
    func isOwned(_ item: GearItem) -> Bool {
        collection.contains { $0.name == item.name && $0.category == item.category }
    }

    /// Add a copy of a catalog item to the owned collection (fresh id + default knobs).
    func addToCollection(_ item: GearItem) {
        guard !isOwned(item) else { return }
        collection.append(GearItem(name: item.name, category: item.category))
    }

    /// Two-way binding to one knob of one owned item (used by the zoom sliders).
    func binding(itemId: UUID, param: String) -> Binding<Double> {
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

    struct PersistedState: Codable {
        var collection: [GearItem]
        var rig: RigConfiguration
    }

    func save() {
        guard persist else { return }
        Self.write(PersistedState(collection: collection, rig: rig), to: saveURL)
    }

    private static func stateURL() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("rig_state.json")
    }

    private static func load(from url: URL) -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    private static func write(_ state: PersistedState, to url: URL) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    // MARK: - Seed

    static func seed() -> (collection: [GearItem], rig: RigConfiguration) {
        let guitar   = GearItem(name: "Les Paul Standard", category: .guitar)
        let amp      = GearItem(name: "Marshall JCM800",   category: .amp)
        let cab      = GearItem(name: "Marshall 1960A 4x12", category: .cabinet)
        let combo    = GearItem(name: "Fender Deluxe",     category: .comboAmp)
        let tuner    = GearItem(name: "Boss TU-3",         category: .tuner)
        let wah      = GearItem(name: "Cry Baby",          category: .wah)
        let comp     = GearItem(name: "Dyna Comp",         category: .compressor)
        let ts       = GearItem(name: "Tube Screamer",     category: .overdrive)
        let muff     = GearItem(name: "Big Muff",          category: .overdrive)
        let chorus   = GearItem(name: "CE-2 Chorus",       category: .modulation)
        let phaser   = GearItem(name: "Phase 90",          category: .modulation)
        let delay    = GearItem(name: "Carbon Copy",       category: .delay)
        let reverb   = GearItem(name: "Boss RV-6",         category: .reverb)
        let looper   = GearItem(name: "Ditto Looper",      category: .looper)

        let collection = [guitar, amp, cab, combo, tuner, wah, comp, ts, muff, chorus, phaser, delay, reverb, looper]
        let rig = RigConfiguration(
            guitarId: guitar.id,
            ampSection: .stack(ampId: amp.id, cabinetId: cab.id),
            pedalIds: [ts.id, delay.id, reverb.id]
        )
        return (collection, rig)
    }

    // MARK: - Catalog (the full library to add gear from)

    static let catalog: [GearItem] = {
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
            // Tuner
            mk("Boss TU-3", .tuner), mk("TC PolyTune", .tuner),
            // Wah / filter
            mk("Cry Baby", .wah), mk("Vox V846 Wah", .wah),
            // Compressor
            mk("Dyna Comp", .compressor), mk("Keeley Compressor", .compressor),
            // Overdrive / distortion / fuzz / boost
            mk("Tube Screamer", .overdrive), mk("Big Muff", .overdrive), mk("ProCo RAT", .overdrive),
            mk("Klon Centaur", .overdrive), mk("Blues Driver", .overdrive), mk("Fuzz Face", .overdrive),
            // EQ
            mk("MXR 10-Band EQ", .eq), mk("Boss GE-7", .eq),
            // Noise gate
            mk("Boss NS-2", .noiseGate), mk("ISP Decimator", .noiseGate),
            // Modulation (chorus / flanger / phaser / tremolo)
            mk("CE-2 Chorus", .modulation), mk("Phase 90", .modulation),
            mk("MXR Flanger", .modulation), mk("Boss TR-2 Tremolo", .modulation),
            // Pitch / octave
            mk("DigiTech Whammy", .pitch), mk("EHX POG", .pitch),
            // Delay
            mk("Carbon Copy", .delay), mk("Boss DD-8", .delay), mk("Memory Man", .delay),
            // Reverb
            mk("Boss RV-6", .reverb), mk("TC Hall of Fame", .reverb),
            // Volume
            mk("EB Volume", .volume),
            // Looper
            mk("Ditto Looper", .looper), mk("Boss RC-5", .looper),
        ]
    }()
}
