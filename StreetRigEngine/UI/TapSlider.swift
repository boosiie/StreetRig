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
//  Three refinements keep that from feeling like a bare hit target:
//  • A touch that lands ON the thumb drags RELATIVE to the current value. Snapping
//    the thumb's centre to a finger that grabbed it a few points off would jog the
//    value before the player had moved at all — wrong on a control being trimmed
//    by a hair. A touch anywhere else on the track still jumps.
//  • The jump is animated (~0.12s); the drag that follows is not. A teleport reads
//    as a glitch, but animating the drag puts the thumb behind the finger, which is
//    worse than no animation.
//  • The jump fires a haptic via SwiftUI's `.sensoryFeedback`, deliberately NOT a
//    UIKit generator: this file also ships inside the AUv3 extension, where a
//    UIKit haptic engine is unavailable and `.sensoryFeedback` simply no-ops.
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

    /// Where the live touch started, or nil between gestures. Identity is the start
    /// location rather than a plain "is dragging" flag because a ScrollView that
    /// claims the drag cancels us WITHOUT calling `onEnded` — a stale flag would
    /// then swallow the jump on the next touch.
    @State private var touchStart: CGPoint?
    /// How far the finger landed from the thumb's centre (0 for a track jump).
    @State private var grabOffset: CGFloat = 0
    /// Bumped only by a touch-down that sets a value, to trigger the haptic.
    @State private var jumps = 0

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
                // The unfilled track is a GROOVE, not a raised surface, so it takes
                // `hairline` rather than a rung of the elevation ladder — the same
                // warm tone LevelMeterView draws its unlit segments in, so every
                // "range you haven't used yet" in the app reads as one material.
                // (It was `Color.white.opacity(0.14)`, which greyed out over the
                // espresso card behind it.)
                Capsule().fill(RigTheme.hairline).frame(height: track)
                Capsule().fill(tint).frame(width: knobX + knob / 2, height: track)
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(x: knobX)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // Plain `.gesture`, NOT `.simultaneousGesture`: these sliders sit inside
            // ScrollViews (the detail dock, the control board, the plugin editor).
            // Running simultaneously would let a scroll drag rewrite whatever track
            // it happened to start on. This way the touch belongs to exactly one of
            // them — scroll from the labels, set the value from the track.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if touchStart != gesture.startLocation {
                            touchStart = gesture.startLocation
                            let thumbCentre = knobX + knob / 2
                            if abs(gesture.startLocation.x - thumbCentre) <= knob / 2 {
                                // Grabbed the thumb: hold the finger's offset so the
                                // value stays put until the finger actually moves.
                                grabOffset = gesture.startLocation.x - thumbCentre
                            } else {
                                grabOffset = 0
                                jumps += 1
                                withAnimation(.easeOut(duration: 0.12)) {
                                    value = valueAt(gesture.location.x, usable: usable, span: span)
                                }
                                return
                            }
                        }
                        // Unanimated from here so the thumb never trails the finger.
                        value = valueAt(gesture.location.x - grabOffset, usable: usable, span: span)
                    }
                    .onEnded { _ in touchStart = nil }
            )
        }
        .frame(height: knob)
        // SwiftUI-native haptic: no UIKit generator to link, and it degrades to a
        // no-op wherever there's no haptic context (i.e. the AUv3 in a host).
        .sensoryFeedback(.selection, trigger: jumps)
    }

    /// Maps a touch's x to a value, treating that x as where the thumb's centre lands.
    private func valueAt(_ x: CGFloat, usable: CGFloat, span: Double) -> Double {
        let clamped = min(max(0, x - knob / 2), usable)
        return range.lowerBound + Double(clamped / usable) * span
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
