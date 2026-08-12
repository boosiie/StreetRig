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
        }
    }
}
