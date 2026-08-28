//
//  GearCardView.swift
//  StreetRig
//
//  A single collection card: a vectorized picture of the actual gear + name.
//  Draggable — hold briefly and the card compresses as an amber ring charges
//  around it, thumps when it's yours, then pulls onto the rig stage to swap that
//  part. A plain swipe scrolls the rail instead. The grip dots, the ring and the
//  tap-hint all exist for one reason: the hold is invisible on its own.
//

import SwiftUI
import StreetRigEngine

struct GearCardView: View {
    @EnvironmentObject private var drag: RigDragController
    let item: GearItem
    /// Which card the rail is currently holding, owned by the rail so it can stop
    /// scrolling the instant a card is picked up — before the ghost exists.
    @Binding var held: GearItem.ID?
    /// Set on the rail's first card, once ever, to nudge that these lift.
    var demoLift: Bool = false
    /// This gear is already placed in the rig on MY RIG. Passed in rather than
    /// read from the store so this card stays a pure presentation view, the same
    /// way `demoLift` is decided by the rail.
    var inRig: Bool = false

    private var isHeld: Bool { held == item.id }
    /// True only once the ghost exists — i.e. the card really has left the rail.
    private var isLifted: Bool { drag.item?.id == item.id }

    /// A drag threshold no finger will ever reach — see `liftDrag`.
    private let unreachable: CGFloat = 10_000

    /// The charge waits, then runs; the two sum to the hold duration so it
    /// completes exactly as the card lifts. The wait is what stops the rail
    /// strobing on every scroll flick — `onPressingChanged` fires on ANY touch
    /// down, including one that becomes a scroll.
    private let chargeDelay: Duration = .milliseconds(80)
    private let chargeFill: TimeInterval = 0.17

    /// 0…1 for the whole hold. Drives the ring AND the squeeze from one value, so
    /// they physically cannot drift out of step.
    @State private var charge: CGFloat = 0
    @State private var chargeTask: Task<Void, Never>?
    /// Flipped by the charge animation's own completion — see `beginCharge`.
    @State private var charged = false
    @State private var pressing = false
    @State private var didLift = false
    @State private var hinting = false
    @State private var hintTask: Task<Void, Never>?
    @State private var demoOffset: CGFloat = 0

    /// Compresses in lockstep with the ring, and STAYS compressed once the hold
    /// lands — no spring back out. A pop at the moment of success read as the
    /// gesture ending rather than the card being ready to move.
    private var cardScale: CGFloat { 1 - 0.04 * charge }

