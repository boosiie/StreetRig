//
//  GearRemoval.swift
//  StreetRig
//
//  The ONE removal decision + the ONE confirmation dialog, shared by every
//  surface that can delete owned gear: the MY GEAR rail's trash target and the
//  GEAR LIBRARY's owned tiles.
//
//  It lives in its own file rather than inside either surface because the whole
//  point is that neither owns it. Deleting is destructive and touches persisted
//  state, so "is this allowed", "does it need to ask first" and "what does the
//  question say" must have exactly one answer — the moment the rail and the
//  library each grow their own dialog, one of them quietly stops asking.
//  The wording itself is one level further down still, in
//  `RemovalImpact.message` (StreetRigEngine), so it's derived from the conflict
//  rather than typed out per surface.
//

import SwiftUI
import StreetRigEngine

/// A deletion the player has been asked about but hasn't answered yet.
struct PendingGearRemoval: Identifiable {
    /// The OWNED INSTANCE's id — never a catalog item's throwaway id.
    let id: UUID
    let impact: RemovalImpact
}

enum GearRemoval {
    /// Why a protected item refused to be removed. Short enough to sit inline
    /// under the trash target; a dialog would be too much ceremony for "no".
    static let protectedReason = "Your guitar is fixed"

    /// What happened when a surface asked to remove some gear.
    enum Outcome {
        case removed                                  // nothing referenced it — already gone
        case needsConfirmation(PendingGearRemoval)    // in use — ask, then delete
        case rejected(String)                         // protected — explain, delete nothing
    }

    /// The single decision point in front of `RigStore.removeFromCollection`.
    ///
    /// Unused gear is deleted here and now: a confirmation on EVERY deletion
    /// trains the player to dismiss it reflexively, which is precisely when the
    /// one that matters gets waved through. Only gear the current rig is
    /// actually holding earns a question.
    @MainActor
    static func request(_ id: UUID, store: RigStore) -> Outcome {
        guard store.canRemove(id) else { return .rejected(protectedReason) }
        let impact = store.removalImpact(id)
        guard !impact.needsConfirmation else {
            return .needsConfirmation(PendingGearRemoval(id: id, impact: impact))
        }
        withAnimation(.easeInOut(duration: 0.28)) { store.removeFromCollection(id) }
        return .removed
    }
}

extension View {
    /// Presents the in-use confirmation for `pending`, and on Remove deletes
    /// through the store's one destructive entry point. Attach this to any
    /// surface that calls `GearRemoval.request`.
    func gearRemovalConfirmation(_ pending: Binding<PendingGearRemoval?>,
                                 store: RigStore) -> some View {
        modifier(GearRemovalConfirmation(pending: pending, store: store))
    }
}

private struct GearRemovalConfirmation: ViewModifier {
    @Binding var pending: PendingGearRemoval?
    let store: RigStore

