//
//  AudioLevelMonitor.swift
//  StreetRig
//
//  THE SIGNAL METER. Answers the one question the old "LIVE 48k · load 3%"
//  status text never could: *is the guitar actually getting in?* Two meters —
//  raw DI at the input node (pre-rig) and the processed sound at the main mixer
//  (post-rig) — each with peak, RMS, a held clip flag and a signal-present state,
//  so "plugged in but silent" looks nothing like "playing quietly".
//
//  THREADING (this is the whole design; see Audio/RealtimeSafety.md):
//
//    AUDIO THREAD          `AudioLevelBus.accumulate` runs inside an
//    (tap callback)        AVAudioNode tap. It does vDSP peak / sum-of-squares
//                          over the caller's buffer and a handful of RELAXED
//                          ATOMIC stores into preallocated storage. No malloc,
//                          no locks, no GCD, no Task, no @Published write. The
//                          bus is captured once when the tap is installed (one
//                          retain, on the main thread) and the callback only
//                          calls straight through it — no per-buffer ARC.
//
//    MAIN THREAD           `AudioLevelMonitor.tick` drains those atomics ~30×/s,
//                          applies fast-attack / slow-release ballistics and
//                          publishes. This is the ONLY place a level is published.
//
//  The two never share anything but the lock-free counters below — the same
//  single-writer / single-reader value bus the kernel's parameters ride on.
//
//  The meters live on their OWN ObservableObject rather than on
//  `AudioEngineController` on purpose: a 30 Hz publish on the controller would
//  re-render every view that observes it (the control panel, its route zones, the
//  AR slots, the camera preview). Only the meter views observe this object, so a
//  level update redraws a meter and nothing else.
//

import Foundation
import Accelerate
import Combine
import Synchronization

// MARK: - One meter's published state

/// A single meter read-out, already smoothed and in dBFS.
struct AudioLevel: Equatable {
    /// Smoothed peak (fast attack, slow release).
    var peakDB: Float = AudioLevel.floorDB
    /// Smoothed RMS — the "how loud does this feel" bar.
    var rmsDB: Float = AudioLevel.floorDB
    /// Peak-hold tick: the highest peak of the last ~1 s, like a hardware meter.
    var holdDB: Float = AudioLevel.floorDB
    /// A sample hit full scale recently (held ~1.5 s so a single spike is visible).
    var isClipping = false
    /// Something is actually coming down the wire (see `signalFloorDB`).
    var hasSignal = false

    /// Bottom of the drawn scale. Below this the meter is simply "nothing".
    static let floorDB: Float = -72

    /// Signal-present threshold.
    ///
    /// A guitar plugged into an iRig and left alone sits in its own noise floor —
    /// roughly -75…-85 dBFS for a passive humbucker at rest, a little hotter with
    /// single coils near a screen. The quietest note a player would call "playing"
    /// lands well above -50 dBFS. -60 dBFS sits in the empty band between the two:
    /// high enough that interface hiss doesn't light the lamp, low enough that a
    /// gently fretted note does. That gap is what makes "connected but silent"
    /// (dark lamp, dead bar) diagnosable at a glance from "playing quietly".
    static let signalFloorDB: Float = -60
}

// MARK: - The lock-free audio→UI level bus

/// Preallocated, lock-free accumulator shared by ONE audio thread (writer) and
/// the main thread (reader). Every field is a relaxed atomic — the same
/// wait-free value-bus discipline the kernel's parameters use.
///
/// Peak and loudness are accumulated (not overwritten) between drains, so a
/// transient that lands between two UI ticks is still reported.
///
/// WHY THE TWO HALVES USE DIFFERENT MECHANISMS. A meter must never let the
/// audio/UI interleaving corrupt the number it shows — an earlier draft used a
/// plain load-modify-store for both and produced RMS readings ~7 dB ABOVE the
/// peak (physically impossible): the audio thread could re-store a sum the main
/// thread had already drained, pairing old energy with a fresh frame count.
///  • PEAK is a max, so it uses a compare-exchange loop. If a drain resets the
///    slot mid-update the exchange fails, the loop re-reads and stores against
///    the new (zero) value — the reset can't be lost.
///  • LOUDNESS is an average, so nothing is ever reset: the audio thread only
///    ever ADDS (a true atomic add) to monotonic totals, and the main thread
///    takes the delta since its last read. Per-BUFFER mean square is what gets
///    accumulated, divided by a BUFFER count, so a buffer that lands between the
///    reader's two loads merely counts in the next window — it can't skew the
///    average either way. Both totals are unsigned, so wrap-around subtraction
///    stays exact.
final class AudioLevelBus: @unchecked Sendable {

