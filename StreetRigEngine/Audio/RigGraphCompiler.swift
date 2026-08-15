//
//  RigGraphCompiler.swift
//  StreetRig
//
//  Prompt 003 — the bridge between the VISUAL rig and the TONE engine. Two jobs:
//
//    1. COMPILE: read the current `RigConfiguration` (pedals in signal-chain
//       order → amp → cab, or a combo) and produce an ordered `RigDSPPlan` for
//       the kernel, so the audible chain matches the on-screen chain exactly.
//
//    2. APPLY (two paths, per RealtimeSafety.md):
//       • STRUCTURAL edits (add/remove/reorder a pedal, swap amp/cab, .stack↔
//         .combo, change a clip character) rebuild the chain under the kernel's
//         reconfigure barrier — the render thread fades to silence and PARKS
//         (skips every DSP stage) while the setup thread mutates pedal/cab/amp
//         state, then fades back in. No audio-thread allocation or locks.
//       • CONTINUOUS knob turns push values straight onto the lock-free parameter
//         bus (`SRKernelSetParameter`) — NEVER a rebuild, so a slider drag is
//         heard immediately and de-zippered in the kernel.
//
//  `RigAudioBridge` wires `RigStore` (`store.binding(itemId:param:)` — the SAME
//  binding the CONTROLS tab, zoom knobs and sliders use) reactively to those two
//  paths: `store.$rig` (topology) → structural; `store.$collection` (knob values)
//  → continuous push. It marshals every value change onto the param bus and never
//  touches DSP state directly from the main thread.
//
//  AR FOOTSWITCHES: `store.$arSlots` is the third input. An AR stomp slot is a
//  FOOTSWITCH onto a pedal that is already in the chain — stomping it pushes
//  `SRPedalFieldEnabled` on the continuous bus (a relaxed atomic store the render
//  thread reads next buffer), never a rebuild. `compile` therefore derives each
//  slot's `enabled` from the AR slots on EVERY compile, so a structural rebuild
//  (add / remove / swap a pedal) can't silently re-enable a stomped-off pedal.
//

import Foundation
import Combine

/// Plain, value-typed description of the compiled chain (Sendable so it can be
/// handed to the background reconfigure queue). Produced on the main thread from
/// `RigStore`; consumed by the (thread-agnostic) kernel C ABI.
public struct RigDSPPlan: Sendable, Equatable {
    public struct PedalSlot: Sendable, Equatable {
        public var type: Int          // PedalChain::Type (0 transparent, 1 drive, 2 eq, 3 comp, …)
        public var character: Int     // slot VOICING (drive: soft/hard/fuzz; mod: chorus/…/univibe)
        public var enabled: Bool
        public var params: [Float]    // continuous knobs already in DSP units (Param0…), per family

        public init(type: Int, character: Int, enabled: Bool, params: [Float]) {
            self.type = type; self.character = character; self.enabled = enabled; self.params = params
        }
    }

    public var pedals: [PedalSlot] = []      // in signal-chain order
    public var cabSlot: Int = 0
    public var useNeural: Bool = true
    public var ampBypass: Bool = false
    public var cabBypass: Bool = false

    // Amp continuous params.
    public var ampDrive: Float = 3.0
    public var ampMaster: Float = 1.0
    public var ampBassDB: Float = 0
    public var ampMidDB: Float = 0
    public var ampTrebleDB: Float = 0
    public var ampPresenceDB: Float = 0

    /// Topology-only fingerprint (NOT knob values). A change here means a
    /// structural rebuild; identical signature + changed values = a continuous
    /// push.
    public var signature: String = ""

    public init() {}
}

public enum RigGraphCompiler {

    // MARK: - Compile (main thread — reads the @MainActor RigStore)

    @MainActor
    public static func compile(store: RigStore) -> RigDSPPlan {
        // Thin @MainActor wrapper: pull the value-typed rig out of the store and
        // hand it to the nonisolated core, so there is ONE compile implementation.
        compile(collection: store.collection, rig: store.rig, arSlots: store.arSlots)
    }

