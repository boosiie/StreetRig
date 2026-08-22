//
//  AudioEngineController.swift
//  StreetRig
//
//  The audio ENGINE HOST: owns the AVAudioSession, the AVAudioEngine graph
//  (inputNode -> StreetRigDSPUnit -> mainMixerNode -> outputNode), the engine
//  lifecycle, interruption/route-change handling, mic permission, live route
//  enumeration for the control panel, and the OFFLINE FILE-RENDER HARNESS that
//  verifies the whole graph without a guitar plugged in. (The Simulator DOES
//  capture — it forwards the Mac's mic — so live monitoring runs there too; what
//  it can't reproduce is the iRig's real DI levels.)
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
import UIKit

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
    /// the controller (the control panel, its route zones, the AR slots, the camera
    /// preview) would re-render at that rate. Only the meter views observe this,
    /// so a level update redraws a meter and nothing else. The controller still
    /// owns its lifecycle: it installs the taps that feed it and tears them down.
    let levels = AudioLevelMonitor()

    /// Monitoring volume — the DSP's existing OUTPUT LEVEL stage (unity = 1.0).
    /// Kept here (not in a view) so it survives the signal-check screen being
    /// dismissed and re-opened, and is re-applied on every engage.
    ///
    /// DEFAULT IS +6 dB, NOT UNITY. `.measurement` mode is what keeps the DI
    /// clean — no AGC, no EQ, no noise suppression on the way in — and it costs
    /// real output level on the way out. At unity, through the phone's own
    /// speaker, the rig is too quiet to play against; doubling it is the standing
    /// start. There is another 6 dB above this on the slider, and no limiter
    /// behind it, so the clip lamp is the thing to watch on the way up.
    @Published var masterLevel: Float = 2.0 {
        didSet {
            guard masterLevel != oldValue else { return }
            applyMasterLevel()
        }
    }

    // Routes for the control panel's INPUT / OUTPUT zones.
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
    /// and every knob is bound. Call once (e.g. from the control panel's onAppear).
    func attach(store: RigStore) { rigStore = store }

    // The requested low-latency targets (the OS grants what it can).
    private let requestedSampleRate: Double = 48_000
    private let requestedIOBufferDuration: TimeInterval = 0.005   // ~5 ms

    init() {
        // Inert on purpose: no session, no engine, no notifications until the
        // player engages. Keeps SwiftUI previews and app launch side-effect free.
        // (Reading two defaults is not a side effect on the audio stack.)
        let defaults = UserDefaults.standard
        asksAboutNewDevices = defaults.object(forKey: Self.asksKey) as? Bool ?? true
        autoAdoptNewDevices = defaults.object(forKey: Self.adoptKey) as? Bool ?? true
    }

    deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: - Engage / disengage (LIVE monitoring — physical device only)

    /// Configure the session + graph and start live monitoring. On the Simulator
    /// there is no input device, so this will surface an error — that is expected
    /// and the offline harness is the Simulator verification path.
    /// Why Proceed refuses when the rig has no amp. Reported through the normal
    /// `.error` channel so the device bar's status line renders it in the
    /// established error colour (it upper-cases the message itself).
    static let noAmpStatus = "No amp in rig"

    func engage() async {
        guard !isEngaged else { return }

        // A rig whose `ampSection` no longer resolves has no amp to compile into
        // the graph, so engaging would start the engine and monitor an amp-less
        // signal with no explanation of why it sounds wrong. Refused HERE, not
        // only at the button, so every caller — the device bar AND the signal
        // check's retry — gets the same answer. Nothing has been touched yet:
        // no session, no permission prompt, no engine.
        if let rigStore, !rigStore.hasAmp {
            status = .error(Self.noAmpStatus)
            return
        }

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
            wiredInputFormat = inputFormat

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
            // NOBODY TOUCHES THE SCREEN WHILE THEY ARE PLAYING. The phone is on
            // the floor with a guitar in the way, so iOS reads a live rig as an
            // idle device and locks it mid-song. Held awake for exactly as long
            // as the engine is running, and handed straight back on teardown.
            UIApplication.shared.isIdleTimerDisabled = true
            log("Live engine started. \(latencyLine())")
        } catch {
            status = .error(error.localizedDescription)
            teardown()
            log("engage() failed: \(error.localizedDescription)")
        }
    }

    /// The format the running graph was cut for. A route change and a
    /// configuration change both land for one switch, in either order — this is
    /// what makes the second one free instead of a second glitch in the monitor.
    private var wiredInputFormat: AVAudioFormat?

    /// THE HARDWARE MOVED — re-cut the graph against whatever is there now.
    ///
    /// AVAudioEngine negotiates its I/O format ONCE, at start. Move the input
    /// route under a running engine and iOS stops the engine and drops the
    /// connections into and out of its I/O nodes: the edge cut at `engage()`
    /// describes a device that is no longer on the other end of it. Restarting
    /// without re-cutting — which is all the route handler used to do, through a
    /// `try?` that swallowed the refusal — is how switching INPUT on the play
    /// page left a panel still reading LIVE over dead meters and no sound.
    private func rewireForCurrentHardware(_ reason: String) {
        guard isEngaged, let engine, let unit = avAudioUnit else { return }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)

        // Already cut for this hardware and still running: nothing moved.
        if engine.isRunning, let wired = wiredInputFormat, wired.isEqual(format) { return }

        guard format.channelCount > 0, format.sampleRate > 0 else {
            wiredInputFormat = nil
            status = .error("No audio input available")
            log("\(reason): no usable input format — engine left stopped.")
            return
        }

        // Taps first: they belong to the old configuration, and a tap outliving
        // the node it was installed on is the classic AVAudioEngine crash.
        removeLevelTaps()
        engine.stop()
        engine.connect(input, to: unit, format: format)
        engine.connect(unit, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
            wiredInputFormat = format
            installLevelTaps(on: engine)
            status = .running
            log("\(reason) — graph re-cut for \(Int(format.sampleRate)) Hz / \(format.channelCount) ch.")
        } catch {
            wiredInputFormat = nil
            status = .error(error.localizedDescription)
            log("\(reason) — re-cut failed: \(error.localizedDescription)")
        }
    }

    func disengage() {
        teardown()
        isEngaged = false
        status = .idle
        log("Live engine stopped.")
    }

    private func teardown() {
        UIApplication.shared.isIdleTimerDisabled = false
        stopMetering()
        wiredInputFormat = nil
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
        // MODE `.default`, NOT `.measurement`. Measurement mode was chosen to keep
        // the DI untouched on the way IN — and it does — but the same switch also
        // strips the system's processing on the way OUT: the speaker EQ, the low-
        // frequency compensation, and the multiband limiting iOS runs to make a
        // 10 mm driver sound like a speaker. That is why the rig came out quiet
        // and thin no matter how much gain was thrown at it, and it is the
        // difference between this and every other music app on the phone. The
        // input processing this gives back applies to the built-in mic path, not
        // to a digital interface — which is where a guitar should be arriving.
        // A2DP allowed so AirPods can monitor.
        //
        // `.defaultToSpeaker` because the alternative is the EARPIECE: a
        // `.playAndRecord` session with nothing plugged in routes playback to the
        // little speaker you hold to your ear, which for an amp sim is a route in
        // name only. It was left off here over a feedback risk that belongs to the
        // built-in mic, not to the DI this rig is built around — and a connected
        // device still wins, so headphones and interfaces are unaffected.
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.allowBluetoothA2DP, .defaultToSpeaker])
        try? session.setPreferredSampleRate(requestedSampleRate)
        try? session.setPreferredIOBufferDuration(requestedIOBufferDuration)
        if activate {
            try session.setActive(true, options: [])
            applyPendingInput(session)
            applyOutputChoice()
            applyInputTrim(session)
        }

        grantedSampleRate = session.sampleRate
        grantedIOBufferDuration = session.ioBufferDuration
        grantedInputLatency = session.inputLatency
        grantedOutputLatency = session.outputLatency
        let route = session.currentRoute
        log("Session configured. \(latencyLine()) · in=\(route.inputs.first?.portName ?? "—") out=\(route.outputs.first?.portName ?? "—")")
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
    /// control panel can enumerate inputs before the player engages. Best-effort.
    func primeRoutes() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothA2DP])
        // Listen BEFORE engaging: plugging the iRig in is usually the thing you do
        // just before pressing Proceed, and that is exactly when being asked about
        // it is useful. The interruption handler this also installs is inert until
        // there is an engine to pause.
        registerObservers()
        refreshRoutes()
    }

    /// THE PORT THE PLAYER PICKED, held from the tap until the route agrees.
    ///
    /// `setPreferredInput` SUCCEEDS on an idle session and iOS remembers the
    /// choice — but it does not move `currentRoute`, because a session that was
    /// never activated has no live route to move. So before PROCEED the route is
    /// still naming whatever was there before, and a panel that reads only the
    /// route reports the pick as though nothing happened. That is what made the
    /// INPUT picker look dead on the rig screen and alive on the play page: same
    /// control, same code — the play page just has an active session behind it,
    /// because PROCEED engaged one on the way in.
    private var pendingInputUID: String?

    /// The pick's name, for as long as the route can't confirm it itself.
    private var pendingInputName: String? {
        pendingInputUID.flatMap { uid in availableInputs.first(where: { $0.uid == uid })?.name }
    }

    func refreshRoutes() {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        availableInputs = (session.availableInputs ?? []).map {
            RouteOption(name: $0.portName, uid: $0.uid)
        }

        let routeInput = route.inputs.first
        // Stop standing in for the route the moment it stops being blind: it has
        // caught up, the port was pulled, or the session is live — and a live
        // session's route is the only honest answer, including when iOS declined
        // the pick and opened something else.
        if let pending = pendingInputUID,
           isEngaged
            || routeInput?.uid == pending
            || !availableInputs.contains(where: { $0.uid == pending }) {
            pendingInputUID = nil
        }

        currentInputName = pendingInputName ?? routeInput?.portName ?? "—"
        currentOutputName = route.outputs.first?.portName ?? "—"

        // Re-measure latency here too: iOS re-negotiates the buffer and the port
        // latencies on every route change, so these are only meaningful once the
        // route has settled — which is exactly here.
        //
        // The sample rate is read here as well as in `configureSession`, and that
        // matters: without it the whole read-out stays hidden until the player
        // hits Proceed, which is precisely too late. Deciding whether to get off
        // the AirPods is a BEFORE-you-engage decision. These are iOS's current
        // session values rather than post-activation granted ones, so they are an
        // estimate until engaged — and then they refine in place.
        grantedSampleRate = session.sampleRate
        grantedIOBufferDuration = session.ioBufferDuration
        grantedInputLatency  = session.inputLatency
        grantedOutputLatency = session.outputLatency
        outputIsWireless = Self.wirelessPort(route.outputs.first?.portType)
        detectNewDevices(session)
    }

    // MARK: - Latency, as a number the player can see

    /// True when the OUTPUT is a wireless route. This is the single most useful
    /// fact about latency on this app and it was previously invisible: A2DP
    /// Bluetooth buffers by protocol design, and AirPlay is worse. Measured on an
    /// iPhone 17e: a 172 ms round trip, of which the output port alone was 163 ms
    /// — against 1.54 ms of input and a 5 ms buffer iOS granted in full. No amount
    /// of DSP work touches that, so an amp sim that silently routes to AirPods
    /// just feels broken. `.allowBluetoothA2DP` stays ON deliberately — monitoring
    /// wirelessly while noodling is legitimate — but the cost is now stated.
    @Published private(set) var outputIsWireless = false

    private static func wirelessPort(_ type: AVAudioSession.Port?) -> Bool {
        guard let type else { return false }
        return type == .bluetoothA2DP || type == .bluetoothLE
            || type == .bluetoothHFP || type == .airPlay
    }

    /// The DSP's own contribution, in samples — derived from the kernel rather
    /// than assumed, so it stays honest if a future block adds real latency.
    /// Today this is the cab convolver's 128-sample partition and nothing else:
    /// the delay and reverb blocks report zero, because their dry path is never
    /// delayed.
    var dspLatencySamples: Int { dspUnit?.cabLatencySamples ?? 0 }

    /// Measured round trip, milliseconds: hardware in + hardware out + the buffer
    /// the render callback runs on + the DSP's own contribution.
    var roundTripMs: Double {
        guard grantedSampleRate > 0 else { return 0 }
        let dspSeconds = Double(dspLatencySamples) / grantedSampleRate
        return (grantedInputLatency + grantedOutputLatency
                + grantedIOBufferDuration + dspSeconds) * 1_000
    }

    /// The amber line. NOT the ~15 ms textbook "playable" figure, deliberately:
    /// this app buys output processing with latency on purpose. Mode `.default`
    /// rather than `.measurement` is what gets iOS's speaker EQ and limiting —
    /// the whole difference between this and every other music app on the phone —
    /// and it was measured costing 9.73 → 15.35 ms of output latency on its own.
    /// A healthy wired rig therefore lands near 25 ms and must not read as a
    /// fault. Wireless lands near 180 ms. 40 ms separates the two with room to
    /// spare, which is the only job this threshold has.
    var latencyIsPlayable: Bool { roundTripMs > 0 && roundTripMs <= 40 }

    /// Choose the port the guitar comes in on. While the engine is idle this
    /// records a preference that iOS opens when the session goes live; while it
    /// is running the route moves under your finger.
    func selectInput(_ option: RouteOption) {
        let session = AVAudioSession.sharedInstance()
        guard let port = (session.availableInputs ?? []).first(where: { $0.uid == option.uid }) else { return }
        do {
            try session.setPreferredInput(port)
            pendingInputUID = option.uid
        } catch {
            // Not `try?`: a refusal is the one case where the panel must NOT go
            // on to name the port the player asked for.
            log("Couldn't select input \(option.name): \(error.localizedDescription)")
        }
        refreshRoutes()
    }

    /// Re-assert the pick at the one moment it can actually take — the session
    /// going active. iOS does carry a preference set while idle across the
    /// activation, but the category is re-set on the way in, so this makes the
    /// guarantee ours rather than the framework's.
    private func applyPendingInput(_ session: AVAudioSession) {
        guard let uid = pendingInputUID,
              let port = (session.availableInputs ?? []).first(where: { $0.uid == uid }) else { return }
        do { try session.setPreferredInput(port) }
        catch { log("Couldn't open the chosen input \(port.portName): \(error.localizedDescription)") }
    }

    // MARK: - Input trim: the preamp knob nobody can reach

    /// WHERE THE HARDWARE PREAMP IS SET, 0…1, when iOS lets us set it at all.
    ///
    /// Both ends of this were measured on device and both were wrong. Left alone,
    /// a guitar through the headphone-jack adapter arrived 42 dB down — so quiet
    /// the rig had to invent the difference, and the hiss with it. Turned all the
    /// way up, it pinned 0.0 dBFS on every transient against a −44 dB average:
    /// a front end clipping itself, which is where the noise came from and where
    /// the low end went, a clipped wave losing its fundamental before anything
    /// else. Neither is a setting. This walks to one and then stops.
    private var inputTrim: Float = 0.5

    /// Peaks should land here: hot enough to leave the noise behind, cold enough
    /// that a hard-picked chord still has somewhere to go. WIDE, because a guitar
    /// is: the gap between a dying note and a dug-in chord is 40 dB, and the first
    /// version of this window was narrower than that — so it chased the decay up
    /// and the strum back down, 194 times in one session, riding the gain audibly
    /// the whole way. A trim that moves while you play is worse than one set wrong.
    private static let trimTargetLowDB: Float = -20
    private static let trimTargetHighDB: Float = -8

    /// ONLY PLAYING GETS A VOTE. Measured: a window of someone playing reads a
    /// peak 30–40 dB over its own average (−10 peak on a −50 average), because
    /// notes are transients. Hiss reads about 15 dB over — it is steady, that is
    /// what makes it hiss. So the crest is what tells them apart, and it does it
    /// without caring how weak the pickup is, which an absolute threshold cannot.
    ///
    /// This is the fix for the last thing still moving on its own: the trim used
    /// to read a quiet window as "needs more gain" and walk up during the gaps —
    /// 0.66 → 0.74 on windows peaking at −51 dBFS, which is silence — then walk
    /// back down the moment a chord landed. Silence now says nothing at all.
    private static let trimPlayingCrestDB: Float = 20
    private static let trimPlayingFloorDB: Float = -45

    /// The loudest peak and loudest average since the last decision. Judging on
    /// the window rather than the instant is what makes this settle.
    private var trimWindowPeakDB: Float = AudioLevel.floorDB
    private var trimWindowRmsDB: Float = AudioLevel.floorDB
    private var trimAgreement = 0

    private func applyInputTrim(_ session: AVAudioSession) {
        guard session.isInputGainSettable else { return }
        try? session.setInputGain(inputTrim)
    }

    /// Nudge the trim toward the window, a step at a time, roughly twice a
    /// second. NOT gain-riding: this moves an ANALOG knob ahead of the converter,
    /// never the audio, and once the peaks are in the window it stops moving
    /// entirely — the deadband is the whole point. Down quickly (clipping is
    /// damage), up slowly (a quiet passage is not a reason to crank).
    private func adjustInputTrim() {
        let session = AVAudioSession.sharedInstance()
        guard isEngaged, session.isInputGainSettable else { return }
        let level = levels.input
        trimWindowPeakDB = max(trimWindowPeakDB, level.peakDB)
        trimWindowRmsDB = max(trimWindowRmsDB, level.rmsDB)
        if level.isClipping { trimWindowPeakDB = 0 }

        // Decide on the window, not on the instant — and only every few seconds.
        trimAgreement += 1
        guard trimAgreement >= 6 else { return }
        trimAgreement = 0
        let windowPeak = trimWindowPeakDB
        let windowCrest = trimWindowPeakDB - trimWindowRmsDB
        trimWindowPeakDB = AudioLevel.floorDB
        trimWindowRmsDB = AudioLevel.floorDB

        var next = inputTrim
        if windowPeak > Self.trimTargetHighDB {
            // Down on the evidence of the peak alone. Too hot is too hot whatever
            // made it, and the cost of being wrong is a clipped transient.
            next -= 0.04
        } else if windowPeak < Self.trimTargetLowDB {
            // Up only on the evidence of PLAYING. Everything else — a decaying
            // note, a gap between phrases, a room full of hiss — is quiet for
            // reasons that more gain would not improve.
            guard windowPeak > Self.trimPlayingFloorDB,
                  windowCrest > Self.trimPlayingCrestDB else { return }
            next += 0.02
        } else {
            return                             // in range — this is where it stops
        }

        next = min(1.0, max(0.05, next))
        guard abs(next - inputTrim) > 0.001 else { return }
        inputTrim = next
        try? session.setInputGain(next)
        log(String(format: "Input trim → %.2f (window peak %.1f dBFS, crest %.1f dB)",
                   next, windowPeak, windowCrest))
    }

    // MARK: - Output: the one override a session gets

    /// WHERE MONITORING COMES OUT, as far as an app is allowed to say.
    ///
    /// iOS owns which DEVICE plays — it follows headphones, an interface, AirPods
    /// — and the single override it grants a session is speaker-or-not. So that
    /// is exactly what this offers, and nothing it can't keep: `.automatic`
    /// follows whatever iOS picked, `.speaker` forces the phone's loudspeaker
    /// even over something connected.
    enum OutputChoice: String, CaseIterable, Identifiable {
        case automatic, speaker
        var id: String { rawValue }
        var label: String { self == .automatic ? "Automatic" : "Speaker" }
    }

    @Published private(set) var outputChoice: OutputChoice = .automatic

    /// Whether OUR override is the reason the speaker is playing — there is no
    /// API to ask the session, and letting go of an override we never took would
    /// throw away one the player set in Control Center.
    private var speakerOverrideApplied = false

    func selectOutput(_ choice: OutputChoice) {
        outputChoice = choice
        applyOutputChoice()
        refreshRoutes()
    }

    /// Put the route where the choice says. Only ever calls the API when
    /// something actually needs changing: every override raises a route change,
    /// which comes straight back through here, and a version of this that always
    /// called would chase its own tail.
    ///
    /// An override needs a live session, so before PROCEED this is a preference —
    /// `configureSession` applies it the moment the session goes active, the same
    /// shape as the INPUT pick.
    private func applyOutputChoice() {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        let onReceiver = outputs.contains { $0.portType == .builtInReceiver }
        let onSpeaker = outputs.contains { $0.portType == .builtInSpeaker }
        do {
            switch outputChoice {
            case .speaker:
                guard !onSpeaker else { return }
                try session.overrideOutputAudioPort(.speaker)
                speakerOverrideApplied = true
            case .automatic:
                if speakerOverrideApplied {
                    try session.overrideOutputAudioPort(.none)
                    speakerOverrideApplied = false
                }
                // The belt to `.defaultToSpeaker`'s braces: if the route still
                // lands on the earpiece — the one place nobody chose and nobody
                // wants — take the override back out and push it to the speaker.
                if onReceiver {
                    try session.overrideOutputAudioPort(.speaker)
                    speakerOverrideApplied = true
                }
            }
        } catch {
            log("Couldn't set the output route: \(error.localizedDescription)")
        }
    }

    // MARK: - New hardware: ask before switching

    /// Hardware that appeared while the app was running and that the player has
    /// not been asked about yet.
    struct DeviceOffer: Identifiable, Equatable {
        enum Kind: Equatable { case input, output }
        let kind: Kind
        let name: String
        let uid: String
        /// Kind is part of the identity: the same physical port can legitimately
        /// show up as both an input and an output (a USB interface, a headset).
        var id: String { "\(kind == .input ? "in" : "out")-\(uid)" }
    }

    /// The outstanding question, if any. Nil when there is nothing to ask.
    @Published private(set) var deviceOffer: DeviceOffer?

    /// "Don't ask me this again". Persisted.
    @Published var asksAboutNewDevices: Bool {
        didSet { UserDefaults.standard.set(asksAboutNewDevices, forKey: Self.asksKey) }
    }

    /// What to DO once we've stopped asking. The checkbox remembers the answer
    /// the player gave, not merely that they want silence: dismissing the prompt
    /// with "Use it" ticked means later devices are adopted automatically, while
    /// "Keep current" means they are ignored. Persisted.
    @Published var autoAdoptNewDevices: Bool {
        didSet { UserDefaults.standard.set(autoAdoptNewDevices, forKey: Self.adoptKey) }
    }

    private static let asksKey = "StreetRig.asksAboutNewDevices"
    private static let adoptKey = "StreetRig.autoAdoptNewDevices"

    /// Device identities already seen. Primed on the FIRST route read so whatever
    /// is already plugged in when the app opens is never announced back.
    private var knownDeviceIDs: Set<String> = []
    private var hasPrimedKnownDevices = false

    /// Diff the current route against what we've seen. Called from
    /// `refreshRoutes`, which every route change already runs through.
    private func detectNewDevices(_ session: AVAudioSession) {
        let candidates =
            (session.availableInputs ?? []).map {
                DeviceOffer(kind: .input, name: $0.portName, uid: $0.uid)
            }
            + session.currentRoute.outputs.map {
                DeviceOffer(kind: .output, name: $0.portName, uid: $0.uid)
            }
        let ids = Set(candidates.map(\.id))

        guard hasPrimedKnownDevices else {
            knownDeviceIDs = ids
            hasPrimedKnownDevices = true
            return
        }

        let fresh = candidates.filter { !knownDeviceIDs.contains($0.id) }
        knownDeviceIDs.formUnion(ids)
        guard let offer = fresh.first else { return }

        guard asksAboutNewDevices else {
            // Answer stored: act on it without interrupting.
            if autoAdoptNewDevices { adopt(offer) }
            return
        }
        // One question at a time — an unanswered offer is never replaced.
        guard deviceOffer == nil else { return }
        deviceOffer = offer
    }

    /// Answer the outstanding offer. `remember` stops the question being asked
    /// again and stores `adopt` as the standing answer.
    func resolveDeviceOffer(_ offer: DeviceOffer, adopt useIt: Bool, remember: Bool) {
        if useIt { adopt(offer) } else { decline(offer) }
        if remember {
            autoAdoptNewDevices = useIt
            asksAboutNewDevices = false
        }
        if deviceOffer == offer { deviceOffer = nil }
    }

    private func adopt(_ offer: DeviceOffer) {
        switch offer.kind {
        case .input:
            // Straight through the picker's own path — which refreshes the routes
            // itself — so "Use it" on the rig screen names the new device in the
            // panel exactly as choosing it from the INPUT menu does. It was
            // silent here for the same reason the menu was.
            selectInput(RouteOption(name: offer.name, uid: offer.uid))
        case .output:
            // iOS has ALREADY routed to the new output by the time the
            // notification lands, so "use it" means letting the session follow
            // the newest device — which is what automatic IS.
            selectOutput(.automatic)
        }
    }

    #if DEBUG
    /// Testing affordance in the same spirit as `-RunOfflineRender`: the Simulator
    /// never gains or loses hardware, so there is otherwise no way to see this
    /// prompt without a physical device. Launch with `-ShowDeviceOffer`.
    func seedDebugDeviceOffer() {
        deviceOffer = DeviceOffer(kind: .input, name: "iRig HD 2", uid: "debug-irig")
    }
    #endif

    private func decline(_ offer: DeviceOffer) {
        switch offer.kind {
        case .input:
            break   // keep whatever input is already preferred
        case .output:
            // iOS has already switched, so declining can only mean pushing
            // playback back to the phone's own speaker — which is the other
            // choice the OUTPUT zone offers, set here by the same route.
            selectOutput(.speaker)
            return
        }
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
        // THE ENGINE'S OWN ALARM, and the one nothing was listening for. iOS
        // raises it when the I/O hardware underneath a running engine changes —
        // which is precisely what choosing a different INPUT does — and by the
        // time it lands the engine has already stopped itself.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rewireForCurrentHardware("Engine configuration changed") }
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
        // Pulling headphones out hands playback back to the earpiece; put it
        // where the player asked for it. Inert unless something needs moving.
        if isEngaged { applyOutputChoice() }
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
        case .newDeviceAvailable, .routeConfigurationChange, .override:
            // The switch itself, or the iRig going back in after an unplug. One
            // answer for both: cut the graph to the hardware that is there NOW.
            // A bare `try? engine.start()` was the old answer, and it restarted
            // an engine still wired to the device that just left.
            rewireForCurrentHardware("Route changed")
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
        var trimTicks = 0
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.levels.tick(dt: interval)
                trimTicks += 1
                if trimTicks >= 15 { trimTicks = 0; self.adjustInputTrim() }
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