    /// Running max |sample| since the last drain, as a Float bit pattern.
    private let peakBits = Atomic<UInt32>(0)
    /// MONOTONIC Σ(per-buffer mean square), fixed-point (see `meanSquareScale`).
    private let meanSquareTotal = Atomic<UInt64>(0)
    /// MONOTONIC count of buffers folded into `meanSquareTotal`.
    private let bufferTotal = Atomic<UInt64>(0)
    /// Sticky "a sample reached full scale" flag (0/1).
    private let clipFlag = Atomic<UInt32>(0)

    /// Fixed-point scale for the mean-square accumulator. 2^40 keeps ~-120 dBFS
    /// resolvable (far below the -72 dBFS meter floor) while a full-scale signal
    /// needs decades of playing to wrap — and wrapping is harmless anyway,
    /// because the reader subtracts unsigned totals.
    private static let meanSquareScale: Double = 1_099_511_627_776   // 2^40
    /// Hard ceiling for one buffer's scaled contribution, well inside UInt64.
    private static let meanSquareCeiling: Double = 9.0e18

    // MARK: Audio thread

    /// AUDIO THREAD ONLY. Fold one channel of one buffer into the accumulators.
    ///
    /// Cost is two vDSP passes over the buffer plus a handful of relaxed atomic
    /// operations — allocation-free, lock-free and bounded, per RealtimeSafety.md.
    /// `samples` is the tap's own storage; nothing is copied. The compare-exchange
    /// below is lock-free, not a lock: with a single audio writer it settles on
    /// the first or second attempt and never waits on the main thread.
    func accumulate(_ samples: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }

        var bufferPeak: Float = 0
        vDSP_maxmgv(samples, 1, &bufferPeak, vDSP_Length(frameCount))
        var bufferSumSquares: Float = 0
        vDSP_svesq(samples, 1, &bufferSumSquares, vDSP_Length(frameCount))

        // Peak: lock-free max.
        var known = peakBits.load(ordering: .relaxed)
        while bufferPeak > Float(bitPattern: known) {
            let (swapped, current) = peakBits.compareExchange(expected: known,
                                                              desired: bufferPeak.bitPattern,
                                                              ordering: .relaxed)
            if swapped { break }
            known = current
        }

        // Loudness: monotonic adds only. The value is clamped BEFORE the integer
        // conversion because `UInt64(Double)` traps on NaN and on overflow — and a
        // meter must never be the thing that kills the audio thread if the DSP
        // upstream produces a NaN or a runaway level. (`bufferPeak` needs no such
        // guard: every comparison against NaN is already false.)
        let meanSquare = Double(bufferSumSquares) / Double(frameCount) * Self.meanSquareScale
        let bounded = meanSquare.isFinite ? min(max(meanSquare, 0), Self.meanSquareCeiling) : 0
        meanSquareTotal.wrappingAdd(UInt64(bounded), ordering: .relaxed)
        bufferTotal.wrappingAdd(1, ordering: .relaxed)

