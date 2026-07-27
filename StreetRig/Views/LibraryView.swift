//
//  LibraryView.swift
//  StreetRig
//
//  The gear library, laid out with a left Gear / Amp / Pedal tab rail, a
//  search field, and the device bar along the bottom. The Amp tab leads with
//  two big choices — Amp + Cabinet vs Combo Amp — then lists that type's
//  models. Tapping a tile adds it to the collection (owned shows a check).
//  Opened full-screen from the "+" in the collection tab; Back returns.
//

import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var store: RigStore
    var onClose: () -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case gear = "Gear", amp = "Amp", pedal = "Pedal"
        var id: String { rawValue }
    }
    enum AmpMode { case stack, combo }

    @State private var tab: Tab = .gear
    @State private var ampMode: AmpMode = .stack
    @State private var query = ""

    private let allOrder: [GearCategory] = [
        .amp, .cabinet, .comboAmp,
        .tuner, .wah, .compressor, .overdrive, .eq, .noiseGate,
        .modulation, .pitch, .delay, .reverb, .volume, .looper
    ]
    private let pedalOrder: [GearCategory] = [
        .tuner, .wah, .compressor, .overdrive, .eq, .noiseGate,
        .modulation, .pitch, .delay, .reverb, .volume, .looper
    ]
    private let columns = [GridItem(.adaptive(minimum: 148, maximum: 210), spacing: 14)]

    var body: some View {
        ZStack {
            RigTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                HStack(spacing: 0) {
                    tabRail
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                DeviceBarView()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 16) {
            Button(action: onClose) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(RigTheme.amber)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(RigTheme.textMuted)
                TextField("Search gear", text: $query)
                    .textFieldStyle(.plain)
                    .foregroundStyle(RigTheme.textPrimary)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(RigTheme.textMuted)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(RigTheme.backgroundLift))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            .frame(maxWidth: 420)

            Spacer(minLength: 0)

            Text("GEAR LIBRARY")
                .font(.caption.weight(.bold))
                .tracking(1.5)
                .foregroundStyle(RigTheme.textMuted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(RigTheme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
    }

    // MARK: - Left tab rail

    private var tabRail: some View {
        VStack(spacing: 6) {
            ForEach(Tab.allCases) { t in
                Button { withAnimation(.easeInOut(duration: 0.15)) { tab = t } } label: {
                    Text(t.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tab == t ? RigTheme.amber : RigTheme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(tab == t ? RigTheme.backgroundLift : Color.clear)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(RigTheme.amber).frame(width: 3).opacity(tab == t ? 1 : 0)
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.top, 12)
        .frame(width: 120)
        .background(RigTheme.background.opacity(0.5))
        .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1) }
    }

    // MARK: - Content per tab

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .gear:
            ScrollView { gearSections(allOrder).padding(20) }
        case .pedal:
            ScrollView { gearSections(pedalOrder).padding(20) }
        case .amp:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 16) {
                        ampModeCard(.stack, title: "Amp + Cabinet")
                        ampModeCard(.combo, title: "Combo Amp")
                    }
                    gearSections(ampMode == .stack ? [.amp, .cabinet] : [.comboAmp])
                }
                .padding(20)
            }
        }
    }

    @ViewBuilder
    private func gearSections(_ categories: [GearCategory]) -> some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(categories, id: \.self) { category in
                let items = catalog(for: category)
                if !items.isEmpty {
                    Text(sectionTitle(category))
                        .font(.caption.weight(.bold)).tracking(1.2)
                        .foregroundStyle(RigTheme.trim)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(items) { LibraryTile(item: $0) }
                    }
                }
            }
            if categories.allSatisfy({ catalog(for: $0).isEmpty }) {
                Text(query.isEmpty ? "Nothing here yet" : "No gear matches “\(query)”")
                    .font(.callout)
                    .foregroundStyle(RigTheme.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
        }
    }

    private func ampModeCard(_ mode: AmpMode, title: String) -> some View {
        let selected = ampMode == mode
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { ampMode = mode }
        } label: {
            VStack(spacing: 12) {
                Group {
                    if mode == .stack {
                        VStack(spacing: 4) {
                            GearArtView(item: GearItem(name: "", category: .amp)).frame(width: 88, height: 32)
                            GearArtView(item: GearItem(name: "", category: .cabinet)).frame(width: 102, height: 62)
                        }
                    } else {
                        GearArtView(item: GearItem(name: "", category: .comboAmp)).frame(width: 112, height: 90)
                    }
                }
                .frame(height: 104)
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(RigTheme.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(RigTheme.backgroundLift))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(selected ? RigTheme.amber : Color.white.opacity(0.08), lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func catalog(for category: GearCategory) -> [GearItem] {
        RigStore.catalog.filter { $0.category == category && matches($0) }
    }

    private func matches(_ item: GearItem) -> Bool {
        query.isEmpty
            || item.name.localizedCaseInsensitiveContains(query)
            || item.category.displayName.localizedCaseInsensitiveContains(query)
    }

    private func sectionTitle(_ category: GearCategory) -> String {
        switch category {
        case .amp: return "AMP HEADS"
        case .cabinet: return "CABINETS"
        case .comboAmp: return "COMBO AMPS"
        default: return category.displayName.uppercased()
        }
    }
}

private struct LibraryTile: View {
    @EnvironmentObject var store: RigStore
    let item: GearItem

    private var artSize: CGSize {
        switch item.category {
        case .amp:      return CGSize(width: 84, height: 56)
        case .cabinet:  return CGSize(width: 66, height: 60)
        case .comboAmp: return CGSize(width: 70, height: 58)
        case .wah:      return CGSize(width: 72, height: 56)
        default:        return CGSize(width: 44, height: 62)
        }
    }

    var body: some View {
        let owned = store.isOwned(item)
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { store.addToCollection(item) }
        } label: {
            VStack(spacing: 10) {
                GearArtView(item: item)
                    .frame(width: artSize.width, height: artSize.height)
                    .frame(height: 64)
                Text(item.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(RigTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
                    .frame(height: 32)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(RigTheme.backgroundLift))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(owned ? RigTheme.amber.opacity(0.5) : Color.white.opacity(0.06), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                Image(systemName: owned ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(owned ? RigTheme.amber : RigTheme.textMuted)
                    .padding(8)
            }
        }
        .buttonStyle(.plain)
        .disabled(owned)
        .opacity(owned ? 0.72 : 1)
    }
}

#Preview {
    LibraryView(onClose: {})
        .environmentObject(RigStore.preview)
        .preferredColorScheme(.dark)
}
