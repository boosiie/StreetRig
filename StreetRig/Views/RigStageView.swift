//
//  RigStageView.swift
//  StreetRig
//
//  The center stage. With 3D enabled the whole rig is one SceneKit diorama
//  (RigStage3DView) — amp centered, pedalboard in front, guitar to the right —
//  that you orbit as a single scene. With 3D off (or a combo amp) it falls back
//  to the flat vector layout: amp head + cabinet + pedalboard centered, a guitar
//  on a stand to the right, drag to tilt up to ~20° and rubber-band back. Tap a
//  component to zoom in. Drop a collection card on it to swap that part, or
//  long-press a pedal and pull it onto the rail's trash to take it off the board
//  (the gear stays owned — that is NOT the rail's delete).
//
//  Also home to the no-amp warning: `store.hasAmp` goes false the moment the
//  last amp is deleted, and this is the surface where the player will be
//  looking for the reason nothing works.
//

import SwiftUI
import StreetRigEngine

/// Which rig part is in focus (for the zoomed-in view).
enum RigComponent: Hashable {
    case guitar, amp, cabinet, combo
    case pedal(UUID)
}

struct RigStageView: View {
    @EnvironmentObject var store: RigStore
    @EnvironmentObject var drag: RigDragController
    @Binding var focused: RigComponent?
    /// Tapping the no-amp warning goes and fixes it. The shell owns which page is
    /// showing, so the stage can only ask.
    var onFindAmp: () -> Void = {}

    @State private var tilt: CGSize = .zero
    @State private var isTargeted = false
    /// The stage's registration with the drag controller — its frame plus the
    /// hooks whichever stage layout is on screen wires into it.
    @State private var stageArea = RigDropArea()

    private let maxAngle: CGFloat = 20

    /// The 3D diorama, for every amp section. A combo used to fall back here to
    /// the flat vector layout, which meant picking a combo dropped the WHOLE
    /// stage — pedalboard and guitar included — out of 3D. The combo is now just
    /// a one-box amp in the same scene, so only the amp's shape changes.
    private var use3DStage: Bool { FeatureFlags.amp3D }

