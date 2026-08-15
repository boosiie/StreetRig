//
//  RigAUParameterBridge.swift
//  StreetRigEngine
//
//  Phase 4 — the TWO-WAY bridge between the plugin editor's on-screen knobs and
//  the host-automatable `AUParameterTree`. It is the AUv3 peer of `RigAudioBridge`
//  (store → kernel): where that one-way bridge pushes knob values straight onto
//  the lock-free kernel bus, THIS bridge keeps the editor's `RigStore` and the
//  unit's `AUParameterTree` in lock-step in BOTH directions, so:
//
//    • UI → host: a knob turn (a write through `store.binding(itemId:param:)`)
//      also sets the matching `AUParameter.value` — the host RECORDS the move as
//      automation. Setting the parameter runs the unit's `implementorValueObserver`
//      (`SRKernelSetParameter`), so the kernel is written EXACTLY ONCE, through the
//      parameter path — never double-written.
//    • host → UI: host automation moves an `AUParameter`; a parameter observer
//      writes the inverse-mapped value back into the `RigStore`, so the on-screen
//      knob animates to follow the host.
//
//  FRESH VALUES, not stale reads. `@Published` delivers the NEW value to sinks in
//  `willSet` — BEFORE the stored property updates — so a sink that re-reads
//  `store.collection` sees the OLD knob. This bridge threads the EMITTED
//  collection/rig through, reading the just-changed value directly.
//
//  FEEDBACK is defeated two ways, both async-safe:
//    1. UI → host writes use `setValue(_:originator:)` with OUR observer token, so
//       the host-→-UI observer is not asked to re-apply our own writes; and because
//       the values are FRESH, even if a host coalesces an echo it re-applies the
//       SAME knob value (a no-op), never a stale one.
//    2. host → UI writes set `applyingHostUpdate` around the (synchronous) store
//       mutation, so the store's `$collection` sink does not push the value back to
//       the parameter.
//
//  The (gear/slot, param) → `AUParameterAddress` MAPPING reuses the exact slot
//  assignment `RigGraphCompiler` uses (chain-ordered pedals → fixed slots 0…7) and
//  `ParameterMap`'s forward curves, so a UI edit and its automation lane hit the
//  SAME kernel address with the SAME value. Structural edits (add/remove/swap gear)
//  go through the unit's proven, defer-safe `applyRig(_:)` barrier path.
//
//  MAIN-ACTOR only; adds NO audio-thread work — RealtimeSafety.md stays intact.
//

import Foundation
import Combine
import AVFoundation
import AudioToolbox
import SwiftUI   // `store.binding(...)` returns a SwiftUI `Binding`

@MainActor
public final class RigAUParameterBridge {

    /// One automatable knob: which stored gear knob it is, the kernel/host address
    /// it drives, and the forward (knob → bus) / inverse (bus → knob) converters.
    private struct ParamLink {
        let itemId: UUID
        let param: String
        let address: AUParameterAddress
        let toBus: (Double) -> AUValue      // 0…10 knob → DSP-bus value (gain/Hz/dB)
        let toKnob: (AUValue) -> Double     // DSP-bus value → 0…10 knob
    }

    private let store: RigStore
    private let dsp: StreetRigDSPUnit
    private var cancellables = Set<AnyCancellable>()

    private var links: [ParamLink] = []
    private var reverse: [AUParameterAddress: ParamLink] = [:]
    private var lastSignature = ""

    private var observerToken: AUParameterObserverToken?
    /// True only while a host→UI write is mutating the store, so the store's own
    /// `$collection` sink does not push the value straight back to the parameter.
    private var applyingHostUpdate = false

    // Diagnostics (read by the headless self-test to localize any wiring gap).
    /// Number of automatable knobs currently mapped (amp + drive-pedal fields).
    public var automatableCount: Int { links.count }
    /// Times the store's `$collection` sink fired (a knob turn was observed).
    public private(set) var continuousSinkCount = 0
    /// Times a host `AUParameter` change was delivered to us (host → UI).
    public private(set) var observerCallbackCount = 0
    /// Last value the observer delivered per address (host → UI insight).
    public private(set) var lastObserved: [UInt64: Float] = [:]
    /// Times a full structural (re)apply ran — should be 1 (init) during knob-only edits.
    public private(set) var applyStructuralCount = 0

    public init(store: RigStore, dsp: StreetRigDSPUnit) {
        self.store = store
        self.dsp = dsp

        // host → UI: observe automation. The block may be called on any thread; hop
        // to the main actor to touch the store. Our own UI→host writes pass
        // `observerToken` as originator, and carry FRESH values, so an echo re-applies
        // the same knob (a no-op) rather than a stale one.
        observerToken = dsp.parameterTree?.token(byAddingParameterObserver: { [weak self] address, value in
            guard let self else { return }
            Task { @MainActor in self.hostDidChangeParameter(address: address, value: value) }
        })

        // Initial full apply: establish the store's rig on the unit (structure +
        // parameter values) and build the address map.
        applyStructural(collection: store.collection, rig: store.rig)

        // Topology (add/remove/swap gear) → structural rebuild, using the EMITTED rig.
        store.$rig
            .dropFirst()
            .sink { [weak self] rig in
                guard let self else { return }
                MainActor.assumeIsolated { self.applyStructural(collection: self.store.collection, rig: rig) }
            }
            .store(in: &cancellables)

        // Knob turns (store.binding writes `collection`) → push the EMITTED
        // collection's values onto the matching AUParameters (record automation +
        // drive the kernel). Reading the emitted value avoids the willSet staleness.
        store.$collection
            .dropFirst()
            .sink { [weak self] collection in
                guard let self else { return }
                MainActor.assumeIsolated { self.handleContinuousChange(collection: collection) }
            }
            .store(in: &cancellables)
    }

