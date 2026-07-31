//
//  MainView.swift
//  StreetRig
//
//  The app shell: a persistent left MY GEAR rail and bottom device bar frame a
//  center area that pages between three screens — the gear library (left), the
//  rig (center), and the AR pedal setup (right). Move between them with the top
//  arrows or by swiping. A tapped rig component zooms into a control overlay.
//

import SwiftUI

enum AppPage: Int, CaseIterable, Hashable {
    case library = 0, main = 1, controls = 2, ar = 3

    var title: String {
        switch self {
        case .library:  return "GEAR LIBRARY"
        case .main:     return "MY RIG"
        case .controls: return "CONTROLS"
        case .ar:       return "PEDAL AR"
        }
    }

    var previous: AppPage? { AppPage(rawValue: rawValue - 1) }
    var next: AppPage? { AppPage(rawValue: rawValue + 1) }
}

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
                        ControlBoardView()
                            .tag(AppPage.controls)
                        ARPedalSetupView()
                            .tag(AppPage.ar)
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
            navArrow(systemName: "chevron.left", target: page.previous)
            Spacer()
            Text(page.title)
                .font(.caption.weight(.bold))
                .tracking(2)
                .foregroundStyle(RigTheme.textMuted)
            Spacer()
            navArrow(systemName: "chevron.right", target: page.next)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(RigTheme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
    }

    private func navArrow(systemName: String, target: AppPage?) -> some View {
        Button {
            if let target { withAnimation(.easeInOut(duration: 0.28)) { page = target } }
        } label: {
            Image(systemName: systemName)
                .font(.title3.weight(.bold))
                .foregroundStyle(target != nil ? RigTheme.amber : RigTheme.textMuted.opacity(0.35))
                .frame(width: 46, height: 30)
                .contentShape(Rectangle())
        }
        .disabled(target == nil)
    }
}

#Preview {
    MainView()
        .environmentObject(RigStore.preview)
        .preferredColorScheme(.dark)
}
