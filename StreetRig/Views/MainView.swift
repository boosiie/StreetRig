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
import StreetRigEngine

enum AppPage: Int, CaseIterable, Hashable {
    case library = 0, main = 1, ar = 2

    var title: String {
        switch self {
        case .library:  return "GEAR LIBRARY"
        case .main:     return "MY RIG"
        case .ar:       return "PEDAL AR"
        }
    }

    var previous: AppPage? { AppPage(rawValue: rawValue - 1) }
    var next: AppPage? { AppPage(rawValue: rawValue + 1) }
}

struct MainView: View {
    @EnvironmentObject var store: RigStore
    @EnvironmentObject var drag: RigDragController
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
                // Stage 2: zoom the control panel in over the now-centered model.
                .transition(.scale(scale: 0.82).combined(with: .opacity))
                .zIndex(1)
            }

            // The dragged card's "ghost", following the finger above everything.
            // Isolated in its own view so only it re-renders as the drag moves.
            DragGhostView().zIndex(2)
        }
        // Shared coordinate space so the rail's drag, the ghost, and the rig
        // stage all measure the finger position against the same origin.
        .coordinateSpace(.named("appRoot"))
        // …and where that origin actually sits in UIKit window coordinates, for
        // the one drag that starts in UIKit: a piece lifted off the SceneKit
        // stage. Measured HERE, on the appRoot view itself, because that is the
        // only place the answer can't be wrong (see RigDragController.appRootOrigin).
        .background(appRootOriginReader)
    }

    private var appRootOriginReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { drag.appRootOrigin = proxy.frame(in: .global).origin }
                .onChange(of: proxy.frame(in: .global).origin) { _, origin in
                    drag.appRootOrigin = origin
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

/// The floating preview of the card being dragged, tracking the finger in the
/// shared "appRoot" space. Observes only the drag controller, so the rest of the
/// shell doesn't re-render while the finger moves.
private struct DragGhostView: View {
    @EnvironmentObject private var drag: RigDragController

    var body: some View {
        if let item = drag.item {
            GearArtView(item: item)
                .frame(width: 44, height: 56)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(RigTheme.backgroundLift)
                        .shadow(color: .black.opacity(0.55), radius: 12, y: 5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(RigTheme.amber.opacity(0.85), lineWidth: 1.5)
                )
                .scaleEffect(1.12)
                .position(drag.location)
                .allowsHitTesting(false)
        }
    }
}

#Preview {
    MainView()
        .environmentObject(RigStore.preview)
        .environmentObject(RigDragController())
        .preferredColorScheme(.dark)
}

#Preview("Drag in progress") {
    // The shell mid-drag: ghost on the finger, trash target docked in the rail.
    let drag = RigDragController()
    let store = RigStore.preview
    if let pedal = store.collection.first(where: { $0.category.isPedal }) {
        drag.begin(pedal, at: CGPoint(x: 300, y: 200))
    }
    return MainView()
        .environmentObject(store)
        .environmentObject(drag)
        .preferredColorScheme(.dark)
}
