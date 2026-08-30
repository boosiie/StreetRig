//
//  PreferencesView.swift
//  StreetRig
//
//  THE SETTINGS PAGE — and the app's FIRST settings surface, which is the point
//  of it.
//
//  It began as the right-hand half of the profile page and is now a page of its
//  own, reached from a button there. Sharing that page made it two unrelated
//  screens either side of a divider — who you are on the left, every switch in
//  the app on the right — and neither got the width it wanted.
//
//  WHY IT EXISTS AT ALL. Two real preferences already shipped, and until now the
//  only way to set either was a checkbox inside `DeviceOfferPrompt` — a card that
//  appears when hardware is plugged in and vanishes when it is answered. Tick
//  "don't ask again" once and there was no route back: the question that would
//  have offered the checkbox was the very thing you had switched off. A
//  preference you can turn on and never off is a trap, not a setting.
//
//  EVERY SWITCH ON THIS PAGE DOES SOMETHING. There are no placeholders here and
//  none should be added — a settings page that is half inert teaches the player
//  that none of it works, and then the half that does gets ignored too. The
//  "Help & guides" section shipped for one release as a bare heading over a
//  single sentence, for exactly this reason: a heading is an honest promise, a
//  greyed-out button is not. The rule outlived the section and still applies to
//  anything added next.
//
//  HELP & GUIDES IS NO LONGER HERE. It sits on the PROFILE page itself now, one
//  swipe away and behind no button — see `HelpGuidesPanel`, which carries the
//  reasoning. What is left on this page is switches, which is what it is for:
//  none of those four rows changed a value, and the people who needed them were
//  the least likely to go looking at the bottom of a settings list.
//
//  WHERE THE VALUES GO. Straight into `UserDefaults`, under the keys registered
//  in `AppPreferences` — including the two audio ones, which the audio engine
//  also owns copies of. The reasoning for writing the keys rather than binding to
//  `AudioEngineController` is written out in full at the top of `AppPreferences`;
//  it is a decision about audio-engine lifetime, and it is worth reading before
//  changing anything here.
//
//  LANDSCAPE. Rows are as short as a 31pt system switch allows and the page
//  scrolls, because it is barely 300pt tall on a phone. The switches are NOT
//  shrunk to buy rows back — they are the touch targets, and a settings page you
//  have to aim at is worse than one you have to scroll. Row text is capped at
//  `textMeasure` for the opposite reason: the page is 854pt WIDE, and a line
//  allowed to fill that is a line nobody scans.
//

import SwiftUI
import StreetRigEngine

struct PreferencesView: View {
    // Audio devices — see the file header and `AppPreferences`.
    @AppStorage(AppPreferences.asksAboutNewDevices) private var asksAboutNewDevices = true
    @AppStorage(AppPreferences.autoAdoptNewDevices) private var autoAdoptNewDevices = true

    // Display.
    @AppStorage(AppPreferences.stage3D) private var stage3D = true
    @AppStorage(AppPreferences.keepScreenAwake) private var keepScreenAwake = true

    /// Set for a few seconds after "Show hints again" so the button visibly did
    /// something. Without it the action is invisible — the hints it re-arms are
    /// on another page and only fire on the next visit — and an action with no
    /// feedback reads as broken.
    @State private var hintsResetAt: Date?

    /// Back to the profile page. Settings is its own page now, so it owns a
    /// title bar and a way out rather than being a column somebody scrolled past.
    var onClose: (() -> Void)?

