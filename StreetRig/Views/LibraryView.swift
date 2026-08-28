//
//  LibraryView.swift
//  StreetRig
//
//  The gear-library page content (the left swipe page in the app shell). Two
//  tabs, Amp and Pedal, each showing category cards; tapping a card opens a
//  drill-down page listing that category's models (Back returns). Amp offers
//  Amp + Cabinet vs Combo Amp; Pedal shows one card per pedal category.
//  Tapping a model tile adds it to the collection; an owned tile's badge
//  removes it again (see LibraryTile for why the badge, and not the tile).
//

import SwiftUI
import StreetRigEngine

struct LibraryContentView: View {
    @EnvironmentObject var store: RigStore

    enum Section: Hashable { case amp, pedal }
    enum Drill: Hashable { case ampStack, ampCombo, pedal(GearCategory) }

    /// An external request to open at a particular place — the rig's no-amp warning
    /// sending the player straight to the amps. Cleared the moment it is honoured,
    /// so the same request can be made again after they wander off.
    var openAt: Binding<Drill?> = .constant(nil)

    @State private var section: Section = .amp
    @State private var drill: Drill?
    @State private var query = ""
    /// Hoisted out of the tiles: a removal confirmation must outlive the tile
    /// that asked for it, which re-renders (owned → unowned) the moment the
    /// player answers Remove.
    @State private var pendingRemoval: PendingGearRemoval?

    /// The pedal categories worth showing: those with at least one model still
    /// in the library. Withholding every model in a category (tuner, looper)
    /// would otherwise leave a "0 models" card that drills into an empty list.
    private var stockedPedalOrder: [GearCategory] {
        pedalOrder.filter { category in RigStore.catalog.contains { $0.category == category } }
    }

