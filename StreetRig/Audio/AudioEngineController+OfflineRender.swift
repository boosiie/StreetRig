//
//  AudioEngineController+OfflineRender.swift
//  StreetRig
//
//  OFFLINE FILE-RENDER HARNESS + A/B VERIFICATION. The iOS Simulator has NO audio
//  input, so this renders a known input (bundled DI or a generated test signal)
//  through the SAME custom AUAudioUnit graph in manual `.offline` mode and proves
//  the amp → cab chain works. Prompt 002 extends it into a multi-pass A/B rig:
//
//    • PASSTHROUGH  (master bypass)            → must still null vs. dry
//    • CAB ONLY     (amp bypassed)             → speaker voicing
//    • AMP ONLY (analog)                       → distortion adds harmonics
//    • AMP ONLY (neural)                       → the captured/placeholder model
//    • FULL amp → cab (written to the WAV)     → distorted + cab-voiced
//    • IMPULSE      (cab-only, unit impulse)   → convolver FFT-math self-test
//
//  For each pass it reports peak / RMS + a brightness (high-band energy) metric so
//  the distortion (harmonics up) and cab band-limiting (highs down) are visible in
//  numbers, plus the measured render-block cost and the neural per-sample cost.
//
//  Triggered by a DEBUG control-panel affordance and by `-RunOfflineRender` /
//  STREETRIG_OFFLINE_RENDER=1 for headless simctl runs. See `shouldRunOfflineRenderAtLaunch`.
//

import Foundation
import StreetRigEngine
import SwiftUI
@preconcurrency import AVFoundation

extension AudioEngineController {

    struct OfflineRenderResult {
        var success: Bool
        var summary: String
        var wavPath: String?
    }

