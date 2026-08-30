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
    /// Whether the pager is currently showing this page — see `ARCameraView.isActive`.
    /// Defaults true so the play page, which hosts the content directly and is only
    /// ever on screen when it is the thing being looked at, needs to say nothing.
    var isActive: Bool = true

    var body: some View {
        ARPedalContentView(isActive: isActive)
            .environment(\.rigDrag, drag)
    }
}

// MARK: - Shared content

struct ARPedalContentView: View {
    /// See `ARCameraView.isActive`. Only the camera feed reads it — the overlays are
    /// already cheap, and blanking them off-page would make a swipe show an empty
    /// board sliding away instead of the board.
    var isActive: Bool = true

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
    /// Running total of the calibration drag, so each change applies only the NEW
    /// movement. `DragGesture` reports translation from the START of the gesture, and
    /// feeding that straight in would re-apply the whole drag on every callback.
    @State private var lastCalibrationTranslation: CGFloat = 0
    /// The live placement angle while a calibration drag is in progress, for the
    /// readout.
    /// The board moves as you drag, which is the real feedback — but a number tells
    /// you when you have hit the end of the range, which a board that has simply
    /// stopped moving does not.
    @State private var calibrationHeight: Float?

    /// Room the banner needs at the top, so an anchored slot can never be clamped up
    /// underneath it.
    private static let bannerReserve: CGFloat = 54

    /// Which of the three switches currently hold a rocker. The detector needs this
    /// to stop a rocking foot from throwing phantom stomps at the pedals beside it.
    private var treadleSlotSet: Set<Int> {
        Set((0..<3).filter { store.arPedal($0)?.isTreadle == true })
    }

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
                FloorPedalsDriver(layout: detector.layout,
                                  pedals: floorPedals,
                                  hovered: detector.hoveredSlot)
                if anchored, let pad = detector.layout.switchPad {
                    SwitchPadView(pad: pad,
                                  armed: detector.treadleArmedSlot == pad.slot,
                                  turningOn: !store.arSlots[pad.slot].isOn,
                                  name: store.arPedal(pad.slot)?.name ?? "")
                        .position(pad.point)
                }
                if anchored {
                    FloorSlotChrome(layout: detector.layout,
                                    viewport: geo.size,
                                    armedSlot: detector.treadleArmedSlot,
                                    armProgress: detector.treadleArmProgress,
                                    onAssign: { picking = SlotIndex(id: $0) })
                }

                // Where the last placement tap went, and whether it took. Keyed by
                // the mark's id so a second tap in the same spot replays rather than
                // sitting there already-finished — see `ARTapMark`.
                if let tap = detector.lastTap {
                    ARTapRipple(mark: tap).id(tap.id)
                }

