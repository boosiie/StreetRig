//
//  OnboardingCoordinator.swift
//  StreetRig
//
//  THE ONE OBJECT THAT KNOWS WHETHER THE PLAYER IS BEING SHOWN AROUND — which
//  guide is up, which step it is on, and which page the shell has to be showing
//  for that step to point at anything.
//
//  WHY AN OBSERVABLE OBJECT AND NOT `@State` IN `ContentView`. The tour has to
//  DRIVE THE PAGER, and `MainView.page` is private `@State` by design — the
//  header comment there is explicit that page order lives in `AppPage` and
//  nowhere else, and threading a binding out of the shell to satisfy a tutorial
//  would make the tutorial a special case in the one file that exists to have
//  none. So the coordinator asks (`requestedPage`) and the shell answers
//  (`currentPage`), using the shell's own `withAnimation(.easeInOut(duration:
//  0.28))` for the move. The tour looks like the app because it IS the app's
//  page transition; it just isn't the one pressing the chevron.
//
//  WHY THE TWO-WAY HANDSHAKE. A step that points inside the pager is only
//  meaningful once the page it belongs to has actually arrived. Setting
//  `requestedPage` and drawing immediately spotlights the OUTGOING page for a
//  third of a second, which reads as the tour pointing at the wrong thing and
//  then correcting itself. `currentPage` coming back from the shell is what lets
//  the overlay hold the spotlight still until the page settles.
//
//  INTERRUPTION: THE FLOW RESTARTS, IT DOES NOT RESUME. The completion flag is
//  written at exactly two moments — finishing, and skipping — and nowhere in
//  between. So an app killed on step 4 of the tour runs the whole thing again
//  from the setup guide on next launch. That is deliberate:
//
//    • Resuming means persisting a step index, and a step index is a promise
//      about the shape of the tour that a future edit silently breaks — the
//      player gets dropped into step 7 of a tour that now has five steps.
//    • The flow is short and skippable at every step. Restarting costs one tap
//      on SKIP. Being dropped back into the middle of a half-finished overlay
//      with no memory of the first half costs comprehension.
//    • Backgrounding is NOT a kill: state lives in this object, so switching
//      apps and coming back leaves the tour exactly where it was. Only an actual
//      relaunch restarts, which is the case where restarting is right anyway.
//

import SwiftUI
import StreetRigEngine
// `@Published` needs it explicitly in this project's Swift 5 mode — SwiftUI does
// not re-export Combine here, and without it the `ObservableObject` conformance
// simply fails to synthesise.
import Combine

// MARK: - What a step is

/// The gesture a step demonstrates, animated by `GestureGhostView`.
///
/// `dragTo` names a SECOND target rather than carrying a point, for the same
/// reason the first one is a target and not a rect: the drag from the rail to
/// the rig stage has to still be right on an iPad, where both ends are somewhere
/// else entirely.
enum TourGesture: Equatable {
    case none
    case tap
    case press
    case swipeLeft
    case dragTo(CoachMarkTarget)
}

/// One stop on the tour.
struct CoachMarkStep: Identifiable, Equatable {
    let id: Int
    /// What to spotlight. May be resolved to `.pageArea` instead — see
    /// `CoachMarkResolution`.
    let target: CoachMarkTarget
    /// The page the shell must be showing. `nil` means "wherever we are" — used
    /// for the shell furniture that is on screen on all four pages.
    let page: AppPage?
    let title: String
    let detail: String
    let gesture: TourGesture
    /// Corner radius of the hole cut in the scrim. Matches the thing being lit:
    /// the trash is a circle, a card is 12, the rail is a full-height slab.
    let cornerRadius: CGFloat
    /// How far the hole is grown past the target's own bounds. A spotlight
    /// exactly on the bounds looks like a mistake — the edge of the element sits
    /// on the edge of the light and reads as clipped.
    let outset: CGFloat

