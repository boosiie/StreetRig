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
    private var observers: [NSObjectProtocol] = []

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

    private func startMetering() {
        stopMetering()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let unit = self.dspUnit else { return }
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