                // The prop-height readout, only while a calibration drag is running.
                if let height = calibrationHeight {
                    VStack(spacing: 3) {
                        Text("BOARD POSITION")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(1.0)
                            .foregroundStyle(RigTheme.textMuted)
                        Text(String(format: "%.0f°", height * 180 / .pi))
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(RigTheme.textPrimary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.6)))
                    .allowsHitTesting(false)
                }

                // The camera flip. It NAMES the mode rather than just showing an
                // icon, because the two modes behave differently enough that "which
                // one am I in" is a real question: front places itself and has no
                // detected floor, rear wants a tap and does. An unlabelled flip icon
                // would leave the player guessing why tapping did or did not work.
                if detector.state.isCameraLive {
                    Button { detector.flipCamera() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.2.circlepath.camera")
                                .font(.system(size: 12, weight: .semibold))
                            Text(detector.facing == .front ? "FRONT" : "REAR")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.6)
                        }
                        .foregroundStyle(RigTheme.textMuted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(.black.opacity(0.45)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                    }
                    .padding(.trailing, 14)
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
        }
        .sheet(item: $picking) { slot in
            ARPedalPicker(index: slot.id)
                .environmentObject(store)
        }
        .onAppear {
            // THE TREADLE. The detector reports a foot's height over a slot; what
            // that MEANS is decided here, because this is the layer that knows what
            // kind of pedal is in the slot. On a rocker it is the treadle angle; on
            // anything else a foot riding high over a pedal means nothing at all, and
            // silently driving some other pedal's first knob with it would be a
            // genuinely baffling bug to chase.
            //
            // Every pedal with a rocker answers to this — the wahs, both volume
            // pedals and the pitch treadle — because `isTreadle` asks the pedal for its
            // controls rather than naming categories. It read `category == .wah`
            // when only the wahs had art for it, which left a player standing on a
            // volume pedal watching nothing happen.
            //
            // Gated on the pedal being ON, exactly as the hardware is: a bypassed wah
            // does not sweep, and a player resting a foot on a pedal they have not
            // switched on should not be changing its tone.
            detector.onTreadle = { slot, position in
                guard let pedal = store.arPedal(slot), pedal.isTreadle,
                      store.arSlots[slot].isOn else { return }
                store.setARSlotParameter(slot, GearItem.treadleParameter,
                                         position * pedal.treadleMax)
            }
            // A STOMP DOES NOT SWITCH A TREADLE PEDAL. On a footswitch pedal the
            // stamp IS the switch and this is the whole feature. On a rocker the foot
            // LIVES on the pedal — rocking it heel-to-toe is the normal way to play
            // one — and every press of the toe down reads to the tracker exactly like
            // a stamp. Left wired up, sweeping a wah switched it off mid-phrase.
            //
            // Vision cannot tell the two apart: it reports the ANKLE, and the toe
            // press that works a real wah's switch barely moves the ankle at all. So
            // the switch moves to a control the player aims at deliberately — the
            // switch pad out on the empty floor — and the foot means
            // only "sweep", which is the one thing it can say unambiguously.
            // THE ROCKER'S OWN SWITCH. Push the toe past the end of the sweep and the
            // pedal flips — the pedal is split in two, the inner travel doing the
            // sweeping and the far end doing the switching, exactly as the casting of
            // a real wah is. The side button stays for setting a pedal up by hand,
            // but it needs a HAND, and a player standing behind a guitar has only
            // feet to spare.
            detector.onTreadleSwitch = { slot in
                guard store.arPedal(slot)?.isTreadle == true else { return }
                withAnimation(.easeInOut(duration: 0.15)) { store.toggleARSlot(slot) }
                floorPedals.burst(slot: slot, engaged: store.arSlots[slot].isOn)
            }
            detector.onStomp = { slot in
                guard store.arPedal(slot)?.isTreadle != true else { return }
                withAnimation(.easeInOut(duration: 0.15)) { store.toggleARSlot(slot) }
                // AFTER the toggle, so the burst shows the state the pedal ended up
                // in rather than the one it was leaving. Fired here rather than from
                // the detector because what is worth confirming is the pedal
                // CHANGING — a stamp the store declined must light nothing up.
                floorPedals.burst(slot: slot, engaged: store.arSlots[slot].isOn)
            }
            detector.treadleSlots = treadleSlotSet
            detector.start()
        }
        .onChange(of: treadleSlotSet) { _, slots in
            // The rig can change under the AR page (the board and these switches are
            // the same three pedals now), so this cannot be set once at start-up.
            detector.treadleSlots = slots
        }
        .onDisappear {
            detector.stop()
            // The session outlives this page — the other host may still be showing
            // it — so the nodes have to come out rather than be left parented to a
            // scene the next host will reuse.
            floorPedals.detach()
        }
    }

    /// Only front mode has a guess to correct, and only while it is actually showing
    /// a board — dragging at a grey searching screen would silently change a number
    /// with nothing on screen to show for it.
    private var calibrationEnabled: Bool {
        detector.facing.placesAutomatically && detector.state == .locked
    }

    /// How much placement angle one point of vertical drag is worth. The useful range
    /// is 4°–30° across a ~370-point viewport, so this spends a full-height drag on
    /// roughly the whole range and leaves room to be precise in the middle. Dragging
    /// DOWN increases the angle, which moves the board DOWN the frame — the gesture
    /// follows the thing rather than the number behind it.
    private static let calibrationRadiansPerPoint: Float = 0.0009

    private var calibrationDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard calibrationEnabled else { return }
                // Vertical drags only. A mostly-sideways drag on this page is somebody
                // trying to page away, and stealing it would trap them here.
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                let delta = Float(value.translation.height - lastCalibrationTranslation)
                lastCalibrationTranslation = value.translation.height
                calibrationHeight = ARFloorCalibration.adjust(by: delta * Self.calibrationRadiansPerPoint)
            }
            .onEnded { _ in
                lastCalibrationTranslation = 0
                calibrationHeight = nil
                ARDiagnostics.log("calib set height="
                                + "\(ARDiagnostics.f(ARFloorCalibration.placementDegrees, 1))° — remembered")
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
                         isActive: isActive,
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
                // DRAG UP AND DOWN TO SIT THE BOARD ON THE FLOOR.
                //
                // Front mode's one guess is how high the phone is propped, and this is
                // where the player corrects it. Vertical only, and only in front mode:
                // the pager owns horizontal drags on this page, and rear mode has a
                // measured plane and nothing to correct.
                //
                // The correction persists (`ARFloorCalibration`), so this is a
                // once-per-setup gesture rather than something to redo every session —
                // which is the closest thing this mode has to remembering a placement.
                .highPriorityGesture(calibrationDrag, including: calibrationEnabled ? .all : .subviews)
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

    /// FRONT MODE NEVER SAYS "TAP", because in front mode there is nothing to tap and
    /// nobody within reach to tap it. The instruction that replaces it is the one the
    /// player can actually follow from where they are standing: prop it and wait.
    /// Rear mode keeps every word it had.
    private var bannerText: String {
        let auto = detector.facing.placesAutomatically
        switch detector.state {
        case .searching(.lookingForFloor):
            return auto ? "Getting its bearings — hold the phone steady"
                        : "Looking for the floor — aim at your feet"
        case .searching(.holdStill):       return "Hold still"
        case .searching(.aimLower):        return "Aim lower, toward your feet"
        case .ready:
            return auto ? "Placing your pedals…" : "Tap the floor to place your pedals"
        case .locked:                      return "Locked in · stomp a slot to toggle"
        case .lost:
            // NAMES THE REASON. "Phone moved" was hardcoded and is one of seven
            // things that end a lock; saying it for all of them sent a player
            // chasing a phone that had not moved.
            let why = detector.lastUnlockReason ?? "phone moved"
            return auto ? "Lost the board (\(why)) — set it down and it will re-place"
                        : "Lost the board (\(why)) — tap the floor to re-place"
        default:
            // .idle / .unsupported / .denied / .running: nothing is being placed, so
            // the banner goes back to being the page's instructions.
            return auto ? "Prop your phone facing your feet · stomp to toggle"
                        : "Prop your phone facing your feet · tap or drag to fill a slot · stomp to toggle"
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
    /// Which slot the foot is over. Passed in rather than observed here so this view
    /// keeps re-rendering only on the three things it already watched.
    let hovered: Int?

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: layout.floor) { _, _ in push() }
            .onChange(of: store.arSlots) { _, _ in push() }
            .onChange(of: hovered) { _, _ in push() }
            .onAppear { push() }
    }

    private func push() {
        pedals.update(floor: layout.floor,
                      pedals: (0..<3).map { store.arPedal($0) },
                      engaged: (0..<3).map { store.arSlots[$0].isOn },
                      hovered: hovered)
    }
}