    init(id: Int, target: CoachMarkTarget, page: AppPage?, title: String, detail: String,
         gesture: TourGesture = .none, cornerRadius: CGFloat = 14, outset: CGFloat = 8) {
        self.id = id
        self.target = target
        self.page = page
        self.title = title
        self.detail = detail
        self.gesture = gesture
        self.cornerRadius = cornerRadius
        self.outset = outset
    }
}

// MARK: - The coordinator

@MainActor
final class OnboardingCoordinator: ObservableObject {

    /// Which guide, if any, is on screen.
    enum Phase: Equatable {
        case idle
        /// The standalone animated hardware/audio walkthrough.
        case setupGuide
        /// Coach marks over the live shell.
        case tour
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var stepIndex = 0

    /// Set by the tour, consumed by `MainView`. Written as a fresh value every
    /// time (never coalesced) so that asking for the page you are already on is
    /// a no-op rather than a stall.
    @Published var requestedPage: AppPage?
    /// Written back by `MainView` once a page transition has actually landed.
    @Published var currentPage: AppPage = .main

    /// True while the FIRST-LAUNCH chain is running, as opposed to a replay from
    /// Preferences. It is what decides whether finishing the setup guide rolls
    /// straight into the tour or simply closes.
    private(set) var isFirstRunChain = false

    /// The flag, written at exactly two moments. See the file header.
    @AppStorage(AppPreferences.onboardingComplete) private var onboardingComplete = false

    // MARK: Steps

    let steps: [CoachMarkStep] = OnboardingCoordinator.tourSteps

    var step: CoachMarkStep? {
        steps.indices.contains(stepIndex) ? steps[stepIndex] : nil
    }

    var isLastStep: Bool { stepIndex >= steps.count - 1 }

    /// The trash target is invisible unless something is being dragged, which
    /// would leave its step spotlighting a hole in the scrim with nothing in it.
    /// The shell reads this and shows it anyway for the length of that one step.
    var revealsTrash: Bool {
        phase == .tour && step?.target == .trash
    }

    /// The MY GEAR rail retracts into a tab, and the player may well have left it
    /// that way — so the same problem, with the same answer: the shell reads this
    /// and holds the drawer open for the two steps that are ABOUT the rail. Both
    /// of them, not just the first: the card the second one points at lives inside
    /// the rail, so a closed drawer would leave that spotlight resolving to the
    /// whole page area instead of one 12pt-radius card.
    ///
    /// The shell must have it open BEFORE the step's rect is read — anchors are
    /// resolved after layout, so forcing it here (rather than animating it open
    /// when the step appears) is what stops the first rail step from lighting a
    /// 22pt sliver of tab.
    var revealsGearRail: Bool {
        guard phase == .tour, let target = step?.target else { return false }
        return target == .gearRail || target == .railCard
    }

    // MARK: Entry points

    /// First launch, called once the splash has finished. Does nothing at all if
    /// the player has been here before.
    func beginFirstRunIfNeeded() {
        #if DEBUG
        // `-CoachMarkTour` drops straight into the coach marks, skipping the
        // setup guide and ignoring the completion flag. Same family as
        // `-ShowDeviceOffer` in the control panel and `-CoachMarkProbe` in
        // CoachMarkAnchor: the tour is a thing you have to LOOK at on several
        // device sizes, and the alternative to a launch argument is clearing a
        // preference and tapping through four guide pages before every check.
        if ProcessInfo.processInfo.arguments.contains("-CoachMarkTour") {
            replayTour()
            return
        }
        #endif
        guard !onboardingComplete, phase == .idle else { return }
        isFirstRunChain = true
        phase = .setupGuide
    }

    /// "Audio setup guide" in Preferences. A replay: it closes when it is done
    /// rather than rolling into the tour.
    func replaySetupGuide() {
        isFirstRunChain = false
        stepIndex = 0
        phase = .setupGuide
    }