        // Full scale reached. Float samples can legally exceed 1.0 inside the
        // graph, but anything at or past it will clip at the converter.
        if bufferPeak >= 1.0 { clipFlag.store(1, ordering: .relaxed) }
    }

    // MARK: Main thread

    /// One window's measurement. A window with no audio at all reads zero for
    /// both, which the ballistics floor identically — "nothing arrived" and
    /// "silence arrived" look the same on a meter, and should.
    struct Drain {
        var peak: Float = 0
        var rms: Float = 0
        var clipped = false
    }

    /// Where the reader's last delta ended. MAIN THREAD ONLY.
    private var lastMeanSquareTotal: UInt64 = 0
    private var lastBufferTotal: UInt64 = 0

    /// MAIN THREAD ONLY. Take everything accumulated since the last call.
    ///
    /// READ ORDER MIRRORS THE WRITE ORDER, and that is load-bearing. The audio
    /// thread stores the peak BEFORE the loudness, so the reader takes the
    /// loudness BEFORE the peak: any buffer whose energy is in this window's
    /// average had its peak stored earlier still, and is therefore in the peak
    /// slot by the time we take it. Reading the peak first would let a buffer
    /// contribute loudness to a window whose peak it missed — a reading with RMS
    /// above peak, which no meter should ever be able to show.
    func drain() -> Drain {
        let meanSquareNow = meanSquareTotal.load(ordering: .relaxed)
        let buffersNow = bufferTotal.load(ordering: .relaxed)
        let peak = Float(bitPattern: peakBits.exchange(0, ordering: .relaxed))
        let clipped = clipFlag.exchange(0, ordering: .relaxed) != 0

        let meanSquareDelta = meanSquareNow &- lastMeanSquareTotal
        let buffersDelta = buffersNow &- lastBufferTotal
        lastMeanSquareTotal = meanSquareNow
        lastBufferTotal = buffersNow

        guard buffersDelta > 0 else { return Drain(peak: peak, rms: 0, clipped: clipped) }
        let meanSquare = Double(meanSquareDelta) / Double(buffersDelta) / Self.meanSquareScale
        return Drain(peak: peak, rms: Float(meanSquare.squareRoot()), clipped: clipped)
    }

    /// Drop everything (engine stopped / re-engaged).
    func clear() {
        peakBits.store(0, ordering: .relaxed)
        clipFlag.store(0, ordering: .relaxed)
        // Re-baseline rather than zeroing the monotonic totals, so an in-flight
        // audio buffer can never make the next delta negative.
        lastMeanSquareTotal = meanSquareTotal.load(ordering: .relaxed)
        lastBufferTotal = bufferTotal.load(ordering: .relaxed)
    }

    // MARK: dBFS

    /// THE dBFS conversion, defined once. A linear magnitude of 1.0 reads 0 dBFS,
    /// 0.5 reads -6.02 dBFS, 0 is floored at 1e-9 (-180 dBFS) so logs stay finite.
    /// `AudioEngineController.dbfs` (the offline render report) formats THIS
    /// function, so the meter and the harness can never drift apart.
    static func dbfs(_ magnitude: Float) -> Float {
        20 * log10(max(magnitude, 1e-9))
    }
}

// MARK: - Ballistics + publishing

/// Owns both level buses and publishes smoothed meter state at ~30 Hz.
@MainActor
final class AudioLevelMonitor: ObservableObject {

    /// Raw DI arriving from the iRig, tapped PRE-rig on the engine's input node.
    @Published private(set) var input = AudioLevel()
    /// The processed rig output, tapped POST-rig on the main mixer.
    @Published private(set) var output = AudioLevel()

    /// Written by the audio thread's taps.
    let inputBus = AudioLevelBus()
    let outputBus = AudioLevelBus()

    private var inputBallistics = Ballistics()
    private var outputBallistics = Ballistics()

    /// Publish rate. 0.25 s (the render-load timer) is far too slow to feel
    /// connected to your right hand; ~30 Hz tracks a pick attack.
    /// `nonisolated` so it can be read as a default argument below.
    nonisolated static let tickInterval: TimeInterval = 1.0 / 30.0

    /// Drain both buses and publish. Called from the controller's meter timer.
    func tick(dt: TimeInterval = AudioLevelMonitor.tickInterval) {
        let newInput = inputBallistics.advance(inputBus.drain(), dt: dt)
        if newInput != input { input = newInput }
        let newOutput = outputBallistics.advance(outputBus.drain(), dt: dt)
        if newOutput != output { output = newOutput }
    }

    /// Zero everything — used when monitoring stops so the meters don't freeze
    /// mid-swing showing a level that is no longer being measured.
    func reset() {
        inputBus.clear(); outputBus.clear()
        inputBallistics = Ballistics(); outputBallistics = Ballistics()
        input = AudioLevel(); output = AudioLevel()
    }

    /// Hardware-style meter movement: jump to a new peak instantly, fall back
    /// slowly, and park the highest recent peak on a hold tick.
    private struct Ballistics {
        var peakDB = AudioLevel.floorDB
        var rmsDB = AudioLevel.floorDB
        var holdDB = AudioLevel.floorDB
        var holdRemaining: TimeInterval = 0
        var clipRemaining: TimeInterval = 0

