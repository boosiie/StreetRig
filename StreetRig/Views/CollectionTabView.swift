//
//  CollectionTabView.swift
//  StreetRig
//
//  The left tab: the user's owned gear, grouped with amps & cabinets on top
//  and pedals below (in signal-chain order), scrollable, one card each.
//  Cards drag out onto the rig stage to replace a part.
//

import SwiftUI

struct CollectionTabView: View {
    @EnvironmentObject var store: RigStore
    @EnvironmentObject var drag: RigDragController
    @State private var isDropTargeted = false

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

#Preview {
    CollectionTabView()
        .environmentObject(RigStore.preview)
        .environmentObject(RigDragController())
        .frame(height: 640)
        .background(RigTheme.background)
        .preferredColorScheme(.dark)
}
