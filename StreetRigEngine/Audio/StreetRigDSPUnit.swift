//
//  StreetRigDSPUnit.swift
//  StreetRig
//
//  The custom AUAudioUnit (v3) that is the DSP INSERTION POINT of the whole
//  amp-sim. It hosts the C++ real-time core (StreetRigDSPKernel) and today does
//  unity-gain passthrough with two ramped gain parameters + a hard bypass. The
//  audio-thread render block lives here; the actual per-sample math lives in the
//  C++ kernel so prompt 002 (neural amp + cab IR) and prompt 003 (pedal/EQ
//  chain) drop their DSP into `SRKernelProcess` without reworking this host.
//
//  ISOLATION: this class is `nonisolated` on purpose. The project builds with
//  SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, but `internalRenderBlock`,
//  `allocateRenderResources`, and the bus accessors are called by the audio
//  system OFF the main actor — so nothing here may be main-actor isolated.
//  See RealtimeSafety.md for the render-thread contract.
//

import Foundation
import AVFoundation
import AudioToolbox
import CoreAudioKit

public nonisolated final class StreetRigDSPUnit: AUAudioUnit {

    // MARK: - Component identity / in-process registration

    /// `aufx`/`srds`/`Strg` — the CANONICAL, PUBLIC effect identity. This is what
    /// the AUv3 appex advertises in its Info.plist `AudioComponents` and what a
    /// host / `AVAudioUnitComponentManager` discovery matches on. Keep these codes
    /// stable forever — changing them orphans saved host automation/presets (§8).
    public static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: fourCharCode("srds"),
        componentManufacturer: fourCharCode("Strg"),
        componentFlags: 0,
        componentFlagsMask: 0
    )

    /// `aufx`/`srdi`/`Strg` — an APP-PRIVATE, IN-PROCESS registration handle used
    /// ONLY by the standalone app to instantiate the DSP unit inside its OWN
    /// process. It deliberately uses a different subtype (`srdi` = "internal")
    /// from the public `srds`, because once the AUv3 appex is installed the OS
    /// treats `srds` as an extension-backed v3 AU and — on iOS, whose default is
    /// out-of-process and which offers NO `.loadInProcess` option (that flag is
    /// macOS-only) — `AVAudioUnit.instantiate(with: srds, options: [])` resolves
    /// to (and loads) the app's OWN appex out-of-process, breaking the in-process
    /// hosting the standalone app depends on (its `auAudioUnit as? StreetRigDSPUnit`
    /// cast would fail). Registering + instantiating a DISTINCT in-process
    /// component is the portable §8 fix: no extension advertises `srdi`, so it
    /// always resolves locally. Hosts never see this triple.
    public static let inProcessComponentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: fourCharCode("srdi"),
        componentManufacturer: fourCharCode("Strg"),
        componentFlags: 0,
        componentFlagsMask: 0
    )

    /// Register the subclass exactly once under the IN-PROCESS handle so the app's
    /// `AVAudioUnit.instantiate(with: inProcessComponentDescription, …)` finds it
    /// locally and never loads the out-of-process appex.
    private static let registration: Void = {
        AUAudioUnit.registerSubclass(StreetRigDSPUnit.self,
                                     as: inProcessComponentDescription,
                                     name: "StreetRig DSP",
                                     version: 1)
    }()
    public static func registerIfNeeded() { _ = registration }

    // MARK: - Kernel + buses + parameters

    private let kernel: SRKernelRef = SRKernelCreate()

    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    private let _parameterTree: AUParameterTree
    let inputGainParameter: AUParameter
    let outputLevelParameter: AUParameter
    // Prompt 002 amp/cab parameters (step 3 binds these to per-amp knobs).
    let ampDriveParameter: AUParameter
    let ampMakeupParameter: AUParameter
    let ampBypassParameter: AUParameter
    let cabBypassParameter: AUParameter
    let useNeuralParameter: AUParameter
    let cabSelectParameter: AUParameter
    // Phase 3 — amp passive tone-stack EQ (addresses 8–11, already on the kernel
    // bus via `processor.setToneBandDB`). dB domain, 0 = flat.
    let ampBassParameter: AUParameter
    let ampMidParameter: AUParameter
    let ampTrebleParameter: AUParameter
    let ampPresenceParameter: AUParameter
    // Per-amp voicing — the only two new addresses (12, 13). The voicing PROFILE
    // itself is structural and travels in the serialized rig, not here.
    let ampVolumeParameter: AUParameter
    let ampPowerParameter: AUParameter

    // Phase 3 — the OWNED structural rig, serialized in `fullState` and rebuilt on
    // restore / preset select. Default = `RigStore.seed()`. It is NOT applied to
    // the kernel by default (`structuralApplyPending` stays false), so an untouched
    // unit's render path is byte-for-byte identical to Phase 2 (no active pedals) —
    // the offline-render A/B passes + impulse self-test rely on that clean default.
    private var ownedSnapshot: RigStore.PersistedState
    private var ownedPlan: RigDSPPlan
    private var ownedRigData: Data
    /// Set when a rig / preset / `fullState` is applied while render resources do
    /// not yet exist; the pending STRUCTURE is applied in `allocateRenderResources`
    /// (kernel prepared, render not yet live → the no-barrier path is correct).
    private var structuralApplyPending = false
    private let reconfigureQueue = DispatchQueue(label: "streetrig.auv3.reconfigure")
    private var _currentPreset: AUAudioUnitPreset?

    /// Loaded once, off the audio thread, in `allocateRenderResources`.
    private var didLoadToneAssets = false

    /// Backing storage the engine pulls upstream audio into. Allocated in
    /// `allocateRenderResources`; it keeps the channel storage alive while the
    /// render block reads the raw pointers stashed in `renderStatePtr`.
    private var inputBuffer: AVAudioPCMBuffer?

    /// STABLE render context. Allocated once in `init` and populated in
    /// `allocateRenderResources`. The render block captures ONLY this pointer and
    /// reads the *current* state each render. This is what makes correctness
    /// independent of WHEN the host reads `internalRenderBlock` — AVAudioEngine
    /// reads it several times BEFORE `allocateRenderResources`, so a block that
    /// captured `inputBuffer` at getter-eval time would be permanently wired to
    /// nil. Reading through a stable pointer sidesteps that entirely.
    private let renderStatePtr: UnsafeMutablePointer<StreetRigRenderState>

    /// mach time → seconds, captured once so the render block does no lookups.
    private var secondsPerTick: Double = 0

    /// Stream sample rate, refreshed in `allocateRenderResources` and captured
    /// by the render block to turn frame counts into the deadline in seconds.
    private var renderSampleRate: Double = 48_000

    // Phase 3 — the CONTINUOUS pedal fields exposed as host-automatable params, one
    // group per fixed slot. Type / Character are STRUCTURAL (gear identity) and are
    // carried in serialized state (§5.C), NOT exposed here. Value domains are
    // bus-matched to `ParameterMap` (drive/level linear, tone in Hz) so a host
    // automation write equals a compiler write at the same address.
    private struct PedalFieldSpec {
        let field: Int; let id: String; let name: String
        let min: AUValue; let max: AUValue; let unit: AudioUnitParameterUnit; let def: AUValue
    }
    //
    // THE DOMAINS ARE GENERIC, and had to become so. A slot is a POOL position,
    // not a pedal: the same address is a drive pedal's pre-gain in one rig and a
    // delay's time in milliseconds in the next. The original three fields were
    // typed for the only family that existed then (`.linearGain` 0.8…25.6,
    // `.hertz` 700…8500, `.linearGain` 0.1…2.0), which silently CLAMPED every
    // other family that reached the tree — a 226 ms delay time arrived at the
    // kernel as 25.6, and an EQ's −12 dB as +0.8. Widening the range and
    // dropping the unit fixes that for every family at once. Widening is safe
    // for already-saved host sessions in exactly the sense Phase A used for
    // `cabSelect`: every previously stored value is still inside the new range,
    // and the address, identifier and ordering are untouched.
    private static let exposedPedalFields: [PedalFieldSpec] = [
        .init(field: Int(SRPedalFieldEnabled), id: "enabled", name: "Enabled",
              min: 0, max: 1, unit: .boolean, def: 1),                     // per-slot bypass
        // Param0 — drive 0.8…25.6 · delay time 40…1280 ms · EQ low ±12 dB ·
        //          gate threshold −70…−20 dB · mod rate 0.1…6.4 Hz · reverb decay
        .init(field: Int(SRPedalFieldDrive), id: "drive", name: "Drive",
              min: -70, max: 1300, unit: .generic, def: 4.53),             // ParameterMap.pedalDrive(0…10)
        // Param1 — tone 700…8500 Hz · delay feedback 0…0.95 · reverb tone to 12 kHz
        .init(field: Int(SRPedalFieldTone), id: "tone", name: "Tone",
              min: -12, max: 12000, unit: .generic, def: 2437.5),          // ParameterMap.pedalToneHz(0…10)
        // Param2 — level 0.1…2.0 · delay/reverb mix 0…0.8 · EQ high ±12 dB
        .init(field: Int(SRPedalFieldLevel), id: "level", name: "Level",
              min: -12, max: 12, unit: .generic, def: 1.05),               // ParameterMap.pedalLevel(0…10)
        // The two fields the time-based blocks needed. Their ADDRESSES were
        // already reserved by `SRPedalParamStride = 8`, so nothing moves and
        // every persisted host automation lane still resolves — the tree simply
        // grows from 44 parameters to 62. Delay is the only family that reads
        // them today, hence the labels. Param3 accepts 0, which is the "use the
        // circuit's own corner" sentinel a pedal with no Tone knob sends.
        .init(field: Int(SRPedalFieldParam3), id: "param3", name: "Delay Tone",
              min: 0, max: 12000, unit: .generic, def: 0),                 // ParameterMap.delayToneHz(0…10)
        .init(field: Int(SRPedalFieldParam4), id: "param4", name: "Mod Depth",
              min: 0, max: 1, unit: .generic, def: 0),                     // ParameterMap.delayModDepth(0…10)
    ]

    // MARK: - Init

    // `public` so the AUv3 appex factory (StreetRigAUFactory, a separate module)
    // can construct the unit across the framework boundary in `createAudioUnit`.
    // The app still instantiates in-process via `AVAudioUnit.instantiate`.
    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {

        // Parameters: two linear gain stages, both unity by default so the
        // untouched graph is a bit-exact passthrough (the null test depends on
        // this). `.flag_CanRamp` lets the kernel de-zipper knob moves.
        let inputGain = AUParameterTree.createParameter(
            withIdentifier: "inputGain", name: "Input Gain",
            address: AUParameterAddress(SRParamInputGain.rawValue),
            min: 0.0, max: 4.0, unit: .linearGain, unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable, .flag_CanRamp],
            valueStrings: nil, dependentParameters: nil)
        // Ceiling raised to 128.0 (+42 dB) — measured, not guessed: a guitar at
        // mic level lands near −42 dBFS and the rig has to make up the difference
        // before anything is audible. Safe to hand over that much because the
        // kernel's output stage now ends in a soft ceiling, so the far end of the
        // fader saturates like a pushed power amp instead of shattering on the
        // converter. Was 4.0 (+12 dB): a rig monitored
        // through a phone speaker, out of a `.measurement` session that gives up
        // level to keep the DI clean, runs out of fader long before it runs out
        // of room. NOTE for the plugin: a parameter's range is part of its public
        // face, so a host automation curve written against the old maximum reads
        // 4x hotter now — pre-release, and worth one rescale.
        let outputLevel = AUParameterTree.createParameter(
            withIdentifier: "outputLevel", name: "Output Level",
            address: AUParameterAddress(SRParamOutputLevel.rawValue),
            min: 0.0, max: 128.0, unit: .linearGain, unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable, .flag_CanRamp],
            valueStrings: nil, dependentParameters: nil)
        inputGain.value = 1.0
        outputLevel.value = 1.0

        // --- Amp / cab parameters (addresses match SRParameterAddress) ---
        let ampDrive = AUParameterTree.createParameter(
            withIdentifier: "ampDrive", name: "Amp Drive",
            address: AUParameterAddress(SRParamAmpDrive.rawValue),
            min: 0.1, max: 10.0, unit: .linearGain, unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable, .flag_CanRamp],
            valueStrings: nil, dependentParameters: nil)
        let ampMakeup = AUParameterTree.createParameter(
            withIdentifier: "ampMakeup", name: "Amp Makeup",
            address: AUParameterAddress(SRParamAmpMakeup.rawValue),
            min: 0.0, max: 4.0, unit: .linearGain, unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable, .flag_CanRamp],
            valueStrings: nil, dependentParameters: nil)
        let ampBypass = AUParameterTree.createParameter(
            withIdentifier: "ampBypass", name: "Amp Bypass",
            address: AUParameterAddress(SRParamAmpBypass.rawValue),
            min: 0.0, max: 1.0, unit: .boolean, unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable], valueStrings: nil, dependentParameters: nil)
        let cabBypass = AUParameterTree.createParameter(
            withIdentifier: "cabBypass", name: "Cab Bypass",
            address: AUParameterAddress(SRParamCabBypass.rawValue),
            min: 0.0, max: 1.0, unit: .boolean, unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable], valueStrings: nil, dependentParameters: nil)
        let useNeural = AUParameterTree.createParameter(
            withIdentifier: "useNeural", name: "Use Neural Amp",
            address: AUParameterAddress(SRParamAmpUseNeural.rawValue),
            min: 0.0, max: 1.0, unit: .boolean, unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable], valueStrings: nil, dependentParameters: nil)
        // 0…7 since the engine grew to 8 cab slots. WIDENING a max is safe for
        // already-saved host sessions — every previously stored value 0–3 is
        // still in range; narrowing one would not be.
        let cabSelect = AUParameterTree.createParameter(
            withIdentifier: "cabSelect", name: "Cab Select",
            address: AUParameterAddress(SRParamCabSelect.rawValue),
            min: 0.0, max: 7.0, unit: .indexed, unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable], valueStrings: nil, dependentParameters: nil)
        // Defaults: amp + cab engaged, prefer the neural capture when one loads
        // (the kernel auto-falls back to the analog amp if none is available).
        ampDrive.value = 3.0
        ampMakeup.value = 1.0
        ampBypass.value = 0.0
        cabBypass.value = 0.0
        useNeural.value = 1.0
        cabSelect.value = 0.0

        // --- Phase 3: amp tone-stack EQ (dB; 0 = flat). Addresses 8–11 are already
        //     on the kernel bus (`processor.setToneBandDB`). Bus-matched domains
        //     from `ParameterMap.ampBandDB`: ±12 dB Bass/Mid/Treble, ±9 dB Presence.
        func makeEQ(_ id: String, _ name: String, _ addr: SRParameterAddress, _ range: AUValue) -> AUParameter {
            let p = AUParameterTree.createParameter(
                withIdentifier: id, name: name, address: AUParameterAddress(addr.rawValue),
                min: -range, max: range, unit: .decibels, unitName: nil,
                flags: [.flag_IsReadable, .flag_IsWritable, .flag_CanRamp],
                valueStrings: nil, dependentParameters: nil)
            p.value = 0.0
            return p
        }
        let ampBass     = makeEQ("ampBass",     "Amp Bass",     SRParamAmpBass,     12)
        let ampMid      = makeEQ("ampMid",      "Amp Mid",      SRParamAmpMid,      12)
        let ampTreble   = makeEQ("ampTreble",   "Amp Treble",   SRParamAmpTreble,   12)
        let ampPresence = makeEQ("ampPresence", "Amp Presence", SRParamAmpPresence,  9)

        // --- Per-amp voicing: Volume (into the power amp) and the power-amp
        //     headroom scale. Appended at addresses 12/13; every existing address
        //     is untouched, so persisted automation still resolves. The scale is a
        //     ramping linear gain rather than an indexed switch on purpose — the
        //     kernel de-zippers it, which is what makes the power control glide.
        let ampVolume = AUParameterTree.createParameter(
            withIdentifier: "ampVolume", name: "Amp Volume",
            address: AUParameterAddress(SRParamAmpVolume.rawValue),
            min: 0.0, max: 4.0, unit: .linearGain, unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable, .flag_CanRamp],
            valueStrings: nil, dependentParameters: nil)
        let ampPower = AUParameterTree.createParameter(
            withIdentifier: "ampPower", name: "Amp Power",
            address: AUParameterAddress(SRParamAmpPower.rawValue),
            min: 0.05, max: 1.0, unit: .linearGain, unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable, .flag_CanRamp],
            valueStrings: nil, dependentParameters: nil)
        ampVolume.value = 1.0      // unity: no change for any amp without a Volume knob
        ampPower.value = 1.0       // 100 W

        // --- Phase 3: fixed 8×4 pedal grid. For each of the kernel's 8 fixed slots
        //     expose ONLY the continuous fields {Enabled, Drive, Tone, Level} at the
        //     structured addresses `SRPedalParamBase + slot*stride + field`. Present
        //     even for empty slots (inert — the render thread only walks the active
        //     count). Type / Character are structural → serialized state, not here.
        var pedalGroups: [AUParameterGroup] = []
        for slot in 0..<Int(SRMaxPedals) {
            var children: [AUParameter] = []
            for f in Self.exposedPedalFields {
                let address = AUParameterAddress(UInt64(SRPedalParamBase)
                    + UInt64(slot) * UInt64(SRPedalParamStride) + UInt64(f.field))
                var flags: AudioUnitParameterOptions = [.flag_IsReadable, .flag_IsWritable]
                if f.unit != .boolean { flags.insert(.flag_CanRamp) }
                let p = AUParameterTree.createParameter(
                    withIdentifier: "slot\(slot)_\(f.id)", name: "Slot \(slot + 1) \(f.name)",
                    address: address, min: f.min, max: f.max, unit: f.unit, unitName: nil,
                    flags: flags, valueStrings: nil, dependentParameters: nil)
                p.value = f.def
                children.append(p)
            }
            pedalGroups.append(AUParameterTree.createGroup(
                withIdentifier: "slot\(slot)", name: "Slot \(slot + 1)", children: children))
        }

        // Grouped fixed superset: one Amp/global group (the 8 legacy params + the
        // four EQ bands) and eight pedal-slot groups. Addresses are unchanged /
        // append-only, so persisted host automation always resolves.
        let ampGroup = AUParameterTree.createGroup(withIdentifier: "amp", name: "Amp", children: [
            inputGain, outputLevel, ampDrive, ampMakeup, ampBypass, cabBypass, useNeural, cabSelect,
            ampBass, ampMid, ampTreble, ampPresence, ampVolume, ampPower,
        ])

        self.inputGainParameter = inputGain
        self.outputLevelParameter = outputLevel
        self.ampDriveParameter = ampDrive
        self.ampMakeupParameter = ampMakeup
        self.ampBypassParameter = ampBypass
        self.cabBypassParameter = cabBypass
        self.useNeuralParameter = useNeural
        self.cabSelectParameter = cabSelect
        self.ampBassParameter = ampBass
        self.ampMidParameter = ampMid
        self.ampTrebleParameter = ampTreble
        self.ampPresenceParameter = ampPresence
        self.ampVolumeParameter = ampVolume
        self.ampPowerParameter = ampPower
        self._parameterTree = AUParameterTree.createTree(withChildren: [ampGroup] + pedalGroups)

        // Own the plugin's default rig for serialization. The plugin boots to a CLEAN
        // default — the seed amp + cab, but NO pedals — so a freshly-inserted StreetRig in
        // a host sounds like a bare amp until the user adds pedals. A real host (like the
        // out-of-process load) round-trips `fullState`, which DOES apply this owned rig, so
        // "clean" must live in the owned rig itself — not only in the deferred
        // `structuralApplyPending` flag. `RigStore.seed()` is unchanged, so the STANDALONE
        // app still starts on the full seed rig; only the plugin's default is cleared here.
        // The full catalog stays in the snapshot collection so the editor/presets can add gear.
        let seed = RigStore.seed()
        var defaultRig = seed.rig
        defaultRig.pedalIds = []
        let seedState = RigStore.PersistedState(collection: seed.collection, rig: defaultRig, arSlots: nil)
        self.ownedSnapshot = seedState
        self.ownedPlan = RigGraphCompiler.compile(collection: seed.collection, rig: defaultRig)
        self.ownedRigData = (try? JSONEncoder().encode(seedState)) ?? Data()

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        self.secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1.0e9

        // Allocate the stable render context up front so `internalRenderBlock`
        // can be read (and cached by the host) before render resources exist.
        renderStatePtr = .allocate(capacity: 1)
        renderStatePtr.initialize(to: StreetRigRenderState(
            kernel: kernel, inputABL: nil, channelData: nil,
            channelCount: 0, sampleRate: 48_000,
            secondsPerTick: self.secondsPerTick, ready: 0))

        try super.init(componentDescription: componentDescription, options: options)

        // Buses default to stereo 48k float; the engine overrides the format at
        // connect time and we re-read it in `allocateRenderResources`.
        let defaultFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input,
                                            busses: [try AUAudioUnitBus(format: defaultFormat)])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output,
                                             busses: [try AUAudioUnitBus(format: defaultFormat)])

        // Lock-free parameter bus: UI edits (main thread) push targets into the
        // kernel; the render thread reads + ramps them. Capture only the raw
        // kernel pointer so these blocks never do ARC on the kernel.
        let k = kernel
        _parameterTree.implementorValueObserver = { param, value in
            SRKernelSetParameter(k, param.address, value)
        }
        // NO implementorValueProvider (Phase 4): the tree reports its own cached
        // value — the standard AUv3 pattern when the DSP only RAMPS toward the set
        // target and never changes a parameter on its own. The Phase-3
        // `SRKernelGetParameter` readback only tracks the gain atomics (it returns 0
        // for the amp EQ 8–11 and the pedal range 100+), so routing `.value` through
        // it would make those parameters read back — and be OBSERVED — as 0, which
        // breaks host automation display and the two-way editor bridge (host→UI). The
        // kernel still receives every value via the observer above (audio changes);
        // this only fixes what the parameter surface REPORTS. `fullState` now also
        // captures the true EQ/pedal values instead of zeros.
        _parameterTree.implementorStringFromValueCallback = { param, valuePtr in
            let v = valuePtr?.pointee ?? param.value
            return String(format: "%.2f", v)
        }

        // Seed the kernel with the default parameter values.
        SRKernelSetParameter(k, inputGain.address, inputGain.value)
        SRKernelSetParameter(k, outputLevel.address, outputLevel.value)
        SRKernelSetParameter(k, ampDrive.address, ampDrive.value)
        SRKernelSetParameter(k, ampMakeup.address, ampMakeup.value)
        SRKernelSetParameter(k, ampBypass.address, ampBypass.value)
        SRKernelSetParameter(k, cabBypass.address, cabBypass.value)
        SRKernelSetParameter(k, useNeural.address, useNeural.value)
        SRKernelSetParameter(k, cabSelect.address, cabSelect.value)
        // Amp EQ defaults are 0 dB = flat, matching the C++ ToneStack default, so
        // this changes no audio — it just keeps the new tree params in sync with the
        // kernel bus. Pedal-grid params are intentionally NOT seeded here: their
        // slots are inactive by default (active count 0), so leaving the kernel's
        // slot atomics at their C++ defaults keeps an untouched unit's render
        // identical to Phase 2 (a rig apply seeds them when a slot goes active).
        SRKernelSetParameter(k, ampBass.address, ampBass.value)
        SRKernelSetParameter(k, ampMid.address, ampMid.value)
        SRKernelSetParameter(k, ampTreble.address, ampTreble.value)
        SRKernelSetParameter(k, ampPresence.address, ampPresence.value)
        // Both default to unity / 100 W, matching the kernel's own defaults, so
        // this changes no audio — it keeps the new tree params in sync with the bus.
        SRKernelSetParameter(k, ampVolume.address, ampVolume.value)
        SRKernelSetParameter(k, ampPower.address, ampPower.value)
    }

    deinit {
        renderStatePtr.deinitialize(count: 1)
        renderStatePtr.deallocate()
        SRKernelDestroy(kernel)
    }

    // MARK: - AUAudioUnit overrides

    public override var parameterTree: AUParameterTree? {
        get { _parameterTree }
        set { /* fixed tree */ }
    }

    public override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    public override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()

        let inFormat = inputBusArray[0].format
        let outFormat = outputBusArray[0].format

        guard let buffer = AVAudioPCMBuffer(pcmFormat: inFormat,
                                            frameCapacity: AVAudioFrameCount(maximumFramesToRender)) else {
            throw NSError(domain: "StreetRigDSPUnit", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate input buffer"])
        }
        buffer.frameLength = AVAudioFrameCount(maximumFramesToRender)
        inputBuffer = buffer
        renderSampleRate = outFormat.sampleRate

        SRKernelPrepare(kernel, outFormat.sampleRate,
                        Int32(outFormat.channelCount),
                        Int32(maximumFramesToRender))

        // Build the neural model + cab IRs OFF the audio thread and hand them to
        // the render path (atomic model swap + preallocated convolver). Runs on
        // the render-setup thread — allocation / file I/O are permitted here.
        loadToneAssets(sampleRate: outFormat.sampleRate)

        // Phase 3: if a rig / preset / fullState was applied before render resources
        // existed, apply its STRUCTURE now — the kernel is prepared and the render
        // thread is not live yet, so the no-barrier `applyImmediate` is correct. An
        // untouched unit has nothing pending, so its render path is unchanged.
        if structuralApplyPending {
            RigGraphCompiler.applyImmediate(ownedPlan, to: self)
            structuralApplyPending = false
        }

        // Publish the live pointers into the stable render context, then flip
        // `ready` last so the render block only proceeds once everything is set.
        renderStatePtr.pointee.inputABL = buffer.mutableAudioBufferList
        renderStatePtr.pointee.channelData = buffer.floatChannelData
        renderStatePtr.pointee.channelCount = Int32(inFormat.channelCount)
        renderStatePtr.pointee.sampleRate = outFormat.sampleRate
        renderStatePtr.pointee.secondsPerTick = secondsPerTick
        renderStatePtr.pointee.ready = 1
    }

    public override func deallocateRenderResources() {
        renderStatePtr.pointee.ready = 0
        renderStatePtr.pointee.inputABL = nil
        renderStatePtr.pointee.channelData = nil
        inputBuffer = nil
        SRKernelReset(kernel)
        super.deallocateRenderResources()
    }

    public override var canProcessInPlace: Bool { true }

    // MARK: - Render block (AUDIO THREAD — hard real-time, no alloc/lock/ARC)

    public override var internalRenderBlock: AUInternalRenderBlock {
        // Capture ONLY the stable render-context pointer (valid for the AU's
        // whole life) — never `self`, never `inputBuffer`. The host reads this
        // getter several times BEFORE render resources exist; the block below
        // simply reads the CURRENT context each call, so it starts working the
        // instant `allocateRenderResources` flips `ready` to 1. No ARC on the
        // audio thread. See RealtimeSafety.md.
        let statePtr = renderStatePtr
        let bytesPerFrame = MemoryLayout<Float>.size

        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            let state = statePtr.pointee
            guard state.ready != 0,
                  let inputABLPtr = state.inputABL,
                  let channels = state.channelData else {
                return kAudioUnitErr_Uninitialized
            }
            let kernel = state.kernel
            let frames = Int(frameCount)

            // Point the input ABL at our stable storage before pulling, so
            // upstream writes where we expect and `mDataByteSize` is right.
            let inABL = UnsafeMutableAudioBufferListPointer(inputABLPtr)
            let byteSize = UInt32(frames * bytesPerFrame)
            let n = min(inABL.count, Int(state.channelCount))
            for i in 0..<n {
                inABL[i].mDataByteSize = byteSize
                inABL[i].mData = UnsafeMutableRawPointer(channels[i])
            }

            // Pull upstream audio (inputNode live, or player node offline).
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
            var pullFlags = AudioUnitRenderActionFlags()
            let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, inputABLPtr)
            if status != noErr { return status }

            // In-place: if the host gave us null output buffers, render into the
            // input storage and hand it back as the output.
            let outABL = UnsafeMutableAudioBufferListPointer(outputData)
            for i in 0..<outABL.count {
                if outABL[i].mData == nil {
                    let j = min(i, inABL.count - 1)
                    outABL[i].mData = inABL[j].mData
                    outABL[i].mDataByteSize = inABL[j].mDataByteSize
                }
            }

            // Hand off to the C++ kernel and record the render load (time spent
            // vs. the buffer's hard deadline = frames / sampleRate).
            let t0 = mach_absolute_time()
            SRKernelProcess(kernel, inputABLPtr, outputData, Int32(frames))
            let t1 = mach_absolute_time()
            let elapsed = Double(t1 &- t0) * state.secondsPerTick
            let deadline = state.sampleRate > 0 ? Double(frames) / state.sampleRate : 0
            SRKernelStoreRenderMetrics(kernel, elapsed, deadline)
            return noErr
        }
    }

    // MARK: - Main-thread conveniences (called by the controller / UI)

    public func setBypassed(_ bypassed: Bool) { SRKernelSetBypass(kernel, bypassed) }
    var isBypassed: Bool { SRKernelGetBypass(kernel) }

    public func setParameter(_ address: SRParameterAddress, value: Float) {
        SRKernelSetParameter(kernel, address.rawValue, value)
    }

    // MARK: - Prompt 003: pedal chain + hot-swap conveniences (setup / bus)

    /// Push a value onto the lock-free bus at a RAW address (used for the
    /// structured pedal parameter range — the SAME `SRKernelSetParameter` bus).
    func setRawParameter(_ address: UInt64, value: Float) {
        SRKernelSetParameter(kernel, address, value)
    }

    /// Push one pedal-slot field (Drive/Tone/Level/…) live through the bus.
    public func setPedalParam(slot: Int, field: Int, value: Float) {
        let address = UInt64(SRPedalParamBase) + UInt64(slot) * UInt64(SRPedalParamStride) + UInt64(field)
        SRKernelSetParameter(kernel, address, value)
    }

    /// How many pedal slots the render thread walks (setup thread).
    func setActivePedalCount(_ count: Int) { SRKernelSetActivePedalCount(kernel, Int32(count)) }

    /// Configure a slot's type (0=transparent,1=drive) + character (0=soft,1=hard,
    /// 2=fuzz) and enablement (setup thread; call inside the reconfigure barrier).
    func configurePedal(slot: Int, type: Int, character: Int, enabled: Bool) {
        SRKernelConfigurePedal(kernel, Int32(slot), Int32(type), Int32(character), enabled)
    }

    /// Where each slot runs relative to the amp: `[0, pre)` in front of the
    /// preamp, `[pre, post)` in the amp's FX loop (after the tone stack, before
    /// the power amp), `[post, count)` after the cabinet. Setup thread; call
    /// inside the reconfigure barrier.
    public func setPedalSplits(pre: Int, post: Int) {
        SRKernelSetPedalSplits(kernel, Int32(pre), Int32(post))
    }

    /// Bytes reserved by the pedal chain's delay/reverb arena. Diagnostics — the
    /// offline harness asserts the documented worst-case footprint.
    public var pedalArenaBytes: UInt64 { SRKernelPedalArenaBytes(kernel) }

    /// Install an amp VOICING PROFILE (`ParameterMap.amp*` ↔ `streetrig::AmpVoicing`)
    /// — re-designs the preamp cascade, tone-stack centres and power amp. Setup
    /// thread; call inside the reconfigure barrier.
    public func configureAmp(profile: Int) { SRKernelConfigureAmp(kernel, Int32(profile)) }

    /// The profile currently installed in the kernel (diagnostics / harness).
    public var activeAmpProfile: Int { Int(SRKernelActiveAmpProfile(kernel)) }

    /// The profile the OWNED rig resolves to. Differs from `activeAmpProfile`
    /// while a rig has been applied but render resources do not exist yet — the
    /// structure is deliberately deferred to `allocateRenderResources`, so an
    /// untouched unit never mutates kernel structure. Diagnostics / harness.
    public var configuredAmpProfile: Int { ownedPlan.ampProfile }

    /// Structural hot-swap barrier (setup thread; safe from a background queue).
    public func beginReconfigure() { SRKernelSetReconfiguring(kernel, true) }
    public func endReconfigure()   { SRKernelSetReconfiguring(kernel, false) }
    var parkedBufferCount: UInt64 { SRKernelGetParkedBufferCount(kernel) }
    func resetChainState()  { SRKernelResetChainState(kernel) }

    /// Fraction of the render deadline consumed by the last audio buffer (0…1+).
    public var lastRenderLoad: Double { SRKernelGetLastRenderLoad(kernel) }
    /// Wall-clock seconds spent in the last render buffer.
    public var lastBlockSeconds: Double { SRKernelGetLastBlockSeconds(kernel) }

    /// How many buffers the render thread has processed since creation — an
    /// "is the audio graph actually running?" signal for the UI and tests.
    public var processCallCount: UInt64 { SRKernelGetProcessCallCount(kernel) }

    // MARK: - Amp / cab conveniences (setup thread — used by the offline harness)

    /// Neural capture + cab IR status captured when assets were loaded. Prompt 003
    /// swaps these per selected amp.
    public struct ToneAssetStatus {
        public var neuralLoaded = false
        public var neuralError: String?
        public var cabLengths: [Int] = []
        public var cabLatency = 0
    }
    public private(set) var toneStatus = ToneAssetStatus()

    private func loadToneAssets(sampleRate: Double) {
        if !didLoadToneAssets {
            var status = ToneAssetStatus()
            // Cabinet IRs → slots 0 (dark 4x12) and 1 (bright 1x12).
            let cabNames = ["cab_v30_4x12", "cab_greenback_1x12"]
            for (slot, name) in cabNames.enumerated() {
                if let ir = Self.loadMonoWav(name) {
                    ir.samples.withUnsafeBufferPointer { buf in
                        SRKernelLoadCabIR(kernel, Int32(slot), buf.baseAddress, Int32(buf.count), ir.sampleRate)
                    }
                }
            }
            // Amp capture (GuitarML / RTNeural "SimpleRNN" LSTM JSON). Resource
            // now ships INSIDE this framework, so resolve the framework bundle
            // (not `Bundle.main`, which is the *host app* — or a DAW in Phase 2).
            if let url = Bundle(for: StreetRigDSPUnit.self).url(forResource: "StreetRig_amp_placeholder", withExtension: "json") {
                var err = [CChar](repeating: 0, count: 256)
                let ok = url.path.withCString { SRKernelLoadAmpModelJSON(kernel, $0, &err, 256) }
                status.neuralLoaded = ok
                if !ok { status.neuralError = String(cString: err) }
            } else {
                status.neuralError = "no amp capture bundled (analog fallback active)"
            }
            didLoadToneAssets = true
            toneStatus = status
        }
        // Re-activate the default cab slot (the convolver is re-prepared per allocate).
        SRKernelSetActiveCabSlot(kernel, 0)
        toneStatus.cabLengths = [Int(SRKernelCabIRLength(kernel, 0)), Int(SRKernelCabIRLength(kernel, 1))]
        toneStatus.cabLatency = Int(SRKernelCabLatencySamples(kernel))
        toneStatus.neuralLoaded = SRKernelHasNeuralModel(kernel)
    }

    /// Load a bundled mono WAV as float samples at its own sample rate.
    public static func loadMonoWav(_ name: String) -> (samples: [Float], sampleRate: Double)? {
        // Cab IRs ship inside this framework — resolve its bundle, not `Bundle.main`.
        guard let url = Bundle(for: StreetRigDSPUnit.self).url(forResource: name, withExtension: "wav"),
              let file = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = file.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil,
              let cd = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength)
        let ch0 = cd[0]
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = ch0[i] }
        return (out, fmt.sampleRate)
    }

    public func setActiveCabSlot(_ slot: Int) { SRKernelSetActiveCabSlot(kernel, Int32(slot)) }
    var hasNeuralModel: Bool { SRKernelHasNeuralModel(kernel) }
    func cabIRLength(_ slot: Int) -> Int { Int(SRKernelCabIRLength(kernel, Int32(slot))) }
    public var cabLatencySamples: Int { Int(SRKernelCabLatencySamples(kernel)) }
    public func resetDSP() { SRKernelReset(kernel) }

    /// Average nanoseconds per sample of the active neural forward pass (0 if none).
    public func benchmarkNeuralNsPerSample(_ iterations: Int) -> Double {
        SRKernelBenchmarkNeuralNsPerSample(kernel, Int32(iterations))
    }

    /// Average nanoseconds per sample of the WHOLE amp→cab chain at the current
    /// parameter state — the definitive live-cost estimate.
    public func benchmarkFullNsPerSample(frames: Int, iterations: Int) -> Double {
        SRKernelBenchmarkFullNsPerSample(kernel, Int32(frames), Int32(iterations))
    }

    // MARK: - Phase 3: host-facing declarations (channel caps + reported latency)

    /// Advertise supported I/O configs as (in, out) pairs: mono→mono (guitar tracks
    /// are frequently mono) and stereo→stereo. Lets hosts / `auval` route correctly.
    public override var channelCapabilities: [NSNumber]? {
        [1, 1, 2, 2].map { NSNumber(value: $0) }
    }

    /// Report the cabinet convolver's delay so the host performs plugin-delay
    /// compensation. `SRKernelCabLatencySamples` is non-zero once an IR is active
    /// (after `allocateRenderResources` → `loadToneAssets`); guard the divide.
    public override var latency: TimeInterval {
        renderSampleRate > 0 ? Double(SRKernelCabLatencySamples(kernel)) / renderSampleRate : 0
    }

    // MARK: - Phase 4: host view configurations (compact + full editor sizes)

    /// The two sizes the plugin editor is designed for: a COMPACT control strip
    /// (amp knobs + active-pedal row) and the FULL rig editor (amp + every pedal
    /// card). A host that supports `AUAudioUnitViewConfiguration` may offer either;
    /// `supportedViewConfigurations` advertises that we render both.
    public static let compactViewConfiguration = AUAudioUnitViewConfiguration(width: 400, height: 200, hostHasController: false)
    public static let fullViewConfiguration = AUAudioUnitViewConfiguration(width: 640, height: 420, hostHasController: false)

    /// Below this offered height the editor collapses to the compact strip.
    static let compactHeightThreshold: CGFloat = 260

    /// Set by the editor view controller; invoked (on the main thread) with
    /// `isCompact` whenever the host selects a view configuration, so the SwiftUI
    /// editor can switch layouts live. `Bool` (not the config object) keeps the
    /// hop trivially `Sendable`.
    public var viewConfigurationHandler: ((Bool) -> Void)?

    /// The configuration the host most recently `select`ed (nil until then).
    public private(set) var selectedViewConfiguration: AUAudioUnitViewConfiguration?

    /// Which offered configurations we can render. The editor is responsive, so we
    /// support every size the host offers (choosing compact vs full by height).
    public override func supportedViewConfigurations(_ availableViewConfigurations: [AUAudioUnitViewConfiguration]) -> IndexSet {
        IndexSet(availableViewConfigurations.indices)
    }

    /// The host picked a size — remember it and tell the editor to relayout.
    public override func select(_ viewConfiguration: AUAudioUnitViewConfiguration) {
        selectedViewConfiguration = viewConfiguration
        let compact = viewConfiguration.height > 0 && viewConfiguration.height < Self.compactHeightThreshold
        guard let handler = viewConfigurationHandler else { return }
        if Thread.isMainThread { handler(compact) }
        else { DispatchQueue.main.async { handler(compact) } }
    }

    // MARK: - Phase 3: structural rig apply seam (SETUP THREAD — never audio thread)

    /// Apply a serialized rig snapshot: compile it, sync the AUParameterTree +
    /// kernel CONTINUOUS bus to the compiled values, then (re)apply the STRUCTURE
    /// (pedal count / type / character, cab slot). Structure runs through the
    /// fade/park barrier when render is LIVE, else is deferred to the next
    /// `allocateRenderResources` (so an untouched unit never mutates structure).
    /// Setup-thread only — adds no audio-thread work (RealtimeSafety.md intact).
    /// Internal (not public): `RigStore.PersistedState` is a framework-internal type,
    /// and hosts drive the rig through the public `fullState` / preset API instead.
    func applyRig(_ snapshot: RigStore.PersistedState) {
        let plan = RigGraphCompiler.compile(collection: snapshot.collection, rig: snapshot.rig)
        ownedSnapshot = snapshot
        ownedPlan = plan
        if let data = try? JSONEncoder().encode(snapshot) { ownedRigData = data }
        syncParameterTree(from: plan)
        if renderResourcesAllocated {
            RigGraphCompiler.applyHotSwap(plan, to: self, on: reconfigureQueue)
        } else {
            structuralApplyPending = true
        }
    }

    /// Push the compiled plan's CONTINUOUS values into the AUParameterTree so the
    /// tree (hence `fullState` and the host's automation lanes) mirrors the rig;
    /// each `.value` write forwards to the kernel bus via the generic value
    /// observer. Input/output gains are independent of the rig and left untouched.
    private func syncParameterTree(from plan: RigDSPPlan) {
        func set(_ address: UInt64, _ value: AUValue) {
            _parameterTree.parameter(withAddress: address)?.value = value
        }
        set(UInt64(SRParamAmpDrive.rawValue),     plan.ampDrive)
        set(UInt64(SRParamAmpMakeup.rawValue),    plan.ampMaster)
        set(UInt64(SRParamAmpBypass.rawValue),    plan.ampBypass ? 1 : 0)
        set(UInt64(SRParamCabBypass.rawValue),    plan.cabBypass ? 1 : 0)
        set(UInt64(SRParamAmpUseNeural.rawValue), plan.useNeural ? 1 : 0)
        set(UInt64(SRParamCabSelect.rawValue),    AUValue(plan.cabSlot))
        set(UInt64(SRParamAmpBass.rawValue),      plan.ampBassDB)
        set(UInt64(SRParamAmpMid.rawValue),       plan.ampMidDB)
        set(UInt64(SRParamAmpTreble.rawValue),    plan.ampTrebleDB)
        set(UInt64(SRParamAmpPresence.rawValue),  plan.ampPresenceDB)
        set(UInt64(SRParamAmpVolume.rawValue),    plan.ampVolume)
        set(UInt64(SRParamAmpPower.rawValue),     plan.ampPower)
        for (i, slot) in plan.pedals.enumerated() where i < Int(SRMaxPedals) {
            let base = UInt64(SRPedalParamBase) + UInt64(i) * UInt64(SRPedalParamStride)
            set(base + UInt64(SRPedalFieldEnabled), slot.enabled ? 1 : 0)
            // Mirror the compiler's generic per-family params (Param0 == SRPedalFieldDrive)
            // EXACTLY as RigGraphCompiler.pushValues writes them to the kernel bus, so the
            // tree/fullState stay in lock-step with the kernel across every pedal family.
            let maxParams = Int(SRPedalParamStride) - Int(SRPedalFieldDrive)
            for (j, value) in slot.params.enumerated() where j < maxParams {
                set(base + UInt64(Int(SRPedalFieldDrive) + j), value)
            }
        }
    }

    // MARK: - Phase 3: full state (save / recall the WHOLE rig with the project)

    /// Stable custom key carrying the serialized rig snapshot (topology + resolved
    /// gear + knob values) alongside `super`'s parameter dictionary.
    private static let rigStateKey = "streetrig.rig.v1"

    public override var fullState: [String : Any]? {
        get { augmentedState(super.fullState) }
        set {
            applyRigBlob(from: newValue)     // rebuild structure/gear first…
            super.fullState = strippedForSuper(newValue)   // …then load saved params
        }
    }

    /// Documents get the same blob today; the distinct seam is kept in case a
    /// document later needs to EMBED a neural capture (plan §5.D).
    public override var fullStateForDocument: [String : Any]? {
        get { augmentedState(super.fullStateForDocument) }
        set {
            applyRigBlob(from: newValue)
            super.fullStateForDocument = strippedForSuper(newValue)
        }
    }

    private func augmentedState(_ base: [String : Any]?) -> [String : Any]? {
        var state = base ?? [:]
        state[Self.rigStateKey] = ownedRigData
        return state
    }

    /// Rebuild the structural rig from our blob (baseline = the rig's gear values).
    /// `super` then loads the saved parameter values, which are AUTHORITATIVE — they
    /// honor host automation that differs from the baked knobs and carry the I/O
    /// gains the blob does not. The structure is applied via the barrier/allocate
    /// seam inside `applyRig`.
    private func applyRigBlob(from newValue: [String : Any]?) {
        guard let data = newValue?[Self.rigStateKey] as? Data,
              let snapshot = try? JSONDecoder().decode(RigStore.PersistedState.self, from: data) else { return }
        applyRig(snapshot)
    }

    private func strippedForSuper(_ newValue: [String : Any]?) -> [String : Any]? {
        guard var v = newValue else { return nil }
        v.removeValue(forKey: Self.rigStateKey)
        return v
    }

    // MARK: - Phase 3: presets (factory + user)

    /// A few starter rigs built from seed-style `RigConfiguration`s — self-contained
    /// (resolved gear + wiring), so they round-trip without the app's collection.
    static let factoryRigs: [(name: String, state: RigStore.PersistedState)] = makeFactoryRigs()

    private lazy var _factoryPresets: [AUAudioUnitPreset] = Self.factoryRigs.enumerated().map { pair in
        let p = AUAudioUnitPreset(); p.number = pair.offset; p.name = pair.element.name; return p
    }

    public override var factoryPresets: [AUAudioUnitPreset]? { _factoryPresets }

    /// Standard iOS 13+ user-preset storage (persists `fullStateForDocument`, which
    /// carries the rig blob). The App-Group shared location is Phase 4.
    public override var supportsUserPresets: Bool { true }

    public override var currentPreset: AUAudioUnitPreset? {
        get { _currentPreset }
        set {
            guard let preset = newValue else { _currentPreset = nil; return }
            if preset.number >= 0 {
                // Factory: apply its rig directly (syncs the tree + kernel + structure).
                guard preset.number < Self.factoryRigs.count else { return }
                applyRig(Self.factoryRigs[preset.number].state)
                _currentPreset = preset
            } else if let state = try? presetState(for: preset) {
                // User: load the persisted full state.
                fullState = state
                _currentPreset = preset
            }
        }
    }

    public override func presetState(for preset: AUAudioUnitPreset) throws -> [String : Any] {
        if preset.number >= 0 {
            guard preset.number < Self.factoryRigs.count else {
                throw NSError(domain: "StreetRigDSPUnit", code: -40,
                              userInfo: [NSLocalizedDescriptionKey: "unknown factory preset \(preset.number)"])
            }
            // Realize the factory rig on a scratch unit and read its full state, so
            // the returned dictionary is exactly what selecting the preset produces.
            let scratch = try StreetRigDSPUnit(componentDescription: Self.inProcessComponentDescription)
            scratch.applyRig(Self.factoryRigs[preset.number].state)
            return scratch.fullState ?? [:]
        }
        // User preset — load from our own local storage (the built-in machinery does
        // not persist for the in-process `srdi` handle; local storage is portable).
        guard let url = Self.userPresetURL(preset.name),
              let data = try? Data(contentsOf: url),
              let dict = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw NSError(domain: "StreetRigDSPUnit", code: -42,
                          userInfo: [NSLocalizedDescriptionKey: "user preset not found: \(preset.name)"])
        }
        return dict
    }

    // MARK: - Phase 3: user-preset storage (LOCAL; App-Group sharing is Phase 4)

    public override func saveUserPreset(_ userPreset: AUAudioUnitPreset) throws {
        guard let url = Self.userPresetURL(userPreset.name) else {
            throw NSError(domain: "StreetRigDSPUnit", code: -41,
                          userInfo: [NSLocalizedDescriptionKey: "no user-preset storage location"])
        }
        // A user preset's state IS the plugin's full document state (params + rig blob).
        let state = fullStateForDocument ?? [:]
        let data = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
        try data.write(to: url, options: [.atomic])
        _currentPreset = userPreset
    }

    public override func deleteUserPreset(_ userPreset: AUAudioUnitPreset) throws {
        guard let url = Self.userPresetURL(userPreset.name) else { return }
        try FileManager.default.removeItem(at: url)
        if _currentPreset?.name == userPreset.name { _currentPreset = nil }
    }

    public override var userPresets: [AUAudioUnitPreset] {
        guard let dir = Self.userPresetsDir(),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        let names = files.filter { $0.pathExtension == "srpreset" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
        return names.enumerated().map { idx, name in
            let p = AUAudioUnitPreset(); p.number = -(idx + 1); p.name = name; return p
        }
    }

    private static func userPresetsDir() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("StreetRigUserPresets", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func userPresetURL(_ name: String) -> URL? {
        let safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        guard !safe.isEmpty else { return nil }
        return userPresetsDir()?.appendingPathComponent(safe).appendingPathExtension("srpreset")
    }

    /// The factory rig catalog. Each is a self-contained `PersistedState` whose
    /// `collection` holds exactly the gear the rig references.
    private static func makeFactoryRigs() -> [(name: String, state: RigStore.PersistedState)] {
        func state(guitar: GearItem, amp: AmpSection, gear: [GearItem], pedals: [UUID]) -> RigStore.PersistedState {
            RigStore.PersistedState(collection: [guitar] + gear,
                                    rig: RigConfiguration(guitarId: guitar.id, ampSection: amp, pedalIds: pedals),
                                    arSlots: nil)
        }
        // Clean Combo — Fandor Deluxe combo, no pedals.
        let g1 = GearItem(name: "Lyle Preston Standard", category: .guitar)
        let combo = GearItem(name: "Fandor Deluxe", category: .comboAmp,
                             values: ["Gain": 3, "Bass": 6, "Mid": 5, "Treble": 6, "Presence": 5, "Master": 5])
        let clean = state(guitar: g1, amp: .combo(comboId: combo.id), gear: [combo], pedals: [])

        // British Crunch — ValveShrieker → MSW900 + 4x12 (slot 0 is a DRIVE pedal).
        let g2 = GearItem(name: "Lyle Preston Standard", category: .guitar)
        let jcm = GearItem(name: "Marswell MSW900", category: .amp,
                           values: ["Gain": 6, "Bass": 5, "Mid": 6, "Treble": 6, "Presence": 5, "Master": 6])
        let cab412 = GearItem(name: "Marswell 2415A 4x12", category: .cabinet)
        let ts = GearItem(name: "ValveShrieker", category: .overdrive,
                          values: ["Drive": 5, "Tone": 6, "Level": 6])
        let crunch = state(guitar: g2, amp: .stack(ampId: jcm.id, cabinetId: cab412.id),
                           gear: [jcm, cab412, ts], pedals: [ts.id])

        // High-Gain Stack — ValveShrieker + BigMitt → Mesquite Dual Reactor + 4x12.
        let g3 = GearItem(name: "Lyle Preston Standard", category: .guitar)
        let mesquite = GearItem(name: "Mesquite Dual Reactor", category: .amp,
                            values: ["Gain": 8, "Bass": 6, "Mid": 4, "Treble": 6, "Presence": 6, "Master": 5])
        let cabHG = GearItem(name: "Marswell 2415A 4x12", category: .cabinet)
        let ts2 = GearItem(name: "ValveShrieker", category: .overdrive,
                           values: ["Drive": 3, "Tone": 6, "Level": 7])
        let mitt = GearItem(name: "BigMitt", category: .overdrive,
                            values: ["Drive": 8, "Tone": 5, "Level": 5])
        let highGain = state(guitar: g3, amp: .stack(ampId: mesquite.id, cabinetId: cabHG.id),
                             gear: [mesquite, cabHG, ts2, mitt], pedals: [ts2.id, mitt.id])

        // Kabuto channels. A channel memory on the hardware is "the whole panel,
        // stored" — and `GearItem.values` already IS the whole panel, including
        // Character / Variation / Power, so a channel needs no schema of its own.
        // APPENDED, never inserted: a host may have stored `preset.number`, so the
        // three presets above must keep numbers 0, 1 and 2 forever.
        let g4 = GearItem(name: "Lyle Preston Standard", category: .guitar)
        let katCrunch = GearItem(name: "VOSS Ketana 100", category: .comboAmp,
                                 values: ["Gain": 6, "Bass": 5, "Mid": 6, "Treble": 6,
                                          "Presence": 5, "Volume": 6, "Master": 5,
                                          "Character": 2, "Variation": 0, "Power": 2])
        let katCrunchRig = state(guitar: g4, amp: .combo(comboId: katCrunch.id),
                                 gear: [katCrunch], pedals: [])

        // Brown B at 0.5 W: the power control doing the thing it exists for —
        // output-stage saturation at a level you could rehearse at.
        let g5 = GearItem(name: "Lyle Preston Standard", category: .guitar)
        let katBrown = GearItem(name: "VOSS Ketana 100", category: .comboAmp,
                                values: ["Gain": 7, "Bass": 5, "Mid": 6, "Treble": 6,
                                         "Presence": 6, "Volume": 8, "Master": 5,
                                         "Character": 4, "Variation": 1, "Power": 0])
        let katBrownRig = state(guitar: g5, amp: .combo(comboId: katBrown.id),
                                gear: [katBrown], pedals: [])

        return [("Clean Combo", clean), ("British Crunch", crunch), ("High-Gain Stack", highGain),
                ("Kabuto Crunch", katCrunchRig), ("Kabuto Brown Lead", katBrownRig)]
    }
}

/// Stable, plain-old-data render context shared between the setup thread (which
/// populates it in `allocateRenderResources`) and the audio thread (which reads
/// it every render). All fields are pointers/scalars — no reference types — so
/// reading `statePtr.pointee` on the audio thread does zero ARC. `ready` is the
/// last field flipped, so the render block never touches half-initialized state.
nonisolated struct StreetRigRenderState {
    var kernel: SRKernelRef?
    var inputABL: UnsafeMutablePointer<AudioBufferList>?
    var channelData: UnsafePointer<UnsafeMutablePointer<Float>>?
    var channelCount: Int32
    var sampleRate: Double
    var secondsPerTick: Double
    var ready: Int32
}

/// Four-character-code helper for AudioComponentDescription fields.
nonisolated func fourCharCode(_ string: String) -> FourCharCode {
    var result: FourCharCode = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) + FourCharCode(scalar.value & 0xFF)
    }
    return result
}
