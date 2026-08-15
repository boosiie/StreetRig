//
//  AudioEngineController.swift
//  StreetRig
//
//  The audio ENGINE HOST: owns the AVAudioSession, the AVAudioEngine graph
//  (inputNode -> StreetRigDSPUnit -> mainMixerNode -> outputNode), the engine
//  lifecycle, interruption/route-change handling, mic permission, live route
//  enumeration for the DeviceBar, and the OFFLINE FILE-RENDER HARNESS that
//  verifies the whole graph on the Simulator (which has no audio input).
//
//  THREADING: everything here is @MainActor — session setup, engine start/stop,
//  parameter writes, published UI state. The ONLY code that runs on the audio
//  render thread is inside StreetRigDSPUnit's render block / the C++ kernel.
//  The parameter hand-off between the two is the lock-free AUParameterTree bus.
//  See RealtimeSafety.md.
//

import Foundation
import StreetRigEngine
import AVFoundation
import Combine

@MainActor
final class AudioEngineController: ObservableObject {

    // MARK: - Published UI state

    enum EngineStatus: Equatable {
        case idle, running, interrupted
        case error(String)

        var label: String {
            switch self {
            case .idle: return "Idle"
            case .running: return "Live"
            case .interrupted: return "Paused"
            case .error(let m): return "Error: \(m)"
            }
        }
    }

    enum PermissionState { case unknown, granted, denied }

    @Published private(set) var status: EngineStatus = .idle
    @Published private(set) var isEngaged = false
    @Published private(set) var micPermission: PermissionState = .unknown

    // Granted session values (read back from the OS — it may not honor requests).
    @Published private(set) var grantedSampleRate: Double = 0
    @Published private(set) var grantedIOBufferDuration: Double = 0
    @Published private(set) var grantedInputLatency: Double = 0
    @Published private(set) var grantedOutputLatency: Double = 0

    // Live render-load read-out (fraction of the buffer deadline consumed).
    @Published private(set) var renderLoad: Double = 0
    @Published private(set) var lastBlockSeconds: Double = 0

    /// LIVE SIGNAL LEVELS — input (raw DI, pre-rig) and output (post-rig).
    ///
    /// Deliberately a nested ObservableObject held by a plain `let` rather than a
    /// `@Published` property here: levels publish ~30×/s, and anything observing
    /// the controller (the device bar, route pickers, the AR slots, the camera
    /// preview) would re-render at that rate. Only the meter views observe this,
    /// so a level update redraws a meter and nothing else. The controller still
    /// owns its lifecycle: it installs the taps that feed it and tears them down.
    let levels = AudioLevelMonitor()

    /// Monitoring volume — the DSP's existing OUTPUT LEVEL stage (unity = 1.0).
    /// Kept here (not in a view) so it survives the signal-check screen being
    /// dismissed and re-opened, and is re-applied on every engage.
    @Published var masterLevel: Float = 1.0 {
        didSet {
            guard masterLevel != oldValue else { return }
            applyMasterLevel()
        }
    }

    // Routes for the DeviceBar dropdowns.
    @Published private(set) var currentInputName: String = "—"
    @Published private(set) var currentOutputName: String = "—"
    @Published private(set) var availableInputs: [RouteOption] = []

    /// Human-readable summary of the last offline render (shown in DEBUG UI).
    @Published private(set) var lastRenderReport: String?

    struct RouteOption: Identifiable, Hashable {
        let name: String
        let uid: String
        var id: String { uid }
    }

    // MARK: - Private engine state

    private var engine: AVAudioEngine?
    private var avAudioUnit: AVAudioUnit?
    private var dspUnit: StreetRigDSPUnit?
    private var meterTimer: DispatchSourceTimer?
    private var levelTapsInstalled = false
    private var observers: [NSObjectProtocol] = []