    /// DELIBERATELY PLAIN, AND THAT IS THE DESIGN.
    ///
    /// This was a column of `rigCard`s — every row its own rounded, shadowed,
    /// warm-edged tile, the same treatment the gear panels and the rig stage use.
    /// On the gear screens that elevation means something: a card is a THING, and
    /// you pick it up and drag it. A checkbox is not a thing. Fifteen tiles of
    /// furniture for fifteen switches read as important, and settings are the one
    /// screen in an app that should read as boring — you come here to change one
    /// value and leave, and anything decorative is in the way of finding it.
    ///
    /// So: no cards. Rows on the page, hairline rules between them, section
    /// headings in the app's small caps. The palette is unchanged, which is what
    /// keeps it StreetRig's settings page rather than a different app's.
    var body: some View {
        VStack(spacing: 0) {
            titleBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    audioSection
                    displaySection
                    privacySection
                }
                .padding(.bottom, 14)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var titleBar: some View {
        HStack(spacing: 10) {
            if let onClose {
                Button(action: onClose) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .bold))
                        Text("Profile")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .contentShape(Rectangle())
                }
                // Quiet: a back affordance should not compete with the screen it is
                // backing out of, and the kit gives it the 44pt floor it lacked.
                .buttonStyle(.rigQuiet)
                .accessibilityLabel("Back to profile")
            }
            Spacer(minLength: 0)
            Text("SETTINGS")
                .rigLegend(10, weight: .bold)
                .foregroundStyle(RigTheme.textMuted)
            Spacer(minLength: 0)
            // Balances the back button so the title sits on the centre of the
            // bar rather than drifting — the same trick `MainView.topNav` uses.
            Color.clear.frame(width: 62, height: 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle().fill(RigTheme.hairline).frame(height: 1)
        }
    }

    // MARK: - Audio devices

    private var audioSection: some View {
        section("AUDIO DEVICES") {
            toggleRow(
                title: "Ask when something is plugged in",
                note: "A card offers the new input or output before anything switches.",
                isOn: $asksAboutNewDevices
            )
            toggleRow(
                title: "Switch to new devices automatically",
                note: asksAboutNewDevices
                    ? "Only used when asking is off."
                    : "New gear is adopted silently. Off keeps whatever you are already using.",
                isOn: $autoAdoptNewDevices,
                // Nested AND disabled, rather than hidden: hiding it would make the
                // standing answer — which the prompt's checkbox may already have set
                // for you — invisible and unguessable. Greyed out still shows the
                // answer on file and says plainly what would change it.
                enabled: !asksAboutNewDevices,
                indented: true
            )
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        section("DISPLAY") {
            toggleRow(
                title: "3D rig stage",
                note: "Off draws the rig as flat artwork. Easier on the battery.",
                isOn: $stage3D
            )
            toggleRow(
                title: "Keep the screen awake while playing",
                note: "Applies while the rig is live. Off lets the phone lock as usual.",
                isOn: $keepScreenAwake
            )
        }
    }

    // MARK: - Data & privacy

    private var privacySection: some View {
        section("DATA & PRIVACY") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your name, avatar, gear collection, rig and AR pedal slots are files "
                     + "in this app on this phone. StreetRig has no account, no sign-in and "
                     + "sends nothing anywhere — deleting the app deletes the lot.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(RigTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Self.textMeasure, alignment: .leading)

                HStack(spacing: 10) {
                    Button {
                        AppPreferences.resetOneShotHints()
                        withAnimation(.easeOut(duration: 0.2)) { hintsResetAt = Date() }
                    } label: {
                        Text("SHOW HINTS AGAIN")
                    }
                    .buttonStyle(.rigSecondary)

                    if hintsResetAt != nil {
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(RigTheme.signal)
                            .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                }

                Text("One-off tips — like the MY GEAR rail's card hop — are shown once. "
                     + "This arms them again.")
                    .font(.system(size: 10))
                    .foregroundStyle(RigTheme.textMuted.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { rowRule }
        }
    }

    // MARK: - Pieces

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .rigLegend(9.5, weight: .bold)
                .foregroundStyle(RigTheme.textMuted)
                .padding(.horizontal, 20)
                .padding(.top, 17)
                .padding(.bottom, 6)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// How wide a row's words are allowed to get. Past about this the line stops
    /// being scannable, and a settings page is scanned rather than read.
    private static let textMeasure: CGFloat = 430

    /// The rule under a row. Inset from the leading edge so the list reads as a
    /// list rather than as a stack of separate slabs — the standard settings
    /// idiom, and the reason these rows do not need boxes to look grouped.
    private var rowRule: some View {
        Rectangle()
            .fill(RigTheme.hairline)
            .frame(height: 1)
            .padding(.leading, 20)
    }

    /// One preference row: name, one line of what it actually does, a switch.
    ///
    /// The note is not decoration. Both audio preferences are subtler than their
    /// names — "switch automatically" only applies once asking is off — and a
    /// switch whose consequence you have to guess gets left alone.
    private func toggleRow(title: String,
                           note: String,
                           isOn: Binding<Bool>,
                           enabled: Bool = true,
                           indented: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 10) {
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
            // CAPPED, because the page is 854 pt wide and the switch is at the
            // far end of it. Left to fill, a 9.5 pt note ran a measure three
            // times past the point where a line stops being scannable.
            .frame(maxWidth: Self.textMeasure, alignment: .leading)
            Spacer(minLength: 4)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(RigTheme.amberChrome)
        }
        .padding(.leading, indented ? 34 : 20)
        .padding(.trailing, 20)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { rowRule }
        // Dimmed as well as disabled: `.disabled` alone leaves the row looking
        // live on this palette, since a dark theme has little headroom to grey
        // anything out with.
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
        .animation(.easeInOut(duration: 0.2), value: enabled)
    }
}

#Preview {
    PreferencesView()
        .frame(width: 340, height: 250)
        .padding(16)
        .background(RigTheme.background)
        .preferredColorScheme(.dark)
}
