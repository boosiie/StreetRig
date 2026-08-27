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
    /// The player's name and avatar. Injected alongside `store` and for the same
    /// reason: it is read by the profile page today and will be read by the
    /// forthcoming tutorial and (very likely) the top nav, and a second instance
    /// would be a second copy of the same file racing the first to write it.
    @StateObject private var profileStore = ProfileStore()
    @StateObject private var dragController = RigDragController()
    @StateObject private var slotLift = ARSlotLift()
    /// The tutorial's state. Owned here rather than in `ContentView` because two
    /// unrelated places have to see it: the splash gate that starts the
    /// first-run chain, and `MainView`, which the coach-mark tour has to be able
    /// to page. See `OnboardingCoordinator`'s header.
    @StateObject private var onboarding = OnboardingCoordinator()

    init() {
        #if DEBUG
        // One-off: export the procedural models to editable 3D files (see
        // ModelExporter). Trigger with STREETRIG_EXPORT=1 in the launch env.
        if ProcessInfo.processInfo.environment["STREETRIG_EXPORT"] == "1" {
            ModelExporter.exportAll()
        }
        // The 2D sibling: bake every component's knob panel to an editable PNG in
        // Documents/PanelArt (see PanelArtExporter). `=1` fills in what is
        // missing and never touches a plate you have edited; `=force` replaces
        // the lot with clean baselines.
        if let mode = ProcessInfo.processInfo.environment["STREETRIG_EXPORT_PANELS"] {
            _ = MainActor.assumeIsolated { PanelArtExporter.exportAll(force: mode == "force") }
        }
        // And the app icon: the three 1024² appearance variants iOS 26 wants, baked
        // from the same `AmpLogoView` the splash draws (see AppIconExporter). `=1`
        // for the catalog sizes, `=2`/`=3` for marketing renders, `=probe` to also
        // write the render-route comparison. The bake itself is deferred to a later
        // main-queue turn — there is no window scene yet at this point.
        if let mode = ProcessInfo.processInfo.environment["STREETRIG_EXPORT_ICON"] {
            MainActor.assumeIsolated { AppIconExporter.runFromLaunchEnvironment(mode) }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(profileStore)
                .environmentObject(dragController)
                .environmentObject(slotLift)
                .environmentObject(onboarding)
        }
    }
}