    /// True when the app was launched to run the offline render headlessly.
    static var shouldRunOfflineRenderAtLaunch: Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-RunOfflineRender") || args.contains("--offline-render") { return true }
        return ProcessInfo.processInfo.environment["STREETRIG_OFFLINE_RENDER"] == "1"
    }

    // MARK: - Per-pass configuration + result

    /// A/B knob settings for one render pass. Mirrors the SRParameterAddress bus.
    private struct PassConfig {
        var masterBypass = false
        var ampBypass    = false
        var cabBypass    = false
        var useNeural    = false
        var drive: Float = 3.0
        var makeup: Float = 1.0
        var cabSlot      = 0
    }

    private struct PassOutput {
        var samples: [Float] = []
        var blockUs: Double = 0
        var blocks: UInt64 = 0
        var neuralLoaded = false
        var neuralError: String?
        var cabLengths: [Int] = []
        var cabLatency = 0
        var neuralNsPerSample: Double = 0
        var fullNsPerSample: Double = 0
    }

    // MARK: - Entry point

    /// Render the bundled/generated DI through the real graph in several A/B
    /// configurations, write the full-chain result to a WAV, and verify.
    @discardableResult
    func runOfflineRender() async -> OfflineRenderResult {
        log("Offline render harness starting…")
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            return finishOffline(success: false, summary: "Could not create processing format", wav: nil)
        }
        do { try? configureSession(activate: true) }

        // Source signal.
        let usingBundledDI = (loadBundledDI(targetFormat: fmt) != nil)
        let dry = loadBundledDI(targetFormat: fmt) ?? Self.generateTestSignal(format: fmt, seconds: 2.5)
        let sourceLabel = usingBundledDI
            ? "bundled DI (StreetRig_DI_placeholder.wav)"
            : "GENERATED deterministic test signal (PLACEHOLDER — swap for a real DI clip)"
        let inSamples = Self.channelSamples(dry)
        let sr = fmt.sampleRate

        do {
            // --- A/B passes through the real AU graph ---
            let passthrough = try await renderPass(source: dry, fmt: fmt) { c in c.masterBypass = true }
            let cabOnly     = try await renderPass(source: dry, fmt: fmt) { c in c.ampBypass = true }
            let ampAnalog   = try await renderPass(source: dry, fmt: fmt) { c in c.cabBypass = true; c.useNeural = false }
            let ampNeural   = try await renderPass(source: dry, fmt: fmt, benchmarkNeural: true) { c in c.cabBypass = true; c.useNeural = true }
            let full        = try await renderPass(source: dry, fmt: fmt, benchmarkFull: true) { c in c.useNeural = ampNeural.neuralLoaded }

            // --- Convolver impulse self-test (cab-only, unit impulse vs. raw IR) ---
            let impulse = try await impulseSelfTest(fmt: fmt, cabSlot: 0)

            let neuralActive = full.neuralLoaded
            let ampEngine = neuralActive ? "NEURAL capture (StreetRig_amp_placeholder.json — SYNTHETIC placeholder)"
                                         : "ANALOG fallback (4x-oversampled waveshaper + voicing)"

            // --- Write the full-chain result to a WAV in Documents ---
            let outURL = Self.documentsURL("StreetRig_offline_render.wav")
            try? Self.writeWav(full.samples, to: outURL, format: fmt)
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: outURL.path))?[.size] as? Int) ?? 0

            // --- Metrics ---
            func brightPct(_ s: [Float], _ hz: Double) -> Double { Double(Self.brightness(s, sr: sr, cutoff: hz) * 100) }
            func line(_ name: String, _ s: [Float]) -> String {
                let padded = name.padding(toLength: 17, withPad: " ", startingAt: 0)
                return "  \(padded) peak \(Self.dbfs(Self.peak(s))) dBFS   RMS \(Self.dbfs(Self.rms(s))) dBFS   |  hi>3k "
                     + String(format: "%5.1f", brightPct(s, 3000)) + "%   hi>6k "
                     + String(format: "%5.1f", brightPct(s, 6000)) + "%"
            }

            // Compare against the amp engine `full` actually used, so the cab
            // band-limit check isn't measured across two different amps.
            let ampMatch   = full.neuralLoaded ? ampNeural : ampAnalog
            let dryBright  = brightPct(inSamples, 3000)
            let ampBright  = brightPct(ampMatch.samples, 3000)
            let fullBright = brightPct(full.samples, 3000)

            let ptNull = Self.analyze(input: inSamples, output: passthrough.samples)
            let diffRMS = Self.rms(Self.difference(full.samples, inSamples))

            // Verdicts.
            let vPassthrough = ptNull.nullRMS < 1e-3
            let vNonSilent   = Self.peak(full.samples) > 1e-4
            let vTransformed = diffRMS > 1e-3
            let vHarmonics   = ampBright > dryBright + 0.5
            let vCabVoicing  = fullBright < ampBright - 0.5
            let vImpulse     = impulse.maxError < 5e-3 && impulse.correlation > 0.99
            let allPass = vPassthrough && vNonSilent && vTransformed && vHarmonics && vCabVoicing && vImpulse

            let liveDeadlineUs = 128.0 / sr * 1_000_000      // ~2667 µs live budget @128 frames
            let neuralNs = ampNeural.neuralNsPerSample
            let neuralBlockUs = neuralNs * 128 / 1000
            let fullNs = full.fullNsPerSample
            let fullBlockUs = fullNs * 128 / 1000

            let report = """
            === STREETRIG OFFLINE RENDER REPORT (prompt 002: neural amp + cabinet IR) ===
            Source        : \(sourceLabel)
            Graph         : AVAudioPlayerNode -> StreetRigDSPUnit[input -> AMP -> CAB -> output] -> mainMixer  [manual .offline]
            Format        : \(Int(sr)) Hz, \(fmt.channelCount) ch, float32
            Session grant : \(latencyLine())

            AMP ENGINE    : \(ampEngine)
              neural model loaded : \(full.neuralLoaded ? "YES" : "NO")\(full.neuralError.map { " (\($0))" } ?? "")
              → For pro tone, drop a trained GuitarML / RTNeural 'SimpleRNN' LSTM .json at
                StreetRig/Audio/Resources/StreetRig_amp_placeholder.json (same schema); the
                neural path replaces the fallback automatically. (.nam WaveNet not yet parsed.)
            CAB IRs       : slot0 v30_4x12 = \(full.cabLengths.first ?? 0) taps,  slot1 greenback_1x12 = \(full.cabLengths.count > 1 ? full.cabLengths[1] : 0) taps
              cab latency : \(full.cabLatency) samples (\(String(format: "%.2f", Double(full.cabLatency) / sr * 1000)) ms) — partitioned FFT, B=128

            --- A/B passes (peak / RMS / high-band energy fraction) ---
            \(line("dry (input)", inSamples))
            \(line("passthrough", passthrough.samples))
            \(line("cab only", cabOnly.samples))
            \(line("amp only (analog)", ampAnalog.samples))
            \(line("amp only (neural)", ampNeural.samples))
            \(line("FULL amp->cab", full.samples))

            --- Verdicts ---
            passthrough transparent : \(vPassthrough ? "PASS" : "FAIL")  (null \(Self.dbfs(ptNull.nullRMS)) dBFS @ lag \(ptNull.bestLag))
            full output non-silent  : \(vNonSilent ? "PASS" : "FAIL")  (peak \(Self.dbfs(Self.peak(full.samples))) dBFS)
            full != dry (changed)   : \(vTransformed ? "PASS" : "FAIL")  (diff RMS \(Self.dbfs(diffRMS)) dBFS)
            amp adds harmonics      : \(vHarmonics ? "PASS" : "FAIL")  (hi>3k: dry \(String(format: "%.1f", dryBright))% -> amp \(String(format: "%.1f", ampBright))%)
            cab band-limits         : \(vCabVoicing ? "PASS" : "FAIL")  (hi>3k: amp \(String(format: "%.1f", ampBright))% -> full \(String(format: "%.1f", fullBright))%)
            convolver impulse test  : \(vImpulse ? "PASS" : "FAIL")  (max|out-IR| \(String(format: "%.2e", Double(impulse.maxError))), corr \(String(format: "%.4f", Double(impulse.correlation))) @ lag \(impulse.lag))

            --- Render cost (per-sample benchmarks → projected to the 128-frame LIVE block) ---
            FULL amp->cab     : \(String(format: "%.1f", fullNs)) ns/sample -> \(String(format: "%.1f", fullBlockUs)) µs / 128-frame block = \(String(format: "%.2f", fullBlockUs / liveDeadlineUs * 100))% of the ~\(String(format: "%.0f", liveDeadlineUs)) µs LIVE budget
            neural amp only   : \(String(format: "%.1f", neuralNs)) ns/sample -> \(String(format: "%.1f", neuralBlockUs)) µs / 128-frame block = \(String(format: "%.2f", neuralBlockUs / liveDeadlineUs * 100))% (dominant cost; cab convolution is the remainder)
            offline last block: full \(String(format: "%.1f", full.blockUs)) µs | cab-only \(String(format: "%.1f", cabOnly.blockUs)) µs | passthrough \(String(format: "%.1f", passthrough.blockUs)) µs  (variable block size, faster-than-real-time — informational)
            render blocks     : \(full.blocks) buffers processed by the kernel (full pass)

            WAV           : \(outURL.path)  (\(bytes) bytes)  [FULL amp->cab pass]
            OVERALL       : \(allPass ? "PASS" : "SOME CHECKS FAILED")
            === END REPORT ===
            """
            log(report)

            // --- PROMPT 003: assemble + verify the FULL compiled rig chain. ---
            let rig = await runRigVerification(dry: dry, fmt: fmt, sr: sr)
            // The deliverable WAV is the actual on-screen rig played through the chain.
            if !rig.wav.isEmpty { try? Self.writeWav(rig.wav, to: outURL, format: fmt) }
            // --- PEDAL FAMILIES: prove each NEW structural family is audible. ---
            let fam = await runPedalFamilyVerification(dry: dry, fmt: fmt, sr: sr)
            // --- SIGNAL METERS: prove the dBFS math against known amplitudes. ---
            let meter = runMeterVerification(sr: sr)
            // --- AR FOOTSWITCHES: prove a stomp actually bypasses a pedal. ---
            let foot = await runFootswitchVerification(dry: dry, fmt: fmt, sr: sr)
            // --- AMP PROFILES: prove every amp is a different amp. ---
            let amps = await runAmpProfileVerification(dry: dry, fmt: fmt, sr: sr)
            // --- TIME BLOCKS: delay + reverb + the Katana's FX section. ---
            let timeBlocks = await runTimeBlockVerification(dry: dry, fmt: fmt, sr: sr)
            // --- LEGACY REFERENCE: the fixed pole of the cross-build null test. ---
            let legacy = await runLegacyNullReference(fmt: fmt)
            let legacyText = """
            === LEGACY BACK-COMPAT REFERENCE (amp with no profile) ===
            Method        : pinned plan — unrecognized amp name (→ AmpVoicing::Legacy), no pedals,
                            cab BYPASSED, neural off, generated test signal, off-centre EQ.
            \(legacy.text)
            LEGACY REFERENCE OVERALL: \(legacy.pass ? "PASS" : "FAIL")
            === END LEGACY REFERENCE ===
            """
            let combined = [report, rig.text, fam.text, meter.text, foot.text,
                            amps.text, timeBlocks.text, legacyText].joined(separator: "\n\n")
            let overall = allPass && rig.pass && fam.pass && meter.pass && foot.pass
                && amps.pass && timeBlocks.pass && legacy.pass
            log(combined)
            return finishOffline(success: overall, summary: combined, wav: outURL.path)
        } catch {
            let msg = "Offline render failed: \(error.localizedDescription)"
            log(msg)
            return finishOffline(success: false, summary: msg, wav: nil)
        }
    }

    // MARK: - Render one pass through the real AU graph

    /// A/B pass configured by the prompt-002 `PassConfig` (bypasses + drive/makeup).
    private func renderPass(source: AVAudioPCMBuffer,
                            fmt: AVAudioFormat,
                            tailSeconds: Double = 0.15,
                            benchmarkNeural: Bool = false,
                            benchmarkFull: Bool = false,
                            configure: (inout PassConfig) -> Void) async throws -> PassOutput {
        var cfg = PassConfig(); configure(&cfg)
        return try await renderCore(source: source, fmt: fmt, tailSeconds: tailSeconds,
                                    benchmarkNeural: benchmarkNeural, benchmarkFull: benchmarkFull) { dsp in
            dsp.setBypassed(cfg.masterBypass)
            dsp.setActiveCabSlot(cfg.cabSlot)
            dsp.setParameter(SRParamAmpBypass, value: cfg.ampBypass ? 1 : 0)
            dsp.setParameter(SRParamCabBypass, value: cfg.cabBypass ? 1 : 0)
            dsp.setParameter(SRParamAmpUseNeural, value: cfg.useNeural ? 1 : 0)
            dsp.setParameter(SRParamAmpDrive, value: cfg.drive)
            dsp.setParameter(SRParamAmpMakeup, value: cfg.makeup)
            dsp.resetDSP()
        }
    }

    /// Shared engine plumbing for one offline pass. `apply` configures the DSP
    /// (setup thread, before any render) — prompt 002 sets A/B params; prompt 003
    /// compiles a whole rig via `RigGraphCompiler.applyImmediate`.
    private func renderCore(source: AVAudioPCMBuffer,
                            fmt: AVAudioFormat,
                            tailSeconds: Double = 0.15,
                            benchmarkNeural: Bool = false,
                            benchmarkFull: Bool = false,
                            apply: (StreetRigDSPUnit) -> Void) async throws -> PassOutput {
        StreetRigDSPUnit.registerIfNeeded()
        let unit = try await Self.instantiateDSPUnit()
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

        // Assets load in the AU's allocateRenderResources (triggered by start).
        // Apply the DSP config now — before any renderOffline — so setup-thread
        // work (cab-slot swap, pedal config) never races the render thread.
        let dsp = unit.auAudioUnit as? StreetRigDSPUnit
        if let dsp { apply(dsp) }

        player.scheduleBuffer(source, at: nil, options: [], completionHandler: nil)
        player.play()

        guard let renderBuffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                  frameCapacity: maxFrames) else {
            throw NSError(domain: "AudioEngineController", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate render buffer"])
        }

        let total = Int(source.frameLength) + Int(fmt.sampleRate * tailSeconds)
        var out = [Float](); out.reserveCapacity(total)
        var rendered = 0
        loop: while rendered < total {
            let want = AVAudioFrameCount(min(Int(maxFrames), total - rendered))
            let st = try engine.renderOffline(want, to: renderBuffer)
            switch st {
            case .success:
                let count = Int(renderBuffer.frameLength)
                if count == 0 { break loop }
                if let cd = renderBuffer.floatChannelData {
                    let m = cd[0]; for i in 0..<count { out.append(m[i]) }
                }
                rendered += count
            case .insufficientDataFromInputNode: break loop
            case .cannotDoInCurrentContext: continue
            case .error:
                throw NSError(domain: "AudioEngineController", code: -6,
                              userInfo: [NSLocalizedDescriptionKey: "renderOffline reported .error"])
            @unknown default: break loop
            }
        }

        // Benchmark while the model + unit are still alive (setup-thread timing).
        var neuralNs = 0.0, fullNs = 0.0
        if benchmarkNeural, let dsp { neuralNs = dsp.benchmarkNeuralNsPerSample(100_000) }
        if benchmarkFull, let dsp { fullNs = dsp.benchmarkFullNsPerSample(frames: 128, iterations: 4000) }

        player.stop(); engine.stop()

        var result = PassOutput(samples: out,
                                blockUs: (dsp?.lastBlockSeconds ?? 0) * 1_000_000,
                                blocks: dsp?.processCallCount ?? 0)
        result.neuralNsPerSample = neuralNs
        result.fullNsPerSample = fullNs
        if let s = dsp?.toneStatus {
            result.neuralLoaded = s.neuralLoaded
            result.neuralError = s.neuralError
            result.cabLengths = s.cabLengths
            result.cabLatency = s.cabLatency
        }
        return result
    }

    // MARK: - Convolver impulse self-test

    struct ImpulseResult { var maxError: Float; var correlation: Float; var lag: Int }

    /// Render a unit impulse through the cab-only path and compare to the raw IR —
    /// proving the partitioned FFT convolution (and its scaling) is numerically
    /// correct, independent of the amp.
    private func impulseSelfTest(fmt: AVAudioFormat, cabSlot: Int) async throws -> ImpulseResult {
        let irName = cabSlot == 0 ? "cab_v30_4x12" : "cab_greenback_1x12"
        guard let ir = StreetRigDSPUnit.loadMonoWav(irName) else {
            return ImpulseResult(maxError: .greatestFiniteMagnitude, correlation: 0, lag: 0)
        }
        let irs = ir.samples

        let n = irs.count + 512
        guard let src = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else {
            return ImpulseResult(maxError: .greatestFiniteMagnitude, correlation: 0, lag: 0)
        }
        src.frameLength = AVAudioFrameCount(n)
        if let cd = src.floatChannelData { cd[0][0] = 1.0 }

        let pass = try await renderPass(source: src, fmt: fmt, tailSeconds: 0.05) { c in
            c.ampBypass = true; c.cabBypass = false; c.cabSlot = cabSlot
        }
        let out = pass.samples
        if out.isEmpty { return ImpulseResult(maxError: .greatestFiniteMagnitude, correlation: 0, lag: 0) }

        // Align (small lag search) then compare over the IR length.
        var bestLag = 0, bestErr = Float.greatestFiniteMagnitude
        let maxLag = min(600, max(0, out.count - irs.count))
        for lag in 0...max(0, maxLag) {
            var err: Float = 0
            for k in 0..<irs.count where lag + k < out.count { err += abs(out[lag + k] - irs[k]) }
            if err < bestErr { bestErr = err; bestLag = lag }
        }
        var maxErr: Float = 0, dot: Float = 0, e1: Float = 0, e2: Float = 0
        for k in 0..<irs.count where bestLag + k < out.count {
            let o = out[bestLag + k], r = irs[k]
            maxErr = max(maxErr, abs(o - r)); dot += o * r; e1 += o * o; e2 += r * r
        }
        let corr = (e1 > 0 && e2 > 0) ? dot / (e1.squareRoot() * e2.squareRoot()) : 0
        return ImpulseResult(maxError: maxErr, correlation: corr, lag: bestLag)
    }

    // MARK: - Prompt 003: full compiled-rig chain verification

    /// Render one whole rig (compiled from a `RigDSPPlan`) through the real graph.
    private func renderRigPlan(_ plan: RigDSPPlan,
                               source: AVAudioPCMBuffer,
                               fmt: AVAudioFormat,
                               tailSeconds: Double = 0.15,
                               benchmarkFull: Bool = false) async throws -> PassOutput {
        try await renderCore(source: source, fmt: fmt, tailSeconds: tailSeconds,
                             benchmarkFull: benchmarkFull) { dsp in
            RigGraphCompiler.applyImmediate(plan, to: dsp)   // pedals → amp → cab, in order
        }
    }

    private func rigLine(_ name: String, _ s: [Float], _ sr: Double) -> String {
        let padded = name.padding(toLength: 20, withPad: " ", startingAt: 0)
        let b2 = Double(Self.brightness(s, sr: sr, cutoff: 2000) * 100)
        let b3 = Double(Self.brightness(s, sr: sr, cutoff: 3000) * 100)
        return "  \(padded) peak \(Self.dbfs(Self.peak(s))) dBFS   RMS \(Self.dbfs(Self.rms(s))) dBFS   |  hi>2k "
             + String(format: "%5.1f", b2) + "%   hi>3k " + String(format: "%5.1f", b3) + "%"
    }

    @MainActor
    private func chainDescription(_ store: RigStore) -> String {
        let peds = store.pedalItems.map { $0.name }.joined(separator: " → ")
        let amp = store.ampItem?.name ?? "—"
        let cab = store.isCombo ? "(combo)" : (store.cabinetItem?.name ?? "—")
        return (peds.isEmpty ? "(no pedals)" : peds) + " → " + amp + " → " + cab
    }

    /// Build a seed rig, render the full compiled chain, sweep a pedal + amp knob
    /// through `store.binding(...)`, reconfigure (remove / add / swap), and prove
    /// the barrier fade — the prompt-003 success criteria.
    private func runRigVerification(dry: AVAudioPCMBuffer,
                                    fmt: AVAudioFormat,
                                    sr: Double) async -> (text: String, pass: Bool, wav: [Float]) {
        let store = RigStore(persist: false)               // in-memory seeded rig (no disk)
        let inSamples = Self.channelSamples(dry)
        func bright(_ s: [Float], _ hz: Double) -> Double { Double(Self.brightness(s, sr: sr, cutoff: hz) * 100) }
        func setKnob(_ id: UUID, _ p: String, _ v: Double) { store.binding(itemId: id, param: p).wrappedValue = v }

        guard let odId = store.pedalItems.first(where: { $0.category == .overdrive })?.id,
              let ampId = store.ampItem?.id else {
            return ("PROMPT 003: seed rig missing an overdrive pedal or amp — cannot verify.", false, [])
        }

        var L: [String] = []
        var checks: [(String, Bool, String)] = []   // (name, pass, detail)

        // --- 1. Baseline: the full compiled rig (Tube Screamer → JCM800 → 4x12). ---
        setKnob(odId, "Drive", 6); setKnob(odId, "Tone", 6); setKnob(odId, "Level", 6)
        for (p, v) in [("Gain", 6.0), ("Bass", 5.0), ("Mid", 5.0), ("Treble", 5.0), ("Presence", 5.0), ("Master", 6.0)] {
            setKnob(ampId, p, v)
        }
        let basePlan = RigGraphCompiler.compile(store: store)
        let baseDesc = chainDescription(store)
        let base = (try? await renderRigPlan(basePlan, source: dry, fmt: fmt, benchmarkFull: true)) ?? PassOutput()
        let dryB2 = bright(inSamples, 2000)
        let baseB2 = bright(base.samples, 2000)

        L.append("on-screen chain : \(baseDesc)")
        L.append("compiled chain  : \(basePlan.pedals.count) pedal slot(s) [\(basePlan.signature)]")
        L.append(rigLine("dry (input)", inSamples, sr))
        L.append(rigLine("FULL rig (base)", base.samples, sr))
        checks.append(("rig renders non-silent", Self.peak(base.samples) > 1e-4,
                       "peak \(Self.dbfs(Self.peak(base.samples))) dBFS"))
        checks.append(("rig transforms the DI", Self.rms(Self.difference(base.samples, inSamples)) > 1e-3,
                       "diff RMS \(Self.dbfs(Self.rms(Self.difference(base.samples, inSamples)))) dBFS"))
        checks.append(("drive+amp add harmonics", baseB2 > dryB2 + 0.3,
                       String(format: "hi>2k: dry %.1f%% → rig %.1f%%", dryB2, baseB2)))

        // --- 2. LIVE-BINDING sweeps: move the SAME binding the UI uses, recompile. ---
        // Pedal Drive 0 → 10 (harmonics must rise).
        setKnob(odId, "Drive", 0)
        let dLow = (try? await renderRigPlan(RigGraphCompiler.compile(store: store), source: dry, fmt: fmt)) ?? PassOutput()
        setKnob(odId, "Drive", 10)
        let dHigh = (try? await renderRigPlan(RigGraphCompiler.compile(store: store), source: dry, fmt: fmt)) ?? PassOutput()
        let dLowB = bright(dLow.samples, 2000), dHighB = bright(dHigh.samples, 2000)
        checks.append(("pedal Drive 0→10 ↑ harmonics", dHighB > dLowB + 0.3,
                       String(format: "hi>2k: %.1f%% → %.1f%%", dLowB, dHighB)))
        setKnob(odId, "Drive", 6)

        // Amp Treble 0 → 10 (brightness must rise).
        setKnob(ampId, "Treble", 0)
        let tLow = (try? await renderRigPlan(RigGraphCompiler.compile(store: store), source: dry, fmt: fmt)) ?? PassOutput()
        setKnob(ampId, "Treble", 10)
        let tHigh = (try? await renderRigPlan(RigGraphCompiler.compile(store: store), source: dry, fmt: fmt)) ?? PassOutput()
        let tLowB = bright(tLow.samples, 3000), tHighB = bright(tHigh.samples, 3000)
        checks.append(("amp Treble 0→10 ↑ brightness", tHighB > tLowB + 0.3,
                       String(format: "hi>3k: %.1f%% → %.1f%%", tLowB, tHighB)))
        setKnob(ampId, "Treble", 5)

        // --- 3. STRUCTURAL reconfigure through the SAME store mutations the UI uses. ---
        let sigBase = RigGraphCompiler.compile(store: store).signature
        // (a) remove the drive pedal.
        store.removePedal(odId)
        let planNoDrive = RigGraphCompiler.compile(store: store)
        let noDrive = (try? await renderRigPlan(planNoDrive, source: dry, fmt: fmt)) ?? PassOutput()
        let noDriveB = bright(noDrive.samples, 2000)
        let removedOK = planNoDrive.signature != sigBase && !planNoDrive.pedals.contains { $0.type == ParameterMap.typeDrive }
        checks.append(("remove pedal → chain changed", removedOK,
                       "no drive slot; sig \(planNoDrive.signature)"))
        checks.append(("remove pedal → fewer harmonics", noDriveB < baseB2,
                       String(format: "hi>2k: base %.1f%% → no-drive %.1f%%", baseB2, noDriveB)))

        // (b) add a FUZZ pedal (BIG MUFF) — different character, re-sorted into chain.
        if let muff = store.collection.first(where: { $0.name.lowercased().contains("big muff") }) { store.apply(muff) }
        let planFuzz = RigGraphCompiler.compile(store: store)
        let fuzz = (try? await renderRigPlan(planFuzz, source: dry, fmt: fmt)) ?? PassOutput()
        checks.append(("add Big Muff → its voicing present",
                       planFuzz.pedals.contains { $0.character == ParameterMap.voiceBigMuff } && Self.peak(fuzz.samples) > 1e-4,
                       "voicings \(planFuzz.pedals.map { $0.character })"))

        // (c) swap the whole amp section stack → combo (Volt AC30 = different cab).
        if let combo = store.collection.first(where: { $0.category == .comboAmp }) { store.apply(combo) }
        let planCombo = RigGraphCompiler.compile(store: store)
        let combo = (try? await renderRigPlan(planCombo, source: dry, fmt: fmt)) ?? PassOutput()
        checks.append(("stack→combo swaps cab & renders",
                       store.isCombo && planCombo.cabSlot != basePlan.cabSlot && Self.peak(combo.samples) > 1e-4,
                       "combo cab slot \(planCombo.cabSlot) vs base \(basePlan.cabSlot)"))

        // --- 4. Hot-swap barrier: fade-out → park (silence) → fade-in, click-free. ---
        let barrier = await barrierFadeTest(fmt: fmt)
        checks.append(("barrier fades to silence + parks", barrier.faded && barrier.finite, "tail RMS ≈ 0"))
        checks.append(("barrier fades back in (recovers)", barrier.recovered, "signal returns"))
        checks.append(("swap boundary click-free", barrier.clickFree,
                       String(format: "max |Δsample| %.3f", barrier.maxJump)))

        // --- Render cost (full board incl. pedals) vs. the ~2667 µs live budget. ---
        let liveDeadlineUs = 128.0 / sr * 1_000_000
        let fullNs = base.fullNsPerSample
        let fullBlockUs = fullNs * 128 / 1000

        let allPass = checks.allSatisfy { $0.1 }
        var out = """
        === PROMPT 003 — FULL COMPILED-RIG CHAIN VERIFICATION ===
        Graph         : player → StreetRigDSPUnit[in → PEDALS(ordered) → AMP → TONE STACK → CAB → out] → mixer  [.offline]
        \(L.joined(separator: "\n"))

        --- Checks (live binding + reconfigure + barrier) ---

        """
        for (name, ok, detail) in checks {
            let pad = name.padding(toLength: 34, withPad: " ", startingAt: 0)
            out += "  \(pad) \(ok ? "PASS" : "FAIL")   (\(detail))\n"
        }
        out += """

        --- Full-board render cost (pedals + amp + tone + cab, current base rig) ---
        FULL board        : \(String(format: "%.1f", fullNs)) ns/sample → \(String(format: "%.1f", fullBlockUs)) µs / 128-frame block = \(String(format: "%.2f", fullBlockUs / liveDeadlineUs * 100))% of the ~\(String(format: "%.0f", liveDeadlineUs)) µs LIVE budget
        Reconfigure model : knob turns → atomic bus (NO rebuild); add/remove/reorder/swap → faded park barrier (setup thread), audio thread read-only over preallocated slots
        PROMPT 003 OVERALL: \(allPass ? "PASS" : "SOME CHECKS FAILED")
        NOTE          : clip shapes + 0…10→DSP ranges (ParameterMap.swift) are a first pass — final feel needs on-device tuning with a real iRig.
        === END PROMPT 003 ===
        """
        return (out, allPass, base.samples)
    }

    /// Drive the reconfigure barrier inside a running (offline) render: steady tone
    /// → begin (fade to silence + park) → end (fade back in). Proves the fade is
    /// click-free and the parked branch truly mutes, without a physical device.
    private func barrierFadeTest(fmt: AVAudioFormat)
        async -> (faded: Bool, recovered: Bool, clickFree: Bool, finite: Bool, maxJump: Float) {
        let sr = fmt.sampleRate
        let n = Int(2.0 * sr)
        guard let src = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else {
            return (false, false, false, false, 0)
        }
        src.frameLength = AVAudioFrameCount(n)
        if let cd = src.floatChannelData {
            for i in 0..<n { cd[0][i] = Float(0.3 * sin(2.0 * Double.pi * 220.0 * Double(i) / sr)) }
        }

        StreetRigDSPUnit.registerIfNeeded()
        guard let unit = try? await Self.instantiateDSPUnit() else { return (false, false, false, false, 0) }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player); engine.attach(unit)
        engine.connect(player, to: unit, format: fmt)
        engine.connect(unit, to: engine.mainMixerNode, format: fmt)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: fmt)
        let maxFrames: AVAudioFrameCount = 128
        guard (try? engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: maxFrames)) != nil,
              (try? engine.start()) != nil,
              let rb = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames) else {
            return (false, false, false, false, 0)
        }
        let dsp = unit.auAudioUnit as? StreetRigDSPUnit
        dsp?.setParameter(SRParamAmpDrive, value: 3.0)
        dsp?.setParameter(SRParamAmpMakeup, value: 1.0)
        dsp?.resetDSP()
        player.scheduleBuffer(src, at: nil, options: [], completionHandler: nil)
        player.play()

        func renderChunks(_ count: Int) -> [Float] {
            var out: [Float] = []
            for _ in 0..<count where (try? engine.renderOffline(maxFrames, to: rb)) == .some(.success) {
                let c = Int(rb.frameLength)
                if let cd = rb.floatChannelData { for i in 0..<c { out.append(cd[0][i]) } }
            }
            return out
        }

        let phase1 = renderChunks(30)          // steady tone
        dsp?.beginReconfigure()
        let phase2 = renderChunks(30)          // fade out → park (silence)
        dsp?.endReconfigure()
        let phase3 = renderChunks(60)          // fade back in → recover
        player.stop(); engine.stop()

        let all = phase1 + phase2 + phase3
        let finite = all.allSatisfy { $0.isFinite }
        let tail2 = Array(phase2.suffix(256))
        let faded = Self.rms(tail2) < 0.02 && Self.peak(tail2) < 0.05
        let recovered = Self.rms(Array(phase3.suffix(512))) > 0.02
        var maxJump: Float = 0
        if all.count > 1 { for i in 1..<all.count { maxJump = max(maxJump, abs(all[i] - all[i - 1])) } }
        return (faded, recovered, maxJump < 0.15, finite, maxJump)
    }

    // MARK: - Pedal-family verification (EQ / comp / gate / wah / volume / modulation)

    /// Isolate each NEW structural family (amp + cab BYPASSED) and prove it audibly
    /// transforms the DI in the expected direction — the sound-level proof that the
    /// generalized PedalChain slot actually runs each engine, not just that it builds.
    private func runPedalFamilyVerification(dry: AVAudioPCMBuffer,
                                            fmt: AVAudioFormat,
                                            sr: Double) async -> (text: String, pass: Bool) {
        func bright(_ s: [Float], _ hz: Double) -> Double { Double(Self.brightness(s, sr: sr, cutoff: hz) * 100) }

        // One pedal per pass, amp + cab bypassed, so we hear ONLY that pedal. Params
        // come from the SAME ParameterMap the app uses, so this tests the real map.
        func famPlan(_ category: GearCategory, _ name: String, _ values: [String: Double]) -> RigDSPPlan {
            var p = RigDSPPlan()
            p.ampBypass = true; p.cabBypass = true
            p.pedals = [.init(type: ParameterMap.pedalType(for: category),
                              character: ParameterMap.pedalVoicing(name: name, category: category),
                              enabled: true,
                              params: ParameterMap.pedalParams(category: category, values: values))]
            p.signature = "fam-\(name)"
            return p
        }
        func render(_ p: RigDSPPlan) async -> [Float] {
            ((try? await renderRigPlan(p, source: dry, fmt: fmt)) ?? PassOutput()).samples
        }

        // Reference: empty chain, amp + cab bypassed → ≈ dry. Proves stage-bypass
        // passes through, so every difference below is the pedal's own doing.
        var refPlan = RigDSPPlan(); refPlan.ampBypass = true; refPlan.cabBypass = true; refPlan.signature = "fam-ref"
        let ref = await render(refPlan)
        let refRMS = Self.rms(ref)
        let refB3 = bright(ref, 3000)

        // Dedicated LOUD→QUIET bursts (0.5 then 0.02 amplitude) so the dynamics
        // pedals act on a clear quiet section the plucked DI lacks.
        func burstSignal(_ loudSec: Double, _ quietSec: Double) -> AVAudioPCMBuffer {
            let nL = Int(loudSec * sr), nQ = Int(quietSec * sr), n = nL + nQ
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            let ch = buf.floatChannelData![0]
            for i in 0..<n {
                let amp: Double = i < nL ? 0.5 : 0.02            // loud (-6 dB) → quiet (-34 dB)
                ch[i] = Float(amp * sin(2.0 * Double.pi * 220.0 * Double(i) / sr))
            }
            return buf
        }
        func renderOn(_ p: RigDSPPlan, _ src: AVAudioPCMBuffer) async -> [Float] {
            ((try? await renderRigPlan(p, source: src, fmt: fmt)) ?? PassOutput()).samples
        }

        var checks: [(String, Bool, String)] = []

        // EQ — prove it is FREQUENCY-SELECTIVE: a treble-boost setting is brighter
        // than a bass-boost setting, and the two settings differ materially. (This
        // is DI-spectrum-independent, unlike an absolute brightness threshold.)
        let eqTreble = await render(famPlan(.eq, "Graphic EQ", ["Low": 3, "Mid": 5, "High": 10]))
        let eqBass   = await render(famPlan(.eq, "Graphic EQ", ["Low": 10, "Mid": 5, "High": 3]))
        checks.append(("EQ is frequency-selective",
                       bright(eqTreble, 3000) > bright(eqBass, 3000) && Self.rms(Self.difference(eqTreble, eqBass)) > 1e-2,
                       String(format: "hi>3k: bass-boost %.1f%% < treble-boost %.1f%%",
                              bright(eqBass, 3000), bright(eqTreble, 3000))))

        // Wah — resonant peak → materially changes the signal.
        let wah = await render(famPlan(.wah, "Cry Baby", ["Position": 7]))
        checks.append(("Wah reshapes the signal", Self.rms(Self.difference(wah, ref)) > 1e-3,
                       "diff RMS \(Self.dbfs(Self.rms(Self.difference(wah, ref)))) dBFS"))

        // Compressor — evens a loud→quiet burst → the loud/quiet ratio shrinks.
        let cburst = burstSignal(0.5, 0.5)
        let (brLoud, brQuiet) = Self.halves(await renderOn(refPlan, cburst))
        let refRatio = brQuiet > 1e-9 ? brLoud / brQuiet : 0
        let (cLoud, cQuiet) = Self.halves(await renderOn(famPlan(.compressor, "Dyna Comp", ["Sustain": 9, "Level": 5]), cburst))
        let compRatio = cQuiet > 1e-9 ? cLoud / cQuiet : 0
        checks.append(("Compressor evens dynamics", compRatio < refRatio * 0.6,
                       String(format: "loud/quiet ratio: ref %.1f → comp %.1f (loud %@→%@)",
                              refRatio, compRatio, Self.dbfs(brLoud), Self.dbfs(cLoud))))

        // Gate — a long quiet tail below threshold → muted to near silence.
        let gburst = burstSignal(0.2, 0.8)
        let gTailRef  = Self.rms(Self.tail(await renderOn(refPlan, gburst), 0.3))
        let gTailGate = Self.rms(Self.tail(await renderOn(famPlan(.noiseGate, "Noise Gate", ["Threshold": 9, "Decay": 2]), gburst), 0.3))
        checks.append(("Gate mutes below-threshold tail", gTailGate < gTailRef * 0.3,
                       "tail RMS ref \(Self.dbfs(gTailRef)) → gate \(Self.dbfs(gTailGate))"))

        // Volume — low position → strong attenuation.
        let vol = await render(famPlan(.volume, "Volume", ["Position": 2]))
        checks.append(("Volume pedal attenuates", Self.rms(vol) < refRMS * 0.5,
                       "RMS ref \(Self.dbfs(refRMS)) → vol \(Self.dbfs(Self.rms(vol)))"))

        // Tremolo — amplitude LFO → differs from dry and lowers average level.
        let trem = await render(famPlan(.modulation, "Tremolo", ["Rate": 7, "Depth": 8, "Mix": 5]))
        checks.append(("Tremolo modulates amplitude",
                       Self.rms(trem) < refRMS * 0.98 && Self.rms(Self.difference(trem, ref)) > 1e-3,
                       "RMS ref \(Self.dbfs(refRMS)) → trem \(Self.dbfs(Self.rms(trem)))"))

        // Phaser — sweeping all-pass notches → differs from dry.
        let phaser = await render(famPlan(.modulation, "Phase 90", ["Rate": 4, "Depth": 7, "Mix": 6]))
        checks.append(("Phaser alters the signal", Self.rms(Self.difference(phaser, ref)) > 1e-3,
                       "diff RMS \(Self.dbfs(Self.rms(Self.difference(phaser, ref)))) dBFS"))

        // Chorus — modulated delay → differs from dry.
        let chorus = await render(famPlan(.modulation, "CE-2 Chorus", ["Rate": 5, "Depth": 6, "Mix": 6]))
        checks.append(("Chorus alters the signal", Self.rms(Self.difference(chorus, ref)) > 1e-3,
                       "diff RMS \(Self.dbfs(Self.rms(Self.difference(chorus, ref)))) dBFS"))

        // ---- Per-model DRIVE voicing: SAME knobs, different pedal → different circuit.
        func crest(_ s: [Float]) -> Float { let r = Self.rms(s); return r > 1e-9 ? Self.peak(s) / r : 0 }
        func drv(_ name: String) async -> [Float] {
            await render(famPlan(.overdrive, name, ["Drive": 7, "Tone": 6, "Level": 5]))
        }
        func dd(_ a: [Float], _ b: [Float]) -> Float { Self.rms(Self.difference(a, b)) }
        let ts = await drv("Tube Screamer"), rat = await drv("ProCo RAT")
        let muff = await drv("Big Muff"), klon = await drv("Klon Centaur")
        checks.append(("drive models are distinct (TS/RAT/Muff/Klon)",
                       dd(ts, rat) > 1e-2 && dd(rat, muff) > 1e-2 && dd(muff, klon) > 1e-2 && dd(ts, klon) > 1e-2,
                       "Δ TS-RAT \(Self.dbfs(dd(ts, rat))), RAT-Muff \(Self.dbfs(dd(rat, muff))), Muff-Klon \(Self.dbfs(dd(muff, klon)))"))
        checks.append(("RAT brighter than Big Muff (scoop)", bright(rat, 3000) > bright(muff, 3000),
                       String(format: "hi>3k: RAT %.1f%% vs Muff %.1f%%", bright(rat, 3000), bright(muff, 3000))))
        checks.append(("Klon more dynamic than RAT (headroom)", crest(klon) > crest(rat),
                       String(format: "crest: Klon %.2f vs RAT %.2f", crest(klon), crest(rat))))

        let allPass = checks.allSatisfy { $0.1 }
        var out = """
        === PEDAL FAMILIES — new structural DSP (EQ / comp / gate / wah / volume / modulation) ===
        Method        : one pedal per pass, amp + cab BYPASSED, vs a dry reference (same graph).

        """
        for (name, ok, detail) in checks {
            let pad = name.padding(toLength: 34, withPad: " ", startingAt: 0)
            out += "  \(pad) \(ok ? "PASS" : "FAIL")   (\(detail))\n"
        }
        out += "PEDAL FAMILIES OVERALL: \(allPass ? "PASS" : "SOME CHECKS FAILED")\n=== END PEDAL FAMILIES ==="
        return (out, allPass)
    }

    // MARK: - Signal-meter math verification

    /// Prove the LIVE METER math without a guitar.
    ///
    /// The Simulator has no audio input, so the meters can't be validated by
    /// playing — but they can be validated exactly, because the answers for a
    /// known-amplitude sine are arithmetic: a full-scale sine peaks at 0 dBFS and
    /// has an RMS of 1/√2 = -3.01 dBFS; halving the amplitude drops both by
    /// 6.02 dB; silence falls to the floor. This drives the REAL audio-thread
    /// routine (`AudioLevelBus.accumulate`), the REAL drain and the REAL
    /// ballistics (`AudioLevelMonitor.tick`), and cross-checks every number
    /// against this harness's own `peak` / `rms` over the same samples — so there
    /// is one implementation of the math, checked two ways.
    private func runMeterVerification(sr: Double) -> (text: String, pass: Bool) {
        /// Whole cycles at 1 kHz / 48 kHz = 48 samples per cycle, so the crest
        /// (k = 12) is sampled exactly and peak == amplitude with no windowing error.
        func sine(_ amplitude: Float, seconds: Double = 0.25, hz: Double = 1000) -> [Float] {
            let n = Int(seconds * sr)
            return (0..<n).map { Float(Double(amplitude) * sin(2 * Double.pi * hz * Double($0) / sr)) }
        }

        let monitor = AudioLevelMonitor()
        /// Push one block through the real bus + ballistics and read back both the
        /// raw drained numbers and the published (smoothed) meter state.
        func measure(_ samples: [Float]) -> (peak: Float, rms: Float, level: AudioLevel) {
            monitor.reset()
            // HOLD THE TONE UNTIL THE DISPLAY CONVERGES. The peak lands on the
            // measurement in a single tick — its attack is instant by design — but
            // the RMS body deliberately RAMPS toward it (`Ballistics.rmsAttackTau`;
            // an instant attack is what made the bar strobe at 30 Hz). These checks
            // are about the dBFS MATH, not about arrival time, so sustain the tone
            // the way a held note does and read the settled value. 200 ticks is
            // ~6.7 s, comfortably past convergence for any sane attack constant —
            // deliberately generous so that tuning the meter's feel doesn't quietly
            // start failing the dBFS math. (`AudioLevelBus.drain` is exercised on
            // every one of those ticks, so this still covers the accumulator.)
            for _ in 0..<200 {
                samples.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    monitor.inputBus.accumulate(base, frameCount: buffer.count)
                }
                monitor.tick()
            }
            return (AudioLevelBus.dbfs(Self.peak(samples)),
                    AudioLevelBus.dbfs(Self.rms(samples)),
                    monitor.input)
        }

        let full = measure(sine(1.0))
        let half = measure(sine(0.5))
        let quiet = measure(sine(0.005))          // -46 dBFS: quiet playing
        let noise = measure(sine(0.0005))         // -66 dBFS: below the presence floor
        let silence = measure([Float](repeating: 0, count: Int(0.25 * sr)))

        func near(_ a: Float, _ b: Float, _ tol: Float = 0.05) -> Bool { abs(a - b) <= tol }

        var checks: [(String, Bool, String)] = []
        checks.append(("full-scale sine peak = 0 dBFS",
                       near(full.level.peakDB, 0) && near(full.peak, 0),
                       String(format: "meter %.2f / harness %.2f dBFS", full.level.peakDB, full.peak)))
        checks.append(("full-scale sine RMS = -3.01 dBFS",
                       near(full.level.rmsDB, -3.01) && near(full.rms, -3.01),
                       String(format: "meter %.2f / harness %.2f dBFS", full.level.rmsDB, full.rms)))
        checks.append(("amplitude 0.5 peak = -6.02 dBFS",
                       near(half.level.peakDB, -6.02) && near(half.peak, -6.02),
                       String(format: "meter %.2f / harness %.2f dBFS", half.level.peakDB, half.peak)))
        checks.append(("amplitude 0.5 RMS = -9.03 dBFS",
                       near(half.level.rmsDB, -9.03) && near(half.rms, -9.03),
                       String(format: "meter %.2f / harness %.2f dBFS", half.level.rmsDB, half.rms)))
        checks.append(("meter == harness on every signal",
                       near(full.level.peakDB, full.peak) && near(half.level.peakDB, half.peak)
                       && near(full.level.rmsDB, full.rms) && near(half.level.rmsDB, half.rms),
                       "one dBFS implementation, two call sites"))
        checks.append(("silence sits on the floor",
                       silence.level.peakDB <= AudioLevel.floorDB + 0.01 && silence.peak < -170,
                       String(format: "meter %.1f dBFS (scale floor %.0f), raw %.1f dBFS",
                              silence.level.peakDB, AudioLevel.floorDB, silence.peak)))
        checks.append(("clip flag latches at full scale",
                       full.level.isClipping && !half.level.isClipping,
                       "1.0 → CLIP, 0.5 → clear"))
        checks.append(("signal-present splits quiet from silent",
                       quiet.level.hasSignal && !noise.level.hasSignal && !silence.level.hasSignal,
                       String(format: "-46 dBFS lit, -66 dBFS dark (floor %.0f dBFS)", AudioLevel.signalFloorDB)))

        // MANY BUFFERS OVER MANY WINDOWS. A single-buffer test cannot see an
        // accumulator that compounds across drains — the failure mode that made a
        // live meter read RMS *above* peak (impossible) because already-drained
        // energy was being re-counted against a fresh frame count. Feeding a
        // steady tone through several buffers per window, for several windows,
        // must read the SAME numbers every window.
        monitor.reset()
        let block = sine(0.5, seconds: 0.02)          // 960 frames = 20 whole cycles
        func feedWindow() {
            for _ in 0..<4 {
                block.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    monitor.inputBus.accumulate(base, frameCount: buffer.count)
                }
            }
            monitor.tick()
        }
        // SETTLE FIRST. The RMS body deliberately RAMPS toward a new level rather
        // than snapping to it (see `Ballistics.rmsAttackTau` — an instant attack is
        // what made the bar strobe at 30 Hz), so the first windows are legitimately
        // still climbing. What this check hunts is drift BETWEEN windows once the
        // level has arrived — an accumulator that compounds across drains — not how
        // long the arrival takes.
        var ramp: [Float] = []
        for _ in 0..<200 { feedWindow(); ramp.append(monitor.input.rmsDB) }
        var windows: [AudioLevel] = []
        for _ in 0..<3 { feedWindow(); windows.append(monitor.input) }
        let steady = windows.allSatisfy { near($0.peakDB, -6.02) && near($0.rmsDB, -9.03) }
        checks.append(("steady tone reads the same every window", steady,
                       "3 settled windows × 4 buffers: "
                       + windows.map { String(format: "%.2f/%.2f", $0.peakDB, $0.rmsDB) }.joined(separator: ", ")))

        // THE SMOOTHING ITSELF, measured. A bar that reaches its target in one tick
        // is the strobe; a bar that climbs monotonically over many ticks is what
        // reads as a level swelling. Both halves matter — monotonic alone would
        // pass an instant jump, and slow alone would pass a jittery crawl.
        let ramped = zip(ramp, ramp.dropFirst()).allSatisfy { $1 >= $0 - 0.01 }
        let ticksToArrive = ramp.firstIndex { $0 >= -9.03 - 1.0 } ?? ramp.count
        checks.append(("RMS bar ramps instead of snapping", ramped && ticksToArrive >= 5,
                       String(format: "monotonic rise, %d ticks (~%.0f ms) to within 1 dB",
                              ticksToArrive,
                              Double(ticksToArrive) * AudioLevelMonitor.tickInterval * 1000)))

        // DECAY INTO SILENCE — where the two bars first crossed on the real screen.
        // A loud window followed by empty ones (the gap between two picked notes)
        // must fall with peak above RMS the whole way down: they have to release
        // toward the SAME floor, or the peak dives past the RMS and the meter shows
        // the impossible.
        monitor.reset()
        block.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            monitor.inputBus.accumulate(base, frameCount: buffer.count)
        }
        monitor.tick()
        var decay: [AudioLevel] = [monitor.input]
        for _ in 0..<40 {                      // ~1.3 s of dead air
            monitor.tick()
            decay.append(monitor.input)
        }
        checks.append(("peak stays above RMS decaying into silence",
                       decay.allSatisfy { $0.rmsDB <= $0.peakDB + 0.01 },
                       String(format: "after %d silent ticks: peak %.1f, RMS %.1f, hasSignal %@",
                              decay.count - 1, decay.last!.peakDB, decay.last!.rmsDB,
                              decay.last!.hasSignal ? "yes" : "no")))
        checks.append(("silence eventually clears the signal lamp",
                       !decay.last!.hasSignal && decay.first!.hasSignal,
                       "lit while playing, dark once the note has gone"))

        // The invariant the live screen violated: RMS can never exceed peak.
        let everyLevel = windows + decay + [full.level, half.level, quiet.level, noise.level, silence.level]
        checks.append(("RMS never exceeds peak (physics)",
                       everyLevel.allSatisfy { $0.rmsDB <= $0.peakDB + 0.01 },
                       "checked across \(everyLevel.count) published readings"))

        let allPass = checks.allSatisfy { $0.1 }
        var out = """
        === SIGNAL METERS — dBFS math (input/output level metering) ===
        Method        : known-amplitude 1 kHz sines → AudioLevelBus.accumulate (the audio-thread
                        routine) → drain → AudioLevelMonitor ballistics, cross-checked against the
                        harness's own peak/RMS. Meter scale floor \(Int(AudioLevel.floorDB)) dBFS,
                        signal-present floor \(Int(AudioLevel.signalFloorDB)) dBFS.

        """
        for (name, ok, detail) in checks {
            let pad = name.padding(toLength: 38, withPad: " ", startingAt: 0)
            out += "  \(pad) \(ok ? "PASS" : "FAIL")   (\(detail))\n"
        }
        out += "SIGNAL METERS OVERALL: \(allPass ? "PASS" : "SOME CHECKS FAILED")\n=== END SIGNAL METERS ==="
        return (out, allPass)
    }

    // MARK: - AR footswitch verification

    /// Prove an AR stomp slot is a real FOOTSWITCH, not decoration: binding a
    /// pedal must not silence it, stomping it off must change the sound, and — the
    /// regression this exists to prevent — a STRUCTURAL rebuild triggered by an
    /// unrelated rig edit must not quietly re-enable a pedal the player stomped off.
    private func runFootswitchVerification(dry: AVAudioPCMBuffer,
                                           fmt: AVAudioFormat,
                                           sr: Double) async -> (text: String, pass: Bool) {
        let store = RigStore(persist: false)
        func bright(_ s: [Float], _ hz: Double) -> Double { Double(Self.brightness(s, sr: sr, cutoff: hz) * 100) }
        func setKnob(_ id: UUID, _ p: String, _ v: Double) { store.binding(itemId: id, param: p).wrappedValue = v }
        func render(_ plan: RigDSPPlan) async -> [Float] {
            ((try? await renderRigPlan(plan, source: dry, fmt: fmt)) ?? PassOutput()).samples
        }
        /// The compiled slot index of a pedal — `rig.pedalIds` order IS plan order,
        /// and it is re-sorted on every structural edit, so never cache it.
        func slotIndex(_ id: UUID) -> Int? { store.rig.pedalIds.firstIndex(of: id) }
        func enabled(_ plan: RigDSPPlan, _ id: UUID) -> Bool? {
            guard let i = slotIndex(id), plan.pedals.indices.contains(i) else { return nil }
            return plan.pedals[i].enabled
        }

        guard let odId = store.pedalItems.first(where: { $0.category == .overdrive })?.id,
              let ampId = store.ampItem?.id else {
            return ("AR FOOTSWITCH: seed rig missing an overdrive pedal or amp — cannot verify.", false)
        }
        setKnob(odId, "Drive", 9); setKnob(odId, "Tone", 6); setKnob(odId, "Level", 6)
        for (p, v) in [("Gain", 6.0), ("Bass", 5.0), ("Mid", 5.0), ("Treble", 5.0), ("Presence", 5.0), ("Master", 6.0)] {
            setKnob(ampId, p, v)
        }
        let pedalName = store.item(odId)?.name ?? "drive pedal"

        var checks: [(String, Bool, String)] = []
        var lines: [String] = []

        // 1. UNBOUND — the pedal is simply in the chain, so it is enabled.
        let planFree = RigGraphCompiler.compile(store: store)
        let free = await render(planFree)
        checks.append(("unbound pedal stays enabled", enabled(planFree, odId) == true,
                       "no AR slot holds \(pedalName)"))

        // 2. BIND — dropping it on a footswitch must NOT bypass a working pedal.
        store.setARSlot(0, pedalId: odId)
        let planBound = RigGraphCompiler.compile(store: store)
        let bound = await render(planBound)
        let bindDelta = Self.rms(Self.difference(bound, free))
        checks.append(("binding defaults the slot ON", store.arSlots[0].isOn && enabled(planBound, odId) == true,
                       "slot 0 ← \(pedalName), isOn=\(store.arSlots[0].isOn)"))
        checks.append(("binding is inaudible (no silent bypass)", bindDelta < 1e-6,
                       "Δ vs unbound \(Self.dbfs(bindDelta)) dBFS"))

        // 3. STOMP OFF — audibly bypassed, and via the CONTINUOUS bus (signature
        //    unchanged ⇒ RigAudioBridge pushes SRPedalFieldEnabled, no rebuild).
        store.toggleARSlot(0)
        let planOff = RigGraphCompiler.compile(store: store)
        let off = await render(planOff)
        let stompDelta = Self.rms(Self.difference(off, bound))
        let onBright = bright(bound, 2000), offBright = bright(off, 2000)
        checks.append(("stomp sets the slot's enabled flag to 0", enabled(planOff, odId) == false,
                       "compiled slot \(slotIndex(odId).map(String.init) ?? "?") enabled=false"))
        checks.append(("stomp is a CONTINUOUS push, not a rebuild", planOff.signature == planBound.signature,
                       "signature unchanged: \(planOff.signature)"))
        checks.append(("stomp audibly changes the output", stompDelta > 1e-3,
                       "Δ on→off \(Self.dbfs(stompDelta)) dBFS"))
        checks.append(("bypassed drive loses harmonics", offBright < onBright,
                       String(format: "hi>2k: on %.1f%% → off %.1f%%", onBright, offBright)))
        lines.append(rigLine("footswitch ON", bound, sr))
        lines.append(rigLine("footswitch OFF", off, sr))

        // 4. STRUCTURAL REBUILD while stomped off — add another pedal (a genuine
        //    topology change) and confirm the stomped pedal is STILL bypassed.
        //    This is the regression the enabled-state rule exists to prevent.
        if let muff = store.collection.first(where: { $0.name.lowercased().contains("big muff") }) {
            store.apply(muff)
        }
        let planRebuilt = RigGraphCompiler.compile(store: store)
        let rebuilt = await render(planRebuilt)
        var planForced = planRebuilt                    // control: same rig, pedal forced back on
        if let i = slotIndex(odId), planForced.pedals.indices.contains(i) { planForced.pedals[i].enabled = true }
        let forced = await render(planForced)
        let stillOffDelta = Self.rms(Self.difference(rebuilt, forced))
        checks.append(("structural rebuild really happened", planRebuilt.signature != planOff.signature,
                       "sig \(planOff.signature) → \(planRebuilt.signature)"))
        checks.append(("rebuild does NOT re-enable a stomped pedal", enabled(planRebuilt, odId) == false,
                       "still enabled=false after adding a pedal to the chain"))
        checks.append(("…and it is still audibly bypassed", stillOffDelta > 1e-3,
                       "Δ vs the same rig with it forced on: \(Self.dbfs(stillOffDelta)) dBFS"))
        lines.append(rigLine("rebuilt, still off", rebuilt, sr))
        lines.append(rigLine("rebuilt, forced on", forced, sr))

        // 5. UNBIND — taking the footswitch off must never strand the pedal bypassed.
        store.setARSlot(0, pedalId: nil)
        let planUnbound = RigGraphCompiler.compile(store: store)
        checks.append(("clearing the slot re-enables the pedal", enabled(planUnbound, odId) == true,
                       "slot released → pedal enabled again"))

        // 6. Dropping a pedal that is NOT in the rig adds it to the chain first.
        let spare = store.collection.first { $0.category.isPedal && !store.rig.pedalIds.contains($0.id) }
        var addedOK = false, addedDetail = "no spare pedal in the collection"
        if let spare {
            let before = store.rig.pedalIds.count
            store.setARSlot(1, pedalId: spare.id)
            let planAdded = RigGraphCompiler.compile(store: store)
            addedOK = store.rig.pedalIds.contains(spare.id)
                && store.rig.pedalIds.count == before + 1
                && enabled(planAdded, spare.id) == true
            addedDetail = "\(spare.name) added to the chain (\(before) → \(store.rig.pedalIds.count) pedals), enabled"
        }
        checks.append(("dropping an unracked pedal adds it to the rig", addedOK, addedDetail))

        // 7. ONE PEDAL, ONE FOOTSWITCH. Assigning a pedal that already holds a slot
        //    releases the old one, so the enabled-state rule keeps a single source —
        //    and the pedal comes out enabled rather than stranded by the slot it left.
        //    The AR page's picker now shows this coming ("ON SWITCH n · MOVES HERE"),
        //    which is only honest while this holds.
        var movedOK = false, movedDetail = "no spare pedal in the collection"
        if let spare {
            store.setARSlot(2, pedalId: spare.id)
            let planMoved = RigGraphCompiler.compile(store: store)
            movedOK = store.arSlots[1].pedalId == nil
                && store.arSlots[2].pedalId == spare.id
                && store.arSlots[2].isOn
                && enabled(planMoved, spare.id) == true
            movedDetail = "\(spare.name): slot 1 released, now on slot 2 only, still enabled"
        }
        checks.append(("re-binding releases the pedal's old slot", movedOK, movedDetail))

        let allPass = checks.allSatisfy { $0.1 }
        var out = """
        === AR FOOTSWITCHES — stomp slots drive the real chain ===
        Method        : the SAME store mutations the AR screen performs (setARSlot / toggleARSlot),
                        compiled by RigGraphCompiler and rendered through the real graph.
                        Footswitched pedal: \(pedalName), Drive 9.
        \(lines.joined(separator: "\n"))

        """
        for (name, ok, detail) in checks {
            let pad = name.padding(toLength: 42, withPad: " ", startingAt: 0)
            out += "  \(pad) \(ok ? "PASS" : "FAIL")   (\(detail))\n"
        }
        out += """
        Live path     : slot toggle → store.$arSlots → RigAudioBridge → (signature unchanged) →
                        pushValues → setPedalParam(SRPedalFieldEnabled) → one relaxed atomic store,
                        read by the render thread next buffer. Adding a pedal moves the signature and
                        goes through the fade/park barrier instead.
        AR FOOTSWITCH OVERALL: \(allPass ? "PASS" : "SOME CHECKS FAILED")
        === END AR FOOTSWITCHES ===
        """
        return (out, allPass)
    }

    // MARK: - Amp-profile verification (per-amp voicing + the Katana)
    //
    //  The exit criterion for the profile system is not "it builds" — it is that
    //  the six catalog amps are MEASURABLY different, that the differences are
    //  VOICING rather than level, that the Katana's characters and its power
    //  control do what they claim, and that an amp with no profile is unchanged.
    //  Everything below renders through the real AU graph with the CAB BYPASSED,
    //  so what is measured is the amp itself and not two shared IRs.

    /// Fraction of a signal's RMS that sits inside [lo, hi] Hz — a 2nd-order RBJ
    /// high-pass into a 2nd-order low-pass. Normalized by the total, so it is
    /// LEVEL-INDEPENDENT: two renders that differ only in gain score identically,
    /// which is exactly what makes it a voicing measurement.
    static func bandEnergy(_ x: [Float], sr: Double, lo: Double, hi: Double) -> Double {
        guard !x.isEmpty else { return 0 }
        func rbj(_ fc: Double, highpass: Bool) -> (Float, Float, Float, Float, Float) {
            let w0 = 2 * Double.pi * fc / sr
            let cw = cos(w0), sw = sin(w0), alpha = sw / (2 * 0.707)
            let a0 = 1 + alpha
            if highpass {
                return (Float((1 + cw) / 2 / a0), Float(-(1 + cw) / a0), Float((1 + cw) / 2 / a0),
                        Float(-2 * cw / a0), Float((1 - alpha) / a0))
            }
            return (Float((1 - cw) / 2 / a0), Float((1 - cw) / a0), Float((1 - cw) / 2 / a0),
                    Float(-2 * cw / a0), Float((1 - alpha) / a0))
        }
        let (hb0, hb1, hb2, ha1, ha2) = rbj(lo, highpass: true)
        let (lb0, lb1, lb2, la1, la2) = rbj(hi, highpass: false)
        var hx1: Float = 0, hx2: Float = 0, hy1: Float = 0, hy2: Float = 0
        var lx1: Float = 0, lx2: Float = 0, ly1: Float = 0, ly2: Float = 0
        var sumB: Float = 0, sumF: Float = 0
        for s in x {
            let h = hb0 * s + hb1 * hx1 + hb2 * hx2 - ha1 * hy1 - ha2 * hy2
            hx2 = hx1; hx1 = s; hy2 = hy1; hy1 = h
            let l = lb0 * h + lb1 * lx1 + lb2 * lx2 - la1 * ly1 - la2 * ly2
            lx2 = lx1; lx1 = h; ly2 = ly1; ly1 = l
            sumB += l * l; sumF += s * s
        }
        let rmsF = (sumF / Float(x.count)).squareRoot()
        let rmsB = (sumB / Float(x.count)).squareRoot()
        return rmsF > 1e-9 ? Double(rmsB / rmsF) * 100 : 0
    }

    /// A level-independent SPECTRAL FINGERPRINT: the fraction of energy above
    /// each of five cutoffs. Two amps that differ only in output gain produce the
    /// same fingerprint; two amps that are voiced differently cannot.
    static func fingerprint(_ x: [Float], sr: Double) -> [Double] {
        [500.0, 1000, 2000, 4000, 8000].map { Double(Self.brightness(x, sr: sr, cutoff: $0) * 100) }
    }

    /// Largest per-band gap between two fingerprints, in percentage points.
    static func fingerprintGap(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }

    /// Peak ÷ RMS. Compression squashes it; clean headroom preserves it.
    static func crestFactor(_ x: [Float]) -> Double {
        let r = Self.rms(x)
        return r > 1e-9 ? Double(Self.peak(x) / r) : 0
    }

    /// Difference RMS after matching levels, as a fraction of the reference RMS.
    /// This is the "it is not just a volume knob" measurement: scale one render
    /// onto the other and see what is left.
    static func levelMatchedDiff(_ a: [Float], _ b: [Float]) -> Double {
        let ra = Self.rms(a), rb = Self.rms(b)
        guard ra > 1e-9, rb > 1e-9 else { return 0 }
        let k = ra / rb
        let n = min(a.count, b.count)
        var sum: Float = 0
        for i in 0..<n { let d = a[i] - b[i] * k; sum += d * d }
        let diff = n > 0 ? (sum / Float(n)).squareRoot() : 0
        return Double(diff / ra)
    }

    /// One amp under test: a minimal rig (guitar + amp, plus a cabinet for a
    /// head) compiled by the REAL `RigGraphCompiler`, so the profile is resolved
    /// from the catalog NAME and the knob set from `PedalSpec` — the same path
    /// the app takes. The cab is then bypassed so the measurement is the amp.
    private func ampPlan(_ name: String, _ category: GearCategory,
                         values: [String: Double]) -> (plan: RigDSPPlan, item: GearItem) {
        let guitar = GearItem(name: "Les Paul Standard", category: .guitar)
        var amp = GearItem(name: name, category: category)
        for (k, v) in values { amp.values[k] = v }
        var collection = [guitar, amp]
        let section: AmpSection
        if category == .comboAmp {
            section = .combo(comboId: amp.id)
        } else {
            let cab = GearItem(name: "Marswell 1960A 4x12", category: .cabinet)
            collection.append(cab)
            section = .stack(ampId: amp.id, cabinetId: cab.id)
        }
        var plan = RigGraphCompiler.compile(
            collection: collection,
            rig: RigConfiguration(guitarId: guitar.id, ampSection: section, pedalIds: []))
        plan.cabBypass = true      // isolate the AMP: only two IRs are bundled
        return (plan, amp)
    }

    /// Knobs held identical across every amp under test, so any difference is the
    /// profile and nothing else. Gain 5 sits at edge-of-breakup for a crunch
    /// voicing and stays clean for a Twin, which is the point.
    private static let ampTestKnobs: [String: Double] = [
        "Gain": 5, "Bass": 5, "Mid": 5, "Treble": 5, "Presence": 5,
        "Volume": 5, "Master": 5,
    ]

    private func runAmpProfileVerification(dry: AVAudioPCMBuffer,
                                           fmt: AVAudioFormat,
                                           sr: Double) async -> (text: String, pass: Bool) {
        var checks: [(String, Bool, String)] = []
        var lines: [String] = []

        func render(_ plan: RigDSPPlan) async -> [Float] {
            ((try? await renderRigPlan(plan, source: dry, fmt: fmt)) ?? PassOutput()).samples
        }
        func mid(_ s: [Float]) -> Double { Self.bandEnergy(s, sr: sr, lo: 300, hi: 1200) }
        func hi3(_ s: [Float]) -> Double { Double(Self.brightness(s, sr: sr, cutoff: 3000) * 100) }

        // ---- 1. THE SIX CATALOG AMPS, same DI, same knobs, cab bypassed. ------
        let catalog: [(String, GearCategory)] = [
            ("Marswell JCM800 2203", .amp),
            ("Fandor Twin Reverb",   .comboAmp),
            ("Volt AC30",            .comboAmp),
            ("Rolund JC-120 Jazz Chorus", .comboAmp),
            ("Fandor Bassman '59",   .comboAmp),
            ("VOSS Katana 100",      .comboAmp),
        ]
        var rendered: [(name: String, profile: Int, samples: [Float], fp: [Double])] = []
        for (name, cat) in catalog {
            let built = ampPlan(name, cat, values: Self.ampTestKnobs)
            let out = await render(built.plan)
            rendered.append((name, built.plan.ampProfile, out, Self.fingerprint(out, sr: sr)))
        }

        lines.append("  amp                    profile  RMS       crest  |  mid300-1.2k  hi>500  hi>1k  hi>2k  hi>4k  hi>8k")
        for r in rendered {
            let pad = r.name.padding(toLength: 22, withPad: " ", startingAt: 0)
            lines.append("  \(pad) \(String(format: "%2d", r.profile))     "
                + "\(Self.dbfs(Self.rms(r.samples))) dB  "
                + String(format: "%5.2f", Self.crestFactor(r.samples)) + "  |  "
                + String(format: "%8.1f%%", mid(r.samples)) + "  "
                + r.fp.map { String(format: "%5.1f%%", $0) }.joined(separator: " "))
        }

        // Every amp resolved to a DISTINCT profile — the name matcher works.
        let ids = rendered.map(\.profile)
        checks.append(("six amps resolve to six profiles", Set(ids).count == 6 && !ids.contains(0),
                       "ids \(ids) (0 = legacy fallback, must not appear)"))

        // Pairwise: audibly different AND spectrally different. The second half
        // is what rules out "they are the same amp at different volumes".
        var worstDiff = Double.greatestFiniteMagnitude, worstDiffPair = ""
        var worstGap  = Double.greatestFiniteMagnitude, worstGapPair = ""
        for i in 0..<rendered.count {
            for j in (i + 1)..<rendered.count {
                let d = Self.levelMatchedDiff(rendered[i].samples, rendered[j].samples)
                if d < worstDiff { worstDiff = d; worstDiffPair = "\(rendered[i].profile)/\(rendered[j].profile)" }
                let g = Self.fingerprintGap(rendered[i].fp, rendered[j].fp)
                if g < worstGap { worstGap = g; worstGapPair = "\(rendered[i].profile)/\(rendered[j].profile)" }
            }
        }
        checks.append(("every amp pair differs (level-matched)", worstDiff > 0.10,
                       String(format: "closest pair %@ still %.1f%% residual after level matching",
                              worstDiffPair, worstDiff * 100)))
        checks.append(("…and differs SPECTRALLY, not just in level", worstGap > 1.0,
                       String(format: "closest pair %@ still %.1f pp apart in a band", worstGapPair, worstGap)))

        // The `noonDB` claims, measured. These are the exact rows the whole change
        // hinges on: a passive stack is not flat at noon, and each amp's scoop is
        // its own. Everything here is at IDENTICAL knob settings.
        func byId(_ id: Int) -> [Float] { rendered.first { $0.profile == id }?.samples ?? [] }
        let ac30Mid = mid(byId(ParameterMap.ampAC30))
        let othersMid = rendered.filter { $0.profile != ParameterMap.ampAC30 }.map { mid($0.samples) }
        checks.append(("AC30 is the only mid-FORWARD amp", ac30Mid > (othersMid.max() ?? 0),
                       String(format: "AC30 %.1f%% vs next-highest %.1f%%", ac30Mid, othersMid.max() ?? 0)))
        let twinMid = mid(byId(ParameterMap.ampTwinReverb)), jcmMid = mid(byId(ParameterMap.ampJCM800))
        checks.append(("Twin is more mid-scooped than the JCM800", twinMid < jcmMid,
                       String(format: "mid 300–1.2k: Twin %.1f%% < JCM800 %.1f%% (noonDB −11 vs −7)",
                              twinMid, jcmMid)))
        let jcCrest = Self.crestFactor(byId(ParameterMap.ampJC120))
        let jcmCrest = Self.crestFactor(byId(ParameterMap.ampJCM800))
        checks.append(("JC-120 keeps its headroom; the JCM800 does not", jcCrest > jcmCrest,
                       String(format: "crest: JC-120 %.2f > JCM800 %.2f (headroom 3.00 vs 0.75)",
                              jcCrest, jcmCrest)))

        // ---- 2. THE VOX CUT: a knob that works BACKWARDS. --------------------
        // The strongest form of "a brighter amp measures brighter": the same
        // control, on two amps, must move brightness in OPPOSITE directions,
        // because the AC30's `presenceScale` is negative.
        func presenceSweep(_ name: String, _ cat: GearCategory) async -> (lo: Double, hi: Double) {
            var v = Self.ampTestKnobs; v["Presence"] = 0
            let dark = await render(ampPlan(name, cat, values: v).plan)
            v["Presence"] = 10
            let bright = await render(ampPlan(name, cat, values: v).plan)
            return (hi3(dark), hi3(bright))
        }
        let acP = await presenceSweep("Volt AC30", .comboAmp)
        let jcmP = await presenceSweep("Marswell JCM800 2203", .amp)
        checks.append(("JCM800 Presence 0→10 brightens", jcmP.hi > jcmP.lo + 0.2,
                       String(format: "hi>3k %.1f%% → %.1f%%", jcmP.lo, jcmP.hi)))
        checks.append(("AC30 Presence 0→10 DARKENS (the Vox Cut)", acP.hi < acP.lo - 0.2,
                       String(format: "hi>3k %.1f%% → %.1f%% (presenceScale −0.8)", acP.lo, acP.hi)))

        // ---- 3. THE KATANA: five characters × two variations. ----------------
        var kat: [(label: String, id: Int, s: [Float], fp: [Double])] = []
        for (c, cname) in ParameterMap.ampKatanaCharacters.enumerated() {
            for variation in 0...1 {
                var v = Self.ampTestKnobs
                v["Character"] = Double(c); v["Variation"] = Double(variation)
                let built = ampPlan("VOSS Katana 100", .comboAmp, values: v)
                let out = await render(built.plan)
                kat.append(("\(cname) \(variation == 0 ? "A" : "B")", built.plan.ampProfile,
                            out, Self.fingerprint(out, sr: sr)))
            }
        }
        lines.append("")
        lines.append("  Katana voicing         profile  RMS       crest  |  mid300-1.2k  hi>500  hi>1k  hi>2k  hi>4k  hi>8k")
        for k in kat {
            let pad = k.label.padding(toLength: 22, withPad: " ", startingAt: 0)
            lines.append("  \(pad) \(String(format: "%2d", k.id))     "
                + "\(Self.dbfs(Self.rms(k.s))) dB  "
                + String(format: "%5.2f", Self.crestFactor(k.s)) + "  |  "
                + String(format: "%8.1f%%", mid(k.s)) + "  "
                + k.fp.map { String(format: "%5.1f%%", $0) }.joined(separator: " "))
        }
        let katIds = kat.map(\.id)
        checks.append(("ten Katana voicings, ten profile ids", Set(katIds).count == 10,
                       "ids \(katIds)"))
        var worstChar = Double.greatestFiniteMagnitude, worstCharPair = ""
        for i in 0..<kat.count {
            for j in (i + 1)..<kat.count {
                let d = Self.levelMatchedDiff(kat[i].s, kat[j].s)
                if d < worstChar { worstChar = d; worstCharPair = "\(kat[i].label) vs \(kat[j].label)" }
            }
        }
        checks.append(("all ten Katana voicings are distinct", worstChar > 0.05,
                       String(format: "closest pair %@ still %.1f%% residual", worstCharPair, worstChar * 100)))
        var worstVar = Double.greatestFiniteMagnitude, worstVarLabel = ""
        for c in 0..<ParameterMap.ampKatanaCharacterCount {
            let d = Self.levelMatchedDiff(kat[c * 2].s, kat[c * 2 + 1].s)
            if d < worstVar { worstVar = d; worstVarLabel = ParameterMap.ampKatanaCharacters[c] }
        }
        checks.append(("Variation B differs from A on every character", worstVar > 0.05,
                       String(format: "weakest: %@ %.1f%% residual", worstVarLabel, worstVar * 100)))
        // B is "hotter and tighter": less low end into the clipper, more drive.
        let brownA = kat[8], brownB = kat[9]
        checks.append(("Brown B is tighter than Brown A (less low end)",
                       Self.bandEnergy(brownB.s, sr: sr, lo: 20, hi: 150)
                       < Self.bandEnergy(brownA.s, sr: sr, lo: 20, hi: 150),
                       String(format: "20–150 Hz: A %.1f%% → B %.1f%% (inputHz 85 → 105)",
                              Self.bandEnergy(brownA.s, sr: sr, lo: 20, hi: 150),
                              Self.bandEnergy(brownB.s, sr: sr, lo: 20, hi: 150))))

        // ---- 4. THE POWER CONTROL IS NOT A VOLUME KNOB. ----------------------
        // The check most likely to catch a wrong implementation. Everything is
        // held fixed except the power setting, the two renders are LEVEL-MATCHED,
        // and what is compared is harmonic content and compression.
        func katanaPowerPlan(_ index: Int) -> RigDSPPlan {
            var v = Self.ampTestKnobs
            v["Character"] = 2; v["Variation"] = 1; v["Volume"] = 8   // Crunch B, pushed
            v["Power"] = Double(index)
            return ampPlan("VOSS Katana 100", .comboAmp, values: v).plan
        }
        func katanaAtPower(_ index: Int) async -> [Float] { await render(katanaPowerPlan(index)) }
        let p100 = await katanaAtPower(2), p50 = await katanaAtPower(1), p05 = await katanaAtPower(0)
        let residual = Self.levelMatchedDiff(p100, p05)
        let hi100 = hi3(p100), hi05 = hi3(p05)

        // COMPRESSION, measured the only way that is not confounded by the
        // program material: a LOUD → QUIET burst, and how far apart the two halves
        // still are on the way out. Crest factor is reported below but is a poor
        // test here — sag deliberately lets transients punch through a ducking
        // supply, which RAISES crest even as the stage compresses harder.
        let burstN = Int(0.5 * sr)
        let burst = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(burstN * 2))!
        burst.frameLength = AVAudioFrameCount(burstN * 2)
        if let cd = burst.floatChannelData {
            for i in 0..<(burstN * 2) {
                let amp: Double = i < burstN ? 0.5 : 0.02        // −6 dBFS → −34 dBFS
                cd[0][i] = Float(amp * sin(2.0 * Double.pi * 220.0 * Double(i) / sr))
            }
        }
        func burstRatio(_ index: Int) async -> Double {
            let out = ((try? await renderRigPlan(katanaPowerPlan(index), source: burst, fmt: fmt))
                        ?? PassOutput()).samples
            let (loud, quiet) = Self.halves(out)
            return quiet > 1e-9 ? Double(loud / quiet) : 0
        }
        let ratio100 = await burstRatio(2), ratio50 = await burstRatio(1), ratio05 = await burstRatio(0)

        lines.append("")
        lines.append(String(format: "  power 100 W : RMS %@ dB  crest %.2f  hi>3k %.1f%%  loud/quiet %.2f",
                            Self.dbfs(Self.rms(p100)), Self.crestFactor(p100), hi100, ratio100))
        lines.append(String(format: "  power  50 W : RMS %@ dB  crest %.2f  hi>3k %.1f%%  loud/quiet %.2f",
                            Self.dbfs(Self.rms(p50)), Self.crestFactor(p50), hi3(p50), ratio50))
        lines.append(String(format: "  power 0.5 W : RMS %@ dB  crest %.2f  hi>3k %.1f%%  loud/quiet %.2f",
                            Self.dbfs(Self.rms(p05)), Self.crestFactor(p05), hi05, ratio05))
        checks.append(("power 0.5 W ≠ 100 W AT MATCHED LEVEL", residual > 0.10,
                       String(format: "%.1f%% residual after level matching — not a gain change", residual * 100)))
        checks.append(("0.5 W changes HARMONIC content", abs(hi05 - hi100) > 0.3,
                       String(format: "hi>3k %.1f%% → %.1f%%", hi100, hi05)))
        checks.append(("0.5 W COMPRESSES harder (loud→quiet burst)", ratio05 < ratio100 * 0.8,
                       String(format: "loud/quiet %.2f → %.2f", ratio100, ratio05)))
        checks.append(("50 W sits between the two", ratio50 <= ratio100 && ratio50 >= ratio05,
                       String(format: "loud/quiet 100 W %.2f ≥ 50 W %.2f ≥ 0.5 W %.2f",
                              ratio100, ratio50, ratio05)))

        // ---- 5. STRUCTURAL vs CONTINUOUS, read off the signature. ------------
        func sig(_ v: [String: Double]) -> String {
            var vals = Self.ampTestKnobs
            for (k, x) in v { vals[k] = x }
            return ampPlan("VOSS Katana 100", .comboAmp, values: vals).plan.signature
        }
        let sigBase = sig(["Character": 2, "Variation": 0, "Power": 2])
        checks.append(("Power is CONTINUOUS (signature unchanged)",
                       sig(["Character": 2, "Variation": 0, "Power": 0]) == sigBase,
                       "0.5 W and 100 W compile to \(sigBase)"))
        checks.append(("Gain/EQ/Volume are CONTINUOUS (signature unchanged)",
                       sig(["Gain": 9, "Treble": 1, "Volume": 9, "Master": 2]) == sigBase,
                       "knob turns never rebuild the chain"))
        checks.append(("Character is STRUCTURAL (signature moves)",
                       sig(["Character": 4]) != sigBase,
                       "Crunch \(sigBase) → Brown \(sig(["Character": 4]))"))
        checks.append(("Variation is STRUCTURAL (signature moves)",
                       sig(["Variation": 1]) != sigBase, "A → B changes the profile id"))
        let click = await powerSwitchClickTest(fmt: fmt)
        checks.append(("power switch mid-render is click-free", click.clickFree,
                       String(format: "max |Δsample| %.4f across the switch vs %.4f steady (×%.2f)",
                              click.switchJump, click.steadyJump, click.ratio)))

        // ---- 6. ROUND-TRIP IDENTITY for every new curve. ---------------------
        var volErr = 0.0
        for i in 0...20 {
            let knob = Double(i) * 0.5
            volErr = max(volErr, abs(ParameterMap.invAmpVolumeKnob(ParameterMap.ampVolume(volumeKnob: knob)) - knob))
        }
        checks.append(("ampVolume knob → bus → knob is identity", volErr < 1e-4,
                       String(format: "max error %.2e over 0…10 in 0.5 steps", volErr)))
        let powerRT = (0...2).allSatisfy {
            Int(ParameterMap.invAmpPowerIndex(ParameterMap.ampPowerScale(powerIndex: Double($0)))) == $0
        }
        checks.append(("ampPower index → bus → index is identity", powerRT,
                       "0.5 W / 50 W / 100 W all resolve back to their own detent"))

        // ---- 7. SAVED STATE: a rig from before these knobs existed. ----------
        let oldJSON = """
        {"id":"\(UUID().uuidString)","name":"VOSS Katana 100","category":"comboAmp",
         "values":{"Gain":6,"Bass":5,"Mid":5,"Treble":5,"Presence":5,"Master":6}}
        """
        var savedOK = false, savedDetail = "could not decode the legacy GearItem JSON"
        if let data = oldJSON.data(using: .utf8),
           let oldAmp = try? JSONDecoder().decode(GearItem.self, from: data) {
            let guitar = GearItem(name: "Les Paul Standard", category: .guitar)
            let plan = RigGraphCompiler.compile(
                collection: [guitar, oldAmp],
                rig: RigConfiguration(guitarId: guitar.id,
                                      ampSection: .combo(comboId: oldAmp.id), pedalIds: []))
            savedOK = plan.ampProfile == ParameterMap.ampKatanaBase + 2 * 2   // Crunch, variation A
                && plan.ampPower == 1.0                                       // 100 W
                && abs(plan.ampVolume - 1.0) < 1e-6                           // unity
            savedDetail = "no Character/Variation/Power/Volume keys → profile \(plan.ampProfile) "
                + "(Crunch A), power \(plan.ampPower), volume \(plan.ampVolume)"
        }
        checks.append(("a rig saved before this change loads with sane defaults", savedOK, savedDetail))

        let host = await auv3StateRoundTrip()
        checks.append(("AUv3 fullState round-trips the new addresses", host.paramsOK, host.paramsDetail))
        checks.append(("a host blob with NO new params loads on defaults", host.legacyOK, host.legacyDetail))

        // ---- Listening artifacts. --------------------------------------------
        // The measurements above prove the amps are DIFFERENT. Whether they are
        // RIGHT is an ear question, and this harness has no ears — so it writes
        // the A/B material the owner needs: every amp, then every Katana voicing,
        // back to back on the same DI with the same knobs, half a second of
        // silence between each so they are easy to pick apart.
        func concat(_ clips: [[Float]]) -> [Float] {
            let gap = [Float](repeating: 0, count: Int(0.5 * sr))
            return clips.flatMap { $0 + gap }
        }
        let ampsURL = Self.documentsURL("StreetRig_amp_ab.wav")
        let katURL = Self.documentsURL("StreetRig_katana_ab.wav")
        try? Self.writeWav(concat(rendered.map(\.samples)), to: ampsURL, format: fmt)
        try? Self.writeWav(concat(kat.map(\.s)), to: katURL, format: fmt)
        lines.append("")
        lines.append("  A/B for listening : \(ampsURL.lastPathComponent) — "
                     + rendered.map(\.name).joined(separator: " · "))
        lines.append("                      \(katURL.lastPathComponent) — "
                     + kat.map(\.label).joined(separator: " · "))

        // ---- Cost, per profile. ----------------------------------------------
        let liveDeadlineUs = 128.0 / sr * 1_000_000
        var costLines: [String] = []
        for (label, name, cat, extra) in [("JCM800 (3 stages)", "Marswell JCM800 2203", GearCategory.amp, [String: Double]()),
                                          ("Katana Brown B (4)", "VOSS Katana 100", .comboAmp, ["Character": 4, "Variation": 1]),
                                          ("legacy (unprofiled)", "Generic Practice Amp", .comboAmp, [:])] {
            var v = Self.ampTestKnobs
            for (k, x) in extra { v[k] = x }
            var plan = ampPlan(name, cat, values: v).plan
            plan.cabBypass = false          // FULL board cost, cab included
            let out = (try? await renderRigPlan(plan, source: dry, fmt: fmt, benchmarkFull: true)) ?? PassOutput()
            let us = out.fullNsPerSample * 128 / 1000
            costLines.append(String(format: "  %@ : %.1f ns/sample → %.1f µs/128-frame block = %.2f%% of the ~%.0f µs budget",
                                    label.padding(toLength: 20, withPad: " ", startingAt: 0),
                                    out.fullNsPerSample, us, us / liveDeadlineUs * 100, liveDeadlineUs))
        }

        let allPass = checks.allSatisfy { $0.1 }
        var out = """
        === AMP PROFILES — every amp is a different amp ===
        Method        : one amp per pass, no pedals, CAB BYPASSED, identical knobs (all at noon,
                        Gain 5), rendered through the real AU graph. `mid` and `hi>` are RMS
                        FRACTIONS, so they are level-independent — an amp cannot score differently
                        just by being louder.

        \(lines.joined(separator: "\n"))

        --- Checks ---

        """
        for (name, ok, detail) in checks {
            let pad = name.padding(toLength: 46, withPad: " ", startingAt: 0)
            out += "  \(pad) \(ok ? "PASS" : "FAIL")   (\(detail))\n"
        }
        out += """

        --- Per-profile render cost (full board incl. cab) ---
        \(costLines.joined(separator: "\n"))
        Note          : a profiled amp turns the neural rail OFF (its character IS the profile), so
                        the LSTM forward pass that dominated the old amp cost is gone.
        AMP PROFILES OVERALL: \(allPass ? "PASS" : "SOME CHECKS FAILED")
        === END AMP PROFILES ===
        """
        return (out, allPass)
    }

    /// Flip `SRParamAmpPower` from 100 W to 0.5 W in the MIDDLE of a live render
    /// and measure the seam. The power control is deliberately off the topology
    /// signature, so this is the proof that keeping it there was safe: it must
    /// glide, not step.
    private func powerSwitchClickTest(fmt: AVAudioFormat)
        async -> (clickFree: Bool, steadyJump: Float, switchJump: Float, ratio: Double) {
        let sr = fmt.sampleRate
        let n = Int(2.0 * sr)
        guard let src = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else {
            return (false, 0, 0, 0)
        }
        src.frameLength = AVAudioFrameCount(n)
        if let cd = src.floatChannelData {
            for i in 0..<n { cd[0][i] = Float(0.3 * sin(2.0 * Double.pi * 220.0 * Double(i) / sr)) }
        }

        StreetRigDSPUnit.registerIfNeeded()
        guard let unit = try? await Self.instantiateDSPUnit() else { return (false, 0, 0, 0) }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player); engine.attach(unit)
        engine.connect(player, to: unit, format: fmt)
        engine.connect(unit, to: engine.mainMixerNode, format: fmt)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: fmt)
        let maxFrames: AVAudioFrameCount = 128
        guard (try? engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: maxFrames)) != nil,
              (try? engine.start()) != nil,
              let rb = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames) else {
            return (false, 0, 0, 0)
        }
        guard let dsp = unit.auAudioUnit as? StreetRigDSPUnit else { return (false, 0, 0, 0) }

        // A Katana Crunch B, pushed hard enough that the power stage is doing work.
        var v = Self.ampTestKnobs
        v["Character"] = 2; v["Variation"] = 1; v["Volume"] = 8
        var plan = ampPlan("VOSS Katana 100", .comboAmp, values: v).plan
        plan.cabBypass = true
        RigGraphCompiler.applyImmediate(plan, to: dsp)
        player.scheduleBuffer(src, at: nil, options: [], completionHandler: nil)
        player.play()

        func renderChunks(_ count: Int) -> [Float] {
            var out: [Float] = []
            for _ in 0..<count where (try? engine.renderOffline(maxFrames, to: rb)) == .some(.success) {
                let c = Int(rb.frameLength)
                if let cd = rb.floatChannelData { for i in 0..<c { out.append(cd[0][i]) } }
            }
            return out
        }
        func maxJump(_ s: [Float]) -> Float {
            guard s.count > 1 else { return 0 }
            var m: Float = 0
            for i in 1..<s.count { m = max(m, abs(s[i] - s[i - 1])) }
            return m
        }

        // THREE windows, not two. A relative test against the BEFORE window alone
        // would fail for an honest reason: at 0.5 W the output-stage waveform is
        // genuinely squarer, so its legitimate sample-to-sample steps are larger
        // than at 100 W. That is the control working, not a click. The seam is
        // isolated by bracketing it with BOTH settled waveforms and asking whether
        // anything happens in between that neither endpoint already does.
        _ = renderChunks(40)                                  // settle at 100 W
        let before = renderChunks(20)                         // 100 W, steady
        dsp.setParameter(SRParamAmpPower, value: ParameterMap.ampPowerScale(powerIndex: 0))
        let across = renderChunks(10)                         // the switch + the ~5 ms glide
        let after = renderChunks(20)                          // 0.5 W, settled
        player.stop(); engine.stop()

        let steadyJump = max(maxJump(before), maxJump(after))
        let switchJump = maxJump(across)
        let steadyPeak = max(Self.peak(before), Self.peak(after))
        let finite = (before + across + after).allSatisfy { $0.isFinite }
        let ratio = steadyJump > 1e-6 ? Double(switchJump / steadyJump) : 0
        // A click is a step, or a level spike, outside what both settled states
        // already produce. 25 % of headroom on either is generous for a glide and
        // nowhere near what a fade/park rebuild or a mis-derived makeup looks like
        // (the first cut of this measured ×6.6 for exactly that reason).
        let clickFree = finite && ratio > 0 && ratio < 1.25
            && Self.peak(across) < steadyPeak * 1.25
        return (clickFree, steadyJump, switchJump, ratio)
    }

    /// AUv3 state: (a) the two new addresses survive a `fullState` round-trip, and
    /// (b) a blob carrying ONLY a rig — the shape a session saved before these
    /// parameters existed has — still loads, on defaults.
    private func auv3StateRoundTrip() async
        -> (paramsOK: Bool, paramsDetail: String, legacyOK: Bool, legacyDetail: String) {
        StreetRigDSPUnit.registerIfNeeded()
        guard let unitA = try? await Self.instantiateDSPUnit(),
              let unitB = try? await Self.instantiateDSPUnit(),
              let a = unitA.auAudioUnit as? StreetRigDSPUnit,
              let b = unitB.auAudioUnit as? StreetRigDSPUnit else {
            return (false, "could not instantiate two units", false, "—")
        }
        let volAddr = UInt64(SRParamAmpVolume.rawValue), powAddr = UInt64(SRParamAmpPower.rawValue)
        a.parameterTree?.parameter(withAddress: volAddr)?.value = 1.4
        a.parameterTree?.parameter(withAddress: powAddr)?.value = 0.14
        let saved = a.fullState
        b.fullState = saved
        let bVol = b.parameterTree?.parameter(withAddress: volAddr)?.value ?? -1
        let bPow = b.parameterTree?.parameter(withAddress: powAddr)?.value ?? -1
        let paramsOK = abs(bVol - 1.4) < 1e-4 && abs(bPow - 0.14) < 1e-4
        let paramsDetail = String(format: "volume 1.400 → %.3f, power 0.140 → %.3f", bVol, bPow)

        // A pre-change host blob: the stable rig key and nothing else. The unit
        // must rebuild the rig and leave the new parameters at their defaults.
        guard let unitC = try? await Self.instantiateDSPUnit(),
              let c = unitC.auAudioUnit as? StreetRigDSPUnit,
              let blob = legacyRigBlob() else {
            return (paramsOK, paramsDetail, false, "could not build a legacy rig blob")
        }
        c.fullState = ["streetrig.rig.v1": blob]
        let cVol = c.parameterTree?.parameter(withAddress: volAddr)?.value ?? -1
        let cPow = c.parameterTree?.parameter(withAddress: powAddr)?.value ?? -1
        // `configuredAmpProfile`, not `activeAmpProfile`: with no render resources
        // allocated the unit deliberately DEFERS structural application to
        // `allocateRenderResources`, so the kernel is still on its default. What
        // matters here is that the blob resolved correctly and the new parameters
        // are sitting on their defaults, which is what an old session gives us.
        let cProfile = c.configuredAmpProfile
        let legacyOK = abs(cVol - 1.0) < 1e-4 && abs(cPow - 1.0) < 1e-4
            && cProfile == ParameterMap.ampKatanaBase + 4
        let legacyDetail = "rig-only blob → resolved profile \(cProfile) (Katana Crunch A), "
            + String(format: "volume %.3f, power %.3f (both at their defaults)", cVol, cPow)
        return (paramsOK, paramsDetail, legacyOK, legacyDetail)
    }

    /// A serialized rig in the shape saved BEFORE the new knobs existed: a Katana
    /// whose `values` carry only the original six. Assembled as raw JSON because
    /// that is exactly how an old `rig_state.json` / host blob reaches the decoder.
    private func legacyRigBlob() -> Data? {
        let guitarId = UUID(), ampId = UUID()
        let json: [String: Any] = [
            "catalogVersion": 3,
            "collection": [
                ["id": guitarId.uuidString, "name": "Les Paul Standard",
                 "category": "guitar", "values": [String: Double]()],
                ["id": ampId.uuidString, "name": "VOSS Katana 100", "category": "comboAmp",
                 "values": ["Gain": 6, "Bass": 5, "Mid": 5, "Treble": 5, "Presence": 5, "Master": 6]],
            ],
            "rig": ["guitarId": guitarId.uuidString,
                    "ampSection": ["combo": ["comboId": ampId.uuidString]],
                    "pedalIds": [String]()],
        ]
        return try? JSONSerialization.data(withJSONObject: json)
    }

    // MARK: - Legacy back-compat reference (the null test's fixed pole)

    /// A FIXED, deterministic render whose only job is to be nulled against a
    /// render from a different build of the engine.
    ///
    /// Everything about it is pinned so the only thing that can move the samples
    /// is the amp code itself: an amp name no profile matches (so the profile
    /// system resolves `AmpVoicing::Legacy`), no pedals, the cab BYPASSED (so no
    /// bundled IR can vary the result), the neural rail off, the generated test
    /// signal rather than the bundled DI, and knobs set off-centre so every tone
    /// band is actually doing something.
    ///
    /// It is written to `Documents/StreetRig_legacy_reference.wav` on every run.
    /// Drop a previous build's copy in as `StreetRig_legacy_baseline.wav` and the
    /// harness nulls the two — that is the mechanically-checkable form of "an amp
    /// with no profile is bit-identical to the behaviour before profiles existed".
    private func legacyReferencePlan() -> RigDSPPlan {
        var plan = RigDSPPlan()
        plan.pedals = []
        plan.useNeural = false        // analog fallback = the Legacy voicing
        plan.ampBypass = false
        plan.cabBypass = true         // no IR in the loop
        plan.cabSlot = 0
        // LITERAL bus values, not `ParameterMap` calls: this reference must stay
        // pinned even if the knob curves are ear-tuned later, or the null test
        // would fail for a reason that has nothing to do with the amp.
        plan.ampDrive      = 3.8988               // ampDrive(gainKnob: 6)
        plan.ampMaster     = 1.16                 // ampMaster(masterKnob: 6)
        plan.ampBassDB     =  4.8                 // ampBandDB("Bass",     knob: 7)
        plan.ampMidDB      = -4.8                 // ampBandDB("Mid",      knob: 3)
        plan.ampTrebleDB   =  7.2                 // ampBandDB("Treble",   knob: 8)
        plan.ampPresenceDB =  1.8                 // ampBandDB("Presence", knob: 6)
        plan.signature = "legacy-reference"
        return plan
    }

    /// Render the reference, write it, and null it against a baseline WAV if one
    /// was placed in Documents by a previous build.
    func runLegacyNullReference(fmt: AVAudioFormat) async -> (text: String, pass: Bool) {
        let src = Self.generateTestSignal(format: fmt, seconds: 2.0)
        let out = ((try? await renderRigPlan(legacyReferencePlan(), source: src, fmt: fmt)) ?? PassOutput()).samples
        let refURL = Self.documentsURL("StreetRig_legacy_reference.wav")
        try? Self.writeWav(out, to: refURL, format: fmt)

        var lines: [String] = []
        lines.append("  reference written : \(refURL.path)  (\(out.count) samples, peak \(Self.dbfs(Self.peak(out))) dBFS)")

        let baseURL = Self.documentsURL("StreetRig_legacy_baseline.wav")
        guard FileManager.default.fileExists(atPath: baseURL.path),
              let file = try? AVAudioFile(forReading: baseURL) else {
            lines.append("  baseline null test: SKIPPED (no StreetRig_legacy_baseline.wav in Documents —")
            lines.append("                      copy this run's reference in as the baseline, rebuild, re-run)")
            return (lines.joined(separator: "\n"), true)
        }
        // Read in CHUNKS until the file runs dry. A single `read(into:)` returns
        // at most one buffer's worth however large the capacity, so reading once
        // silently truncates — which showed up as a bit-exact null test failing on
        // a length mismatch rather than on a single differing sample.
        var base: [Float] = []
        base.reserveCapacity(Int(file.length))
        while true {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                               frameCapacity: 8192),
                  (try? file.read(into: chunk)) != nil, chunk.frameLength > 0 else { break }
            base.append(contentsOf: Self.channelSamples(chunk))
        }
        let n = min(base.count, out.count)
        var maxAbs: Float = 0
        for i in 0..<n { maxAbs = max(maxAbs, abs(out[i] - base[i])) }
        let nullRMS = Self.rms(Self.difference(out, base))
        let exact = (n == base.count && n == out.count && maxAbs == 0)
        lines.append("  baseline null test: \(exact ? "BIT-EXACT" : "NOT BIT-EXACT")  "
                     + "(\(n) samples compared, max |Δ| \(String(format: "%.3e", Double(maxAbs))), "
                     + "null RMS \(Self.dbfs(nullRMS)) dBFS)")
        return (lines.joined(separator: "\n"), exact)
    }

    // MARK: - Shared time-based blocks (delay + reverb + the Katana FX section)
    //
    //  These two engines are the first RECIRCULATING blocks in the app, and
    //  recirculation is what makes them worth a suite of their own: a NaN never
    //  leaves a feedback loop, a decayed tail stalls on denormals minutes after
    //  the last note, and a delay-time change either clicks or pitch-bends —
    //  which of those two is CORRECT depends on the circuit, so both are checked.
    //  Everything below renders through the real AU graph.

    /// All samples finite (no NaN, no ±Inf). The single most important assertion
    /// about a feedback loop: one NaN written into a delay line recirculates for
    /// ever, so "the output is finite" is not a formality here.
    static func allFinite(_ s: [Float]) -> Bool { s.allSatisfy { $0.isFinite } }

    /// Index and value of the largest |sample| inside [from, to).
    static func peakIn(_ s: [Float], _ from: Int, _ to: Int) -> (index: Int, value: Float) {
        var bi = max(0, from), bv: Float = 0
        var i = max(0, from)
        let hi = min(s.count, to)
        while i < hi { if abs(s[i]) > bv { bv = abs(s[i]); bi = i }; i += 1 }
        return (bi, bv)
    }

    /// Zero crossings per second — a cheap, robust pitch estimate for the pure
    /// sine the sweep test uses. It is how the tape voicing's pitch GLIDE is
    /// distinguished from the digital voicing's pitch-preserving crossfade.
    ///
    /// The gate is RELATIVE to the window's own peak and the rate is divided by
    /// the number of samples actually CONSIDERED, not by the window length. Both
    /// matter: an absolute gate plus a full-length denominator reads a quiet
    /// window as a lower pitch, which is exactly the artefact that would make a
    /// pitch-preserving crossfade look like a downward bend.
    static func zeroCrossHz(_ s: [Float], sr: Double) -> Double {
        guard s.count > 1 else { return 0 }
        let gate = Self.peak(s) * 0.02
        guard gate > 0 else { return 0 }
        var crossings = 0, considered = 0
        var last: Float = 0
        var haveLast = false
        for v in s where abs(v) > gate {
            considered += 1
            if haveLast && ((v > 0) != (last > 0)) { crossings += 1 }
            last = v; haveLast = true
        }
        guard considered > 1 else { return 0 }
        return Double(crossings) * sr / (2.0 * Double(considered))
    }

    /// RT60 from a decaying tail: fit the level between −5 dB and −25 dB below
    /// the tail's start and extrapolate to −60 dB. Measuring the whole 60 dB
    /// directly would be dominated by whatever floor the signal lands on.
    static func rt60(_ s: [Float], sr: Double) -> Double {
        let win = max(64, Int(0.02 * sr))
        var env: [(t: Double, db: Double)] = []
        var i = 0
        while i + win <= s.count {
            let r = Self.rms(Array(s[i..<(i + win)]))
            env.append((Double(i) / sr, r > 1e-12 ? 20 * log10(Double(r)) : -240))
            i += win
        }
        guard let peak = env.map(\.db).max(), peak > -200 else { return 0 }
        let a = env.first { $0.db <= peak - 5 }
        let b = env.first { $0.db <= peak - 25 }
        guard let a, let b, b.t > a.t else { return 0 }
        let slope = (b.db - a.db) / (b.t - a.t)      // dB per second (negative)
        guard slope < -0.01 else { return 0 }
        return -60.0 / slope
    }

    /// A source buffer: `burstSec` of a sine at `hz`, then `silenceSec` of
    /// nothing, so the tail / the repeats can be measured with no dry signal on
    /// top of them.
    private func burstThenSilence(_ fmt: AVAudioFormat, hz: Double,
                                  burstSec: Double, silenceSec: Double,
                                  amplitude: Double = 0.5) -> AVAudioPCMBuffer {
        let sr = fmt.sampleRate
        let nB = Int(burstSec * sr), nS = Int(silenceSec * sr)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(nB + nS))!
        buf.frameLength = AVAudioFrameCount(nB + nS)
        let ch = buf.floatChannelData![0]
        for i in 0..<(nB + nS) {
            // A short raised-cosine fade at each end of the burst, so the burst
            // itself contributes no click for the click tests to trip over.
            var a = i < nB ? amplitude : 0
            let fade = Int(0.005 * sr)
            if i < fade { a *= Double(i) / Double(fade) }
            if i < nB && i > nB - fade { a *= Double(nB - i) / Double(fade) }
            ch[i] = Float(a * sin(2.0 * Double.pi * hz * Double(i) / sr))
        }
        return buf
    }

    /// A PLUCK: a decaying stack of harmonics, then silence. Unlike an impulse it
    /// has a guitar-shaped spectrum with real content across the audio band, which
    /// is what makes it a fair probe for a bandwidth question; unlike a sine it
    /// has enough top end for a 2.5 kHz filter and an 8 kHz one to measure apart.
    private func pluckThenSilence(_ fmt: AVAudioFormat, f0: Double, partials: Int,
                                  burstSec: Double, silenceSec: Double,
                                  decaySec: Double) -> AVAudioPCMBuffer {
        let sr = fmt.sampleRate
        let nB = Int(burstSec * sr), nS = Int(silenceSec * sr)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(nB + nS))!
        buf.frameLength = AVAudioFrameCount(nB + nS)
        let ch = buf.floatChannelData![0]
        var peak = 0.0
        var tmp = [Double](repeating: 0, count: nB)
        for i in 0..<nB {
            let t = Double(i) / sr
            var v = 0.0
            for k in 1...partials where Double(k) * f0 < sr * 0.45 {
                v += sin(2.0 * Double.pi * f0 * Double(k) * t) / Double(k)
            }
            v *= exp(-t / decaySec)
            tmp[i] = v
            peak = max(peak, abs(v))
        }
        let g = peak > 0 ? 0.6 / peak : 0
        for i in 0..<nB { ch[i] = Float(tmp[i] * g) }
        for i in nB..<(nB + nS) { ch[i] = 0 }
        return buf
    }

    /// A one-pedal plan with the amp and cab bypassed, built through the REAL
    /// `ParameterMap`, so what is measured is the shipping mapping and not a
    /// hand-written duplicate of it.
    private func timePlan(_ category: GearCategory, _ name: String,
                          _ values: [String: Double]) -> RigDSPPlan {
        var p = RigDSPPlan()
        p.ampBypass = true; p.cabBypass = true
        p.pedals = [.init(type: ParameterMap.pedalType(for: category),
                          character: ParameterMap.pedalVoicing(name: name, category: category),
                          enabled: true,
                          params: ParameterMap.pedalParams(category: category, values: values))]
        p.splitPre = 1; p.splitPost = 1
        p.signature = "time-\(name)-\(values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined())"
        return p
    }

    private func runTimeBlockVerification(dry: AVAudioPCMBuffer,
                                          fmt: AVAudioFormat,
                                          sr: Double) async -> (text: String, pass: Bool) {
        var checks: [(String, Bool, String)] = []
        var lines: [String] = []

        func render(_ p: RigDSPPlan, _ src: AVAudioPCMBuffer) async -> [Float] {
            ((try? await renderRigPlan(p, source: src, fmt: fmt, tailSeconds: 0)) ?? PassOutput()).samples
        }
        func bright(_ s: [Float], _ hz: Double) -> Double { Double(Self.brightness(s, sr: sr, cutoff: hz) * 100) }

        // ---- 1. DELAY IS AUDIBLE, AND THE REPEATS LAND WHERE THEY SHOULD ----
        // An impulse in, and the output must be the dry spike plus a repeat every
        // `Time` milliseconds, each quieter than the last by the feedback factor.
        let timeKnob = 6.0                                   // 40·2^(0.6·5) = 320 ms
        let expectedMs = Double(ParameterMap.delayTimeMs(timeKnob))
        let D = Int(expectedMs * sr / 1000.0)
        let impulseLen = Int(2.2 * sr)
        let impulse = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(impulseLen))!
        impulse.frameLength = AVAudioFrameCount(impulseLen)
        impulse.floatChannelData![0][0] = 1.0

        let fbKnob = 7.0
        let nominalFB = Double(ParameterMap.delayFeedback(fbKnob))
        let dig = await render(timePlan(.delay, "VOSS Digital Delay",
                                        ["Time": timeKnob, "Feedback": fbKnob, "Mix": 10]), impulse)
        var repeatPeaks: [(Int, Float)] = []
        for k in 1...4 {
            let centre = k * D
            let w = max(16, D / 8)
            repeatPeaks.append(Self.peakIn(dig, centre - w, centre + w))
        }
        let offsets = repeatPeaks.enumerated().map { $0.element.0 - ($0.offset + 1) * D }
        let onTime = offsets.allSatisfy { abs($0) <= 4 }
        let amps = repeatPeaks.map { Double($0.1) }
        let decaying = zip(amps, amps.dropFirst()).allSatisfy { $1 < $0 } && amps[0] > 1e-3
        lines.append(String(format: "  delay impulse   : Time %.0f ms (%d samples), feedback %.2f", expectedMs, D, nominalFB))
        lines.append("  repeat peaks    : "
            + repeatPeaks.enumerated().map { String(format: "#%d @%+d smp %.4f", $0.offset + 1, offsets[$0.offset], Double($0.element.1)) }
                .joined(separator: "  "))
        checks.append(("delay: repeats land at the set time", onTime && decaying,
                       String(format: "offsets from k·%d samples: %@; peaks %.4f → %.4f", D,
                              offsets.map { String($0) }.joined(separator: ", "), amps[0], amps[3])))

        // "Decaying at the expected rate" made concrete: the same impulse at a
        // LOW feedback must die faster than at a high one, and the measured
        // repeat-to-repeat ratio must track the feedback coefficient.
        let digLowFB = await render(timePlan(.delay, "VOSS Digital Delay",
                                             ["Time": timeKnob, "Feedback": 3, "Mix": 10]), impulse)
        let lowAmps = (1...3).map { k -> Double in
            Double(Self.peakIn(digLowFB, k * D - max(16, D / 8), k * D + max(16, D / 8)).value)
        }
        let hiRatio = amps[1] / max(amps[0], 1e-9)
        let loRatio = lowAmps[1] / max(lowAmps[0], 1e-9)
        let nominalLow = Double(ParameterMap.delayFeedback(3))
        checks.append(("delay: feedback sets the decay rate",
                       hiRatio > loRatio * 1.5 && hiRatio < nominalFB * 1.6 && loRatio < nominalLow * 1.6,
                       String(format: "repeat2/repeat1 = %.3f at fb %.2f vs %.3f at fb %.2f",
                              hiRatio, nominalFB, loRatio, nominalLow)))

        // ---- 2. THE THREE DELAY CIRCUITS ARE DIFFERENT CIRCUITS -------------
        //
        // Measured on a PLUCK (a decaying harmonic stack with real content up to
        // ~10 kHz) rather than the impulse, and on the WET PATH ONLY, isolated
        // exactly: the dry path is never attenuated, so rendering the same source
        // at Mix 10 and Mix 0 and subtracting leaves `wet · echo` and nothing
        // else. An impulse is the wrong probe for a bandwidth question — its own
        // spectrum is flat, so every voicing reads ~90 % high-band and the
        // differences are squeezed into the last percent.
        let pluckSrc = pluckThenSilence(fmt, f0: 220, partials: 45, burstSec: 0.10,
                                        silenceSec: 1.9, decaySec: 0.030)
        func wetOf(_ name: String, _ keys: (time: String, fb: String, mix: String),
                   _ extra: [String: Double] = [:]) async -> [Float] {
            var wetVals: [String: Double] = [keys.time: timeKnob, keys.fb: fbKnob, keys.mix: 10]
            var dryVals: [String: Double] = [keys.time: timeKnob, keys.fb: fbKnob, keys.mix: 0]
            for (k, v) in extra { wetVals[k] = v; dryVals[k] = v }
            let a = await render(timePlan(.delay, name, wetVals), pluckSrc)
            let b = await render(timePlan(.delay, name, dryVals), pluckSrc)
            return Self.difference(a, b)
        }
        let wDig = await wetOf("VOSS Digital Delay", ("Time", "Feedback", "Mix"))
        let wTape = await wetOf("DUNLAP ECHOPLEX", ("Delay", "Sustain", "Volume"))
        let wBBD = await wetOf("electro-harmonium MEMORY MAN", ("Delay", "Feedback", "Blend"), ["Depth": 0])
        func repeatBand(_ s: [Float], _ k: Int) -> [Float] {
            let w = max(64, Int(0.09 * sr))
            let lo = max(0, k * D - w / 4), hi = min(s.count, k * D + w)
            return lo < hi ? Array(s[lo..<hi]) : []
        }
        let bDig = bright(repeatBand(wDig, 1), 2000)
        let bTape = bright(repeatBand(wTape, 1), 2000)
        let bBBD = bright(repeatBand(wBBD, 1), 2000)
        lines.append(String(format: "  repeat-1 hi>2k  : digital %.1f%%   tape %.1f%%   BBD %.1f%%   (wet path only)",
                            bDig, bTape, bBBD))
        checks.append(("delay voicings differ in repeat BANDWIDTH",
                       bDig > bTape + 1.0 && bTape > bBBD + 1.0,
                       String(format: "digital %.1f%% > tape %.1f%% > BBD %.1f%% (record-side LP 8k / 4k / 2.5k×2)",
                              bDig, bTape, bBBD)))
        // Per-repeat DEGRADATION: how much darker repeat 3 is than repeat 1. A
        // digital delay's loop filter is gentle, so it barely changes; tape and
        // BBD compound their losses every pass, which is the whole point.
        func degradation(_ s: [Float]) -> Double {
            let r1 = bright(repeatBand(s, 1), 2000), r3 = bright(repeatBand(s, 3), 2000)
            return r1 > 0 ? (r1 - r3) / r1 * 100 : 0
        }
        let dDig = degradation(wDig), dTape = degradation(wTape), dBBD = degradation(wBBD)
        lines.append(String(format: "  hi loss r1→r3   : digital %.1f%%   tape %.1f%%   BBD %.1f%%", dDig, dTape, dBBD))
        checks.append(("…and in PER-REPEAT degradation",
                       dTape > dDig + 3.0 && dBBD > dDig + 3.0,
                       String(format: "hi>2k lost from repeat 1 to 3: digital %.1f%%, tape %.1f%%, BBD %.1f%%",
                              dDig, dTape, dBBD)))
        checks.append(("…and are not each other (level-matched)",
                       Self.levelMatchedDiff(wDig, wTape) > 0.15
                       && Self.levelMatchedDiff(wTape, wBBD) > 0.15,
                       String(format: "residual dig/tape %.0f%%, tape/BBD %.0f%%",
                              Self.levelMatchedDiff(wDig, wTape) * 100,
                              Self.levelMatchedDiff(wTape, wBBD) * 100)))

        // ---- 3. TIME CHANGES: TWO OPPOSITE CORRECT BEHAVIOURS ---------------
        let sweepDigital = await delayTimeSweepTest(fmt: fmt, voicingName: "VOSS Digital Delay",
                                                    knobs: ["Time": 6, "Feedback": 9, "Mix": 10])
        let sweepTape = await delayTimeSweepTest(fmt: fmt, voicingName: "DUNLAP ECHOPLEX",
                                                 knobs: ["Delay": 6, "Sustain": 9, "Volume": 10])
        lines.append(String(format: "  time sweep      : digital %.0f Hz → %.0f Hz across the change (max |Δ| %.4f vs %.4f steady)",
                            sweepDigital.beforeHz, sweepDigital.duringHz, sweepDigital.switchJump, sweepDigital.steadyJump))
        lines.append(String(format: "                    tape    %.0f Hz → %.0f Hz across the change (max |Δ| %.4f vs %.4f steady)",
                            sweepTape.beforeHz, sweepTape.duringHz, sweepTape.switchJump, sweepTape.steadyJump))
        let digDrift = abs(sweepDigital.duringHz - sweepDigital.beforeHz) / max(sweepDigital.beforeHz, 1)
        let tapeDrift = abs(sweepTape.duringHz - sweepTape.beforeHz) / max(sweepTape.beforeHz, 1)
        checks.append(("digital time change is CLICK-FREE",
                       sweepDigital.finite && sweepDigital.switchJump < sweepDigital.steadyJump * 1.5,
                       String(format: "max |Δsample| %.4f across the change vs %.4f steady (×%.2f)",
                              sweepDigital.switchJump, sweepDigital.steadyJump,
                              Double(sweepDigital.switchJump / max(sweepDigital.steadyJump, 1e-9)))))
        checks.append(("digital time change does NOT bend pitch", digDrift < 0.05,
                       String(format: "repeats stay at %.0f Hz (%.1f%% drift) — the crossfade preserves pitch",
                              sweepDigital.duringHz, digDrift * 100)))
        checks.append(("tape time change DOES bend pitch (opposite, on purpose)",
                       tapeDrift > 0.08 && sweepTape.finite,
                       String(format: "repeats glide %.0f Hz → %.0f Hz (%.1f%%) — the read pointer slews",
                              sweepTape.beforeHz, sweepTape.duringHz, tapeDrift * 100)))

        // ---- 4. REVERB IS AUDIBLE AND STABLE --------------------------------
        let vBurst = burstThenSilence(fmt, hz: 220, burstSec: 0.4, silenceSec: 7.0)
        func reverbTail(_ decayKnob: Double, _ name: String = "VOSS Reverb") async -> [Float] {
            let out = await render(timePlan(.reverb, name, ["Decay": decayKnob, "Tone": 6, "Mix": 10]), vBurst)
            return Array(out.dropFirst(Int(0.45 * sr)))     // after the burst — pure tail
        }
        let tailLong = await reverbTail(8)
        let tailShort = await reverbTail(2)
        let rtLong = Self.rt60(tailLong, sr: sr), rtShort = Self.rt60(tailShort, sr: sr)
        let tailEnd = Array(tailLong.suffix(Int(0.5 * sr)))
        lines.append(String(format: "  reverb RT60     : Decay 2 → %.2f s   Decay 8 → %.2f s   (tail peak %.5f → last 0.5 s RMS %@)",
                            rtShort, rtLong, Double(Self.peak(tailLong)), Self.dbfs(Self.rms(tailEnd))))
        checks.append(("reverb is audible and its tail decays",
                       Self.peak(tailLong) > 1e-3 && Self.allFinite(tailLong)
                       && Self.rms(tailEnd) < Self.rms(Array(tailLong.prefix(Int(0.5 * sr)))) * 0.2,
                       String(format: "tail peak %.4f, first 0.5 s RMS %@ → last 0.5 s RMS %@",
                              Double(Self.peak(tailLong)),
                              Self.dbfs(Self.rms(Array(tailLong.prefix(Int(0.5 * sr))))),
                              Self.dbfs(Self.rms(tailEnd)))))
        checks.append(("reverb RT60 is in the specified range and tracks Decay",
                       rtLong > rtShort * 1.4 && rtLong > 0.8 && rtLong < 12.0 && rtShort > 0.2,
                       String(format: "Decay 2 → %.2f s, Decay 8 → %.2f s (spec: ~0.4 s … ~6 s)", rtShort, rtLong)))

        // ---- 5. DENORMAL SAFETY ---------------------------------------------
        let denorm = await reverbDenormalTest(fmt: fmt)
        lines.append(String(format: "  denormal probe  : %.1f µs/block with the tail live → %.1f µs/block after it decayed (×%.2f)",
                            denorm.loudUs, denorm.deadUs, denorm.ratio))
        checks.append(("CPU returns to baseline after the tail decays",
                       denorm.ratio < 2.0 && denorm.ratio > 0,
                       String(format: "%.1f µs → %.1f µs per block (×%.2f); a denormal stall is 10–100×",
                              denorm.loudUs, denorm.deadUs, denorm.ratio)))
        checks.append(("…and the decayed tank is EXACTLY zero, not merely small",
                       denorm.silent,
                       denorm.silent ? "every sample of the last block is 0.0 — states are flushed at 1e-20, "
                                     + "far above the 1.18e-38 denormal threshold"
                                     : String(format: "residual peak %.3e", denorm.residual)))

        // ---- 6. FEEDBACK IS BOUNDED, AND A NaN DOES NOT SURVIVE -------------
        // Maximum feedback, driven by real material, then left to ring.
        let hotSrc = burstThenSilence(fmt, hz: 196, burstSec: 1.0, silenceSec: 4.0, amplitude: 0.8)
        let hot = await render(timePlan(.delay, "VOSS Digital Delay",
                                        ["Time": 3, "Feedback": 10, "Mix": 10]), hotSrc)
        let hotQ1 = Self.rms(Array(hot[(hot.count / 4)..<(hot.count / 2)]))
        let hotQ4 = Self.rms(Array(hot.suffix(hot.count / 4)))
        checks.append(("max feedback does not run away", Self.allFinite(hot) && Self.peak(hot) < 4.0 && hotQ4 <= hotQ1,
                       String(format: "peak %.3f, finite, RMS %@ → %@ over the ring-out",
                              Double(Self.peak(hot)), Self.dbfs(hotQ1), Self.dbfs(hotQ4))))

        // A feedback coefficient ABOVE unity, pushed straight onto the bus so the
        // Swift-side clamp is bypassed — this tests the engine's own ceiling.
        var runaway = timePlan(.delay, "VOSS Digital Delay", ["Time": 3, "Feedback": 10, "Mix": 10])
        runaway.pedals[0].params[1] = 1.6
        runaway.signature = "time-runaway"
        let ran = await render(runaway, hotSrc)
        checks.append(("a feedback coefficient of 1.6 is clamped, not obeyed",
                       Self.allFinite(ran) && Self.peak(ran) < 4.0
                       && Self.rms(Array(ran.suffix(ran.count / 4))) <= Self.rms(Array(ran[(ran.count / 4)..<(ran.count / 2)])),
                       String(format: "peak %.3f and still decaying with fb pushed to 1.6", Double(Self.peak(ran)))))

        // NaN INJECTION. Eight NaN samples in the middle of the source. The
        // affected output samples are garbage-in/garbage-out, but the LOOP must
        // recover — a NaN that recirculates never leaves on its own.
        let nanSrc = burstThenSilence(fmt, hz: 300, burstSec: 1.5, silenceSec: 2.5, amplitude: 0.5)
        do {
            let ch = nanSrc.floatChannelData![0]
            for i in 0..<8 { ch[Int(0.5 * sr) + i] = Float.nan }
        }
        let nanDelay = await render(timePlan(.delay, "DUNLAP ECHOPLEX",
                                             ["Delay": 6, "Sustain": 9, "Volume": 10]), nanSrc)
        let nanVerb = await render(timePlan(.reverb, "electro-harmonium HOLY GRAIL", ["Reverb": 10]), nanSrc)
        let dTail = Array(nanDelay.suffix(nanDelay.count / 2))
        let vTail = Array(nanVerb.suffix(nanVerb.count / 2))
        checks.append(("a NaN injected into the input does not poison the loop",
                       Self.allFinite(dTail) && Self.allFinite(vTail),
                       "delay and reverb both finite over the second half, after 8 NaN input samples"))

        // ---- 7. THE FIVE PREVIOUSLY-SILENT CATALOG PEDALS -------------------
        var refPlan = RigDSPPlan()
        refPlan.ampBypass = true; refPlan.cabBypass = true; refPlan.signature = "time-ref"
        let ref = await render(refPlan, dry)
        let silent: [(String, GearCategory, [String: Double])] = [
            ("VOSS Digital Delay", .delay, ["Time": 5, "Feedback": 6, "Mix": 7]),
            ("DUNLAP ECHOPLEX", .delay, ["Volume": 7, "Sustain": 6, "Delay": 5]),
            ("electro-harmonium MEMORY MAN", .delay, ["Blend": 7, "Feedback": 6, "Delay": 5, "Depth": 6, "Rate": 5]),
            ("VOSS Reverb", .reverb, ["Decay": 7, "Tone": 6, "Mix": 8]),
            ("electro-harmonium HOLY GRAIL", .reverb, ["Reverb": 8]),
        ]
        var audible = true
        var detail: [String] = []
        var rendered: [[Float]] = []
        for (name, cat, vals) in silent {
            let out = await render(timePlan(cat, name, vals), dry)
            rendered.append(out)
            let d = Self.rms(Self.difference(out, ref))
            if d <= 1e-3 || !Self.allFinite(out) { audible = false }
            detail.append("\(name.prefix(22)) Δ\(Self.dbfs(d))")
            lines.append(rigLine(String(name.prefix(20)), out, sr))
        }
        checks.append(("all five formerly-silent pedals are audible", audible,
                       detail.joined(separator: " · ")))
        let distinctDelays = Self.levelMatchedDiff(rendered[0], rendered[1]) > 0.05
            && Self.levelMatchedDiff(rendered[1], rendered[2]) > 0.05
        let distinctVerbs = Self.levelMatchedDiff(rendered[3], rendered[4]) > 0.05
        checks.append(("…and the models are voiced distinctly", distinctDelays && distinctVerbs,
                       String(format: "DD/EP %.0f%%, EP/MM %.0f%%, RV/Grail %.0f%% residual",
                              Self.levelMatchedDiff(rendered[0], rendered[1]) * 100,
                              Self.levelMatchedDiff(rendered[1], rendered[2]) * 100,
                              Self.levelMatchedDiff(rendered[3], rendered[4]) * 100)))

        // ---- 8. KATANA FX ROUTING -------------------------------------------
        var katVals = Self.ampTestKnobs
        katVals["Character"] = 2; katVals["Variation"] = 0; katVals["Power"] = 2
        katVals["Booster"] = 3; katVals["Booster On"] = 1; katVals["Booster Level"] = 6
        katVals["Mod"] = 1; katVals["Mod On"] = 1; katVals["Mod Level"] = 5
        katVals["Delay"] = 1; katVals["Delay On"] = 1; katVals["Delay Level"] = 7; katVals["Delay Time"] = 5
        katVals["Reverb"] = 2; katVals["Reverb On"] = 1; katVals["Reverb Level"] = 7
        let katPlan = ampPlan("VOSS Katana 100", .comboAmp, values: katVals).plan
        let types = katPlan.pedals.map(\.type)
        let preTypes = Array(types.prefix(katPlan.splitPre))
        let midTypes = Array(types[katPlan.splitPre..<katPlan.splitPost])
        lines.append("  katana FX chain : \(katPlan.signature)")
        lines.append("  PRE \(preTypes)  MID \(midTypes)  POST \(Array(types.dropFirst(katPlan.splitPost)))")
        checks.append(("Booster + Mod route PRE-preamp; FX/Delay/Reverb route into the LOOP",
                       preTypes == [ParameterMap.typeDrive, ParameterMap.typeModulation]
                       && midTypes == [ParameterMap.typeDelay, ParameterMap.typeReverb],
                       "PRE \(preTypes) (drive \(ParameterMap.typeDrive), mod \(ParameterMap.typeModulation)); "
                       + "MID \(midTypes) (delay \(ParameterMap.typeDelay), reverb \(ParameterMap.typeReverb))"))

        // The routing must be AUDIBLE, not just declared: the same reverb block,
        // moved between the three spans, has to measure differently. In the loop
        // its tail is squashed by the output stage; after the cab it floats on
        // top of a finished signal; in front of the preamp the amp distorts the
        // reverb instead of the note.
        func spanPlan(_ pre: Int, _ post: Int) -> RigDSPPlan {
            var p = ampPlan("VOSS Katana 100", .comboAmp, values: {
                var v = Self.ampTestKnobs
                v["Character"] = 2; v["Variation"] = 0; v["Power"] = 2; v["Volume"] = 8
                v["Reverb"] = 2; v["Reverb On"] = 1; v["Reverb Level"] = 9
                return v
            }()).plan
            p.cabBypass = false
            p.splitPre = pre; p.splitPost = post
            p.signature = "span-\(pre)-\(post)"
            return p
        }
        let spanPre = await render(spanPlan(1, 1), dry)     // reverb in FRONT of the preamp
        let spanMid = await render(spanPlan(0, 1), dry)     // reverb in the LOOP (shipping)
        let spanPost = await render(spanPlan(0, 0), dry)    // reverb AFTER the cab
        let dPreMid = Self.levelMatchedDiff(spanPre, spanMid)
        let dMidPost = Self.levelMatchedDiff(spanMid, spanPost)
        lines.append(String(format: "  reverb by span  : pre↔mid %.0f%% residual, mid↔post %.0f%% residual",
                            dPreMid * 100, dMidPost * 100))
        checks.append(("the same block sounds different in each span",
                       dPreMid > 0.10 && dMidPost > 0.10,
                       String(format: "pre-preamp vs loop %.0f%%, loop vs post-cab %.0f%% (level-matched)",
                              dPreMid * 100, dMidPost * 100)))

        // ---- 9. BLOCK ON/OFF IS CONTINUOUS ----------------------------------
        func katSig(_ overrides: [String: Double]) -> String {
            var v = katVals
            for (k, x) in overrides { v[k] = x }
            return ampPlan("VOSS Katana 100", .comboAmp, values: v).plan.signature
        }
        let sigOn = katSig([:])
        checks.append(("a block's ON/OFF does NOT move the topology signature",
                       katSig(["Reverb On": 0]) == sigOn && katSig(["Booster On": 0]) == sigOn,
                       "stomping a block takes the same lock-free path an AR footswitch does"))
        checks.append(("a block's LEVEL knob does not move it either",
                       katSig(["Reverb Level": 1, "Delay Level": 2, "Booster Level": 9]) == sigOn,
                       "knob turns never rebuild the chain"))
        checks.append(("a block's TYPE selection IS structural",
                       katSig(["Reverb": 4]) != sigOn && katSig(["Delay": 0]) != sigOn,
                       "changing type re-voices a slot; turning a block Off frees it"))

        // ---- 10. CHANNEL PRESETS ---------------------------------------------
        let chOK = katanaChannelRoundTrip()
        checks.append(("a channel memory stores and recalls the whole panel", chOK.pass, chOK.detail))
        let chClick = await channelSwitchClickTest(fmt: fmt)
        checks.append(("switching channels mid-render is click-free", chClick.clickFree,
                       String(format: "max |Δsample| %.4f across the switch vs %.4f steady (×%.2f)",
                              chClick.switchJump, chClick.steadyJump, chClick.ratio)))
        let hostFX = await auv3FXStateRoundTrip()
        checks.append(("the FX panel survives an AUv3 fullState round-trip", hostFX.pass, hostFX.detail))

        // ---- 11. LATENCY AND THE ARENA ---------------------------------------
        let lat = await latencyAndArenaProbe(fmt: fmt)
        lines.append(String(format: "  arena           : %.2f MB reserved (8 slots × 2 ch × %d floats)",
                            Double(lat.arenaBytes) / (1024 * 1024), lat.arenaBytes / (8 * 2 * 4)))
        lines.append("  latency         : cab \(lat.cabOnly) samples · with delay+reverb in the chain \(lat.withBlocks) samples "
                     + String(format: "(reported %.3f ms)", lat.reportedMs))
        checks.append(("neither block adds reported latency", lat.cabOnly == lat.withBlocks,
                       "cab convolver \(lat.cabOnly) samples is still the whole of it — both blocks sum a wet send "
                       + "against an UNDELAYED dry path, so their group delay at DC is zero"))
        checks.append(("the host-reported latency matches the composed total",
                       abs(lat.reportedMs - Double(lat.withBlocks) / sr * 1000) < 0.01,
                       String(format: "AUAudioUnit.latency %.3f ms == %d samples @ %.0f Hz",
                              lat.reportedMs, lat.withBlocks, sr)))
        let expectedArena = 8 * 2 * 131_072 * 4
        checks.append(("the arena is the documented worst case, allocated once",
                       lat.arenaBytes == expectedArena,
                       String(format: "%d bytes = 8 slots × 2 ch × 131072 floats × 4 B (%.1f MB) @ 48 kHz",
                              lat.arenaBytes, Double(lat.arenaBytes) / (1024 * 1024))))

        // ---- 12. ROUND-TRIP IDENTITY FOR EVERY NEW CURVE ---------------------
        var worst = 0.0, worstName = ""
        func rt(_ name: String, _ fwd: (Double) -> Float, _ inv: (Float) -> Double) {
            for i in 0...20 {
                let knob = Double(i) * 0.5
                let e = abs(inv(fwd(knob)) - knob)
                if e > worst { worst = e; worstName = name }
            }
        }
        rt("delayTime", { ParameterMap.delayTimeMs($0) }, { ParameterMap.invDelayTimeKnob($0) })
        rt("delayFeedback", { ParameterMap.delayFeedback($0) }, { ParameterMap.invDelayFeedbackKnob($0) })
        rt("delayMix", { ParameterMap.delayMix($0) }, { ParameterMap.invDelayMixKnob($0) })
        rt("delayTone", { ParameterMap.delayToneHz($0) }, { ParameterMap.invDelayToneKnob($0) })
        rt("delayModDepth", { ParameterMap.delayModDepth($0) }, { ParameterMap.invDelayModDepthKnob($0) })
        rt("reverbDecay", { ParameterMap.reverbDecay($0) }, { ParameterMap.invReverbDecayKnob($0) })
        rt("reverbTone", { ParameterMap.reverbToneHz($0) }, { ParameterMap.invReverbToneKnob($0) })
        rt("reverbMix", { ParameterMap.reverbMix($0) }, { ParameterMap.invReverbMixKnob($0) })
        checks.append(("every new curve round-trips knob → bus → knob", worst < 1e-4,
                       String(format: "max error %.2e (worst: %@)", worst, worstName)))

        // A rig saved before any of this existed must compile to the same chain.
        let oldJSON = """
        {"id":"\(UUID().uuidString)","name":"VOSS Katana 100","category":"comboAmp",
         "values":{"Gain":6,"Bass":5,"Mid":5,"Treble":5,"Presence":5,"Master":6}}
        """
        var backCompat = false, bcDetail = "could not decode the legacy GearItem JSON"
        if let data = oldJSON.data(using: .utf8),
           let oldAmp = try? JSONDecoder().decode(GearItem.self, from: data) {
            let guitar = GearItem(name: "Les Paul Standard", category: .guitar)
            let plan = RigGraphCompiler.compile(
                collection: [guitar, oldAmp],
                rig: RigConfiguration(guitarId: guitar.id,
                                      ampSection: .combo(comboId: oldAmp.id), pedalIds: []))
            backCompat = plan.pedals.isEmpty && plan.splitPre == 0 && plan.splitPost == 0
            bcDetail = "no FX keys → \(plan.pedals.count) slots, split \(plan.splitPre)/\(plan.splitPost) "
                + "— every block defaults to Off, so the chain is the one it always was"
        }
        checks.append(("a rig saved before the FX section loads unchanged", backCompat, bcDetail))

        // ---- Cost with the WHOLE Katana panel lit ----------------------------
        let liveDeadlineUs = 128.0 / sr * 1_000_000
        var costLines: [String] = []
        for (label, values) in [("Katana, no FX", { () -> [String: Double] in
                                    var v = Self.ampTestKnobs
                                    v["Character"] = 2; v["Variation"] = 0; v["Power"] = 2
                                    return v }()),
                                ("+ delay only", { () -> [String: Double] in
                                    var v = Self.ampTestKnobs
                                    v["Character"] = 2; v["Variation"] = 0; v["Power"] = 2
                                    v["Delay"] = 1; v["Delay On"] = 1; v["Delay Level"] = 7; v["Delay Time"] = 5
                                    return v }()),
                                ("+ reverb only", { () -> [String: Double] in
                                    var v = Self.ampTestKnobs
                                    v["Character"] = 2; v["Variation"] = 0; v["Power"] = 2
                                    v["Reverb"] = 2; v["Reverb On"] = 1; v["Reverb Level"] = 7
                                    return v }()),
                                ("FULL FX panel (5)", { () -> [String: Double] in
                                    var v = Self.ampTestKnobs
                                    v["Character"] = 2; v["Variation"] = 0; v["Power"] = 2
                                    v["Booster"] = 3; v["Booster On"] = 1; v["Booster Level"] = 6
                                    v["Mod"] = 1; v["Mod On"] = 1; v["Mod Level"] = 5
                                    v["FX"] = 1; v["FX On"] = 1; v["FX Level"] = 5
                                    v["Delay"] = 3; v["Delay On"] = 1; v["Delay Level"] = 7; v["Delay Time"] = 5
                                    v["Reverb"] = 4; v["Reverb On"] = 1; v["Reverb Level"] = 7
                                    return v }())] {
            var plan = ampPlan("VOSS Katana 100", .comboAmp, values: values).plan
            plan.cabBypass = false                    // FULL board cost, cab included
            let out = (try? await renderRigPlan(plan, source: dry, fmt: fmt, benchmarkFull: true)) ?? PassOutput()
            let us = out.fullNsPerSample * 128 / 1000
            costLines.append(String(format: "  %@ : %.1f ns/sample → %.1f µs/128-frame block = %.2f%% of the ~%.0f µs budget",
                                    label.padding(toLength: 19, withPad: " ", startingAt: 0),
                                    out.fullNsPerSample, us, us / liveDeadlineUs * 100, liveDeadlineUs))
        }

        let allPass = checks.allSatisfy { $0.1 }
        var out = """
        === SHARED TIME BLOCKS — delay, reverb and the Katana FX section ===
        Method        : one block per pass, amp + cab BYPASSED unless the check is about routing,
                        rendered through the real AU graph. Repeats and tails are measured AFTER
                        the dry signal has passed, so nothing is flattered by the dry path.

        \(lines.joined(separator: "\n"))

        --- Checks ---

        """
        for (name, ok, d) in checks {
            let pad = name.padding(toLength: 54, withPad: " ", startingAt: 0)
            out += "  \(pad) \(ok ? "PASS" : "FAIL")   (\(d))\n"
        }
        out += """

        --- Render cost with the Katana's FX panel ---
        \(costLines.joined(separator: "\n"))
        TIME BLOCKS OVERALL: \(allPass ? "PASS" : "SOME CHECKS FAILED")
        === END TIME BLOCKS ===
        """
        return (out, allPass)
    }

    /// Sweep a delay's Time knob DOWN in the middle of a live render and measure
    /// both things that can go wrong: the seam (a click) and the pitch of the
    /// repeats (a glide). The source is a burst followed by silence, so what is
    /// measured across the change is the WET path alone.
    private func delayTimeSweepTest(fmt: AVAudioFormat, voicingName: String, knobs: [String: Double])
        async -> (finite: Bool, steadyJump: Float, switchJump: Float, beforeHz: Double, duringHz: Double) {
        let sr = fmt.sampleRate
        // A LONG burst at high feedback, so once the source goes quiet the delay
        // is left holding a continuous 440 Hz drone of its own repeats. That is
        // the only condition under which "did the pitch move?" is a clean
        // question: no dry signal to average against, and no gaps between
        // repeats for the estimator to fall into.
        let src = burstThenSilence(fmt, hz: 440, burstSec: 1.2, silenceSec: 4.0, amplitude: 0.6)

        StreetRigDSPUnit.registerIfNeeded()
        guard let unit = try? await Self.instantiateDSPUnit() else { return (false, 0, 0, 0, 0) }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player); engine.attach(unit)
        engine.connect(player, to: unit, format: fmt)
        engine.connect(unit, to: engine.mainMixerNode, format: fmt)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: fmt)
        let maxFrames: AVAudioFrameCount = 128
        guard (try? engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: maxFrames)) != nil,
              (try? engine.start()) != nil,
              let rb = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames),
              let dsp = unit.auAudioUnit as? StreetRigDSPUnit else { return (false, 0, 0, 0, 0) }

        let category = GearCategory.delay
        let plan = timePlan(category, voicingName, knobs)
        RigGraphCompiler.applyImmediate(plan, to: dsp)
        player.scheduleBuffer(src, at: nil, options: [], completionHandler: nil)
        player.play()

        func renderChunks(_ count: Int) -> [Float] {
            var out: [Float] = []
            for _ in 0..<count where (try? engine.renderOffline(maxFrames, to: rb)) == .some(.success) {
                let c = Int(rb.frameLength)
                if let cd = rb.floatChannelData { for i in 0..<c { out.append(cd[0][i]) } }
            }
            return out
        }
        func maxJump(_ s: [Float]) -> Float {
            guard s.count > 1 else { return 0 }
            var m: Float = 0
            for i in 1..<s.count { m = max(m, abs(s[i] - s[i - 1])) }
            return m
        }

        _ = renderChunks(470)                       // past the burst: only repeats now
        let before = renderChunks(100)              // the drone, steady, at the set time
        // Sweep the time DOWN over the next window, one push per block — the way
        // a knob drag actually arrives.
        var across: [Float] = []
        let timeKey = knobs.keys.contains("Time") ? "Time" : "Delay"
        let startKnob = knobs[timeKey] ?? 6
        for step in 0..<150 {
            let k = startKnob - 3.0 * Double(step) / 149.0
            var v = knobs; v[timeKey] = k
            let params = ParameterMap.pedalParams(category: category, values: v)
            dsp.setPedalParam(slot: 0, field: Int(SRPedalFieldDrive), value: params[0])
            across += renderChunks(1)
        }
        let after = renderChunks(60)
        player.stop(); engine.stop()

        let steadyJump = max(maxJump(before), maxJump(after))
        return (Self.allFinite(before + across + after), steadyJump, maxJump(across),
                Self.zeroCrossHz(before, sr: sr), Self.zeroCrossHz(across, sr: sr))
    }

    /// THE DENORMAL PROBE. Render a burst into a reverb, let the tail decay for
    /// long enough that an unprotected tank would be deep in denormal territory,
    /// and time the SILENT blocks against the loud ones. A denormal stall is
    /// 10–100× — it is the classic way an amp sim starts dropping out minutes
    /// after the player stopped playing, on a rig that is doing nothing.
    private func reverbDenormalTest(fmt: AVAudioFormat)
        async -> (loudUs: Double, deadUs: Double, ratio: Double, silent: Bool, residual: Float) {
        let sr = fmt.sampleRate
        // Decay 0 so the tail is genuinely over inside the render: a long decay
        // would still be ringing (correctly) and the probe would measure a live
        // tail, not a dead one.
        let src = burstThenSilence(fmt, hz: 220, burstSec: 0.3, silenceSec: 14.0, amplitude: 0.7)

        StreetRigDSPUnit.registerIfNeeded()
        guard let unit = try? await Self.instantiateDSPUnit() else { return (0, 0, 0, false, 0) }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player); engine.attach(unit)
        engine.connect(player, to: unit, format: fmt)
        engine.connect(unit, to: engine.mainMixerNode, format: fmt)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: fmt)
        let maxFrames: AVAudioFrameCount = 128
        guard (try? engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: maxFrames)) != nil,
              (try? engine.start()) != nil,
              let rb = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames),
              let dsp = unit.auAudioUnit as? StreetRigDSPUnit else { return (0, 0, 0, false, 0) }

        RigGraphCompiler.applyImmediate(timePlan(.reverb, "VOSS Reverb",
                                                 ["Decay": 0, "Tone": 6, "Mix": 10]), to: dsp)
        player.scheduleBuffer(src, at: nil, options: [], completionHandler: nil)
        player.play()

        @discardableResult
        func renderChunks(_ count: Int) -> [Float] {
            var out: [Float] = []
            for _ in 0..<count where (try? engine.renderOffline(maxFrames, to: rb)) == .some(.success) {
                let c = Int(rb.frameLength)
                if let cd = rb.floatChannelData { for i in 0..<c { out.append(cd[0][i]) } }
            }
            return out
        }
        func timed(_ count: Int) -> (Double, [Float]) {
            let t0 = Date()
            let s = renderChunks(count)
            return (Date().timeIntervalSince(t0) / Double(count) * 1_000_000, s)
        }

        renderChunks(120)                                 // through the burst
        let (loudUs, _) = timed(400)                      // the tail at full level
        renderChunks(Int(10.0 * sr / 128))                // ~10 s of silence: the tail dies
        let (deadUs, deadSamples) = timed(400)            // …and now the same work on nothing
        player.stop(); engine.stop()

        let residual = Self.peak(deadSamples)
        return (loudUs, deadUs, deadUs / max(loudUs, 1e-9), residual == 0, residual)
    }

    /// Store two different panels into two channel slots, recall each, and prove
    /// the whole panel — dials, selectors and FX blocks — comes back byte for
    /// byte. This is the persistence half of "channel memories"; the audible half
    /// is `channelSwitchClickTest`.
    private func katanaChannelRoundTrip() -> (pass: Bool, detail: String) {
        let ampName = "VOSS Katana 100"
        let a: [String: Double] = ["Gain": 3, "Bass": 6, "Mid": 4, "Treble": 7, "Presence": 5,
                                   "Volume": 5, "Master": 6, "Character": 1, "Variation": 0, "Power": 2,
                                   "Reverb": 2, "Reverb On": 1, "Reverb Level": 4,
                                   "Delay": 0, "Delay On": 1, "Delay Level": 5, "Delay Time": 5]
        let b: [String: Double] = ["Gain": 9, "Bass": 4, "Mid": 7, "Treble": 6, "Presence": 8,
                                   "Volume": 8, "Master": 5, "Character": 4, "Variation": 1, "Power": 0,
                                   "Reverb": 4, "Reverb On": 0, "Reverb Level": 9,
                                   "Delay": 3, "Delay On": 1, "Delay Level": 8, "Delay Time": 7]
        KatanaChannelStore.save(ampName: ampName, values: a, channel: 0)
        KatanaChannelStore.save(ampName: ampName, values: b, channel: 1)
        let ra = KatanaChannelStore.load(channel: 0, ampName: ampName)?.values
        let rb = KatanaChannelStore.load(channel: 1, ampName: ampName)?.values
        // A channel stored from one amp must NOT be recalled onto another — the
        // keys would be meaningless, and half-applying them would be worse than
        // refusing.
        let wrongAmp = KatanaChannelStore.load(channel: 0, ampName: "Marswell JCM800 2203")
        // …and the panels must compile to DIFFERENT chains, or the round-trip
        // would be proving nothing but that a dictionary survives JSON.
        let guitar = GearItem(name: "Les Paul Standard", category: .guitar)
        func sig(_ v: [String: Double]) -> String {
            var amp = GearItem(name: ampName, category: .comboAmp)
            for (k, x) in v { amp.values[k] = x }
            return RigGraphCompiler.compile(
                collection: [guitar, amp],
                rig: RigConfiguration(guitarId: guitar.id,
                                      ampSection: .combo(comboId: amp.id), pedalIds: [])).signature
        }
        let ok = ra == a && rb == b && wrongAmp == nil && sig(a) != sig(b)
        KatanaChannelStore.clear(channel: 0); KatanaChannelStore.clear(channel: 1)
        return (ok, "CH1 \(ra == a ? "exact" : "MISMATCH"), CH2 \(rb == b ? "exact" : "MISMATCH"), "
                + "cross-amp recall refused: \(wrongAmp == nil), "
                + "and the two compile to different chains: \(sig(a) != sig(b))")
    }

    /// Switch channels in the MIDDLE of a live render and measure the seam. The
    /// two channels here differ only in continuous values, which is the case that
    /// must not click at all — a channel that also changes Character takes the
    /// fade/park barrier, which `barrierFadeTest` already covers.
    private func channelSwitchClickTest(fmt: AVAudioFormat)
        async -> (clickFree: Bool, steadyJump: Float, switchJump: Float, ratio: Double) {
        let sr = fmt.sampleRate
        let n = Int(2.5 * sr)
        guard let src = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else {
            return (false, 0, 0, 0)
        }
        src.frameLength = AVAudioFrameCount(n)
        if let cd = src.floatChannelData {
            for i in 0..<n { cd[0][i] = Float(0.3 * sin(2.0 * Double.pi * 220.0 * Double(i) / sr)) }
        }

        StreetRigDSPUnit.registerIfNeeded()
        guard let unit = try? await Self.instantiateDSPUnit() else { return (false, 0, 0, 0) }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player); engine.attach(unit)
        engine.connect(player, to: unit, format: fmt)
        engine.connect(unit, to: engine.mainMixerNode, format: fmt)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: fmt)
        let maxFrames: AVAudioFrameCount = 128
        guard (try? engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: maxFrames)) != nil,
              (try? engine.start()) != nil,
              let rb = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames),
              let dsp = unit.auAudioUnit as? StreetRigDSPUnit else { return (false, 0, 0, 0) }

        func panel(_ gain: Double, _ volume: Double, _ reverbLevel: Double) -> [String: Double] {
            var v = Self.ampTestKnobs
            v["Character"] = 2; v["Variation"] = 0; v["Power"] = 2
            v["Gain"] = gain; v["Volume"] = volume
            v["Reverb"] = 2; v["Reverb On"] = 1; v["Reverb Level"] = reverbLevel
            v["Delay"] = 1; v["Delay On"] = 1; v["Delay Level"] = 5; v["Delay Time"] = 5
            return v
        }
        let planA = ampPlan("VOSS Katana 100", .comboAmp, values: panel(4, 5, 3)).plan
        var planB = ampPlan("VOSS Katana 100", .comboAmp, values: panel(8, 8, 9)).plan
        planB.cabBypass = planA.cabBypass
        RigGraphCompiler.applyImmediate(planA, to: dsp)
        player.scheduleBuffer(src, at: nil, options: [], completionHandler: nil)
        player.play()

        func renderChunks(_ count: Int) -> [Float] {
            var out: [Float] = []
            for _ in 0..<count where (try? engine.renderOffline(maxFrames, to: rb)) == .some(.success) {
                let c = Int(rb.frameLength)
                if let cd = rb.floatChannelData { for i in 0..<c { out.append(cd[0][i]) } }
            }
            return out
        }
        func maxJump(_ s: [Float]) -> Float {
            guard s.count > 1 else { return 0 }
            var m: Float = 0
            for i in 1..<s.count { m = max(m, abs(s[i] - s[i - 1])) }
            return m
        }

        _ = renderChunks(80)
        let before = renderChunks(30)
        // Same signature (both channels are Crunch A with the same blocks), so a
        // channel recall is a CONTINUOUS push, exactly as the compiler decides.
        let sameTopology = planA.signature == planB.signature
        RigGraphCompiler.pushValues(planB, to: dsp)
        let across = renderChunks(10)
        let after = renderChunks(30)
        player.stop(); engine.stop()

        let steadyJump = max(maxJump(before), maxJump(after))
        let ratio = steadyJump > 1e-6 ? Double(maxJump(across) / steadyJump) : 0
        let finite = Self.allFinite(before + across + after)
        return (sameTopology && finite && ratio > 0 && ratio < 1.25
                && Self.peak(across) < max(Self.peak(before), Self.peak(after)) * 1.25,
                steadyJump, maxJump(across), ratio)
    }

    /// The FX panel is `GearItem.values`, so it rides inside the rig blob a host
    /// already saves. Prove it: set a full panel on one unit, hand its
    /// `fullState` to another, and read the FX keys back out.
    private func auv3FXStateRoundTrip() async -> (pass: Bool, detail: String) {
        StreetRigDSPUnit.registerIfNeeded()
        guard let unitA = try? await Self.instantiateDSPUnit(),
              let unitB = try? await Self.instantiateDSPUnit(),
              let a = unitA.auAudioUnit as? StreetRigDSPUnit,
              let b = unitB.auAudioUnit as? StreetRigDSPUnit else {
            return (false, "could not instantiate two units")
        }
        // Factory preset 3 is "Katana Crunch"; select it, then write an FX panel
        // through the same `fullState` a host would.
        let guitarId = UUID(), ampId = UUID()
        let blob: [String: Any] = [
            "catalogVersion": 3,
            "collection": [
                ["id": guitarId.uuidString, "name": "Les Paul Standard",
                 "category": "guitar", "values": [String: Double]()],
                ["id": ampId.uuidString, "name": "VOSS Katana 100", "category": "comboAmp",
                 "values": ["Gain": 6, "Bass": 5, "Mid": 5, "Treble": 5, "Presence": 5, "Master": 6,
                            "Volume": 6, "Character": 3, "Variation": 1, "Power": 1,
                            "Delay": 3, "Delay On": 1, "Delay Level": 8, "Delay Time": 7,
                            "Reverb": 4, "Reverb On": 1, "Reverb Level": 6]],
            ],
            "rig": ["guitarId": guitarId.uuidString,
                    "ampSection": ["combo": ["comboId": ampId.uuidString]],
                    "pedalIds": [String]()],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: blob) else {
            return (false, "could not build the rig blob")
        }
        a.fullState = ["streetrig.rig.v1": data]
        b.fullState = a.fullState
        // Decode what came out the other side and compile it, which is the only
        // check that matters: does the restored blob produce the same CHAIN?
        guard let out = b.fullState?["streetrig.rig.v1"] as? Data,
              let json = try? JSONSerialization.jsonObject(with: out) as? [String: Any],
              let coll = json["collection"] as? [[String: Any]],
              let amp = coll.first(where: { ($0["name"] as? String) == "VOSS Katana 100" }),
              let values = amp["values"] as? [String: Double] else {
            return (false, "the rig blob did not survive the round-trip")
        }
        let slots = ParameterMap.ampFXSlots(name: "VOSS Katana 100", values: values)
        let profileOK = b.configuredAmpProfile == ParameterMap.ampKatanaBase + 3 * 2 + 1   // Lead B
        let fxOK = slots.count == 2
            && slots.contains { $0.type == ParameterMap.typeDelay && $0.voicing == ParameterMap.delayTape }
            && slots.contains { $0.type == ParameterMap.typeReverb && $0.voicing == ParameterMap.reverbHall }
        return (profileOK && fxOK,
                "restored profile \(b.configuredAmpProfile) (Katana Lead B), "
                + "FX blocks \(slots.map { "\($0.name)/\($0.voicing)" }) — tape delay + hall reverb, "
                + "both still in the loop span")
    }

    /// Reported latency with the time-based blocks live, plus the arena's real
    /// size read back off the kernel.
    private func latencyAndArenaProbe(fmt: AVAudioFormat)
        async -> (cabOnly: Int, withBlocks: Int, reportedMs: Double, arenaBytes: Int) {
        StreetRigDSPUnit.registerIfNeeded()
        guard let unit = try? await Self.instantiateDSPUnit() else { return (0, 0, 0, 0) }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player); engine.attach(unit)
        engine.connect(player, to: unit, format: fmt)
        engine.connect(unit, to: engine.mainMixerNode, format: fmt)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: fmt)
        guard (try? engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 512)) != nil,
              (try? engine.start()) != nil,
              let dsp = unit.auAudioUnit as? StreetRigDSPUnit else { return (0, 0, 0, 0) }

        // Cab alone (no pedals at all).
        var bare = RigDSPPlan(); bare.signature = "lat-bare"
        RigGraphCompiler.applyImmediate(bare, to: dsp)
        let cabOnly = dsp.cabLatencySamples

        // …and now with a delay AND a reverb live in the chain.
        var loaded = RigDSPPlan()
        loaded.pedals = [
            .init(type: ParameterMap.typeDelay, character: ParameterMap.delayTape, enabled: true,
                  params: ParameterMap.pedalParams(category: .delay,
                                                   values: ["Time": 6, "Feedback": 6, "Mix": 7])),
            .init(type: ParameterMap.typeReverb, character: ParameterMap.reverbHall, enabled: true,
                  params: ParameterMap.pedalParams(category: .reverb,
                                                   values: ["Decay": 8, "Tone": 6, "Mix": 7])),
        ]
        loaded.splitPre = 0; loaded.splitPost = 2
        loaded.signature = "lat-loaded"
        RigGraphCompiler.applyImmediate(loaded, to: dsp)
        let withBlocks = dsp.cabLatencySamples
        let reportedMs = unit.auAudioUnit.latency * 1000
        let arena = Int(dsp.pedalArenaBytes)
        engine.stop()
        return (cabOnly, withBlocks, reportedMs, arena)
    }

    // MARK: - Result plumbing

    private func finishOffline(success: Bool, summary: String, wav: String?) -> OfflineRenderResult {
        let result = OfflineRenderResult(success: success, summary: summary, wavPath: wav)
        setLastRenderReport(summary)
        try? summary.data(using: .utf8)?.write(to: Self.documentsURL("StreetRig_offline_report.txt"))
        return result
    }

    // MARK: - Source signals

    private func loadBundledDI(targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        // The DI placeholder now ships in StreetRigEngine.framework, not the app
        // bundle — resolve the framework bundle via one of its classes.
        guard let url = Bundle(for: StreetRigDSPUnit.self).url(forResource: "StreetRig_DI_placeholder", withExtension: "wav"),
              let file = try? AVAudioFile(forReading: url) else { return nil }
        let fileFormat = file.processingFormat
        guard let src = AVAudioPCMBuffer(pcmFormat: fileFormat,
                                         frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: src)) != nil else { return nil }
        if fileFormat == targetFormat { return src }
        guard let converter = AVAudioConverter(from: fileFormat, to: targetFormat) else { return src }
        let ratio = targetFormat.sampleRate / fileFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(src.frameLength) * ratio) + 2048
        guard let dst = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return src }
        var provided = false
        let status = converter.convert(to: dst, error: nil) { _, outStatus in
            if provided { outStatus.pointee = .noDataNow; return nil }
            provided = true; outStatus.pointee = .haveData; return src
        }
        return status == .haveData || status == .inputRanDry ? dst : src
    }

    /// Deterministic three-note plucked-string-ish signal (no randomness) so the
    /// null test is reproducible. PLACEHOLDER — swap for a real dry guitar DI.
    static func generateTestSignal(format: AVAudioFormat, seconds: Double) -> AVAudioPCMBuffer {
        let sr = format.sampleRate
        let n = Int(seconds * sr)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buffer.frameLength = AVAudioFrameCount(n)
        let ch = buffer.floatChannelData![0]
        let twoPi = 2.0 * Double.pi
        let notes: [Double] = [110.0, 146.83, 196.0]
        let noteDur = seconds / Double(notes.count)
        for i in 0..<n {
            let t = Double(i) / sr
            let idx = min(notes.count - 1, Int(t / noteDur))
            let f0 = notes[idx]
            let lt = t - Double(idx) * noteDur
            let env = exp(-3.0 * lt)
            var s = sin(twoPi * f0 * lt)
            s += 0.5 * sin(twoPi * 2 * f0 * lt)
            s += 0.25 * sin(twoPi * 3 * f0 * lt)
            s += 0.12 * sin(twoPi * 4 * f0 * lt)
            ch[i] = Float(0.35 * env * s)
        }
        return buffer
    }

    // MARK: - WAV writing (float32 mono)

    static func writeWav(_ samples: [Float], to url: URL, format: AVAudioFormat) throws {
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 4096
        var i = 0
        while i < samples.count {
            let c = min(chunk, samples.count - i)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(c)) else { break }
            buf.frameLength = AVAudioFrameCount(c)
            if let cd = buf.floatChannelData { for k in 0..<c { cd[0][k] = samples[i + k] } }
            try file.write(from: buf)
            i += c
        }
    }

    // MARK: - Analysis

    struct Analysis {
        var inPeak: Float, inRMS: Float
        var outPeak: Float, outRMSAligned: Float
        var nullRMS: Float
        var bestLag: Int
    }

    static func channelSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let cd = buffer.floatChannelData else { return [] }
        let m = cd[0]
        return (0..<Int(buffer.frameLength)).map { m[$0] }
    }

    static func peak(_ a: [Float]) -> Float { a.reduce(0) { max($0, abs($1)) } }
    static func rms(_ a: [Float]) -> Float {
        guard !a.isEmpty else { return 0 }
        let sum = a.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(a.count)).squareRoot()
    }

    /// RMS of the first vs second half of a signal — for loud→quiet dynamics tests.
    static func halves(_ s: [Float]) -> (loud: Float, quiet: Float) {
        let h = s.count / 2
        guard h > 0 else { return (0, 0) }
        return (rms(Array(s[0..<h])), rms(Array(s[h..<s.count])))
    }

    /// The last `frac` fraction of a signal (for gate-tail / decay measurements).
    static func tail(_ s: [Float], _ frac: Double) -> [Float] {
        let k = max(0, min(s.count, Int(Double(s.count) * frac)))
        return Array(s.suffix(k))
    }

    /// Sample-wise difference over the overlapping length (both starting at 0).
    static func difference(_ a: [Float], _ b: [Float]) -> [Float] {
        let n = min(a.count, b.count)
        var d = [Float](repeating: 0, count: n)
        for i in 0..<n { d[i] = a[i] - b[i] }
        return d
    }

    /// High-band energy fraction: RMS of the signal above `cutoff` / RMS of the
    /// whole signal, via a 2nd-order RBJ high-pass. Distortion pushes this up; the
    /// cab IR pulls it down.
    static func brightness(_ x: [Float], sr: Double, cutoff: Double) -> Float {
        guard !x.isEmpty else { return 0 }
        let w0 = 2 * Double.pi * cutoff / sr
        let cw = cos(w0), sw = sin(w0), alpha = sw / (2 * 0.707)
        let a0 = 1 + alpha
        let b0 = Float((1 + cw) / 2 / a0), b1 = Float(-(1 + cw) / a0), b2 = Float((1 + cw) / 2 / a0)
        let a1 = Float(-2 * cw / a0), a2 = Float((1 - alpha) / a0)
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        var sumH: Float = 0, sumF: Float = 0
        for s in x {
            let y = b0 * s + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = s; y2 = y1; y1 = y
            sumH += y * y; sumF += s * s
        }
        let rmsF = (sumF / Float(x.count)).squareRoot()
        let rmsH = (sumH / Float(x.count)).squareRoot()
        return rmsF > 1e-9 ? rmsH / rmsF : 0
    }

    static func analyze(input: [Float], output: [Float]) -> Analysis {
        let inPeak = peak(input)
        let inRMS = rms(input)
        let outPeak = peak(output)

        let maxLag = min(2048, max(0, output.count - input.count))
        var bestLag = 0
        var bestSum = Float.greatestFiniteMagnitude
        let count = input.count
        if count > 0 {
            for lag in 0...maxLag {
                var sum: Float = 0
                var i = 0
                while i < count {
                    let d = output[lag + i] - input[i]
                    sum += d * d
                    i += 1
                }
                if sum < bestSum { bestSum = sum; bestLag = lag }
            }
        }
        let nullRMS = count > 0 ? (bestSum / Float(count)).squareRoot() : 0
        var alignedSum: Float = 0
        for i in 0..<count where bestLag + i < output.count {
            let v = output[bestLag + i]; alignedSum += v * v
        }
        let outRMSAligned = count > 0 ? (alignedSum / Float(count)).squareRoot() : 0
        return Analysis(inPeak: inPeak, inRMS: inRMS,
                        outPeak: outPeak, outRMSAligned: outRMSAligned,
                        nullRMS: nullRMS, bestLag: bestLag)
    }

    /// Formats THE shared dBFS conversion (`AudioLevelBus.dbfs`) — the same one
    /// the live signal meters use — so the report and the meters can never drift.
    static func dbfs(_ value: Float) -> String {
        String(format: "%.1f", AudioLevelBus.dbfs(value))
    }

    static func documentsURL(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent(name)
    }
}
