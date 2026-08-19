//
//  PlayView.swift
//  StreetRig
//
//  THE PLAY PAGE. Full-screen, opened by PROCEED: the control panel across the
//  top and your pedals underneath it, which is the arrangement you want when the
//  phone is on the floor and you are standing over it with a guitar on.
//
//  It is the same `ControlPanelSurface` the shell puts along the bottom — the
//  same routes, the same lamps and meters, the same master and transport, driven
//  by the SAME engine instance (passed in, never made here: two panels must not
//  mean two engines). Only the closing zone is added, and only here.
//
//  WHY IT OPENS EVEN WHEN ENGAGING FAILED: the panel is where the failure is
//  reported, so it has to be the thing you are looking at when `engage()` throws.
//  The error strip lands across the top of this page.
//
//  LEAVING IS NOT STOPPING. DONE returns you to the rig with monitoring still
//  live; STOP is right there in the panel and is its own decision.
//

import SwiftUI
import StreetRigEngine

struct PlayView: View {
    /// Held UNOBSERVED on purpose. The panel below observes what it needs, so a
    /// meter tick (~30 Hz) or a render-load update never re-renders this body —
    /// and therefore never re-renders the AR slots or the camera preview under it.
    let audio: AudioEngineController

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var drag: RigDragController

    /// The shell's appRoot origin, put back when this page closes. Both pages are
    /// full-screen and landscape so the two are almost always identical — but
    /// "almost always" is not something a drag should depend on, and the shell has
    /// no way to notice it was overwritten while it was covered up.
    @State private var shellOrigin: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            ControlPanelSurface(audio: audio, onDone: { dismiss() })
            // The AR page, minus one thing it has in the shell: there is no MY GEAR
            // rail on this surface, so no pedal can be dragged IN. Filling a slot
            // here is a tap. Taking one off is still a drag, because the slot is its
            // own drag source — which is why this page carries a ghost and a trash
            // of its own below.
            ARPedalContentView()
        }
        .environment(\.rigDrag, drag)
        .background(RigTheme.background)
        // Its own space, its own ghost, its own bin. A full-screen cover is a
        // separate hierarchy: the shell's "appRoot" does not resolve inside it and
        // the shell's overlays cannot draw over it.
        .coordinateSpace(.named("appRoot"))
        .background(appRootOriginReader)
        .overlay(alignment: .topLeading) { GearTrashTarget() }
        .overlay { DragGhostView() }
        .overlay {
            // Asked here rather than as a system alert so the "don't ask again"
            // choice can sit in the same card as the answer it qualifies. The
            // shell's panel suppresses its own copy while this page is up.
            DeviceOfferPrompt(audio: audio)
        }
        .onDisappear { if let shellOrigin { drag.appRootOrigin = shellOrigin } }
    }

    private var appRootOriginReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    shellOrigin = drag.appRootOrigin
                    drag.appRootOrigin = proxy.frame(in: .global).origin
                }
                .onChange(of: proxy.frame(in: .global).origin) { _, origin in
                    drag.appRootOrigin = origin
                }
        }
    }
}

#Preview("Play page") {
    PlayView(audio: AudioEngineController())
        .environmentObject(RigStore.preview)
        .preferredColorScheme(.dark)
}
