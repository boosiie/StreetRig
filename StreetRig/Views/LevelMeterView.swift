//
//  LevelMeterView.swift
//  StreetRig
//
//  A horizontal signal meter, drawn the way a hardware one reads: a solid RMS
//  bar for "how loud this feels", a peak-hold tick riding on top, a dB scale you
//  can actually aim at, a signal-present lamp and a clip LED that stays lit long
//  enough to be seen.
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

    private func bar(_ level: AudioLevel) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let rmsWidth = width * CGFloat(Self.fraction(level.rmsDB))
            let holdX = width * CGFloat(Self.fraction(level.holdDB))

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)

                // RMS body — green up to -12 dBFS, amber through the last 6 dB of
                // headroom, red at full scale. The gradient is laid out across the
                // WHOLE meter and then masked to the current level, so a colour
                // always means the same dB no matter how far the bar has moved.
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(LinearGradient(gradient: Self.barGradient,
                                         startPoint: .leading, endPoint: .trailing))
                    .mask(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .frame(width: max(0, rmsWidth))
                    }

                // Peak-hold tick.
                if level.holdDB > AudioLevel.floorDB + 0.5 {
                    Rectangle()
                        .fill(level.isClipping ? RigTheme.clip : RigTheme.panel)
                        .frame(width: 2)
                        .offset(x: min(max(0, holdX - 1), width - 2))
                }
            }
        }
        .frame(height: 14)
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

    /// Colour by ABSOLUTE dB position: healthy up to -12, into the headroom band
    /// at -6, hot at 0.
    private static let barGradient = Gradient(stops: [
        .init(color: RigTheme.signal, location: 0),
        .init(color: RigTheme.signal, location: Double(fraction(-12))),
        .init(color: RigTheme.amber,  location: Double(fraction(-6))),
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
