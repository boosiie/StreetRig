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
    /// The cap's machined grip: four hairlines, drawn rather than tiled because at
    /// this size a tiled pattern would alias into a grey wash.
    private var knurl: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<4, id: \.self) { _ in
                Rectangle().fill(Color.black.opacity(0.16)).frame(width: 1)
            }
        }
    }

    /// How far the finger landed from the thumb's centre (0 for a track jump).
    @State private var grabOffset: CGFloat = 0
    /// Bumped only when a touch actually sets a value, to trigger the haptic.
    @State private var jumps = 0

    /// Which way this touch turned out to be going, or nil while it is still too
    /// small to tell. See the axis note on the gesture.
    @State private var axis: Axis?

    /// How far a finger must travel before this slider decides what the touch IS.
    /// 6pt: under a normal scroll's first frame of travel, over the jitter of a
    /// stationary thumb.
    private static let axisLock: CGFloat = 6

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
                // A KNURLED FADER CAP, not a bead. A circle carries no orientation,
                // so it cannot show where in its travel the value sits — every
                // slider in the app looked identical at every setting, and there was
                // no long axis whose bevel a pressed state could invert. The cap has
                // a machined grip, a bevel lit from the same 0° overhead as every
                // other control, and an amber index line down the middle that IS the
                // readout.
                //
                // The CONTAINER stays `knob` wide. Everything downstream — `knobX`,
                // `thumbCentre`, the grab offset — is arithmetic on that width, so
                // the cap is drawn inside a frame of the old size rather than
                // replacing it. Change the frame and the drag maths goes with it.
                ZStack {
                    RoundedRectangle(cornerRadius: RigTheme.Radius.tight, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.98), Color(white: 0.91),
                                                      Color(white: 0.75), Color(white: 0.60)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay { knurl }
                        .overlay {
                            RoundedRectangle(cornerRadius: RigTheme.Radius.tight, style: .continuous)
                                .strokeBorder(Color.black.opacity(0.30), lineWidth: 1)
                        }
                        .overlay {
                            Capsule().fill(RigTheme.amber)
                                .frame(width: 1.5, height: knob * 0.56)
                        }
                        .frame(width: knob * 0.66, height: knob * 1.18)
                }
                .frame(width: knob, height: knob)
                .offset(x: knobX)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // Plain `.gesture`, NOT `.simultaneousGesture`: these sliders sit inside
            // ScrollViews (the detail dock, the control board, the plugin editor).
            // Running simultaneously would let a scroll drag rewrite whatever track
            // it happened to start on. This way the touch belongs to exactly one of
            // them — scroll from the labels, set the value from the track.
            // NOTHING IS WRITTEN UNTIL THE TOUCH SAYS WHAT IT IS.
            //
            // The track used to set the value on touch-DOWN, which made these sliders
            // impossible to scroll past: putting a finger on a track to swipe the dock
            // up had already jumped that parameter before the scroll was recognised,
            // and the player got a changed setting for a gesture they meant as
            // navigation. On a dock of a dozen dials that is not an edge case, it is
            // every scroll.
            //
            // So the first `axisLock` points decide, and only then does anything
            // happen: a mostly-VERTICAL travel is a scroll and this slider stays out
            // of it entirely, leaving the ScrollView to claim the drag (it cancels us
            // without `onEnded`, which is exactly why `touchStart` identifies a touch
            // by its start location rather than a flag). A mostly-HORIZONTAL travel is
            // a value change. And a touch that never passes the threshold at all is a
            // TAP, honoured on release.
            //
            // Tap-to-set therefore fires on touch-up rather than touch-down. That is
            // the cost, and it is the same trade every tappable row in a scroll view
            // makes — a control that acts before it knows whether you were scrolling
            // is a control that acts against you.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if touchStart != gesture.startLocation {
                            touchStart = gesture.startLocation
                            axis = nil
                            grabOffset = 0
                        }
                        if axis == nil {
                            let dx = abs(gesture.translation.width)
                            let dy = abs(gesture.translation.height)
                            guard max(dx, dy) >= Self.axisLock else { return }
                            guard dx > dy else { axis = .vertical; return }
                            axis = .horizontal
                            // Grabbed the thumb: hold the finger's offset so the value
                            // stays put until the finger actually moves.
                            let thumbCentre = knobX + knob / 2
                            grabOffset = abs(gesture.startLocation.x - thumbCentre) <= knob / 2
                                ? gesture.startLocation.x - thumbCentre
                                : 0
                        }
                        guard axis == .horizontal else { return }
                        // Unanimated from here so the thumb never trails the finger.
                        value = valueAt(gesture.location.x - grabOffset, usable: usable, span: span)
                    }
                    .onEnded { gesture in
                        if axis == nil {
                            jumps += 1
                            withAnimation(.easeOut(duration: 0.12)) {
                                value = valueAt(gesture.location.x, usable: usable, span: span)
                            }
                        }
                        touchStart = nil
                        axis = nil
                    }
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
