//
//  MainView.swift
//  StreetRig
//
//  The app shell: a persistent left MY GEAR rail and bottom control panel frame a
//  center area that pages between four screens — the gear library, the rig, the
//  AR pedal setup, and the player's profile. Move between them with the top
//  arrows, by swiping the center area, or with a decisive horizontal swipe across
//  the header — the dots under the title say which page you're on. A tapped rig
//  component zooms into a control overlay.
//
//  PAGE ORDER IS `AppPage`'s `rawValue` AND NOTHING ELSE. `previous`/`next` do
//  arithmetic on it and `pageDots` iterates `allCases`, so adding a page is one
//  case plus one `.tag` — the arrows, the dots and both swipes follow for free.
//  Resist adding a special case here; the moment one page is exceptional the
//  other three stop being predictable.
//

import SwiftUI
import StreetRigEngine

enum AppPage: Int, CaseIterable, Hashable {
    case library = 0, main = 1, ar = 2, profile = 3

    var title: String {
        switch self {
        case .library:  return "GEAR LIBRARY"
        case .main:     return "MY RIG"
        case .ar:       return "PEDAL AR"
        case .profile:  return "PROFILE"
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
    /// The tutorial. Observed by the shell for two things only: which page the
    /// tour wants to be on, and whether the trash target has to be shown while
    /// the step that explains it is up. Everything else the tour does, it draws
    /// itself in `CoachMarkOverlay`.
    @EnvironmentObject private var onboarding: OnboardingCoordinator
    @State private var focused: RigComponent?
    @State private var page: AppPage = MainView.initialPage

    /// Which page the shell opens on.
    ///
    /// `-OpenPage library|main|ar|profile` drops straight onto a page in DEBUG
    /// builds. Same family as `-CoachMarkTour` and `-ShowDeviceOffer`: a screen you
    /// have to LOOK at repeatedly, on several device sizes, is a screen worth being
    /// able to open directly — the alternative is three swipes before every check,
    /// and synthetic swipes into a landscape app running in a portrait simulator
    /// frame are exactly as reliable as that sounds.
    private static var initialPage: AppPage {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-OpenPage"), i + 1 < args.count {
            switch args[i + 1] {
            case "library": return .library
            case "ar":      return .ar
            case "profile": return .profile
            default:        return .main
            }
        }
        #endif
        return .main
    }
    /// Where the library should open when something sends the player there — the
    /// no-amp warning, so far. Consumed by LibraryContentView.
    @State private var libraryDestination: LibraryContentView.Drill? = MainView.initialDrill

    /// `-OpenPage library -OpenDrill overdrive` lands on a model grid rather than the
    /// category cards above it. The grid is where the gear CARD lives, so it is the
    /// thing worth being able to open directly; the category screen in front of it is
    /// one tap that a synthetic tap cannot reliably make.
    private static var initialDrill: LibraryContentView.Drill? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-OpenDrill"), i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "ampStack":  return .ampStack
        case "ampCombo":  return .ampCombo
        case "overdrive": return .pedal(.overdrive)
        case "delay":     return .pedal(.delay)
        case "modulation":return .pedal(.modulation)
        default:          return nil
        }
        #else
        return nil
        #endif
    }
    @State private var showCredits = false

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
                    // THE RAIL STANDS DOWN ON TWO PAGES NOW, for two different
                    // reasons that happen to want the same thing.
                    //
                    // On PROFILE, because there is nothing there to drag gear onto,
                    // so all the rail does is take 150 pt off a page that wants the
                    // width for a name field and a settings list.
                    //
                    // On AR, because that page is a real floor seen through a lens
                    // and every point of chrome is a point of floor a propped phone
                    // cannot show the player.
                    if !immersive, page != .profile {
                        CollectionTabView()
                            .coachMarkTarget(.gearRail)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    TabView(selection: $page) {
                        LibraryContentView(openAt: $libraryDestination)
                            .tag(AppPage.library)
                        RigStageView(focused: $focused, onFindAmp: showAmpLibrary)
                            .tag(AppPage.main)
                        ARPedalSetupView()
                            .tag(AppPage.ar)
                        ProfileView()
                            .tag(AppPage.profile)
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
                        // Hidden on the AR page for the same reason the rail is —
                        // but it keeps the tour's forced reveal, so the step that
                        // explains the trash still works everywhere it can be shown.
                        if !immersive {
                            GearTrashTarget(forcedVisible: onboarding.revealsTrash)
                                .padding(.leading, 10)
                                .padding(.top, 8)
                        }
                    }
                    // The pager's own rectangle, tagged OUTSIDE the bridge. It is
                    // both the spotlight for the four "here is a page" steps and
                    // the fallback for any anchor that comes back out of a page
                    // looking wrong — see CoachMarkAnchor's header.
                    .coachMarkTarget(.pageArea)
                }
                // Same reasoning as the rail: on the AR page the control panel is
                // 77 pt of floor the player cannot see. It keeps its coach-mark
                // target for every page that still shows it.
                if !immersive {
                    ControlPanelView()
                        .coachMarkTarget(.controlPanel)
                }
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
            // The STACK keeps its safe area. Ignoring it here was tried and reverted:
            // it does push the app to the glass, but it pushes the CONTENT there too,
            // so the Dynamic Island landed on the gear rail and the centre column's
            // section headers were clipped by the opposite inset.
            //
            // What actually wanted to reach the edge was the chassis, not the
            // controls — so `rigChrome` extends its own plate instead, and the
            // content it wraps stays inset. See `RigMaterials`.
            .ignoresSafeArea(edges: immersive ? .all : [])
            // THE SHELL DOES NOT MOVE FOR THE KEYBOARD, and this one line is the
            // whole reason the profile page's name field is usable.
            //
            // SwiftUI's default is to inset the hierarchy above the keyboard. In
            // PORTRAIT that is right. This app is landscape-only, where the
            // keyboard takes ~230 of 402 points: the shell would have to fit its
            // top nav (50pt) and control panel (77pt) into the 172 that are left,
            // leaving the page itself about 45 points tall — every page, not just
            // the one with the field. The keyboard now simply covers the bottom of
            // the app, which is where the control panel is and where nothing is
            // being typed. Pages with text fields must keep them in the top half;
            // both that do (the library's search box, the profile's name) already
            // sit at the top of their column.
            .ignoresSafeArea(.keyboard, edges: .bottom)

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
        .sheet(isPresented: $showCredits) { CreditsView() }
        // THE TOUR. One reader for every tagged target in the shell, resolving
        // the lot into THIS view's space in a single pass — which is the point
        // of anchors over published frames (see CoachMarkAnchor).
        .overlayPreferenceValue(CoachMarkAnchorKey.self) { anchors in
            GeometryReader { proxy in
                ZStack {
                    CoachMarkOverlay(coordinator: onboarding, anchors: anchors, proxy: proxy)
                    #if DEBUG
                    if CoachMarkProbeOverlay.isEnabled {
                        CoachMarkProbeOverlay(anchors: anchors, proxy: proxy)
                    }
                    #endif
                }
            }
        }
        // The tour ASKS for a page; the shell moves. Using the shell's own
        // transition, deliberately — see OnboardingCoordinator's header.
        .onChange(of: onboarding.requestedPage) { _, requested in
            guard let requested else { return }
            if requested != page {
                withAnimation(.easeInOut(duration: 0.28)) { page = requested }
            }
            // AND THEN CONSUME IT. `requestedPage` used to latch — it kept the
            // last page it was handed — so asking for that same page a second
            // time was not a CHANGE and this handler never ran at all. That is
            // exactly the shape of the "Show me around" bug: finish or skip a
            // tour that left the request sitting on `.main`, swipe to PROFILE by
            // hand (which moves `currentPage` and nothing else), press "Show me
            // around", and the coordinator sets `.main` onto `.main`. Nothing
            // published, the shell never moved, and the walkthrough opened on the
            // profile page pointing at a rail that was not there.
            //
            // Clearing it makes every request a fresh edge, whatever came before.
            onboarding.requestedPage = nil
        }
        // …and reports back once it has landed, so a step that points INSIDE the
        // pager waits for the page instead of spotlighting the outgoing one.
        .onChange(of: page) { _, current in onboarding.currentPage = current }
        .onAppear { onboarding.currentPage = page }
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
            // Balances the credits button opposite, so the title stays centred on
            // the header rather than drifting left by the button's width.
            Color.clear.frame(width: 34, height: 30)
            navArrow(systemName: "chevron.left", target: page.previous)
            Spacer()
            VStack(spacing: 5) {
                Text(page.title)
                    .rigLegend(12)
                    .foregroundStyle(RigTheme.textMuted)
                pageDots
            }
            Spacer()
            navArrow(systemName: "chevron.right", target: page.next)
            creditsButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 3)
        // The nav bar is a piece of the app's chassis, so it is made of something:
        // black anodised plate with a brass hairline along its lit edge. The white
        // 7% separator it used to carry is gone — the plate's own dark bottom stop
        // is the edge now, and a white line on a warm-black app was always a borrowed
        // Material trick rather than a decision.
        .rigChrome()
        .contentShape(Rectangle())   // the gaps beside the title are swipeable too
        .gesture(headerSwipe)
        .coachMarkTarget(.header)
    }

    /// Opens third-party attribution. Deliberately quiet — muted, not amber — since
    /// it is a legal obligation to keep reachable, not a feature to advertise. It
    /// must stay present: the stage model's CC BY licence is conditional on it.
    private var creditsButton: some View {
        Button { showCredits = true } label: {
            Image(systemName: "info.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(RigTheme.textMuted)
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Credits and licences")
        .coachMarkTarget(.credits)
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
                .foregroundStyle(target != nil ? RigTheme.amberChrome
                                               : RigTheme.textMuted.opacity(0.35))
                // 46x30 was one of three sub-minimum targets in this file. The height
                // goes to 44; the bar does NOT grow, because the header's own vertical
                // padding drops from 10 to 3 to pay for it. Same 50pt bar, a target
                // you can actually hit with a guitar on.
                .frame(width: 46, height: 44)
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
                .rigCard(cornerRadius: RigTheme.Radius.control,
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
        .environmentObject(ProfileStore.preview)
        .environmentObject(RigDragController())
        .environmentObject(ARSlotLift())
        .environmentObject(OnboardingCoordinator())
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
        .environmentObject(ProfileStore.preview)
        .environmentObject(drag)
        .environmentObject(ARSlotLift())
        .environmentObject(OnboardingCoordinator())
        .preferredColorScheme(.dark)
}
