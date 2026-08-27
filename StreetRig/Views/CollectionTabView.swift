//
//  CollectionTabView.swift
//  StreetRig
//
//  The left tab: the user's owned gear, grouped with amps & cabinets on top
//  and pedals below (in signal-chain order), scrollable, one card each.
//  Cards drag out onto the rig stage to replace a part — or across to the trash
//  target that fades in at the top of the centre area, just past this rail,
//  which deletes them (see GearTrashTarget).
//

import SwiftUI
import StreetRigEngine

struct CollectionTabView: View {
    @EnvironmentObject var store: RigStore
    @EnvironmentObject var drag: RigDragController
    @State private var isDropTargeted = false
    /// The card currently held down, set by GearCardView the moment its hold
    /// succeeds. Tracked here (not in the controller) purely so the rail can stop
    /// scrolling before the drag begins — see `scrollDisabled` below.
    @State private var heldCard: GearItem.ID?
    /// Shown once, ever: the rail's first card gives a small hop so a new player
    /// sees that these lift at all.
    @AppStorage("streetrig.railLiftHintShown") private var railHintShown = false
    @State private var demoTarget: GearItem.ID?

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
            VStack(alignment: .leading, spacing: 3) {
                Text("MY GEAR")
                    .font(.caption2.weight(.bold))
                    .tracking(1.5)
                    .foregroundStyle(RigTheme.textMuted)
                // The standing instruction. One line here beats repeating a hint
                // on all 47 cards, and the rail is only 150pt wide.
                Text("HOLD TO PLACE")
                    .font(.system(size: 8, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(RigTheme.textMuted.opacity(0.55))
            }
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
            // Freeze the rail from the moment a card is held, not just once the
            // ghost exists: otherwise pulling a held card straight up out of the
            // rail scrolls it instead of lifting, since the ScrollView wins the
            // pan before the drag clears its threshold.
            .scrollDisabled(drag.isDragging || heldCard != nil)
        }
        .frame(width: 150)
        .onAppear {
            guard !railHintShown else { return }
            demoTarget = ampsAndCabs.first?.id ?? pedals.first?.id
            railHintShown = true
        }
        .background(RigTheme.background.opacity(0.55))
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
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
    }

    /// The card the coach-mark tour points at when it teaches the hold-and-drag.
    /// The SAME card the one-shot hint hops, and for the same reason: it is the
    /// first thing in the rail, so it is on screen without scrolling and it is
    /// where a new player's eye already is.
    private var tourCardID: GearItem.ID? { ampsAndCabs.first?.id ?? pedals.first?.id }

    @ViewBuilder
    private func section(_ title: String, items: [GearItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(RigTheme.trim.opacity(0.9))
            ForEach(items) { item in
                GearCardView(item: item, held: $heldCard, demoLift: item.id == demoTarget)
                    .coachMarkTargetIf(item.id == tourCardID, .railCard)
            }
        }
    }
}

#Preview {
    CollectionTabView()
        .environmentObject(RigStore.preview)
        .environmentObject(RigDragController())
        .frame(height: 640)
        .background(RigTheme.background)
        .preferredColorScheme(.dark)
}
