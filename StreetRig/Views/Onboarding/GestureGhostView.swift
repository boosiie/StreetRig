//
//  GestureGhostView.swift
//  StreetRig
//
//  THE HAND. A translucent fingertip that performs the gesture a coach mark is
//  teaching — travelling the rail-to-stage drag, sweeping the header swipe,
//  pressing the amp.
//
//  WHY IT EXISTS AT ALL, given the caption already says "press and hold, then
//  drag". Because a ring round an element with a sentence beside it is a legend,
//  not a tutorial: it tells you WHAT the thing is and leaves you to infer what
//  to DO to it. The one thing genuinely hard to discover in this app is that a
//  rail card needs a HOLD before it will move — a tap does nothing, on purpose,
//  because the rail scrolls — and there is no wording that teaches a hold as
//  fast as watching a finger sit still on a card until it lifts.
//
//  BUILT ON `KeyframeAnimator`, not a `.repeatForever` animation on a Bool. A
//  drag demonstration is not one curve: it is reach, press, hold, travel, drop,
//  pause, and start again — and the PAUSE at the end is what makes it read as a
//  repeated demonstration rather than a thing sliding back and forth forever.
//  Keyframe tracks give each of those its own timing on one shared clock;
//  `.repeatForever(autoreverses:)` can express exactly two of them.
//
//  REDUCE MOTION TAKES A DIFFERENT DRAWING, NOT A SLOWER ONE. Nothing travels:
//  the drag becomes a dashed route with a fingertip at each end and an arrowhead
//  saying which way, the swipe becomes an arrow, the tap becomes a static ring.
//  The information survives; the movement doesn't. Fading a moving thing in and
//  out more gently is still a moving thing.
//

import SwiftUI
import StreetRigEngine

/// The animated state of the fingertip, as one value with four independently
/// keyframed tracks.
private struct GhostFrame {
    /// 0 → 1 along the taught path (drag and swipe).
    var travel: CGFloat = 0
    /// Fingertip size multiplier — the dip on a press, the squash on a tap.
    var scale: CGFloat = 1
    /// Whole-ghost alpha, so it can arrive and leave rather than blink.
    var opacity: CGFloat = 0
    /// 0 → 1 fill of the hold ring, which is what "keep holding" looks like.
    var hold: CGFloat = 0
}

struct GestureGhostView: View {
    let gesture: TourGesture
    /// Where the gesture starts, in the overlay's coordinate space.
    let from: CGPoint
    /// Where it ends. `nil` for gestures that stay put.
    var to: CGPoint?
    let reduceMotion: Bool

    /// Fingertip diameter. Sized off a real fingertip contact patch rather than
    /// off the icon it sits on — a 20pt dot over a 58pt trash circle reads as a
    /// bullet point, not a finger.
    private let tipDiameter: CGFloat = 34

    /// How far a swipe demonstration travels either side of centre. Long enough
    /// to read as a sweep, short enough to stay over the element it belongs to.
    private let swipeReach: CGFloat = 62

    var body: some View {
        Group {
            switch gesture {
            case .none:
                EmptyView()
            case .tap:
                if reduceMotion { staticTap } else { animatedTap }
            case .press:
                if reduceMotion { staticTap } else { animatedPress }
            case .swipeLeft:
                if reduceMotion { staticSwipe } else { animatedSwipe }
            case .dragTo:
                if reduceMotion { staticDrag } else { animatedDrag }
            }
        }
        .allowsHitTesting(false)
        // The caption says the same thing in words, and a fingertip announced as
        // "image" between two paragraphs is noise in a screen reader.
        .accessibilityHidden(true)
    }

    // MARK: - Animated

    private var animatedTap: some View {
        KeyframeAnimator(initialValue: GhostFrame(), repeating: true) { frame in
            ZStack {
                // The ring is the tap's "contact ripple" — it expands past the
                // fingertip and fades, which is the visual grammar every phone
                // OS already uses for a press landing.
                Circle()
                    .strokeBorder(RigTheme.amber.opacity(0.9 * (1 - frame.hold)), lineWidth: 2)
                    .frame(width: tipDiameter * (0.7 + frame.hold * 1.1),
                           height: tipDiameter * (0.7 + frame.hold * 1.1))
                fingertip
                    .scaleEffect(frame.scale)
            }
            .opacity(frame.opacity)
            .position(from)
        } keyframes: { _ in
            KeyframeTrack(\.opacity) {
                LinearKeyframe(0, duration: 0.05)
                CubicKeyframe(1, duration: 0.25)
                LinearKeyframe(1, duration: 1.1)
                CubicKeyframe(0, duration: 0.35)
            }
            KeyframeTrack(\.scale) {
                LinearKeyframe(1, duration: 0.45)
                SpringKeyframe(0.76, duration: 0.18)
                SpringKeyframe(1, duration: 0.42)
                LinearKeyframe(1, duration: 0.70)
            }
            KeyframeTrack(\.hold) {
                LinearKeyframe(0, duration: 0.60)
                CubicKeyframe(1, duration: 0.60)
                LinearKeyframe(0, duration: 0.55)
            }
        }
    }