    /// Tap buffer size. ~21 ms at 48 kHz — long enough that the tap overhead is
    /// negligible against the render deadline, short enough that the 30 Hz UI
    /// tick always has fresh audio to drain.
    private static let levelTapFrames: AVAudioFrameCount = 1024

    // Prompt 003: the live rig↔DSP binding. Set via `attach(store:)`; the bridge
    // is (re)created on engage so knob moves + rig edits drive the audio graph.
    private weak var rigStore: RigStore?
    private var rigBridge: RigAudioBridge?

    /// Give the controller the app's rig so live monitoring plays the built rig
    /// and every knob is bound. Call once (e.g. from the device bar's onAppear).
    func attach(store: RigStore) { rigStore = store }

    // The requested low-latency targets (the OS grants what it can).
    private let requestedSampleRate: Double = 48_000
    private let requestedIOBufferDuration: TimeInterval = 0.005   // ~5 ms

    init() {
        // Inert on purpose: no session, no engine, no notifications until the
        // player engages. Keeps SwiftUI previews and app launch side-effect free.
    }

    deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: - Engage / disengage (LIVE monitoring — physical device only)

    /// Configure the session + graph and start live monitoring. On the Simulator
    /// there is no input device, so this will surface an error — that is expected
    /// and the offline harness is the Simulator verification path.
    func engage() async {
        guard !isEngaged else { return }

        let granted = await Self.requestMicPermission()
        micPermission = granted ? .granted : .denied
        guard granted else {
            status = .error("Microphone access denied")
            return
        }

        do {
            try configureSession(activate: true)
            registerObservers()

            StreetRigDSPUnit.registerIfNeeded()
            let unit = try await Self.instantiateDSPUnit()

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let inputFormat = input.inputFormat(forBus: 0)
            guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
                throw NSError(domain: "AudioEngineController", code: -10,
                              userInfo: [NSLocalizedDescriptionKey:
                                "No audio input available (expected on Simulator — use the offline render)"])
            }

            engine.attach(unit)
            engine.connect(input, to: unit, format: inputFormat)
            engine.connect(unit, to: engine.mainMixerNode, format: inputFormat)

            engine.prepare()
            try engine.start()

            self.engine = engine
            self.avAudioUnit = unit
            self.dspUnit = unit.auAudioUnit as? StreetRigDSPUnit
            applyMasterLevel()

            // Meter taps go on once the engine is RUNNING, so both nodes report a
            // settled stream format (a tap installed against a not-yet-negotiated
            // format is the other classic AVAudioEngine trap). Input node = raw DI
            // pre-rig; main mixer = the processed rig post-rig.
            installLevelTaps(on: engine)

            // Compile the current rig into the graph and bind every knob live.
            // The engine is running, so structural edits use the fade/park barrier.
            if let dsp = self.dspUnit, let store = self.rigStore {
                rigBridge = RigAudioBridge(store: store, dsp: dsp,
                                           isRenderLive: { [weak self] in self?.engine?.isRunning ?? false })
            }

            startMetering()
            refreshRoutes()
            isEngaged = true
            status = .running
            log("Live engine started. \(latencyLine())")
        } catch {
            status = .error(error.localizedDescription)
            teardown()
            log("engage() failed: \(error.localizedDescription)")
        }
    }

    func disengage() {
        teardown()
        isEngaged = false
        status = .idle
        log("Live engine stopped.")
    }

    private func teardown() {
        stopMetering()
        // Taps come off BEFORE the nodes stop / detach: a tap left on a node that
        // is being torn down is the classic AVAudioEngine crash.
        removeLevelTaps()
        rigBridge = nil
        engine?.stop()
        if let unit = avAudioUnit { engine?.detach(unit) }
        engine = nil
        avAudioUnit = nil
        dspUnit = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Bypass / parameter conveniences (prompt 003 binds knobs through here)

    func setBypassed(_ bypassed: Bool) { dspUnit?.setBypassed(bypassed) }

    /// Push the monitoring volume onto the DSP through the AUParameterTree, so
    /// the kernel bus AND the unit's serialized state stay in lock-step (the tree
    /// forwards to `SRKernelSetParameter` in its value observer — a lock-free
    /// relaxed store the render thread ramps, never a rebuild).
    private func applyMasterLevel() {
        dspUnit?.parameterTree?
            .parameter(withAddress: AUParameterAddress(SRParamOutputLevel.rawValue))?
            .value = masterLevel
    }

    // MARK: - Level taps (the only StreetRig code that runs on the audio thread
    //         outside the kernel — see RealtimeSafety.md)

    /// Install the pre-rig and post-rig meter taps.
    ///
    /// Everything the tap block needs is resolved HERE, on the main thread, and
    /// captured as plain `Int`s: the audio thread never queries a format, never
    /// allocates, never locks and never hops a queue. The buses are captured once
    /// (a single retain at install time); each callback just calls through them.
    private func installLevelTaps(on engine: AVAudioEngine) {
        // Deinterleaved (the engine's normal case) → one plane per channel.
        // Interleaved → a single plane holding channelCount samples per frame.
        // Precomputing both forms keeps the callback free of format lookups.
        func install(_ node: AVAudioNode, into bus: AudioLevelBus) {
            let format = node.outputFormat(forBus: 0)
            guard format.channelCount > 0 else { return }
            let planes = format.isInterleaved ? 1 : Int(format.channelCount)
            let samplesPerFrame = format.isInterleaved ? Int(format.channelCount) : 1

            node.installTap(onBus: 0, bufferSize: Self.levelTapFrames, format: format) { buffer, _ in
                guard let channels = buffer.floatChannelData else { return }
                let samples = Int(buffer.frameLength) * samplesPerFrame
                for plane in 0..<planes {
                    bus.accumulate(channels[plane], frameCount: samples)
                }
            }
        }
        // Independently, so a mixer whose format hasn't settled can't cost us the
        // input meter — the one that answers "is the guitar even reaching me?".
        install(engine.inputNode, into: levels.inputBus)
        install(engine.mainMixerNode, into: levels.outputBus)
        levelTapsInstalled = true
    }

    private func removeLevelTaps() {
        defer { levelTapsInstalled = false }
        guard levelTapsInstalled, let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
    }

    // MARK: - Session

    /// Configure `.playAndRecord` + `.measurement` (raw DI: no AGC/EQ/NR), request
    /// a low IO buffer + 48 kHz, then READ BACK and publish the granted values.
    /// Not `private` so the offline-render extension (separate file) can reuse it.
    func configureSession(activate: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        // `.measurement` disables input processing so the amp sim starts from the
        // untouched guitar signal. No `.defaultToSpeaker` (feedback risk) — prefer
        // the connected headphones/route. A2DP allowed so AirPods can monitor.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothA2DP])
        try? session.setPreferredSampleRate(requestedSampleRate)
        try? session.setPreferredIOBufferDuration(requestedIOBufferDuration)
        if activate { try session.setActive(true, options: []) }

        grantedSampleRate = session.sampleRate
        grantedIOBufferDuration = session.ioBufferDuration
        grantedInputLatency = session.inputLatency
        grantedOutputLatency = session.outputLatency
        log("Session configured. \(latencyLine())")
    }

    func latencyLine() -> String {
        let bufMs = grantedIOBufferDuration * 1_000
        let frames = grantedIOBufferDuration * grantedSampleRate
        return String(format: "SR=%.0f Hz, IOBuffer=%.3f ms (~%.0f frames), inLat=%.2f ms, outLat=%.2f ms",
                      grantedSampleRate, bufMs, frames,
                      grantedInputLatency * 1_000, grantedOutputLatency * 1_000)
    }

    /// Set from the offline-render extension (separate file → needs a setter
    /// because `lastRenderReport` is `private(set)`).
    func setLastRenderReport(_ report: String) { lastRenderReport = report }

    // MARK: - Routes

    /// Set a record-capable category (no activation, no permission prompt) so the
    /// DeviceBar can enumerate inputs before the player engages. Best-effort.
    func primeRoutes() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothA2DP])
        refreshRoutes()
    }

    func refreshRoutes() {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        currentInputName = route.inputs.first?.portName ?? "—"
        currentOutputName = route.outputs.first?.portName ?? "—"
        availableInputs = (session.availableInputs ?? []).map {
            RouteOption(name: $0.portName, uid: $0.uid)
        }
    }

    func selectInput(_ option: RouteOption) {
        let session = AVAudioSession.sharedInstance()
        guard let port = (session.availableInputs ?? []).first(where: { $0.uid == option.uid }) else { return }
        try? session.setPreferredInput(port)
        refreshRoutes()
    }

    // MARK: - Interruptions & route changes

    private func registerObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handleRouteChange(note) }
        })
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            engine?.pause()
            if isEngaged { status = .interrupted }
            log("Interruption began — engine paused.")
        case .ended:
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            if options.contains(.shouldResume), isEngaged {
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    try engine?.start()
                    status = .running
                    log("Interruption ended — engine resumed.")
                } catch {
                    status = .error("Resume failed: \(error.localizedDescription)")
                }
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        refreshRoutes()
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            // e.g. the iRig / headphones were unplugged — pause to avoid feedback
            // or driving a stale route; the player can re-engage when reconnected.
            if isEngaged {
                engine?.pause()
                status = .interrupted
                log("Input/route removed — engine paused.")
            }
        case .newDeviceAvailable, .routeConfigurationChange:
            if isEngaged, let engine, !engine.isRunning {
                try? engine.start()
                if engine.isRunning { status = .running }
            }
        default:
            break
        }
    }

    // MARK: - Metering

    /// ONE main-thread timer drives both read-outs at their own rates: signal
    /// levels at ~30 Hz (slower feels disconnected from your picking hand) and
    /// the render load every 8th tick (~0.27 s, the original cadence). The load
    /// stays slow on purpose — it is `@Published` on the controller, so every
    /// observer re-renders when it changes.
    private func startMetering() {
        stopMetering()
        let interval = AudioLevelMonitor.tickInterval
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(4))
        var ticks = 0
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.levels.tick(dt: interval)
                ticks += 1
                guard ticks >= 8 else { return }
                ticks = 0
                guard let unit = self.dspUnit else { return }
                self.renderLoad = unit.lastRenderLoad
                self.lastBlockSeconds = unit.lastBlockSeconds
            }
        }
        timer.resume()
        meterTimer = timer
    }

    private func stopMetering() {
        meterTimer?.cancel()
        meterTimer = nil
        // Don't leave the meters frozen mid-swing showing a level nothing is
        // measuring any more.
        levels.reset()
    }

    // MARK: - Permission / instantiation helpers

    static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in cont.resume(returning: granted) }
        }
    }

    static func instantiateDSPUnit() async throws -> AVAudioUnit {
        StreetRigDSPUnit.registerIfNeeded()
        return try await withCheckedThrowingContinuation { cont in
            // Instantiate the app-private IN-PROCESS handle (`srdi`), NOT the
            // public `srds`. With the AUv3 appex installed, `srds` + options []
            // resolves to the out-of-process extension on iOS (no `.loadInProcess`
            // on iOS), which would fail the `auAudioUnit as? StreetRigDSPUnit`
            // cast the standalone graph relies on. See `inProcessComponentDescription`
            // (§8 registration coexistence).
            AVAudioUnit.instantiate(with: StreetRigDSPUnit.inProcessComponentDescription, options: []) { unit, error in
                if let unit { cont.resume(returning: unit) }
                else { cont.resume(throwing: error ?? NSError(domain: "AudioEngineController", code: -3)) }
            }
        }
    }

    // MARK: - Logging

    nonisolated func log(_ message: String) {
        print("[StreetRigAudio] \(message)")
    }
}
