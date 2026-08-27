//
//  SetupGuideView.swift
//  StreetRig
//
//  THE FIRST THING A NEW PLAYER SEES AFTER THE SPLASH, and the only screen in
//  this app whose subject is not on the screen.
//
//  WHY IT IS A STANDALONE SCENE RATHER THAN COACH MARKS. Everything it teaches
//  is hardware sitting outside the phone: an interface, an adapter, a pair of
//  headphones, the floor. There is nothing in the UI to point at, so pointing at
//  the UI would be a lie about where the problem is.
//
//  WHY IT COMES FIRST, BEFORE THE TOUR. The single most likely way to lose a new
//  player in the first minute is not that they cannot find the AR page. It is
//  that they tap PROCEED with AirPods connected, hear their own playing arrive a
//  fifth of a second late, and conclude the app is broken. It isn't — A2DP
//  buffers by protocol design, and `AudioEngineController` has the measurements
//  — but nobody debugs an amp sim, they delete it. So the audio route gets said
//  first, while it can still prevent something.
//
//  EVERY AUDIO CLAIM ON THESE FOUR PAGES IS TRACEABLE, and deliberately no
//  further than that. The 42 dB, the 172/163 ms round trip, the ≈25 ms wired
//  figure, the speaker compensation and the reason `.allowBluetoothA2DP` stays
//  on are all written down in `AudioEngineController` as things measured on real
//  hardware. Nothing here rounds them into a better story. If those numbers are
//  ever re-measured, this file is the second place to change.
//
//  LANDSCAPE SHAPE: illustration left, prose right, on one row. A stacked card
//  would put the drawing off the bottom of a 382-point-tall viewport.
//

import SwiftUI
import StreetRigEngine

struct SetupGuideView: View {
    /// Reached the end. On a first run the coordinator rolls straight into the
    /// coach-mark tour; on a replay from Preferences it just closes.
    var onFinish: () -> Void

    /// SKIP LEAVES THE WHOLE CHAIN, not just this guide. Pressing skip and being
    /// handed a second full-screen thing to skip is how an app argues with
    /// someone who has already said no — so this sets the completion flag and
    /// puts the player in the app. Both guides stay one tap away in Preferences,
    /// which is what makes that a choice rather than a loss.
    var onSkip: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    /// Which way the last move went, so the page transition slides the right way.
    @State private var forwards = true

    private var pages: [SetupGuidePage] { SetupGuidePage.all }