    var body: some View {
        VStack(spacing: 8) {
            GearArtView(item: item)
                .frame(width: item.category.artSize.width,
                       height: item.category.artSize.height)
                .frame(maxWidth: .infinity)
                .frame(height: 56)

            Text(item.name)
                .font(.caption2.weight(.medium))
                .foregroundStyle(RigTheme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
                .frame(height: 28)

        }
        .padding(10)
        .frame(maxWidth: .infinity)
        // `.rigCard` before the affordance overlays so the grip dots, hold ring and
        // hint draw ON the card rather than under its edge and shadow.
        .rigCard(cornerRadius: RigTheme.Radius.control, stroke: RigTheme.surfaceEdge)
        // Gear already in the rig sits in shadow, matching how the library shades
        // what you already own: darkened means "already accounted for", so the
        // cards that stay bright are the ones still available to place. The rail
        // lists everything owned, and `maxPedalsOnBoard` keeps most of it off the
        // board, so without this the spare pedals and the placed ones look alike.
        //
        // The shadow is the standing signal that these cards do not lift (the
        // hold is refused below). ABOVE the card fill but BELOW the overlays that
        // follow, so the tap hint EXPLAINING the refusal stays at full contrast --
        // dimming the one thing that answers "why did nothing happen?" would be
        // exactly backwards. Hit testing off; the refusal lives in the gesture.
        .overlay {
            if inRig {
                RoundedRectangle(cornerRadius: RigTheme.Radius.control, style: .continuous)
                    .fill(RigTheme.background.opacity(0.58))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) { gripDots }
        .overlay { holdRing }
        .overlay(alignment: .bottom) { tapHint }
        // Dim ONLY once the ghost exists. Dimming at the moment of the hold left a
        // greyed-out card with nothing yet in hand — which reads as "disabled",
        // and is exactly when people let go.
        .opacity(isLifted ? 0.35 : 1)
        .scaleEffect(cardScale)   // animates with `charge`; no separate curve
        .offset(y: demoOffset)
        .contentShape(RoundedRectangle(cornerRadius: RigTheme.Radius.control, style: .continuous))
        // Someone who taps instead of holding gets told what to do instead —
        // and nobody who already knows ever sees it.
        .onTapGesture { showHint() }
        // The hold and the drag are two SEPARATE gestures on purpose. A
        // `LongPressGesture` sequenced before a `DragGesture` claims the touch
        // outright and the rail's ScrollView pan then never starts at all — that
        // is what made the rail completely unscrollable, and no amount of tuning
        // the sequence fixed it. `.onLongPressGesture` leaves the pan alone, so a
        // flick scrolls and only a real hold picks a card up.
        .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 10) {
            guard !inRig else { return }
            held = item.id
            didLift = true
            // Deliberately NOT discharging here: the card holds its squeeze so
            // nothing moves at the instant of success except the ring fading.
        } onPressingChanged: { isPressing in
            if isPressing {
                // Gear in the rig doesn't come out of the rail, so don't even
                // start the charge: a ring that fills and then refuses to hand
                // the card over teaches that the hold is broken. Guarding the
                // press-DOWN only -- the release path below must always run, or
                // a hold that ends after this flips would strand the ghost and
                // leave the rail disabled for good.
                guard !inRig else { return }
                pressing = true
                didLift = false
                beginCharge()
                return
            }
            pressing = false
            endCharge()
            // The drag below may never reach its threshold, so lifting the finger
            // here is the only guaranteed end: without it a hold-and-release would
            // strand the ghost and leave the rail disabled for good.
            if isHeld { held = nil }
            if drag.item?.id == item.id { drag.end() }
        }
        .simultaneousGesture(liftDrag)
        // At 0.25s the hold is too short to be sure of by eye, so the thump is what
        // tells the player the card is actually in their hand — landing on the
        // exact frame the ring closes the loop.
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.8), trigger: charged) { _, done in done }
        .task(id: demoLift) { await playDemoLift() }
    }

    // MARK: - Affordances

    /// The standing "you can grab this" mark. Fades out once the card is in play,
    /// where the ring and the ghost are saying it far louder.
    private var gripDots: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(spacing: 2.5) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(RigTheme.textMuted.opacity(0.3))
                            .frame(width: 2, height: 2)
                    }
                }
            }
        }
        .padding(7)
        // Hidden on in-rig cards: the dots are the standing "you can grab this"
        // mark, and it is not true of gear that is already in the rig.
        .opacity(inRig || pressing || isHeld || isLifted ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: pressing)
    }

    /// Fills over the hold, so an aborted press shows a half-drawn ring — which
    /// teaches "too early" rather than "nothing happened".
    private var holdRing: some View {
        RoundedRectangle(cornerRadius: RigTheme.Radius.control, style: .continuous)
            .trim(from: 0, to: charge)
            .stroke(RigTheme.amber, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .opacity(isHeld || isLifted ? 0 : 1)
            .animation(.easeOut(duration: 0.14), value: isHeld)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var tapHint: some View {
        if hinting {
            // A locked card's tap answers "why won't this move?" instead of
            // teaching the hold. Without it the refusal just reads as a dead card.
            Text(inRig ? "IN YOUR RIG" : "HOLD TO PICK UP")
                .rigLegend(8, weight: .bold)
                .foregroundStyle(RigTheme.background)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(RigTheme.amber))
                .padding(.bottom, 7)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .allowsHitTesting(false)
        }
    }

    private func beginCharge() {
        chargeTask?.cancel()
        charged = false
        chargeTask = Task { @MainActor in
            try? await Task.sleep(for: chargeDelay)
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: chargeFill)) {
                charge = 1
            } completion: {
                // Fire from the animation finishing, NOT from the long-press
                // timer. Both nominally land at 0.25s, but the timer is exact
                // while the ring is an 80ms sleep plus a 170ms curve — so the
                // thump used to beat the ring closing. This ties it to what the
                // eye actually sees. The guard keeps an aborted hold silent:
                // `pressing` is cleared before the discharge interrupts us.
                guard pressing else { return }
                charged = true
            }
        }
    }

    /// Only ever the abort/finish path — a successful hold leaves the charge up.
    private func endCharge() {
        chargeTask?.cancel()
        chargeTask = nil
        charged = false
        withAnimation(.easeOut(duration: 0.12)) { charge = 0 }
    }

    private func showHint() {
        // A tap that followed a successful hold isn't a mistake — stay quiet.
        guard !didLift else { return }
        hintTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) { hinting = true }
        hintTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) { hinting = false }
        }
    }

    private func playDemoLift() async {
        guard demoLift else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { demoOffset = -8 }
        try? await Task.sleep(for: .milliseconds(280))
        guard !Task.isCancelled else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.7)) { demoOffset = 0 }
    }

    /// Follows the finger once the hold has picked the card up, in the shared
    /// "appRoot" space. We use a real gesture rather than `.draggable` because the
    /// system drag won't reliably lift here — see RigDragController.
    ///
    /// The threshold is the whole trick. Parked out of reach until the card is
    /// held, this gesture never claims the touch, so the rail's ScrollView always
    /// wins the pan — a fixed threshold instead let a fast flick through, because
    /// one event can clear 24pt outright and SwiftUI then took the touch and the
    /// rail sat still. It has to be raised *in place* rather than switched with
    /// `isEnabled:`: toggling detaches the recognizer, and one attached mid-touch
    /// never receives the finger already down, so the lift would never track.
    private var liftDrag: some Gesture {
        DragGesture(minimumDistance: isHeld ? 24 : unreachable, coordinateSpace: .named("appRoot"))
            .onChanged { move in
                guard isHeld else { return }
                // `.rail` origin: dropping this on the trash DELETES the gear
                // (a piece lifted off the stage only leaves the rig).
                if drag.item == nil { drag.begin(item, at: move.location, from: .rail) }
                else { drag.move(to: move.location) }
            }
            .onEnded { move in
                guard isHeld else { return }
                held = nil
                guard drag.item?.id == item.id else { return }
                drag.move(to: move.location)
                drag.end()
            }
    }
}

#Preview {
    @Previewable @State var held: GearItem.ID?
    HStack {
        GearCardView(item: GearItem(name: "Marswell JCM800 2203", category: .amp), held: $held)
        GearCardView(item: GearItem(name: "Ibonez Tube Screamer", category: .overdrive), held: $held, demoLift: true)
        GearCardView(item: GearItem(name: "DUNLAP CRY BABY", category: .wah), held: $held)
    }
    .frame(width: 460)
    .padding()
    .background(RigTheme.background)
    .environmentObject(RigDragController())
    .preferredColorScheme(.dark)
}
