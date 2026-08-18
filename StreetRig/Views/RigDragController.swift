//
//  RigDragController.swift
//  StreetRig
//
//  Drives a custom drag-to-place across the app. A card in the MY GEAR rail is
//  picked up (a "ghost" of it follows the finger), and as the finger moves over a
//  registered target — the 3D rig stage, or one of the AR page's stomp slots — the
//  thing it would land on glows; releasing over it applies the drop.
//
//  We roll our own instead of SwiftUI `.draggable` / `.dropDestination` because
//  the system drag is unreliable for intra-app dragging here — it won't lift on
//  the Simulator or inside the rail's ScrollView — and because a custom drag
//  hands us the continuous finger position the 3D highlight needs. Everything is
//  measured in the shared "appRoot" coordinate space (declared in MainView).
//
//  TARGETS REGISTER, AND DEREGISTER. This used to be a single hard-coded rect for
//  the rig stage, which made every other drop area in the app impossible — the AR
//  page's slots advertised a drop they could never receive. A view now hands in a
//  `RigDropArea` when it appears and takes it back when it disappears. Taking it
//  back is the load-bearing half: the pager keeps a page alive after you swipe off
//  it, and a target left behind by a page you can no longer see must not be able to
//  catch a drop aimed at the page that replaced it.
//
//  OVERLAP: the LAST target registered wins. Registration order is z-order here —
//  a target registered later is either finer-grained (a slot inside a page) or
//  literally on top of the other (a full-screen page over the shell), and in both
//  cases it is the one the player is aiming at. A target that refuses the dragged
//  item is skipped rather than swallowing the drop, so an amp dragged over a
//  pedal-only slot falls through to whatever is behind it instead of hitting a
//  dead zone.
//
//  The registry is deliberately NOT `@Published`. Frames are re-registered on every
//  layout change — including 30×/second while the AR page's anchored slots track a
//  world anchor — and publishing that would re-render the AR page's banner, camera
//  preview and slots on each of those frames, on the main thread, next to a live
//  neural amp. Frames change on layout; nothing here changes per finger move.
//

import SwiftUI
import StreetRigEngine
import Combine

/// One area a dragged card can land in. Owned by the view that draws it and lent
/// to `RigDragController` for exactly as long as that view is on screen. (Not to be
/// confused with `RigDropTarget`, which is the specific PIECE of the 3D rig a drop
/// would replace once it is inside the stage's area.)
final class RigDropArea {
    /// The target's frame in the shared "appRoot" coordinate space.
    var frame: CGRect = .zero
    /// Which gear this target will take. Refusing lets the drag pass through it.
    var accepts: (GearItem) -> Bool = { _ in true }
    /// The finger moved over the target. The point is target-LOCAL, so a view that
    /// hit-tests its own contents (the 3D stage) can use it without conversion.
    var onHover: ((CGPoint, GearItem) -> Void)?
    /// The finger left the target, or the drag ended: drop any highlight.
    var onExit: (() -> Void)?
    /// Released over the target.
    var onDrop: ((GearItem) -> Void)?
}

@MainActor
final class RigDragController: ObservableObject {
    /// The card currently being dragged (nil when idle). The ghost observes this.
    @Published var item: GearItem?
    /// Finger position in the shared "appRoot" coordinate space.
    @Published var location: CGPoint = .zero

    /// Live targets, in registration order — the last one wins an overlap.
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

    func begin(_ item: GearItem, at point: CGPoint) {
        self.item = item
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
            hit.onHover?(CGPoint(x: point.x - hit.frame.minX, y: point.y - hit.frame.minY), item)
        }
    }

    func end() {
        // Apply first (while the highlight/target is still set), then reset.
        if let item, let hit = target(at: location, for: item) { hit.onDrop?(item) }
        item = nil
        hovered?.onExit?()
        hovered = nil
    }

    private func target(at point: CGPoint, for item: GearItem) -> RigDropArea? {
        targets.last { $0.frame.contains(point) && $0.accepts(item) }
    }
}

extension EnvironmentValues {
    /// The live drag controller, passed down as an environment VALUE rather than
    /// read back as an `@EnvironmentObject`, on purpose: observing the controller
    /// re-renders a view on every finger move, and the AR page's slots must only
    /// re-render when their own hover state flips.
    ///
    /// Nil wherever no drag can start. The play page hosts the AR content with no
    /// rail on screen, so it never supplies one — which is what makes drop targets
    /// absent there by construction rather than switched off by a flag.
    @Entry var rigDrag: RigDragController?
}
