//
//  ARPedalSetupView.swift
//  StreetRig
//
//  The AR pedal-setup page (right of the rig). A live camera feed backs three
//  pedal "stomp" slots: drag a pedal from the collection into a slot, then a
//  foot-stomp over that slot (detected by CameraStompDetector) toggles it
//  on/off. Tapping a slot toggles it too — the always-available fallback, and
//  the only way to test in the simulator (which has no camera).
//

import SwiftUI
import StreetRigEngine

struct ARPedalSetupView: View {
    @EnvironmentObject var store: RigStore
    @StateObject private var detector = CameraStompDetector()

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                banner
                    .padding(.top, 14)
                Spacer(minLength: 0)
                HStack(alignment: .top, spacing: 16) {
                    ForEach(0..<3, id: \.self) { index in
                        ARSlotView(index: index)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .onAppear {
            detector.onStomp = { slot in
                withAnimation(.easeInOut(duration: 0.15)) { store.toggleARSlot(slot) }
            }
            detector.start()
        }
        .onDisappear { detector.stop() }
    }

    @ViewBuilder
    private var background: some View {
        if detector.status == .running {
            CameraPreviewView(session: detector.session)
        } else {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(white: 0.12), Color(white: 0.04)],
                               startPoint: .top, endPoint: .bottom)
                VStack(spacing: 12) {
                    Image(systemName: detector.status == .denied ? "video.slash" : "camera.viewfinder")
                        .font(.system(size: 38))
                        .foregroundStyle(RigTheme.textMuted)
                    Text(fallbackText)
                        .font(.caption)
                        .foregroundStyle(RigTheme.textMuted)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: 460)
                }
                .padding(.top, 52)
                .padding(.horizontal, 24)
            }
        }
    }

    private var fallbackText: String {
        switch detector.status {
        case .denied:
            return "Camera is off — enable it in Settings for stomp detection. Tap a slot to toggle for now."
        default: // .unavailable / .idle
            return "Camera + foot-stomp detection run on a real iPhone. Tap a slot to toggle here."
        }
    }

    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: "figure.walk")
            Text("Prop your phone facing your feet · drag pedals into a slot · stomp a slot to toggle")
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(RigTheme.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.black.opacity(0.55)))
    }
}

private struct ARSlotView: View {
    @EnvironmentObject var store: RigStore
    let index: Int
    @State private var targeted = false

    var body: some View {
        let pedal = store.arPedal(index)
        let on = store.arSlots[index].isOn && pedal != nil

        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.black.opacity(0.45))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        borderColor(on: on),
                        style: StrokeStyle(lineWidth: 2, dash: pedal == nil ? [6] : [])
                    )

                if let pedal {
                    VStack(spacing: 8) {
                        GearArtView(item: pedal).frame(width: 46, height: 62)
                        Text(pedal.name)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(RigTheme.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "plus.circle").font(.title2)
                        Text("Drop pedal").font(.caption2)
                    }
                    .foregroundStyle(RigTheme.textMuted)
                }
            }
            .frame(height: 150)
            .overlay(alignment: .topTrailing) {
                if pedal != nil {
                    Circle()
                        .fill(on ? RigTheme.amber : Color(white: 0.25))
                        .frame(width: 12, height: 12)
                        .shadow(color: on ? RigTheme.amber : .clear, radius: 5)
                        .padding(10)
                }
            }
            .overlay(alignment: .topLeading) {
                if pedal != nil {
                    Button { store.setARSlot(index, pedalId: nil) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(RigTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                }
            }
            .shadow(color: on ? RigTheme.amber.opacity(0.45) : .clear, radius: 12)

            Text(pedal == nil ? "\(index + 1)" : (on ? "ON" : "OFF"))
                .font(.caption2.weight(.bold))
                .foregroundStyle(on ? RigTheme.amber : RigTheme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) { store.toggleARSlot(index) }
        }
        .dropDestination(for: GearItem.self) { items, _ in
            guard let item = items.first, item.category.isPedal else { return false }
            if store.item(item.id) != nil {
                store.setARSlot(index, pedalId: item.id)
            } else {
                store.addToCollection(item)
                if let owned = store.collection.first(where: { $0.name == item.name && $0.category == item.category }) {
                    store.setARSlot(index, pedalId: owned.id)
                }
            }
            return true
        } isTargeted: { targeted = $0 }
    }

    private func borderColor(on: Bool) -> Color {
        if on { return RigTheme.amber }
        if targeted { return RigTheme.amber }
        return RigTheme.trim.opacity(0.5)
    }
}

#Preview {
    ARPedalSetupView()
        .environmentObject(RigStore.preview)
        .preferredColorScheme(.dark)
}
