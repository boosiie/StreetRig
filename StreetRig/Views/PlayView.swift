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

    var body: some View {
        VStack(spacing: 0) {
            ControlPanelSurface(audio: audio, onDone: { dismiss() })
            ARPedalContentView()
        }
        .background(RigTheme.background)
        .overlay {
            // Asked here rather than as a system alert so the "don't ask again"
            // choice can sit in the same card as the answer it qualifies. The
            // shell's panel suppresses its own copy while this page is up.
            DeviceOfferPrompt(audio: audio)
        }
    }
}

#Preview("Play page") {
    PlayView(audio: AudioEngineController())
        .environmentObject(RigStore.preview)
        .preferredColorScheme(.dark)
}
