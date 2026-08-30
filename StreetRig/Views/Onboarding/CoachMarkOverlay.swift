//
//  CoachMarkOverlay.swift
//  StreetRig
//
//  THE TOUR, DRAWN. A scrim over the live shell with one hole cut in it, a
//  caption card placed wherever the hole isn't, and a fingertip performing the
//  gesture inside the hole.
//
//  THE HOLE IS AN EVEN-ODD PATH, NOT A BLEND MODE. The usual recipe is a black
//  rectangle with a rounded rect drawn over it in `.destinationOut` inside a
//  `compositingGroup()`. It works, and it costs an offscreen render pass for
//  every frame of a spotlight that is animating between two targets — over a
//  live SceneKit stage, on a phone that is also running an audio graph. One
//  `Shape` whose `path(in:)` appends the cutout and fills `eoFill` gets the same
//  picture from the rasteriser it was already going to run, and it makes the
//  spotlight ANIMATABLE: `animatableData` interpolates the rect and the radius,
//  so the light travels from the rail to the trash instead of cutting to it.
//
//  THE SCRIM IS NOT PURE BLACK, and that is a real decision on this palette.
//  `RigTheme.background` is #170F09 — already almost black — so 75% black over
//  it changes a dark page by almost nothing, and a scrim you cannot see is a
//  tutorial pointing at a room with the lights already off. What DOES dim
//  visibly is the content: cards at #33221A, the cream control panel, the lit 3D
//  stage. So the scrim is black with a trace of the app's own espresso in it,
//  and the real work of saying "look here" is done by the amber rim and its
//  glow, which are bright against everything this app draws.
//
//  CAPTION PLACEMENT IS COMPUTED, NOT CHOSEN PER STEP. A landscape phone is
//  ~874 x 402: there is no fixed corner that is free for all twelve steps, and a
//  hand-placed caption per step is twelve things to get wrong again the next
//  time a layout moves. `captionRect(for:)` tries below, above, trailing and
//  leading in that order, takes the first that fits entirely inside the safe
//  area, and — for a spotlight that fills the page, where none of them fit —
//  drops the card INSIDE the bottom of the spotlight rather than off the screen.
//
//  INTERACTION IS BLOCKED, DELIBERATELY AND COMPLETELY. The scrim swallows every
//  touch. A player who drags real gear into the real bin during the step that is
//  explaining the bin has been failed by the tutorial, and "they can just undo
//  it" is not an answer when the gesture being demonstrated is destructive.
//  Advancing is by the card's own buttons only — not tap-anywhere — because on
//  a screen this size a stray thumb is not a decision.
//

import SwiftUI
import StreetRigEngine

// MARK: - The cut-out scrim

/// A full-bleed fill with one rounded hole in it. See the file header for why
/// this is a shape rather than a `.destinationOut` composite.
struct SpotlightScrimShape: Shape {
    var spot: CGRect
    var cornerRadius: CGFloat

    /// Rect + radius, so the hole interpolates between steps and the light
    /// TRAVELS. Nested pairs because that is the only shape `VectorArithmetic`
    /// gives us for five numbers.
    var animatableData: AnimatablePair<AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                                      AnimatablePair<CGFloat, CGFloat>>,
                                       CGFloat> {
        get {
            .init(.init(.init(spot.origin.x, spot.origin.y),
                        .init(spot.size.width, spot.size.height)),
                  cornerRadius)
        }
        set {
            spot = CGRect(x: newValue.first.first.first, y: newValue.first.first.second,
                          width: newValue.first.second.first, height: newValue.first.second.second)
            cornerRadius = newValue.second
        }
    }

    func path(in bounds: CGRect) -> Path {
        var path = Path(bounds)
        guard spot.width > 0, spot.height > 0 else { return path }
        path.addPath(Path(roundedRect: spot,
                          cornerRadius: min(cornerRadius, min(spot.width, spot.height) / 2),
                          style: .continuous))
        return path
    }
}

// MARK: - The overlay

