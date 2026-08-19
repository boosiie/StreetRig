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
//  TAKING A PEDAL OFF is a hold-and-drag onto the trash, the same gesture the rail
//  and the rig board use, and it replaced a ✕ button — a 20pt target on a page read
//  from standing height, on a phone lying on the floor. What the trash MEANS here is
//  narrower than anywhere else: it clears the FOOTSWITCH only. The pedal stays owned
//  and stays in the chain, which is exactly what the ✕ did (`RigDragOrigin.arSlot`).
//
//  PLACEMENT READINESS. The slots outline GREEN once ARKit reports a real floor
//  below the phone, in view, with steady tracking — a promise that stomps will land.
//  Tapping the floor then pins the row to a world anchor, and the bottom row is
//  replaced by real pedals lying on the spot the player chose (`ARFloorPedals`).
//  Green never means "engaged"; engaged is amber, and the two have to be tellable
//  apart from standing height. All of it is driven by ONE value, `detector.state`.
//
//  LAYOUT, IN LANDSCAPE, WITH NO VERTICAL ROOM. The banner and the placeholder live
//  IN the layout flow rather than floating over it: as top-anchored overlays they
//  landed on the slots whenever the available height shifted, because a `Spacer` can
//  only absorb slack it can see.
//
//  ONCE ANCHORED, NOTHING IS CLAMPED, and that is a reversal. The old screen-space
//  slots were pulled back inside the viewport so they stayed tappable. A pedal that
//  is a real object on a real floor cannot be: its label would slide off it and sit
//  over empty carpet, which is a worse lie than being out of frame. Aim the phone
//  back at your feet and it comes back, the way the pedal does.
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

    /// The pedals as objects on the real floor. Held here for the life of the page
    /// so the node graph survives the camera view being handed over on every
    /// SwiftUI update pass — see `ARFloorPedals.attach(to:)`.
    @State private var floorPedals = ARFloorPedals()

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

                // The pedals themselves are SceneKit nodes on the floor (see
                // ARFloorPedals); what is drawn here is only the writing about them.
                FloorPedalsDriver(layout: detector.layout, pedals: floorPedals)
                if anchored {
                    FloorSlotChrome(layout: detector.layout,
                                    viewport: geo.size,
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
        .onDisappear {
            detector.stop()
            // The session outlives this page — the other host may still be showing
            // it — so the nodes have to come out rather than be left parented to a
            // scene the next host will reuse.
            floorPedals.detach()
        }
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
                         onView: {
                             detector.attach(feedView: $0)
                             floorPedals.attach(to: $0)
                         })
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

/// Keeps the SceneKit floor pedals in step with the anchor and the slot contents.
///
/// A view purely so it can observe: it draws nothing. The alternative — updating
/// the nodes from the page's own body — would tie a 3D refresh to every banner
/// change and every camera-state flip, and would miss the updates that matter
/// (the anchor being refined) because the page does not observe the layout.
private struct FloorPedalsDriver: View {
    @EnvironmentObject var store: RigStore
    @ObservedObject var layout: ARSlotLayout
    let pedals: ARFloorPedals

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: layout.floor) { _, _ in push() }
            .onChange(of: store.arSlots) { _, _ in push() }
            .onAppear { push() }
    }

    private func push() {
        pedals.update(floor: layout.floor,
                      pedals: (0..<3).map { store.arPedal($0) },
                      engaged: (0..<3).map { store.arSlots[$0].isOn })
    }
}

/// The writing about each floor pedal, tracking where that pedal is on screen.
///
/// Its own view observing its own object: the projected positions update up to
/// 30×/second, and routing that through the page's own state would re-render the
/// banner, the background and the placeholder alongside them — on the main thread,
/// next to a live neural amp.
///
/// NOT CLAMPED, deliberately, and this is a reversal of what it used to do. The
/// old screen-space slots were pulled back to the edge of the viewport so they
/// stayed tappable. A pedal that is a real object on a real floor cannot be: the
/// label would slide off the thing it names and sit over empty carpet, which is a
/// worse lie than being out of frame. Aim the phone back at your feet and it comes
/// back, the way the pedal itself does.
private struct FloorSlotChrome: View {
    @ObservedObject var layout: ARSlotLayout
    let viewport: CGSize
    let onAssign: (Int) -> Void

    var body: some View {
        if let points = layout.slots, points.count == 3 {
            ForEach(0..<3, id: \.self) { index in
                if visible(points[index]) {
                    ARFloorSlotView(index: index, onAssign: { onAssign(index) })
                        .position(points[index])
                }
            }
        }
    }

    /// Drawn only while its pedal is actually in frame. A little slack past the
    /// edge, so a label does not blink out the instant its pedal touches the bezel.
    private func visible(_ point: CGPoint) -> Bool {
        let slack: CGFloat = 60
        return point.x > -slack && point.x < viewport.width + slack
            && point.y > -slack && point.y < viewport.height + slack
    }
}

