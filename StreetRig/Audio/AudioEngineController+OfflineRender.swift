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
            let combined = [report, rig.text, fam.text, meter.text, foot.text].joined(separator: "\n\n")
            let overall = allPass && rig.pass && fam.pass && meter.pass && foot.pass
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
                               benchmarkFull: Bool = false) async throws -> PassOutput {
        try await renderCore(source: source, fmt: fmt, benchmarkFull: benchmarkFull) { dsp in
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

        // (c) swap the whole amp section stack → combo (Fender Deluxe = different cab).
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
