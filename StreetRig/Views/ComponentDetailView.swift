//
//  ComponentDetailView.swift
//  StreetRig
//
//  The zoomed-in view a component locks into when tapped. The component fills
//  the top as a large control panel focused on its row of knobs — the knobs
//  are turnable (vertical drag) — and a dock of `TapSlider`s stays at the bottom,
//  each set by touching the track where you want the value, no thumb-hunting.
//  The knobs stay drag-only on purpose: mapping a tap onto a rotary angle would
//  slam a touch near the knob's edge to an extreme. Knobs and sliders are bound
//  to the same values, so either one moves both, and the amber number beside a
//  slider opens a keypad for an exact figure.
//

import SwiftUI
import StreetRigEngine

struct ComponentDetailView: View {
    @EnvironmentObject var store: RigStore
    let component: RigComponent
    var onClose: () -> Void

    /// The value currently being typed into the keypad (nil = keypad closed).
    @State private var editing: KeypadEdit?

    /// Which page the lower pane is showing. Only amps with an FX section have
    /// more than one; everything else never sees the picker.
    private enum Pane: String, CaseIterable { case levels = "LEVELS", fx = "FX", channels = "CHANNELS" }
    @State private var pane: Pane = .levels

    /// Which parameter's number the keypad is editing.
    struct KeypadEdit: Identifiable {
        let itemId: UUID
        let param: GearParameter
        var id: String { param.name }
    }

    private var item: GearItem? {
        switch component {
        case .guitar: return store.guitar
        case .amp, .combo: return store.ampItem
        case .cabinet: return store.cabinetItem
        case .pedal(let id): return store.item(id)
        }
    }

    private var params: [GearParameter] { item?.parameters ?? [] }

    /// A rotary is for a value that sweeps; a Katana's Character selector has
    /// five detents and its Power switch three, and both live in the same knob
    /// list as Gain and Bass. Splitting the list here — rather than teaching one
    /// control to be two things — keeps the dial panel exactly as it was for the
    /// twelve amps that only have dials, and gives the selectors the segmented
    /// control they actually are.
    /// The MAIN panel is everything with no group. A grouped control belongs to a
    /// named sub-panel instead — the Katana's five FX blocks are one group each —
    /// so the knob row and the switch strip stay exactly as they were for the
    /// twelve amps that have no groups, instead of trying to fit twenty-six
    /// controls across one landscape row.
    private var dials: [GearParameter] { params.filter { !$0.isDiscrete && $0.group == nil } }

    /// THE KNOB PANEL'S ROWS. Panels are faithful to the chassis now and some amps
    /// have a lot of controls — the Friedman has nineteen — so one row is no longer
    /// a safe assumption. Explicit `rowLabel`s win (an amp with two channels reads
    /// as two named rows, which is how the hardware is laid out); otherwise a row
    /// that would squeeze knobs below legibility is split in half. One row is
    /// still preferred and still what most amps get.
    ///
    /// A stray unlabelled dial or two alongside named rows — the Orange's shared
    /// REVERB — joins the first row rather than earning a third.
    private var dialRows: [(label: String?, dials: [GearParameter])] {
        var order: [String] = []
        var byRow: [String: [GearParameter]] = [:]
        var loose: [GearParameter] = []
        for d in dials {
            if let r = d.rowLabel {
                if byRow[r] == nil { order.append(r) }
                byRow[r, default: []].append(d)
            } else { loose.append(d) }
        }
        if !order.isEmpty {
            var rows: [(String?, [GearParameter])] = order.map { ($0, byRow[$0] ?? []) }
            if !loose.isEmpty, loose.count <= 2, var first = rows.first {
                first.1 = loose + first.1
                rows[0] = first
            } else if !loose.isEmpty {
                rows.insert((nil, loose), at: 0)
            }
            return rows.map { (label: $0.0, dials: $0.1) }
        }
        guard loose.count > 7 else { return [(nil, loose)] }
        let half = (loose.count + 1) / 2
        return [(nil, Array(loose.prefix(half))), (nil, Array(loose.dropFirst(half)))]
    }

