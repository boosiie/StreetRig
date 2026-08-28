//
//  MainView.swift
//  StreetRig
//
//  The app shell: a RETRACTABLE left MY GEAR drawer and a bottom control panel
//  frame a center area that pages between four screens — the gear library, the
//  rig, the AR pedal setup, and the player's profile. Move between them with the
//  top arrows, by swiping the center area, or with a decisive horizontal swipe
//  across the header — the dots under the title say which page you're on. A
//  tapped rig component zooms into a control overlay.
//
//  THE DRAWER IS THE PLAYER'S, NOT THE APP'S. The rail is 150 of the 874 points
//  a landscape-only phone has, and whether that is worth spending depends
//  entirely on what is being done with the app: setting a rig up at a desk wants
//  the gear in reach, a phone on the floor with a guitar over it wants the floor.
//  The app used to answer that question for the player by hiding the rail on the
//  pages it guessed did not want it; now the rail is on all four and a tab on its
//  right edge retracts it, with each page only choosing where it STARTS (see
//  `AppPage.remembersGearDrawer`).
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

    /// Whether opening or closing the MY GEAR drawer ON THIS PAGE is a preference
    /// worth keeping, or a one-off reach.
    ///
    /// THE ONE PER-PAGE EXCEPTION IN THIS FILE, and it is deliberately a single
    /// exhaustive expression rather than an `if page == .ar` sprinkled through the
    /// shell — the header above is right that scattered special cases make the
    /// other pages unpredictable, and an exhaustive switch at least makes a fifth
    /// page a compile error instead of a silent default.
    ///
    /// LIBRARY and RIG are where a rig gets built: gear is dragged out of the
    /// drawer onto the stage and into it off the library grid, so how the player
    /// leaves it there is how they want the app to open. AR and PROFILE have
    /// nothing to drag onto by default — AR is a real floor seen through a lens
    /// where every point of chrome is a point of floor a propped phone cannot
    /// show, and profile wants its width for a name field — so they start closed
    /// every time, and pulling the drawer out there is a reach for one thing, not
    /// a change of mind about how the app opens.
    var remembersGearDrawer: Bool {
        switch self {
        case .library, .main: return true
        case .ar, .profile:   return false
        }
    }

    /// Whether the floating TONES square sits on this page's right edge.
    ///
    /// THE RIG PAGE ONLY, and written as an exhaustive switch for the same
    /// reason `remembersGearDrawer` is: a fifth page should be a compile error
    /// here, not a silent default.
    ///
    /// A preset rebuilds the amp, the cab and the board and then sets thirty
    /// knobs, and every one of those things is drawn on the rig page. Pressing
    /// it from the library or the profile would be pressing a button whose whole
    /// effect happens somewhere you cannot see — and on AR the header is already
    /// explicit that every point of chrome is a point of floor a propped phone
    /// cannot show.
    var showsTonePresets: Bool {
        switch self {
        case .main:                    return true
        case .library, .ar, .profile:  return false
        }
    }
}

struct MainView: View {
    @EnvironmentObject var store: RigStore
    /// Observed only to freeze the pager while an AR pedal is being lifted off its
    /// switch — see `ARSlotLift`. Two renders per lift, not one per finger move.
    @EnvironmentObject private var slotLift: ARSlotLift
    @EnvironmentObject var drag: RigDragController
    /// The tutorial. Observed by the shell for three things only: which page the
    /// tour wants to be on, and whether the trash target or the gear drawer has to
    /// be shown while the step that explains it is up. Everything else the tour
    /// does, it draws itself in `CoachMarkOverlay`.
    @EnvironmentObject private var onboarding: OnboardingCoordinator
    @State private var focused: RigComponent?
    @State private var page: AppPage = .main
    /// Where the library should open when something sends the player there — the
    /// no-amp warning, so far. Consumed by LibraryContentView.
    @State private var libraryDestination: LibraryContentView.Drill?
    @State private var showCredits = false

    /// The TONES page, over the shell rather than inside the pager — see
    /// `PresetsView`'s header for why it is not a fifth `AppPage`.
    @State private var showingPresets = false

    /// HOW THE PLAYER LIKES THE DRAWER, and WHERE IT IS RIGHT NOW. Two values on
    /// purpose, because they are two different questions: the preference is a
    /// standing answer, the state is what this page is showing at this moment.
    /// Collapsing one into the other would mean a reach for the drawer on the AR
    /// page silently rewrote how the rig page opens tomorrow.
    @AppStorage("streetrig.gearDrawerOpen") private var drawerOpenPreference = true
    @State private var drawerOpen = true

