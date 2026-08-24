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

/// What deleting one piece of gear would disturb in the current rig, plus the
/// player-facing copy that describes it.
///
/// The copy lives HERE, derived from the flags, rather than at each call site:
/// the MY GEAR rail, the gear library and the rig stage all delete through
/// `RigStore.removeFromCollection`, and they must not be able to describe the
/// same deletion in three drifting ways. Add a new conflict → add a clause here
/// once and every surface picks it up.
public struct RemovalImpact: Equatable {
    /// The gear's model name, so the copy can lead with it.
    public var name: String
    /// The guitar — fixed, so the drop is rejected instead of confirmed.
    public var isProtected: Bool
    public var isCurrentAmp: Bool
    public var isCurrentCabinet: Bool
    public var isCurrentCombo: Bool
    public var isOnBoard: Bool
    /// 1-based AR footswitch this pedal is bound to, if any.
    public var footswitch: Int?
    /// True when nothing amp-shaped survives this deletion, i.e. the rig ends up
    /// silent. Drives the extra line in the confirmation.
    public var leavesRigWithoutAmp: Bool

    public init(name: String, isProtected: Bool = false,
                isCurrentAmp: Bool = false, isCurrentCabinet: Bool = false,
                isCurrentCombo: Bool = false, isOnBoard: Bool = false,
                footswitch: Int? = nil, leavesRigWithoutAmp: Bool = false) {
        self.name = name
        self.isProtected = isProtected
        self.isCurrentAmp = isCurrentAmp
        self.isCurrentCabinet = isCurrentCabinet
        self.isCurrentCombo = isCurrentCombo
        self.isOnBoard = isOnBoard
        self.footswitch = footswitch
        self.leavesRigWithoutAmp = leavesRigWithoutAmp
    }

    /// Is this gear referenced by the rig the player is using right now?
    public var isInUse: Bool {
        isCurrentAmp || isCurrentCabinet || isCurrentCombo || isOnBoard || footswitch != nil
    }

    /// Only IN-USE gear asks first. Confirming every deletion trains the player
    /// to swat the dialog away, which is exactly when the one that matters gets
    /// waved through — so unused gear goes straight in the bin.
    public var needsConfirmation: Bool { !isProtected && isInUse }

    public var title: String { "Remove \(name)?" }

    /// Names the specific conflict in the player's language, e.g.
    /// "VOSS Digital Delay is on your board and bound to footswitch 2."
    public var message: String {
        var clauses: [String] = []
        if isCurrentAmp     { clauses.append("is your current amp") }
        if isCurrentCabinet { clauses.append("is your current cabinet") }
        if isCurrentCombo   { clauses.append("is your current combo amp") }
        if isOnBoard        { clauses.append("is on your board") }
        if let footswitch   { clauses.append("bound to footswitch \(footswitch)") }

        guard !clauses.isEmpty else {
            return "\(name) will be removed from your gear."
        }
        var sentence = "\(name) \(Self.list(clauses))."
        if leavesRigWithoutAmp {
            // The first of the two no-amp warnings (the stage banner is the
            // second, the Proceed error the third) — said here while the player
            // can still back out.
            sentence += " Removing it leaves your rig with no amp — you won't be able to play until you add one."
        }
        return sentence
    }

