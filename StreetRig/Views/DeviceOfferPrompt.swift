//
//  DeviceOfferPrompt.swift
//  StreetRig
//
//  "Something got plugged in" — the card that asks before switching routes.
//
//  Asked when hardware appears while the app is running, which is usually while
//  the player is standing on the rig screen: the iRig goes in just before
//  Proceed. Nothing is switched until it is answered, EXCEPT that iOS has already
//  moved the output route by the time we hear about it — so for an output this
//  asks whether to keep what iOS chose or fall back to the speaker, which is the
//  only override a session gets. Inputs are ours to set, so nothing changes
//  unless you say so.
//
//  Presented by the control panel as a full-screen cover rather than an overlay
//  so it can darken the whole app: the panel itself is only ~100pt tall.
//

import SwiftUI
import StreetRigEngine

struct DeviceOfferPrompt: View {
    @ObservedObject var audio: AudioEngineController
    @State private var remember = false

    var body: some View {
        if let offer = audio.deviceOffer {
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea()
                card(offer)
            }
            .transition(.opacity)
        }
    }

    private func card(_ offer: AudioEngineController.DeviceOffer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: offer.kind == .input ? "cable.connector" : "headphones")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(RigTheme.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text(offer.kind == .input ? "New input detected" : "New output detected")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(RigTheme.textPrimary)
                    Text(offer.name)
                        .font(.system(size: 14))
                        .foregroundStyle(RigTheme.textMuted)
                        .lineLimit(1)
                }
            }

            Text(offer.kind == .input
                 ? "Switch the guitar input over to it?"
                 : "Keep listening through it?")
                .font(.system(size: 14))
                .foregroundStyle(RigTheme.textPrimary.opacity(0.9))

            Button {
                remember.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: remember ? "checkmark.square.fill" : "square")
                        .font(.system(size: 15))
                        .foregroundStyle(remember ? RigTheme.amber : RigTheme.textMuted)
                    Text("Don't ask me this again")
                        .font(.system(size: 13))
                        .foregroundStyle(RigTheme.textMuted)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                choice("Not now", filled: false) {
                    audio.resolveDeviceOffer(offer, adopt: false, remember: remember)
                    remember = false
                }
                choice(offer.kind == .input ? "Use it" : "Keep it", filled: true) {
                    audio.resolveDeviceOffer(offer, adopt: true, remember: remember)
                    remember = false
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        // A floating dialog, so `lifted:` — a deeper shadow than a card resting in
        // the page. `backgroundLift` here was the old invisible-card bug carried
        // over from DeviceBarView; it is only 1.10:1 against the page behind it.
        .rigCard(cornerRadius: RigTheme.Radius.control, lifted: true)
    }

    @ViewBuilder
    private func choice(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            let label = Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(filled ? .black : RigTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
            // The dismissive choice sits ON the dialog, so it takes the RAISED rung.
            // At `surface` it was the same tone as the card under it and vanished.
            if filled {
                label.background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(RigTheme.amber)
                )
            } else {
                label.rigRaised(cornerRadius: RigTheme.Radius.tight)
            }
        }
    }
}
