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
    /// Observed only to freeze the pager while an AR pedal is being lifted off its
    /// switch — see `ARSlotLift`. Two renders per lift, not one per finger move.
    @EnvironmentObject private var slotLift: ARSlotLift
    @EnvironmentObject var drag: RigDragController
    @State private var focused: RigComponent?
    @State private var page: AppPage = .main
    /// Where the library should open when something sends the player there — the
    /// no-amp warning, so far. Consumed by LibraryContentView.
    @State private var libraryDestination: LibraryContentView.Drill?

    /// Whether the current page runs edge to edge with the app chrome hidden.
    ///
    /// Only the AR page does. It is the one page whose content is a real floor seen
    /// through a lens: the nav bar, the gear rail and the control panel between them
    /// were taking about two thirds of the screen, which on a propped phone is two
    /// thirds of the floor the player is trying to aim at. Everywhere else the chrome
    /// IS the app and stays put.
    private var immersive: Bool { page == .ar }

    var body: some View {
        ZStack {
            RigTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                if !immersive { topNav }
                HStack(spacing: 0) {
                    if !immersive { CollectionTabView() }
                    TabView(selection: $page) {
                        LibraryContentView(openAt: $libraryDestination)
                            .tag(AppPage.library)
                        RigStageView(focused: $focused, onFindAmp: showAmpLibrary)
                            .tag(AppPage.main)
                        ARPedalSetupView()
                            .tag(AppPage.ar)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    // A held AR pedal has to be draggable across the page it sits
                    // on, and the pager would otherwise take that movement as a
                    // swipe. Same switch the rail throws for the same reason.
                    .scrollDisabled(slotLift.armed)
                    // The trash lives HERE — top-left of the centre area, just
                    // past the MY GEAR rail — so it is somewhere you drag TO,
                    // equally reachable from the rail and from the rig stage.
                    //
                    // An overlay ON the TabView, not a page inside it: it has to
                    // stay put while the pages swipe under it, and it must sit
                    // outside the UIPageViewController bridge, where measurements
                    // still mean what they say (see RigDragController.appRootOrigin).
                    .overlay(alignment: .topLeading) {
                        if !immersive {
                            GearTrashTarget()
                                .padding(.leading, 10)
                                .padding(.top, 8)
                        }
                    }
                }
                if !immersive { ControlPanelView() }
            }
            // The AR page is aimed at a floor from ankle height and read from
            // standing. Every point the chrome keeps is a point of floor the player
            // cannot see, so on that page it gets the glass.
            //
            // ON THE VSTACK, NOT ON THE TABVIEW INSIDE IT, and that move is the
            // difference between nearly full-screen and full-screen. A child cannot
            // grow past a parent that has already been inset: with this a level lower
            // the page measured 750×293 on a device whose screen is larger in both
            // directions — the safe-area inset had been taken by the stack before the
            // page ever saw it.
            .ignoresSafeArea(edges: immersive ? .all : [])

            // Hiding `topNav` took the only VISIBLE way off this page with it. The
            // pager still swipes, but a full-screen camera feed gives no hint that it
            // does, and "I could not get out of the AR page" is a worse bug than a
            // cramped one. Deliberately small and low-contrast: it is an exit, not a
            // control the player needs mid-song.
            if immersive {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { page = .main }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(RigTheme.textMuted)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.black.opacity(0.45)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                }
                .padding(.leading, 14)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .zIndex(3)
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

    /// The no-amp warning's destination: the amp models, not merely the library's
    /// front page. Someone who has just been told they have no amp should land on
    /// the list of amps, not on a menu that asks them to find it.
    private func showAmpLibrary() {
        libraryDestination = .ampStack
        withAnimation(.easeInOut(duration: 0.28)) { page = .library }
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
///
/// Internal rather than private because the play page is a full-screen cover — a
/// separate hierarchy that the shell's ghost cannot reach over — and a drag with
/// no ghost is a finger dragging nothing.
struct DragGhostView: View {
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
                // Literally in the air: the `lifted` shadow, and an amber edge that
                // means "this one is in your hand" rather than the usual hairline.
                .rigCard(cornerRadius: 12,
                         stroke: RigTheme.amber.opacity(0.85),
                         lineWidth: 1.5,
                         lifted: true)
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
