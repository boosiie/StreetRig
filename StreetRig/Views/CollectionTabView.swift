//
//  CollectionTabView.swift
//  StreetRig
//
//  The left tab: the user's owned gear, grouped with amps & cabinets on top
//  and pedals below (in signal-chain order), scrollable, one card each.
//  Cards drag out onto the rig stage to replace a part — or down onto the trash
//  target that fades in at the bottom of the rail for the duration of a drag,
//  which deletes the gear (rail card) or pulls it off the board (stage piece).
//

import SwiftUI
import StreetRigEngine

struct CollectionTabView: View {
    @EnvironmentObject var store: RigStore
    @EnvironmentObject var drag: RigDragController
    @State private var isDropTargeted = false

    /// A deletion waiting on the player's answer (in-use gear only).
    @State private var pendingRemoval: PendingGearRemoval?
    /// Inline reason for a rejected drop ("Your guitar is fixed"), auto-clearing.
    @State private var rejection: String?
    /// Bumped per rejection so the shake replays even for the same reason.
    @State private var rejectionShake: CGFloat = 0
    @State private var rejectionTimeout: Task<Void, Never>?

    /// Amps, cabinets, combos — the guitar is fixed so it's not listed.
    private var ampsAndCabs: [GearItem] {
        let order: [GearCategory] = [.amp, .cabinet, .comboAmp]
        return store.collection
            .filter { !$0.category.isPedal && $0.category != .guitar }
            .sorted {
                let a = order.firstIndex(of: $0.category) ?? 99
                let b = order.firstIndex(of: $1.category) ?? 99
                return a != b ? a < b : $0.name < $1.name
            }
    }

    private var pedals: [GearItem] {
        store.collection
            .filter { $0.category.isPedal }
            .sorted {
                $0.category.chainOrder != $1.category.chainOrder
                    ? $0.category.chainOrder < $1.category.chainOrder
                    : $0.name < $1.name
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MY GEAR")
                .font(.caption2.weight(.bold))
                .tracking(1.5)
                .foregroundStyle(RigTheme.textMuted)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    section("AMPS & CABS", items: ampsAndCabs)
                    section("PEDALS", items: pedals)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
            .scrollDisabled(drag.isDragging)   // don't scroll the rail mid-drag
        }
        .frame(width: 150)
        .background(RigTheme.background.opacity(0.55))
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
        }
        // Docked at the BOTTOM of the rail as an overlay, so it can never reflow
        // the card list — the list must not jump the instant a card is lifted.
        .overlay(alignment: .bottom) {
            RailTrashTarget(rejection: rejection, shake: rejectionShake)
                .padding(.bottom, 10)
        }
        .overlay {
            Rectangle()
                .strokeBorder(RigTheme.amber, lineWidth: 3)
                .opacity(isDropTargeted ? 0.85 : 0)
                .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
                .allowsHitTesting(false)
        }
        // Drop a library card here to add it to the collection.
        .dropDestination(for: GearItem.self) { items, _ in
            var added = false
            for item in items where !store.isOwned(item) {
                store.addToCollection(item)
                added = true
            }
            return added
        } isTargeted: { isDropTargeted = $0 }
        // The rail owns the trash target, so it owns what a drop on it means.
        .onAppear { drag.onTrash = { item, origin in handleTrash(item, from: origin) } }
        .gearRemovalConfirmation($pendingRemoval, store: store)
    }

    /// A card was released over the trash. What that means depends entirely on
    /// where the drag started — see `RigDragOrigin`.
    private func handleTrash(_ item: GearItem, from origin: RigDragOrigin) {
        switch origin {
        case .rail:
            // Owned gear being deleted. Everything funnels through GearRemoval so
            // the library's owned tiles ask the identical question.
            switch GearRemoval.request(item.id, store: store) {
            case .removed:                        break
            case .needsConfirmation(let pending):  pendingRemoval = pending
            case .rejected(let reason):            reject(reason)
            }

        case .stage:
            // Pulled off the rig board: the gear stays OWNED and stays in this
            // rail. Only the board loses it.
            guard item.category.isPedal else {
                // The only non-pedal the stage lets you lift is the guitar, and
                // the guitar is fixed — same refusal, same wording.
                reject(GearRemoval.protectedReason)
                return
            }
            withAnimation(.easeInOut(duration: 0.28)) { store.removePedal(item.id) }
        }
    }

    /// Refuse a drop out loud: shake the target and post a short reason under it.
    /// A dialog would be far too much ceremony for "no".
    private func reject(_ reason: String) {
        rejectionTimeout?.cancel()
        rejection = reason
        withAnimation(.easeInOut(duration: 0.45)) { rejectionShake += 1 }
        rejectionTimeout = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { rejection = nil }
        }
    }

    @ViewBuilder
    private func section(_ title: String, items: [GearItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(RigTheme.trim.opacity(0.9))
            ForEach(items) { GearCardView(item: $0) }
        }
    }
}