struct CoachMarkOverlay: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    /// Everything the shell tagged, still unresolved. Handed in by
    /// `.overlayPreferenceValue` in `MainView`.
    let anchors: [CoachMarkTarget: Anchor<CGRect>]
    /// The reader's proxy — the shell's own root. Anchors resolve against this,
    /// which is what puts every rect in one space regardless of which side of
    /// the pager bridge it came from.
    let proxy: GeometryProxy

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The caption's measured size, fed back so placement can know whether the
    /// card actually fits below the spotlight. Seeded with a plausible value so
    /// the very first frame is not placed off screen.
    @State private var captionSize = CGSize(width: 320, height: 132)

    /// The spotlight's last good geometry. Held so that a step whose anchor is
    /// briefly missing — the pager mid-flight, a rail card scrolled out — leaves
    /// the light where it was rather than slamming the scrim shut and reopening.
    @State private var heldSpot: CGRect?

    private let scrimOpacity: CGFloat = 0.80
    private let captionGap: CGFloat = 14
    private let edgeMargin: CGFloat = 12

    var body: some View {
        if coordinator.phase == .tour, let step = coordinator.step {
            content(step)
        }
    }

    @ViewBuilder
    private func content(_ step: CoachMarkStep) -> some View {
        let container = CGRect(origin: .zero, size: proxy.size)
        let resolved = CoachMarkResolution.resolve(step.target, anchors: anchors, proxy: proxy)
        let spot = spotRect(for: step, resolved: resolved) ?? heldSpot
        let waiting = coordinator.isWaitingForPage(step)

        // Placement is worked out ONCE and shared, because the caption's position
        // is an input to the gesture ghost's. When the caption has to sit inside
        // the spotlight — the four page-region steps — a fingertip on the spot's
        // own centre lands underneath it, and the whole demonstration plays out
        // behind an opaque card.
        let place = captionRect(for: spot, in: container)

        ZStack {
            scrim(spot: spot, step: step, resolved: resolved)

            if let spot {
                spotlightRim(spot: spot, step: step, resolved: resolved)

                // Suppressed while the pager is still moving: a fingertip flying
                // across a page that is itself sliding reads as two unrelated
                // animations, not as one instruction.
                if !waiting {
                    ghost(step, spot: spot, avoiding: place)
                }
            }

            caption(step, place: place)
            skipBar
        }
        // MODAL, so VoiceOver stays in the tour instead of wandering into the
        // dimmed shell behind it and reading a rail it cannot reach.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .transition(.opacity)
        .onChange(of: spot) { _, latest in
            if let latest { heldSpot = latest }
        }
        .onAppear { if let spot { heldSpot = spot } }
        .onChange(of: coordinator.stepIndex) { _, _ in announce(step) }
    }

    /// THE WAY OUT, PINNED TO THE TOP-RIGHT AND NOWHERE NEAR NEXT.
    ///
    /// It used to live in the caption card's button row, which is the one piece
    /// of this screen that moves: the card follows the spotlight, so SKIP landed
    /// somewhere different on every step and sat a thumb's width from the button
    /// you press eleven times. Up here it is in the same corner on all twelve
    /// steps, far from the card wherever the card has gone, and it reads as the
    /// dismiss it is rather than as a third navigation choice.
    ///
    /// It stays PRESENT on every step regardless — a landscape-locked tutorial
    /// with no visible way out is the fastest way to make somebody resent an app.
    /// Moving it is about making it hard to hit by accident, not hard to find.
    /// POSITIONED WITH AN INSET FRAME, NOT WITH PADDING, and that distinction is
    /// the whole reason this button works.
    ///
    /// The first cut was a full-bleed `VStack`/`HStack` of spacers with
    /// `.padding(.top, 2).padding(.trailing, 2)` on the outside. A view that
    /// already fills its parent and is THEN padded wants to be four points
    /// bigger than the space it was given, so it overflows — and the pill ended
    /// up a couple of points outside the overlay's bounds. SwiftUI still DREW it
    /// there, perfectly, in the right corner: it just would not route a touch to
    /// anything outside the parent's bounds. A skip button that renders and
    /// cannot be pressed is worse than no skip button, because it looks like the
    /// way out right up until you need it.
    ///
    /// Taking the inset off `proxy.size` keeps the pill inside the bounds, which
    /// is where hit testing lives.
    private var skipBar: some View {
        Button { end { coordinator.skip() } } label: {
            Text("SKIP")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(RigTheme.textMuted)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(RigTheme.background.opacity(0.92)))
                .overlay(Capsule().strokeBorder(RigTheme.surfaceEdge, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Skip the walkthrough")
        .frame(width: max(0, proxy.size.width - 16),
               height: max(0, proxy.size.height - 16),
               alignment: .topTrailing)
    }

    // MARK: - Geometry

    /// The hole for this step: the resolved target, grown by the step's outset
    /// and clipped to the shell so it can never open a hole off the screen.
    private func spotRect(for step: CoachMarkStep, resolved: ResolvedCoachMark?) -> CGRect? {
        guard let resolved else { return nil }
        let grown = resolved.rect.insetBy(dx: -step.outset, dy: -step.outset)
        let clipped = grown.intersection(CGRect(origin: .zero, size: proxy.size))
        guard !clipped.isNull, clipped.width > 1, clipped.height > 1 else { return nil }
        return clipped
    }

    /// A page-region fallback gets a rounder hole. A 300 x 250 rectangle with a
    /// 10pt radius reads as a rendering error; the radius is what tells the eye
    /// "this is a region", not "this is a control".
    private func radius(for step: CoachMarkStep, resolved: ResolvedCoachMark?) -> CGFloat {
        guard let resolved else { return step.cornerRadius }
        return resolved.isFallback ? max(step.cornerRadius, 18) : step.cornerRadius
    }

    // MARK: - Layers

    /// THE SCRIM IS THE ONE LAYER IN A DIFFERENT COORDINATE SPACE, and it has to
    /// be. Everything else here is in the reader's space — which is the SAFE
    /// AREA, measured at 750 x 382 inside an 872 x 402 landscape phone, i.e. 61
    /// points short on each side for the camera housing and 20 at the bottom for
    /// the home indicator. A scrim that stopped there would leave three
    /// undimmed strips down the edges of a screen it is supposed to be dimming.
    ///
    /// `.ignoresSafeArea()` expands the shape to the whole display, which also
    /// moves its local origin out to the display's corner — so the hole, whose
    /// rect is still in reader space, has to be pushed back in by the same
    /// insets. That one `offsetBy` is what keeps the light on the target.
    private func scrim(spot: CGRect?, step: CoachMarkStep, resolved: ResolvedCoachMark?) -> some View {
        let insets = proxy.safeAreaInsets
        let bled = (spot ?? .zero).offsetBy(dx: insets.leading, dy: insets.top)
        return SpotlightScrimShape(spot: bled, cornerRadius: radius(for: step, resolved: resolved))
            .fill(scrimColour, style: FillStyle(eoFill: true))
            .ignoresSafeArea()
            // Every touch, everywhere, including inside the hole. See the header.
            .contentShape(Rectangle())
            .onTapGesture { }
            .accessibilityHidden(true)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: spot)
    }

    /// Black with a trace of the app's own espresso — see the file header. Held
    /// as literal channels rather than `RigTheme.background.mix(with: .black,…)`
    /// so it is one flat value the rasteriser resolves once, and so the ratio it
    /// was judged at cannot drift when the palette's page colour is retuned.
    private var scrimColour: Color {
        Color(red: 0.031, green: 0.020, blue: 0.012).opacity(scrimOpacity)
    }

    /// The rim and its glow — the part that actually says "here".
    private func spotlightRim(spot: CGRect, step: CoachMarkStep, resolved: ResolvedCoachMark?) -> some View {
        RoundedRectangle(cornerRadius: min(radius(for: step, resolved: resolved),
                                           min(spot.width, spot.height) / 2),
                         style: .continuous)
            .strokeBorder(RigTheme.amber.opacity(0.95), lineWidth: 2)
            .shadow(color: RigTheme.amber.opacity(0.55), radius: 10)
            .shadow(color: RigTheme.amber.opacity(0.30), radius: 22)
            .frame(width: spot.width, height: spot.height)
            .position(x: spot.midX, y: spot.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: spot)
    }

    @ViewBuilder
    private func ghost(_ step: CoachMarkStep, spot: CGRect, avoiding place: CaptionPlacement) -> some View {
        let origin = gestureAnchor(in: spot, avoiding: place)
        switch step.gesture {
        case .none:
            EmptyView()
        case .dragTo(let destination):
            // The far end is a target too, so the drag still lands on the rig on
            // an iPad where both ends are somewhere else. If it cannot be
            // resolved, aim at the middle of the shell rather than drawing a
            // drag to nowhere.
            let end = CoachMarkResolution.resolve(destination, anchors: anchors, proxy: proxy)?.rect
            let target = end.map { gestureAnchor(in: $0, avoiding: place) }
            GestureGhostView(gesture: step.gesture,
                             from: origin,
                             to: target ?? CGPoint(x: proxy.size.width * 0.6,
                                                   y: proxy.size.height * 0.5),
                             reduceMotion: reduceMotion)
        default:
            GestureGhostView(gesture: step.gesture, from: origin, reduceMotion: reduceMotion)
        }
    }

    /// Where in the spotlight to put the hand: its centre, unless the caption is
    /// sitting inside the spotlight — in which case the centre of whatever is
    /// left above the card, which on a page-sized spot is most of it.
    private func gestureAnchor(in spot: CGRect, avoiding place: CaptionPlacement) -> CGPoint {
        guard place.overlapsSpot else { return CGPoint(x: spot.midX, y: spot.midY) }
        let clearBottom = min(place.rect.minY - captionGap, spot.maxY)
        guard clearBottom - spot.minY > 60 else { return CGPoint(x: spot.midX, y: spot.midY) }
        return CGPoint(x: spot.midX, y: (spot.minY + clearBottom) / 2)
    }

    // MARK: - Caption

    private func caption(_ step: CoachMarkStep, place: CaptionPlacement) -> some View {
        captionCard(step, overlapping: place.overlapsSpot)
            .frame(width: place.rect.width)
            .background(captionMeasure)
            .position(x: place.rect.midX, y: place.rect.midY)
            .animation(.spring(response: 0.45, dampingFraction: 0.88), value: place.rect)
    }

    private var captionMeasure: some View {
        GeometryReader { inner in
            Color.clear
                .onAppear { captionSize = inner.size }
                .onChange(of: inner.size) { _, size in captionSize = size }
        }
    }

    private func captionCard(_ step: CoachMarkStep, overlapping: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(step.title)
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(RigTheme.amber)
                Spacer(minLength: 4)
                Text("\(coordinator.stepIndex + 1)/\(coordinator.steps.count)")
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(RigTheme.textMuted)
            }

            Text(step.detail)
                .font(.system(size: 11.5))
                .foregroundStyle(RigTheme.textPrimary.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            progressPips

            HStack(spacing: 8) {
                // SKIP IS NOT IN THIS ROW ANY MORE — see `skipBar`. It sat on the
                // leading edge here, one pill away from BACK and two from NEXT,
                // which put "leave the tour" inside the same thumb sweep as "keep
                // going". On a card that MOVES from step to step, that is a
                // mis-tap waiting to happen, and the cost of the mis-tap is the
                // whole walkthrough.
                if coordinator.stepIndex > 0 {
                    pill("BACK", tone: .quiet) { withAnimation(.easeInOut(duration: 0.28)) { coordinator.retreat() } }
                }
                Spacer(minLength: 0)
                pill(coordinator.isLastStep ? "FINISH" : "NEXT", tone: .primary) {
                    if coordinator.isLastStep {
                        end { coordinator.finish() }
                    } else {
                        withAnimation(.easeInOut(duration: 0.28)) { coordinator.advance() }
                    }
                }
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        // A caption sitting INSIDE the spotlight is over live UI, so it takes
        // the deeper shadow and an opaque backing; one resting on the scrim does
        // not need either.
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(RigTheme.background.opacity(overlapping ? 0.97 : 0.75))
        }
        .rigCard(cornerRadius: RigTheme.Radius.control, stroke: RigTheme.amber.opacity(0.35), lifted: overlapping)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(coordinator.stepIndex + 1) of \(coordinator.steps.count), \(step.title). Showing \(step.target.accessibleName).")
    }

    /// Where you are, without reading the counter. Twelve pips fit across a
    /// 320pt card at 4pt each; the current one widens rather than brightening,
    /// because on this palette a brightness step that small does not survive
    /// being 4 points wide.
    private var progressPips: some View {
        HStack(spacing: 3) {
            ForEach(coordinator.steps) { item in
                Capsule()
                    .fill(item.id == coordinator.stepIndex
                          ? RigTheme.amber
                          : RigTheme.textMuted.opacity(item.id < coordinator.stepIndex ? 0.5 : 0.22))
                    .frame(width: item.id == coordinator.stepIndex ? 13 : 4, height: 4)
            }
            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: 0.28), value: coordinator.stepIndex)
        .accessibilityHidden(true)
    }

    private enum PillTone { case primary, quiet }

    private func pill(_ title: String, tone: PillTone, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(tone == .primary ? .black : RigTheme.textMuted)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background {
                    if tone == .primary {
                        Capsule().fill(RigTheme.amber)
                    } else {
                        Capsule().fill(RigTheme.surfaceRaised)
                            .overlay { Capsule().strokeBorder(RigTheme.surfaceEdge, lineWidth: 1) }
                    }
                }
        }
        .buttonStyle(.plain)
    }

    /// Closing the tour is the one transition that must not be a spring: the
    /// scrim is over the live app, and a bouncing hole on the way out looks like
    /// the app is still doing something to you after you asked it to stop.
    private func end(_ action: @escaping () -> Void) {
        withAnimation(.easeOut(duration: 0.25)) { action() }
    }

    // MARK: - Caption placement

    struct CaptionPlacement {
        let rect: CGRect
        /// True when the card had to be dropped inside the spotlight because no
        /// band around it was big enough — the four page-region steps, mainly.
        let overlapsSpot: Bool
    }

    /// Below, above, trailing, leading — first fit wins. See the file header for
    /// why this is computed rather than authored per step.
    private func captionRect(for spot: CGRect?, in container: CGRect) -> CaptionPlacement {
        // `container` is the READER's bounds, which are already inside the safe
        // area (see `scrim`) — so this insets for breathing room only. Adding
        // `proxy.safeAreaInsets` here as well took 122 points off the width for
        // a notch that had already been accounted for.
        let safe = container.inset(by: EdgeInsets.uniform(edgeMargin))
        let width = min(340, max(220, safe.width))
        let height = captionSize.height

        guard let spot else {
            return CaptionPlacement(rect: CGRect(x: safe.midX - width / 2,
                                                 y: safe.midY - height / 2,
                                                 width: width, height: height),
                                    overlapsSpot: false)
        }

        let candidates: [CGRect] = [
            CGRect(x: spot.midX - width / 2, y: spot.maxY + captionGap, width: width, height: height),
            CGRect(x: spot.midX - width / 2, y: spot.minY - captionGap - height, width: width, height: height),
            CGRect(x: spot.maxX + captionGap, y: spot.midY - height / 2, width: width, height: height),
            CGRect(x: spot.minX - captionGap - width, y: spot.midY - height / 2, width: width, height: height)
        ]

        for candidate in candidates {
            // Slide it along the axis it is free on before rejecting it: a
            // caption under the trash target is fine, it just cannot be centred
            // on a circle that is 20 points from the left edge.
            let nudged = clamp(candidate, into: safe)
            guard nudged.size == candidate.size else { continue }
            if safe.contains(nudged), !nudged.intersects(spot.insetBy(dx: 2, dy: 2)) {
                return CaptionPlacement(rect: nudged, overlapsSpot: false)
            }
        }

        // Nothing fits beside it — the spotlight is a whole page. Sit the card
        // inside the bottom of the light, where it covers the least.
        let inside = clamp(CGRect(x: spot.midX - width / 2,
                                  y: spot.maxY - height - captionGap,
                                  width: width, height: height),
                           into: safe)
        return CaptionPlacement(rect: inside, overlapsSpot: true)
    }

    private func clamp(_ rect: CGRect, into bounds: CGRect) -> CGRect {
        var result = rect
        result.origin.x = min(max(rect.origin.x, bounds.minX), max(bounds.minX, bounds.maxX - rect.width))
        result.origin.y = min(max(rect.origin.y, bounds.minY), max(bounds.minY, bounds.maxY - rect.height))
        return result
    }

    private func announce(_ step: CoachMarkStep) {
        AccessibilityNotification.Announcement("\(step.title). \(step.detail)").post()
    }
}