    /// Nonisolated compile CORE: turn value-typed rig data (collection + wiring)
    /// into a `RigDSPPlan`, with no dependency on the `@MainActor` `RigStore`. Used
    /// by the AUv3 plugin, which owns a SERIALIZED rig snapshot (resolved gear +
    /// `RigConfiguration`) and has no access to the app's live store. `compile(store:)`
    /// delegates here; the two are behaviourally identical (`store.pedalItems`,
    /// `store.ampItem`, `store.cabinetItem`, `store.isCombo` are all derived from
    /// exactly these two inputs).
    ///
    /// `arSlots` are the app's AR stomp footswitches. They default to EMPTY so a
    /// host-loaded plugin (which has no AR screen — its `PersistedState.arSlots`
    /// is deliberately `nil`) compiles exactly as before: every pedal enabled.
    public static func compile(collection: [GearItem],
                               rig: RigConfiguration,
                               arSlots: [ARSlot] = []) -> RigDSPPlan {
        func item(_ id: UUID) -> GearItem? { collection.first { $0.id == id } }

        /// THE ENABLED-STATE RULE, in one place. A pedal that no AR slot holds is
        /// always enabled (it is simply in the chain). A pedal bound to a slot
        /// follows that slot's `isOn`. Because this is re-derived on every compile,
        /// a structural rebuild triggered by an unrelated edit cannot resurrect a
        /// pedal the player stomped off — nor strand an unbound one in bypass.
        func footswitchEnabled(_ pedalId: UUID) -> Bool {
            guard let slot = arSlots.first(where: { $0.pedalId == pedalId }) else { return true }
            return slot.isOn
        }

        // Amp section (head+cab stack, or a single combo) mirrored from RigStore.
        let ampItem: GearItem?
        let cabinetItem: GearItem?
        let isCombo: Bool
        switch rig.ampSection {
        case .stack(let ampId, let cabinetId):
            ampItem = item(ampId); cabinetItem = item(cabinetId); isCombo = false
        case .combo(let comboId):
            ampItem = item(comboId); cabinetItem = nil; isCombo = true
        }

        var plan = RigDSPPlan()

        // Pedals in signal-chain order (rig.pedalIds is kept chain-sorted by the
        // store; the snapshot preserves that order), capped at the fixed pool.
        for gear in rig.pedalIds.compactMap(item).prefix(Int(SRMaxPedals)) {
            plan.pedals.append(.init(
                type: ParameterMap.pedalType(for: gear.category),
                character: ParameterMap.pedalVoicing(name: gear.name, category: gear.category),
                enabled: footswitchEnabled(gear.id),
                params: ParameterMap.pedalParams(category: gear.category, values: gear.values)
            ))
        }

        // Amp section (head or combo — both expose the same 6 knobs).
        let ampName = ampItem?.name ?? ""
        let v: (String) -> Double = { ampItem?.values[$0] ?? 5 }
        plan.ampDrive       = ParameterMap.ampDrive(gainKnob: v("Gain"))
        plan.ampMaster      = ParameterMap.ampMaster(masterKnob: v("Master"))
        plan.ampBassDB      = ParameterMap.ampBandDB("Bass",     knob: v("Bass"))
        plan.ampMidDB       = ParameterMap.ampBandDB("Mid",      knob: v("Mid"))
        plan.ampTrebleDB    = ParameterMap.ampBandDB("Treble",   knob: v("Treble"))
        plan.ampPresenceDB  = ParameterMap.ampBandDB("Presence", knob: v("Presence"))
        plan.useNeural      = ParameterMap.ampUsesNeural(name: ampName)

        // Cabinet: for a stack the paired cab, for a combo the combo's own box.
        let cabName = isCombo ? ampName : (cabinetItem?.name ?? "")
        plan.cabSlot = ParameterMap.cabSlot(name: cabName)

        // Topology fingerprint — TYPE + VOICING per slot, NOT `enabled`. Enablement
        // rides the continuous bus (`SRPedalFieldEnabled`, pushed by `pushValues`),
        // so a footswitch stomp keeps the signature identical and takes the cheap
        // lock-free path instead of a fade/park rebuild of the whole chain.
        let pedalSig = plan.pedals.map { "\($0.type)/\($0.character)" }.joined(separator: ",")
        plan.signature = "P[\(pedalSig)]|amp:\(plan.useNeural ? "n" : "a")|cab:\(plan.cabSlot)|combo:\(isCombo)"
        return plan
    }

