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

    /// THE THREE-SPAN SPLIT (mirrors `PedalChain::setSplits`). Slots
    /// `[0, splitPre)` run in front of the preamp, `[splitPre, splitPost)` in the
    /// amp's FX loop (after the tone stack, before the power amp) and
    /// `[splitPost, count)` after the cabinet. The defaults put every slot in the
    /// PRE span, which is the behaviour before an FX loop existed — so a rig with
    /// no amp FX compiles to exactly the chain it always did.
    ///
    /// STRUCTURAL: moving a block between spans reorders the graph, so both are
    /// in the topology signature.
    public var splitPre: Int = Int(SRMaxPedals)
    public var splitPost: Int = Int(SRMaxPedals)

    /// Which amp VOICING PROFILE the kernel should install (`streetrig::AmpVoicing`,
    /// mirrored by `ParameterMap.amp*`). STRUCTURAL: it redesigns the preamp
    /// cascade, the tone-stack centres and the power amp, so it belongs in the
    /// signature and travels through the fade/park barrier. 0 = the legacy
    /// voicing, which is also the default, so a plan nobody sets this on behaves
    /// exactly as it did before profiles existed.
    public var ampProfile: Int = ParameterMap.ampLegacy

    // Amp continuous params.
    public var ampDrive: Float = 3.0
    public var ampMaster: Float = 1.0
    public var ampBassDB: Float = 0
    public var ampMidDB: Float = 0
    public var ampTrebleDB: Float = 0
    public var ampPresenceDB: Float = 0
    /// Volume into the power amp (unity) and the power-amp headroom scale
    /// (1.0 = 100 W). Both CONTINUOUS — see the signature note below for why the
    /// power scale in particular must never become structural.
    public var ampVolume: Float = 1.0
    public var ampPower: Float = 1.0

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

        // --- THE THREE SPANS ---------------------------------------------
        // PRE holds the player's own pedalboard (in signal-chain order — the
        // store keeps `rig.pedalIds` sorted, and the snapshot preserves it) plus
        // any of the amp's own input-stage blocks; MID holds the amp's FX loop.
        // Both are assembled first and merged below, because the slot pool is
        // fixed at eight and the split points are just the two boundaries in the
        // merged list.
        var preSlots: [RigDSPPlan.PedalSlot] = []
        var midSlots: [RigDSPPlan.PedalSlot] = []

        for gear in rig.pedalIds.compactMap(item) {
            preSlots.append(.init(
                type: ParameterMap.pedalType(for: gear.category),
                character: ParameterMap.pedalVoicing(name: gear.name, category: gear.category),
                enabled: footswitchEnabled(gear.id),
                params: ParameterMap.pedalParams(category: gear.category, values: gear.values)
            ))
        }

        // Amp section (head or combo). Most amps expose the shared six knobs; a
        // Katana adds Volume, Character, Variation and Power, and a JC-120 drops
        // Presence — so every read needs a default that is right FOR THAT KNOB,
        // not the generic 5. A rig saved before those knobs existed simply has no
        // entry for them, and `values` is `[String: Double]`, so the defaults
        // below are the whole of the migration.
        let ampName = ampItem?.name ?? ""
        let vals = ampItem?.values ?? [:]
        let v: (String) -> Double = { vals[$0] ?? 5 }
        /// Index-valued selectors are NOT dials: 5 would be a nonsense default.
        let idx: (String, Double) -> Double = { vals[$0] ?? $1 }
        plan.ampDrive       = ParameterMap.ampDrive(gainKnob: v("Gain"))
        plan.ampMaster      = ParameterMap.ampMaster(masterKnob: v("Master"))
        plan.ampBassDB      = ParameterMap.ampBandDB("Bass",     knob: v("Bass"))
        plan.ampMidDB       = ParameterMap.ampBandDB("Mid",      knob: v("Mid"))
        plan.ampTrebleDB    = ParameterMap.ampBandDB("Treble",   knob: v("Treble"))
        plan.ampPresenceDB  = ParameterMap.ampBandDB("Presence", knob: v("Presence"))
        plan.ampVolume      = ParameterMap.ampVolume(volumeKnob: v("Volume"))
        // PINNED TO FULL POWER. The wattage selector is gone from the panel (see
        // Gear.swift for why), and this is read from the profile rather than from
        // the item's values ON PURPOSE: a rig saved while the selector existed
        // still carries "Power": 0, and honouring it would leave that player stuck
        // at half a watt with no control to undo it.
        plan.ampPower       = ParameterMap.ampPowerScale(powerIndex: 2)   // 2 = 100 W
        plan.ampProfile     = ParameterMap.ampProfile(name: ampName, values: vals)
        plan.useNeural      = ParameterMap.ampUsesNeural(name: ampName)

        // Cabinet: for a stack the paired cab, for a combo the combo's own box.
        // A profiled amp brings its own pairing; an unprofiled one still matches
        // on the cabinet's name, exactly as before.
        let cabName = isCombo ? ampName : (cabinetItem?.name ?? "")
        plan.cabSlot = ParameterMap.ampProfileCabSlot(plan.ampProfile)
            ?? ParameterMap.cabSlot(name: cabName)
        // The Katana's ACOUSTIC character has no speaker in the model at all.
        if ParameterMap.ampProfileBypassesCab(plan.ampProfile) { plan.cabBypass = true }

        // --- The amp's own FX section (the Katana's five blocks) -----------
        // These are NOT a private effect inside the amp: each resolves to the
        // same PedalChain type and voicing a standalone pedal would, and each
        // lands in the span its real position dictates — Booster and Mod in
        // front of the preamp so a boost drives the character, FX/Delay/Reverb
        // in the loop so their tails go THROUGH the power amp.
        for fx in ParameterMap.ampFXSlots(name: ampName, values: vals) {
            let slot = RigDSPPlan.PedalSlot(type: fx.type, character: fx.voicing,
                                            enabled: fx.enabled, params: fx.params)
            switch fx.span {
            case .pre: preSlots.append(slot)
            case .mid: midSlots.append(slot)
            }
        }

        // THE SLOT BUDGET. Eight slots, and a full pedalboard plus a fully
        // loaded FX panel can ask for more. The player's own board wins — it is
        // the thing on screen — and the amp's blocks fill whatever is left, in
        // panel order. Anything past eight is dropped rather than silently
        // reordered, and the drop is deterministic so it can be explained.
        let capacity = Int(SRMaxPedals)
        let pre = Array(preSlots.prefix(capacity))
        let mid = Array(midSlots.prefix(max(0, capacity - pre.count)))
        plan.pedals = pre + mid
        plan.splitPre = pre.count
        plan.splitPost = pre.count + mid.count

        // Topology fingerprint — TYPE + VOICING per slot, NOT `enabled`. Enablement
        // rides the continuous bus (`SRPedalFieldEnabled`, pushed by `pushValues`),
        // so a footswitch stomp keeps the signature identical and takes the cheap
        // lock-free path instead of a fade/park rebuild of the whole chain.
        //
        // `ampProfile` joins it because a profile change redesigns filters, which
        // cannot be interpolated: Character and Variation are 5- and 2-position
        // selectors nobody sweeps, and they are already folded into the profile id.
        // `ampPower` deliberately does NOT join it — if the power scale entered
        // the signature, flipping the power switch would fade the amp to silence,
        // park the render thread, rebuild and fade back in: a ~60 ms dropout in
        // place of a 5 ms glide, on a control the hardware switches silently.
        //
        // `split` joins it because moving a block between spans REORDERS the
        // graph — a reverb in front of the preamp is a different circuit from
        // the same reverb in the loop, not the same circuit at a different
        // setting. A block's on/off deliberately stays OUT, for the same reason
        // `enabled` does: it must take the cheap continuous path.
        let pedalSig = plan.pedals.map { "\($0.type)/\($0.character)" }.joined(separator: ",")
        plan.signature = "P[\(pedalSig)]|split:\(plan.splitPre)/\(plan.splitPost)"
            + "|amp:\(plan.ampProfile)/\(plan.useNeural ? "n" : "a")"
            + "|cab:\(plan.cabSlot)\(plan.cabBypass ? "x" : "")|combo:\(isCombo)"
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
        // WHERE each slot runs, not just what it is. Set after the slots are
        // configured and before anything renders, so a block never processes one
        // buffer in the wrong span.
        dsp.setPedalSplits(pre: plan.splitPre, post: plan.splitPost)
        dsp.configureAmp(profile: plan.ampProfile)                          // re-designs the amp's filters
        dsp.setActiveCabSlot(plan.cabSlot)                                  // re-partitions the convolver
        dsp.setParameter(SRParamAmpUseNeural, value: plan.useNeural ? 1 : 0)
        dsp.setParameter(SRParamAmpBypass,    value: plan.ampBypass ? 1 : 0)
        dsp.setParameter(SRParamCabBypass,    value: plan.cabBypass ? 1 : 0)
    }

    /// Push every CONTINUOUS parameter onto the lock-free bus (no rebuild). Safe
    /// to call from the main thread on a knob move.
    nonisolated public static func pushValues(_ plan: RigDSPPlan, to dsp: StreetRigDSPUnit) {
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
        dsp.setParameter(SRParamAmpVolume,   value: plan.ampVolume)
        dsp.setParameter(SRParamAmpPower,    value: plan.ampPower)
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

    /// WHAT THE ENGINE WAS ACTUALLY TOLD, every time the topology moves.
    ///
    /// Two things have now been reported that the offline suite cannot reproduce
    /// — "every amp sounds exactly the same" and effects "crossing over" between
    /// blocks — and both are questions about what the chain IS at that moment on
    /// that device. Measuring harder off-device has produced two wrong theories;
    /// this prints the answer instead. Structural rebuilds only, so it is a line
    /// per topology change and never per knob turn.
    private func logChain(_ plan: RigDSPPlan) {
        let slots = plan.pedals.enumerated().map { i, s in
            let span = i < plan.splitPre ? "PRE" : (i < plan.splitPost ? "MID" : "POST")
            return "[\(i) \(span) t\(s.type)/v\(s.character)\(s.enabled ? "" : " OFF")]"
        }.joined(separator: " ")
        print("[StreetRigChain] amp=\(plan.ampProfile) cab=\(plan.cabSlot)"
              + " slots=\(plan.pedals.count)/\(SRMaxPedals)"
              + " split=\(plan.splitPre)/\(plan.splitPost) \(slots)")
    }

    private func applyStructural(_ plan: RigDSPPlan) {
        logChain(plan)
        if isRenderLive() {
            RigGraphCompiler.applyHotSwap(plan, to: dsp, on: reconfigureQueue)
        } else {
            RigGraphCompiler.applyImmediate(plan, to: dsp)
        }
    }
}