/// The drag-only trash target docked at the bottom of the rail.
///
/// Idle state costs nothing: it is laid out permanently (so its frame is always
/// current for the drag controller's hit test) but drawn at zero opacity and
/// non-interactive, so there is no persistent trash button and no permanent rail
/// chrome. It fades in with the drag and, on hover, scales up and goes solid
/// `RigTheme.clip` — the existing semantic clip/peak red, deliberately not the
/// amber that already means "drop here to swap this piece in".
private struct RailTrashTarget: View {
    @EnvironmentObject private var drag: RigDragController
    let rejection: String?
    let shake: CGFloat

    private let diameter: CGFloat = 58

    var body: some View {
        // Stays up a beat past the drag when a rejection needs explaining.
        let visible = drag.isDragging || rejection != nil
        let hot = drag.isOverTrash

        VStack(spacing: 5) {
            ZStack {
                Circle().fill(hot ? RigTheme.clip : RigTheme.clip.opacity(0.16))
                Circle().strokeBorder(RigTheme.clip.opacity(hot ? 0 : 0.9), lineWidth: 1.5)
                Image(systemName: "trash.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(hot ? .white : RigTheme.clip)
            }
            .frame(width: diameter, height: diameter)
            .scaleEffect(hot ? 1.18 : 1)
            .shadow(color: .black.opacity(0.55), radius: 9, y: 4)
            .background(frameReader)

            Text(rejection ?? caption)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(rejection == nil ? RigTheme.clip.opacity(0.95) : RigTheme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .frame(width: 120)
        }
        .modifier(ShakeEffect(phase: shake))
        .padding(.top, 14)
        .background(
            // Enough of a scrim that the target never reads as a card.
            LinearGradient(colors: [RigTheme.background.opacity(0), RigTheme.background.opacity(0.92)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.86, anchor: .bottom)
        .animation(.easeOut(duration: 0.18), value: visible)
        .animation(.easeOut(duration: 0.14), value: hot)
        // The project's haptic idiom (see TapSlider): SwiftUI-native, so it
        // no-ops wherever there's no haptic context. Fires only on ENTERING the
        // target — that's the commit point the player needs to feel.
        .sensoryFeedback(trigger: hot) { _, isHot in isHot ? .impact(flexibility: .rigid) : nil }
        // Never eats a tap or a scroll: the drag controller hit-tests it by frame.
        .allowsHitTesting(false)
    }

    /// A rail drag DELETES; a stage drag only unloads the piece from the rig.
    /// Saying which keeps one red circle from meaning two different things.
    private var caption: String { drag.origin == .stage ? "OFF RIG" : "DELETE" }

    /// Publishes the target's frame in the shared "appRoot" space. Slightly
    /// generous — a 58pt circle is a small thing to hit with a moving finger.
    private var frameReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { drag.trashFrame = proxy.frame(in: .named("appRoot")).insetBy(dx: -12, dy: -12) }
                .onChange(of: proxy.frame(in: .named("appRoot"))) { _, frame in
                    drag.trashFrame = frame.insetBy(dx: -12, dy: -12)
                }
        }
    }
}

/// A short horizontal wobble, used to refuse a drop. Driven by a phase counter
/// so the same rejection can replay.
private struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 7
    var shakes: CGFloat = 3
    var phase: CGFloat

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(translationX: travel * sin(phase * .pi * shakes * 2), y: 0)
        )
    }
}

#Preview("Idle") {
    CollectionTabView()
        .environmentObject(RigStore.preview)
        .environmentObject(RigDragController())
        .frame(height: 640)
        .background(RigTheme.background)
        .preferredColorScheme(.dark)
}

#Preview("Dragging — trash target visible") {
    // A drag already in flight, so the preview shows the state that only exists
    // mid-gesture: the trash docked at the bottom of the rail.
    let drag = RigDragController()
    let store = RigStore.preview
    if let pedal = store.collection.first(where: { $0.category.isPedal }) {
        drag.begin(pedal, at: CGPoint(x: 75, y: 520))
    }
    return CollectionTabView()
        .environmentObject(store)
        .environmentObject(drag)
        .frame(height: 640)
        .background(RigTheme.background)
        .preferredColorScheme(.dark)
}