    // MARK: - Apply (nonisolated — kernel C ABI is thread-agnostic)

    /// Set the structural topology: pedal count + per-slot type/character/enable,
    /// cab slot, amp engine + bypasses. Setup-thread work (call immediate when the
    /// render thread is idle, or inside the reconfigure barrier when it is live).
    nonisolated static func applyStructure(_ plan: RigDSPPlan, to dsp: StreetRigDSPUnit) {
        dsp.setActivePedalCount(plan.pedals.count)
        for (i, slot) in plan.pedals.enumerated() {
            dsp.configurePedal(slot: i, type: slot.type, character: slot.character, enabled: slot.enabled)
        }
        dsp.setActiveCabSlot(plan.cabSlot)                                  // re-partitions the convolver
        dsp.setParameter(SRParamAmpUseNeural, value: plan.useNeural ? 1 : 0)
        dsp.setParameter(SRParamAmpBypass,    value: plan.ampBypass ? 1 : 0)
        dsp.setParameter(SRParamCabBypass,    value: plan.cabBypass ? 1 : 0)
    }

    /// Push every CONTINUOUS parameter onto the lock-free bus (no rebuild). Safe
    /// to call from the main thread on a knob move.
    nonisolated static func pushValues(_ plan: RigDSPPlan, to dsp: StreetRigDSPUnit) {
        for (i, slot) in plan.pedals.enumerated() {
            dsp.setPedalParam(slot: i, field: Int(SRPedalFieldEnabled), value: slot.enabled ? 1 : 0)
            // Continuous knobs → generic param fields (Param0 == SRPedalFieldDrive == 3),
            // capped at the slot's stride so a family with many knobs can't overflow.
            let maxParams = Int(SRPedalParamStride) - Int(SRPedalFieldDrive)
            for (j, value) in slot.params.enumerated() where j < maxParams {
                dsp.setPedalParam(slot: i, field: Int(SRPedalFieldDrive) + j, value: value)
            }
        }
        dsp.setParameter(SRParamAmpDrive,    value: plan.ampDrive)
        dsp.setParameter(SRParamAmpMakeup,   value: plan.ampMaster)
        dsp.setParameter(SRParamAmpBass,     value: plan.ampBassDB)
        dsp.setParameter(SRParamAmpMid,      value: plan.ampMidDB)
        dsp.setParameter(SRParamAmpTreble,   value: plan.ampTrebleDB)
        dsp.setParameter(SRParamAmpPresence, value: plan.ampPresenceDB)
    }

    /// Apply a whole plan with NO barrier. Correct when the render thread is not
    /// running (offline harness before `renderOffline`, or initial setup) — there
    /// is no concurrent render to race. Structural mutation + clean state + values.
    nonisolated public static func applyImmediate(_ plan: RigDSPPlan, to dsp: StreetRigDSPUnit) {
        applyStructure(plan, to: dsp)
        dsp.resetChainState()
        pushValues(plan, to: dsp)
    }

    /// Apply a plan while the render thread is LIVE, via the fade/park barrier.
    /// Runs on `queue` (a background serial queue) so the main thread and — above
    /// all — the audio thread never block. Sequence: mute+park → mutate → clean →
    /// unmute(fade-in) → push values.
    nonisolated static func applyHotSwap(_ plan: RigDSPPlan, to dsp: StreetRigDSPUnit, on queue: DispatchQueue) {
        queue.async {
            dsp.beginReconfigure()
            waitUntilParked(dsp, timeoutMs: 60)
            applyStructure(plan, to: dsp)
            dsp.resetChainState()
            dsp.endReconfigure()
            pushValues(plan, to: dsp)
        }
    }