    /// "Show me around" in Preferences.
    ///
    /// No navigation to arrange, which is worth stating because it looks like it
    /// should need some: `PreferencesView` is not a screen, it is the right-hand
    /// column of the PROFILE page, which is page four of the very shell the tour
    /// points at. The player is already standing on the live `MainView`. The
    /// first step asks for `.main` and the shell pages over to it.
    func replayTour() {
        isFirstRunChain = false
        stepIndex = 0
        phase = .tour
        requestPage(for: steps.first)
    }

    /// Clears the flag so the whole first-launch chain runs again on next launch.
    /// Also the only practical way to test this feature twice without a reinstall.
    func resetCompletionFlag() {
        onboardingComplete = false
    }

    var hasCompletedOnboarding: Bool { onboardingComplete }

    // MARK: Setup guide → tour

    /// The setup guide finished on its own terms.
    func setupGuideDidFinish() {
        if isFirstRunChain {
            stepIndex = 0
            phase = .tour
            requestPage(for: steps.first)
        } else {
            phase = .idle
        }
    }

    // MARK: Tour movement

    func advance() {
        guard phase == .tour else { return }
        guard stepIndex < steps.count - 1 else { return finish() }
        stepIndex += 1
        requestPage(for: step)
    }

    func retreat() {
        guard phase == .tour, stepIndex > 0 else { return }
        stepIndex -= 1
        requestPage(for: step)
    }

    /// SKIP, from anywhere in either guide.
    ///
    /// Sets the completion flag even though nothing was read. Forcing someone
    /// back through a tutorial they have explicitly declined is how an app earns
    /// resentment, and both guides stay one tap away in Preferences — which is
    /// the difference between skipping and losing.
    func skip() {
        complete()
    }

    /// The last step's FINISH.
    func finish() {
        complete()
    }

    private func complete() {
        let wasFirstRun = isFirstRunChain
        onboardingComplete = true
        isFirstRunChain = false
        stepIndex = 0
        phase = .idle
        // The whole flow is aimed at the profile page: the last thing it asks is
        // that the player names themselves, so that is where it lets go of them.
        //
        // FIRST RUN ONLY. A replay is started from the profile page — it is where
        // the Preferences panel lives — and the tour has already walked the
        // player somewhere else by the time they finish or skip it. Snapping them
        // back to profile at that point would undo a page move they watched
        // happen, so a replay simply lets go wherever the tour got to.
        if wasFirstRun { requestedPage = .profile }
    }

    // MARK: Paging

    /// True while the shell is still moving to the page this step needs. The
    /// overlay holds its spotlight rather than pointing at the outgoing page.
    func isWaitingForPage(_ step: CoachMarkStep?) -> Bool {
        guard let wanted = step?.page else { return false }
        return currentPage != wanted
    }

    private func requestPage(for step: CoachMarkStep?) {
        guard let wanted = step?.page, wanted != currentPage else { return }
        requestedPage = wanted
    }
}

// MARK: - The tour itself

extension OnboardingCoordinator {

