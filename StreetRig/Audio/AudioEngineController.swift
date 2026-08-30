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
        observeDevicePreferenceChanges()
    }

    /// Re-read the two device preferences when something else writes them.
    ///
    /// WHY THIS IS HERE. Those two lines above run ONCE, and this object lives for
    /// the whole session — so before this, a player who changed the preference on
    /// the profile page would have been obeyed only after a relaunch, while the
    /// live engine carried on with the value it read at startup. The profile page
    /// writes the same `UserDefaults` keys deliberately rather than reaching for
    /// this object; the full argument for that is at the top of `AppPreferences`,
    /// and this observer is the price it agreed to pay.
    ///
    /// The write-back in each `didSet` cannot loop: a value is only assigned here
    /// when it DIFFERS from what is held, so the resulting `set` is a no-op write
    /// of a value already on disk and the next notification finds nothing to do.
    private func observeDevicePreferenceChanges() {
        observers.append(
            NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                   object: UserDefaults.standard,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let defaults = UserDefaults.standard
                    let asks = defaults.object(forKey: Self.asksKey) as? Bool ?? true
                    let adopt = defaults.object(forKey: Self.adoptKey) as? Bool ?? true
                    if asks != self.asksAboutNewDevices { self.asksAboutNewDevices = asks }
                    if adopt != self.autoAdoptNewDevices { self.autoAdoptNewDevices = adopt }
                }
            }
        )
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

        // …and refused for the same reason the route handler refuses: the phone's own
        // mic into its own speaker is a feedback loop, and engaging onto one is the
        // same scream as unplugging into one. Refused HERE rather than only at the
        // button so every caller gets the same answer, and stated as an instruction
        // rather than an error code — the player is holding a guitar and the fix is
        // to plug the interface in or put headphones on.
        refreshRoutes()
        if !Self.isInterfaceInput(Self.liveInputPort) {
            status = .error(Self.noInterfaceStatus)
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

            // THE ONE AND ONLY PLACE THE OPEN-MIC MUTE IS DECIDED — see the function.
            //
            // Here rather than earlier because the mute is a gain on `mainMixerNode`,
            // and the connect above is what realises that node; and here rather than
            // after `start()` because a mic engine that starts unmuted screeches for
            // however long it takes the next line to run.
            applyOpenMicMute(engine: engine, reason: "engine built")

            engine.prepare()
            try engine.start()

            self.engine = engine
            self.avAudioUnit = unit
            self.dspUnit = unit.auAudioUnit as? StreetRigDSPUnit
            applyMasterLevel()
            applySpeakerComp()      // the DSP unit exists now; re-assert the route

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
            // Remember what we engaged ON, so a later route change can tell "the
            // player's interface" from "whatever iOS fell back to".
            engagedInputUID = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
            status = .running
            // NOBODY TOUCHES THE SCREEN WHILE THEY ARE PLAYING. The phone is on
            // the floor with a guitar in the way, so iOS reads a live rig as an
            // idle device and locks it mid-song. Held awake for exactly as long
            // as the engine is running, and handed straight back on teardown.
            //
            // Now asks first (profile page → Display → "Keep the screen awake").
            // The old unconditional hold was right for a phone propped in front
            // of a player and wrong for one left running on a desk, and there was
            // no way to say which. `teardown()` still clears it unconditionally —
            // releasing a hold you never took is harmless, and it means turning
            // the preference off mid-session cannot strand the screen awake.
            UIApplication.shared.isIdleTimerDisabled = AppPreferences.keepScreenAwakeEnabled
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

    /// SILENCE THE PHONE'S OWN MIC INTO THE PHONE'S OWN SPEAKER — that pair, only.
    ///
    /// Third attempt, and the two before it are the whole reason this one is shaped
    /// the way it is.
    ///
    /// The FIRST used iOS voice processing. It killed the howl and wrecked the good
    /// path with it: enabling it swaps the entire I/O unit for the speech one, at a
    /// speech sample rate with noise suppression and automatic gain, and turning it
    /// off again on a running graph does not reliably undo that. The USB interface
    /// came out sounding worse for having shared an engine with it.
    ///
    /// The SECOND muted a gain — the right mechanism — but recomputed it from the
    /// live route on every route-change notification. A USB input that drops or
    /// re-enumerates for an instant, which they do, reads as the built-in mic for
    /// that instant, and the interface inherited a gain of zero from a glitch that
    /// had nothing to do with it.
    ///
    /// So the mechanism is kept and the trigger is split in two, because the two
    /// halves of "is this a feedback loop" do not behave alike.
    ///
    /// THE INPUT HALF IS A LATCH. `openMicArmed` is decided here, once, against the
    /// port `engage()` cut the graph for, and never moves again for the life of that
    /// engine. That is safe because the engine only ever runs on the input it was
    /// engaged on — `handleRouteChange` stops it outright the moment the input UID
    /// stops matching, which is a harder guard than a mute. Nothing about the input
    /// is ever re-read from a notification, so there is no input glitch left for a
    /// gain to inherit. This is the specific thing that broke attempt two.
    ///
    /// THE OUTPUT HALF IS READ LIVE, because it genuinely moves under a running
    /// engine: pulling the headphones hands playback straight back to the speaker,
    /// and the input-UID guard never fires for an output-only change. So it is read
    /// again on every route change — but ONE WAY. `enforceOpenMicMute` can only ever
    /// add a mute, never lift one. A monotonic latch cannot get stuck in the wrong
    /// state, which is exactly the failure a two-way route-following gain had.
    ///
    /// ON ANY OTHER INPUT NOTHING IS WRITTEN. Not a gain, not a 1.0, not a property.
    /// `openMicArmed` stays false for an interface session, so every path below —
    /// including the one route changes reach — returns on its first line. There is no
    /// statement an interface session can arrive at, which is the property attempt two
    /// lacked.
    ///
    /// `.builtInMic` and `.builtInSpeaker` by name. Not a whitelist of "real"
    /// interfaces: that was tried too and it blocked real ones, which is a worse
    /// failure than the bug it was written for, because it stops the app being used at
    /// all. iOS reports interfaces under more port types than a list can predict. One
    /// pairing is dangerous and both halves of it are ports that never change.
    ///
    /// What it costs is nothing real. A mic six inches from the speaker feeding it
    /// cannot make a usable guitar sound; the only thing monitoring it ever produced
    /// was the screech. Everything that is not monitoring still runs — the input
    /// meter, the pedals, the AR page, the whole rig — and on headphones, where there
    /// is no acoustic loop to break, the mic is monitored normally.
    private func applyOpenMicMute(engine: AVAudioEngine, reason: String) {
        guard Self.liveInputPort?.portType == .builtInMic else { return }
        openMicArmed = true
        enforceOpenMicMute(engine: engine, reason: reason)
    }

    /// Mute an armed open-mic session the moment it is playing out of the phone's own
    /// speaker. Called at `engage()` and on every route change after it.
    ///
    /// ONE WAY, DELIBERATELY: there is no branch here that raises a gain. Putting the
    /// headphones back does not un-mute — re-engaging does, through a fresh engine
    /// with an untouched mixer. An un-mute branch would mean a gain that follows the
    /// route in both directions, and that is precisely the shape that had to be
    /// withdrawn last time.
    private func enforceOpenMicMute(engine: AVAudioEngine, reason: String) {
        // Not a mic session, or already silent: nothing to do, and nothing written.
        guard openMicArmed, !openMicMuted else { return }
        guard AVAudioSession.sharedInstance().currentRoute.outputs
                .contains(where: { $0.portType == .builtInSpeaker }) else { return }
        engine.mainMixerNode.outputVolume = 0
        openMicMuted = true
        log("Open mic into the phone speaker (\(reason)) — output muted; the rest of the rig still runs.")
    }

    /// THE HARDWARE MOVED — re-cut the graph against whatever is there now.
    ///
    /// AVAudioEngine negotiates its I/O format ONCE, at start. Move the input
    /// route under a running engine and iOS stops the engine and drops the
    /// connections into and out of its I/O nodes: the edge cut at `engage()`
    /// describes a device that is no longer on the other end of it. Restarting
    /// without re-cutting — which is all the route handler used to do, through a
    /// `try?` that swallowed the refusal — is how switching INPUT on the play
    /// page left a panel still reading LIVE over dead meters and no sound.

    private func rewireForCurrentHardware(_ reason: String, confirmed: Bool = false) {
        guard isEngaged, let engine, let unit = avAudioUnit else { return }
        // NOT RE-DECIDED HERE, and that is the fix rather than an oversight. The mute's
        // input half is latched against the port `engage()` cut for, and by the time a
        // re-cut runs the input UID is still that same port — `handleRouteChange` stops
        // the engine outright otherwise — so that half cannot have changed. Re-asking
        // it is what withdrew the last attempt. The output half is re-asked, but from
        // `handleRouteChange`, which sees every route change including the output-only
        // ones a re-cut never hears about. The gain rides on the mixer node, which
        // survives a stop/connect/start, so a re-cut keeps whatever was decided.
        // See `applyOpenMicMute`.

        // THIS IS THE PATH THAT BLASTS YOU, and until now it was unguarded.
        //
        // It used to ask `isInterfaceInput`, which was erased to `return true` so the
        // app could be used without an interface plugged in. That erasure left the
        // guard here as DEAD CODE: every caller fell straight through to the re-cut
        // below and restarted the engine onto "the hardware that is there NOW" —
        // which, one instant after the interface is pulled, is the built-in mic six
        // inches from the speaker, at whatever gain the amp was set to.
        //
        // The engine's own configuration-change alarm reaches here DIRECTLY, without
        // passing through `handleRouteChange`, so the input-UID check that guards the
        // route path never saw this at all. That is why a guard is needed here rather
        // than only there.
        //
        // Asks the identity question instead of the category one: not "is this a real
        // interface" — a judgement that needs a list of port types nobody can predict —
        // but "is this still the exact port the player engaged on", which is a fact.
        if inputChangedUnderUs {
            stopBecauseInputChanged(reason)
            return
        }

        // AND DO NOT RESTART ONTO A ROUTE THAT MAY NOT HAVE SETTLED YET.
        //
        // The check above is only as honest as `currentRoute`, and iOS posts these
        // notifications at the START of a transition — so immediately after an unplug
        // the route can still be naming the interface that is already gone, the UID
        // matches, and the restart goes ahead into exactly the blast this is meant to
        // stop. Re-asking a moment later is the only way to know.
        //
        // Deferring costs nothing audible: iOS has ALREADY stopped the engine by the
        // time this runs, so the rig is silent either way and the only difference is
        // whether it comes back ~120 ms later or comes back screaming. The settle poll
        // calls this again with `confirmed: true` once the route has had time to
        // agree with the hardware.
        guard confirmed else {
            scheduleRouteSettle(reason)
            log("\(reason): deferring re-cut until the route settles.")
            return
        }

        // Route named nothing at all — mid-transition. Not a teardown (see
        // `inputChangedUnderUs`), but certainly not something to start an amp onto.
        guard Self.liveInputPort != nil else {
            log("\(reason): no input port yet — leaving the engine stopped.")
            return
        }
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
        // The player chose this, so nothing is owed back: a later reconnect must not
        // start the rig up underneath them. Only an unplug arms the resume.
        resumeInputUID = nil
        resumeSawPortLeave = false
        log("Live engine stopped.")
    }

    private func teardown() {
        UIApplication.shared.isIdleTimerDisabled = false
        stopMetering()
        wiredInputFormat = nil
        // The engine — and with it the mixer node holding the gain — is discarded
        // below, so the next `engage()` starts from an untouched 1.0 and decides
        // again from scratch.
        openMicMuted = false
        openMicArmed = false
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

    /// Assign only on a real change.
    ///
    /// `@Published` fires `objectWillChange` on EVERY assignment, equal or not, and
    /// `refreshRoutes()` is about to be called five more times after each route change
    /// while the route settles. Written straight through, that is five extra SwiftUI
    /// invalidation passes per unplug for values that mostly did not move — on a view
    /// tree that is redrawing meters at frame rate. Guarding the writes makes a
    /// no-change re-read genuinely free, which is what makes the settle poll below
    /// affordable.
    private func publish<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AudioEngineController, T>,
                                       _ value: T) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }

    func refreshRoutes() {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        publish(\.availableInputs, (session.availableInputs ?? []).map {
            RouteOption(name: $0.portName, uid: $0.uid)
        })

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

        publish(\.currentInputName, pendingInputName ?? routeInput?.portName ?? "—")
        publish(\.currentOutputName, route.outputs.first?.portName ?? "—")

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
        publish(\.grantedSampleRate, session.sampleRate)
        publish(\.grantedIOBufferDuration, session.ioBufferDuration)
        publish(\.grantedInputLatency, session.inputLatency)
        publish(\.grantedOutputLatency, session.outputLatency)
        publish(\.outputIsWireless, Self.wirelessPort(route.outputs.first?.portType))
        publish(\.outputIsPhoneSpeaker, route.outputs.first?.portType == .builtInSpeaker)
        publish(\.inputIsBuiltInMic, routeInput?.portType == .builtInMic)
        applySpeakerComp()
        detectNewDevices(session)
    }

    /// THE ROUTE IS NOT SETTLED WHEN THE NOTIFICATION SAYS IT IS.
    ///
    /// iOS posts `routeChangeNotification` at the START of a transition, and
    /// `currentRoute` / `availableInputs` catch up some unspecified time afterwards —
    /// tens of milliseconds for a wired unplug, well over a second for Bluetooth
    /// tearing down or a USB interface enumerating. Reading them synchronously in the
    /// handler, which is all this did, gets the values from BEFORE the change; and
    /// since the only thing that re-reads them is the next notification, a plug event
    /// with no follow-up leaves the panel naming a port that is already gone. That is
    /// the "takes a while to update" — it was never slow, it read once and read early.
    ///
    /// So the route is re-read across a settle window instead of once. Each pass is a
    /// no-op unless something actually moved, because every write goes through
    /// `publish` above.
    ///
    /// THIS ALSO CARRIES THE MUTE, and that is the half that matters. `enforceOpenMicMute`
    /// decides from the OUTPUT route, so a stale read is not merely a cosmetic lag: pull
    /// the headphones on an open mic and the route can still name them at notification
    /// time, the speaker check declines, and the screech starts anyway. Re-asking as the
    /// route settles closes that window. Safe to re-ask precisely because the mute is
    /// one-way — see `enforceOpenMicMute`.
    private func refreshRouteState(_ reason: String, confirmed: Bool = false) {
        refreshRoutes()
        guard isEngaged else {
            // Not running. The one thing worth doing here is noticing that the port
            // taken away mid-session has come back.
            attemptResume(reason)
            return
        }

        // The mute first. It is one-way and costs nothing, and if the output has
        // landed on the speaker the rig should go quiet before anything else is
        // decided about it.
        //
        // `applyOpenMicMute` rather than `enforceOpenMicMute`, so the INPUT half can
        // arm late as well. A graph cut while the route was still settling can start
        // on the built-in mic while `currentRoute` is still naming the interface that
        // left; the arming read at `engage()` then said "not a mic" and the session
        // ran unmuted. Re-asking here catches it on the next settle pass.
        //
        // Safe to re-ask because arming is ONE-WAY: `applyOpenMicMute` sets the latch
        // only on a positive `.builtInMic` reading and has no branch that clears it.
        // It can only ever become more protective, never less, so the glitch that
        // withdrew attempt two — a gain following the route DOWN — has no path here.
        if let engine { applyOpenMicMute(engine: engine, reason: reason) }

        // Then the input. A route that has NOW settled onto a different port than the
        // one engaged on is the unplug arriving late — the case where the notification
        // fired before `currentRoute` caught up, so the check at notification time saw
        // the interface still there and waved it through.
        if inputChangedUnderUs {
            stopBecauseInputChanged(reason)
            return
        }

        // And finally the re-cut that was deferred until the route could be trusted.
        // Only from a settle pass: called with the notification's own early read this
        // would restart onto exactly the unsettled route the deferral exists to avoid.
        if confirmed { rewireForCurrentHardware(reason, confirmed: true) }
    }

    /// Cumulative: ~0.12s, 0.37s, 0.87s, 1.87s, 3.37s. Front-loaded so a wired unplug
    /// looks instant, with a long tail for Bluetooth, which is genuinely that slow.
    private static let routeSettleDelays: [Int] = [120, 250, 500, 1000, 1500]

    /// Re-read the route repeatedly while it settles. Replaces any window already in
    /// flight: a second unplug during the first one restarts the clock rather than
    /// stacking two pollers.
    private func scheduleRouteSettle(_ reason: String) {
        routeSettleTask?.cancel()
        routeSettleTask = Task { [weak self] in
            for delay in Self.routeSettleDelays {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.refreshRouteState("\(reason) settling", confirmed: true)
            }
        }
    }

    private var routeSettleTask: Task<Void, Never>?

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

    /// True when the rig is coming out of the PHONE'S OWN SPEAKER — which is how
    /// this app is meant to be used: phone on the floor, no headphones. That
    /// driver makes almost nothing below a few hundred Hz, so the kernel switches
    /// on a compensation stage that clears the sub-bass out of the limiter's way
    /// and lifts the band the speaker is good at. Strictly route-following: a
    /// wired output or an interface gets the full-range signal untouched.
    @Published private(set) var outputIsPhoneSpeaker = false
    /// The input is the phone's own microphone.
    @Published private(set) var inputIsBuiltInMic = false

    /// The output is muted because this session engaged on the phone's own mic.
    ///
    /// Published so the panel can SAY so. A player who presses PROCEED, watches the
    /// input meter move and hears nothing has been handed a broken app unless
    /// something on screen explains the silence — see `applyOpenMicMute` for why the
    /// silence is deliberate. Latched at `engage()` and cleared at teardown; it never
    /// moves under a running engine.
    @Published private(set) var openMicMuted = false

    /// This session engaged on the phone's own mic, so the output half is worth
    /// watching. Latched in `applyOpenMicMute` and never re-read from a route — it
    /// is what keeps an interface session from reaching a gain write at all.
    private var openMicArmed = false

    /// THE ONE ROUTE THIS APP MUST NEVER RUN: the phone's own microphone into the
    /// phone's own speaker.
    ///
    /// It is an acoustic loop with a cranked amp sim inside it, and it does not
    /// settle at some unpleasant-but-survivable level — it screams, instantly, at
    /// whatever the speaker can produce. Unplugging the interface mid-session lands
    /// exactly here: the interface stops being the input, iOS falls back to the
    /// built-in mic, and the speaker is already the output.
    ///
    /// There WAS a guard for this, on the `.oldDeviceUnavailable` route-change
    /// reason, and it did not hold — an unplug also produces reasons that route
    /// through `rewireForCurrentHardware`, which happily rebuilt the graph onto the
    /// hardware "that is there NOW", mic and speaker included. Asking WHY the route
    /// changed was the mistake. This asks what the route IS, so no reason code,
    /// ordering, or future notification can get past it.
    ///
    /// STILL UNREFERENCED, and deliberately so now: both halves of this are derived
    /// from the live route, and reading the INPUT half from the route on every change
    /// is the bug that withdrew the second mute attempt. The guard that replaced it
    /// splits the pair — a latched input half, a one-way live output half — in
    /// `applyOpenMicMute` / `enforceOpenMicMute`. Kept because it names the dangerous
    /// pairing more clearly than anything else here; do not wire it to a gain.
    var isFeedbackRoute: Bool { inputIsBuiltInMic && outputIsPhoneSpeaker }

    /// Whether an input port is a real instrument interface rather than a microphone.
    ///
    /// THE RULE THAT REPLACES SIX FAILED GUARDS. Every one of them tried to catch the
    /// dangerous MOMENT — this route-change reason, that route pairing, an input UID
    /// that stopped matching — and every one depended on being told, in time, by a
    /// notification that the evidence says does not always come. Meanwhile the app
    /// happily monitored a microphone six inches from a speaker at gig volume.
    ///
    /// This asks about the port instead, and a port's type is simply true whenever
    /// anyone looks. An iRig or any class-compliant box comes in as `usbAudio`; a
    /// jack-in-the-side interface as `lineIn`. Everything else — and `builtInMic`
    /// above all — is a microphone, and a microphone is not what this app is for.
    ///
    /// Deliberately a WHITELIST. A blacklist has to anticipate every port iOS might
    /// fall back to, which is the same losing shape as anticipating every route-change
    /// reason. If a port is not recognisably an instrument input, it does not get
    /// monitored, and the worst case is a real interface that needs adding here —
    /// annoying, and quiet.
    static func isInterfaceInput(_ port: AVAudioSessionPortDescription?) -> Bool {
        // NIL COUNTS AS FINE TOO, and missing this is why the message came back after
        // the check was supposedly erased. `return true` was put below this guard, so
        // a real port passed — but before PROCEED the session is not active yet and
        // `currentRoute.inputs` is EMPTY, so the port is nil and the old
        // `guard let port else { return false }` still answered "not an interface"
        // and put "No instrument interface — plug one in to play" back on screen.
        // Erasing a check means erasing its nil case as well.
        // BLOCK THE MIC, ALLOW EVERYTHING ELSE. This was a whitelist of `usbAudio`
        // and `lineIn`, and it blocked a real interface — which is a worse failure
        // than the one it was written for, because it stops the app being used at
        // all. iOS reports interfaces under more port types than a list can predict,
        // and predicting the whole list is the same losing game as predicting every
        // route-change reason.
        //
        // Only one input is actually dangerous, and it is the one that never changes:
        // the phone's own microphone, inches from the phone's own speaker, which is
        // what makes the loop. Naming that single port is a fact, not a forecast.
        // ERASED ON REQUEST. This returned `port.portType != .builtInMic`, which
        // refused to monitor the phone's own microphone and put "No instrument
        // interface — plug one in to play" on screen instead. It made the app
        // untestable without an interface plugged in, which is most of the time
        // while the AR page is being worked on.
        //
        // WHAT THAT COSTS, written down because it is not obvious from here: this
        // was the ONLY live guard against the built-in mic being monitored through
        // the built-in speaker, inches apart, at playing volume — a feedback loop.
        // `isFeedbackRoute` above describes exactly that pairing and is currently
        // referenced by nothing, so it is the ready-made narrower guard if the
        // squeal turns up: block mic AND speaker together, allow mic with
        // headphones. Restoring the old behaviour is this one line.
        _ = port
        return true
    }

    /// The live route's input, right now — never a remembered one.
    static var liveInputPort: AVAudioSessionPortDescription? {
        AVAudioSession.sharedInstance().currentRoute.inputs.first
    }

    /// The route is POSITIVELY naming a different input than the one engaged on.
    ///
    /// Deliberately false when the route names nothing. Mid-transition the input list
    /// goes briefly empty, and treating that as "changed" would tear the rig down on
    /// every USB blip — the failure that made the second mute attempt unusable. An
    /// empty route is instead treated as "not yet known", which blocks a restart
    /// without killing a session that is fine.
    private var inputChangedUnderUs: Bool {
        guard let engaged = engagedInputUID, let live = Self.liveInputPort?.uid else { return false }
        return live != engaged
    }

    /// Stop, and pull the session down with it.
    ///
    /// Extracted because three separate paths now need to reach it — the route
    /// handler, the re-cut, and the settle poll — and three copies of a safety
    /// teardown is how one of them ends up subtly different from the others.
    private func stopBecauseInputChanged(_ reason: String) {
        let was = engagedInputUID ?? "none"

        // THROUGH `teardown()`, not a hand-rolled stop. The hand-rolled version left
        // `openMicMuted` set, and that is not cosmetic: `enforceOpenMicMute` early-returns
        // when it thinks it has already muted, so the NEXT engine — a fresh one, with a
        // fresh mixer sitting at 1.0 — would be waved through unmuted. An open mic into
        // the speaker at full gain, from a stale boolean. `teardown()` also drops the
        // level taps, the metering and the idle-timer hold, all of which the stop
        // path was leaking.
        teardown()
        isEngaged = false
        status = .error(Self.inputChangedStatus)

        // TAKEN AWAY, NOT GIVEN UP — so remember it. The rig was playing through this
        // exact port when it vanished, which is a different thing from the player
        // choosing to stop, and it is what lets the reconnect resume on its own.
        // `disengage()` clears this, because pressing STOP IS choosing to stop.
        resumeInputUID = was
        resumeSawPortLeave = false
        engagedInputUID = nil
        log("\(reason): input changed (\(was) → \(Self.liveInputPort?.uid ?? "none")) — engine stopped, session deactivated.")
    }

    /// The input that was taken away mid-session, held so it can be given back.
    ///
    /// Non-nil means: if this exact port reappears, carry on playing. Not any port —
    /// a different interface is a decision the player should make, and the built-in
    /// mic falling in as a substitute is the thing this whole file exists to refuse.
    private var resumeInputUID: String?

    /// A resume already in flight, so five settle passes cannot start five engines.
    private var isResuming = false

    /// The port named by `resumeInputUID` has been OBSERVED absent at least once.
    /// Until then a sighting of it means the route has not caught up, not that it
    /// came back — see `attemptResume`.
    private var resumeSawPortLeave = false

    /// PLUGGED BACK IN — PICK UP WHERE IT STOPPED.
    ///
    /// Without this the unplug guard is only half a feature: it stops the blast, and
    /// then leaves the player at a dead panel that says "press Proceed" for a rig that
    /// was playing a second ago. Losing your interface for a moment should not cost
    /// you a trip to the transport.
    ///
    /// Deliberately narrow. It resumes only the port that was taken — matched by UID,
    /// not by "something is available now" — and only when the rig was stopped BY the
    /// unplug rather than by the player. Anything else is a choice, and choices stay
    /// on the button.
    private func attemptResume(_ reason: String) {
        guard let wanted = resumeInputUID, !isResuming else { return }

        // GONE FIRST, THEN BACK. Never merely "present".
        //
        // THIS IS WHAT BLASTED. `availableInputs` is stale for a moment after an
        // unplug — the same staleness the settle window exists for — so the port that
        // just left is STILL LISTED when the first passes run. Resuming on "present"
        // therefore fired instantly, before the hardware had gone anywhere, and
        // `engage()` built an engine onto what was really the built-in mic. The mute
        // read the same stale route, saw an interface, and let it through unmuted:
        // an open mic into the speaker at playing gain.
        //
        // Presence is not evidence. A departure followed by a return is. Until this
        // has watched the port actually disappear, there is nothing to come back.
        guard availableInputs.contains(where: { $0.uid == wanted }) else {
            if !resumeSawPortLeave {
                resumeSawPortLeave = true
                log("\(reason): \(wanted) is gone — armed to resume when it returns.")
            }
            return
        }
        guard resumeSawPortLeave else { return }
        isResuming = true

        // ONE ATTEMPT PER DEPARTURE. Spending the observation here, at the moment of
        // committing, is what bounds this: if the engage below fails, the remaining
        // settle passes see a cleared flag and do NOT try again. Without it a failing
        // resume is retried by every pass in the window, and since each attempt builds
        // and STARTS an engine, a retry loop does not just spin — it multiplies the
        // exposure to the very window this is guarding. A genuine new unplug-and-return
        // re-arms it; nothing else does.
        resumeSawPortLeave = false
        log("\(reason): \(wanted) is back — resuming.")
        Task { [weak self] in
            guard let self else { return }
            // Point the session at the port that returned BEFORE engaging. iOS does
            // not necessarily route to a device just because it reappeared, and
            // resuming onto whatever it defaulted to is how "it came back on the
            // wrong input" would happen.
            if let option = self.availableInputs.first(where: { $0.uid == wanted }) {
                self.selectInput(option)
            }
            await self.engage()
            self.isResuming = false
            guard self.isEngaged else { return }   // kept armed: the next route change is a fair retry

            // AND CHECK WHERE IT ACTUALLY LANDED. Asking for a port is not the same as
            // getting it, and a resume that came up on something else — the built-in
            // mic above all — is the failure this whole path is capable of. Cheap to
            // ask, and the answer is the difference between playing and screaming.
            guard self.engagedInputUID == wanted else {
                self.stopBecauseInputChanged("Resume landed on the wrong input")
                return
            }
            self.resumeInputUID = nil
            self.resumeSawPortLeave = false
        }
    }

    static let noInterfaceStatus =
        "No instrument interface — plug one in to play"

    /// The input the player actually engaged on. Anything else arriving later is a
    /// different microphone or a different box, and monitoring it is not what they
    /// asked for — see `handleRouteChange`.
    private var engagedInputUID: String?

    /// Says what the app will DO, not what the player must do. Reconnecting the same
    /// port resumes on its own now — see `attemptResume` — so instructing them to
    /// press Proceed was both a chore and, after the resume landed, a lie.
    static let inputChangedStatus =
        "Input disconnected — plug it back in to carry on"

    static let feedbackRouteStatus =
        "Mic into speaker would feed back — plug in your interface or use headphones"

    private func applySpeakerComp() {
        dspUnit?.parameterTree?
            .parameter(withAddress: AUParameterAddress(SRParamSpeakerComp.rawValue))?
            .value = outputIsPhoneSpeaker ? 1 : 0
    }

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
        // DIAGNOSTIC. Five fixes have assumed this method runs; nothing has ever
        // confirmed it. If the unplug produces no line here, every guard hung off
        // this notification is dead code at the moment it matters, and the search
        // moves somewhere else entirely.
        let raw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 999
        log("DIAG routeChange fired reason=\(raw) engaged=\(isEngaged)")
        // Both of these run the mute's OUTPUT half and the input-changed check —
        // see `refreshRouteState`. Once now, because the notification may already be
        // telling the truth, and then again across the settle window, because it very
        // often is not.
        //
        // The output half matters here specifically: a mic session playing to
        // headphones needs no mute, but the moment those come out playback lands on
        // the speaker inches from the mic, and the input-UID check below never fires
        // because the INPUT did not change.
        //
        // This is not a return to what broke attempt two. That recomputed the whole
        // decision, INPUT included, from the live route, so a USB interface that
        // dropped for an instant read as the built-in mic for exactly that instant and
        // had its own gain pulled to zero. Here the input half is a latch set once in
        // `engage()`, so an interface session has `openMicArmed == false` and it
        // returns on its first line having written nothing — and it is one-way, so no
        // glitch can leave a gain stuck up.
        refreshRouteState("route change")
        scheduleRouteSettle("route change")

        // THE INPUT CHANGED UNDER US — STOP. Not pause, not re-cut for the new
        // hardware: stop.
        //
        // Two narrower guards were tried before this and neither held. The first
        // keyed on the `.oldDeviceUnavailable` reason, and an unplug also emits
        // reasons that route into `rewireForCurrentHardware`, which rebuilt onto
        // whatever was left. The second recognised the dangerous ROUTE — built-in mic
        // into built-in speaker — and still screamed, which means the port left
        // behind by an unplugged interface is not reporting as `.builtInMic`, or not
        // yet, at the moment this runs.
        //
        // Both were versions of the same mistake: trying to identify the situation
        // before refusing it. The fact that actually matters needs no identification
        // at all — the thing generating the sound is not the thing that was
        // generating it a moment ago, and continuing to monitor at gig volume through
        // an unknown input is never right. Whatever it turned into, it is not what
        // the player set up.
        //
        // `stop()` rather than `pause()`: pause leaves the graph attached and a later
        // route event can start it again, which is how the previous guard was
        // undone. Re-engaging is one button, and it goes through `engage()`, which
        // does its own checks.
        if isEngaged, AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid != engagedInputUID {
            stopBecauseInputChanged("Route change")
            return
        }
        // Pulling headphones out hands playback back to the earpiece; put it
        // where the player asked for it. Inert unless something needs moving.
        if isEngaged { applyOutputChoice() }
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            // e.g. the iRig / headphones were unplugged — stop rather than drive a
            // stale route; the player can re-engage when reconnected. Through the
            // shared teardown, so this cannot drift from the other two callers.
            if isEngaged { stopBecauseInputChanged("Route removed") }
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

    /// How long the output may sit pinned at full scale before this calls it
    /// feedback rather than playing.
    ///
    /// A guitar CAN sit near the top — a hard chord into a cranked amp does — but it
    /// decays. Feedback does not: the loop keeps re-feeding itself, so the level goes
    /// up and stays up. Over a second of unbroken full-tilt output is not a
    /// performance.
    private static let runawaySeconds: TimeInterval = 1.2
    private var runawayFor: TimeInterval = 0

    /// THE NET UNDER THE ROUTE GUARDS.
    ///
    /// Every guard above this one asks a question about the ROUTE — which port, which
    /// reason, which UID — and answers it from a notification that has to arrive, in
    /// time, describing the situation accurately. Two of those have already failed
    /// while the speaker was screaming, which is a bad place to be wrong.
    ///
    /// This one asks nothing about the route. It listens to what is coming out, and a
    /// signal that has been pinned at full scale for the best part of a second is not
    /// music by any route. It cannot be defeated by a port that misreports itself or a
    /// notification that arrives late, because it is not listening for either.
    /// A second-by-second picture of what is actually true while the app is making
    /// noise, so the next unplug answers the question instead of raising it.
    ///
    /// It prints the four facts that would each explain the screech and cannot be
    /// told apart from here: whether this timer is running at all, whether the engine
    /// still is, what the route ACTUALLY says right now, and how loud it is. One
    /// unplug with this on and the cause stops being a guess.
    private var diagFor: TimeInterval = 0
    private func diagHeartbeat(dt: TimeInterval) {
        diagFor += dt
        guard diagFor >= 1.0 else { return }
        diagFor = 0
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let inPort = route.inputs.first
        log("DIAG engaged=\(isEngaged) running=\(engine?.isRunning ?? false) "
          + "in=\(inPort?.portName ?? "none")/\(inPort?.portType.rawValue ?? "-") "
          + "uid=\(inPort?.uid ?? "none") engagedUID=\(engagedInputUID ?? "none") "
          + "out=\(route.outputs.first?.portType.rawValue ?? "-") "
          + "inPeak=\(Int(levels.input.peakDB)) outPeak=\(Int(levels.output.peakDB))")
    }

    /// How long the live route must keep saying "built-in mic" before this believes
    /// it. Three ticks or so — long enough that a single glitched read cannot mute a
    /// working interface, short enough to be inaudible next to the 1.2 s the runaway
    /// net takes.
    private static let openMicDebounce: TimeInterval = 0.1
    private var openMicFor: TimeInterval = 0

    /// THE MUTE, POLLED — because a notification is not guaranteed to arrive before
    /// the speaker does.
    ///
    /// This is the hole every fix so far has been standing next to. Pull the interface
    /// and iOS moves the RUNNING engine onto the built-in mic at once; the route-change
    /// notification arrives afterwards, and every guard built so far — the UID check,
    /// the settle window, the late arming — hangs off that notification. In the gap
    /// the graph is already pumping an open mic into the speaker at playing gain, and
    /// the only thing that ever stopped it was the runaway net, which by design waits
    /// 1.2 seconds. That wait IS the screech.
    ///
    /// So the route is read on the meter timer instead, thirty times a second, and it
    /// answers what the route IS rather than what an event said it would become. A
    /// notification that is late, or never comes at all, cannot get past this, because
    /// it is not waiting to be told.
    ///
    /// It only ever MUTES — through the same one-way `applyOpenMicMute` as everything
    /// else, so there is still no branch anywhere that lets a gain follow the route
    /// back up. And it is debounced, so the single glitched read that a bare poll would
    /// act on cannot silence a working interface.
    ///
    /// Deliberately not the erased route-poll that stopped the engine outright: that
    /// one made the app unusable without an interface, which is why it went. Muting
    /// leaves the mic entirely usable for testing — meters, pedals, AR, the whole rig —
    /// and only takes away the one thing that was never usable anyway.
    private func pollForOpenMic(dt: TimeInterval) {
        guard isEngaged, let engine,
              Self.liveInputPort?.portType == .builtInMic else {
            openMicFor = 0
            return
        }
        openMicFor += dt
        guard openMicFor >= Self.openMicDebounce else { return }
        applyOpenMicMute(engine: engine, reason: "polled route")
    }

    private func checkForRunaway(dt: TimeInterval) {
        guard isEngaged else { runawayFor = 0; return }

        // POLLED, NOT NOTIFIED. This is the fix the previous five were not.
        //
        // Every earlier guard hung off `routeChangeNotification`: stop on this
        // reason, refuse that route, remember the engaged input and compare on
        // change. They all share one assumption — that the notification arrives, and
        // arrives in time — and the evidence says it does not. The report that
        // settled it: the interface is out, the phone is on a charger, the app is
        // still running, and the INPUT METER IS PEGGED. That is the built-in mic
        // sitting next to the speaker, being monitored at gig volume, with every
        // event-driven guard in this file having had its chance and taken none.
        //
        // So this asks on a timer instead. Thirty times a second it reads the route
        // that IS, not the one an event said it would be. A missed notification, a
        // late one, or one that never fires cannot get past it, because it is not
        // waiting to be told.
        // ERASED ON REQUEST, along with `isInterfaceInput` above.
        //
        // This polled the live route thirty times a second and stopped the engine if
        // the input was not an interface, OR was not the exact port engaged on. With
        // the interface test gone the first half was already inert, but the second
        // half still stopped playback the moment the live input's UID differed from
        // the remembered one — which is every session that starts on the built-in
        // mic, so the check was still there from the player's side. "Input
        // disconnected — reconnect it and press Proceed" was this line.
        //
        // The comment above is worth keeping for what it records: this replaced five
        // event-driven guards that all missed, and the report that settled it was an
        // interface unplugged with the input meter pegged — the built-in mic being
        // monitored next to the speaker at gig volume. That is the failure this
        // removal re-opens, deliberately and on request, and `isFeedbackRoute` is the
        // narrower guard already written for it if the squeal turns up. Restoring
        // this is uncommenting one condition.
        // NOT "IS IT CLIPPING". That was the flaw in the first version of this net:
        // feedback is deafening in the ROOM, and a signal at −6 dBFS through a phone
        // speaker at full volume will take your head off without ever touching full
        // scale digitally. Waiting for a clip flag meant waiting for something that
        // may never come.
        //
        // Sustained loudness is the honest signature. A guitar gets here too — a big
        // chord into a cranked amp sits near the top — but it DECAYS, and this wants
        // over a second of it unbroken. A second and a bit of unrelieved full-tilt
        // output is not a chord.
        guard levels.output.peakDB > -6.0 else {
            runawayFor = 0
            return
        }
        runawayFor += dt
        guard runawayFor >= Self.runawaySeconds else { return }
        runawayFor = 0
        engine?.stop()
        isEngaged = false
        engagedInputUID = nil
        status = .error(Self.runawayStatus)
        log("Output pinned at full scale for \(Self.runawaySeconds)s — engine stopped (feedback).")
    }

    static let runawayStatus =
        "Stopped — that was feedback. Check your input and output before starting again."

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
                self.diagHeartbeat(dt: interval)
                self.pollForOpenMic(dt: interval)
                self.checkForRunaway(dt: interval)
                trimTicks += 1
                // Auto-trim RAISES gain on a quiet input. Pointed at a built-in mic
                // that is hearing its own speaker, that is an amplifier wired into a
                // feedback loop — it winds the level up until the room screams.
                //
                // The comment here used to say this "only runs while the engaged input
                // is still the one on the route, which the check above now enforces
                // every tick" — and that check was erased along with `isInterfaceInput`,
                // taking this guarantee with it silently. So an unplug left auto-trim
                // climbing on the built-in mic: not merely failing to prevent the
                // screech but feeding it. The condition is restored here, locally, where
                // it cannot be removed by deleting something elsewhere.
                if trimTicks >= 15 {
                    trimTicks = 0
                    if !self.inputChangedUnderUs && !self.openMicMuted { self.adjustInputTrim() }
                }
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
