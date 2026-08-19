//
//  RigDragController.swift
//  StreetRig
//
//  Drives a custom drag-to-place across the app. A piece of gear is picked up —
//  a card in the MY GEAR rail, a model on the rig board, a pedal off an AR
//  footswitch — a "ghost" of it follows the finger, and as the finger moves over
//  a registered target the thing it would land on glows; releasing applies it.
//
//  We roll our own instead of SwiftUI `.draggable` / `.dropDestination` because
//  the system drag is unreliable for intra-app dragging here — it won't lift on
//  the Simulator or inside the rail's ScrollView — and because a custom drag
//  hands us the continuous finger position the 3D highlight needs. Everything is
//  measured in the shared "appRoot" coordinate space (declared in MainView).
//
//  TARGETS REGISTER, AND DEREGISTER. This used to be a single hard-coded rect for
//  the rig stage, plus a second one bolted on for the trash, which made every
//  further drop area impossible — the AR page's slots advertised a drop they could
//  never receive. A view now hands in a `RigDropArea` when it appears and takes it
//  back when it disappears. Taking it back is the load-bearing half: the pager
//  keeps a page alive after you swipe off it, and a target left behind by a page
//  you can no longer see must not catch a drop aimed at the page that replaced it.
//
//  PRECEDENCE is `priority` first, then registration order (later wins). The trash
//  sits above everything, explicitly: a destructive target must never double as a
//  "replace this piece" hover, or a finger in an overlap would arm two outcomes at
//  once and `end()` would have to guess which the player meant. Among equals, later
//  registration is z-order — a target registered later is either finer-grained (a
//  slot inside a page) or literally on top. A target that refuses the drag is
//  skipped rather than swallowing it, so an amp dragged over a pedal-only slot
//  falls through instead of hitting a dead zone.
//
//  WHAT A DROP MEANS DEPENDS ON WHERE IT STARTED — see `RigDragOrigin`. The origin
//  travels with every hover and drop so one red circle can mean three different
//  things without three trash cans.
//
//  The registry is deliberately NOT `@Published`. Frames are re-registered on every
//  layout change — including while the AR page's anchored slots track a world
//  anchor — and publishing that would re-render the AR page's banner, camera
//  preview and slots on each of those frames, on the main thread, next to a live
//  neural amp. Frames change on layout; nothing here changes per finger move.
//

import SwiftUI
import StreetRigEngine
import Combine

/// Where a drag started, which decides what the trash MEANS for it.
///
/// These are genuinely different operations and must never be confused: a card
/// pulled out of the rail is owned gear being deleted; a piece pulled off the
/// board is only leaving the current rig and stays owned; a pedal pulled off an
/// AR footswitch is only losing its switch and stays on the board.
enum RigDragOrigin: Equatable {
    case rail            // MY GEAR card → dropping on the trash DELETES the gear
    case stage           // a piece on the rig board → the trash unloads it from the rig
    case arSlot(Int)     // a pedal on an AR footswitch → the trash clears that binding

    /// Whether this drag is looking for somewhere new to LAND, as opposed to being
    /// carried off something it is already on. A pull-off must not highlight (and
    /// then replace) a neighbour on its way to the bin.
    var isPlacing: Bool { self == .rail }
}

/// One area a dragged piece can land in. Owned by the view that draws it and lent
/// to `RigDragController` for exactly as long as that view is on screen. (Not to be
/// confused with `RigDropTarget`, which is the specific PIECE of the 3D rig a drop
/// would replace once it is inside the stage's area.)
final class RigDropArea {
    /// Which space `frame` is measured in.
    ///
    /// `window` exists because a `.named` coordinate space does not resolve across
    /// the shell's paged TabView (a UIPageViewController bridge), where a
    /// `GeometryReader` silently falls back to global coordinates — and because
    /// converting on READ removes an ordering hazard: a target may publish its
    /// frame before MainView has reported the appRoot origin, and still be right.
    enum Space { case appRoot, window }

    /// The target's frame, in `space`.
    var frame: CGRect = .zero
    var space: Space = .appRoot
    /// Higher wins an overlap regardless of registration order. Only the trash
    /// raises it; see the precedence note in the file header.
    var priority: Int = 0
    /// Whether this target will take the drag. Refusing lets it pass through.
    var accepts: (GearItem, RigDragOrigin) -> Bool = { _, _ in true }
    /// The finger moved over the target. The point is target-LOCAL, so a view that
    /// hit-tests its own contents (the 3D stage) can use it without conversion.
    var onHover: ((CGPoint, GearItem, RigDragOrigin) -> Void)?
    /// The finger left the target, or the drag ended: drop any highlight.
    var onExit: (() -> Void)?
    /// Released over the target.
    var onDrop: ((GearItem, RigDragOrigin) -> Void)?
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

