//
//  RigDragController.swift
//  StreetRig
//
//  Drives a custom drag-to-replace for the rig. A card in the MY GEAR rail is
//  picked up (a "ghost" of it follows the finger), and as the finger moves over
//  the 3D stage the piece it would replace glows; releasing over that piece
//  swaps it in.
//
//  The same drag also feeds the TRASH target that fades into the bottom of the
//  rail while a drag is live. Two drop zones, one gesture — see `end()`, which
//  is deliberately written so exactly one outcome can fire per drag.
//
//  We roll our own instead of SwiftUI `.draggable` / `.dropDestination` because
//  the system drag is unreliable for intra-app dragging here — it won't lift on
//  the Simulator or inside the rail's ScrollView — and because a custom drag
//  hands us the continuous finger position the 3D highlight needs. Everything is
//  measured in the shared "appRoot" coordinate space (declared in MainView).
//

import SwiftUI
import StreetRigEngine
import Combine

/// Where a drag started, which decides what the trash MEANS for it.
///
/// The two are genuinely different operations and must never be confused: a
/// card pulled out of the rail is owned gear being deleted, while a pedal
/// pulled off the board is only leaving the current rig and stays owned.
enum RigDragOrigin {
    case rail    // MY GEAR card → dropping on the trash DELETES the gear
    case stage   // a piece on the rig board → dropping on the trash unloads it
}

@MainActor
final class RigDragController: ObservableObject {
    /// The card currently being dragged (nil when idle). The ghost observes this.
    @Published var item: GearItem?
    /// Finger position in the shared "appRoot" coordinate space.
    @Published var location: CGPoint = .zero
    /// True while the finger is inside the trash target. Published because the
    /// target's own hover styling (and its haptic) is driven off it.
    @Published private(set) var isOverTrash = false

    /// Where the live drag was picked up from. Reset with the drag. Published so
    /// the trash target can relabel itself (delete vs. take off the rig).
    @Published private(set) var origin: RigDragOrigin = .rail

    /// The rig stage's frame in "appRoot" space (set by the stage view).
    var stageFrame: CGRect = .zero
    /// The trash target's frame in UIKit WINDOW coordinates (set by the target).
    ///
    /// Window space rather than "appRoot" because the target floats over the
    /// shell's paged TabView, where a `.named` space is not guaranteed to resolve
    /// (see `appRootOrigin`) — `.global` always is. Converting on READ rather than
    /// on write also removes an ordering hazard: the target may publish its frame
    /// before MainView has reported the origin, and still be right.
    var trashFrameInWindow: CGRect = .zero

    /// That same frame in the shared "appRoot" space every drag measures in.
    /// Before the target reports, this is zero-sized — and a zero-sized rect
    /// contains nothing, so an unreported target is simply cold rather than a
    /// bin sitting invisibly in the top-left corner.
    var trashFrame: CGRect {
        CGRect(origin: appRootPoint(fromWindow: trashFrameInWindow.origin),
               size: trashFrameInWindow.size)
    }

    /// Where the "appRoot" space's origin sits in UIKit WINDOW coordinates,
    /// reported by MainView.
    ///
    /// Needed only by drags that start in UIKit — the rig stage's SceneKit view,
    /// whose gesture recognisers hand us window points. It is not derivable from
    /// `stageFrame`: that frame is measured by a GeometryReader living inside the
    /// shell's paged TabView, and a `.named` coordinate space does not resolve
    /// across that UIPageViewController bridge, so the reader silently falls back
    /// to global/window coordinates. Reading the origin from the appRoot view
    /// ITSELF is the one measurement that is always in the space its name says.
    var appRootOrigin: CGPoint = .zero

    /// A UIKit window point → the shared "appRoot" space the ghost, the trash and
    /// the rail's drag all measure in.
    func appRootPoint(fromWindow point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - appRootOrigin.x, y: point.y - appRootOrigin.y)
    }

    /// Live hooks into the rig stage, wired by whichever stage is on screen:
    var onMove: ((CGPoint, GearItem) -> Void)?   // stage-local point + item → update highlight
    var onClear: (() -> Void)?                    // clear any highlight
    var onDrop: ((GearItem) -> Void)?             // released over the stage → apply
    /// Released over the trash. The origin comes along because the rail's trash
    /// deletes owned gear while the stage's only unloads it from the rig.
    var onTrash: ((GearItem, RigDragOrigin) -> Void)?

    var isDragging: Bool { item != nil }

    func begin(_ item: GearItem, at point: CGPoint, from origin: RigDragOrigin = .rail) {
        self.item = item
        self.origin = origin
        move(to: point)
    }

    func move(to point: CGPoint) {
        location = point
        guard let item else { return }

        // TRASH WINS over the stage, explicitly. The rail and the stage don't
        // overlap in today's layout, but the precedence still has to be stated:
        // a destructive target must never double as a "replace this piece" hover,
        // or a finger in an overlap would arm two outcomes at once and `end()`
        // would have to guess which one the player meant.
        let overTrash = trashFrame.contains(point)
        if overTrash != isOverTrash { isOverTrash = overTrash }
        if overTrash { onClear?(); return }

        // A stage-originated drag is a pull-OFF, not a drop-to-replace: letting it
        // highlight (and then replace) a board piece would let a pedal swap itself
        // over a neighbour on the way to the bin.
        guard origin == .rail else { onClear?(); return }

        if stageFrame.contains(point) {
            onMove?(CGPoint(x: point.x - stageFrame.minX, y: point.y - stageFrame.minY), item)
        } else {
            onClear?()          // dragged back out of the stage → no target
        }
    }

    func end() {
        // Decide the ONE outcome up front, from the state the gesture ended in.
        let dropped = item
        let overTrash = dropped != nil && trashFrame.contains(location)
        let overStage = dropped != nil && !overTrash && origin == .rail && stageFrame.contains(location)
        let source = origin

        // Clear the drag BEFORE dispatching. A trash drop can open a confirmation
        // dialog, and the delete is then deferred until the player answers it —
        // if `item` were still set the ghost would hang on screen over that dialog
        // for as long as it stayed up.
        item = nil
        isOverTrash = false
        origin = .rail

        if let dropped {
            if overTrash        { onTrash?(dropped, source) }
            else if overStage   { onDrop?(dropped) }
        }
        // Last, so the stage's drop handler can still read the highlighted target
        // it is about to replace (onClear nils that out).
        onClear?()
    }
}