    private var animatedPress: some View {
        KeyframeAnimator(initialValue: GhostFrame(), repeating: true) { frame in
            ZStack {
                holdRing(frame.hold)
                fingertip.scaleEffect(frame.scale)
            }
            .opacity(frame.opacity)
            .position(from)
        } keyframes: { _ in
            KeyframeTrack(\.opacity) {
                CubicKeyframe(1, duration: 0.3)
                LinearKeyframe(1, duration: 1.5)
                CubicKeyframe(0, duration: 0.3)
            }
            KeyframeTrack(\.scale) {
                SpringKeyframe(0.82, duration: 0.32)
                LinearKeyframe(0.82, duration: 1.5)
                SpringKeyframe(1, duration: 0.28)
            }
            KeyframeTrack(\.hold) {
                LinearKeyframe(0, duration: 0.32)
                LinearKeyframe(1, duration: 0.95)
                LinearKeyframe(1, duration: 0.55)
                LinearKeyframe(0, duration: 0.28)
            }
        }
    }

    /// Right to left, because that is the direction that moves you FORWARD
    /// through `AppPage` — drag the content left and the next page follows your
    /// finger. Teaching the swipe in the wrong direction is worse than not
    /// teaching it, since it is the direction that is unguessable, not the
    /// gesture.
    private var animatedSwipe: some View {
        KeyframeAnimator(initialValue: GhostFrame(), repeating: true) { frame in
            let x = from.x + swipeReach * (0.5 - frame.travel) * 2
            ZStack {
                trail(from: CGPoint(x: from.x + swipeReach, y: from.y),
                      to: CGPoint(x: x, y: from.y),
                      strength: frame.opacity * 0.55)
                fingertip.scaleEffect(frame.scale).position(x: x, y: from.y)
            }
            .opacity(frame.opacity)
        } keyframes: { _ in
            KeyframeTrack(\.travel) {
                LinearKeyframe(0, duration: 0.35)
                CubicKeyframe(1, duration: 0.85)
                LinearKeyframe(1, duration: 0.45)
            }
            KeyframeTrack(\.opacity) {
                CubicKeyframe(1, duration: 0.28)
                LinearKeyframe(1, duration: 0.95)
                CubicKeyframe(0, duration: 0.42)
            }
            KeyframeTrack(\.scale) {
                SpringKeyframe(0.86, duration: 0.3)
                LinearKeyframe(0.86, duration: 0.9)
                SpringKeyframe(1, duration: 0.45)
            }
        }
    }

    /// The full rail-to-rig demonstration: arrive, hold until it lifts, carry it
    /// across, let go. The hold ring completing BEFORE the travel starts is the
    /// whole lesson — a drag that begins the instant the finger lands teaches
    /// the gesture that does not work.
    private var animatedDrag: some View {
        let target = to ?? from
        return KeyframeAnimator(initialValue: GhostFrame(), repeating: true) { frame in
            let point = CGPoint(x: from.x + (target.x - from.x) * frame.travel,
                                y: from.y + (target.y - from.y) * frame.travel)
            ZStack {
                route(from: from, to: target).opacity(frame.opacity * 0.5)
                trail(from: from, to: point, strength: frame.opacity * 0.5)
                ZStack {
                    holdRing(frame.hold)
                    fingertip.scaleEffect(frame.scale)
                }
                .position(point)
            }
            .opacity(frame.opacity)
        } keyframes: { _ in
            KeyframeTrack(\.travel) {
                LinearKeyframe(0, duration: 1.15)          // land and hold
                CubicKeyframe(1, duration: 1.0)            // carry it over
                LinearKeyframe(1, duration: 0.55)          // drop, and let it read
            }
            KeyframeTrack(\.opacity) {
                CubicKeyframe(1, duration: 0.3)
                LinearKeyframe(1, duration: 1.95)
                CubicKeyframe(0, duration: 0.45)
            }
            KeyframeTrack(\.scale) {
                SpringKeyframe(0.84, duration: 0.35)
                LinearKeyframe(0.84, duration: 1.9)
                SpringKeyframe(1, duration: 0.45)
            }
            KeyframeTrack(\.hold) {
                LinearKeyframe(0, duration: 0.35)
                LinearKeyframe(1, duration: 0.80)          // the ring fills: "keep holding"
                LinearKeyframe(1, duration: 1.0)           // stays full while carried
                LinearKeyframe(0, duration: 0.55)
            }
        }
    }

    // MARK: - Reduce Motion drawings

