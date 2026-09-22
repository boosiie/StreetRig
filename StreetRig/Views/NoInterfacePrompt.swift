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
//  IT ALSO COVERS THE DENIED MICROPHONE, which is the worse of the two states and
//  was originally missed. Refuse the permission prompt and the engine never starts,
//  so `openMicMuted` is never set, so this card never appeared — leaving the one
//  person who cannot hear anything looking at CAN'T START with nowhere to go. Saying
//  no to a microphone is an entirely reasonable thing for a reviewer to do.
//
//  DISMISSIBLE, because the muted mic is genuinely usable: the meters, the pedal
//  chain, the AR page and the whole rig still run on it, which is how the app is
//  tested without hardware. Saying "got it" should not mean saying it again every
//  thirty seconds — so it stays dismissed until the state itself clears, and comes
//  back the next time the rig lands in either one.
//

import SwiftUI
import StreetRigEngine

struct NoInterfacePrompt: View {
    @ObservedObject var audio: AudioEngineController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Dismissed for THIS occurrence only — see the note on re-showing above.
    @State private var dismissed = false

    /// TWO WAYS TO END UP UNABLE TO HEAR THE RIG, and the second one is worse.
    ///
    /// `openMic` is the muted session: the app is running and deliberately silent.
    /// `micDenied` is the player who said no to the microphone prompt — the engine
    /// never starts, `openMicMuted` is never set, and before this the card did not
    /// appear at all. That left the one person with no way to hear anything staring
    /// at CAN'T START and no route forward, which is precisely the dead end the
    /// demo exists to remove. Saying no to a microphone is a completely reasonable
    /// thing for a reviewer to do.
    private enum Reason { case openMic, micDenied }

    private var reason: Reason? {
        if case .error(let message) = audio.status,
           message == AudioEngineController.micDeniedStatus { return .micDenied }
        if audio.openMicMuted { return .openMic }
        return nil
    }

    var body: some View {
        ZStack {
            if let reason, !dismissed {
                Color.black.opacity(0.55).ignoresSafeArea()
                card(reason)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: reason)
        .animation(.easeInOut(duration: 0.2), value: dismissed)
        // Re-arm on `reason` rather than on the mute, so BOTH ways out of this count:
        // the mute lifting, and the permission error clearing. Keyed to the mute
        // alone, a card dismissed on the denied-microphone path stayed dismissed for
        // the life of the session, because nothing on that path ever touches it.
        .onChange(of: reason) { _, now in
            if now == nil { dismissed = false }
        }
    }

    /// Illustration beside the prose rather than above it: the app is landscape
    /// locked, so height is the scarce axis and a stacked card would run off the
    /// top of a 402-point screen.
    private func card(_ reason: Reason) -> some View {
        HStack(alignment: .center, spacing: 18) {
            // Wider than it looks like it needs. The drawing lays the phone on its
            // side and runs the cable in horizontally, so width is what it spends —
            // squeezed to ~200 the guitar crowds the interface box and both labels
            // start wrapping.
            PlugInIllustration(reduceMotion: reduceMotion)
                .frame(width: 250, height: 150)

            VStack(alignment: .leading, spacing: 9) {
                Text(reason == .openMic ? "NO INSTRUMENT INPUT" : "NO INPUT ALLOWED")
                    .rigLegend(11, weight: .bold)
                    .foregroundStyle(RigTheme.amber)

                Text(reason == .openMic ? "Plug in an interface"
                                        : "Microphone access is off")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(RigTheme.textPrimary)

                Text(reason == .openMic
                     ? "StreetRig is on the phone's own mic. It hears the room instead "
                       + "of your pickup, and pointed at the speaker it feeds back — so "
                       + "the output is muted."
                     // Worth saying plainly: an interface arrives as a microphone as far
                     // as iOS is concerned, so refusing the prompt refuses the guitar too,
                     // which is not obvious from the wording iOS uses.
                     : "iOS asks for it before any instrument can reach the app — an "
                       + "interface counts as a microphone too. Turn it on in Settings › "
                       + "Privacy › Microphone.")
                    .font(.system(size: 13))
                    .foregroundStyle(RigTheme.textPrimary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)

                Text(reason == .openMic
                     ? "Any guitar interface fixes it — an iRig or anything like it. "
                       + "Plug one in and StreetRig switches over on its own."
                     : "The demo needs none of that. It plays through the same amp, "
                       + "pedals and cab, with no microphone involved.")
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
