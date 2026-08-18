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
