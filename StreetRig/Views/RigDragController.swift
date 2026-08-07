//
//  RigDragController.swift
//  StreetRig
//
//  Drives a custom drag-to-replace for the rig. A card in the MY GEAR rail is
//  picked up (a "ghost" of it follows the finger), and as the finger moves over
//  the 3D stage the piece it would replace glows; releasing over that piece
//  swaps it in.
//
//  We roll our own instead of SwiftUI `.draggable` / `.dropDestination` because
//  the system drag is unreliable for intra-app dragging here — it won't lift on
//  the Simulator or inside the rail's ScrollView — and because a custom drag
//  hands us the continuous finger position the 3D highlight needs. Everything is
//  measured in the shared "appRoot" coordinate space (declared in MainView).
//

import SwiftUI
import Combine

@MainActor
final class RigDragController: ObservableObject {
    /// The card currently being dragged (nil when idle). The ghost observes this.
    @Published var item: GearItem?
    /// Finger position in the shared "appRoot" coordinate space.
    @Published var location: CGPoint = .zero

    /// The rig stage's frame in "appRoot" space (set by the stage view).
    var stageFrame: CGRect = .zero
    /// Live hooks into the rig stage, wired by whichever stage is on screen:
    var onMove: ((CGPoint, GearItem) -> Void)?   // stage-local point + item → update highlight
    var onClear: (() -> Void)?                    // clear any highlight
    var onDrop: ((GearItem) -> Void)?             // released over the stage → apply

    var isDragging: Bool { item != nil }

    func begin(_ item: GearItem, at point: CGPoint) {
        self.item = item
        move(to: point)
    }

    func move(to point: CGPoint) {
        location = point
        guard let item else { return }
        if stageFrame.contains(point) {
            onMove?(CGPoint(x: point.x - stageFrame.minX, y: point.y - stageFrame.minY), item)
        } else {
            onClear?()          // dragged back out of the stage → no target
        }
    }

    func end() {
        // Apply first (while the highlight/target is still set), then reset.
        if let item, stageFrame.contains(location) { onDrop?(item) }
        item = nil
        onClear?()
    }
}
