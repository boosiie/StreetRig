//
//  ControlBoardView.swift
//  StreetRig
//
//  The CONTROLS page: every adjustable component in the current rig (amp/combo
//  + pedals) laid out as cards of tap-to-set sliders. Each slider is bound to
//  the same `store.binding(itemId:param:)` as the zoom-view knobs, so the two
//  stay in sync.
//

import SwiftUI

struct ControlBoardView: View {
    @EnvironmentObject var store: RigStore

    /// Rig components that actually have adjustable parameters.
    private var components: [GearItem] {
        var items: [GearItem] = []
        if let amp = store.ampItem, !amp.parameters.isEmpty { items.append(amp) }
        items.append(contentsOf: store.pedalItems.filter { !$0.parameters.isEmpty })
        return items
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if components.isEmpty {
                    Text("No adjustable components in your rig.")
                        .font(.callout)
                        .foregroundStyle(RigTheme.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    ForEach(components) { componentCard($0) }
                }
            }
            .padding(20)
        }
    }

    private func componentCard(_ item: GearItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                GearArtView(item: item)
                    .frame(width: 40, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(RigTheme.textPrimary)
                    Text(item.category.displayName)
                        .font(.caption)
                        .foregroundStyle(RigTheme.textMuted)
                }
                Spacer()
            }

            ForEach(item.parameters) { param in
                HStack(spacing: 12) {
                    Text(param.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(RigTheme.textPrimary)
                        .frame(width: 92, alignment: .leading)

                    TapSlider(value: store.binding(itemId: item.id, param: param.name),
                              in: param.min...param.max)

                    Text(String(format: "%.1f", store.item(item.id)?.values[param.name] ?? 0))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(RigTheme.textMuted)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(RigTheme.backgroundLift)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

#Preview {
    ControlBoardView()
        .environmentObject(RigStore.preview)
        .background(RigTheme.background)
        .preferredColorScheme(.dark)
}