    /// TWELVE STOPS, IN THE ORDER SOMEONE ACTUALLY MEETS THE APP.
    ///
    /// Shell furniture first (the rail, the drag, the bin), because that is what
    /// is under the player's thumb the second the splash clears and it is on
    /// every page. Then the rig itself and the panel that starts it. Only then
    /// the pager, which is a thing you learn once you have a reason to leave the
    /// page you are on. It ends on PROFILE with an empty name field, which is
    /// both the last thing to explain and the first thing to do.
    ///
    /// Copy rule for this array: say what the thing IS and what it COSTS or
    /// gives you. "Everything you own lives here" beats "browse your collection".
    static let tourSteps: [CoachMarkStep] = [
        CoachMarkStep(
            id: 0, target: .gearRail, page: .main,
            title: "MY GEAR",
            detail: "Everything you own sits in this rail — amps and cabs on top, "
                  + "pedals below in signal-chain order. It stays put on every page.",
            cornerRadius: 0, outset: 4
        ),
        CoachMarkStep(
            id: 1, target: .railCard, page: .main,
            title: "HOLD, THEN PULL",
            detail: "Press a card until it lifts, then drag it onto the rig and drop "
                  + "it on the part it replaces. A quick tap does nothing on purpose — "
                  + "the rail scrolls.",
            gesture: .dragTo(.rigStage), cornerRadius: 12
        ),
        CoachMarkStep(
            id: 2, target: .trash, page: .main,
            title: "DRAG HERE TO REMOVE",
            detail: "This bin only appears while you are dragging. Drop a piece pulled "
                  + "off the rig and it just comes off the board. Drop one dragged out "
                  + "of the rail and you no longer own it.",
            cornerRadius: 40, outset: 6
        ),
        CoachMarkStep(
            id: 3, target: .rigStage, page: .main,
            title: "MY RIG",
            detail: "Your signal chain as a real rig: amp, cab, pedalboard, guitar. "
                  + "Drag anywhere on it to orbit the whole stage. The TONES square "
                  + "on the right loads a finished one — amp, pedals and all.",
            cornerRadius: 16, outset: 0
        ),
        CoachMarkStep(
            id: 4, target: .rigStage, page: .main,
            title: "TAP A PIECE TO DIAL IT IN",
            detail: "Tap the amp or any pedal and it zooms in with its own knobs. "
                  + "Tap the space around it to come back out.",
            gesture: .tap, cornerRadius: 16, outset: 0
        ),
        CoachMarkStep(
            id: 5, target: .controlPanel, page: .main,
            title: "THE CONTROL PANEL",
            detail: "Where the guitar comes IN, where the sound goes OUT, how loud, "
                  + "and the button that starts it. It is on the bottom of every page. "
                  + "OUTPUT also carries your round-trip latency.",
            cornerRadius: 0, outset: 2
        ),
        CoachMarkStep(
            id: 6, target: .transportZone, page: .main,
            title: "PROCEED STARTS THE RIG",
            detail: "This engages the audio engine and opens the play page with your "
                  + "pedals under your feet. Press it again to stop.",
            gesture: .tap, cornerRadius: 12
        ),
        CoachMarkStep(
            id: 7, target: .header, page: .main,
            title: "FOUR PAGES",
            detail: "Tap the arrows or swipe across this header to move between them. "
                  + "The dots under the title say where you are. The centre of the "
                  + "screen swipes too.",
            gesture: .swipeLeft, cornerRadius: 0, outset: 0
        ),
        CoachMarkStep(
            id: 8, target: .pageArea, page: .library,
            title: "GEAR LIBRARY",
            detail: "Every amp, cab and pedal StreetRig models — far more than you "
                  + "own. Drag one across onto the MY GEAR rail to add it. The noise "
                  + "gate that shuts up a roaring rig lives in here too.",
            cornerRadius: 16, outset: -2
        ),
        CoachMarkStep(
            id: 9, target: .pageArea, page: .ar,
            title: "PEDAL AR",
            detail: "Lay the phone on the floor and the camera watches for your foot "
                  + "over a pedal. Set the slots up here first.",
            cornerRadius: 16, outset: -2
        ),
        CoachMarkStep(
            id: 10, target: .credits, page: .profile,
            title: "CREDITS",
            detail: "Third-party models and licences. Quiet on purpose, and never "
                  + "going away — the stage model's licence depends on it.",
            gesture: .tap, cornerRadius: 10, outset: 4
        ),
        CoachMarkStep(
            id: 11, target: .profileIdentity, page: .profile,
            title: "NOW NAME YOURSELF",
            detail: "Your name and avatar, every setting the app has, both guides "
                  + "again, and the answers to the echo and the noise. Nothing here "
                  + "leaves the phone.",
            cornerRadius: 14, outset: 4
        )
    ]
}
