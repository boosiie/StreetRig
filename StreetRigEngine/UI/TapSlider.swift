//
//  TapSlider.swift
//  StreetRigEngine
//
//  A slider you set by tapping anywhere on the track — the knob jumps straight
//  to the touch, no dragging required. Uses DragGesture(minimumDistance: 0),
//  which fires even on a stationary tap, so the touch's x maps directly to a
//  value; continued dragging then tracks 1:1. (SwiftUI's built-in Slider only
//  moves when you grab the thumb.)
//
//  RELOCATED to the shared framework (Phase 4): this is the ONE knob primitive
//  the standalone app AND the AUv3 plugin editor both bind to `store.binding(...)`.
//

import SwiftUI

public struct TapSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var tint: Color = RigTheme.amber

    private let knob: CGFloat = 22
    private let track: CGFloat = 6

    public init(value: Binding<Double>, in range: ClosedRange<Double>, tint: Color = RigTheme.amber) {
        self._value = value
        self.range = range
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let usable = max(1, width - knob)
            let span = range.upperBound - range.lowerBound
            let frac = span > 0 ? (value - range.lowerBound) / span : 0
            let knobX = CGFloat(frac) * usable // left edge of the knob

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14)).frame(height: track)
                Capsule().fill(tint).frame(width: knobX + knob / 2, height: track)
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(x: knobX)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let x = min(max(0, gesture.location.x - knob / 2), usable)
                        value = range.lowerBound + Double(x / usable) * span
                    }
            )
        }
        .frame(height: knob)
    }
}

#Preview {
    struct Demo: View {
        @State private var v = 5.0
        var body: some View {
            VStack(spacing: 20) {
                TapSlider(value: $v, in: 0...10)
                Text(String(format: "%.1f", v)).foregroundStyle(RigTheme.textPrimary)
            }
            .padding(40)
            .background(RigTheme.background)
        }
    }
    return Demo().preferredColorScheme(.dark)
}
