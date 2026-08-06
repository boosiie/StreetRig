//
//  RigStageView.swift
//  StreetRig
//
//  The center stage. With 3D enabled the whole rig is one SceneKit diorama
//  (RigStage3DView) — amp centered, pedalboard in front, guitar to the right —
//  that you orbit as a single scene. With 3D off (or a combo amp) it falls back
//  to the flat vector layout: amp head + cabinet + pedalboard centered, a guitar
//  on a stand to the right, drag to tilt up to ~20° and rubber-band back. Tap a
//  component to zoom in. Drop a collection card on it to swap that part.
//

import SwiftUI

/// Which rig part is in focus (for the zoomed-in view).
enum RigComponent: Hashable {
    case guitar, amp, cabinet, combo
    case pedal(UUID)
}

struct RigStageView: View {
    @EnvironmentObject var store: RigStore
    @Binding var focused: RigComponent?

    @State private var tilt: CGSize = .zero
    @State private var isTargeted = false

    private let maxAngle: CGFloat = 20

    /// One 3D diorama for a head+cab stack; the vector layout otherwise.
    private var use3DStage: Bool { FeatureFlags.amp3D && !store.isCombo }

    var body: some View {
        ZStack {
            stageBackground

            if use3DStage {
                // The whole rig orbits together as one scene — no SwiftUI warp.
                RigStage3DView(amp: store.ampItem, pedals: store.pedalItems, guitar: store.guitar) { component in
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { focused = component }
                }
                .padding(.horizontal, 8)
                .padding(.top, 20)
            } else {
                vectorRig
                    .rotation3DEffect(.degrees(Double(tilt.width)),  axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                    .rotation3DEffect(.degrees(Double(-tilt.height)), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                    .simultaneousGesture(rotateDrag)
                    .padding(.top, 26)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(RigTheme.amber, lineWidth: 2)
                .padding(6)
                .opacity(isTargeted ? 0.9 : 0)
                .animation(.easeInOut(duration: 0.15), value: isTargeted)
        }
        .dropDestination(for: GearItem.self) { items, _ in
            guard let first = items.first else { return false }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { store.apply(first) }
            return true
        } isTargeted: { isTargeted = $0 }
    }

    // MARK: - Vector fallback (flag off, or a combo amp)

    private var vectorRig: some View {
        ZStack(alignment: .bottom) {
            // Centered: amp head + cabinet + pedalboard
            VStack(spacing: 12) {
                if store.isCombo {
                    gearView(.combo, item: store.ampItem, width: 156, height: 116)
                } else {
                    VStack(spacing: 5) {
                        gearView(.amp, item: store.ampItem, width: 138, height: 46)
                        gearView(.cabinet, item: store.cabinetItem, width: 166, height: 98)
                    }
                }
                vectorPedalboard
            }

            // Single guitar on a stand, to the right
            HStack {
                Spacer(minLength: 0)
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { focused = .guitar }
                } label: {
                    GuitarOnStandView().frame(width: 118, height: 214)
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, 24)
        }
    }

    private var vectorPedalboard: some View {
        HStack(spacing: 10) {
            if store.pedalItems.isEmpty {
                Text("Drop pedals here")
                    .font(.caption2)
                    .foregroundStyle(RigTheme.textMuted)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            } else {
                ForEach(store.pedalItems) { pedal in
                    gearView(.pedal(pedal.id), item: pedal, width: 40, height: 50)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.13)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(RigTheme.trim.opacity(0.30), lineWidth: 1.5)
                )
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
        )
    }

    private func gearView(_ component: RigComponent, item: GearItem?, width: CGFloat, height: CGFloat) -> some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { focused = component }
        } label: {
            GearArtView(item: item)
                .frame(width: width, height: height)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Background (lighter "stage" panel)

    private var stageBackground: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.17), Color(white: 0.10)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [RigTheme.amber.opacity(0.10), .clear],
                           center: .center, startRadius: 0, endRadius: 340)
        }
    }

    // MARK: - Tilt gesture for the vector layout (rubber-band back to center)

    private var rotateDrag: some Gesture {
        DragGesture()
            .onChanged { value in
                tilt = CGSize(
                    width: clamp(value.translation.width / 6),
                    height: clamp(value.translation.height / 6)
                )
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.55, dampingFraction: 0.55)) { tilt = .zero }
            }
    }

    private func clamp(_ x: CGFloat) -> CGFloat { max(-maxAngle, min(maxAngle, x)) }
}

#Preview {
    RigStageView(focused: .constant(nil))
        .environmentObject(RigStore.preview)
        .preferredColorScheme(.dark)
}