    /// SMALLER THAN IT WAS, on request: the panel is a picture of an amp face and
    /// the controls under it are what the player actually came for. A row is 56 pt
    /// — a 34 pt knob and its label — against the 132 pt a single row used to take.
    private var knobPanelHeight: CGFloat {
        let rows = max(1, dialRows.count)
        // Every LABELLED row needs its caption's height too. Counting only the
        // knob rows is what clipped "CHANNEL 1" off the top of the Mesa and the
        // Orange: the panel was sized for the dials and the text had nowhere to go.
        let labels = dialRows.filter { $0.label != nil }.count
        return CGFloat(rows) * 56 + CGFloat(labels) * 17 + 14
    }
    private var switches: [GearParameter] { params.filter { $0.isDiscrete && $0.group == nil } }

    /// The grouped controls, in declaration order, one entry per group.
    private var fxGroups: [(name: String, controls: [GearParameter])] {
        var order: [String] = []
        var byName: [String: [GearParameter]] = [:]
        for p in params {
            guard let g = p.group else { continue }
            if byName[g] == nil { order.append(g) }
            byName[g, default: []].append(p)
        }
        return order.map { ($0, byName[$0] ?? []) }
    }

    /// Channel memories are offered for any amp that has an FX section — the
    /// panel is big enough by then that recalling it wholesale is the point.
    private var hasChannels: Bool {
        guard let item, item.category == .amp || item.category == .comboAmp else { return false }
        return ParameterMap.ampHasFXSection(name: item.name)
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.85))
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            // A panel with an FX SECTION is fighting for every point of height —
            // the app is landscape-only, so the whole sheet is ~400 pt tall and
            // the knob row plus the switch strip already claim more than half of
            // it. For those amps only, the fixed furniture is trimmed so the
            // lower pane has room to be usable; every other amp keeps the
            // original proportions exactly.
            let dense = !fxGroups.isEmpty
            VStack(spacing: dense ? 10 : 14) {
                header

                if let id = item?.id, !params.isEmpty {
                    // THE PANEL TAKES WHAT IT NEEDS AND NO MORE, and is capped so
                    // it can never crowd out the dock. A tall panel on a ~400 pt
                    // landscape sheet used to push the sliders — the controls the
                    // player actually drags — off the bottom; the cap plus the
                    // dock's own floor means both are always reachable.
                    knobPanel(id: id)
                        .frame(height: min(knobPanelHeight, dense ? 132 : 178))
                    if !switches.isEmpty { switchPanel(id: id, compact: dense) }
                    sliderDock(id: id)
                        .frame(minHeight: 132, maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        GearArtView(item: item)
                            .frame(width: 220, height: 190)
                        Text("No adjustable controls")
                            .font(.footnote)
                            .foregroundStyle(RigTheme.textMuted)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .padding(.horizontal, dense ? 20 : 28)
            .padding(.vertical, dense ? 10 : 16)

            // Tap a number → this keypad slides in to set it exactly.
            if let edit = editing {
                NumberKeypad(
                    title: edit.param.name,
                    initial: store.item(edit.itemId)?.values[edit.param.name] ?? 0,
                    range: edit.param.min...edit.param.max,
                    onCancel: { editing = nil },
                    onCommit: { newValue in
                        store.binding(itemId: edit.itemId, param: edit.param.name).wrappedValue = newValue
                        editing = nil
                    }
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: editing?.id)
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            HStack {
                Button(action: onClose) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Rig")
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(RigTheme.amber)
                }
                Spacer()
            }
            VStack(spacing: 2) {
                Text(item?.name ?? "—")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(RigTheme.textPrimary)
                Text(item?.category.displayName ?? "")
                    .font(.caption)
                    .foregroundStyle(RigTheme.textMuted)
            }
        }
    }

    // MARK: - Enlarged control panel with turnable knobs

    private func knobPanel(id: UUID) -> some View {
        let panel = GearArtView.panelColor(for: item)
        let light = GearArtView.panelIsLight(for: item)
        let labelColor: Color = light ? .black.opacity(0.72) : .white.opacity(0.88)

        return RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(panel)
            .overlay(
                LinearGradient(colors: [.white.opacity(0.12), .clear, .black.opacity(0.16)],
                               startPoint: .top, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            )
            .overlay(
                GeometryReader { geo in
                    // THE FLOOR IS GONE. A 48 pt minimum meant nineteen knobs ran
                    // off the side of the panel rather than getting smaller; 26 pt
                    // is still a legible dial and the row always fits now. Rows are
                    // sized from the widest one so every knob on the panel matches.
                    let widest = CGFloat(max(1, dialRows.map(\.dials.count).max() ?? 1))
                    let rowH = (geo.size.height - 10) / CGFloat(max(1, dialRows.count))
                    let knob = max(26, min(rowH - 20, (geo.size.width - 28) / widest - 8))
                    VStack(spacing: 4) {
                        ForEach(Array(dialRows.enumerated()), id: \.offset) { _, row in
                            if let label = row.label {
                                // Centred across the panel and readable at arm's
                                // length — it names the row of knobs under it, so
                                // it has to carry as much as they do.
                                Text(label)
                                    .font(.system(size: 12, weight: .bold)).tracking(1.6)
                                    .foregroundStyle(labelColor.opacity(0.85))
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.top, 1)
                            }
                            knobRow(id: id, row.dials, knob: knob,
                                    light: light, labelColor: labelColor)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
    }

    /// One row of the knob panel.
    private func knobRow(id: UUID, _ row: [GearParameter], knob: CGFloat,
                         light: Bool, labelColor: Color) -> some View {
        HStack(spacing: 6) {
            ForEach(row) { param in
                            VStack(spacing: 5) {
                                InteractiveKnob(
                                    value: store.binding(itemId: id, param: param.name),
                                    range: param.min...param.max,
                                    onLight: light
                                )
                                .frame(width: knob, height: knob)
                                // The shade sits ON THE KNOB, and is round like it
                                // is. It used to cover the whole cell — knob, label
                                // and the empty width either side — which drew a
                                // grey slab across the panel instead of reading as
                                // one dial being out of service.
                                .overlay {
                                    if param.isDisabled {
                                        Circle()
                                            .fill(.black.opacity(0.5))
                                            .blendMode(.multiply)
                                            .allowsHitTesting(false)
                                    }
                                }
                                Text(param.displayName)
                                    .font(.system(size: knob < 40 ? 8 : 11, weight: .medium))
                                    .foregroundStyle(labelColor)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                            }
                            .frame(maxWidth: .infinity)
                            // A control the AMP has and this build cannot drive:
                            // drawn so the panel stays a true picture of the
                            // chassis, dimmed and dead to the touch so it reads as
                            // "not yet" rather than as a knob that lies. The shade
                            // itself is on the knob above; this only fades the pair.
                            .opacity(param.isDisabled ? 0.45 : 1)
                            .allowsHitTesting(!param.isDisabled)
            }
        }
    }

    // MARK: - Discrete selectors (character / variation / power switches)

    /// The panel's switches. These are NOT 0–10 dials: each stored value is an
    /// index into the parameter's `options`, so the control shows the detents and
    /// writes an integer. It goes through the SAME `store.binding(itemId:param:)`
    /// every knob uses, so a character change lands on the rig compiler exactly
    /// like a knob turn — and is then routed structurally or continuously by the
    /// compiler, which is the only place that decision belongs.
    private func switchPanel(id: UUID, compact: Bool = false) -> some View {
        // The selectors sit SIDE BY SIDE in one strip, not stacked. The app is
        // landscape-only, so vertical space is the scarce axis — three stacked
        // rows ate the slider dock below them. Each group is width-weighted by
        // how many detents it has, so a five-position Character and a two-position
        // Variation both get room without either looking stretched.
        // Width is shared BY DETENT COUNT, not equally and not by layout priority
        // — five Character positions and two Variation positions need different
        // amounts of room, and every button should still come out the same size.
        let counts = switches.map { CGFloat($0.options?.count ?? 1) }
        let total = max(1, counts.reduce(0, +))
        return GeometryReader { geo in
            let gaps = CGFloat(max(0, switches.count - 1)) * 16
            let unit = max(0, geo.size.width - gaps) / total
            HStack(alignment: .top, spacing: 16) {
                ForEach(Array(switches.enumerated()), id: \.element.id) { i, param in
                    let binding = store.binding(itemId: id, param: param.name)
                    let options = param.options ?? []
                    let selected = Int(binding.wrappedValue.rounded())
                    VStack(alignment: .leading, spacing: 6) {
                        Text(param.name.uppercased())
                            .font(.caption2.weight(.bold)).tracking(1.2)
                            .foregroundStyle(RigTheme.textMuted)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            ForEach(Array(options.enumerated()), id: \.offset) { index, label in
                                let isOn = (index == selected)
                                Button {
                                    binding.wrappedValue = Double(index)
                                } label: {
                                    Text(label)
                                        .font(.caption.weight(isOn ? .bold : .medium))
                                        .foregroundStyle(isOn ? .black : RigTheme.textPrimary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.6)
                                        .padding(.horizontal, 4)
                                        .frame(maxWidth: .infinity, minHeight: 30)
                                        .background {
                                            if isOn {
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .fill(RigTheme.amber)
                                            } else {
                                                Color.clear.rigRaised(cornerRadius: 8)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(width: unit * counts[i])
                }
            }
        }
        .frame(height: compact ? 42 : 52)
        .padding(compact ? 8 : 14)
        .rigCard(cornerRadius: 16)
    }

    // MARK: - Slider dock (bottom), aligned under the knobs

    /// The lower pane. For an ordinary amp or pedal it is exactly what it always
    /// was — a scrolling column of sliders. For an amp with an FX section it
    /// gains a PAGE PICKER, because the alternative does not fit: the app is
    /// landscape-only, so the whole panel has ~400 pt of height, of which the
    /// knob row and the switch strip already take more than half. Stacking a
    /// Katana's twenty-six controls into one scrolling column left a ~70 pt
    /// window to hunt through them in. Paging spends the axis that IS abundant —
    /// the FX page scrolls sideways, one card per block.
    private func sliderDock(id: UUID) -> some View {
        VStack(spacing: 8) {
            if !fxGroups.isEmpty { panePicker }
            switch (fxGroups.isEmpty || !panes.contains(pane) ? .levels : pane) {
            case .levels:
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(dials) { param in
                            dialRow(id: id, param: param, labelWidth: 92)
                        }
                    }
                    .padding(.vertical, 4)
                }
            case .fx:
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(fxGroups, id: \.name) { group in
                            fxBlockCard(id: id, name: group.name, controls: group.controls)
                                .frame(width: 178)
                        }
                    }
                    .padding(.vertical, 2)
                }
            case .channels:
                channelStrip(id: id)
            }
        }
        .padding(14)
        .rigCard(cornerRadius: 18)
    }

    /// The pages this item actually has. Channel memories are offered only to an
    /// amp that has an FX section — the panel is big enough by then that
    /// recalling it wholesale is the point — so a future grouped control on some
    /// other kind of gear does not silently gain a channel strip it cannot fill.
    private var panes: [Pane] { hasChannels ? Pane.allCases : [.levels, .fx] }

    private var panePicker: some View {
        HStack(spacing: 5) {
            ForEach(panes, id: \.self) { p in
                let isOn = (p == pane)
                Button { pane = p } label: {
                    Text(p.rawValue)
                        .font(.caption2.weight(isOn ? .bold : .medium)).tracking(0.8)
                        .foregroundStyle(isOn ? .black : RigTheme.textMuted)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(RigTheme.amber)
                            } else {
                                Color.clear.rigRaised(cornerRadius: 6)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// One "label — slider — number" row, shared by the main dock and the FX
    /// blocks so a block's Level behaves exactly like Gain does.
    private func dialRow(id: UUID, param: GearParameter, labelWidth: CGFloat) -> some View {
        HStack(spacing: 12) {
            Text(param.displayName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(RigTheme.textPrimary)
                .frame(width: labelWidth, alignment: .leading)
            TapSlider(value: store.binding(itemId: id, param: param.name),
                      in: param.min...param.max)
            // Tap the number to type an exact value on the keypad.
            Button {
                editing = KeypadEdit(itemId: id, param: param)
            } label: {
                Text(String(format: "%.1f", store.item(id)?.values[param.name] ?? 0))
                    .font(.footnote.monospacedDigit().weight(.semibold))
                    .foregroundStyle(RigTheme.amber)
                    .frame(width: 42, alignment: .trailing)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(RigTheme.amber.opacity(0.14))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - The amp's FX section (one card per block)

    /// One effect block: its type selector, its on/off and its own dial(s).
    ///
    /// Both switches go through the SAME `store.binding(itemId:param:)` every
    /// knob uses, so the compiler decides what each one costs — and it decides
    /// differently on purpose. Choosing a TYPE is structural (the block gains or
    /// loses a chain slot, and the slot has to be voiced), while the On switch is
    /// continuous: it rides the per-slot enable, the same lock-free path an AR
    /// footswitch stomp takes, so stomping a block never rebuilds the chain.
    private func fxBlockCard(id: UUID, name: String, controls: [GearParameter]) -> some View {
        let typeParam = controls.first { $0.name == name }
        let onParam = controls.first { $0.name == "\(name) On" }
        let dialsInBlock = controls.filter { !$0.isDiscrete }
        let isOff = Int((store.item(id)?.values[name] ?? 0).rounded()) == ParameterMap.ampFXOff

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(name.uppercased())
                    .font(.caption2.weight(.bold)).tracking(1.2)
                    .foregroundStyle(isOff ? RigTheme.textMuted : RigTheme.amber)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let onParam, !isOff {
                    // BIGGER, on request. This is the control a player reaches for
                    // mid-song — the one that stomps a block in and out — and it was
                    // a 74 pt pair of 24 pt-high chips competing with a type cycler
                    // nobody touches while playing. 104 × 34 is a real target for a
                    // finger on a phone that is ON THE FLOOR, which is where this
                    // app is used and where precision is worst.
                    segmented(id: id, param: onParam, compact: false)
                        .frame(width: 104)
                }
            }
            // A CYCLER, not a row of detents. The Booster alone offers eight
            // types; eight buttons across a 178 pt card would be 20 pt each and
            // unreadable, and a picker sheet would bury the control the player
            // came here for. One tap steps forward, the arrows step either way.
            if let typeParam { typeCycler(id: id, param: typeParam) }
            if !isOff {
                ForEach(dialsInBlock) { p in blockDial(id: id, param: p) }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(RigTheme.trim.opacity(isOff ? 0.25 : 0.5), lineWidth: 1)
        )
    }

    /// `‹ Crunch ›` — the compact stand-in for a many-detent selector.
    private func typeCycler(id: UUID, param: GearParameter) -> some View {
        let binding = store.binding(itemId: id, param: param.name)
        let options = param.options ?? []
        let count = max(1, options.count)
        let index = min(max(Int(binding.wrappedValue.rounded()), 0), count - 1)
        // CYCLES THE REAL TYPES ONLY — Wah → Tremolo → Wah, never through Off.
        // Off is still index 0 and still what an unset block holds, but it is no
        // longer a stop on the carousel: turning a block off is the ON/OFF pair's
        // job, and landing on "Off" while hunting for a sound was just a dead
        // detent in the middle of the loop.
        let firstReal = min(1, count - 1)
        let realCount = max(1, count - firstReal)
        func step(_ d: Int) {
            let cur = max(index, firstReal)
            binding.wrappedValue = Double(firstReal + (cur - firstReal + d + realCount) % realCount)
        }
        return HStack(spacing: 0) {
            Button { step(-1) } label: {
                Image(systemName: "chevron.left").font(.caption2.weight(.bold))
                    .foregroundStyle(RigTheme.textMuted)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { step(1) } label: {
                Text(options.indices.contains(index) ? options[index] : "—")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(index == ParameterMap.ampFXOff ? RigTheme.textMuted : RigTheme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, minHeight: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { step(1) } label: {
                Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                    .foregroundStyle(RigTheme.textMuted)
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background { Color.clear.rigRaised(cornerRadius: 7) }
    }

    /// A block's own dial: label above, slider below, so it fits a 178 pt card.
    private func blockDial(id: UUID, param: GearParameter) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(param.displayName)
                    .font(.caption2).foregroundStyle(RigTheme.textMuted)
                Spacer()
                Text(String(format: "%.1f", store.item(id)?.values[param.name] ?? 0))
                    .font(.caption2.monospacedDigit()).foregroundStyle(RigTheme.amber)
            }
            TapSlider(value: store.binding(itemId: id, param: param.name),
                      in: param.min...param.max)
        }
    }

    /// A detent row for a discrete parameter — the same control the CHARACTER /
    /// VARIATION / POWER strip uses, factored out so a block's selector and the
    /// amp's own switches cannot drift apart visually.
    private func segmented(id: UUID, param: GearParameter, compact: Bool) -> some View {
        let binding = store.binding(itemId: id, param: param.name)
        let options = param.options ?? []
        let selected = Int(binding.wrappedValue.rounded())
        return HStack(spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, label in
                let isOn = (index == selected)
                Button { binding.wrappedValue = Double(index) } label: {
                    Text(label)
                        .font((compact ? Font.caption2 : Font.caption).weight(isOn ? .bold : .medium))
                        .foregroundStyle(isOn ? .black : RigTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, minHeight: compact ? 26 : 34)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(RigTheme.amber)
                            } else {
                                Color.clear.rigRaised(cornerRadius: 7)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Channel memories

    /// The amp's channel buttons: tap to recall, hold to store.
    ///
    /// A channel is the whole panel — every dial, every selector, every FX block
    /// — written in ONE store mutation, so recalling one is a single compile and
    /// therefore a single structural swap through the fade/park barrier, not
    /// twenty-six of them. Nothing about `GearItem` changed to make this work:
    /// the panel already IS a `[String: Double]`, and `catalogVersion` stays at
    /// 3, which is what keeps the player's saved rig loadable.
    private func channelStrip(id: UUID) -> some View {
        let name = store.item(id)?.name ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            Text("tap to recall · hold to store the whole panel")
                .font(.caption2)
                .foregroundStyle(RigTheme.textMuted)
            HStack(spacing: 6) {
                ForEach(0..<KatanaChannelStore.channelCount, id: \.self) { ch in
                    let filled = KatanaChannelStore.isOccupied(channel: ch, ampName: name)
                    Button {
                        _ = store.recallKatanaChannel(ch, itemId: id)
                    } label: {
                        VStack(spacing: 2) {
                            Text("CH \(ch + 1)").font(.caption.weight(.semibold))
                            Text(filled ? "stored" : "empty").font(.caption2)
                                .foregroundStyle(RigTheme.textMuted)
                        }
                        .foregroundStyle(filled ? RigTheme.textPrimary : RigTheme.textMuted)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background { Color.clear.rigRaised(cornerRadius: 9) }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.6).onEnded { _ in
                            _ = store.saveKatanaChannel(ch, itemId: id)
                        }
                    )
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A rotary knob whose pointer reflects `value`; drag up/down to turn it.
struct InteractiveKnob: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var onLight: Bool = false

    @State private var startValue: Double?

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let span = range.upperBound - range.lowerBound
            let frac = span > 0 ? (value - range.lowerBound) / span : 0
            let angle = Angle(degrees: -135 + frac * 270)

            ZStack {
                Circle().fill(onLight ? RigTheme.cabinet : Color(white: 0.85))
                Circle().strokeBorder(onLight ? RigTheme.trim : .black.opacity(0.4), lineWidth: max(2, s * 0.06))
                Capsule()
                    .fill(RigTheme.amber)
                    .frame(width: max(2, s * 0.09), height: s * 0.4)
                    .offset(y: -s * 0.2)
                    .rotationEffect(angle)
            }
            .frame(width: s, height: s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if startValue == nil { startValue = value }
                        let delta = Double(-g.translation.height) / 140.0 * span
                        value = min(range.upperBound, max(range.lowerBound, (startValue ?? value) + delta))
                    }
                    .onEnded { _ in startValue = nil }
            )
        }
    }
}

/// A compact numeric keypad for typing an exact parameter value (0–10 knobs).
struct NumberKeypad: View {
    let title: String
    let initial: Double
    let range: ClosedRange<Double>
    var onCancel: () -> Void
    var onCommit: (Double) -> Void

    @State private var text: String = ""

    private let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"],
                                    ["7", "8", "9"], [".", "0", "⌫"]]

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(spacing: 14) {
                Text(title.uppercased())
                    .font(.caption.weight(.bold)).tracking(1.5)
                    .foregroundStyle(RigTheme.textMuted)

                Text(text.isEmpty ? "0" : text)
                    .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(RigTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.3)))

                Text("Range \(fmt(range.lowerBound))–\(fmt(range.upperBound))")
                    .font(.caption2).foregroundStyle(RigTheme.textMuted)

                VStack(spacing: 10) {
                    ForEach(rows, id: \.self) { row in
                        HStack(spacing: 10) {
                            ForEach(row, id: \.self) { key in keyButton(key) }
                        }
                    }
                }

                HStack(spacing: 10) {
                    action("Cancel", tint: RigTheme.textMuted, action: onCancel)
                    action("Set", tint: RigTheme.amber, filled: true, action: commit)
                }
            }
            .padding(20)
            .frame(width: 300)
            // A modal sheet over the dimmed detail view — the deepest shadow in the app.
            .rigCard(cornerRadius: 22, lifted: true)
        }
        .onAppear { if text.isEmpty { text = fmt(initial) } }
    }

    private func keyButton(_ key: String) -> some View {
        Button { tap(key) } label: {
            Text(key)
                .font(.title2.weight(.medium))
                .foregroundStyle(RigTheme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 48)
                .rigRaised(cornerRadius: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func action(_ label: String, tint: Color, filled: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.body.weight(.semibold))
                .foregroundStyle(filled ? .black : tint)
                .frame(maxWidth: .infinity, minHeight: 46)
                // Filled = the tint IS the surface (Set is amber); otherwise it's a
                // raised key like the digits above it.
                .background {
                    if filled {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint)
                    } else {
                        Color.clear.rigRaised(cornerRadius: 12)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tap(_ key: String) {
        switch key {
        case "⌫": if !text.isEmpty { text.removeLast() }
        case ".": if !text.contains(".") { text = text.isEmpty ? "0." : text + "." }
        default:  if text.replacingOccurrences(of: ".", with: "").count < 4 { text += key }
        }
    }

    private func commit() {
        let value = Double(text) ?? initial
        onCommit(min(range.upperBound, max(range.lowerBound, value)))
    }

    private func fmt(_ d: Double) -> String {
        d == d.rounded() ? String(format: "%.0f", d) : String(format: "%.1f", d)
    }
}

#Preview {
    ComponentDetailView(component: .amp, onClose: {})
        .environmentObject(RigStore.preview)
        .preferredColorScheme(.dark)
}