    private let pedalOrder: [GearCategory] = [
        .tuner, .wah, .compressor, .overdrive, .eq, .noiseGate,
        .modulation, .pitch, .delay, .reverb, .volume, .looper
    ]
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 14)]

    var body: some View {
        content
            .onChange(of: openAt.wrappedValue) { _, requested in honour(requested) }
            .onAppear { honour(openAt.wrappedValue) }
    }

    /// Jump to a requested destination, putting the matching tab behind it so
    /// Back lands somewhere that makes sense rather than on the other section.
    private func honour(_ requested: Drill?) {
        guard let requested else { return }
        query = ""
        switch requested {
        case .ampStack, .ampCombo: section = .amp
        case .pedal:               section = .pedal
        }
        drill = requested
        openAt.wrappedValue = nil
    }

    private var content: some View {
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
                        cards.padding(.horizontal, 20)
                            .padding(.top, 15)
                            .padding(.bottom, 20)
                    } else {
                        modelGrid(section == .amp ? [.amp, .cabinet, .comboAmp] : stockedPedalOrder,
                                  showHeaders: true)
                            .padding(.horizontal, 20)
                            .padding(.top, 15)
                            .padding(.bottom, 20)
                    }
                }
            }
        }
        // Same dialog, same copy as the MY GEAR rail's trash — one definition.
        .gearRemovalConfirmation($pendingRemoval, store: store)
    }

    // MARK: - Card level

    private var header: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                segTab("Amp", .amp)
                segTab("Pedal", .pedal)
            }
            .padding(4)
            .background {
                RoundedRectangle(cornerRadius: RigTheme.Radius.tight, style: .continuous)
                    .fill(RigTheme.well)
                    .overlay {
                        RoundedRectangle(cornerRadius: RigTheme.Radius.tight, style: .continuous)
                            .strokeBorder(RigTheme.surfaceEdge, lineWidth: 1)
                    }
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
            .padding(.vertical, 8)
            // A search field is a recess, so it takes `well` and not the RAISED rung
            // it had — a control you type into should not look like it sits proud of
            // the page.
            .background {
                RoundedRectangle(cornerRadius: RigTheme.Radius.tight, style: .continuous)
                    .fill(RigTheme.well)
                    .overlay {
                        RoundedRectangle(cornerRadius: RigTheme.Radius.tight, style: .continuous)
                            .strokeBorder(RigTheme.surfaceEdge, lineWidth: 1)
                    }
            }
            .frame(maxWidth: 360)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 9)
    }

    private func segTab(_ title: String, _ value: Section) -> some View {
        let selected = section == value
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { section = value }
        } label: {
            // The selected tab is a RAISED THUMB, not an amber fill.
            //
            // A segmented control is a switch: the thumb is the physical thing that
            // moved, and on hardware it is the same material as the panel, lifted.
            // Filling it with the accent made the picker the loudest object on the
            // page and spent the one colour that is supposed to mean "this action" on
            // a state that means "you are looking at amps".
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? RigTheme.textPrimary : RigTheme.textMuted)
                .padding(.horizontal, 20)
                .padding(.vertical, 7)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: RigTheme.Radius.tight, style: .continuous)
                            .fill(RigTheme.surfaceRaised)
                            .overlay {
                                RoundedRectangle(cornerRadius: RigTheme.Radius.tight, style: .continuous)
                                    .strokeBorder(RigTheme.surfaceEdge, lineWidth: 1)
                            }
                    }
                }
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
                ForEach(stockedPedalOrder, id: \.self) { pedalCategoryCard($0) }
            }
        }
    }

    /// The piece a category card puts in its window: the first one in the
    /// catalog that has real art, falling back to the first of its kind.
    ///
    /// WHY THIS EXISTS. The two amp cards used to be drawn from
    /// `GearItem(name: "", category: .amp)` — a NAMELESS piece, which is
    /// precisely the one input `GearIconLoader` can never resolve, since it
    /// matches a piece to its asset by slugging the display NAME. So those two
    /// always fell through to the generic hand-drawn outline, and the front page
    /// of the library — a shop window — was the one screen showing diagrams
    /// while every card one tap behind it showed the real thing.
    ///
    /// Asking the catalog rather than naming a slug here keeps this honest
    /// through a re-badge: the models have been renamed once already (Marshall →
    /// Marswell, Orange → Tangerine), and a hardcoded "marswell-jcm800-2203"
    /// would have rotted silently into the generic outline it replaced. The
    /// `image(for:)` check is what stops it picking a piece whose art has not
    /// been drawn yet and quietly regressing to the same diagram.
    private static func representative(_ category: GearCategory) -> GearItem? {
        let ofKind = RigStore.catalog.filter { $0.category == category }
        return ofKind.first { GearIconLoader.image(for: $0) != nil } ?? ofKind.first
    }

    private func ampCard(_ target: Drill, title: String, stack: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { drill = target }
        } label: {
            VStack(spacing: 12) {
                Group {
                    if stack {
                        // A HEAD SITS ON ITS CAB. Two things were wrong here.
                        //
                        // `GearArtView` aspect-FITS, so a frame is a bounding box and
                        // not a size. The cab's art is 0.87:1, so a 102×62 box drew it
                        // 54 wide; the head's is 2.05:1, so an 88×32 box drew it 66
                        // wide. The cabinet came out NARROWER than the head sitting on
                        // it — a half stack upside down. These frames match the art's
                        // own aspects, so what is asked for is what is drawn.
                        //
                        // And `spacing: 4` floated the head above the cab. A head does
                        // not hover; the whole read of a half stack is that the two are
                        // one object.
                        VStack(spacing: 0) {
                            GearArtView(item: Self.representative(.amp)).frame(width: 45, height: 22)
                            GearArtView(item: Self.representative(.cabinet)).frame(width: 57, height: 66)
                        }
                    } else {
                        GearArtView(item: Self.representative(.comboAmp)).frame(width: 112, height: 90)
                    }
                }
                .frame(height: 104)
                Text(title).font(.headline.weight(.semibold)).foregroundStyle(RigTheme.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(18)
            .rigCard(cornerRadius: RigTheme.Radius.control)
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
            .rigCard(cornerRadius: RigTheme.Radius.control)
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
                .foregroundStyle(RigTheme.amberChrome)
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
                            .rigLegend(12, weight: .bold)
                            .foregroundStyle(RigTheme.trim)
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(items) { LibraryTile(item: $0, pendingRemoval: $pendingRemoval) }
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

/// One catalog model in the grid. Unowned → the whole tile adds it. Owned → the
/// tile body does NOTHING and only the corner badge removes it.
///
/// Why the badge and not a whole-tile toggle or a context menu: this grid is a
/// BROWSE surface that players scroll and tap through quickly, so a single tap
/// must never be able to delete gear they are using — a tap-to-toggle tile makes
/// every mis-tap on an owned model a silent deletion. A context menu is safe but
/// invisible: nothing on the tile says "long-press me", so the removal would
/// effectively not exist. A small, separately-aimed control in the corner is
/// both visible and deliberate. It also replaces the old dead `checkmark.circle`
/// — a checkmark that deletes when tapped would be a lie about what it does; the
/// amber ring and the dimmed art still carry "you own this".
private struct LibraryTile: View {
    @EnvironmentObject var store: RigStore
    let item: GearItem
    @Binding var pendingRemoval: PendingGearRemoval?

    /// The tile's own frames, a size up from `GearCategory.artSize` because a
    /// library tile is roomier than a rail card. Shaped to the shipped art's
    /// measured aspects (head ≈ 2.05:1, cabinet ≈ 0.87:1, combo ≈ 1.13:1) so the
    /// aspect-fit icon fills the frame instead of floating between letterbox
    /// bars; the art sits inside a fixed 64pt-tall box below, so the grid's row
    /// height doesn't move when these change.
    /// The art's drawn size, per category, shaped to the shipped artwork's measured
    /// aspects (head ≈ 2.05:1, cabinet ≈ 0.87:1, combo ≈ 1.13:1, wah ≈ 1.29:1,
    /// compact pedal ≈ 0.71:1) so an aspect-fit icon FILLS its box instead of
    /// floating between letterbox bars.
    ///
    /// These are per-category for a reason this card learned the hard way: it first
    /// shipped forcing every piece into one 34×46 box. That is about right for a
    /// compact pedal and catastrophic for an amp head, which is twice as wide as it
    /// is tall — heads came out tiny and adrift in the corner of their frame. A
    /// single box cannot serve a 2.05:1 head and a 0.71:1 stompbox.
    ///
    /// The widths differ but the BOX below is constant, so the name column starts at
    /// the same x on every card in the grid.
    private var artSize: CGSize {
        switch item.category {
        case .amp:      return CGSize(width: 46, height: 22)
        case .cabinet:  return CGSize(width: 30, height: 35)
        case .comboAmp: return CGSize(width: 38, height: 34)
        case .wah:      return CGSize(width: 40, height: 31)
        default:        return CGSize(width: 30, height: 42)
        }
    }

    var body: some View {
        let owned = store.isOwned(item)
        Group {
            if owned {
                // No whole-tile action at all when owned — see the note above.
                tileFace(owned: true)
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { store.addToCollection(item) }
                } label: {
                    tileFace(owned: false)
                }
                .buttonStyle(.plain)
                .draggable(item) {
                    GearArtView(item: item)
                        .frame(width: 64, height: 64)
                        .padding(8)
                }
            }
        }
        .overlay(alignment: .topTrailing) { badge(owned: owned) }
    }

    /// `DRIVE · TONE · LEVEL`. Capped at three so a wah's single control and a
    /// ten-band EQ both fit one line on the same card.
    private var controlSet: String {
        item.parameters.prefix(3).map { $0.name.uppercased() }.joined(separator: " · ")
    }

    /// The tile face: artwork LEFT, identity RIGHT, then what the piece sounds like,
    /// then what it gives you to turn.
    ///
    /// It used to be a centred column — art on top, name under it, nothing else. That
    /// is a fine shape for a rail card 150pt wide, and the wrong one here: a library
    /// tile is roomy, and the room was going to whitespace while the player still had
    /// to open four overdrives to tell them apart. Horizontal puts the art and the
    /// name on one line and frees the height for the two rows that actually decide a
    /// choice.
    ///
    /// The foot rule is a hairline rather than a gap because it separates the
    /// SPECIFICATION from the description, the way a spec sheet does.
    private func tileFace(owned: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                // The art is drawn at its own aspect and then CENTRED in a constant
                // 56×46 box, so heads, cabs and stompboxes all start their name
                // column at the same x. Sizing the box instead of the art is what
                // squashed heads before.
                GearArtView(item: item)
                    .frame(width: artSize.width, height: artSize.height)
                    .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(RigTheme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(item.category.displayName.uppercased())
                        .rigLegend(7.5, weight: .bold)
                        .foregroundStyle(RigTheme.trim.opacity(0.9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                }
                // Room for the badge, which floats in the top-trailing corner.
                .padding(.trailing, 16)

                Spacer(minLength: 0)
            }

            if let character = GearCharacter.line(forName: item.name, category: item.category) {
                Text(character)
                    .font(.system(size: 11))
                    .foregroundStyle(RigTheme.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !controlSet.isEmpty {
                Rectangle()
                    .fill(RigTheme.hairline.opacity(0.55))
                    .frame(height: 1)
                    .padding(.top, 1)
                Text(controlSet)
                    .rigLegend(7.5, weight: .semibold)
                    .foregroundStyle(RigTheme.textMuted.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The stroke is drawn separately, BELOW, so the scrim can pass between the
        // card and its edge: the tile goes dark, the amber edge saying why does not.
        .rigCard(cornerRadius: RigTheme.Radius.control, stroke: .clear)
        // Gear you already own sits in shadow — the whole tile, fill included, not
        // just its contents. Scanning for what you have yet to add is the main thing
        // this page gets used for, and a tile that has visibly gone dark answers
        // that across the grid, where a hairline border and a badge have to be
        // looked at one at a time. In the page's own background colour rather than
        // black, so an owned tile recedes toward the page instead of turning grey
        // on a warm espresso ground.
        .overlay {
            if owned {
                RoundedRectangle(cornerRadius: RigTheme.Radius.control, style: .continuous)
                    .fill(RigTheme.background.opacity(0.58))
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: RigTheme.Radius.control, style: .continuous)
                .strokeBorder(owned ? RigTheme.amberChrome.opacity(0.6) : RigTheme.surfaceEdge, lineWidth: 1)
        }
    }

    @ViewBuilder
    /// A small square, not a filled SF circle.
    ///
    /// Owned reads as an OUTLINE and unowned as a FILL, which is the right way round:
    /// adding is the action this page exists for, so it gets the solid one, while
    /// removing is a thing you should have to aim at. The circle glyphs it replaced
    /// were `plus.circle.fill` in muted grey and `minus.circle.fill` in `clip` red —
    /// the destructive red shouting on every piece the player already owns, which is
    /// most of the grid once they have been using the app a while.
    private func badge(owned: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: RigTheme.Radius.tight, style: .continuous)
        return Group {
            if owned {
                Button { remove() } label: {
                    Text("−")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(RigTheme.amberChrome)
                        .frame(width: 18, height: 18)
                        .background { shape.strokeBorder(RigTheme.amberChrome.opacity(0.75), lineWidth: 1) }
                        .padding(7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(item.name) from your gear")
            } else {
                Text("+")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Color(red: 0.086, green: 0.047, blue: 0.016))
                    .frame(width: 18, height: 18)
                    .background { shape.fill(RigTheme.amberChrome) }
                    .padding(7)
                    .allowsHitTesting(false)   // the whole tile is the add target
            }
        }
    }

    /// The catalog carries throwaway ids, so "owned" has to be resolved back to
    /// the real instance before anything is deleted — otherwise this would ask
    /// the store to remove an id it has never seen and silently do nothing.
    private func remove() {
        guard let ownedItem = store.ownedInstance(of: item) else { return }
        switch GearRemoval.request(ownedItem.id, store: store) {
        case .removed, .rejected:              break   // the library holds no guitars
        case .needsConfirmation(let pending):  pendingRemoval = pending
        }
    }
}

#Preview {
    LibraryContentView()
        .environmentObject(RigStore.preview)
        .background(RigTheme.background)
        .preferredColorScheme(.dark)
}
