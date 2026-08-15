//
//  ARPedalSetupView.swift
//  StreetRig
//
//  The AR pedal-setup screen. A live camera feed backs three pedal "stomp"
//  slots: drag a pedal into a slot, then a foot-stomp over that slot (detected
//  by CameraStompDetector) toggles it on/off. Tapping a slot toggles it too —
//  the always-available fallback, and the only way to test in the simulator
//  (which has no camera).
//
//  A slot is a FOOTSWITCH onto a real pedal in the rig, not decoration: the
//  toggle lands on `RigStore.arSlots`, which `RigGraphCompiler` reads to derive
//  each pedal's `enabled`, and `RigAudioBridge` pushes onto the DSP's lock-free
//  parameter bus. Dropping a pedal that isn't in the rig adds it to the chain.
//
//  There is ONE implementation, `ARPedalContentView`, with two entry points:
//  this page (right of the rig in MainView's pager) and the signal-check screen,
//  where you can see your levels while you stomp.
//

import SwiftUI
import StreetRigEngine

/// The pager page. A thin wrapper so the shared content can be hosted elsewhere.
struct ARPedalSetupView: View {
    var body: some View { ARPedalContentView() }
}

// MARK: - Shared content

struct ARPedalContentView: View {
    @EnvironmentObject var store: RigStore
    @StateObject private var detector = CameraStompDetector.shared

    var body: some View {
        GeometryReader { geo in
            // Landscape is short: give the slots what's left after the banner and
            // the ON/OFF captions, so the same content fits the full page AND the
            // shorter body of the signal-check screen.
            let slotHeight = min(150, max(72, geo.size.height - 96))
            // Below this there is no room for the big camera-status block without
            // it landing on top of the slots — it becomes a line under the banner.
            let compact = geo.size.height < 300

            ZStack {
                background(compact: compact)

                VStack(spacing: 0) {
                    banner
                        .padding(.top, 14)
                    if compact, detector.status != .running {
                        Text(fallbackText)
                            .font(.system(size: 10))
                            .foregroundStyle(RigTheme.textMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.top, 5)
                    }
                    Spacer(minLength: 0)
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(0..<3, id: \.self) { index in
                            ARSlotView(index: index, height: slotHeight)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
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
    private func background(compact: Bool) -> some View {
        if detector.status == .running {
            CameraPreviewView(session: detector.session)
        } else {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(white: 0.12), Color(white: 0.04)],
                               startPoint: .top, endPoint: .bottom)
                if !compact {
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

// MARK: - One stomp slot

private struct ARSlotView: View {
    @EnvironmentObject var store: RigStore
    let index: Int
    var height: CGFloat = 150
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
                        GearArtView(item: pedal)
                            .frame(width: 46, height: min(62, height * 0.42))
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
            .frame(height: height)
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
