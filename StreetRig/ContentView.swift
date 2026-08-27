//
//  ContentView.swift
//  StreetRig
//
//  Created by Jake C on 23/07/2026.
//

import SwiftUI
import StreetRigEngine

struct ContentView: View {
    /// How long the splash stays up. Temporary timed splash — later this
    /// will be driven by real audio-engine / asset warmup completing.
    private let splashDuration: Duration = .seconds(4)

    @State private var isLoading = true

    /// The first-launch chain lives here because this is the splash gate, and
    /// "after the splash" is the only moment the setup guide can start: any
    /// earlier and it is fighting the logo animation, any later and the player
    /// has already tapped PROCEED with their AirPods in.
    @EnvironmentObject private var onboarding: OnboardingCoordinator

    var body: some View {
        ZStack {
            if isLoading {
                LoadingView()
                    .transition(.opacity)
            } else {
                MainView()
                    .transition(.opacity)
            }

            // OVER the shell, never instead of it. The tour that follows this
            // guide points at `MainView`'s furniture, and its anchors only exist
            // once that view has been laid out — so the shell is built and
            // measured underneath while the guide is still on top of it.
            //
            // The coach-mark tour is NOT presented here: it is drawn inside
            // `MainView` itself, because it has to read that view's anchors.
            if onboarding.phase == .setupGuide {
                SetupGuideView(onFinish: { finishSetupGuide() },
                               onSkip: { skipSetupGuide() })
                    .transition(.opacity)
                    .zIndex(3)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            try? await Task.sleep(for: splashDuration)
            withAnimation(.easeInOut(duration: 0.6)) {
                isLoading = false
            }
            // Nothing at all for a returning player — the flag is checked inside.
            withAnimation(.easeInOut(duration: 0.45)) {
                onboarding.beginFirstRunIfNeeded()
            }
        }
        .task {
            // Headless offline-render harness (launch arg / env flag). The
            // Simulator has no audio input, so this file-render through the real
            // AUAudioUnit graph is the automated verification path.
            guard AudioEngineController.shouldRunOfflineRenderAtLaunch else { return }
            let controller = AudioEngineController()
            _ = await controller.runOfflineRender()
        }
        .task {
            // Headless AUv3 packaging self-test (Phase 2): discovery of the
            // StreetRig AUv3 appex + best-effort out-of-process audio null test.
            // Gated by -VerifyAUv3 / STREETRIG_VERIFY_AUV3=1.
            guard AudioEngineController.shouldRunAUv3VerifyAtLaunch else { return }
            let controller = AudioEngineController()
            _ = await controller.verifyAUv3()
        }
    }

    /// Handed off with a fade rather than a cut: on a first run the coach-mark
    /// tour comes up in the same instant, and two full-screen layers swapping
    /// hard reads as the app having reloaded.
    private func finishSetupGuide() {
        withAnimation(.easeInOut(duration: 0.4)) { onboarding.setupGuideDidFinish() }
    }

    private func skipSetupGuide() {
        withAnimation(.easeInOut(duration: 0.3)) { onboarding.skip() }
    }
}

#Preview {
    ContentView()
        .environmentObject(RigStore.preview)
        .environmentObject(ProfileStore.preview)
        .environmentObject(RigDragController())
        .environmentObject(ARSlotLift())
        .environmentObject(OnboardingCoordinator())
}
