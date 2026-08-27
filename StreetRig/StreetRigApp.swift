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
                // The app icon, for the same reason and by the same route: three
                // 1024² appearance variants baked from the `AmpLogoView` the
                // splash draws (see AppIconExporter). `=1` for the catalog sizes,
                // `=2`/`=3` for marketing renders, `=probe` to also write the
                // render-route comparison.
                //
                // This one is MORE dependent on a live scene than the plates are,
                // not less: the knobs are Metal `.colorEffect` shaders, and the
                // shader library has to have resolved before `ImageRenderer` can
                // rasterise them. An earlier cut ran this from `init()` behind a
                // 1.5s `asyncAfter` to wait the scene out — a guess dressed up as
                // a delay. `.task` just waits for the real thing.
                .task { exportIconIfAsked() }
        }
    }

    private func exportPanelsIfAsked() {
        #if DEBUG
        guard let mode = ProcessInfo.processInfo.environment["STREETRIG_EXPORT_PANELS"] else { return }
        PanelArtExporter.exportAll(force: mode == "force")
        #endif
    }

    private func exportIconIfAsked() {
        #if DEBUG
        guard let mode = ProcessInfo.processInfo.environment["STREETRIG_EXPORT_ICON"] else { return }
        AppIconExporter.runFromLaunchEnvironment(mode)
        #endif
    }
}
