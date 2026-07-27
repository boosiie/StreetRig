//
//  MainView.swift
//  StreetRig
//
//  The main screen: left collection tab, center rig stage, bottom device bar,
//  with a zoomed-in component view that overlays everything when a part is
//  tapped. State lives in RigStore (injected via the environment) and persists.
//

import SwiftUI

struct MainView: View {
    @EnvironmentObject var store: RigStore
    @State private var focused: RigComponent?

    var body: some View {
        ZStack {
            RigTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    CollectionTabView()
                    RigStageView(focused: $focused)
                }
                DeviceBarView()
            }

            if let component = focused {
                ComponentDetailView(component: component) {
                    withAnimation(.easeInOut(duration: 0.25)) { focused = nil }
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
    }
}

#Preview {
    MainView()
        .environmentObject(RigStore.preview)
        .preferredColorScheme(.dark)
}