    var body: some View {
        ZStack {
            stageBackground

            if use3DStage {
                // The whole rig orbits together as one scene — no SwiftUI warp.
                // Dragging a card over it glows the exact piece it would replace
                // (handled inside RigStage3DView) and drops swap that piece.
                RigStage3DView(
                    amp: store.ampItem, cabinet: store.cabinetItem,
                    pedals: store.pedalItems, guitar: store.guitar,
                    focused: focused,
                    pedalInFlight: drag.item?.category.isPedal == true,
                    onFocus: { component in
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { focused = component }
                    },
                    onDrop: { target, item in
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                            switch target {
                            case .pedal(let id):       store.replacePedal(id, with: item)
                            case .addPedal:            store.apply(item)      // append, don't swap
                            case .ampStack, .none:     store.apply(item)
                            }
                        }
                    },
                    dropArea: stageArea,
                    controller: drag
                )
                // Full-bleed on purpose. The scene paints its own backdrop now
                // (`RigDiorama.backdrop`), so any inset here is a strip of SwiftUI
                // colour sitting beside a SceneKit colour that has been through the
                // camera's grade — and they do not match, so the inset reads as a
                // band along the top and sides. No inset, no band.
                .background(stageFrameReader)
            } else {
                vectorRig
                    .rotation3DEffect(.degrees(Double(tilt.width)),  axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                    .rotation3DEffect(.degrees(Double(-tilt.height)), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                    .simultaneousGesture(rotateDrag)
                    .padding(.top, 26)
                    .background(stageFrameReader)
                    .onAppear { wireVectorDrop() }
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
        // Non-blocking and pinned to the very top so it never covers the board.
        .overlay(alignment: .top) {
            if !store.hasAmp { noAmpWarning }
        }
        .animation(.easeInOut(duration: 0.25), value: store.hasAmp)
    }

    // MARK: - No-amp warning

    /// Shown for exactly as long as `store.hasAmp` is false — it appears the
    /// instant the last amp is deleted and goes the instant one is added, because
    /// it is derived, not a flag someone has to remember to clear. States the
    /// problem AND the fix; the hard stop is the device bar's Proceed error.
    private var noAmpWarning: some View {
        Button(action: onFindAmp) { noAmpWarningFace }
            .buttonStyle(.plain)
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityLabel("No amp in your rig. Add one from the Gear Library.")
    }

    private var noAmpWarningFace: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
            Text("NO AMP IN YOUR RIG")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
            Text("· add one from the Gear Library")
                .font(.system(size: 11))
                .foregroundStyle(RigTheme.textPrimary.opacity(0.9))
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(RigTheme.textPrimary.opacity(0.55))
        }
        .foregroundStyle(RigTheme.clip)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(RigTheme.background.opacity(0.92))
        )
        .overlay(Capsule().strokeBorder(RigTheme.clip.opacity(0.65), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
        // Only the capsule itself takes the tap. It used to disable hit-testing
        // outright to stay out of the stage's gestures; now that it is the way to
        // fix the problem it states, it takes exactly its own shape and no more.
        .contentShape(Capsule())
    }

    /// Registers the stage as a drop target for as long as it is on screen, with
    /// its frame in the shared "appRoot" space so the controller can map the finger
    /// position into the scene for hit-testing. Deregistering is not tidiness: this
    /// page stays alive one screen to the left once you swipe to the AR page, and a
    /// stage that stayed registered could take a drop meant for a stomp slot.
    private var stageFrameReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    stageArea.frame = proxy.frame(in: .named("appRoot"))
                    // Only a drag looking for somewhere to LAND: a piece lifted
                    // off this very board must not be able to replace a neighbour
                    // on its way to the trash.
                    stageArea.accepts = { _, origin in origin.isPlacing }
                    drag.register(stageArea)
                }
                .onChange(of: proxy.frame(in: .named("appRoot"))) { _, frame in
                    stageArea.frame = frame
                }
                .onDisappear { drag.deregister(stageArea) }
        }
    }

    /// The flat vector fallback has no per-piece hit-testing, so a drop anywhere
    /// on it just applies the item by category (amp/cab replace, a pedal is added).
    private func wireVectorDrop() {
        stageArea.onHover = { _, _, _ in isTargeted = true }
        stageArea.onExit = { isTargeted = false }
        stageArea.onDrop = { item, _ in
            withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { store.apply(item) }
        }
    }

    // MARK: - Vector fallback (flag off, or a combo amp)

    private var vectorRig: some View {
        ZStack(alignment: .bottom) {
            // Centered: amp head + cabinet + pedalboard
            VStack(spacing: 12) {
                if store.isCombo {
                    gearView(.combo, item: store.ampItem, width: 156, height: 116)
                } else {
                    // Head and cab are framed as ONE stack: a shared width, with
                    // each height falling out of that piece's drawn aspect (head
                    // ≈ 2.05:1, cab ≈ 0.87:1). Sized off the cabinet's original
                    // 98pt height so the stack keeps its vertical footprint —
                    // the axis this composition is actually tight on. Framing the
                    // two independently made the head come out wider than the cab
                    // it stands on, which no stack has ever looked like.
                    VStack(spacing: 5) {
                        gearView(.amp, item: store.ampItem, width: 84, height: 41)
                        gearView(.cabinet, item: store.cabinetItem, width: 85, height: 98)
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
                        // Same press-and-hold as a rail card, but flagged `.stage`
                        // so the trash unloads it from the rig instead of deleting
                        // it. `.simultaneousGesture` keeps tap-to-focus working.
                        .simultaneousGesture(liftGesture(pedal))
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

    /// What the diorama's stage floats in.
    ///
    /// The blue the stage model's own author photographs it against — StreetRig now
    /// shows the same asset in the same setting. It is a deliberate departure from
    /// `RigTheme`'s warm "Burnt Tan" palette, and the ONLY surface in the app that
    /// leaves it, because it is not really UI: it is the backdrop of a photograph of
    /// a room, and the room is wooden. Blue is the complement of that wood, which is
    /// why the boards and the sunburst read as vividly against it as they do — and
    /// why every earlier attempt here, all of them warm, kept flattening the stage
    /// into its own background.
    ///
    /// It replaces a neutral grey ramp that predated there being a modelled stage at
    /// all, and a warm brown one derived from the boards' own colour (#834D2E) that
    /// blended TOO well: matched to the floor, the platform stopped reading as an
    /// object and the diorama lost its edge entirely.
    ///
    /// Backdrop for the stage area, behind the 3D view.
    ///
    /// This is `RigDiorama.backdrop` AS RENDERED, not as authored — #1D96C5 rather
    /// than the #3296C1 the scene is handed. The camera grades every frame
    /// (`saturation` 1.08, `contrast` 0.08) and the background goes through it like
    /// everything else, which drops its red from 0.196 to 0.114. Matching the
    /// authored value instead leaves a visible band wherever the two meet.
    ///
    /// With the 3D view full-bleed this should never actually be on screen — it is
    /// what shows if the scene fails to build, and the point is that you cannot tell.
    private var stageBackground: some View {
        Color(red: 0.114, green: 0.588, blue: 0.773)      // #1D96C5
    }

    // MARK: - Tilt gesture for the vector layout (rubber-band back to center)

    private var rotateDrag: some Gesture {
        DragGesture()
            .onChanged { value in
                // A pedal is being pulled off the board — hand the gesture over
                // rather than tilting the whole rig underneath the player's
                // finger. Any tilt already picked up in the 0.4s before the lift
                // took is unwound here, so the drag-off starts from level.
                guard !drag.isDragging else {
                    if tilt != .zero {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { tilt = .zero }
                    }
                    return
                }
                tilt = CGSize(
                    width: clamp(value.translation.width / 6),
                    height: clamp(value.translation.height / 6)
                )
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.55, dampingFraction: 0.55)) { tilt = .zero }
            }
    }

    /// Press-and-hold a pedal on the flat board to lift it, then drag it to the
    /// rail's trash to take it off the rig. Mirrors `GearCardView.dragGesture`
    /// deliberately: one drag system, one ghost, one trash target.
    private func liftGesture(_ pedal: GearItem) -> some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(coordinateSpace: .named("appRoot")))
            .onChanged { value in
                if case .second(true, let move?) = value {
                    if drag.item == nil { drag.begin(pedal, at: move.location, from: .stage) }
                    else { drag.move(to: move.location) }
                }
            }
            .onEnded { _ in drag.end() }
    }

    private func clamp(_ x: CGFloat) -> CGFloat { max(-maxAngle, min(maxAngle, x)) }
}

#Preview {
    RigStageView(focused: .constant(nil))
        .environmentObject(RigStore.preview)
        .environmentObject(RigDragController())
        .preferredColorScheme(.dark)
}

#Preview("No amp") {
    // Delete every amp-shaped thing so nothing backfills — `ampSection` is left
    // pointing at an id that no longer resolves, which IS "no amp".
    let store = RigStore.preview
    for gear in store.collection where gear.category == .amp || gear.category == .comboAmp {
        store.removeFromCollection(gear.id)
    }
    return RigStageView(focused: .constant(nil))
        .environmentObject(store)
        .environmentObject(RigDragController())
        .preferredColorScheme(.dark)
}
