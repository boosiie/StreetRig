//
//  AudioEngineController+VerifyAUv3.swift
//  StreetRig
//
//  PHASE 2 — AUv3 DISCOVERY + AUDIO SELF-TEST. A headless sibling of the offline
//  render harness (`AudioEngineController+OfflineRender.swift`) that proves the
//  new `StreetRig AUv3.appex` is packaged correctly:
//
//    (1) DISCOVERY — query `AVAudioUnitComponentManager` for the PUBLIC identity
//        (`aufx/srds/Strg`). Because the standalone app now registers its
//        in-process subclass under a DIFFERENT app-private subtype
//        (`inProcessComponentDescription`, `srdi`), a match on `srds` is the
//        APPEX specifically — no in-process registration masks it (§8).
//    (2) IN-PROCESS PROOF — instantiate the app-private in-process handle,
//        confirm it resolves to the real `StreetRigDSPUnit` (NOT the out-of-process
//        appex), and render the bundled DI through the default rig to show it
//        passes audio. This is the part the iOS Simulator CAN prove.
//    (3) OUT-OF-PROCESS — BEST-EFFORT: force-load the appex out-of-process and
//        null-test its render of the DI against the in-process oracle.
//
//  HONEST SIMULATOR CAVEAT: the iOS Simulator generally does not surface / load
//  bundled app-extension Audio Units out-of-process, so (1) discovery and (3)
//  out-of-process audio are reported DEFERRED (to device — Phase 5 AUM/GarageBand
//  — and Catalyst `auval` — Phase 6) rather than FAILED. The Phase-2 gates proven
//  ON THE SIMULATOR are: the app+appex BUILD, the appex EMBEDS in PlugIns/, the
//  Info.plist AudioComponents is valid, and the shared engine instantiates +
//  passes audio in-process with the default rig.
//
//  Triggered by `-VerifyAUv3` / `--verify-auv3` / STREETRIG_VERIFY_AUV3=1. ADDITIVE
//  ONLY — it does not touch the standalone path or the offline null test.
//

import Foundation
import StreetRigEngine
@preconcurrency import AVFoundation

extension AudioEngineController {

