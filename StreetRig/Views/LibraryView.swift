//
//  LibraryView.swift
//  StreetRig
//
//  The gear-library page content (the left swipe page in the app shell). Two
//  tabs, Amp and Pedal, each showing category cards; tapping a card opens a
//  drill-down page listing that category's models (Back returns). Amp offers
//  Amp + Cabinet vs Combo Amp; Pedal shows one card per pedal category.
//  Tapping a model tile adds it to the collection (owned shows a check).
//

import SwiftUI

struct LibraryContentView: View {
    @EnvironmentObject var store: RigStore

    enum Section: Hashable { case amp, pedal }
    enum Drill: Hashable { case ampStack, ampCombo, pedal(GearCategory) }

    @State private var section: Section = .amp
    @State private var drill: Drill?
    @State private var query = ""

    private let pedalOrder: [GearCategory] = [
        .tuner, .wah, .compressor, .overdrive, .eq, .noiseGate,
        .modulation, .pitch, .delay, .reverb, .volume, .looper
    ]
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            if let drill {
                drillHeader(drill)
                ScrollView {
                    modelGrid(categories(for: drill), showHeaders: drill == .ampStack)
                        .padding(20)
                }
            } else {
                header
                ScrollView {
                    if query.isEmpty {
                        cards.padding(20)
                    } else {
                        modelGrid(section == .amp ? [.amp, .cabinet, .comboAmp] : pedalOrder,
                                  showHeaders: true)
                            .padding(20)
                    }
                }
            }
        }
    }

    // MARK: - Card level

    private var header: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                segTab("Amp", .amp)
                segTab("Pedal", .pedal)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(RigTheme.backgroundLift))

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
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(RigTheme.backgroundLift))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            .frame(maxWidth: 360)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func segTab(_ title: String, _ value: Section) -> some View {
        let selected = section == value
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { section = value }
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? .black : RigTheme.textMuted)
                .padding(.horizontal, 20)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selected ? RigTheme.amber : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var cards: some View {
        switch section {
        case .amp:
            HStack(spacing: 16) {
                ampCard(.ampStack, title: "Amp + Cabinet", stack: true)
                ampCard(.ampCombo, title: "Combo Amp", stack: false)
            }
        case .pedal:
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(pedalOrder, id: \.self) { pedalCategoryCard($0) }
            }
        }
    }

    private func ampCard(_ target: Drill, title: String, stack: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { drill = target }
        } label: {
            VStack(spacing: 12) {
                Group {
                    if stack {
                        VStack(spacing: 4) {
                            GearArtView(item: GearItem(name: "", category: .amp)).frame(width: 88, height: 32)
                            GearArtView(item: GearItem(name: "", category: .cabinet)).frame(width: 102, height: 62)
                        }
                    } else {
                        GearArtView(item: GearItem(name: "", category: .comboAmp)).frame(width: 112, height: 90)
                    }
                }
                .frame(height: 104)
                Text(title).font(.headline.weight(.semibold)).foregroundStyle(RigTheme.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(RigTheme.backgroundLift))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(RigTheme.textMuted).padding(12)
            }
        }
        .buttonStyle(.plain)
    }

    private func pedalCategoryCard(_ category: GearCategory) -> some View {
        let representative = RigStore.catalog.first { $0.category == category }
        let count = RigStore.catalog.filter { $0.category == category }.count
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { drill = .pedal(category) }
        } label: {
            VStack(spacing: 10) {
                GearArtView(item: representative)
                    .frame(width: 44, height: 60)
                    .frame(height: 62)
                Text(category.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RigTheme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("\(count) model\(count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(RigTheme.textMuted)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(RigTheme.backgroundLift))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(RigTheme.textMuted).padding(8)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Drill-down level

    private func drillHeader(_ drill: Drill) -> some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { self.drill = nil }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(RigTheme.amber)
            }
            Spacer()
            Text(drillTitle(drill))
                .font(.headline.weight(.bold))
                .foregroundStyle(RigTheme.textPrimary)
            Spacer()
            Color.clear.frame(width: 64, height: 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }

    private func categories(for drill: Drill) -> [GearCategory] {
        switch drill {
        case .ampStack: return [.amp, .cabinet]
        case .ampCombo: return [.comboAmp]
        case .pedal(let category): return [category]
        }
    }

    private func drillTitle(_ drill: Drill) -> String {
        switch drill {
        case .ampStack: return "Amp + Cabinet"
        case .ampCombo: return "Combo Amp"
        case .pedal(let category): return category.displayName
        }
    }

    // MARK: - Shared

    @ViewBuilder
    private func modelGrid(_ categories: [GearCategory], showHeaders: Bool) -> some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(categories, id: \.self) { category in
                let items = catalog(for: category)
                if !items.isEmpty {
                    if showHeaders {
                        Text(sectionTitle(category))
                            .font(.caption.weight(.bold)).tracking(1.2)
                            .foregroundStyle(RigTheme.trim)
                    }
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
        .draggable(item) {
            GearArtView(item: item)
                .frame(width: 64, height: 64)
                .padding(8)
        }
        .disabled(owned)
        .opacity(owned ? 0.72 : 1)
    }
}

#Preview {
    LibraryContentView()
        .environmentObject(RigStore.preview)
        .background(RigTheme.background)
        .preferredColorScheme(.dark)
}