    private var staticTap: some View {
        ZStack {
            Circle()
                .strokeBorder(RigTheme.amber.opacity(0.85), lineWidth: 2)
                .frame(width: tipDiameter * 1.55, height: tipDiameter * 1.55)
            fingertip
        }
        .position(from)
    }

    private var staticSwipe: some View {
        let start = CGPoint(x: from.x + swipeReach, y: from.y)
        let end = CGPoint(x: from.x - swipeReach, y: from.y)
        return ZStack {
            route(from: start, to: end)
            fingertip.position(start)
            arrowhead(at: end, pointingFrom: start)
        }
    }

    private var staticDrag: some View {
        let target = to ?? from
        return ZStack {
            route(from: from, to: target)
            ZStack {
                holdRing(1)
                fingertip
            }
            .position(from)
            arrowhead(at: target, pointingFrom: from)
        }
    }

    // MARK: - Pieces

    /// The fingertip itself: a soft amber disc with a bright rim, sized and
    /// weighted so it reads over the cream control panel AND over the blue-grey
    /// 3D stage without a drop shadow doing the work.
    private var fingertip: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [RigTheme.amber.opacity(0.55),
                                              RigTheme.amber.opacity(0.16)],
                                     center: .init(x: 0.4, y: 0.34),
                                     startRadius: 0, endRadius: tipDiameter * 0.6))
            Circle().strokeBorder(RigTheme.panel.opacity(0.85), lineWidth: 1.5)
        }
        .frame(width: tipDiameter, height: tipDiameter)
        .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
    }

    /// The ring that fills while the finger holds. Trimmed clockwise from the
    /// top, like every "keep pressing" affordance on the platform.
    private func holdRing(_ progress: CGFloat) -> some View {
        Circle()
            .trim(from: 0, to: max(0.001, progress))
            .stroke(RigTheme.amber, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: tipDiameter + 13, height: tipDiameter + 13)
            .opacity(progress > 0 ? 1 : 0)
    }

    /// The route a gesture takes, drawn as a dashed line so it reads as
    /// "intended path" rather than as a drawn object on the UI.
    private func route(from start: CGPoint, to end: CGPoint) -> some View {
        Path { path in
            path.move(to: start)
            path.addLine(to: end)
        }
        .stroke(RigTheme.amber.opacity(0.5),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 6]))
    }

    /// The solid part of the path already covered — a comet tail behind the
    /// finger, which is what makes a travelling dot read as a drag.
    private func trail(from start: CGPoint, to point: CGPoint, strength: CGFloat) -> some View {
        Path { path in
            path.move(to: start)
            path.addLine(to: point)
        }
        .stroke(
            LinearGradient(colors: [RigTheme.amber.opacity(0), RigTheme.amber.opacity(0.9)],
                           startPoint: .init(x: 0, y: 0.5), endPoint: .init(x: 1, y: 0.5)),
            style: StrokeStyle(lineWidth: 3, lineCap: .round)
        )
        .opacity(strength)
    }

    /// Direction, for the Reduce Motion drawings, where nothing moves to say it.
    private func arrowhead(at tip: CGPoint, pointingFrom origin: CGPoint) -> some View {
        let angle = atan2(tip.y - origin.y, tip.x - origin.x)
        return Image(systemName: "arrowtriangle.right.fill")
            .font(.system(size: 15))
            .foregroundStyle(RigTheme.amber)
            .rotationEffect(.radians(angle))
            .position(tip)
    }
}

#Preview("Gesture ghosts") {
    ZStack {
        RigTheme.background.ignoresSafeArea()
        GestureGhostView(gesture: .dragTo(.rigStage),
                         from: CGPoint(x: 90, y: 90), to: CGPoint(x: 320, y: 170),
                         reduceMotion: false)
        GestureGhostView(gesture: .tap, from: CGPoint(x: 480, y: 90), reduceMotion: false)
        GestureGhostView(gesture: .swipeLeft, from: CGPoint(x: 480, y: 200), reduceMotion: false)
        GestureGhostView(gesture: .press, from: CGPoint(x: 620, y: 110), reduceMotion: false)
    }
    .frame(width: 760, height: 300)
    .preferredColorScheme(.dark)
}

#Preview("Gesture ghosts — Reduce Motion") {
    ZStack {
        RigTheme.background.ignoresSafeArea()
        GestureGhostView(gesture: .dragTo(.rigStage),
                         from: CGPoint(x: 90, y: 90), to: CGPoint(x: 320, y: 170),
                         reduceMotion: true)
        GestureGhostView(gesture: .tap, from: CGPoint(x: 480, y: 90), reduceMotion: true)
        GestureGhostView(gesture: .swipeLeft, from: CGPoint(x: 480, y: 210), reduceMotion: true)
    }
    .frame(width: 760, height: 300)
    .preferredColorScheme(.dark)
}