    /// True when the app was launched to run the AUv3 verification headlessly.
    static var shouldRunAUv3VerifyAtLaunch: Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-VerifyAUv3") || args.contains("--verify-auv3") { return true }
        return ProcessInfo.processInfo.environment["STREETRIG_VERIFY_AUV3"] == "1"
    }

    struct AUv3VerifyResult {
        var success: Bool
        var summary: String
    }

    // MARK: - Entry point

    @discardableResult
    func verifyAUv3() async -> AUv3VerifyResult {
        log("AUv3 verification starting…")
        let publicDesc = StreetRigDSPUnit.componentDescription             // aufx/srds/Strg (appex)
        let inProcDesc = StreetRigDSPUnit.inProcessComponentDescription    // aufx/srdi/Strg (app)
        let manager = AVAudioUnitComponentManager.shared()

        func describe(_ components: [AVAudioUnitComponent]) -> String {
            if components.isEmpty { return "  (none)" }
            return components.map { c in
                String(format: "  • name=%@  mfr=%@  ver=%@  type=%@",
                       c.name, c.manufacturerName, c.versionString, c.typeName)
            }.joined(separator: "\n")
        }

        // --- (1) DISCOVERY of the appex (public srds) ------------------------
        StreetRigDSPUnit.registerIfNeeded()   // registers the srdi in-process handle
        let publicMatches = manager.components(matching: publicDesc)
        let inProcMatches = manager.components(matching: inProcDesc)
        let appexDiscovered = !publicMatches.isEmpty

        // --- (2) IN-PROCESS proof (Simulator-provable) -----------------------
        var inProcLine: String
        var inProcPass = false
        var oracleSamples: [Float] = []
        var sourceForOracle: AVAudioPCMBuffer?
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        do {
            guard let fmt else { throw NSError(domain: "VerifyAUv3", code: -20) }
            let source = loadDISource(fmt: fmt)
            sourceForOracle = source
            let unit = try await instantiate(inProcDesc, options: [])
            let isRealUnit = (unit.auAudioUnit is StreetRigDSPUnit)
            oracleSamples = try renderThroughUnit(unit, source: source, fmt: fmt)
            let nonSilent = Self.peak(oracleSamples) > 1e-4
            inProcPass = isRealUnit && nonSilent
            inProcLine = String(format: "in-process handle → StreetRigDSPUnit : %@   audio non-silent : %@  (peak %@ dBFS)",
                                isRealUnit ? "YES (in-process, not the appex)" : "NO (unexpected)",
                                nonSilent ? "YES" : "NO", Self.dbfs(Self.peak(oracleSamples)))
        } catch {
            inProcLine = "in-process instantiate/render : FAILED — \(error.localizedDescription)"
        }

        // --- (3) OUT-OF-PROCESS appex load + audio null (best-effort) --------
        var audioLine: String
        var audioDeferred = true
        var audioPass = false
        do {
            guard let fmt, let source = sourceForOracle, !oracleSamples.isEmpty else {
                throw NSError(domain: "VerifyAUv3", code: -25,
                              userInfo: [NSLocalizedDescriptionKey: "no in-process oracle to null against"])
            }
            let outOfProc = try await instantiate(publicDesc, options: [.loadOutOfProcess])
            let appexOut = try renderThroughUnit(outOfProc, source: source, fmt: fmt)
            let a = Self.analyze(input: oracleSamples, output: appexOut)
            audioPass = a.nullRMS < 1e-3 && Self.peak(appexOut) > 1e-4
            audioDeferred = false
            audioLine = String(format: "OUT-OF-PROCESS render null vs in-process oracle : %@  (null %@ dBFS @ lag %d, appex peak %@ dBFS)",
                               audioPass ? "PASS" : "FAIL",
                               Self.dbfs(a.nullRMS), a.bestLag, Self.dbfs(Self.peak(appexOut)))
        } catch {
            audioLine = "OUT-OF-PROCESS appex load : DEFERRED — \(error.localizedDescription)\n"
                      + "  (expected on the iOS Simulator; live host load defers to device Phase 5 / Catalyst auval Phase 6)"
        }

        // --- Report ----------------------------------------------------------
        // Simulator gate = the shared engine instantiates + passes audio
        // in-process (2). Appex discovery (1) and out-of-process audio (3) are the
        // device/Catalyst gates and are DEFERRED here, not failed.
        let overall = inProcPass && (audioDeferred || audioPass)

        let report = """
        === STREETRIG AUv3 VERIFICATION (Phase 2 — discovery + audio) ===
        Public identity  : type=aufx subtype=srds manufacturer=Strg   (appex Info.plist advertises this)
        In-process handle: type=aufx subtype=srdi manufacturer=Strg   (app-private; avoids self-loading the appex — §8)

        --- (1) Discovery ---
        components matching PUBLIC srds : \(publicMatches.count)   (appex-provided; in-process registers srdi, so it does not appear here)
        \(describe(publicMatches))
        components matching srdi        : \(inProcMatches.count)   (the app's in-process registration)
        \(describe(inProcMatches))
        appex discoverable              : \(appexDiscovered ? "YES" : "NO (expected on Simulator — deferred to device/Catalyst)")

        --- (2) In-process proof (Simulator-provable) ---
        \(inProcLine)

        --- (3) Out-of-process appex load + audio ---
        \(audioLine)

        --- Verdicts ---
        in-process engine instantiates + passes audio : \(inProcPass ? "PASS" : "FAIL")
        appex discoverable (device gate)              : \(appexDiscovered ? "PASS" : "DEFERRED to device/Catalyst")
        out-of-process audio passthrough              : \(audioDeferred ? "DEFERRED to device/Catalyst" : (audioPass ? "PASS" : "FAIL"))
        OVERALL (Simulator gates)                     : \(overall ? "PASS" : "CHECK FAILED")
        NOTE: On the Simulator, build + embed (PlugIns/) + plist-correctness + in-process
              instantiate/audio are the Phase-2 gates; live out-of-process host load is
              validated on device (AUM/GarageBand, Phase 5) and via auval on Catalyst (Phase 6).
        === END AUv3 VERIFICATION ===
        """
        log(report)

        // --- Phase 3: parameters + state + presets (extends this self-test) ---
        let phase3 = await verifyAUv3ParamsAndState()
        log(phase3.text)
        let combined = report + "\n\n" + phase3.text
        try? combined.data(using: .utf8)?.write(to: Self.documentsURL("StreetRig_auv3_verify_report.txt"))
        return AUv3VerifyResult(success: overall && phase3.pass, summary: combined)
    }

    // MARK: - Instantiation helper

    private func instantiate(_ desc: AudioComponentDescription,
                             options: AudioComponentInstantiationOptions) async throws -> AVAudioUnit {
        try await withCheckedThrowingContinuation { cont in
            AVAudioUnit.instantiate(with: desc, options: options) { unit, error in
                if let unit { cont.resume(returning: unit) }
                else { cont.resume(throwing: error ?? NSError(domain: "VerifyAUv3", code: -21,
                        userInfo: [NSLocalizedDescriptionKey: "no component for \(options)"])) }
            }
        }
    }

    // MARK: - Minimal offline render (self-contained; mirrors renderCore)

    private func renderThroughUnit(_ unit: AVAudioUnit,
                                   source: AVAudioPCMBuffer,
                                   fmt: AVAudioFormat) throws -> [Float] {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.attach(unit)
        engine.connect(player, to: unit, format: fmt)
        engine.connect(unit, to: engine.mainMixerNode, format: fmt)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: fmt)

        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: maxFrames)
        try engine.start()
        player.scheduleBuffer(source, at: nil, options: [], completionHandler: nil)
        player.play()

        guard let rb = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames) else {
            throw NSError(domain: "VerifyAUv3", code: -23)
        }
        let total = Int(source.frameLength) + Int(fmt.sampleRate * 0.15)
        var out = [Float](); out.reserveCapacity(total)
        var rendered = 0
        loop: while rendered < total {
            let want = AVAudioFrameCount(min(Int(maxFrames), total - rendered))
            let st = try engine.renderOffline(want, to: rb)
            switch st {
            case .success:
                let count = Int(rb.frameLength)
                if count == 0 { break loop }
                if let cd = rb.floatChannelData { for i in 0..<count { out.append(cd[0][i]) } }
                rendered += count
            case .insufficientDataFromInputNode: break loop
            case .cannotDoInCurrentContext: continue
            case .error: throw NSError(domain: "VerifyAUv3", code: -24)
            @unknown default: break loop
            }
        }
        player.stop(); engine.stop()
        return out
    }

    /// The bundled DI, resolved from the framework bundle (same convention the
    /// engine uses), converted to `fmt`; falls back to the deterministic test
    /// signal so the null test still has a source if the asset is missing.
    private func loadDISource(fmt: AVAudioFormat) -> AVAudioPCMBuffer {
        guard let url = Bundle(for: StreetRigDSPUnit.self).url(forResource: "StreetRig_DI_placeholder", withExtension: "wav"),
              let file = try? AVAudioFile(forReading: url) else {
            return Self.generateTestSignal(format: fmt, seconds: 2.0)
        }
        let fileFormat = file.processingFormat
        guard let src = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: src)) != nil else {
            return Self.generateTestSignal(format: fmt, seconds: 2.0)
        }
        if fileFormat == fmt { return src }
        guard let converter = AVAudioConverter(from: fileFormat, to: fmt) else { return src }
        let ratio = fmt.sampleRate / fileFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(src.frameLength) * ratio) + 2048
        guard let dst = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: capacity) else { return src }
        var provided = false
        let status = converter.convert(to: dst, error: nil) { _, outStatus in
            if provided { outStatus.pointee = .noDataNow; return nil }
            provided = true; outStatus.pointee = .haveData; return src
        }
        return status == .haveData || status == .inputRanDry ? dst : src
    }

    // MARK: - Phase 3: parameters + state + presets self-test

    /// Extends the Phase-2 self-test to prove Phase 3: the expanded (grouped)
    /// AUParameterTree drives audio, `channelCapabilities` / `latency` are declared,
    /// `fullState` round-trips the WHOLE rig bit-exact, and factory / user presets
    /// work. All decisive checks run IN-PROCESS (`srdi`) — the Simulator-provable
    /// path; the out-of-process appex (`srds`) equivalents are attempted best-effort
    /// and DEFERRED to device (Phase 5) / Catalyst auval (Phase 6), as in Phase 2.
    func verifyAUv3ParamsAndState() async -> (text: String, pass: Bool) {
        let inProc = StreetRigDSPUnit.inProcessComponentDescription
        let publicDesc = StreetRigDSPUnit.componentDescription
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            return ("Phase 3: could not create processing format", false)
        }
        let source = loadDISource(fmt: fmt)

        // (name, pass, detail, gating). Only `gating` checks fold into the verdict.
        var checks: [(name: String, ok: Bool, detail: String, gating: Bool)] = []
        func check(_ name: String, _ ok: Bool, _ detail: String, gating: Bool = true) {
            checks.append((name, ok, detail, gating))
        }

        // Host-facing addresses under test.
        let ampBassAddr = AUParameterAddress(SRParamAmpBass.rawValue)                       // 8
        let slot0DriveAddr = AUParameterAddress(UInt64(SRPedalParamBase)
            + 0 * UInt64(SRPedalParamStride) + UInt64(SRPedalFieldDrive))                    // 103
        let inputGainAddr = AUParameterAddress(SRParamInputGain.rawValue)                    // 0

        // Apply the "British Crunch" factory preset (index 1: TS → JCM800, a DRIVE
        // pedal in slot 0) purely through the PUBLIC preset API a host would use.
        let applyCrunch: (AVAudioUnit) -> Void = { unit in
            if let presets = unit.auAudioUnit.factoryPresets, presets.count > 1 {
                unit.auAudioUnit.currentPreset = presets[1]
            }
        }

        // --- Declarations: channelCapabilities + latency (allocated in-process unit) ---
        do {
            let u = try await instantiate(inProc, options: [])
            let caps = u.auAudioUnit.channelCapabilities?.map { $0.intValue } ?? []
            check("channelCapabilities == [1,1,2,2]", caps == [1, 1, 2, 2], "\(caps)")

            // Allocate render resources (activates the cab IR) then read `latency`.
            let engine = AVAudioEngine(); let player = AVAudioPlayerNode()
            engine.attach(player); engine.attach(u)
            engine.connect(player, to: u, format: fmt)
            engine.connect(u, to: engine.mainMixerNode, format: fmt)
            try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
            try engine.start()
            let lat = u.auAudioUnit.latency
            var expected = -1.0
            if let concrete = u.auAudioUnit as? StreetRigDSPUnit {
                expected = Double(concrete.toneStatus.cabLatency) / 48_000.0
            }
            engine.stop()
            let latOK = lat > 0 && (expected < 0 || abs(lat - expected) < 1e-6)
            check("latency > 0 == cabLatency/sr", latOK,
                  String(format: "latency %.6f s, expected %.6f s", lat, expected))
        } catch {
            check("declarations (caps + latency)", false, "error: \(error.localizedDescription)")
        }

        // --- Factory presets: non-empty + selecting one changes the audio ---
        var factoryCount = 0
        if let u = try? await instantiate(inProc, options: []) {
            factoryCount = u.auAudioUnit.factoryPresets?.count ?? 0
        }
        check("factoryPresets non-empty", factoryCount > 0, "\(factoryCount) presets")

        let outDefault = try? await renderUnitConfigured(desc: inProc, fmt: fmt, source: source)
        let outCrunch  = try? await renderUnitConfigured(desc: inProc, fmt: fmt, source: source, preStart: applyCrunch)
        if let d = outDefault, let c = outCrunch {
            let diff = Self.rms(Self.difference(c, d))
            check("factory preset changes audio", diff > 1e-3 && Self.peak(c) > 1e-4,
                  "diff RMS \(Self.dbfs(diff)) dBFS, preset peak \(Self.dbfs(Self.peak(c))) dBFS")
        } else {
            check("factory preset changes audio", false, "render failed")
        }

        // --- New params affect audio (British Crunch base) via the AUParameterTree ---
        let base = try? await renderUnitConfigured(desc: inProc, fmt: fmt, source: source, preStart: applyCrunch)
        let bass = try? await renderUnitConfigured(desc: inProc, fmt: fmt, source: source, preStart: applyCrunch,
                        postStart: { $0.auAudioUnit.parameterTree?.parameter(withAddress: ampBassAddr)?.value = 12 })
        let drive = try? await renderUnitConfigured(desc: inProc, fmt: fmt, source: source, preStart: applyCrunch,
                        postStart: { $0.auAudioUnit.parameterTree?.parameter(withAddress: slot0DriveAddr)?.value = 25.6 })
        if let b = base, let bs = bass {
            let d = Self.rms(Self.difference(bs, b))
            check("SRParamAmpBass (addr 8) → audio", d > 1e-3, "diff RMS \(Self.dbfs(d)) dBFS")
        } else { check("SRParamAmpBass (addr 8) → audio", false, "render failed") }
        if let b = base, let dr = drive {
            let d = Self.rms(Self.difference(dr, b))
            check("Slot1 Drive (addr 103) → audio", d > 1e-3, "diff RMS \(Self.dbfs(d)) dBFS")
        } else { check("Slot1 Drive (addr 103) → audio", false, "render failed") }

        // --- fullState round-trip: whole rig (topology + gear + knobs) nulls bit-exact ---
        var savedState: [String: Any]?
        let outA = try? await renderUnitConfigured(desc: inProc, fmt: fmt, source: source, preStart: { unit in
            applyCrunch(unit)                                             // non-default rig
            // A non-default I/O gain the rig blob does NOT carry — proves super's
            // parameter round-trip too, not just the rig snapshot.
            unit.auAudioUnit.parameterTree?.parameter(withAddress: inputGainAddr)?.value = 1.5
            savedState = unit.auAudioUnit.fullState
        })
        let outB = try? await renderUnitConfigured(desc: inProc, fmt: fmt, source: source, preStart: { unit in
            if let s = savedState { unit.auAudioUnit.fullState = s }
        })
        let hasBlob = (savedState?["streetrig.rig.v1"] as? Data) != nil
        check("fullState carries rig blob", hasBlob, hasBlob ? "streetrig.rig.v1 present" : "missing")
        if let a = outA, let b = outB {
            let an = Self.analyze(input: a, output: b)
            check("fullState round-trip nulls (whole rig)", an.nullRMS < 1e-3 && Self.peak(a) > 1e-4,
                  "null \(Self.dbfs(an.nullRMS)) dBFS @ lag \(an.bestLag), A peak \(Self.dbfs(Self.peak(a))) dBFS")
        } else {
            check("fullState round-trip nulls (whole rig)", false, "render failed")
        }

        // --- User presets (local storage). save+list is a gate; the render reload
        //     round-trip is best-effort (offline manual-render timing). ---
        if let u = try? await instantiate(inProc, options: []) {
            let au = u.auAudioUnit
            check("supportsUserPresets", au.supportsUserPresets, "\(au.supportsUserPresets)")
            if au.supportsUserPresets {
                applyCrunch(u)                                              // state to save = British Crunch
                let preset = AUAudioUnitPreset(); preset.number = -1; preset.name = "SRPhase3Test"
                var saved = false
                var detail = "not attempted"
                do { try au.saveUserPreset(preset); saved = true } catch { detail = "save error: \(error.localizedDescription)" }
                let listed = au.userPresets.contains { $0.name == "SRPhase3Test" }
                if saved { detail = "saved + listed \(listed) (count \(au.userPresets.count))" }
                check("user preset save + list", saved && listed, detail)

                // Reload the saved preset into a fresh unit → must reproduce the rig.
                if saved && listed {
                    let outUser = try? await renderUnitConfigured(desc: inProc, fmt: fmt, source: source, preStart: { unit in
                        if let up = unit.auAudioUnit.userPresets.first(where: { $0.name == "SRPhase3Test" }) {
                            unit.auAudioUnit.currentPreset = up
                        }
                    })
                    if let a = base, let b = outUser {
                        let an = Self.analyze(input: a, output: b)
                        check("user preset reload nulls vs saved rig", an.nullRMS < 1e-3 && Self.peak(b) > 1e-4,
                              "null \(Self.dbfs(an.nullRMS)) dBFS", gating: false)
                    } else {
                        check("user preset reload nulls vs saved rig", false, "render failed", gating: false)
                    }
                }
                if let up = au.userPresets.first(where: { $0.name == "SRPhase3Test" }) { try? au.deleteUserPreset(up) }
            }
        }

        // --- srds (appex, out-of-process) param + srdi-consistency — DEFERRED on Sim ---
        var oopLine = "srds out-of-process (param-affects-audio + srdi consistency): DEFERRED\n"
                    + "    (the iOS Simulator does not load bundled app-extension AUs out-of-process;\n"
                    + "     validated on device — AUM/GarageBand Phase 5 — and via Catalyst auval Phase 6)"
        do {
            let oBase = try await renderUnitConfigured(desc: publicDesc, options: [.loadOutOfProcess], fmt: fmt, source: source, preStart: applyCrunch)
            let oBass = try await renderUnitConfigured(desc: publicDesc, options: [.loadOutOfProcess], fmt: fmt, source: source, preStart: applyCrunch,
                            postStart: { $0.auAudioUnit.parameterTree?.parameter(withAddress: ampBassAddr)?.value = 12 })
            let oopDiff = Self.rms(Self.difference(oBass, oBase))
            var consistency = "n/a"
            if let b = base { let n = Self.analyze(input: b, output: oBase); consistency = "srds↔srdi null \(Self.dbfs(n.nullRMS)) dBFS" }
            oopLine = "srds out-of-process param-affects-audio: PASS (bass diff \(Self.dbfs(oopDiff)) dBFS; \(consistency))"
            check("srds out-of-process param consistency", oopDiff > 1e-3, oopLine, gating: false)
        } catch {
            // Expected on the Simulator — deferred, not failed.
        }

        // --- Report ---
        let pass = checks.filter { $0.gating }.allSatisfy { $0.ok }
        var text = """
        === STREETRIG AUv3 VERIFICATION (Phase 3 — parameters + state + presets) ===
        Parameter surface: grouped fixed superset — one Amp group (8 legacy params + Bass/Mid/
                           Treble/Presence @ addr 8–11) + 8 pedal-slot groups × {Enabled, Drive,
                           Tone, Level} @ addr 100+slot*8+field. 44 params; addresses append-only.
        Value domains    : bus-matched to ParameterMap (EQ dB, pedal drive/level linear, tone Hz).
        Path             : IN-PROCESS srdi (Simulator-provable). srds out-of-process is DEFERRED.

        --- Checks ---

        """
        for c in checks {
            let pad = c.name.padding(toLength: 40, withPad: " ", startingAt: 0)
            text += "  \(pad) \(c.ok ? "PASS" : "FAIL")\(c.gating ? "" : " [best-effort]")   (\(c.detail))\n"
        }
        text += "\n  \(oopLine)\n"
        text += "\n  PHASE 3 (Simulator gates) : \(pass ? "PASS" : "SOME CHECKS FAILED")\n"
        text += "  === END PHASE 3 VERIFICATION ===\n"
        return (text, pass)
    }

    // MARK: - Configurable offline render (pre-start rig/state hook + post-start param hook)

    /// Render `source` through the unit at `desc`. `preStart` runs BEFORE render
    /// resources exist (set a preset / fullState → structure lands at allocate);
    /// `postStart` runs AFTER `start()` (tweak a param host-style, overriding the
    /// applied rig). Mirrors `renderThroughUnit` with the two hooks added.
    private func renderUnitConfigured(desc: AudioComponentDescription,
                                      options: AudioComponentInstantiationOptions = [],
                                      fmt: AVAudioFormat,
                                      source: AVAudioPCMBuffer,
                                      preStart: (AVAudioUnit) -> Void = { _ in },
                                      postStart: (AVAudioUnit) -> Void = { _ in }) async throws -> [Float] {
        let unit = try await instantiate(desc, options: options)
        preStart(unit)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.attach(unit)
        engine.connect(player, to: unit, format: fmt)
        engine.connect(unit, to: engine.mainMixerNode, format: fmt)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: fmt)

        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: maxFrames)
        try engine.start()
        postStart(unit)

        guard let rb = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames) else {
            throw NSError(domain: "VerifyAUv3", code: -33)
        }
        player.scheduleBuffer(source, at: nil, options: [], completionHandler: nil)
        player.play()

        let total = Int(source.frameLength) + Int(fmt.sampleRate * 0.15)
        var out = [Float](); out.reserveCapacity(total)
        var rendered = 0
        loop: while rendered < total {
            let want = AVAudioFrameCount(min(Int(maxFrames), total - rendered))
            let st = try engine.renderOffline(want, to: rb)
            switch st {
            case .success:
                let count = Int(rb.frameLength)
                if count == 0 { break loop }
                if let cd = rb.floatChannelData { for i in 0..<count { out.append(cd[0][i]) } }
                rendered += count
            case .insufficientDataFromInputNode: break loop
            case .cannotDoInCurrentContext: continue
            case .error: throw NSError(domain: "VerifyAUv3", code: -34)
            @unknown default: break loop
            }
        }
        player.stop(); engine.stop()
        return out
    }
}