// MARK: - Small helpers

private extension EdgeInsets {
    static func uniform(_ value: CGFloat) -> EdgeInsets {
        EdgeInsets(top: value, leading: value, bottom: value, trailing: value)
    }
}

private extension CGRect {
    /// `CGRect.inset(by:)` takes a `UIEdgeInsets`; this is the SwiftUI-shaped
    /// one, and it keeps the leading/trailing naming honest in a layout that is
    /// always left-to-right here but need not stay that way.
    func inset(by insets: EdgeInsets) -> CGRect {
        CGRect(x: minX + insets.leading,
               y: minY + insets.top,
               width: max(0, width - insets.leading - insets.trailing),
               height: max(0, height - insets.top - insets.bottom))
    }
}

// The overlay cannot be previewed on its own: it has no geometry of its own to
// show, only a scrim over somebody else's. So the preview is the SHELL with the
// tour already running, which is also the only honest way to check that a hole
// lands on a real control.
#Preview("Coach-mark tour", traits: .landscapeLeft) {
    let coordinator = OnboardingCoordinator()
    coordinator.replayTour()
    return MainView()
        .environmentObject(RigStore.preview)
        .environmentObject(ProfileStore.preview)
        .environmentObject(UserPresetStore.preview)
        .environmentObject(RigDragController())
        .environmentObject(ARSlotLift())
        .environmentObject(coordinator)
        .preferredColorScheme(.dark)
}
