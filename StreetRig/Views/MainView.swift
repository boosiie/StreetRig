//
//  MainView.swift
//  StreetRig
//
//  The app shell: a persistent left MY GEAR rail and bottom control panel frame a
//  center area that pages between three screens — the gear library (left), the
//  rig (center), and the AR pedal setup (right). Move between them with the top
//  arrows, by swiping the center area, or with a decisive horizontal swipe across
//  the header — the dots under the title say which page you're on. A tapped rig
//  component zooms into a control overlay.
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
                ControlPanelView()
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
    }

    // MARK: - Top navigation (arrows + current page title)

    private var topNav: some View {
        HStack(spacing: 0) {
            navArrow(systemName: "chevron.left", target: page.previous)
            Spacer()
            VStack(spacing: 5) {
                Text(page.title)
                    .font(.caption.weight(.bold))
                    .tracking(2)
                    .foregroundStyle(RigTheme.textMuted)
                pageDots
            }
            Spacer()
            navArrow(systemName: "chevron.right", target: page.next)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(RigTheme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
        .contentShape(Rectangle())   // the gaps beside the title are swipeable too
        .gesture(headerSwipe)
    }

    /// The visible hint that the header pages, and the only place the pager's
    /// position is shown — the TabView's own dots are switched off.
    private var pageDots: some View {
        HStack(spacing: 5) {
            ForEach(AppPage.allCases, id: \.self) { dot in
                Circle()
                    .fill(dot == page ? RigTheme.amber : RigTheme.textMuted.opacity(0.35))
                    .frame(width: 5, height: 5)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: page)
    }

    /// Swipe the header to page. Deliberately hard to trigger by accident: it only
    /// commits past a real distance AND when the movement is clearly horizontal, so
    /// drifting sideways while reaching for a chevron leaves the page alone.
    private var headerSwipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) >= 60, abs(dx) > abs(dy) * 2 else { return }
                guard let target = dx < 0 ? page.next : page.previous else { return }
                withAnimation(.easeInOut(duration: 0.28)) { page = target }
            }
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
                // Per-category, exactly as the rail card frames it. A fixed size
                // here squashed wide gear (an amp is 74x50, not 44x56) and the
                // art's own clipShape then cropped what spilled out.
                .frame(width: item.category.artSize.width,
                       height: item.category.artSize.height)
                .frame(width: 74, height: 56)   // uniform ghost box, art centred
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
