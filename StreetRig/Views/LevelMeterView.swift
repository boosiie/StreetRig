//
//  LevelMeterView.swift
//  StreetRig
//
//  The live signal read-out, in two pieces the control panel places itself: a
//  LAMP (dark → green when signal arrives → red on clip) and a segment BAR.
//
//  Segments rather than a continuous bar because a lit-segment count is
//  something you can read at a glance from a few feet away — which is the
//  distance you are standing at with a guitar on.
//
//  DELIBERATELY JUST THE BAR. This meter used to carry its own title, port name,
//  dBFS read-out, CLIP badge and printed dB scale — a five-part instrument, sized
//  for the full-screen signal check it lived on. In the panel the route zone
//  already names the port in type twice that size, and the lamp says the two
//  things a player acts on: signal, and too much of it. The exact dBFS is not
//  something you fix from the bottom of the rig screen.
//
//  RE-RENDER ISOLATION: these two views are the ONLY observers of
//  `AudioLevelMonitor`. Levels publish ~30×/s; because the lamp and the bar (not
//  their parent) hold the @ObservedObject, a level update redraws them and
//  nothing else — the panel around them never re-renders.
//

import SwiftUI
import StreetRigEngine

/// The segment bar. 3 dB per segment across a 72 dB scale.
struct LevelMeterView: View {

    /// Which of the monitor's two meters to draw.
    enum Channel { case input, output }

    @ObservedObject var monitor: AudioLevelMonitor
    let channel: Channel
    /// Greys the meter out when the engine isn't running.
    var isLive: Bool = true

    private var level: AudioLevel {
        channel == .input ? monitor.input : monitor.output
    }

    var body: some View {
        bar(level)
            .frame(height: 11)
            .opacity(isLive ? 1 : 0.4)
    }

    // MARK: - The bar

    /// Segment count. 24 across the 72 dB scale is exactly 3 dB per segment, so
    /// counting lit segments is a real measurement rather than a vibe.
    private static let segmentCount = 24
    private static let segmentGap: CGFloat = 2

    private func bar(_ level: AudioLevel) -> some View {
        // FRACTIONAL LEADING SEGMENT. Lighting segments on a hard threshold makes
        // the meter chop: a level sitting near a boundary pops that segment on and
        // off, and since each segment is 3 dB, ordinary wobble is enough to do it
        // several times a second. The leading segment instead fades in proportion
        // to how far into it the level has come, so the meter travels smoothly and
        // the segments stay a readable scale rather than a set of switches.
        let litExact = Self.litSegmentsExact(level.rmsDB)
        let litThrough = Int(litExact)
        let partial = Double(litExact - Float(litThrough))
        let holdIndex = min(Self.segmentCount - 1, Int(Self.litSegmentsExact(level.holdDB)))
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
                .mask {
                    segmentRow { index in
                        if index < litThrough { return Color.white }
                        if index == litThrough { return Color.white.opacity(partial) }
                        return .clear
                    }
                }

            // Peak hold parks as a single detached lit segment, the way a hardware
            // meter leaves its needle sitting at the loudest thing you just played.
            if showHold {
                LinearGradient(gradient: Self.barGradient, startPoint: .leading, endPoint: .trailing)
                    .mask { segmentRow { $0 == holdIndex ? Color.white : .clear } }
            }
        }
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

    /// How many segments a level lights, WITH its fractional part: 0 at the floor,
    /// `segmentCount` at full scale. The whole part is how many segments are fully
    /// lit; the remainder is how far into the next one the level has reached, which
    /// is what the leading segment fades by.
    static func litSegmentsExact(_ db: Float) -> Float {
        min(Float(segmentCount), max(0, fraction(db) * Float(segmentCount)))
    }

    // MARK: - Scale mapping

    /// dBFS → 0…1 across the drawn scale, linear in dB.
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

// MARK: - Lamp

/// The "is anything arriving, and is it too hot" light, sat next to the route's
/// name. Its own view so a 30 Hz level tick redraws an 8pt circle, not the panel.
struct SignalLamp: View {
    @ObservedObject var monitor: AudioLevelMonitor
    let channel: LevelMeterView.Channel
    var isLive: Bool = true

    private var level: AudioLevel {
        channel == .input ? monitor.input : monitor.output
    }

    var body: some View {
        let level = self.level
        Circle()
            .fill(color(level))
            .frame(width: 8, height: 8)
            .shadow(color: isLive && level.hasSignal ? color(level) : .clear, radius: 4)
            .animation(.easeOut(duration: 0.12), value: level.isClipping)
    }

    private func color(_ level: AudioLevel) -> Color {
        if !isLive { return RigTheme.textMuted.opacity(0.3) }
        if level.isClipping { return RigTheme.clip }
        return level.hasSignal ? RigTheme.signal : RigTheme.textMuted.opacity(0.3)
    }
}

#Preview {
    struct Demo: View {
        @StateObject private var monitor = AudioLevelMonitor()
        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 7) {
                    SignalLamp(monitor: monitor, channel: .input)
                    Text("INPUT").font(.system(size: 12, weight: .bold)).tracking(1.5)
                        .foregroundStyle(RigTheme.textMuted)
                }
                LevelMeterView(monitor: monitor, channel: .input)
                LevelMeterView(monitor: monitor, channel: .output)
                LevelMeterView(monitor: monitor, channel: .input, isLive: false)
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