    /// "a", "a and b", "a, b and c".
    private static func list(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
    }
}

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

    /// An id deliberately present in no collection — the "nothing here" marker for
    /// a rig slot that has to stay non-optional. All-zeros so it is recognisable on
    /// sight in a saved rig, and STABLE so a saved rig round-trips instead of
    /// growing a fresh meaningless id every time it is written.
    public static let noGear = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// Take the whole amp section off the rig WITHOUT disowning it — what the
    /// stage's drag-off is to an amp, `removePedal` is to a pedal. The head and
    /// its cabinet are one piece on the stage, so they leave together.
    ///
    /// It cannot simply leave the amp's own id in place the way `repairAmpSection`
    /// does: there the gear is being DELETED, so its id stops resolving on its own.
    /// Here the amp stays owned and in the rail, so its id would still resolve and
    /// the rig would still have an amp. Pointing the slot at `noGear` gives the
    /// same end state by the same means — an `ampSection` whose ids name nothing,
    /// which is what "no amp" has always been here (see `hasAmp`).
    public func removeAmpFromRig() {
        rig.ampSection = .stack(ampId: Self.noGear, cabinetId: Self.noGear)
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
        let fresh = GearItem(name: item.name, category: item.category)
        collection.append(fresh)

        // Self-heal the no-amp state. The stage warning tells the player in so
        // many words to "add one from the Gear Library", so doing exactly that
        // has to actually fix it — otherwise the warning sends them somewhere
        // that doesn't work and they're left guessing that a second, separate
        // drag onto the stage is also required. Gated on `!hasAmp`, so it can
        // never hijack the amp in a rig the player has already set up: with an
        // amp in place, adding another still just puts it in the collection.
        if !hasAmp, fresh.category == .amp || fresh.category == .comboAmp {
            apply(fresh)
        }
    }

    /// The owned INSTANCE matching a catalog entry (which carries a throwaway id).
    /// `isOwned` matches by model — name + category — because the catalog and the
    /// collection never share ids; anything that wants to *act* on the owned copy
    /// (i.e. remove it) has to resolve that model back to the real instance first.
    public func ownedInstance(of item: GearItem) -> GearItem? {
        collection.first { $0.name == item.name && $0.category == item.category }
    }

    // MARK: - Removal

    /// Whether this piece of gear may be deleted from the collection at all.
    ///
    /// The guitar is the ONE protected item: the rig's guitar is fixed (see
    /// `apply`, which ignores `.guitar`), so there is no "pick another one"
    /// recovery from deleting it. Everything else — including the last amp — is
    /// deletable; a rig with no amp is a legal, loudly-signposted state (see
    /// `hasAmp`), not something the store forbids.
    /// An unknown id is not removable, which is what makes `removeFromCollection`
    /// idempotent: the second call finds nothing and no-ops.
    public func canRemove(_ id: UUID) -> Bool {
        guard let gear = item(id) else { return false }
        return gear.category != .guitar && id != rig.guitarId
    }

    /// What deleting `id` would disturb in the CURRENT rig. The UI reads this to
    /// decide whether to confirm at all, and gets the confirmation copy from
    /// `RemovalImpact.message` — one definition, so the rail, the library and the
    /// stage can never describe the same deletion differently.
    public func removalImpact(_ id: UUID) -> RemovalImpact {
        let gear = item(id)
        let isGuitar = gear?.category == .guitar || id == rig.guitarId

        var isAmp = false, isCabinet = false, isCombo = false
        switch rig.ampSection {
        case .stack(let ampId, let cabinetId):
            isAmp = ampId == id
            isCabinet = cabinetId == id
        case .combo(let comboId):
            isCombo = comboId == id
        }

        // Slots are stored 0-based but spoken about 1-based ("footswitch 2").
        let slot = arSlots.firstIndex { $0.pedalId == id }.map { $0 + 1 }

        // Would the repair below find a replacement? If neither another head nor
        // a combo survives, this deletion is the one that strands the rig.
        let remaining = collection.filter { $0.id != id }
        let replacementExists = remaining.contains { $0.category == .amp || $0.category == .comboAmp }

        return RemovalImpact(
            name: gear?.name ?? "",
            isProtected: isGuitar,
            isCurrentAmp: isAmp,
            isCurrentCabinet: isCabinet,
            isCurrentCombo: isCombo,
            isOnBoard: rig.pedalIds.contains(id),
            footswitch: slot,
            leavesRigWithoutAmp: (isAmp || isCombo) && !replacementExists
        )
    }

    /// THE destructive entry point — the rail, the gear library and any future
    /// surface all funnel through here, so reference cleanup can't be forgotten
    /// at a call site. Deletes the gear and every reference to it:
    /// board, AR footswitch, amp section. Idempotent; no-ops for the guitar.
    public func removeFromCollection(_ id: UUID) {
        guard canRemove(id) else { return }

        collection.removeAll { $0.id == id }
        // `pedalIds` holds each id at most once and is already in chain order, so
        // dropping one entry preserves both invariants `apply`/`replacePedal` keep.
        rig.pedalIds.removeAll { $0 == id }
        // A footswitch bound to gear that no longer exists would compile into a
        // bypass rule for a pedal the graph can't find (RigGraphCompiler), so the
        // slot is released outright rather than left holding a dead id.
        for i in arSlots.indices where arSlots[i].pedalId == id { arSlots[i] = ARSlot() }
        repairAmpSection(afterRemoving: id)
    }

    /// Point the amp section at something that still exists after `id` was
    /// deleted — or, deliberately, at nothing.
    ///
    /// Called AFTER the item has left `collection`, so "what's left" is simply
    /// what the collection now holds. Preference order is same-category first
    /// (another head for a deleted head, another cabinet for a deleted cabinet),
    /// because that keeps the rig shaped the way the player built it.
    private func repairAmpSection(afterRemoving id: UUID) {
        switch rig.ampSection {
        case .stack(let ampId, let cabinetId):
            guard ampId == id || cabinetId == id else { return }
            // A surviving cabinet is picked up independently of the head: losing
            // the cab shouldn't drag the rig off a head that's still fine.
            let cab = cabinetId == id ? collection.first { $0.category == .cabinet }?.id : cabinetId

            if let head = ampId == id ? collection.first(where: { $0.category == .amp })?.id : ampId {
                rig.ampSection = .stack(ampId: head, cabinetId: cab ?? cabinetId)
            } else if let combo = collection.first(where: { $0.category == .comboAmp })?.id {
                // No head left, but a combo is owned. A combo is a complete amp on
                // its own, so switching the section's SHAPE is better than leaving
                // the player silent next to gear that would work — this is the
                // "fall back to .combo" case called out in the design.
                rig.ampSection = .combo(comboId: combo)
            } else {
                // Nothing amp-shaped survives. DELIBERATE: the dead head id stays
                // put. `ampSection` is non-optional by design and `ampItem`
                // already returns nil for an id that no longer resolves, so a
                // dangling id IS the representation of "no amp" (see `hasAmp`).
                // Do not "fix" this by making ampSection optional — that churns
                // persistence, the AUv3's nonisolated seed path and the compiler
                // to model a state that is already representable.
                rig.ampSection = .stack(ampId: ampId, cabinetId: cab ?? cabinetId)
            }

        case .combo(let comboId):
            guard comboId == id else { return }
            if let other = collection.first(where: { $0.category == .comboAmp })?.id {
                rig.ampSection = .combo(comboId: other)
            } else if let head = collection.first(where: { $0.category == .amp })?.id {
                // Same reasoning in reverse: a head (with a cab if one is owned)
                // beats no amp at all. Without a cabinet the stack points its cab
                // slot at the head, matching how `apply` fills a missing half.
                let cab = collection.first { $0.category == .cabinet }?.id ?? head
                rig.ampSection = .stack(ampId: head, cabinetId: cab)
            }
            // else: the dead combo id stays — again, that IS "no amp".
        }
    }

    /// Does the rig point at an amp that still exists? The single source of truth
    /// for the stage's no-amp warning and the device bar's refusal to engage.
    /// Derived, not stored — see `repairAmpSection` for why "no amp" is modelled
    /// as an unresolvable id rather than an optional.
    public var hasAmp: Bool { ampItem != nil }

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
            get: { [weak self] in
                guard let item = self?.item(itemId) else { return 0 }
                if let stored = item.values[param] { return stored }
                // NO ENTRY MEANS THE CONTROL IS NEWER THAN THE SAVE, not that it
                // is at zero. A rig saved before an amp gained a knob has no key
                // for it, and answering 0 put that knob at its minimum while every
                // other reader — the panel's own dimming, the chain compiler —
                // used the parameter's default. The BE-100 gaining a clean channel
                // is exactly this case.
                return item.parameters.first { $0.name == param }?.defaultValue ?? 0
            },
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
    ///   3 — amps/cabs/combos re-badged to invented brands to match their new
    ///       bespoke art (Marshall JCM800 → Marswell JCM800 2203, …), Twin Reverb
    ///       and AC30 recategorised as combos, and the four art-less amps retired.
    ///       Renaming shipped gear and bumping this are ONE atomic change: the
    ///       icon seam matches on name, so a saved rig left on the old names would
    ///       resolve no asset and show procedural art forever.
    ///
    /// Player-driven removal does NOT bump this: the schema is unchanged (a
    /// deletion is just a shorter `collection` array), and re-seeding would hand
    /// back the very gear the player just threw away.
    static let catalogVersion = 3

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
        let amp      = GearItem(name: "Marswell JCM800 2203", category: .amp, values: ["Gain": 0, "Bass": 2, "Mid": 5, "Treble": 5, "Presence": 8, "Master": 10])
        let cab      = GearItem(name: "Marswell 1960A 4x12", category: .cabinet)
        // Replaces the retired "Fender Deluxe" as the owned starter combo. Picked
        // deliberately: it is the only new combo whose name still routes to the
        // brighter 1x12 cab IR (`ParameterMap.cabSlot` matches "ac30"), so the
        // seeded stack → combo swap keeps audibly changing the cab as before.
        let combo    = GearItem(name: "Volt AC30",         category: .comboAmp)
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
            // ---- Amps, cabinets, combos --------------------------------------
            // Re-badged like the pedals below (Marswell/Fandor/Volt/Tangerine/
            // Mesa Boogey/Rolund/Freedman) so nothing ships under a real
            // trademark, and named so `GearIconLoader.slug(name)` lands exactly
            // on the bespoke imageset — these names are load-bearing.
            //
            // Every entry here has artwork; the four art-less heads that used to
            // sit in this list (Marshall 1936 2x12, Fender 1x12, Fender Deluxe,
            // Vox AC15) are retired rather than left to render the procedural
            // fallback beside thirteen illustrated neighbours.

            // Amp heads (art drawn ~2:1)
            mk("Marswell JCM800 2203", .amp), mk("Marswell Plexi Super Lead 1959", .amp),
            mk("Freedman BE-100", .amp), mk("Mesa Boogey Dual Rectifier", .amp),
            mk("Tangerine Rockerverb 100", .amp),
            // Cabinets (art drawn taller than wide, ~0.86:1)
            mk("Marswell 1960A 4x12", .cabinet), mk("Mesa Boogey Oversized 4x12", .cabinet),
            mk("Tangerine PPC412", .cabinet),
            // Combo amps (art drawn near-square, ~1.13:1). Twin Reverb and AC30
            // used to be catalogued as heads; both are combos in the real world
            // and both are drawn combo-shaped, so they live here now.
            mk("Fandor Twin Reverb", .comboAmp), mk("Volt AC30", .comboAmp),
            mk("Marswell DSL40C", .comboAmp), mk("Rolund JC-120 Jazz Chorus", .comboAmp),
            mk("Fandor Bassman '59", .comboAmp), mk("VOSS Katana 100", .comboAmp),
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