/// One floor pedal's chrome: what it is, whether it is on, and a handle to grab.
///
/// Compact on purpose. The pedal itself is a 3D object a foot or two away, so this
/// sits just above it and carries only what the object cannot say for itself at
/// that distance and that angle.
private struct ARFloorSlotView: View {
    @EnvironmentObject private var store: RigStore
    let index: Int
    let onAssign: () -> Void

    @State private var targeted = false
    @State private var held = false

    var body: some View {
        let pedal = store.arPedal(index)
        let on = store.arSlots[index].isOn && pedal != nil

        VStack(spacing: 5) {
            if let pedal {
                HStack(spacing: 5) {
                    Circle()
                        .fill(on ? RigTheme.amber : Color(white: 0.3))
                        .frame(width: 8, height: 8)
                        .shadow(color: on ? RigTheme.amber : .clear, radius: 4)
                    Text(pedal.name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(RigTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(.black.opacity(0.6)))
                .overlay(Capsule().strokeBorder(targeted ? RigTheme.amber : .clear, lineWidth: 2))

                Text(on ? "ON" : "OFF")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(on ? RigTheme.amber : RigTheme.textMuted)
                    .shadow(color: .black, radius: 3)
            } else {
                // An empty switch has a ring on the floor but nothing above it, so
                // the invitation has to be here.
                Label("Add pedal", systemImage: "plus.circle")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(targeted ? RigTheme.amber : RigTheme.textMuted)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .overlay(Capsule().strokeBorder(targeted ? RigTheme.amber : .clear, lineWidth: 2))
            }
        }
        .opacity(held ? 0 : 1)
        .frame(width: 132)
        .contentShape(Rectangle())
        .arSlotInteraction(index: index, pedal: pedal, cornerRadius: 16,
                           held: $held, targeted: $targeted, onAssign: onAssign)
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
    /// Held, and therefore in the air on its way to the trash: the slot goes
    /// invisible so the ghost under the finger is the only copy of it.
    @State private var held = false

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
            .shadow(color: on ? RigTheme.amber.opacity(0.45) : .clear, radius: 12)

            Text(pedal == nil ? "\(index + 1)" : (on ? "ON" : "OFF"))
                .font(.caption2.weight(.bold))
                .foregroundStyle(on ? RigTheme.amber : RigTheme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .opacity(held ? 0 : 1)
        .contentShape(Rectangle())
        .arSlotInteraction(index: index, pedal: pedal, cornerRadius: 18,
                           held: $held, targeted: $targeted, onAssign: onAssign)
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

// MARK: - What you can do to a slot, wherever it is drawn

extension View {
    /// Tap, drop-onto, and lift-off — the three things a footswitch does, attached
    /// identically to the bottom row and to a pedal on the floor. Shared so the two
    /// presentations cannot drift into behaving differently.
    func arSlotInteraction(index: Int, pedal: GearItem?, cornerRadius: CGFloat,
                           held: Binding<Bool>, targeted: Binding<Bool>,
                           onAssign: @escaping () -> Void) -> some View {
        modifier(ARSlotInteraction(index: index, pedal: pedal, cornerRadius: cornerRadius,
                                   held: held, targeted: targeted, onAssign: onAssign))
    }
}

/// TAP toggles an occupied switch and opens the picker on an empty one. HOLD lifts
/// the pedal off, which is how it now comes off — the ✕ button this replaced was a
/// 20pt target on a page read from standing height, and the app already had one
/// gesture for "pick gear up and put it somewhere else".
private struct ARSlotInteraction: ViewModifier {
    @EnvironmentObject private var store: RigStore
    @EnvironmentObject private var lift: ARSlotLift
    @Environment(\.rigDrag) private var drag: RigDragController?
    let index: Int
    let pedal: GearItem?
    /// Corner radius of the ring drawn around this slot while it charges — the
    /// bottom row is a rounded box, a floor pedal's label is a capsule.
    let cornerRadius: CGFloat
    @Binding var held: Bool
    @Binding var targeted: Bool
    let onAssign: () -> Void

    /// Parked out of reach until the pedal is held, so this gesture never claims a
    /// touch and the page swipe always wins — the same trick, for the same reason,
    /// as the rail card's lift. See GearCardView.liftDrag.
    private let unreachable: CGFloat = 10_000

    /// The charge waits, then runs; the two sum to the hold duration, exactly as
    /// the rail card's does. Same numbers on purpose — one "pick gear up" in the
    /// whole app means one length of hold and one animation for it.
    private let chargeDelay: Duration = .milliseconds(80)
    private let chargeFill: TimeInterval = 0.17

    /// 0…1 across the hold, driving the ring AND the squeeze from one value.
    @State private var charge: CGFloat = 0
    @State private var chargeTask: Task<Void, Never>?
    /// Flipped by the charge animation finishing, not by the press timer — see
    /// `beginCharge`.
    @State private var charged = false
    @State private var pressing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - 0.04 * charge)     // animates with `charge`, no second curve
            .overlay { holdRing }
            .onTapGesture {
                guard !held else { return }
                if pedal == nil {
                    onAssign()
                } else {
                    withAnimation(.easeInOut(duration: 0.15)) { store.toggleARSlot(index) }
                }
            }
            // Only an OCCUPIED slot can be lifted: there is nothing to carry off an
            // empty one, and arming the gesture there would just make its tap late.
            .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 10) {
                guard pedal != nil else { return }
                held = true
                // Freeze the pager BEFORE the finger moves — by the time the drag
                // has travelled far enough to recognise, the swipe it would be
                // mistaken for has already started.
                lift.armed = true
            } onPressingChanged: { isPressing in
                pressing = isPressing
                if isPressing {
                    guard pedal != nil else { return }
                    beginCharge()
                    return
                }
                endCharge()
                // The drag below may never reach its threshold, so lifting the
                // finger here is the only guaranteed end: without it a
                // hold-and-release strands the ghost and leaves the pager frozen.
                if held && drag?.item == nil {
                    held = false
                    lift.armed = false
                }
            }
            // SIMULTANEOUS, exactly as the rail card attaches its own lift, and not
            // high-priority. A high-priority drag was tried and is wrong here: a
            // synthetic tap has zero travel so it looked fine, but a real finger
            // always moves a few points, and the high-priority drag can claim that
            // touch and swallow the tap — taking tap-to-toggle and tap-to-pick with
            // it. The pager is kept off this drag by `ARSlotLift` instead, which is
            // the same move the rail makes by disabling its ScrollView.
            .simultaneousGesture(liftDrag)
            // At 0.25s the hold is too short to be sure of by eye, so the thump is
            // what says the pedal is actually in your hand — on the frame the ring
            // closes, which is why it triggers off `charged`.
            .sensoryFeedback(.impact(weight: .medium, intensity: 0.8), trigger: charged) { _, done in done }
            .background { SlotDropArea(index: index, targeted: $targeted) }
    }

    /// Fills over the hold, so an aborted press shows a half-drawn ring — which
    /// teaches "too early" rather than "nothing happened". The rail card's ring,
    /// on a slot.
    private var holdRing: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .trim(from: 0, to: charge)
            .stroke(RigTheme.amber, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .opacity(held ? 0 : 1)
            .animation(.easeOut(duration: 0.14), value: held)
            .allowsHitTesting(false)
    }

    /// MEASURED IN THE WINDOW, then converted — never in `.named("appRoot")`.
    ///
    /// A slot lives inside the shell's paged TabView, and a named coordinate space
    /// does not resolve across that bridge: the gesture quietly reports points in
    /// the slot's OWN space instead, which put the ghost in the top-left corner of
    /// the screen the moment a pedal was picked up. `.global` always resolves, and
    /// `appRootPoint` is the conversion the 3D stage's lift already uses for exactly
    /// this reason.
    private var liftDrag: some Gesture {
        DragGesture(minimumDistance: held ? 20 : unreachable, coordinateSpace: .global)
            .onChanged { move in
                guard held, let drag, let pedal else { return }
                let point = drag.appRootPoint(fromWindow: move.location)
                // `.arSlot` origin: the trash takes this OFF THE SWITCH and nothing
                // more — the pedal keeps its place in the chain and stays owned.
                if drag.item == nil { drag.begin(pedal, at: point, from: .arSlot(index)) }
                else { drag.move(to: point) }
            }
            .onEnded { move in
                guard held, let drag else { return }
                held = false
                lift.armed = false
                endCharge()
                guard drag.item?.id == pedal?.id else { return }
                drag.move(to: drag.appRootPoint(fromWindow: move.location))
                drag.end()
            }
    }

    private func beginCharge() {
        chargeTask?.cancel()
        charged = false
        chargeTask = Task { @MainActor in
            try? await Task.sleep(for: chargeDelay)
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: chargeFill)) {
                charge = 1
            } completion: {
                // Fired by the animation finishing rather than the press timer, so
                // the thump lands on the frame the eye sees the ring close. The
                // guard keeps an aborted hold silent.
                guard pressing else { return }
                charged = true
            }
        }
    }

    /// The abort/finish path. A successful hold keeps its charge up until the pedal
    /// is put down, so nothing springs back at the instant of success.
    private func endCharge() {
        chargeTask?.cancel()
        chargeTask = nil
        charged = false
        guard !held else { return }
        withAnimation(.easeOut(duration: 0.12)) { charge = 0 }
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
                    // WINDOW space, converted on read — a named space does not
                    // resolve across the shell's paged TabView, so measuring in
                    // "appRoot" here silently returns something else. Same reason
                    // the lift gesture measures globally. See RigDropArea.Space.
                    area.space = .window
                    area.frame = proxy.frame(in: .global)
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
                .onChange(of: proxy.frame(in: .global)) { _, frame in
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
