//
//  ARPedalSetupView.swift
//  StreetRig
//
//  The AR pedal-setup screen. A live camera feed backs three pedal "stomp"
//  slots: drag a pedal into a slot, then a foot-stomp over that slot (detected
//  by CameraStompDetector) toggles it on/off. Tapping a slot toggles it too —
//  the always-available fallback, and the only way to test in the simulator
//  (which has no camera, and no ARKit either).
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
//  PLACEMENT READINESS. The slots outline GREEN once ARKit reports a real floor
//  below the phone, in view, with steady tracking — a promise that stomps will land.
//  Tapping the floor then pins the row to a world anchor and the slots move OFF the
//  fixed bottom row onto the spot the player chose. Green never means "engaged";
//  engaged is amber, and the two have to be tellable apart from standing height.
//  All of it is driven by ONE value, `detector.state` — see ARPlacementCoordinator.
//
//  LAYOUT, IN LANDSCAPE, WITH NO VERTICAL ROOM. The banner and the placeholder live
//  IN the layout flow rather than floating over it: as top-anchored overlays they
//  landed on the slots whenever the available height shifted, because a `Spacer` can
//  only absorb slack it can see. The anchored slots are the ONE thing that floats,
//  because their whole purpose is to sit where the floor is — and they are clamped
//  away from the banner rather than trusted not to reach it.
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

    /// Room the banner needs at the top, so an anchored slot can never be clamped up
    /// underneath it.
    private static let bannerReserve: CGFloat = 54

    var body: some View {
        GeometryReader { geo in
            // Landscape is short: give the slots what's left after the banner and
            // the ON/OFF captions, so the same content fits the full page AND the
            // shorter body of the signal-check screen.
            let slotHeight = min(150, max(72, geo.size.height - 96))
            // Below this there is no room for the big camera-status block without
            // it landing on top of the slots — it becomes a line under the banner.
            let compact = geo.size.height < 300
            let slotWidth = max(80, (geo.size.width - 40 - 32) / 3)
            let anchored = detector.state == .locked

            ZStack {
                background

                VStack(spacing: 0) {
                    banner
                        .padding(.top, 14)
                    if !detector.state.isCameraLive {
                        if compact {
                            Text(fallbackText)
                                .font(.system(size: 10))
                                .foregroundStyle(RigTheme.textMuted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .padding(.top, 5)
                        } else {
                            cameraPlaceholder
                        }
                    }
                    Spacer(minLength: 0)
                    if !anchored {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(0..<3, id: \.self) { index in
                                ARSlotView(index: index,
                                           height: slotHeight,
                                           placementIsGood: detector.state.placementIsGood)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                    }
                }

                if anchored {
                    AnchoredSlots(layout: detector.layout,
                                  slotWidth: slotWidth,
                                  slotHeight: slotHeight,
                                  viewport: geo.size,
                                  topLimit: Self.bannerReserve)
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
    private var background: some View {
        if detector.state.isCameraLive {
            // The feed is what settles which way up AND how big the picture is, and
            // both the slot projection and Vision's foot position are derived from
            // that one answer — so it is passed straight on rather than looked up
            // twice. Two nearly-identical viewports is how a stomp lands on the
            // wrong slot.
            ARCameraView(session: detector.session,
                         onGeometry: { detector.setViewGeometry(orientation: $0, size: $1) },
                         onView: { detector.attach(feedView: $0) })
                .contentShape(Rectangle())
                // Tap-to-place lives on the BACKGROUND, so a tap that lands on a slot
                // toggles that slot instead — tap-to-toggle stays available in every
                // state, including this one, and the two gestures never both fire.
                .onTapGesture { detector.place(at: $0) }
        } else {
            LinearGradient(colors: [Color(white: 0.12), Color(white: 0.04)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    /// The "no camera here" block. It lives IN the layout flow rather than
    /// floating over the background: as a top-anchored overlay it landed on the
    /// slots whenever the available height shifted — a `Spacer` can only absorb
    /// slack it can see, and it could not see this. Sequencing it above the
    /// Spacer makes the collision impossible instead of merely unlikely.
    private var cameraPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: detector.state == .denied ? "video.slash" : "camera.viewfinder")
                .font(.system(size: 38))
                .foregroundStyle(RigTheme.textMuted)
            Text(fallbackText)
                .font(.caption)
                .foregroundStyle(RigTheme.textMuted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: 460)
        }
        .padding(.top, 24)
        .padding(.horizontal, 24)
    }

    private var fallbackText: String {
        switch detector.state {
        case .denied:
            return "Camera is off — enable it in Settings for stomp detection. Tap a slot to toggle for now."
        default: // .unsupported / .idle
            return "Camera + foot-stomp detection run on a real iPhone. Tap a slot to toggle here."
        }
    }

    // MARK: Coaching banner
    //
    // One line, always. This page is landscape and short on vertical room, and the
    // banner is the only thing telling a player who is looking at their FEET what the
    // phone on the floor is currently doing.

    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: bannerIcon)
            Text(bannerText)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if detector.state == .locked {
                Button {
                    detector.reposition()
                } label: {
                    Text("Reposition")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(RigTheme.amber)
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(bannerTint)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.black.opacity(0.55)))
        .animation(.easeInOut(duration: 0.2), value: bannerText)
    }

    private var bannerText: String {
        switch detector.state {
        case .searching(.lookingForFloor): return "Looking for the floor — aim at your feet"
        case .searching(.holdStill):       return "Hold still"
        case .searching(.aimLower):        return "Aim lower, toward your feet"
        case .ready:                       return "Tap the floor to place your pedals"
        case .locked:                      return "Locked in · stomp a slot to toggle"
        case .lost:                        return "Phone moved — tap the floor to re-place"
        default:
            // .idle / .unsupported / .denied / .running: nothing is being placed, so
            // the banner goes back to being the page's instructions.
            return "Prop your phone facing your feet · drag pedals into a slot · stomp a slot to toggle"
        }
    }

    private var bannerIcon: String {
        switch detector.state {
        case .ready:  return "hand.tap"
        case .locked: return "checkmark.circle"
        case .lost:   return "exclamationmark.triangle"
        default:      return "figure.walk"
        }
    }

    private var bannerTint: Color {
        switch detector.state {
        case .ready, .locked: return RigTheme.ready
        case .lost:           return RigTheme.clip
        default:              return RigTheme.textPrimary
        }
    }
}

// MARK: - The row, once it belongs to the floor

/// The three slots drawn where ARKit says the anchored row is.
///
/// Its own view observing its own object: the projected positions update up to
/// 30×/second, and routing that through the page's own state would re-render the
/// banner, the background and the placeholder alongside them — on the main thread,
/// next to a live neural amp.
private struct AnchoredSlots: View {
    @ObservedObject var layout: ARSlotLayout
    let slotWidth: CGFloat
    let slotHeight: CGFloat
    let viewport: CGSize
    let topLimit: CGFloat

    var body: some View {
        if let points = layout.slots, points.count == 3 {
            ForEach(0..<3, id: \.self) { index in
                ARSlotView(index: index, height: slotHeight, placementIsGood: true)
                    .frame(width: slotWidth)
                    .position(clamped(points[index]))
            }
        }
    }

    /// Keep a slot on screen and clear of the banner. ARKit will happily project a
    /// point past the edge of the viewport — the anchor is a real spot on a real
    /// floor and the player can aim the phone away from it — and a footswitch that
    /// has slid off the screen cannot be tapped, which is the fallback that is
    /// supposed to always work.
    private func clamped(_ point: CGPoint) -> CGPoint {
        // Height plus the ON/OFF caption underneath it.
        let half = (slotHeight + 22) / 2
        return CGPoint(
            x: min(max(point.x, slotWidth / 2), max(slotWidth / 2, viewport.width - slotWidth / 2)),
            y: min(max(point.y, topLimit + half), max(topLimit + half, viewport.height - half))
        )
    }
}

// MARK: - One stomp slot

private struct ARSlotView: View {
    @EnvironmentObject var store: RigStore
    let index: Int
    var height: CGFloat = 150
    /// Whether the phone is propped somewhere that works. Purely about POSITION —
    /// never about whether the pedal is engaged.
    var placementIsGood: Bool = false
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
            // The promise, drawn OUTSIDE the border rather than replacing it. An
            // engaged pedal keeps its amber border (see `borderColor`), so without a
            // second ring a player with all three pedals on would lose the green
            // entirely — exactly when they are most likely to be standing over the
            // phone about to stomp.
            .overlay {
                if placementIsGood {
                    RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .strokeBorder(RigTheme.ready, lineWidth: 2)
                        .padding(-4)
                        .shadow(color: RigTheme.ready.opacity(0.5), radius: 8)
                }
            }
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

    /// Amber wins, always. It is the PEDAL's state — engaged, or being dropped onto —
    /// and a green that could overwrite it would leave the player unable to tell
    /// "this pedal is on" from "you're standing in the right place".
    private func borderColor(on: Bool) -> Color {
        if on { return RigTheme.amber }
        if targeted { return RigTheme.amber }
        if placementIsGood { return RigTheme.ready }
        return RigTheme.trim.opacity(0.5)
    }
}

#Preview {
    ARPedalSetupView()
        .environmentObject(RigStore.preview)
        .preferredColorScheme(.dark)
}