/// The mark a placement tap leaves: a ring that expands and fades from the point the
/// finger actually landed.
///
/// COLOUR CARRIES THE OUTCOME, and it borrows the page's existing vocabulary rather
/// than inventing one. Green is already the page's single promise that a spot works,
/// so a tap that placed the board is green. A tap that did NOT — no plane under that
/// pixel, or the page was not `.ready` — is `clip` red, which this page uses for
/// nothing else and so cannot be confused with the amber that means a pedal is on.
///
/// Non-interactive on purpose: it is drawn over a camera feed whose whole surface is
/// the placement target, and a ring that swallowed the next tap would make a missed
/// tap harder to correct at exactly the moment the player is trying to correct it.
private struct ARTapRipple: View {
    let mark: ARTapMark
    @State private var expanded = false

    var body: some View {
        Circle()
            .strokeBorder(mark.landed ? RigTheme.ready : RigTheme.clip, lineWidth: 2.5)
            .frame(width: 30, height: 30)
            .scaleEffect(expanded ? 2.4 : 0.5)
            .opacity(expanded ? 0 : 0.95)
            .position(mark.point)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 0.5)) { expanded = true }
            }
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
    /// Which treadle the foot is standing on the switch half of, if any, and how far
    /// through the hold it has got.
    let armedSlot: Int?
    let armProgress: Double
    let onAssign: (Int) -> Void

    var body: some View {
        if let points = layout.slots, points.count == 3 {
            ForEach(0..<3, id: \.self) { index in
                if visible(points[index]) {
                    ARFloorSlotView(index: index,
                                    armed: armedSlot == index,
                                    armProgress: armProgress,
                                    onAssign: { onAssign(index) })
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
    /// Foot is on this pedal's switch half — hold it there and the pedal flips.
    var armed: Bool = false
    /// 0…1 through the hold that commits the switch.
    var armProgress: Double = 0
    let onAssign: () -> Void

    @State private var targeted = false
    @State private var held = false

    var body: some View {
        let pedal = store.arPedal(index)
        let on = store.arSlots[index].isOn && pedal != nil
        // A rocker has NO switch on its own chrome — its on/off is the pad out on the
        // empty floor beside the board. A footswitch pedal's is the whole label,
        // tapped anywhere.
        let treadle = pedal?.isTreadle == true
        // 0…1 for the bar. The store is the one place the foot's readings land, so
        // reading it back here means the bar cannot disagree with what the DSP got.
        let position = (pedal?.values[GearItem.treadleParameter] ?? 0) / (pedal?.treadleMax ?? 10)

        VStack(spacing: 8) {
            if let pedal {
                // THE STATE INDICATOR, AND IT IS THE BIGGEST THING ON THE PAGE.
                //
                // It was an 8-POINT DOT beside a caption. That is a control-panel
                // size, and this is not a control panel — it is read from standing
                // height, several feet back, mid-song, by someone whose eyes are on
                // their hands. At that distance an 8pt dot is not small, it is absent.
                // The one question this page has to answer at a glance for three
                // pedals at once is "which of these are on", so that answer gets the
                // largest, brightest object here and everything else arranges itself
                // around it.
                ZStack {
                    Circle()
                        .fill(on ? RigTheme.amber : Color(white: 0.16))
                        .overlay(
                            Circle().strokeBorder(on ? RigTheme.amber.opacity(0.9)
                                                     : Color(white: 0.42),
                                                  lineWidth: 3)
                        )
                        // A real glow when lit, so it reads as EMITTING rather than as
                        // a painted orange disc — the difference carries at distance
                        // where the fill colour alone starts to wash out.
                        .shadow(color: on ? RigTheme.amber.opacity(0.85) : .clear, radius: 14)
                        .shadow(color: on ? RigTheme.amber.opacity(0.5) : .clear, radius: 26)
                    Text(on ? "ON" : "OFF")
                        .font(.system(size: on ? 20 : 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(on ? Color.black.opacity(0.82) : Color(white: 0.62))
                }
                .frame(width: treadle ? 0 : 62, height: treadle ? 0 : 62)
                .opacity(treadle ? 0 : 1)
                .animation(.easeOut(duration: 0.14), value: on)
                // THE SWITCH, MOVED OUT OF THE FOOT'S WAY.
                //
                // A rocker pedal is played with the foot ON it, so the space directly
                // above it — where this lamp sits for every other pedal — is exactly
                // where the player's boot and shin are. Leaving the switch there gave
                // it two ways to fire by accident: a stray tap while lining the foot
                // up, and the stomp detector reading a toe press as a stamp (now
                // suppressed; see `onStomp`). Pushed to the trailing edge it is a
                // deliberate reach sideways, away from the pedal, which is the whole
                // point — switching a wah on is a decision, not something that should
                // happen because you rested your foot.
                //
                // Trailing for all three slots rather than mirrored outward, because
                // a control you hit mid-song wants to be in the SAME place every
                // time more than it wants to be symmetrical. If it turns out to fall
                // under the strumming hand, the alternative is one `Spacer` swap.
                // NO LAMP ON A ROCKER. Its on/off is the pad out on the empty floor,
                // and a second switch on the pedal itself was two controls for one
                // fact — the pad already shows the state, in the same amber.


                Text(pedal.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(RigTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black, radius: 3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.68)))
                    .overlay(Capsule().strokeBorder(targeted ? RigTheme.amber : .clear, lineWidth: 2))

                // WHERE THE TREADLE IS. Without it the sweep is invisible: the foot
                // is doing something continuous and the only feedback is the sound,
                // so there is no way to tell "my foot is not moving the pedal" from
                // "the pedal is moving and I cannot hear it" — which is exactly the
                // pair that had to be told apart to find the band was mistuned.
                //
                // Only while the pedal is ON, because that is the only time the foot
                // is actually driving it (`onTreadle` is gated the same way). A bar
                // tracking a bypassed pedal would promise control that is not there.
                if treadle {
                    TreadlePositionBar(position: position, armed: armed,
                                       armProgress: armProgress, live: on)
                }
            } else {
                // An empty switch has a ring on the floor but nothing above it, so
                // the invitation has to be here — and at the same scale as the rest,
                // or an empty slot reads as a broken one from across the room.
                Label("Add pedal", systemImage: "plus.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(targeted ? RigTheme.amber : RigTheme.textMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.68)))
                    .overlay(Capsule().strokeBorder(targeted ? RigTheme.amber : .clear, lineWidth: 2))
            }
        }
        .opacity(held ? 0 : 1)
        .frame(width: 190)
        .contentShape(Rectangle())
        .arSlotInteraction(index: index, pedal: pedal, cornerRadius: 22,
                           ringInsets: EdgeInsets(top: -8, leading: 8, bottom: 16, trailing: 8),
                           held: $held, targeted: $targeted,
                           // A rocker keeps its switch on the side button alone. Tap
                           // anywhere on the chrome and nothing happens, which is
                           // what makes the button "deliberate" rather than merely
                           // "also available". The HOLD still lifts the pedal off.
                           togglesOnTap: !treadle,
                           onAssign: onAssign)
    }
}

/// The rocker's switch, standing on the empty floor beside the board.
///
/// WHY IT IS NOT ON THE PEDAL. Three earlier versions carved the switch out of the
/// pedal's own travel — past the toe, behind the heel, past the toe again with a
/// hold — and each traded one failure for another, because the sweep and the switch
/// were competing for the same few centimetres of foot movement. Past the toe it
/// fired during ordinary playing; behind the heel it was unreachable, the floor
/// being in the way.
///
/// Sideways is not scarce. The board projects small, there is floor either side of it
/// doing nothing, and a foot that steps off the pedal onto that floor is
/// unambiguously not sweeping. So the switch is its own PLACE, and stamping it is an
/// ordinary stomp — the gesture this whole page was built around in the first place.
private struct SwitchPadView: View {
    let pad: SwitchPad
    /// A foot is standing on it.
    let armed: Bool
    let turningOn: Bool
    let name: String

    private static let size: CGFloat = 88
    private static let lineWidth: CGFloat = 8

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // The target, drawn whether or not a foot is near it: a switch you
                // cannot see is one the player has to remember the location of.
                // AMBER WHEN THE PEDAL IS ON, dark when it is off — the same word
                // this page uses everywhere else for "this pedal is engaged", so the
                // switch reads as the pedal's own state rather than as a button that
                // happens to sit near it. `turningOn` is what the NEXT stomp will do,
                // so the pedal is currently on exactly when it is false.
                let lit = !turningOn
                Circle()
                    .fill(lit ? RigTheme.amber.opacity(armed ? 0.95 : 0.85)
                              : .black.opacity(armed ? 0.5 : 0.35))
                    .shadow(color: lit ? RigTheme.amber.opacity(0.7) : .clear, radius: 16)
                    .overlay(Circle().strokeBorder(lit ? .white.opacity(0.5)
                                                       : .white.opacity(armed ? 0.35 : 0.18),
                                                   lineWidth: 2))
                if armed {
                    // A full ring, not a filling one. There is nothing to wait out
                    // now — stepping on the pad IS the switch — so a progress arc
                    // would be animating a commitment that already happened.
                    Circle()
                        .stroke(lit ? Color.black.opacity(0.75) : RigTheme.amber,
                                style: StrokeStyle(lineWidth: Self.lineWidth))
                        .shadow(color: lit ? .clear : RigTheme.amber.opacity(0.9), radius: 12)
                }
                VStack(spacing: 2) {
                    Text(armed ? "SWITCHED" : "SWITCH")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.9)
                        .foregroundStyle(lit ? .black.opacity(0.7) : RigTheme.textMuted)
                    Text(turningOn ? "OFF" : "ON")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(lit ? .black.opacity(0.85)
                                             : (armed ? RigTheme.amber : RigTheme.textPrimary))
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                .shadow(color: lit ? .clear : .black, radius: 4)
                .padding(.horizontal, 10)
            }
            .frame(width: Self.size, height: Self.size)
            .scaleEffect(armed ? 1.06 : 1)

            if !name.isEmpty {
                Text(name)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(RigTheme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.68)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: armed)
        .allowsHitTesting(false)
    }
}

/// The hold that switches a rocker, drawn big enough to read from where the player
/// is actually standing.
///
/// A RING, not a bar: it is reporting a COMMITMENT rather than a position, and the
/// page already spends its horizontal vocabulary on the sweep. A ring closing on
/// itself says "this is filling up and then something happens", which is the whole
/// message, and it says it from across a room.
///
/// It also names the OUTCOME — TURNING ON versus TURNING OFF — because at the moment
/// the ring is filling, that is the one thing the player still has time to change
/// their mind about.
private struct TreadleChargeRing: View {
    let armed: Bool
    /// 0…1 through the hold.
    let progress: Double
    /// Which way this press will flip the pedal.
    let turningOn: Bool

    private static let size: CGFloat = 132
    private static let lineWidth: CGFloat = 11

    var body: some View {
        if armed {
            let p = min(1, max(0, progress))
            ZStack {
                Circle()
                    .stroke(Color.black.opacity(0.55), lineWidth: Self.lineWidth)
                Circle()
                    .trim(from: 0, to: p)
                    .stroke(RigTheme.amber,
                            style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                    // Starts at the top and closes clockwise, which is the direction
                    // a filling thing is read in.
                    .rotationEffect(.degrees(-90))
                    .shadow(color: RigTheme.amber.opacity(0.9), radius: 12)

                VStack(spacing: 2) {
                    Text(turningOn ? "TURNING" : "TURNING")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(RigTheme.textMuted)
                    Text(turningOn ? "ON" : "OFF")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(RigTheme.amber)
                }
                .shadow(color: .black, radius: 4)
            }
            .frame(width: Self.size, height: Self.size)
            // Swells as it fills, so the commitment is legible from the corner of an
            // eye without reading the number.
            .scaleEffect(0.86 + 0.14 * p)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }
}

/// Where the treadle is sitting, 0 (heel) to 1 (toe).
///
/// Sized to be read from standing height like everything else on this page — a
/// hairline progress view would be invisible at the distance this is used from. The
/// fill is the same amber as the ON lamp because they are describing the same pedal.
private struct TreadlePositionBar: View {
    /// 0…1. Clamped rather than trusted: it is a knob value divided by a range, and
    /// a bar that draws outside its own track on an unexpected value is a worse
    /// failure than one that saturates.
    let position: Double
    /// The foot is pressed past the toe end, on the switch. Drawn as a cap on the
    /// RIGHT of the track, because that is where it is on the floor: the bar IS the
    /// pedal seen side-on, heel at the left, toe at the right, and the switch sits
    /// past the toe where only a deliberate press-and-hold reaches.
    let armed: Bool
    /// 0…1 through the hold. Drawn as the cap filling, so the player can see the
    /// commit coming and step off it if they did not mean it.
    let armProgress: Double
    /// Whether the pedal is switched on. The bar stays visible either way — knowing
    /// where the treadle is sitting is how you decide whether to switch it on — but
    /// a bypassed pedal's sweep is dimmed, because the foot is not driving anything.
    let live: Bool

    private static let width: CGFloat = 132
    private static let height: CGFloat = 11
    private static let cap: CGFloat = 22

    var body: some View {
        let fill = min(1, max(0, position))
        VStack(spacing: 4) {
            HStack(spacing: 3) {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.black.opacity(0.72))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    Capsule()
                        .fill(RigTheme.amber)
                        .shadow(color: RigTheme.amber.opacity(live ? 0.7 : 0), radius: 6)
                        .frame(width: max(Self.height, Self.width * fill))
                        .opacity(live ? 1 : 0.35)
                }
                .frame(width: Self.width, height: Self.height)

                // The switch, PAST the toe — rightmost, matching the floor.
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(white: 0.20))
                        .overlay(Capsule().strokeBorder(armed ? .white.opacity(0.9)
                                                              : .white.opacity(0.22),
                                                        lineWidth: armed ? 2 : 1))
                    if armed {
                        Capsule()
                            .fill(RigTheme.amber)
                            .shadow(color: RigTheme.amber.opacity(0.9), radius: 10)
                            .frame(width: max(3, Self.cap * min(1, max(0, armProgress))))
                    }
                }
                .frame(width: Self.cap, height: Self.height)
            }
            Text(armed ? "HOLD TO SWITCH" : "HEEL \(Int((fill * 100).rounded()))% TOE   SWITCH →")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(armed ? RigTheme.amber : RigTheme.textMuted)
                .shadow(color: .black, radius: 2)
        }
        // The value changes at the tracker's rate; animating each step would put the
        // bar permanently behind the foot it is reporting on. The ARM is a discrete
        // event a couple of times per press, so that one does animate.
        .animation(nil, value: fill)
        .animation(nil, value: armProgress)   // the hold IS the timer; do not lag it
        .animation(.easeOut(duration: 0.12), value: armed)
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
        .arSlotInteraction(index: index, pedal: pedal, cornerRadius: 23,
                           ringInsets: EdgeInsets(top: -5, leading: -5, bottom: 17, trailing: -5),
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
                           ringInsets: EdgeInsets, held: Binding<Bool>,
                           targeted: Binding<Bool>,
                           togglesOnTap: Bool = true,
                           onAssign: @escaping () -> Void) -> some View {
        modifier(ARSlotInteraction(index: index, pedal: pedal, cornerRadius: cornerRadius,
                                   ringInsets: ringInsets, held: held,
                                   targeted: targeted, togglesOnTap: togglesOnTap,
                                   onAssign: onAssign))
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
    /// Where the ring sits relative to the hit area's edge. NEGATIVE values push it
    /// outward, which is what the sides and top use: the ring rides just OUTSIDE the
    /// slot's own border with a couple of points of dark between them, where nothing
    /// competes with it. Drawn on the border it was fighting the slot's stroke and
    /// its artwork and barely registered. The bottom stays positive because the hit
    /// area deliberately extends over the ON/OFF caption, which the ring must clear.
    let ringInsets: EdgeInsets
    @Binding var held: Bool
    @Binding var targeted: Bool
    /// Whether tapping the chrome flips the pedal. False for a treadle, whose switch
    /// is the pad on the floor beside the board.
    var togglesOnTap: Bool = true
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

    /// The chrome-wide tap, attached ONLY when it has work to do.
    ///
    /// Not merely guarded-and-inert for a treadle: an `.onTapGesture` on the
    /// ancestor is still a gesture competing for the touch, and the treadle's
    /// switch is a `Button` INSIDE this view. Relying on the child winning that
    /// race would be betting the one control that turns a wah on against SwiftUI's
    /// gesture-resolution order, on a page that cannot be exercised anywhere but a
    /// real device. Not attaching it at all is not a bet.
    @ViewBuilder
    private func chromeTap(_ view: some View) -> some View {
        if tapDoesSomething {
            view.onTapGesture {
                guard !held else { return }
                if pedal == nil {
                    onAssign()
                } else {
                    withAnimation(.easeInOut(duration: 0.15)) { store.toggleARSlot(index) }
                }
            }
        } else {
            view
        }
    }

    /// Whether a tap on the chrome as a whole has anything to do. An empty slot
    /// opens the picker; an occupied footswitch pedal flips. A treadle has neither
    /// job — its switch is the button off to the side.
    private var tapDoesSomething: Bool { pedal == nil || togglesOnTap }

    func body(content: Content) -> some View {
        chromeTap(content
            .scaleEffect(1 - 0.04 * charge)     // animates with `charge`, no second curve
            .overlay { holdRing })
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
            .stroke(RigTheme.amber, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            // Read at arm's length on a phone propped on the floor, over a live
            // camera feed — a hairline is not enough. The glow is what separates it
            // from whatever the camera happens to be pointing at.
            .shadow(color: RigTheme.amber.opacity(0.7), radius: 6)
            .padding(ringInsets)
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
                defer { endCharge() }
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

    /// The end of a hold, however it ended. UNCONDITIONAL, deliberately: it used to
    /// bail out while `held` was still set, and on the release path it runs before
    /// `held` is cleared — so a pedal put back in its slot kept a fully drawn ring
    /// around it for good. Nothing needs the charge to survive here; the slot is
    /// already invisible while the pedal is in the air, and the ring hides itself
    /// on `held` regardless.
    private func endCharge() {
        chargeTask?.cancel()
        chargeTask = nil
        charged = false
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

        let artFrame = GearArtFrame.size(for: pedal, base: pedal.category.artSize)

        return Button {
            store.setARSlot(index, pedalId: pedal.id)
            dismiss()
        } label: {
            VStack(spacing: 8) {
                GearArtView(item: pedal)
                    .frame(width: artFrame.width, height: artFrame.height)
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
            .rigCard(cornerRadius: RigTheme.Radius.control,
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
