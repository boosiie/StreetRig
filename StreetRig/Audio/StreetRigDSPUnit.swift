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

nonisolated final class StreetRigDSPUnit: AUAudioUnit {

    // MARK: - Component identity / in-process registration

    /// `aufx`/`srds`/`Strg` — the effect component the AVAudioEngine instantiates.
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: fourCharCode("srds"),
        componentManufacturer: fourCharCode("Strg"),
        componentFlags: 0,
        componentFlagsMask: 0
    )

    /// Register the subclass exactly once so `AVAudioUnit.instantiate` can find it.
    private static let registration: Void = {
        AUAudioUnit.registerSubclass(StreetRigDSPUnit.self,
                                     as: componentDescription,
                                     name: "StreetRig DSP",
                                     version: 1)
    }()
    static func registerIfNeeded() { _ = registration }

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

    // MARK: - Init

    override init(componentDescription: AudioComponentDescription,
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
        let outputLevel = AUParameterTree.createParameter(
            withIdentifier: "outputLevel", name: "Output Level",
            address: AUParameterAddress(SRParamOutputLevel.rawValue),
            min: 0.0, max: 4.0, unit: .linearGain, unitName: nil,
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
        let cabSelect = AUParameterTree.createParameter(
            withIdentifier: "cabSelect", name: "Cab Select",
            address: AUParameterAddress(SRParamCabSelect.rawValue),
            min: 0.0, max: 3.0, unit: .indexed, unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable], valueStrings: nil, dependentParameters: nil)
        // Defaults: amp + cab engaged, prefer the neural capture when one loads
        // (the kernel auto-falls back to the analog amp if none is available).
        ampDrive.value = 3.0
        ampMakeup.value = 1.0
        ampBypass.value = 0.0
        cabBypass.value = 0.0
        useNeural.value = 1.0
        cabSelect.value = 0.0

        self.inputGainParameter = inputGain
        self.outputLevelParameter = outputLevel
        self.ampDriveParameter = ampDrive
        self.ampMakeupParameter = ampMakeup
        self.ampBypassParameter = ampBypass
        self.cabBypassParameter = cabBypass
        self.useNeuralParameter = useNeural
        self.cabSelectParameter = cabSelect
        self._parameterTree = AUParameterTree.createTree(withChildren: [
            inputGain, outputLevel, ampDrive, ampMakeup,
            ampBypass, cabBypass, useNeural, cabSelect,
        ])

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
        _parameterTree.implementorValueProvider = { param in
            SRKernelGetParameter(k, param.address)
        }
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
    }

    deinit {
        renderStatePtr.deinitialize(count: 1)
        renderStatePtr.deallocate()
        SRKernelDestroy(kernel)
    }

    // MARK: - AUAudioUnit overrides

    override var parameterTree: AUParameterTree? {
        get { _parameterTree }
        set { /* fixed tree */ }
    }

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    override func allocateRenderResources() throws {
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

        // Publish the live pointers into the stable render context, then flip
        // `ready` last so the render block only proceeds once everything is set.
        renderStatePtr.pointee.inputABL = buffer.mutableAudioBufferList
        renderStatePtr.pointee.channelData = buffer.floatChannelData
        renderStatePtr.pointee.channelCount = Int32(inFormat.channelCount)
        renderStatePtr.pointee.sampleRate = outFormat.sampleRate
        renderStatePtr.pointee.secondsPerTick = secondsPerTick
        renderStatePtr.pointee.ready = 1
    }

    override func deallocateRenderResources() {
        renderStatePtr.pointee.ready = 0
        renderStatePtr.pointee.inputABL = nil
        renderStatePtr.pointee.channelData = nil
        inputBuffer = nil
        SRKernelReset(kernel)
        super.deallocateRenderResources()
    }

    override var canProcessInPlace: Bool { true }

    // MARK: - Render block (AUDIO THREAD — hard real-time, no alloc/lock/ARC)

    override var internalRenderBlock: AUInternalRenderBlock {
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

    func setBypassed(_ bypassed: Bool) { SRKernelSetBypass(kernel, bypassed) }
    var isBypassed: Bool { SRKernelGetBypass(kernel) }

    func setParameter(_ address: SRParameterAddress, value: Float) {
        SRKernelSetParameter(kernel, address.rawValue, value)
    }

    // MARK: - Prompt 003: pedal chain + hot-swap conveniences (setup / bus)

    /// Push a value onto the lock-free bus at a RAW address (used for the
    /// structured pedal parameter range — the SAME `SRKernelSetParameter` bus).
    func setRawParameter(_ address: UInt64, value: Float) {
        SRKernelSetParameter(kernel, address, value)
    }

    /// Push one pedal-slot field (Drive/Tone/Level/…) live through the bus.
    func setPedalParam(slot: Int, field: Int, value: Float) {
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

    /// Structural hot-swap barrier (setup thread; safe from a background queue).
    func beginReconfigure() { SRKernelSetReconfiguring(kernel, true) }
    func endReconfigure()   { SRKernelSetReconfiguring(kernel, false) }
    var parkedBufferCount: UInt64 { SRKernelGetParkedBufferCount(kernel) }
    func resetChainState()  { SRKernelResetChainState(kernel) }

    /// Fraction of the render deadline consumed by the last audio buffer (0…1+).
    var lastRenderLoad: Double { SRKernelGetLastRenderLoad(kernel) }
    /// Wall-clock seconds spent in the last render buffer.
    var lastBlockSeconds: Double { SRKernelGetLastBlockSeconds(kernel) }

    /// How many buffers the render thread has processed since creation — an
    /// "is the audio graph actually running?" signal for the UI and tests.
    var processCallCount: UInt64 { SRKernelGetProcessCallCount(kernel) }

    // MARK: - Amp / cab conveniences (setup thread — used by the offline harness)

    /// Neural capture + cab IR status captured when assets were loaded. Prompt 003
    /// swaps these per selected amp.
    struct ToneAssetStatus {
        var neuralLoaded = false
        var neuralError: String?
        var cabLengths: [Int] = []
        var cabLatency = 0
    }
    private(set) var toneStatus = ToneAssetStatus()

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
            // Amp capture (GuitarML / RTNeural "SimpleRNN" LSTM JSON).
            if let url = Bundle.main.url(forResource: "StreetRig_amp_placeholder", withExtension: "json") {
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
    static func loadMonoWav(_ name: String) -> (samples: [Float], sampleRate: Double)? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav"),
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

    func setActiveCabSlot(_ slot: Int) { SRKernelSetActiveCabSlot(kernel, Int32(slot)) }
    var hasNeuralModel: Bool { SRKernelHasNeuralModel(kernel) }
    func cabIRLength(_ slot: Int) -> Int { Int(SRKernelCabIRLength(kernel, Int32(slot))) }
    var cabLatencySamples: Int { Int(SRKernelCabLatencySamples(kernel)) }
    func resetDSP() { SRKernelReset(kernel) }

    /// Average nanoseconds per sample of the active neural forward pass (0 if none).
    func benchmarkNeuralNsPerSample(_ iterations: Int) -> Double {
        SRKernelBenchmarkNeuralNsPerSample(kernel, Int32(iterations))
    }

    /// Average nanoseconds per sample of the WHOLE amp→cab chain at the current
    /// parameter state — the definitive live-cost estimate.
    func benchmarkFullNsPerSample(frames: Int, iterations: Int) -> Double {
        SRKernelBenchmarkFullNsPerSample(kernel, Int32(frames), Int32(iterations))
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