    func body(content: Content) -> some View {
        content.alert(
            pending?.impact.title ?? "",
            isPresented: Binding(get: { pending != nil },
                                 set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { removal in
            Button("Remove", role: .destructive) {
                withAnimation(.easeInOut(duration: 0.28)) {
                    store.removeFromCollection(removal.id)
                }
                pending = nil
            }
            // Cancel really cancels: nothing has been mutated up to this point —
            // `request` only *described* the deletion, it didn't start one.
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { removal in
            Text(removal.impact.message)
        }
    }
}

// MARK: - The trash target

/// The drag-only trash, parked at the TOP-LEFT of the centre area — immediately
/// right of the MY GEAR rail, under the page title.
///
/// It sits there rather than inside the rail because the rail is the thing being
/// dragged FROM: a bin at the bottom of a scrolling column of cards put the
/// target under the finger's starting point and made a short downward flick read
/// as a delete. Out here it is a deliberate destination — you have to leave the
/// rail to reach it — and it is equally reachable from the rig stage, which is
/// the other place drags start.
///
/// Idle state costs nothing: it is laid out permanently (so its frame is current
/// the instant a drag starts) but drawn at zero opacity and non-interactive, so
/// there is no persistent trash button. It fades in with the drag and, on hover,
/// scales up and goes solid `RigTheme.clip` — the existing semantic clip/peak
/// red, deliberately not the amber that already means "drop here to swap this
/// piece in".
///
/// It owns what a drop on it MEANS (`handleTrash`), because it is now the only
/// view that knows a drop happened at all.
struct GearTrashTarget: View {
    @EnvironmentObject private var store: RigStore
    @EnvironmentObject private var drag: RigDragController

    /// A deletion waiting on the player's answer (in-use gear only).
    @State private var pendingRemoval: PendingGearRemoval?
    /// Inline reason for a rejected drop ("Your guitar is fixed"), auto-clearing.
    @State private var rejection: String?
    /// Bumped per rejection so the shake replays even for the same reason.
    @State private var rejectionShake: CGFloat = 0
    @State private var rejectionTimeout: Task<Void, Never>?

    /// The trash's registration with the drag controller. Priority above every
    /// other target: a destructive drop must never double as a "replace this
    /// piece" hover (see the precedence note in RigDragController).
    @State private var area = RigDropArea()

    private let diameter: CGFloat = 58

    var body: some View {
        // Stays up a beat past the drag when a rejection needs explaining.
        let visible = drag.isDragging || rejection != nil
        let hot = drag.isOverTrash

        VStack(spacing: 5) {
            ZStack {
                // Opaque base first: this now floats over the rig stage and the
                // gear library, so the tint alone can't be trusted to carry it.
                Circle().fill(RigTheme.background.opacity(0.94))
                Circle().fill(hot ? RigTheme.clip : RigTheme.clip.opacity(0.18))
                Circle().strokeBorder(RigTheme.clip.opacity(hot ? 0 : 0.9), lineWidth: 1.5)
                Image(systemName: "trash.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(hot ? .white : RigTheme.clip)
            }
            .frame(width: diameter, height: diameter)
            .scaleEffect(hot ? 1.18 : 1)
            .shadow(color: .black.opacity(0.55), radius: 9, y: 4)
            .background(frameReader)

            Text(rejection ?? caption)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(rejection == nil ? RigTheme.clip.opacity(0.95) : RigTheme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .frame(width: 104)
                .shadow(color: RigTheme.background, radius: 4)
        }
        .modifier(ShakeEffect(phase: rejectionShake))
        .opacity(visible ? 1 : 0)
        // Grows DOWN from the top edge it's anchored to, so it reads as dropping
        // into the corner rather than swelling out of the middle of the stage.
        .scaleEffect(visible ? 1 : 0.86, anchor: .top)
        .animation(.easeOut(duration: 0.18), value: visible)
        .animation(.easeOut(duration: 0.14), value: hot)
        // The project's haptic idiom (see TapSlider): SwiftUI-native, so it
        // no-ops wherever there's no haptic context. Fires only on ENTERING the
        // target — that's the commit point the player needs to feel.
        .sensoryFeedback(trigger: hot) { _, isHot in isHot ? .impact(flexibility: .rigid) : nil }
        // Never eats a tap, a scroll or a page swipe: the drag controller
        // hit-tests it by frame, so it needs no hit-testing of its own.
        .allowsHitTesting(false)
        .onAppear {
            area.priority = 100
            area.space = .window
            area.onHover = { _, _, _ in drag.setOverTrash(true) }
            area.onExit = { drag.setOverTrash(false) }
            area.onDrop = { item, origin in handleTrash(item, from: origin) }
            drag.register(area)
        }
        .onDisappear { drag.deregister(area) }
        .gearRemovalConfirmation($pendingRemoval, store: store)
    }

    /// A rail drag DELETES; a stage drag only unloads the piece from the rig.
    /// Saying which keeps one red circle from meaning two different things.
    private var caption: String {
        switch drag.origin {
        case .rail:   return "DELETE"
        case .stage:  return "OFF RIG"
        case .arSlot: return "OFF SWITCH"
        }
    }

    /// Publishes the target's frame in WINDOW coordinates — see
    /// `RigDropArea.Space` for why it isn't "appRoot" space.
    /// Slightly generous: a 58pt circle is a small thing to hit with a moving finger.
    private var frameReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { area.frame = proxy.frame(in: .global).insetBy(dx: -12, dy: -12) }
                .onChange(of: proxy.frame(in: .global)) { _, frame in
                    area.frame = frame.insetBy(dx: -12, dy: -12)
                }
        }
    }

    /// A card was released over the trash. What that means depends entirely on
    /// where the drag started — see `RigDragOrigin`.
    private func handleTrash(_ item: GearItem, from origin: RigDragOrigin) {
        switch origin {
        case .rail:
            // Owned gear being deleted. Everything funnels through GearRemoval so
            // the library's owned tiles ask the identical question.
            switch GearRemoval.request(item.id, store: store) {
            case .removed:                         break
            case .needsConfirmation(let pending):  pendingRemoval = pending
            case .rejected(let reason):            reject(reason)
            }

        case .stage:
            // Pulled off the rig board: the gear stays OWNED and stays in the
            // rail. Only the rig loses it.
            switch item.category {
            case .guitar:
                // Fixed — same refusal, same wording as the rail's.
                reject(GearRemoval.protectedReason)
            case .amp, .cabinet, .comboAmp:
                // The head and its cabinet are one piece on the stage, so they
                // leave together. This is the one drag that can leave the rig
                // unable to make a sound, which is allowed and then said out
                // loud: the stage banner appears and PROCEED refuses.
                withAnimation(.easeInOut(duration: 0.28)) { store.removeAmpFromRig() }
            default:
                withAnimation(.easeInOut(duration: 0.28)) { store.removePedal(item.id) }
            }

        case .arSlot(let index):
            // Pulled off a footswitch, and that is ALL it means: the pedal keeps
            // its place in the chain and stays owned, exactly as the ✕ button this
            // gesture replaced did. Clearing a slot leaves the pedal unbound and
            // therefore enabled — it is never stranded in bypass.
            withAnimation(.easeInOut(duration: 0.2)) { store.setARSlot(index, pedalId: nil) }
        }
    }

    /// Refuse a drop out loud: shake the target and post a short reason under it.
    /// A dialog would be far too much ceremony for "no".
    private func reject(_ reason: String) {
        rejectionTimeout?.cancel()
        rejection = reason
        withAnimation(.easeInOut(duration: 0.45)) { rejectionShake += 1 }
        rejectionTimeout = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { rejection = nil }
        }
    }
}

/// A short horizontal wobble, used to refuse a drop. Driven by a phase counter
/// so the same rejection can replay.
private struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 7
    var shakes: CGFloat = 3
    var phase: CGFloat

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(translationX: travel * sin(phase * .pi * shakes * 2), y: 0)
        )
    }
}
