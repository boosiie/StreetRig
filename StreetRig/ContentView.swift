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

    var body: some View {
        ZStack {
            if isLoading {
                LoadingView()
                    .transition(.opacity)
            } else {
                MainView()
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            try? await Task.sleep(for: splashDuration)
            withAnimation(.easeInOut(duration: 0.6)) {
                isLoading = false
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
}

#Preview {
    ContentView()
        .environmentObject(RigStore.preview)
        .environmentObject(RigDragController())
}