    /// Whether this page's content is a live camera feed, which is the one thing
    /// the AR page still gets treated differently for.
    ///
    /// It used to be called `immersive` and it used to hide the nav bar, the rail
    /// and the panel — the whole of the app's chrome — because 50 + 150 + 77 points
    /// of it was two thirds of the floor a propped phone was trying to show. Two of
    /// those three are now the player's to reclaim with the drawer, and the nav bar
    /// came back for consistency, so what is left is narrow enough to say plainly:
    /// this page is a camera, so it keeps the bottom 77 points and runs to the glass.
    private var cameraPage: Bool { page == .ar }

    /// Is the rail on screen? The player's answer, unless the tour needs it out —
    /// exactly the arrangement `GearTrashTarget.forcedVisible` already uses, and for
    /// the same reason: a spotlight cut over a rail that is not there is a hole in
    /// the screen with nothing in it.
    private var drawerShown: Bool { drawerOpen || onboarding.revealsGearRail }

    var body: some View {
        ZStack {
            RigTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // ON EVERY PAGE NOW, THE AR ONE INCLUDED. The player asked for the
                // same bar everywhere over a few more points of floor: a camera
                // page with no header is a page with no visible way off it, and
                // the pager's swipe is invisible over a live feed. The width it
                // used to buy is the drawer's to give back instead.
                topNav
                HStack(spacing: 0) {
                    // THE RAIL IS ON ALL FOUR PAGES, and how much of it you see is
                    // the tab's business, not the page's — see `gearDrawerTab`.
                    if drawerShown {
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
                    // AN OVERLAY ON THE PAGER, NOT A SIBLING BESIDE IT — and that
                    // is a correction, made on a device with the app in hand.
                    //
                    // As a sibling the tab owned a column in the stack, and a column
                    // is full height: 22 points wide from the nav bar to the control
                    // panel, of which the handle covered 56. Every other point of it
                    // showed the shell's background through, so what read on screen
                    // was not a handle on the rail but a BLACK STRIP down the side of
                    // the page with a chevron halfway along it.
                    //
                    // Floating costs the page nothing and leaves only the handle. The
                    // objection to it was that a floating tab covers whatever the page
                    // puts at its leading edge and takes taps meant for that — true,
                    // but it is 44×56 points at the vertical centre of one edge, which
                    // is the same region it was covering as a sibling anyway. A strip
                    // the height of the screen was the larger of the two costs.
                    //
                    // `.gearRail` still stays on `CollectionTabView` alone: the tour's
                    // spotlight is for the rail, and a handle stuck to the outside of
                    // that rect would widen the hole by a tab for no reason.
                    .overlay(alignment: .leading) { gearDrawerTab }
                    // THE OTHER EDGE, AND DELIBERATELY NOT THE SAME SHAPE. The
                    // drawer tab is flush to its edge and half a rounded
                    // rectangle, because it is the visible handle of a thing that
                    // is mostly off screen. This is not a handle: nothing is
                    // parked behind it, so it floats clear of the edge as a whole
                    // square with the card treatment every other liftable thing
                    // in this app has. Two controls on two edges that behave
                    // differently should not look the same.
                    .overlay(alignment: .trailing) {
                        if page.showsTonePresets { tonePresetsTab }
                    }
                    // The trash lives HERE — top-left of the centre area, just
                    // past the MY GEAR rail — so it is somewhere you drag TO,
                    // equally reachable from the rail and from the rig stage.
                    //
                    // An overlay ON the TabView, not a page inside it: it has to
                    // stay put while the pages swipe under it, and it must sit
                    // outside the UIPageViewController bridge, where measurements
                    // still mean what they say (see RigDragController.appRootOrigin).
                    .overlay(alignment: .topLeading) {
                        // ON EVERY PAGE, because the question is "can a drag start
                        // here", not "which page is this" — and the answer is now
                        // yes everywhere. The drawer reaches all four pages, so a
                        // rail card can be lifted on any of them; the stage and the
                        // AR footswitches are drag sources in their own right. This
                        // used to be switched off on AR along with the rail, which
                        // left a pedal pulled off a switch there with nowhere to
                        // drop — a drag with no target is worse than a visible bin.
                        //
                        // Costs nothing when idle: it is drawn at zero opacity and
                        // takes no hits until something is actually moving.
                        GearTrashTarget(forcedVisible: onboarding.revealsTrash)
                            .padding(.leading, 10)
                            .padding(.top, 8)
                    }
                    // The pager's own rectangle, tagged OUTSIDE the bridge. It is
                    // both the spotlight for the four "here is a page" steps and
                    // the fallback for any anchor that comes back out of a page
                    // looking wrong — see CoachMarkAnchor's header.
                    .coachMarkTarget(.pageArea)
                }
                // THE CAMERA RUNS TO THE GLASS; THE NAV BAR DOES NOT.
                //
                // This modifier used to sit one level out, on the VStack, reading
                // `immersive ? .all : []`, and the note it carried is still true and
                // still load-bearing: put it a level DOWN, on the TabView, and the
                // page measured 750×293 on a screen larger in both directions,
                // because a child cannot grow past a parent that has already been
                // inset — the HStack and the VStack had taken the insets before the
                // page ever saw them.
                //
                // What changed is that the nav bar is now on the camera page too. A
                // bar inside a stack that ignores the safe area puts its left arrow
                // under a landscape notch inset, so the VStack cannot be the one to
                // ignore it any more. This band — rail, tab and pager — is a direct
                // child of a stack that has NOT consumed its insets, which is the
                // one condition the failure above was missing, so it can still take
                // them itself. The bar keeps the safe area; everything under it
                // gives it up.
                //
                // `.horizontal` and `.bottom`, never `.all`: there is nothing above
                // this band to reclaim — the nav bar is up there — and `.top` would
                // pull it up underneath the bar it is supposed to sit below.
                //
                // THE PRICE, SAID OUT LOUD: the drawer tab is in this band, so on the
                // camera page it parks against the glass rather than against the safe
                // area, which in one of the two landscape orientations puts it beside
                // the sensor housing. It is the one control out there and it is still
                // whole and still 44 points to aim at; the alternative is a black bar
                // down the side of a page whose entire job is to show the floor.
                .ignoresSafeArea(edges: cameraPage ? [.horizontal, .bottom] : [])
                // THE ONE PIECE OF CHROME THE CAMERA PAGE STILL TAKES BACK. On the
                // AR page the control panel is 77 pt of floor the player cannot
                // see, and unlike the rail it has no handle to pull it out with —
                // it is out of scope here on purpose. It keeps its coach-mark
                // target for every page that still shows it.
                if !cameraPage {
                    ControlPanelView()
                        .coachMarkTarget(.controlPanel)
                }
            }
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

            // (A small chevron used to float here on the AR page. It existed only
            // because hiding `topNav` took the only visible way off that page with
            // it — its own comment said so. The bar is back, and a second, quieter
            // exit sitting on top of the real one is just something else to explain.)

            if showingPresets {
                PresetsView(onClose: {
                    withAnimation(.easeInOut(duration: 0.24)) { showingPresets = false }
                })
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(1)
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
        .onChange(of: page) { _, current in
            onboarding.currentPage = current
            // Arriving somewhere puts the drawer where that page starts. Animated
            // by hand because an `onChange` body runs in its own transaction — the
            // `withAnimation` that moved the page is long finished by the time this
            // is called, so without this the rail would blink in or out beside a
            // page that is still sliding.
            syncGearDrawer(to: current, animated: true)
        }
        .onAppear {
            onboarding.currentPage = page
            // Launching is an arrival too, and the one that makes the preference
            // worth storing at all: the app opens on RIG, so this is where a player
            // who closed the drawer last time finds it still closed.
            syncGearDrawer(to: page, animated: false)
        }
    }

    // MARK: - The MY GEAR drawer

    /// The handle on the rail's right edge, and the whole of the drawer's control
    /// surface — there is deliberately no second way to collapse it, no settings
    /// toggle and no gesture, because a control the player cannot find is worse
    /// than one that is always in the same place.
    ///
    /// Small on purpose: 22 × 56 is a handle, not a button bar, and it is parked
    /// against the glass for the whole time the rail is away. The hit area is
    /// another matter — see the padding pair below.
    private var gearDrawerTab: some View {
        Button { toggleGearDrawer() } label: {
            // Points the way it will MOVE, not at what is behind it: open, it will
            // travel left and take the rail with it.
            Image(systemName: drawerShown ? "chevron.left" : "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(RigTheme.textMuted)
                .frame(width: Self.drawerTabWidth, height: Self.drawerTabHeight)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                           bottomTrailingRadius: 7, topTrailingRadius: 7)
                        .fill(RigTheme.surface)
                )
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                           bottomTrailingRadius: 7, topTrailingRadius: 7)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
                // A 22pt-wide target is not a legal one. Pad the touchable area out
                // to 44 and take the shape at THAT size — the extra 22 points hang
                // over the page, invisible. Nothing has to be handed back: this
                // floats, and an overlay reserves no width to begin with.
                .padding(.trailing, Self.drawerTabHitWidth - Self.drawerTabWidth)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(drawerShown ? "Hide the MY GEAR rail" : "Show the MY GEAR rail")
        // DRAGGING GEAR IN STILL HAS TO WORK. Pulling a card off the GEAR LIBRARY
        // grid onto the rail is the only way to add gear to the collection, so a
        // collapsed rail would silently delete that path. Hovering the tab springs
        // the drawer open — and the tab takes the drop itself, through the same
        // `store.addToCollection` the rail calls, rather than trusting the rail to
        // have arrived under the finger in time to catch it.
        .dropDestination(for: GearItem.self) { items, _ in
            var added = false
            for item in items where !store.isOwned(item) {
                store.addToCollection(item)
                added = true
            }
            return added
        } isTargeted: { targeted in
            // Opening to receive a drop is the app getting out of the way, not the
            // player changing their mind — so it moves the drawer and writes
            // nothing. Come back to this page later and it is closed again.
            guard targeted, !drawerOpen else { return }
            moveGearDrawer(to: true, animated: true)
        }
    }

    private static let drawerTabWidth: CGFloat = 22
    private static let drawerTabHeight: CGFloat = 56
    /// The 44pt minimum a target has to be to be worth aiming at.
    private static let drawerTabHitWidth: CGFloat = 44

    /// THE TONES SQUARE — the way into `PresetsView`, floating at the vertical
    /// centre of the rig page's trailing edge.
    ///
    /// LABELLED, NOT JUST DRAWN. A lone glyph on an edge is a guess, and the one
    /// guess a knob icon invites here is "this opens the amp's controls", which
    /// is the tap the player already has (the amp itself). Four letters under it
    /// costs nine points and removes the guess.
    ///
    /// IT CLEARS THE ZOOM FIRST. Tapping a pedal opens `ComponentDetailView` over
    /// this whole area; leaving that up under a full-screen presets page would
    /// mean closing the presets and finding a zoomed pedal nobody asked to still
    /// be there.
    private var tonePresetsTab: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.24)) {
                focused = nil
                showingPresets = true
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "dial.medium.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(RigTheme.amber)
                Text("TONES")
                    .font(.system(size: 7, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(RigTheme.textMuted)
            }
            .frame(width: Self.presetsTabSide, height: Self.presetsTabSide)
            .rigCard(cornerRadius: 11, stroke: RigTheme.amber.opacity(0.38), lifted: true)
            .padding(.trailing, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tone presets")
        .accessibilityHint("Loads a whole rig — amp, cabinet, pedals and knob settings")
    }

    /// 50, not 44. The minimum is the floor for something you have to AIM at;
    /// this one floats over a 3D stage the player is also dragging to orbit, and
    /// the extra six points are what keep a deliberate press apart from the
    /// start of a spin.
    private static let presetsTabSide: CGFloat = 50

    /// The tab was pressed. THE ONLY PLACE THE PREFERENCE IS EVER WRITTEN, and
    /// only from the pages that keep one — see `AppPage.remembersGearDrawer`.
    private func toggleGearDrawer() {
        let open = !drawerOpen
        moveGearDrawer(to: open, animated: true)
        if page.remembersGearDrawer { drawerOpenPreference = open }
    }

    /// Slide the drawer, deciding nothing about how the app opens next time.
    private func moveGearDrawer(to open: Bool, animated: Bool) {
        guard drawerOpen != open else { return }
        guard animated else {
            drawerOpen = open
            return
        }
        // The pager's curve and the nav arrows', not a third one: this moves the
        // same 150pt band across the screen that those move a whole page across,
        // and a shell with three motion vocabularies reads as three apps.
        withAnimation(.easeInOut(duration: 0.28)) { drawerOpen = open }
    }

    /// Put the drawer where `page` says it starts: the remembered state on the
    /// pages that keep one, shut on the pages that do not.
    private func syncGearDrawer(to page: AppPage, animated: Bool) {
        moveGearDrawer(to: page.remembersGearDrawer ? drawerOpenPreference : false,
                       animated: animated)
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
                    .font(.caption.weight(.bold))
                    .tracking(2)
                    .foregroundStyle(RigTheme.textMuted)
                pageDots
            }
            Spacer()
            navArrow(systemName: "chevron.right", target: page.next)
            creditsButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(RigTheme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
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