        /// Release time constant: ~0.55 s to fall most of the way, which reads as
        /// a needle settling rather than a strobe. Shared by BOTH measurements —
        /// see the invariant note in `rmsAttackTau`.
        static let releaseTau: TimeInterval = 0.55
        /// Attack time constant for the RMS BODY only.
        ///
        /// The peak tick keeps an instant attack — catching the transient is its
        /// entire job. The loudness bar must not: measured over a 33 ms window a
        /// real signal wobbles several dB tick to tick, and an instant attack
        /// snapped the bar to every one of those wobbles before releasing, which
        /// reads as a strobe rather than a level. ~0.18 s integrates roughly five
        /// ticks — slow enough that the bar swells instead of flickering, fast
        /// enough that it still arrives with the pick attack. (0.18 s was a first
        /// pass and still read as too quick and choppy against a real signal; the
        /// other half of that fix is the meter's fractional leading segment, which
        /// stops a 3 dB segment boundary popping on and off.)
        ///
        /// ASYMMETRY IS DELIBERATE AND ONLY SAFE IN THIS DIRECTION. `rmsDB <=
        /// peakDB` holds because the two share ONE release rule and the RMS only
        /// ever rises SLOWER than the peak: when both release they contract at the
        /// same rate from an already-ordered pair, and a window where the RMS
        /// climbs while the peak falls ends with the RMS no higher than the
        /// measured peak it is chasing. Giving the RMS a slower RELEASE would
        /// break exactly that and let the bars cross again — see the note above.
        static let rmsAttackTau: TimeInterval = 0.35
        /// How long the peak tick sits at a new maximum before it starts falling.
        static let holdSeconds: TimeInterval = 1.0
        /// A clip must stay visible long enough to be noticed, not just flicker.
        static let clipHoldSeconds: TimeInterval = 1.5

        mutating func advance(_ drain: AudioLevelBus.Drain, dt: TimeInterval) -> AudioLevel {
            let coefficient = Float(1 - exp(-dt / Self.releaseTau))
            let rmsAttack = Float(1 - exp(-dt / Self.rmsAttackTau))
            // BOTH measurements are clamped to the meter's floor BEFORE smoothing.
            // Letting them release toward different targets is what made the two
            // bars cross: a silent window sent the peak diving toward -180 dBFS
            // while the RMS glided down to the -72 floor, and the published meter
            // then showed RMS ABOVE peak — physically impossible, and exactly what
            // a quiet room between notes produces. Clamping first keeps
            // `measuredRMS <= measuredPeak` true at every step, which — combined
            // with a SHARED release and an RMS attack no faster than the peak's —
            // makes `rmsDB <= peakDB` an invariant (see `rmsAttackTau`).
            let floor = AudioLevel.floorDB
            let measuredPeak = max(AudioLevelBus.dbfs(drain.peak), floor)
            let measuredRMS = max(AudioLevelBus.dbfs(drain.rms), floor)

            peakDB = measuredPeak > peakDB ? measuredPeak : peakDB + (measuredPeak - peakDB) * coefficient
            rmsDB += (measuredRMS - rmsDB) * (measuredRMS > rmsDB ? rmsAttack : coefficient)

            if peakDB >= holdDB {
                holdDB = peakDB
                holdRemaining = Self.holdSeconds
            } else if holdRemaining > 0 {
                holdRemaining -= dt
            } else {
                holdDB += (peakDB - holdDB) * coefficient
            }

            if drain.clipped { clipRemaining = Self.clipHoldSeconds }
            else if clipRemaining > 0 { clipRemaining -= dt }

            // Everything is already at or above the floor (the measurements were
            // clamped before smoothing); `holdDB` is clamped for belt and braces.
            return AudioLevel(peakDB: peakDB,
                              rmsDB: rmsDB,
                              holdDB: max(holdDB, floor),
                              isClipping: clipRemaining > 0,
                              // Judge presence on the RELEASED peak, not the raw
                              // 33 ms measurement: a guitar is mostly decay and
                              // gaps between picks, and a lamp that strobed off
                              // between notes would be worse than no lamp. It
                              // still goes dark about half a second after you
                              // genuinely stop.
                              hasSignal: peakDB > AudioLevel.signalFloorDB)
        }
    }
}
