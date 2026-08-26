//
//  PluginEditorView.swift
//  StreetRigEngine
//
//  Phase 4 — the AUv3 plugin's embedded editor. A SwiftUI control surface driven
//  by a plugin-side `RigStore(persist:false)` that REUSES the framework's shared
//  knob controls (`TapSlider`, `ControlBoardView`) — the same controls the
//  standalone app binds to `store.binding(itemId:param:)`. There is no duplicated
//  knob UI and no reach into the host app: everything here is framework-local, so
//  the editor is self-contained inside the extension sandbox.
//
//  Two layouts, chosen by the host-selected view configuration (see
//  `StreetRigDSPUnit.supportedViewConfigurations`):
//    • COMPACT — amp knobs + an active-pedal row (a short host view).
//    • FULL    — a gear bar (add / remove / swap) + the full `ControlBoardView`
//                rig editor (amp + every pedal card).
//
//  Every knob writes through `store.binding(...)`; the `RigAUParameterBridge` turns
//  those writes into host automation and follows host automation back. This view
//  knows nothing about `AUParameter` — it is purely the store's UI.
//

import SwiftUI
import Combine

/// Observable layout selector the hosting view controller flips when the host
/// picks a compact or full view configuration.
public final class EditorConfig: ObservableObject {
    @Published public var isCompact: Bool
    public init(isCompact: Bool = false) { self.isCompact = isCompact }
}

public struct PluginEditorView: View {
    @ObservedObject var store: RigStore
    @ObservedObject var config: EditorConfig

    public init(store: RigStore, config: EditorConfig) {
        self.store = store
        self.config = config
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            if config.isCompact {
                CompactEditor(store: store)
            } else {
                FullEditor(store: store)
            }
        }
        .background(RigTheme.background)
        .environmentObject(store)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "guitars.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(RigTheme.amber)
            Text("StreetRig")
                .font(.headline.weight(.bold))
                .foregroundStyle(RigTheme.textPrimary)
            Text(config.isCompact ? "Compact" : "Rig Editor")
                .font(.caption)
                .foregroundStyle(RigTheme.textMuted)
            Spacer()
            Text(ampTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(RigTheme.trim)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var ampTitle: String { store.ampItem?.name ?? "No amp" }
}

// MARK: - Compact layout (amp knobs + active-pedal row)

private struct CompactEditor: View {
    @ObservedObject var store: RigStore

    private var drivePedals: [GearItem] {
        store.pedalItems.filter { !$0.category.parameters.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let amp = store.ampItem {
                    SectionCard(title: amp.name, subtitle: amp.category.displayName) {
                        KnobGrid(store: store, item: amp, columns: 2)
                    }
                }
                if drivePedals.isEmpty {
                    Text("No pedals in the chain.")
                        .font(.footnote)
                        .foregroundStyle(RigTheme.textMuted)
                } else {
                    Text("PEDALS")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(RigTheme.textMuted)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(drivePedals) { pedal in
                                SectionCard(title: pedal.name, subtitle: pedal.category.displayName) {
                                    KnobGrid(store: store, item: pedal, columns: 1)
                                }
                                .frame(width: 190)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Full layout (gear bar + reused ControlBoardView)

private struct FullEditor: View {
    @ObservedObject var store: RigStore

    var body: some View {
        VStack(spacing: 0) {
            GearBar(store: store)
            Divider().overlay(Color.white.opacity(0.06))
            // Reuse the app's control surface verbatim (framework-shared).
            ControlBoardView()
                .environmentObject(store)
        }
    }
}

/// Add / remove / swap gear — drives the STRUCTURAL path (topology → the bridge's
/// `applyRig` barrier). Kept intentionally small: a menu to swap the amp, a menu to
/// add a pedal, and a remove control per pedal.
private struct GearBar: View {
    @ObservedObject var store: RigStore

    private var ampChoices: [GearItem] {
        RigStore.catalog.filter { $0.category == .amp || $0.category == .comboAmp }
    }
    private var pedalChoices: [GearItem] {
        RigStore.catalog.filter { $0.category.isPedal }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(ampChoices) { amp in
                        Button(amp.name) { store.apply(GearItem(name: amp.name, category: amp.category)) }
                    }
                } label: {
                    chip(icon: "amplifier", text: "Amp")
                }

                Menu {
                    ForEach(pedalChoices) { pedal in
                        Button(pedal.name) { store.apply(GearItem(name: pedal.name, category: pedal.category)) }
                    }
                } label: {
                    chip(icon: "plus.circle.fill", text: "Add pedal")
                }

                ForEach(store.pedalItems) { pedal in
                    HStack(spacing: 4) {
                        Text(pedal.name)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(RigTheme.textPrimary)
                        Button {
                            store.removePedal(pedal.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(RigTheme.textMuted)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .rigRaised(Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func chip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(RigTheme.amber)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .rigRaised(Capsule())
    }
}

// MARK: - Shared building blocks (all bind to store.binding + TapSlider)

private struct SectionCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                GearGlyphView(item: nil).frame(width: 30, height: 34).hidden().overlay(
                    Image(systemName: "dial.min")
                        .foregroundStyle(RigTheme.trim)
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold))
                        .foregroundStyle(RigTheme.textPrimary).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(RigTheme.textMuted)
                }
                Spacer(minLength: 0)
            }
            content
        }
        .padding(14)
        .rigCard(cornerRadius: 16)
    }
}

/// A grid of labeled `TapSlider`s for one gear item — the reused knob control.
private struct KnobGrid: View {
    @ObservedObject var store: RigStore
    let item: GearItem
    let columns: Int

    var body: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 14), count: max(1, columns))
        // `item.parameters`, not `item.category.parameters`: an amp's panel is as
        // model-specific as a pedal's (a Katana has Volume and three selectors; a
        // JC-120 has no Presence), and the category can only describe the shared six.
        LazyVGrid(columns: cols, alignment: .leading, spacing: 12) {
            ForEach(item.parameters) { param in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(param.name).font(.caption.weight(.medium))
                            .foregroundStyle(RigTheme.textPrimary)
                        Spacer()
                        Text(String(format: "%.1f", store.item(item.id)?.values[param.name] ?? 0))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(RigTheme.textMuted)
                    }
                    TapSlider(value: store.binding(itemId: item.id, param: param.name),
                              in: param.min...param.max)
                }
            }
        }
    }
}

#Preview {
    PluginEditorView(store: RigStore.preview, config: EditorConfig(isCompact: false))
        .frame(width: 640, height: 420)
}
