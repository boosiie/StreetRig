//
//  ARPedalSetupView.swift
//  StreetRig
//
//  The AR pedal-setup screen. A live camera feed backs three pedal "stomp"
//  slots: put a pedal in a slot, then a foot-stomp over that slot (detected
//  by CameraStompDetector) toggles it on/off. Tapping an occupied slot toggles it
//  too — the always-available fallback, and the only way to test in the simulator
//  (which has no camera, and no ARKit either).
//
//  A slot is a FOOTSWITCH onto a real pedal in the rig, not decoration: the
//  toggle lands on `RigStore.arSlots`, which `RigGraphCompiler` reads to derive
//  each pedal's `enabled`, and `RigAudioBridge` pushes onto the DSP's lock-free
//  parameter bus. Assigning a pedal that isn't in the rig adds it to the chain.
//
//  TWO WAYS TO FILL A SLOT, and they are not redundant. DRAG is the idiom the rig
//  stage already teaches: hold a card in the MY GEAR rail and pull it onto a slot,
//  which lands through `RigDragController` (the rail is deliberately not a system
//  drag, so `.dropDestination` could never have seen it). TAP is the one that
//  works on the play page, where there is no rail on screen at all, and the one a
//  player can hit while standing over the phone: tapping an EMPTY slot opens the
//  pedal picker. Tapping an occupied slot stays a single-tap footswitch — the
//  fallback that must always work never becomes a two-step interaction.
//
//  The content lives in `ARPedalContentView`, which `ARPedalSetupView` wraps as
//  the pager page right of the rig in MainView. Signal levels are no longer shown
//  over it — they sit in the control panel at the bottom of the shell instead.
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

/// The pager page. A thin wrapper so the shared content can be hosted elsewhere —
/// and the one place the rail's drag controller is handed down to the slots. The
/// play page hosts `ARPedalContentView` directly and so never supplies one, which
/// is what makes the slots' drop targets absent on a surface with no rail to drag
/// from, rather than present-but-useless.
struct ARPedalSetupView: View {
    @EnvironmentObject private var drag: RigDragController

    var body: some View {
        ARPedalContentView()
            .environment(\.rigDrag, drag)
    }
}

// MARK: - Shared content

struct ARPedalContentView: View {
    @EnvironmentObject var store: RigStore
    @StateObject private var detector = CameraStompDetector.shared

    /// Which empty slot is being filled, if any. Held HERE rather than in the slot
    /// so there is one picker for the page instead of three, and so presenting it
    /// never hangs off a view the anchored layout is repositioning 30×/second.
    @State private var picking: SlotIndex?

    /// Room the banner needs at the top, so an anchored slot can never be clamped up
    /// underneath it.
    private static let bannerReserve: CGFloat = 54

    var body: some View {
        GeometryReader { geo in
            // Landscape is short: give the slots what's left after the banner and
            // the ON/OFF captions, so the content fits whatever height the page is
            // given.
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
                                           placementIsGood: detector.state.placementIsGood,
                                           onAssign: { picking = SlotIndex(id: index) })
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
                                  topLimit: Self.bannerReserve,
                                  onAssign: { picking = SlotIndex(id: $0) })
                }
            }
        }
        .sheet(item: $picking) { slot in
            ARPedalPicker(index: slot.id)
                .environmentObject(store)
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
            return "Prop your phone facing your feet · tap or drag to fill a slot · stomp to toggle"
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
    let onAssign: (Int) -> Void

    var body: some View {
        if let points = layout.slots, points.count == 3 {
            ForEach(0..<3, id: \.self) { index in
                ARSlotView(index: index, height: slotHeight, placementIsGood: true,
                           onAssign: { onAssign(index) })
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
    /// Tapped while EMPTY — the page opens its pedal picker.
    var onAssign: () -> Void = {}
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
                        Text("Add pedal").font(.caption2)
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
            // An empty slot has nothing to toggle — `toggleARSlot` already no-ops
            // on one — so its tap is free to mean "put something here". An occupied
            // slot keeps the single tap that is the footswitch.
            if pedal == nil { onAssign() }
            else { withAnimation(.easeInOut(duration: 0.15)) { store.toggleARSlot(index) } }
        }
        // The drop target, registered while this slot is on screen. It replaces a
        // `.dropDestination(for: GearItem.self)` that had never once fired: the only
        // `.draggable` in the app is the library catalog card, and the library is a
        // sibling pager page that cannot be on screen at the same time as this one.
        // Keeping it would have left two drop paths on one view — a live one and an
        // unreachable one, both writing `targeted` — and the unreachable one is the
        // one that would quietly drift out of step.
        .background { SlotDropArea(index: index, targeted: $targeted) }
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

// MARK: - One slot's drop area

/// Registers one slot with the rail's drag controller for as long as it is on
/// screen, and reports the finger arriving and leaving.
///
/// A leaf view, and the ONLY thing on this page that touches the controller: the
/// controller republishes on every finger move, so an observer up at slot level
/// would redraw three pieces of gear artwork over a live camera preview per move.
/// This redraws `Color.clear`.
///
/// It registers the frame the slot ACTUALLY renders at, which is what makes an
/// anchored slot register its clamped position rather than the raw projected one:
/// a footswitch that ARKit has pushed off the edge of the screen is one the player
/// cannot see, and must not be able to drop onto.
private struct SlotDropArea: View {
    @EnvironmentObject private var store: RigStore
    @Environment(\.rigDrag) private var drag: RigDragController?
    let index: Int
    @Binding var targeted: Bool

    @State private var area = RigDropArea()

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    area.frame = proxy.frame(in: .named("appRoot"))
                    // Pedals only. Refusing an amp here means it never highlights
                    // the slot and never lands in it — a footswitch onto an amp is
                    // not a thing the audio path can express.
                    // Pedals only, and only a drag that is looking for somewhere
                    // to land — including one lifted off another slot, which is
                    // how a footswitch gets moved.
                    area.accepts = { item, origin in
                        guard item.category.isPedal else { return false }
                        if case .stage = origin { return false }
                        return true
                    }
                    area.onHover = { _, _, _ in
                        guard !targeted else { return }
                        withAnimation(.easeOut(duration: 0.12)) { targeted = true }
                    }
                    area.onExit = {
                        guard targeted else { return }
                        withAnimation(.easeOut(duration: 0.12)) { targeted = false }
                    }
                    // `setARSlot` owns the rules — binding defaults the slot ON, and
                    // a pedal that isn't in the chain is added to it first. Both are
                    // load-bearing for the audio path, so they are not restated here.
                    area.onDrop = { item, _ in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            store.setARSlot(index, pedalId: item.id)
                        }
                    }
                    drag?.register(area)
                }
                .onChange(of: proxy.frame(in: .named("appRoot"))) { _, frame in
                    area.frame = frame
                }
                .onDisappear { drag?.deregister(area) }
        }
    }
}

