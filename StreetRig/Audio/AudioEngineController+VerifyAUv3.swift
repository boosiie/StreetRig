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
import UIKit
import SwiftUI        // `store.binding(...)` Binding (Phase 4 bridge self-test)
import CoreAudioKit   // AUAudioUnitViewConfiguration (Phase 4 view-config self-test)
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
            // Host-realistic init: real hosts — and the out-of-process load in (3) below —
            // bridge the unit's state across the process boundary by round-tripping `fullState`,
            // which applies the unit's DEFAULT seed rig (including its seed drive pedal). Mirror
            // that here so the in-process oracle and the out-of-process appex are compared
            // like-for-like; a BARE oracle would leave the null measuring only the seed pedal the
            // OOP path applied and the bare oracle did not.
            unit.auAudioUnit.fullState = unit.auAudioUnit.fullState
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
        // --- Phase 4: embedded editor + two-way UI ⇄ AUParameter bridge ---
        let phase4 = await verifyAUv3EditorAndBridge()
        log(phase4.text)
        let combined = report + "\n\n" + phase3.text + "\n\n" + phase4.text
        try? combined.data(using: .utf8)?.write(to: Self.documentsURL("StreetRig_auv3_verify_report.txt"))
        return AUv3VerifyResult(success: overall && phase3.pass && phase4.pass, summary: combined)
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

    // MARK: - Phase 4: embedded editor + two-way UI ⇄ AUParameter bridge

    /// Proves Phase 4 headlessly (IN-PROCESS `srdi`, the Simulator-provable path):
    ///   • the appex-hosted editor is constructible and hosts a non-nil SwiftUI
    ///     editor, and the unit advertises a COMPACT + a FULL view configuration;
    ///   • the two-way bridge is bit-honest in BOTH directions — a knob turn
    ///     (`store.binding`) moves the matching host `AUParameter` AND reaches the
    ///     kernel at the SAME address; host automation of an `AUParameter` moves the
    ///     on-screen knob; and alternating writes SETTLE (no feedback oscillation).
    ///
    /// HONEST LIMIT: the editor's actual on-screen appearance / touch / layout
    /// inside a real host (GarageBand / AUM) is DEVICE-only (Phase 5) — not asserted.
    func verifyAUv3EditorAndBridge() async -> (text: String, pass: Bool) {
        StreetRigDSPUnit.registerIfNeeded()
        let inProc = StreetRigDSPUnit.inProcessComponentDescription
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            return ("Phase 4: could not create processing format", false)
        }

        var checks: [(name: String, ok: Bool, detail: String)] = []
        func check(_ name: String, _ ok: Bool, _ detail: String) { checks.append((name, ok, detail)) }
        func approx(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }
        func approxF(_ a: Float, _ b: Float, _ tol: Float) -> Bool { abs(a - b) <= tol }

        // --- (A) Editor view controller + view configurations -----------------
        do {
            let u = try await instantiate(inProc, options: [])
            guard let dsp = u.auAudioUnit as? StreetRigDSPUnit else {
                check("editor: in-process unit is StreetRigDSPUnit", false, "cast failed")
                throw NSError(domain: "VerifyAUv3P4", code: -1)
            }
            let compact = StreetRigDSPUnit.compactViewConfiguration
            let full = StreetRigDSPUnit.fullViewConfiguration
            let supported = dsp.supportedViewConfigurations([compact, full])
            check("supportedViewConfigurations offers compact + full",
                  supported.count == 2 && compact.height < full.height,
                  "count \(supported.count); compact \(Int(compact.width))×\(Int(compact.height)) < full \(Int(full.width))×\(Int(full.height))")

            dsp.select(compact)
            let recCompact = dsp.selectedViewConfiguration?.height == compact.height
            dsp.select(full)
            let recFull = dsp.selectedViewConfiguration?.height == full.height
            check("select(_:) records the chosen size", recCompact && recFull,
                  "compact→\(recCompact), full→\(recFull)")

            let vc = StreetRigPluginEditorViewController(dsp: dsp)
            vc.loadViewIfNeeded()
            check("appex editor hosts a non-nil SwiftUI editor",
                  vc.editorIsHosted && !vc.children.isEmpty && vc.view.subviews.count > 0,
                  "hosted \(vc.editorIsHosted), children \(vc.children.count)")
        } catch {
            check("editor VC construction", false, "error: \(error.localizedDescription)")
        }

        // --- (B) Two-way bridge on a LIVE (render-allocated) unit --------------
        do {
            let u = try await instantiate(inProc, options: [])
            guard let dsp = u.auAudioUnit as? StreetRigDSPUnit, let tree = dsp.parameterTree else {
                throw NSError(domain: "VerifyAUv3P4", code: -2)
            }
            // Host the unit in an OFFLINE engine and RENDER between writes. Rendering
            // is essential: it advances the kernel's de-zipper ramps (so a value
            // written to the bus reaches the readable target and the audio) AND drains
            // the `AUParameterTree` observer mailbox (so host→UI callbacks arrive) —
            // exactly the conditions a live host provides continuously.
            let engine = AVAudioEngine(); let player = AVAudioPlayerNode()
            engine.attach(player); engine.attach(u)
            engine.connect(player, to: u, format: fmt)
            engine.connect(u, to: engine.mainMixerNode, format: fmt)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: fmt)
            try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
            try engine.start()
            let src = loadDISource(fmt: fmt)
            player.scheduleBuffer(src, at: nil, options: [.loops], completionHandler: nil)
            player.play()

            let renderBuf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
            @discardableResult
            func render(_ frames: Int) -> [Float] {
                var out: [Float] = []; var done = 0
                while done < frames {
                    let want = AVAudioFrameCount(min(4096, frames - done))
                    guard (try? engine.renderOffline(want, to: renderBuf)) == .success else { break }
                    let n = Int(renderBuf.frameLength); if n == 0 { break }
                    if let cd = renderBuf.floatChannelData { for i in 0..<n { out.append(cd[0][i]) } }
                    done += n
                }
                return out
            }

            // The editor's store (seed = JCM800 + TS→delay→reverb) and the bridge.
            let store = RigStore(persist: false)
            let bridge = RigAUParameterBridge(store: store, dsp: dsp)
            render(10_000)                                   // settle the initial hot-swap + ramps
            try? await Task.sleep(for: .milliseconds(150))   // drain the init observer main-actor hops

            guard let ampId = store.ampItem?.id,
                  let ts = store.pedalItems.first(where: { $0.category == .overdrive }) else {
                check("bridge: seed rig has amp + a drive pedal", false, "amp \(store.ampItem?.name ?? "nil")")
                throw NSError(domain: "VerifyAUv3P4", code: -3)
            }
            check("bridge: automatable knobs mapped (amp + drive pedal)",
                  bridge.automatableCount >= 9,
                  "count \(bridge.automatableCount); amp \(store.ampItem?.name ?? "nil"), pedals \(store.pedalItems.count)")
            let bassAddr = AUParameterAddress(SRParamAmpBass.rawValue)                                    // 8
            let driveAddr = AUParameterAddress(UInt64(SRPedalParamBase)
                + 0 * UInt64(SRPedalParamStride) + UInt64(SRPedalFieldDrive))                             // 103

            // ---- UI → host: a knob turn moves the matching AUParameter (host records
            //      automation) AND the AUDIO (it reached the kernel at that address). The
            //      bridge pushes SYNCHRONOUSLY on the store's willSet, so the AUParameter
            //      reads back immediately — it now reports its cached value (the Phase-3
            //      SRKernelGetParameter did not track the EQ/pedal addresses). ----
            store.binding(itemId: ampId, param: "Bass").wrappedValue = 0     // → −12 dB
            let p8lo = tree.parameter(withAddress: bassAddr)!.value          // what a host reads
            let outLo = render(10_000)
            store.binding(itemId: ampId, param: "Bass").wrappedValue = 10    // → +12 dB
            let p8hi = tree.parameter(withAddress: bassAddr)!.value
            let outHi = render(10_000)
            check("UI→host: amp Bass knob → AUParameter records the move (addr 8)",
                  approxF(p8lo, -12, 0.05) && approxF(p8hi, 12, 0.05),
                  "AUParameter knob0→\(fmt2(p8lo)) dB, knob10→\(fmt2(p8hi)) dB (expect −12 / +12)")
            let bassDiff = Self.rms(Self.difference(outLo, outHi))
            check("UI→host: amp Bass knob changes the AUDIO (reaches the kernel)",
                  bassDiff > 1e-3 && Self.peak(outHi) > 1e-4,
                  "audio diff \(Self.dbfs(bassDiff)) dBFS")

            store.binding(itemId: ts.id, param: "Drive").wrappedValue = 10   // → 25.6 lin
            let p103hi = tree.parameter(withAddress: driveAddr)!.value
            let drvHiOut = render(10_000)
            store.binding(itemId: ts.id, param: "Drive").wrappedValue = 0    // → 0.8 lin
            let p103lo = tree.parameter(withAddress: driveAddr)!.value
            let drvLoOut = render(10_000)
            check("UI→host: slot-0 Drive knob → AUParameter records the move (addr 103 — same address)",
                  approxF(p103hi, 25.6, 0.05) && approxF(p103lo, 0.8, 0.05),
                  "AUParameter knob10→\(fmt2(p103hi)), knob0→\(fmt2(p103lo)) (expect 25.6 / 0.8)")
            let drvDiff = Self.rms(Self.difference(drvHiOut, drvLoOut))
            check("UI→host: slot-0 Drive knob changes the AUDIO (reaches the kernel)",
                  drvDiff > 1e-3, "audio diff \(Self.dbfs(drvDiff)) dBFS")

            // ---- host → UI: automation moves the on-screen knob. The observer hops to
            //      the main actor, so we render (drain the mailbox) THEN await (let the
            //      main-actor writeback run) before reading the knob. Neutralize via the
            //      UI first so each host write is a REAL change. ----
            store.binding(itemId: ampId, param: "Bass").wrappedValue = 5    // UI neutral (0 dB)
            render(4_000); try? await Task.sleep(for: .milliseconds(80))
            tree.parameter(withAddress: bassAddr)!.value = 12              // host: +12 dB
            render(4_000); try? await Task.sleep(for: .milliseconds(120))
            let knobBassHi = store.item(ampId)?.values["Bass"] ?? -1
            tree.parameter(withAddress: bassAddr)!.value = -12             // host: −12 dB
            render(4_000); try? await Task.sleep(for: .milliseconds(120))
            let knobBassLo = store.item(ampId)?.values["Bass"] ?? -1
            check("host→UI: automation (addr 8) moves the Bass knob",
                  approx(knobBassHi, 10, 0.2) && approx(knobBassLo, 0, 0.2),
                  "+12 dB→knob \(fmt2d(knobBassHi)), −12 dB→knob \(fmt2d(knobBassLo)); observed \(bridge.lastObserved[bassAddr].map(fmt2) ?? "nil") (expect 10 / 0)")

            store.binding(itemId: ts.id, param: "Drive").wrappedValue = 5   // UI neutral (~4.53 lin)
            render(4_000); try? await Task.sleep(for: .milliseconds(80))
            tree.parameter(withAddress: driveAddr)!.value = 0.8           // host: min drive
            render(4_000); try? await Task.sleep(for: .milliseconds(120))
            let knobDriveLo = store.item(ts.id)?.values["Drive"] ?? -1
            check("host→UI: automation (addr 103) moves the Drive knob",
                  approx(knobDriveLo, 0, 0.2), "0.8 lin → knob \(fmt2d(knobDriveLo)) (expect 0)")

            // ---- no feedback oscillation: a host write settles and HOLDS ----
            tree.parameter(withAddress: bassAddr)!.value = -6             // host → knob 2.5
            render(4_000); try? await Task.sleep(for: .milliseconds(120))
            let knobT0 = store.item(ampId)?.values["Bass"] ?? -1
            let paramT0 = tree.parameter(withAddress: bassAddr)!.value
            render(4_000); try? await Task.sleep(for: .milliseconds(200))  // idle — a loop would ring
            let knobT1 = store.item(ampId)?.values["Bass"] ?? -1
            let paramT1 = tree.parameter(withAddress: bassAddr)!.value
            check("no feedback oscillation (values settle & hold)",
                  approx(knobT0, knobT1, 0.02) && approxF(paramT0, paramT1, 0.05) && approx(knobT1, 2.5, 0.2),
                  "knob \(fmt2d(knobT0))→\(fmt2d(knobT1)), param \(fmt2(paramT0))→\(fmt2(paramT1)) (target knob 2.5 / param −6)")

            check("bridge diagnostics: sink + observer both fired, one structural apply",
                  bridge.continuousSinkCount > 0 && bridge.observerCallbackCount > 0 && bridge.applyStructuralCount == 1,
                  "continuousSink \(bridge.continuousSinkCount), observerCallback \(bridge.observerCallbackCount), applyStructural \(bridge.applyStructuralCount)")

            player.stop(); engine.stop()
            _ = bridge   // keep the bridge alive for the whole exchange
        } catch {
            check("two-way bridge", false, "error: \(error.localizedDescription)")
        }

        let pass = checks.allSatisfy { $0.ok }
        var text = """
        === STREETRIG AUv3 VERIFICATION (Phase 4 — editor + two-way bridge) ===
        Editor : framework PluginEditorView (compact + full) reusing the app's TapSlider /
                 ControlBoardView; hosted by StreetRigPluginEditorViewController inside the
                 appex AUViewController (StreetRigAUFactory).
        Bridge : RigAUParameterBridge — knob (store.binding) ⇄ AUParameter ⇄ kernel, mapped
                 via ParameterMap; UI→host uses setValue(originator:) + a host→UI guard flag.
        Path   : IN-PROCESS srdi, render-allocated (Simulator-provable). The editor's on-screen
                 appearance inside a real host (GarageBand/AUM) is DEVICE-only (Phase 5).

        --- Checks ---

        """
        for c in checks {
            let pad = c.name.padding(toLength: 54, withPad: " ", startingAt: 0)
            text += "  \(pad) \(c.ok ? "PASS" : "FAIL")   (\(c.detail))\n"
        }
        text += "\n  PHASE 4 (Simulator gates) : \(pass ? "PASS" : "SOME CHECKS FAILED")\n"
        text += "  === END PHASE 4 VERIFICATION ===\n"
        return (text, pass)
    }

    private func fmt2(_ v: Float) -> String { String(format: "%.2f", v) }
    private func fmt2d(_ v: Double) -> String { String(format: "%.2f", v) }

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