    /// Spin (on a background queue only) until the render thread confirms it is
    /// parked (muted, out of every DSP stage), or the render thread is clearly not
    /// running, or the timeout elapses. NEVER call from the main or audio thread.
    nonisolated static func waitUntilParked(_ dsp: StreetRigDSPUnit, timeoutMs: Int) {
        let deadline = DispatchTime.now() + .milliseconds(timeoutMs)
        let startProcess = dsp.processCallCount
        var idleChecks = 0
        while DispatchTime.now() < deadline {
            if dsp.parkedBufferCount >= 2 { return }          // safely parked
            if dsp.processCallCount == startProcess {         // render not advancing…
                idleChecks += 1
                if idleChecks >= 3 { return }                 // …so nothing is rendering
            } else {
                idleChecks = 0
            }
            usleep(1000)                                       // 1 ms
        }
    }
}

// MARK: - RigStore → param-bus binding glue

/// Subscribes to `RigStore` and keeps the DSP chain in sync with the on-screen
/// rig. Topology (`$rig`) drives structural hot-swaps; knob values (`$collection`,
/// written by `store.binding(itemId:param:)`) and AR footswitch stomps
/// (`$arSlots`) drive continuous param pushes. Lives on the main actor; the only
/// cross-thread work is the background reconfigure queue used by `applyHotSwap`.
@MainActor
public final class RigAudioBridge {
    private weak var store: RigStore?
    private let dsp: StreetRigDSPUnit
    private let isRenderLive: () -> Bool
    private let reconfigureQueue = DispatchQueue(label: "streetrig.rig-reconfigure")
    private var cancellables = Set<AnyCancellable>()
    private var lastSignature = ""
    private var syncScheduled = false

    public init(store: RigStore, dsp: StreetRigDSPUnit, isRenderLive: @escaping () -> Bool) {
        self.store = store
        self.dsp = dsp
        self.isRenderLive = isRenderLive

        // Initial full apply so the engine starts on the current rig.
        let plan = RigGraphCompiler.compile(store: store)
        lastSignature = plan.signature
        applyStructural(plan)

        // Topology changes → structural hot-swap.
        store.$rig
            .dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleSync() } }
            .store(in: &cancellables)

        // Knob / value changes → continuous push (rebuild only if the signature
        // somehow moved). `store.binding(...).set` writes `collection`, landing here.
        store.$collection
            .dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleSync() } }
            .store(in: &cancellables)

        // AR stomp slots → the footswitch's enable/bypass push. Same continuous
        // path as a knob: the compiled signature does not move, so this never
        // rebuilds the chain. Dropping a pedal that is not yet in the rig also
        // mutates `$rig` (RigStore adds it), which takes the structural path above.
        store.$arSlots
            .dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleSync() } }
            .store(in: &cancellables)
    }

    /// Coalesce every store change in this main-actor turn into ONE compile, run
    /// on the NEXT turn.
    ///
    /// Why the hop: `@Published` emits from `willSet`, so inside the sink the
    /// store's property still holds the OLD value — compiling there would apply
    /// the state before the edit and leave the newest change unheard until the
    /// next one arrived. Harmless-looking for a slider drag (the following move
    /// corrects it); fatal for a boolean footswitch, which would then toggle one
    /// stomp behind. Deferring also collapses the "add pedal to the rig + bind the
    /// footswitch" pair into a single rebuild.
    private func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.syncScheduled = false
                self.handleChange()
            }
        }
    }

    private func handleChange() {
        guard let store else { return }
        let plan = RigGraphCompiler.compile(store: store)
        if plan.signature != lastSignature {
            lastSignature = plan.signature
            applyStructural(plan)                       // topology moved → rebuild
        } else {
            RigGraphCompiler.pushValues(plan, to: dsp)  // just knobs → live push
        }
    }

    private func applyStructural(_ plan: RigDSPPlan) {
        if isRenderLive() {
            RigGraphCompiler.applyHotSwap(plan, to: dsp, on: reconfigureQueue)
        } else {
            RigGraphCompiler.applyImmediate(plan, to: dsp)
        }
    }
}