    /// Where the "appRoot" space's origin sits in UIKit WINDOW coordinates,
    /// reported by MainView.
    ///
    /// Needed by drags that start in UIKit — the rig stage's SceneKit view and the
    /// AR page's floor pedals, whose gesture recognisers hand us window points. It
    /// is not derivable from any registered frame: a reader living inside the
    /// shell's paged TabView cannot measure "appRoot" (see `RigDropArea.Space`).
    /// Reading the origin from the appRoot view ITSELF is the one measurement that
    /// is always in the space its name says.
    var appRootOrigin: CGPoint = .zero

    /// A UIKit window point → the shared "appRoot" space the ghost, the trash and
    /// the rail's drag all measure in.
    func appRootPoint(fromWindow point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - appRootOrigin.x, y: point.y - appRootOrigin.y)
    }

    /// Live targets, in registration order — later wins an overlap at equal priority.
    private var targets: [RigDropArea] = []
    /// The target the finger is over right now, kept so it can be told when the
    /// finger leaves it for somewhere else.
    private var hovered: RigDropArea?

    var isDragging: Bool { item != nil }

    /// Re-registering an existing target moves it to the top, which is what a view
    /// re-appearing over another one should do.
    func register(_ target: RigDropArea) {
        targets.removeAll { $0 === target }
        targets.append(target)
    }

    /// No `onExit` on the way out: the view is going away and its highlight with it.
    func deregister(_ target: RigDropArea) {
        if hovered === target { hovered = nil }
        targets.removeAll { $0 === target }
    }

    /// Set by the trash target from its own area's hover hooks, so the one place
    /// that knows what "over the trash" looks like is the trash.
    func setOverTrash(_ over: Bool) {
        guard isOverTrash != over else { return }
        isOverTrash = over
    }

    func begin(_ item: GearItem, at point: CGPoint, from origin: RigDragOrigin = .rail) {
        self.item = item
        self.origin = origin
        move(to: point)
    }

    func move(to point: CGPoint) {
        location = point
        guard let item else { return }
        let hit = target(at: point, for: item)
        if hit !== hovered {
            hovered?.onExit?()          // dragged out of the last target
            hovered = hit
        }
        if let hit {
            let local = CGPoint(x: point.x - resolvedFrame(hit).minX,
                                y: point.y - resolvedFrame(hit).minY)
            hit.onHover?(local, item, origin)
        }
    }

    func end() {
        // Decide the ONE outcome up front, from the state the gesture ended in.
        let dropped = item
        let hit = dropped.flatMap { target(at: location, for: $0) }
        let source = origin

        // Clear the drag BEFORE dispatching. A trash drop can open a confirmation
        // dialog, and the delete is then deferred until the player answers it —
        // if `item` were still set the ghost would hang on screen over that dialog
        // for as long as it stayed up.
        item = nil
        isOverTrash = false
        origin = .rail

        if let dropped, let hit { hit.onDrop?(dropped, source) }
        // Last, so the stage's drop handler can still read the highlighted target
        // it is about to replace (onExit nils that out).
        hovered?.onExit?()
        hovered = nil
    }

    /// A target's frame in "appRoot" space, whatever space it reported in.
    private func resolvedFrame(_ area: RigDropArea) -> CGRect {
        switch area.space {
        case .appRoot: return area.frame
        case .window:  return CGRect(origin: appRootPoint(fromWindow: area.frame.origin),
                                     size: area.frame.size)
        }
    }

    /// Highest priority wins; among equals, the most recently registered.
    /// A zero-sized frame contains nothing, so a target that has not reported yet
    /// is simply cold rather than a hot spot sitting in the top-left corner.
    private func target(at point: CGPoint, for item: GearItem) -> RigDropArea? {
        targets.enumerated()
            .filter { resolvedFrame($0.element).contains(point) && $0.element.accepts(item, origin) }
            .max { a, b in
                a.element.priority != b.element.priority
                    ? a.element.priority < b.element.priority
                    : a.offset < b.offset
            }?
            .element
    }
}

/// Whether a pedal on the AR page is held and about to be lifted.
///
/// Its own tiny object rather than a flag on `RigDragController`, and that is the
/// whole point: the controller republishes on every finger move, so a shell that
/// observed it to answer this question would re-render the entire app — the rail,
/// the pager, the control panel — dozens of times per drag. This changes twice per
/// lift.
///
/// It exists because an AR slot lives INSIDE the shell's paged TabView, whose pan
/// will claim the drag and swipe the page instead of lifting the pedal. The rail
/// settles the same fight by switching its ScrollView off while a card is held
/// (see CollectionTabView) and the 3D stage by using a UIKit recogniser; this is
/// the same move for the pager.
@MainActor
final class ARSlotLift: ObservableObject {
    @Published var armed = false
}

extension EnvironmentValues {
    /// The live drag controller, passed down as an environment VALUE rather than
    /// read back as an `@EnvironmentObject`, on purpose: observing the controller
    /// re-renders a view on every finger move, and the AR page's slots must only
    /// re-render when their own hover state flips.
    ///
    /// Nil wherever no drag can start. The play page hosts the AR content with no
    /// rail on screen, so it never supplies one — which is what makes rail-drop
    /// targets absent there by construction rather than switched off by a flag.
    @Entry var rigDrag: RigDragController?
}
