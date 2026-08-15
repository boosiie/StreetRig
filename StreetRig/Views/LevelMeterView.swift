//
//  LevelMeterView.swift
//  StreetRig
//
//  A horizontal signal meter, drawn the way a hardware one reads: a row of
//  SEGMENTS that light up with the RMS ("how loud this feels"), a peak-hold
//  segment parked above them, a dB scale you can actually aim at, a
//  signal-present lamp and a clip LED that stays lit long enough to be seen.
//
//  Segments rather than a continuous bar because a lit-segment count is
//  something you can read at a glance from a few feet away — which is the
//  distance you are standing at with a guitar on.
//
//  RE-RENDER ISOLATION: this view is the ONLY observer of `AudioLevelMonitor`.
//  Levels publish ~30×/s; because the meter (not its parent) holds the
//  @ObservedObject, a level update redraws the bar and nothing else — the AR
//  slots and the camera preview beside it never re-render.
//

import SwiftUI
import StreetRigEngine

struct LevelMeterView: View {

    /// Which of the monitor's two meters to draw.
    enum Channel { case input, output }

    @ObservedObject var monitor: AudioLevelMonitor
    let channel: Channel
    let title: String
    /// Shown under the title — e.g. the port the DI is arriving from.
    var subtitle: String?
    /// Greys the whole meter out when the engine isn't running.
    var isLive: Bool = true

    /// dB marks drawn under the bar. -60 is the signal-present floor; 0 is clip.
    private static let ticks: [Float] = [-60, -40, -20, -12, -6, 0]

    private var level: AudioLevel {
        channel == .input ? monitor.input : monitor.output
    }

    var body: some View {
        let current = level
        VStack(alignment: .leading, spacing: 4) {
            header(current)
            bar(current)
            scale
        }
        .opacity(isLive ? 1 : 0.45)
        .animation(.easeOut(duration: 0.12), value: current.isClipping)
    }

    // MARK: - Header (name, lamps, numbers)

