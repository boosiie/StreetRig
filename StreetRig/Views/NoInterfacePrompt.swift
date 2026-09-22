//
//  NoInterfacePrompt.swift
//  StreetRig
//
//  "You need an interface" — the card that explains the silence.
//
//  THE BADGE WAS NOT ENOUGH, and that is the whole reason this exists. When the
//  rig engages on the phone's own microphone the output is muted on purpose
//  (`AudioEngineController.applyOpenMicMute`), and everything else keeps running:
//  the lamp lights, the meters move, PROCEED says LIVE. A caption on the INPUT
//  zone reading "muted · no interface" is true, and it is also eleven points tall
//  on a panel the player is not looking at — they are looking at the pedals,
//  holding a guitar, hearing nothing. Every person who met that read it as a
//  broken app, App Review included.
//
//  So the explanation moves to the middle of the screen and says what to DO. It
//  names the fix — an interface — rather than the symptom, and never mentions
//  headphones: headphones stop the feedback, but they do not get a guitar into
//  the phone, and sending somebody to find a pair is sending them to the wrong
//  shop.
//
//  BORROWED, NOT REBUILT. The card chrome is `DeviceOfferPrompt`'s — dimmed
//  backdrop, lifted card, one amber affirmative — and the drawing is the setup
//  guide's own `PlugInIllustration`, which already shows this exact idea: guitar,
//  interface, phone, in that order. Two pictures of one concept is how they drift
//  apart, and the player has seen this one before, in the tour.
//
//  DISMISSIBLE, because the muted mic is genuinely usable: the meters, the pedal
//  chain, the AR page and the whole rig still run on it, which is how the app is
//  tested without hardware. Saying "got it" should not mean saying it again every
//  thirty seconds — so it stays dismissed until the mute itself clears, and comes
//  back the next time the rig lands in this state.
//

import SwiftUI
import StreetRigEngine

struct NoInterfacePrompt: View {
    @ObservedObject var audio: AudioEngineController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Dismissed for THIS muted session only — see the note on re-showing above.
    @State private var dismissed = false

    var body: some View {
        ZStack {
            if audio.openMicMuted && !dismissed {
                Color.black.opacity(0.55).ignoresSafeArea()
                card
            }
        }
        .animation(.easeInOut(duration: 0.2), value: audio.openMicMuted)
        .animation(.easeInOut(duration: 0.2), value: dismissed)
        // Re-arm the moment the rig is no longer muted, so the next time it lands
        // here the card is new again rather than already spent.
        .onChange(of: audio.openMicMuted) { _, muted in
            if !muted { dismissed = false }
        }
    }

    /// Illustration beside the prose rather than above it: the app is landscape
    /// locked, so height is the scarce axis and a stacked card would run off the
    /// top of a 402-point screen.
    private var card: some View {
        HStack(alignment: .center, spacing: 18) {
            // Wider than it looks like it needs. The drawing lays the phone on its
            // side and runs the cable in horizontally, so width is what it spends —
            // squeezed to ~200 the guitar crowds the interface box and both labels
            // start wrapping.
            PlugInIllustration(reduceMotion: reduceMotion)
                .frame(width: 250, height: 150)

            VStack(alignment: .leading, spacing: 9) {
                Text("NO INSTRUMENT INPUT")
                    .rigLegend(11, weight: .bold)
                    .foregroundStyle(RigTheme.amber)

                Text("Plug in an interface")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(RigTheme.textPrimary)

                Text("StreetRig is on the phone's own mic. It hears the room instead "
                     + "of your pickup, and pointed at the speaker it feeds back — so "
                     + "the output is muted.")
                    .font(.system(size: 13))
                    .foregroundStyle(RigTheme.textPrimary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)

                Text("Any guitar interface fixes it — an iRig or anything like it. "
                     + "Plug one in and StreetRig switches over on its own.")
                    .font(.system(size: 13))
                    .foregroundStyle(RigTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                // The demo is the AFFIRMATIVE, not the escape hatch. Somebody who
                // has just been told they need hardware they do not own should be
                // one tap from hearing what the hardware would buy them — and it is
                // the only way anyone without an interface, App Review included,
                // hears this app at all.
                HStack(spacing: 10) {
                    choice("Got it", filled: false) { dismissed = true }
                    choice("Hear a demo", filled: true) {
                        dismissed = true
                        Task { await audio.startDemo() }
                    }
                }
                .padding(.top, 2)
            }
            .frame(width: 300, alignment: .leading)
        }
        .padding(20)
        .rigCard(cornerRadius: RigTheme.Radius.control, lifted: true)
        .transition(.opacity)
    }

    /// `DeviceOfferPrompt`'s pair of buttons, to the point of sharing its rung
    /// rule: the dismissive one sits ON the card, so it takes RAISED — at
    /// `surface` it is the same tone as the card beneath it and disappears.
    @ViewBuilder
    private func choice(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            let label = Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(filled ? .black : RigTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            if filled {
                label.background(
                    RoundedRectangle(cornerRadius: RigTheme.Radius.panel, style: .continuous)
                        .fill(RigTheme.amber)
                )
            } else {
                label.rigRaised(cornerRadius: RigTheme.Radius.tight)
            }
        }
    }
}

#Preview {
    NoInterfacePrompt(audio: AudioEngineController())
}
