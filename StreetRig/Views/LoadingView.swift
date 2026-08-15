//
//  LoadingView.swift
//  StreetRig
//
//  The splash shown before the main screen: centered logo, a wobble-free
//  C-spinner, and a guitar-flavored status line that flips over every 3
//  seconds (randomized so it doesn't start on the same message each launch).
//  A warm amber glow behind the logo "breathes" to keep the screen alive.
//

import SwiftUI
import StreetRigEngine
import Combine

struct LoadingView: View {
    /// Status lines, rotated at random.
    static let messages = [
        "Dialing in the gain",
        "Stomping pedals",
        "Chasing the hum",
        "Grounding the loop",
        "Dialing to 11",
        "Warming up the tubes"
    ]

    @State private var messageIndex = Int.random(in: 0..<messages.count)
    @State private var isBreathing = false
    private let rotation = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            backdrop

            VStack(spacing: 44) {
                AmpLogoView(size: 116)
                    .background(glow)          // glow centered on the icon

                VStack(spacing: 24) {
                    CSpinnerView(size: 38, lineWidth: 3.5)

                    Text(LoadingView.messages[messageIndex])
                        .font(.system(.callout, design: .rounded).weight(.medium))
                        .tracking(0.5)
                        .foregroundStyle(RigTheme.textMuted)
                        .id(messageIndex)                       // new identity → flip transition
                        .transition(.flipDown)
                        .frame(height: 22)
                        .frame(maxWidth: 320)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .onAppear { isBreathing = true }
        .onReceive(rotation) { _ in
            withAnimation(.easeInOut(duration: 0.55)) {
                messageIndex = nextMessageIndex()
            }
        }
    }

    /// Dark amp backdrop (tolex gradient).
    private var backdrop: some View {
        LinearGradient(
            colors: [RigTheme.backgroundLift, RigTheme.background],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    /// Soft warm glow that breathes, centered on the logo. The oversized
    /// frame lets it bleed past the icon without clipping or affecting layout.
    private var glow: some View {
        RadialGradient(
            colors: [RigTheme.amber.opacity(0.20), .clear],
            center: .center,
            startRadius: 0,
            endRadius: 140
        )
        .frame(width: 360, height: 360)
        .scaleEffect(isBreathing ? 1.18 : 0.86)      // grow / shrink
        .opacity(isBreathing ? 1.0 : 0.55)           // brighten / dim
        .animation(
            .easeInOut(duration: 2.6).repeatForever(autoreverses: true),
            value: isBreathing
        )
    }

    /// Pick a different message than the current one.
    private func nextMessageIndex() -> Int {
        guard LoadingView.messages.count > 1 else { return messageIndex }
        var next = messageIndex
        while next == messageIndex {
            next = Int.random(in: 0..<LoadingView.messages.count)
        }
        return next
    }
}

#Preview {
    LoadingView()
        .preferredColorScheme(.dark)
}