    private func header(_ level: AudioLevel) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(lampColor(level))
                .frame(width: 7, height: 7)
                .shadow(color: level.hasSignal ? RigTheme.signal : .clear, radius: 3)
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(1)
                .foregroundStyle(RigTheme.textMuted)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(RigTheme.textMuted.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text(readout(level))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(level.hasSignal ? RigTheme.textPrimary : RigTheme.textMuted)
            Text("CLIP")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(level.isClipping ? RigTheme.clip : RigTheme.textMuted.opacity(0.35))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(level.isClipping ? RigTheme.clip.opacity(0.22) : .clear)
                )
        }
    }

    private func lampColor(_ level: AudioLevel) -> Color {
        if !isLive { return RigTheme.textMuted.opacity(0.3) }
        if level.isClipping { return RigTheme.clip }
        return level.hasSignal ? RigTheme.signal : RigTheme.textMuted.opacity(0.3)
    }

    private func readout(_ level: AudioLevel) -> String {
        guard isLive else { return "—" }
        guard level.hasSignal || level.peakDB > AudioLevel.floorDB + 0.5 else { return "no signal" }
        return String(format: "%.1f dBFS", level.peakDB)
    }

    // MARK: - The bar

    /// Segment count. 24 across the 72 dB scale is exactly 3 dB per segment, so
    /// counting lit segments is a real measurement rather than a vibe.
    private static let segmentCount = 24
    private static let segmentGap: CGFloat = 2

    private func bar(_ level: AudioLevel) -> some View {
        let litThrough = Self.litSegments(level.rmsDB)
        let holdIndex = min(Self.segmentCount - 1, Self.litSegments(level.holdDB))
        let showHold = level.holdDB > AudioLevel.floorDB + 0.5

        return ZStack(alignment: .leading) {
            // Unlit track. Every segment is always drawn, so the meter keeps its
            // shape at silence and the headroom you have left is visible as the
            // dark run ahead of the signal.
            segmentRow { _ in RigTheme.hairline.opacity(0.75) }

            // Lit body. The gradient is laid across the WHOLE meter and masked to
            // the lit segments, so a segment's colour always means the same dB no
            // matter how far the meter has moved.
            LinearGradient(gradient: Self.barGradient, startPoint: .leading, endPoint: .trailing)
                .mask { segmentRow { $0 < litThrough ? Color.white : .clear } }

            // Peak hold parks as a single detached lit segment, the way a hardware
            // meter leaves its needle sitting at the loudest thing you just played.
            if showHold {
                LinearGradient(gradient: Self.barGradient, startPoint: .leading, endPoint: .trailing)
                    .mask { segmentRow { $0 == holdIndex ? Color.white : .clear } }
            }
        }
        .frame(height: 16)
    }

    /// One row of evenly-spaced segments, coloured by index. Drawn three times —
    /// the unlit track, the lit body's mask and the peak-hold mask — so all three
    /// share one layout and line up exactly.
    private func segmentRow(_ color: @escaping (Int) -> Color) -> some View {
        HStack(spacing: Self.segmentGap) {
            ForEach(0..<Self.segmentCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(color(index))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// How many segments a level lights: 0 at the floor, `segmentCount` at full
    /// scale. Rounding DOWN means a segment only lights once the signal has
    /// actually reached it.
    static func litSegments(_ db: Float) -> Int {
        min(segmentCount, max(0, Int(fraction(db) * Float(segmentCount))))
    }

    // MARK: - Scale

    private var scale: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                ForEach(Self.ticks, id: \.self) { db in
                    let x = width * CGFloat(Self.fraction(db))
                    Text(db == 0 ? "0" : "\(Int(db))")
                        .font(.system(size: 8, weight: .medium).monospacedDigit())
                        .foregroundStyle(RigTheme.textMuted.opacity(0.7))
                        .fixedSize()
                        // Nudge the end labels inboard so they don't clip.
                        .offset(x: min(max(0, x - 6), width - 12))
                }
            }
        }
        .frame(height: 10)
    }

    // MARK: - Scale mapping

    /// dBFS → 0…1 across the drawn scale, linear in dB so the printed ticks land
    /// where they say they do.
    static func fraction(_ db: Float) -> Float {
        let floor = AudioLevel.floorDB
        return min(1, max(0, (db - floor) / -floor))
    }

    /// Colour by ABSOLUTE dB position, and the warm end starts EARLY on purpose:
    /// green holds only to -24 dBFS, blends through amber by -10 and is fully red
    /// by -3. The first version packed every warm colour into the top 17% of the
    /// scale, so a signal stayed green until it was almost clipping — the meter
    /// only went orange once it was already too late to do anything about it.
    /// Warming from -24 gives you most of the meter's length as warning.
    private static let barGradient = Gradient(stops: [
        .init(color: RigTheme.signal, location: 0),
        .init(color: RigTheme.signal, location: Double(fraction(-24))),
        .init(color: RigTheme.amber,  location: Double(fraction(-10))),
        .init(color: RigTheme.clip,   location: Double(fraction(-3))),
        .init(color: RigTheme.clip,   location: 1),
    ])
}

#Preview {
    struct Demo: View {
        @StateObject private var monitor = AudioLevelMonitor()
        var body: some View {
            VStack(spacing: 14) {
                LevelMeterView(monitor: monitor, channel: .input,
                               title: "INPUT", subtitle: "iRig HD 2")
                LevelMeterView(monitor: monitor, channel: .output,
                               title: "OUTPUT", subtitle: "Speaker")
                LevelMeterView(monitor: monitor, channel: .input,
                               title: "INPUT (IDLE)", isLive: false)
            }
            .padding(24)
            .background(RigTheme.background)
            .task {
                // Drive the real ballistics with a synthetic swell so the preview
                // shows movement, clip and peak-hold rather than a dead bar.
                var t = 0.0
                while !Task.isCancelled {
                    t += AudioLevelMonitor.tickInterval
                    let amplitude = Float(abs(sin(t * 1.1))) * 1.15
                    var block = [Float](repeating: 0, count: 256)
                    for i in 0..<block.count {
                        block[i] = amplitude * Float(sin(Double(i) * 0.19))
                    }
                    block.withUnsafeBufferPointer { buffer in
                        guard let base = buffer.baseAddress else { return }
                        monitor.inputBus.accumulate(base, frameCount: buffer.count)
                        monitor.outputBus.accumulate(base, frameCount: buffer.count)
                    }
                    monitor.tick()
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
        }
    }
    return Demo().preferredColorScheme(.dark)
}