    var body: some View {
        ZStack {
            backdrop

            VStack(spacing: 0) {
                titleBar
                pageBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    // MARK: - Chrome

    /// The same tolex gradient the splash uses, so the guide reads as the next
    /// beat of the launch rather than as a modal that has interrupted it.
    private var backdrop: some View {
        LinearGradient(colors: [RigTheme.backgroundLift, RigTheme.background],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    private var titleBar: some View {
        HStack(spacing: 10) {
            Text("AUDIO SETUP")
                .font(.system(size: 10, weight: .bold))
                .tracking(2)
                .foregroundStyle(RigTheme.textMuted)
            Spacer(minLength: 0)
            Button(action: onSkip) {
                Text("SKIP")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(RigTheme.textMuted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(RigTheme.surfaceRaised))
                    .overlay(Capsule().strokeBorder(RigTheme.surfaceEdge, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip the audio setup guide")
        }
        .padding(.bottom, 6)
    }

    private var pageBody: some View {
        let page = pages[index]
        return HStack(alignment: .center, spacing: 20) {
            page.illustration(reduceMotion)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 4)

            prose(page)
                // The prose column is capped rather than proportional: past about
                // 46 characters a line stops being scannable, and an iPad would
                // otherwise hand this text a 500-point measure.
                .frame(width: 320, alignment: .leading)
        }
        .id(index)
        .transition(pageTransition)
    }

    /// Slide in the direction of travel — except under Reduce Motion, where the
    /// whole screen is the thing that hurts and pages simply cross-fade.
    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let leaving: Edge = forwards ? .leading : .trailing
        let entering: Edge = forwards ? .trailing : .leading
        return .asymmetric(
            insertion: .move(edge: entering).combined(with: .opacity),
            removal: .move(edge: leaving).combined(with: .opacity)
        )
    }

    private func prose(_ page: SetupGuidePage) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(page.kicker)
                .font(.system(size: 9, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(RigTheme.amber)

            Text(page.title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(RigTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(page.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.system(size: 11.5))
                    .foregroundStyle(RigTheme.textPrimary.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let note = page.measuredNote {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(RigTheme.trim)
                        .padding(.top, 1)
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(RigTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .rigCard(cornerRadius: 9)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(page.title). \(page.paragraphs.joined(separator: " ")) \(page.measuredNote ?? "")")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            dots
            Spacer(minLength: 0)
            if index > 0 {
                chrome("BACK", filled: false) { move(to: index - 1) }
            }
            chrome(index == pages.count - 1 ? "GOT IT" : "NEXT", filled: true) {
                if index == pages.count - 1 { onFinish() } else { move(to: index + 1) }
            }
        }
        .padding(.top, 4)
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(pages.indices, id: \.self) { page in
                Capsule()
                    .fill(page == index ? RigTheme.amber : RigTheme.textMuted.opacity(0.3))
                    .frame(width: page == index ? 18 : 6, height: 6)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: index)
        .accessibilityLabel("Page \(index + 1) of \(pages.count)")
    }

    private func chrome(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(filled ? .black : RigTheme.textPrimary)
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background {
                    if filled {
                        Capsule().fill(RigTheme.amber)
                    } else {
                        Capsule().fill(RigTheme.surfaceRaised)
                            .overlay { Capsule().strokeBorder(RigTheme.surfaceEdge, lineWidth: 1) }
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func move(to next: Int) {
        guard pages.indices.contains(next) else { return }
        forwards = next > index
        withAnimation(reduceMotion ? .easeInOut(duration: 0.30)
                                   : .spring(response: 0.42, dampingFraction: 0.88)) {
            index = next
        }
    }
}

// MARK: - The four pages

/// One page of the guide: the words, and the drawing that moves beside them.
///
/// Held as data rather than as four `View` cases so the order, the count and the
/// dots are one array — the same reasoning as `AppPage` in the shell.
struct SetupGuidePage {
    let kicker: String
    let title: String
    let paragraphs: [String]
    /// The measured fact, set apart because it is the part a sceptical player
    /// will want to check — and because every one of them is a number somebody
    /// took off real hardware rather than a claim this screen invented.
    let measuredNote: String?
    let illustrationKind: Kind

    enum Kind { case plugIn, wireless, outputs, levels }

    @ViewBuilder
    func illustration(_ reduceMotion: Bool) -> some View {
        switch illustrationKind {
        case .plugIn:   PlugInIllustration(reduceMotion: reduceMotion)
        case .wireless: WirelessDelayIllustration(reduceMotion: reduceMotion)
        case .outputs:  OutputChoicesIllustration(reduceMotion: reduceMotion)
        case .levels:   LevelsIllustration(reduceMotion: reduceMotion)
        }
    }

    static let all: [SetupGuidePage] = [
        SetupGuidePage(
            kicker: "1 · GET SIGNAL IN",
            title: "Plug the guitar in",
            paragraphs: [
                "StreetRig wants the pickup, not the room. A guitar interface — an "
                + "iRig or anything like it — goes into the phone and hands the "
                + "string straight to the amp.",
                "No headphone jack? The adapter works. Expect to raise the input: "
                + "the panel sets the hardware preamp for you, but it starts from "
                + "a long way down."
            ],
            measuredNote: "Measured on device: a guitar arriving through the "
                        + "headphone-jack adapter came in 42 dB down — quiet enough "
                        + "that the rig has to invent the difference, and it invents "
                        + "hiss along with it.",
            illustrationKind: .plugIn
        ),
        SetupGuidePage(
            kicker: "2 · THE ONE THAT MATTERS",
            title: "Don't play through Bluetooth",
            paragraphs: [
                "This is what makes people think an amp sim is broken. It isn't. "
                + "A2DP buffers by protocol design: the delay is in the route, not "
                + "in the rig, and no amount of DSP work touches it. AirPlay is worse.",
                "You hear yourself late, blame the app, and delete it. That is the "
                + "whole reason this screen exists."
            ],
            measuredNote: "Measured on an iPhone 17e: a 172 ms round trip, of which "
                        + "the output port alone was 163 — against 1.54 ms of input. "
                        + "A healthy wired rig lands near 25.",
            illustrationKind: .wireless
        ),
        SetupGuidePage(
            kicker: "3 · WHAT TO USE INSTEAD",
            title: "Wired, or the phone itself",
            paragraphs: [
                "Wired headphones, a wired interface, or the phone's own speaker. "
                + "All three are fine. The speaker is what this app was built "
                + "around: phone on the floor, no headphones.",
                "Bluetooth stays switched on deliberately — monitoring wirelessly "
                + "while you noodle is legitimate, and being unable to is worse "
                + "than being late. It just isn't for playing."
            ],
            measuredNote: "On the built-in speaker the engine switches on a "
                        + "compensation stage: a 10 mm driver makes almost nothing "
                        + "below a few hundred Hz, so the sub-bass comes out of the "
                        + "limiter's way and the band it is good at comes up.",
            illustrationKind: .outputs
        ),
        SetupGuidePage(
            kicker: "4 · THEN PLAY",
            title: "Set it, then press PROCEED",
            paragraphs: [
                "INPUT picks the port the guitar arrives on. MASTER is how loud. "
                + "PROCEED starts the engine and drops you on the play page with "
                + "your pedals under your feet.",
                "You will find all of it along the bottom of every page. Nothing "
                + "here is buried."
            ],
            measuredNote: "OUTPUT carries the round-trip figure, live — so what this "
                        + "guide just warned you about is on screen the whole time, "
                        + "with the word \"wireless\" beside it when it applies.",
            illustrationKind: .levels
        )
    ]
}

#Preview(traits: .landscapeLeft) {
    SetupGuideView(onFinish: {}, onSkip: {})
        .environmentObject(RigStore.preview)
        .environmentObject(ProfileStore.preview)
}
