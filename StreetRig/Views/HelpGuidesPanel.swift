//
//  HelpGuidesPanel.swift
//  StreetRig
//
//  HELP & GUIDES, ON THE PROFILE PAGE ITSELF — not behind the settings button.
//
//  WHY IT MOVED. This was the last section of `PreferencesView`, which meant the
//  four things a stuck player needs were three taps and a scroll away: swipe to
//  PROFILE, open Settings, scroll past audio devices, display and privacy, and
//  only then find "Common questions". Every switch above it is something you go
//  looking for having already decided what you want to change. Help is the
//  opposite — you come to it not knowing, which is exactly the state in which
//  nobody scrolls a settings list to the bottom.
//
//  IT IS NOT A SETTING, AND THAT IS THE ARGUMENT. `PreferencesView`'s header
//  makes the case that a settings page is a boring place you visit to change one
//  value and leave. None of these four change a value. Three of them restart a
//  walkthrough and one answers a question, which makes them closer in kind to the
//  name and the avatar next door — things about the person using the app rather
//  than about how the app behaves.
//
//  THIS IS A PARTIAL REVERSAL AND IT IS DELIBERATE. `ProfileView`'s header
//  records why the whole settings page came OFF this page: as a right-hand column
//  it made the profile two unrelated screens sharing a hairline, and neither got
//  the width it wanted. That reasoning still holds for fifteen switches. It does
//  not hold for four rows about learning the app, which have a subject in common
//  with the left-hand column. If a future change adds a fifth and sixth row here
//  and this column starts to read as "the other half of settings" again, that is
//  the signal it has outgrown the page — go back and read the argument in
//  `ProfileView` before adding to it.
//
//  THE ROW STYLE IS SHARED, NOT COPIED. `HelpActionRow` is the row this section
//  used when it lived in settings, lifted out whole. Two near-identical row
//  definitions in two files is how two pages quietly drift into looking like two
//  apps, and the 12/9.5 type pairing here is the same one `PreferencesView`'s
//  `toggleRow` uses on purpose.
//

import SwiftUI
import StreetRigEngine

// MARK: - Why these four, in this order
//
// THE PROMISE THIS SECTION MADE, KEPT. It shipped as a bare heading over one
// sentence because a heading is an honest promise and a disabled button is not;
// the entry points it named are here, plus the FAQ.
//
// FOUR ROWS, AND THE FIRST ONE IS NOT A GUIDE. "Common questions" answers the
// two things people actually report — an echo, and a horrible noise between
// notes — and it lands above the guides because somebody with a noise in their
// ears is not looking to be walked around the app again.
//
// WHY BOTH GUIDES ARE REACHABLE FOREVER. The first-launch chain is skippable at
// every single step, and it has to be — a landscape-locked tutorial with no
// visible way out is the fastest way to make somebody resent an app. That is
// only a fair trade if skipping costs nothing, which means the way back in
// cannot be "reinstall".
//
// "SHOW ME AROUND" NEEDS NO NAVIGATION, which is worth stating because it looks
// like it should. This panel is not a screen: it is the right-hand column of the
// PROFILE page, which is page four of the shell the tour points at. The player
// is already standing on the live `MainView`; the tour's first step asks for the
// rig page and the shell pages over to it. That sentence was written when this
// lived in settings and was wrong for as long as it did — settings IS a screen,
// and it covered the shell the tour was about to drive. Moving the panel back
// onto the page made it true again.

struct HelpGuidesPanel: View {

    /// The tutorial, so this panel can start either guide and clear the flag.
    /// An environment object rather than a preference read: it is UI state that
    /// `ContentView` and `MainView` already share, so reading it adds nothing to
    /// its lifetime.
    @EnvironmentObject private var onboarding: OnboardingCoordinator

    /// The FAQ is a page you GO TO, not a section that expands here. It is six
    /// long answers; inline they would be the whole column and the three guide
    /// rows would end up under a wall of prose. The page it pushes over is owned
    /// by `ProfileView`, which is the only thing that knows what it is covering.
    var onOpenFAQ: () -> Void

    /// Bumped when "run it all again" is pressed, purely so the row re-renders
    /// and re-reads the flag. See `willReplay`.
    @State private var resetAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("HELP & GUIDES")
                .rigLegend(9.5, weight: .bold)
                .foregroundStyle(RigTheme.textMuted)
                .padding(.bottom, 7)

            VStack(spacing: 7) {
                // FIRST, ahead of both guides. The guides are things you re-run;
                // this is the one somebody opens WITH A PROBLEM — a noise in
                // their ears right now — and it is the only row here that
                // answers a question rather than restarting a walkthrough.
                HelpActionRow(
                    title: "Common questions",
                    note: "The echo, the noise between notes, and the gate that shuts them up.",
                    symbol: "questionmark.circle",
                    action: onOpenFAQ
                )

                HelpActionRow(
                    title: "Audio setup guide",
                    note: "Interfaces, adapters, and why Bluetooth makes an amp sim feel broken.",
                    symbol: "cable.connector"
                ) { onboarding.replaySetupGuide() }

                HelpActionRow(
                    title: "Show me around",
                    note: "The walkthrough over the app itself — the rail, the rig, the panel, all four pages.",
                    symbol: "hand.point.up.left"
                ) { onboarding.replayTour() }

                HelpActionRow(
                    title: "Run it all again next launch",
                    note: willReplay
                        ? "Armed. Both guides run on the next launch, as they do for a new player."
                        : "Clears the flag that says you have been shown around.",
                    symbol: willReplay ? "checkmark.circle.fill" : "arrow.counterclockwise",
                    tint: willReplay ? RigTheme.signal : RigTheme.amberChrome
                ) {
                    onboarding.resetCompletionFlag()
                    withAnimation(.easeOut(duration: 0.2)) { resetAt = Date() }
                }
            }
        }
    }

    /// Mirrors the flag rather than the button press, so the row tells the truth
    /// after a replay has quietly set it again — an "Armed" label sitting over a
    /// flag that is back on is exactly the kind of small lie that teaches a
    /// player to stop believing what the app tells them.
    private var willReplay: Bool {
        _ = resetAt          // re-read when the button is pressed
        return !onboarding.hasCompletedOnboarding
    }
}

// MARK: - The row

/// One tappable row: name, one line of what it does, and where it takes you.
///
/// Lifted verbatim out of `PreferencesView` when this section moved, keeping the
/// 12/9.5 type pairing and the 12/9 padding its `toggleRow` still uses — the two
/// pages sit one tap apart and a different rhythm on each would read as two
/// different apps.
struct HelpActionRow: View {
    let title: String
    let note: String
    let symbol: String
    var tint: Color = RigTheme.amberChrome
    let action: () -> Void

    /// How wide a row's words are allowed to get. Past about this the line stops
    /// being scannable, and this is a column you scan rather than read.
    private static let textMeasure: CGFloat = 400

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(RigTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(note)
                        .font(.system(size: 9.5))
                        .foregroundStyle(RigTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: Self.textMeasure, alignment: .leading)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(RigTheme.textMuted.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .rigCard(cornerRadius: RigTheme.Radius.control)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(note)
    }
}

#Preview {
    HelpGuidesPanel(onOpenFAQ: {})
        .environmentObject(OnboardingCoordinator())
        .frame(width: 440, height: 300)
        .padding(16)
        .background(RigTheme.background)
        .preferredColorScheme(.dark)
}