    deinit {
        if let token = observerToken {
            dsp.parameterTree?.removeParameterObserver(token)
        }
    }

    // MARK: - Rig resolution (value-typed; never reads the store's stale rig)

    private func resolveAmp(_ collection: [GearItem], _ rig: RigConfiguration) -> GearItem? {
        switch rig.ampSection {
        case .stack(let ampId, _):  return collection.first { $0.id == ampId }
        case .combo(let comboId):   return collection.first { $0.id == comboId }
        }
    }

    private func resolvePedals(_ collection: [GearItem], _ rig: RigConfiguration) -> [GearItem] {
        rig.pedalIds.compactMap { id in collection.first { $0.id == id } }
    }

    // MARK: - Mapping (rebuilt whenever topology changes)

    /// Build the (itemId, param) ⇄ address table from a value-typed rig, mirroring
    /// `RigGraphCompiler`'s slot assignment (chain-ordered pedals capped at the fixed
    /// pool). Only the continuous, kernel-backed knobs are linked: the amp's
    /// Gain/Master + tone stack, and each drive pedal's Drive/Tone/Level.
    private func buildLinks(collection: [GearItem], rig: RigConfiguration) {
        var list: [ParamLink] = []

        if let amp = resolveAmp(collection, rig) {
            let id = amp.id
            list.append(ParamLink(itemId: id, param: "Gain",
                                  address: UInt64(SRParamAmpDrive.rawValue),
                                  toBus: { ParameterMap.ampDrive(gainKnob: $0) },
                                  toKnob: { ParameterMap.invAmpDriveKnob($0) }))
            list.append(ParamLink(itemId: id, param: "Master",
                                  address: UInt64(SRParamAmpMakeup.rawValue),
                                  toBus: { ParameterMap.ampMaster(masterKnob: $0) },
                                  toKnob: { ParameterMap.invAmpMasterKnob($0) }))
            for (name, addr) in [("Bass", SRParamAmpBass), ("Mid", SRParamAmpMid),
                                 ("Treble", SRParamAmpTreble), ("Presence", SRParamAmpPresence)] {
                list.append(ParamLink(itemId: id, param: name,
                                      address: UInt64(addr.rawValue),
                                      toBus: { ParameterMap.ampBandDB(name, knob: $0) },
                                      toKnob: { ParameterMap.invAmpBandKnob(name, dB: $0) }))
            }
        }

        for (slot, pedal) in resolvePedals(collection, rig).prefix(Int(SRMaxPedals)).enumerated()
        where pedal.category == .overdrive {
            let id = pedal.id
            let base = UInt64(SRPedalParamBase) + UInt64(slot) * UInt64(SRPedalParamStride)
            list.append(ParamLink(itemId: id, param: "Drive",
                                  address: base + UInt64(SRPedalFieldDrive),
                                  toBus: { ParameterMap.pedalDrive($0) },
                                  toKnob: { ParameterMap.invPedalDriveKnob($0) }))
            list.append(ParamLink(itemId: id, param: "Tone",
                                  address: base + UInt64(SRPedalFieldTone),
                                  toBus: { ParameterMap.pedalToneHz($0) },
                                  toKnob: { ParameterMap.invPedalToneKnob($0) }))
            list.append(ParamLink(itemId: id, param: "Level",
                                  address: base + UInt64(SRPedalFieldLevel),
                                  toBus: { ParameterMap.pedalLevel($0) },
                                  toKnob: { ParameterMap.invPedalLevelKnob($0) }))
        }

        links = list
        reverse = Dictionary(list.map { ($0.address, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Structural (topology) apply

    /// Rebuild the address map and apply the whole rig (structure + parameter
    /// values) to the unit via its defer-safe barrier path. `applyRig` syncs the
    /// AUParameterTree from the compiled plan, so the tree/kernel start consistent
    /// with the store.
    private func applyStructural(collection: [GearItem], rig: RigConfiguration) {
        applyStructuralCount += 1
        buildLinks(collection: collection, rig: rig)
        lastSignature = RigGraphCompiler.compile(collection: collection, rig: rig).signature
        dsp.applyRig(RigStore.PersistedState(collection: collection, rig: rig, arSlots: nil))
    }

    // MARK: - UI → host (continuous knob turns)

    private func handleContinuousChange(collection: [GearItem]) {
        continuousSinkCount += 1
        guard !applyingHostUpdate else { return }
        // A knob turn keeps the topology fingerprint; if it somehow moved, rebuild.
        let signature = RigGraphCompiler.compile(collection: collection, rig: store.rig).signature
        if signature != lastSignature { applyStructural(collection: collection, rig: store.rig); return }
        pushContinuousToParameters(collection: collection)
    }

    /// Write every linked knob's EMITTED store value onto its `AUParameter` using our
    /// observer token as originator — records host automation and drives the kernel
    /// through `implementorValueObserver` (single write).
    private func pushContinuousToParameters(collection: [GearItem]) {
        guard let tree = dsp.parameterTree, let token = observerToken else { return }
        for link in links {
            let knob = collection.first { $0.id == link.itemId }?.values[link.param] ?? 0
            tree.parameter(withAddress: link.address)?.setValue(link.toBus(knob), originator: token)
        }
    }

    // MARK: - host → UI (automation moves the knob)

    private func hostDidChangeParameter(address: AUParameterAddress, value: AUValue) {
        observerCallbackCount += 1
        lastObserved[address] = value
        guard let link = reverse[address] else { return }
        applyingHostUpdate = true
        store.binding(itemId: link.itemId, param: link.param).wrappedValue = link.toKnob(value)
        applyingHostUpdate = false
    }
}
