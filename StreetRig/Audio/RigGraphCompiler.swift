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

import Foundation
import Combine

/// Plain, value-typed description of the compiled chain (Sendable so it can be
/// handed to the background reconfigure queue). Produced on the main thread from
/// `RigStore`; consumed by the (thread-agnostic) kernel C ABI.
struct RigDSPPlan: Sendable, Equatable {
    struct PedalSlot: Sendable, Equatable {
        var type: Int          // PedalChain::Type (0 transparent, 1 drive, 2 eq, 3 comp, …)
        var character: Int     // slot VOICING (drive: soft/hard/fuzz; mod: chorus/…/univibe)
        var enabled: Bool
        var params: [Float]    // continuous knobs already in DSP units (Param0…), per family
    }

    var pedals: [PedalSlot] = []      // in signal-chain order
    var cabSlot: Int = 0
    var useNeural: Bool = true
    var ampBypass: Bool = false
    var cabBypass: Bool = false

    // Amp continuous params.
    var ampDrive: Float = 3.0
    var ampMaster: Float = 1.0
    var ampBassDB: Float = 0
    var ampMidDB: Float = 0
    var ampTrebleDB: Float = 0
    var ampPresenceDB: Float = 0

    /// Topology-only fingerprint (NOT knob values). A change here means a
    /// structural rebuild; identical signature + changed values = a continuous
    /// push.
    var signature: String = ""
}

enum RigGraphCompiler {

    // MARK: - Compile (main thread — reads the @MainActor RigStore)

    @MainActor
    static func compile(store: RigStore) -> RigDSPPlan {
        var plan = RigDSPPlan()

        // Pedals in the store's signal-chain order (already sorted by chainOrder),
        // capped at the kernel's fixed slot pool.
        for item in store.pedalItems.prefix(Int(SRMaxPedals)) {
            plan.pedals.append(.init(
                type: ParameterMap.pedalType(for: item.category),
                character: ParameterMap.pedalVoicing(name: item.name, category: item.category),
                enabled: true,
                params: ParameterMap.pedalParams(category: item.category, values: item.values)
            ))
        }

        // Amp section (head or combo — both expose the same 6 knobs).
        let ampItem = store.ampItem
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
        let cabName = store.isCombo ? ampName : (store.cabinetItem?.name ?? "")
        plan.cabSlot = ParameterMap.cabSlot(name: cabName)

        // Topology fingerprint.
        let pedalSig = plan.pedals.map { "\($0.type)/\($0.character)/\($0.enabled ? 1 : 0)" }.joined(separator: ",")
        plan.signature = "P[\(pedalSig)]|amp:\(plan.useNeural ? "n" : "a")|cab:\(plan.cabSlot)|combo:\(store.isCombo)"
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
    nonisolated static func applyImmediate(_ plan: RigDSPPlan, to dsp: StreetRigDSPUnit) {
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
/// written by `store.binding(itemId:param:)`) drive continuous param pushes. Lives
/// on the main actor; the only cross-thread work is the background reconfigure
/// queue used by `applyHotSwap`.
@MainActor
final class RigAudioBridge {
    private weak var store: RigStore?
    private let dsp: StreetRigDSPUnit
    private let isRenderLive: () -> Bool
    private let reconfigureQueue = DispatchQueue(label: "streetrig.rig-reconfigure")
    private var cancellables = Set<AnyCancellable>()
    private var lastSignature = ""

    init(store: RigStore, dsp: StreetRigDSPUnit, isRenderLive: @escaping () -> Bool) {
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
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.handleChange() } }
            .store(in: &cancellables)

        // Knob / value changes → continuous push (rebuild only if the signature
        // somehow moved). `store.binding(...).set` writes `collection`, landing here.
        store.$collection
            .dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.handleChange() } }
            .store(in: &cancellables)
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
