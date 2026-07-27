//
//  MainView.swift
//  StreetRig
//
//  The app shell: a persistent left MY GEAR rail and bottom device bar frame a
//  center area that pages between the rig (Main) and the gear library. Move
//  between them with the top arrows or by swiping. A tapped rig component
//  zooms into a control panel overlay above everything.
//

import SwiftUI

enum AppPage: Hashable { case main, library }

struct MainView: View {
    @EnvironmentObject var store: RigStore
    @State private var focused: RigComponent?
    @State private var page: AppPage = .main

    var body: some View {
        ZStack {
            RigTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                topNav
                HStack(spacing: 0) {
                    CollectionTabView()
                    TabView(selection: $page) {
                        LibraryContentView()
                            .tag(AppPage.library)
                        RigStageView(focused: $focused)
                            .tag(AppPage.main)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
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

    // MARK: - Top navigation (arrows + current page title)

    private var topNav: some View {
        HStack(spacing: 0) {
            navArrow(systemName: "chevron.left", target: .library, enabled: page != .library)
            Spacer()
            Text(page == .main ? "MY RIG" : "GEAR LIBRARY")
                .font(.caption.weight(.bold))
                .tracking(2)
                .foregroundStyle(RigTheme.textMuted)
            Spacer()
            navArrow(systemName: "chevron.right", target: .main, enabled: page != .main)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(RigTheme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
    }

    private func navArrow(systemName: String, target: AppPage, enabled: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.28)) { page = target }
        } label: {
            Image(systemName: systemName)
                .font(.title3.weight(.bold))
                .foregroundStyle(enabled ? RigTheme.amber : RigTheme.textMuted.opacity(0.35))
                .frame(width: 46, height: 30)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
    }
}

#Preview {
    MainView()
        .environmentObject(RigStore.preview)
        .preferredColorScheme(.dark)
}
