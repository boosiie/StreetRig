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
//  They arrive in TWO PHASES rather than all at once:
//    1. The mark fades and settles onto the true centre of the viewport, alone,
//       and holds there for a beat. Nothing else is on screen.
//    2. The mark lifts to its resting position and the chrome resolves in
//       beneath it, rising a few points as it fades up.
//  The staging is what makes the logo read as the subject and the status line
//  as commentary on it — showing both at once flattens them into one block.
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

    /// Where the mark RESTS IN PHASE TWO. In phase one it sits at 0 — the true
    /// centre of the viewport — and animates to this lift as the chrome arrives.
    ///
    /// 24, not 16. A lift of 16 would centre the icon+wordmark pair exactly
    /// (measured off a real 874×402 frame: at lift 0 the icon centres on 201.0,
    /// but the wordmark hangs to y 290, leaving the pair ~16pt low). Going to 24
    /// seats the pair slightly ABOVE geometric centre, which is deliberate — the
    /// chrome is pinned near the bottom edge, so a mark on the true centre
    /// leaves a big empty band up top and a cramped one below. Sitting it high
    /// evens those bands out. Judged on screen, not derived.
    private let markOpticalLift: CGFloat = -24

    // MARK: - Phasing

    /// How long the mark holds alone on centre before the chrome resolves in.
    /// Long enough to register as a deliberate beat, short enough not to stall.
    private static let markHold: Duration = .milliseconds(1100)

    /// Phase one — the mark fading and settling into place.
    @State private var markIsIn = false

    /// Phase two — the mark lifting and the chrome arriving beneath it.
    @State private var chromeIsIn = false

    @State private var messageIndex = Int.random(in: 0..<messages.count)
    @State private var isBreathing = false
    /// How long the splash holds. Lives HERE rather than in `ContentView` because
    /// the progress bar has to fill over exactly this long — a bar animating to a
    /// duration the view does not own is a bar that lies the moment either number
    /// moves. `ContentView` reads this instead of keeping its own copy.
    ///
    /// When the hold is eventually driven by real warmup rather than a timer, this
    /// becomes the fallback and the bar takes the real fraction.
    public static let splashDuration: Duration = .seconds(4)

    private let rotation = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            backdrop

            // The mark ignores the safe area so it centres on the TRUE viewport
            // centre. Without this it would centre inside the safe area, and the
            // home indicator's ~21pt bottom inset would silently lift it.
            //
            // Phase one holds it at offset 0 (true centre); phase two lifts it
            // to `markOpticalLift` to open up room for the chrome.
            mark
                .opacity(markIsIn ? 1 : 0)
                .scaleEffect(markIsIn ? 1 : 0.94)
                .offset(y: chromeIsIn ? markOpticalLift : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            // The chrome does NOT ignore the safe area — it is bottom-aligned
            // inside it, so the home indicator is respected on every device.
            // It rises as it fades so it reads as arriving, not blinking on.
            statusChrome
                .opacity(chromeIsIn ? 1 : 0)
                .offset(y: chromeIsIn ? 0 : 14)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .onAppear { isBreathing = true }
        .task {
            withAnimation(.easeOut(duration: 0.55)) { markIsIn = true }
            try? await Task.sleep(for: Self.markHold)
            withAnimation(.easeInOut(duration: 0.6)) { chromeIsIn = true }
        }
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
        VStack(spacing: 14) {
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

            // A determinate bar, not the spinner that used to sit beside the text.
            // The splash is a fixed hold, so a bar that fills over it is honest —
            // and it reads as the amp coming up rather than as the app being busy.
            // `amber` and not `amberChrome`: this is a lit indicator, closer to a
            // meter than to a painted control, and light is where saturation belongs.
            ZStack(alignment: .leading) {
                Capsule().fill(RigTheme.hairline)
                Capsule().fill(RigTheme.amber)
                    .frame(width: 150 * progress)
                    .shadow(color: RigTheme.amber.opacity(0.7), radius: 5)
            }
            .frame(width: 150, height: 3)
        }
        .task {
            withAnimation(.linear(duration: Self.splashSeconds)) { progress = 1 }
        }
    }

    /// `splashDuration` as a `TimeInterval`, for the bar's animation.
    private static var splashSeconds: Double {
        Double(splashDuration.components.seconds)
            + Double(splashDuration.components.attoseconds) / 1e18
    }

    /// One status line, typeset. Shared by the visible line and the hidden
    /// sizers so they cannot drift apart.
    private func statusLine(_ message: String) -> some View {
        // Uppercase and properly tracked. Sentence case at 0.03em read as a caption
        // under a logo; caps at legend tracking read as a status line on a device,
        // which is what it is.
        Text(message.uppercased())
            .rigLegend(12, weight: .semibold)
            .lineLimit(1)
            .multilineTextAlignment(.center)
    }

    // MARK: - Decoration

    /// Dark amp backdrop.
    ///
    /// RADIAL, not a top-to-bottom fade. A linear ramp lights the whole top edge
    /// evenly, which reads as a gradient someone applied; a pool centred slightly
    /// above the middle reads as a room with one lamp in it, and it puts the
    /// brightest ground exactly where the mark sits. The centre is at 0.42 rather
    /// than 0.5 because the wordmark hangs below the mark, so the pair's optical
    /// centre is above the frame's.
    private var backdrop: some View {
        RadialGradient(
            colors: [RigTheme.backgroundLift,
                     RigTheme.background,
                     Color(red: 0.047, green: 0.031, blue: 0.020)],
            center: UnitPoint(x: 0.5, y: 0.42),
            startRadius: 0,
            endRadius: 520
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