// MARK: - Picking a pedal with no rail to drag from

/// Which slot the picker is filling. A sheet needs an `Identifiable`, and the
/// index is the identity.
private struct SlotIndex: Identifiable { let id: Int }

/// The pedal picker for an empty slot. Pure SwiftUI over `RigStore` — no camera,
/// no ARKit — so it works on every surface this page is hosted on, including the
/// play page (which has no rail, and therefore no drag) and the Simulator.
///
/// Pedals already in the rig come first, because a footswitch is FOR a pedal that
/// is in the chain; the rest of the collection follows and gets added on the way in.
/// A pedal already wired to another switch says so on its face: `setARSlot` releases
/// that other slot, and a player who has just watched a switch go dark should have
/// seen it coming.
private struct ARPedalPicker: View {
    @EnvironmentObject var store: RigStore
    @Environment(\.dismiss) private var dismiss
    let index: Int

    private var inRig: [GearItem] { store.pedalItems }

    private var rest: [GearItem] {
        store.collection
            .filter { $0.category.isPedal && !store.rig.pedalIds.contains($0.id) }
            .sorted {
                $0.category.chainOrder != $1.category.chainOrder
                    ? $0.category.chainOrder < $1.category.chainOrder
                    : $0.name < $1.name
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // Landscape leaves barely 300pt of height, so the grid scrolls and the
            // cards stay big: this is read at arm's length at best, and from
            // standing height at worst.
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if inRig.isEmpty && rest.isEmpty {
                        Text("No pedals in your collection yet — add some from the gear library.")
                            .font(.callout)
                            .foregroundStyle(RigTheme.textMuted)
                            .padding(.top, 24)
                    }
                    section("IN YOUR RIG", pedals: inRig)
                    section("YOUR COLLECTION", pedals: rest)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(RigTheme.background)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SWITCH \(index + 1)")
                    .font(.caption2.weight(.bold))
                    .tracking(1.5)
                    .foregroundStyle(RigTheme.amber)
                Text("Pick a pedal")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(RigTheme.textPrimary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(RigTheme.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func section(_ title: String, pedals: [GearItem]) -> some View {
        if !pedals.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(RigTheme.trim.opacity(0.9))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 12)], spacing: 12) {
                    ForEach(pedals) { cell($0) }
                }
            }
        }
    }

    private func cell(_ pedal: GearItem) -> some View {
        let boundElsewhere = store.arSlots.firstIndex { $0.pedalId == pedal.id && $0.pedalId != nil }
            .flatMap { $0 == index ? nil : $0 }

        return Button {
            store.setARSlot(index, pedalId: pedal.id)
            dismiss()
        } label: {
            VStack(spacing: 8) {
                GearArtView(item: pedal)
                    .frame(width: pedal.category.artSize.width, height: pedal.category.artSize.height)
                    .frame(height: 58)
                Text(pedal.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(RigTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
                    .frame(height: 32)
                if let boundElsewhere {
                    Text("ON SWITCH \(boundElsewhere + 1) · MOVES HERE")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(RigTheme.background)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(RigTheme.amber))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .rigCard(cornerRadius: 14,
                     stroke: boundElsewhere == nil ? RigTheme.surfaceEdge : RigTheme.amber.opacity(0.5))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ARPedalSetupView()
        .environmentObject(RigStore.preview)
        .environmentObject(RigDragController())
        .preferredColorScheme(.dark)
}
