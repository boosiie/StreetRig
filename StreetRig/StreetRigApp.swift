//
//  StreetRigApp.swift
//  StreetRig
//
//  Created by Jake C on 23/07/2026.
//

import SwiftUI
import StreetRigEngine

@main
struct StreetRigApp: App {
    @StateObject private var store = RigStore()
    @StateObject private var dragController = RigDragController()
    @StateObject private var slotLift = ARSlotLift()

    init() {
        #if DEBUG
        // One-off: export the procedural models to editable 3D files (see
        // ModelExporter). Trigger with STREETRIG_EXPORT=1 in the launch env.
        if ProcessInfo.processInfo.environment["STREETRIG_EXPORT"] == "1" {
            ModelExporter.exportAll()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(dragController)
                .environmentObject(slotLift)
                // The 2D sibling of ModelExporter: bake every component's knob
                // panel to an editable PNG in Documents/PanelArt (see
                // PanelArtExporter). `=1` fills in what is missing and never
                // touches a plate you have edited; `=force` replaces the lot with
                // clean baselines.
                //
                // Here rather than in `init()` on purpose. A plate is rendered
                // through `ImageRenderer`, and the metal finishes are `Canvas`
                // drawings — that wants a live scene, not a half-built app.
                .task { exportPanelsIfAsked() }
        }
    }

    private func exportPanelsIfAsked() {
        #if DEBUG
        guard let mode = ProcessInfo.processInfo.environment["STREETRIG_EXPORT_PANELS"] else { return }
        PanelArtExporter.exportAll(force: mode == "force")
        #endif
    }
}
