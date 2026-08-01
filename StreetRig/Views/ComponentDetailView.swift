//
//  ComponentDetailView.swift
//  StreetRig
//
//  The zoomed-in view a component locks into when tapped. The component fills
//  the top as a large control panel focused on its row of knobs — the knobs
//  are turnable (vertical drag) — and a dock of sliders stays at the bottom.
//  Knobs and sliders are bound to the same values, so either one moves both.
//

import SwiftUI

struct ComponentDetailView: View {
    @EnvironmentObject var store: RigStore
    let component: RigComponent
    var onClose: () -> Void

    private var item: GearItem? {
        switch component {
        case .guitar: return store.guitar
        case .amp, .combo: return store.ampItem
        case .cabinet: return store.cabinetItem
        case .pedal(let id): return store.item(id)
        }
    }

    private var params: [GearParameter] { item?.category.parameters ?? [] }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.85))
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 14) {
                header

                if let id = item?.id, !params.isEmpty {
                    knobPanel(id: id)
                        .frame(height: 132)
                    sliderDock(id: id)
                        .frame(maxHeight: .infinity)
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
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
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
                    let n = CGFloat(params.count)
                    let knob = max(48, min(geo.size.height * 0.52, (geo.size.width - 48) / n - 14))
                    HStack(spacing: 10) {
                        ForEach(params) { param in
                            VStack(spacing: 12) {
                                InteractiveKnob(
                                    value: store.binding(itemId: id, param: param.name),
                                    range: param.min...param.max,
                                    onLight: light
                                )
                                .frame(width: knob, height: knob)
                                Text(param.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(labelColor)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(22)
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(RigTheme.trim.opacity(0.5), lineWidth: 2)
            )
    }

    // MARK: - Slider dock (bottom), aligned under the knobs

    private func sliderDock(id: UUID) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                ForEach(params) { param in
                    HStack(spacing: 12) {
                        Text(param.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(RigTheme.textPrimary)
                            .frame(width: 92, alignment: .leading)
                        Slider(value: store.binding(itemId: id, param: param.name),
                               in: param.min...param.max)
                            .tint(RigTheme.amber)
                        Text(String(format: "%.1f", store.item(id)?.values[param.name] ?? 0))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(RigTheme.textMuted)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
            .padding(18)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(RigTheme.backgroundLift)
        )
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

#Preview {
    ComponentDetailView(component: .amp, onClose: {})
        .environmentObject(RigStore.preview)
        .preferredColorScheme(.dark)
}
