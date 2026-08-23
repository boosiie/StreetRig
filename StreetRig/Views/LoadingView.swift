//
//  LoadingView.swift
//  StreetRig
//
//  The splash shown before the main screen, composed for the short, wide
//  landscape-only viewport.
//
//  Two layers sit on the amp-tolex backdrop:
//    • THE MARK — the amp logo icon holding the true centre of the viewport,
//      with the STREETRIG wordmark hung beneath it as an overlay so it can
//      never push the icon off centre. A warm amber glow "breathes" behind the
//      icon; it is purely decorative and contributes nothing to layout.
//    • THE CHROME — a wobble-free C-spinner beside a guitar-flavoured status
//      line that flips over every 3 seconds (randomised so it doesn't start on
//      the same message each launch), pinned just above the bottom safe area so
//      it reads as subordinate to the mark rather than competing with it.
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

    // MARK: - Layout

    /// Edge length of the logo icon. The wordmark's size, tracking and gap are
    /// all derived from it, so the mark scales as one unit if this changes.
    private let logoSize: CGFloat = 116

    /// Optical lift for the whole mark, measured off a real 874×402 landscape
    /// screenshot rather than guessed. With a lift of 0 the icon lands on the
    /// exact centre (measured: icon frame y 143…259, centre 201.0, against a
    /// frame centre of 201.0) — but the wordmark then hangs to y 290, so the
    /// icon+wordmark pair reads ~16pt low. Lifting the pair by 8pt splits that
    /// difference: the pair sits 8pt low instead of 16, and the icon sits 8pt
    /// high — 2% of the viewport, small enough that the icon still measures as
    /// centred, large enough to stop the lockup looking like it slipped.
    private let markOpticalLift: CGFloat = -8

    @State private var messageIndex = Int.random(in: 0..<messages.count)
    @State private var isBreathing = false
    private let rotation = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            backdrop

            // The mark ignores the safe area so it centres on the TRUE viewport
            // centre. Without this it would centre inside the safe area, and the
            // home indicator's ~21pt bottom inset would silently lift it.
            mark
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            // The chrome does NOT ignore the safe area — it is bottom-aligned
            // inside it, so the home indicator is respected on every device.
            statusChrome
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .onAppear { isBreathing = true }
        .onReceive(rotation) { _ in
            withAnimation(.easeInOut(duration: 0.55)) {
                messageIndex = nextMessageIndex()
            }
        }
    }

    // MARK: - The mark (icon + wordmark)

    /// The logo icon is the only thing here that occupies layout space, so it
    /// is what gets centred. The glow rides along as a `.background` and the
    /// wordmark as an `.overlay` — neither modifier can grow the icon's frame,
    /// which is exactly what keeps the icon on centre.
    private var mark: some View {
        AmpLogoView(size: logoSize)
            .background(glow)                       // decorative; no layout effect
            .overlay(alignment: .bottom) {
                wordmark
                    // Re-point the overlay's bottom guide to a spot just ABOVE
                    // its own top edge, so aligning it to the icon's bottom
                    // edge hangs the wordmark below the icon with `gap` between.
                    .alignmentGuide(.bottom) { d in d[.top] - wordmarkGap }
            }
            .offset(y: markOpticalLift)
    }

    /// Gap between the bottom of the icon and the cap-height of the wordmark.
    private var wordmarkGap: CGFloat { logoSize * 0.10 }

    /// STREETRIG logotype. All caps, `.rounded` to match the status line, and
    /// tracked wide — the wide tracking is what makes it read as a logotype
    /// rather than a caption. Cream (`panel`) ties it to the logo's faceplate;
    /// amber is deliberately avoided so it doesn't fight the glow behind it.
    private var wordmark: some View {
        let pointSize = logoSize * 0.185            // ≈21.5pt against a 116pt icon
        let track = pointSize * 0.30                // ≈6.4pt — logotype spacing
        return Text("STREETRIG")
            .font(.system(size: pointSize, weight: .semibold, design: .rounded))
            .tracking(track)
            .foregroundStyle(RigTheme.panel)
            .fixedSize()
            // `.tracking` also adds space AFTER the last glyph, which drags the
            // visible letters half a track left of the frame's centre. An offset
            // (not padding) puts the ink back on centre without touching layout.
            .offset(x: track / 2)
            .accessibilityHidden(true)              // the icon already says "StreetRig"
    }

    // MARK: - The loading chrome

    /// Spinner + status line as one horizontal unit. Horizontal, not stacked,
    /// because a short landscape viewport has no vertical room to spare between
    /// the wordmark and the bottom edge.
    private var statusChrome: some View {
        HStack(spacing: 10) {
            CSpinnerView(size: 22, lineWidth: 2.5)

            ZStack {
                // Every message, stacked and hidden, sizes this box to the
                // LONGEST line and to exactly one line's height. That is the
                // original fixed-height guarantee — the layout can't jump as
                // messages change length — now holding on both axes and with no
                // magic constant: the messages measure themselves. The width
                // matters as much as the height here, because the spinner sits
                // beside the text and would otherwise slide on every swap.
                ForEach(LoadingView.messages, id: \.self) { message in
                    statusLine(message).hidden()
                }

                statusLine(LoadingView.messages[messageIndex])
                    .foregroundStyle(RigTheme.textMuted)
                    .id(messageIndex)               // new identity → flip transition
                    .transition(.flipDown)
            }
        }
    }

    /// One status line, typeset. Shared by the visible line and the hidden
    /// sizers so they cannot drift apart.
    private func statusLine(_ message: String) -> some View {
        Text(message)
            .font(.system(.callout, design: .rounded).weight(.medium))
            .tracking(0.5)
            .lineLimit(1)
            .multilineTextAlignment(.center)
    }

    // MARK: - Decoration

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

// Landscape-only app — a portrait preview would misrepresent every layout
// decision on this screen.
#Preview(traits: .landscapeLeft) {
    LoadingView()
        .preferredColorScheme(.dark)
}
