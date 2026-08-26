//
//  PanelSwitchView.swift
//  StreetRig
//
//  THE SWITCHES COME OFF THE BUTTON ROW AND GO BACK ON THE AMP. A faceplate
//  draws its own toggles — FAT, C45, SAT, the channel selector — and until now
//  they were scenery: the live control was a strip of segmented buttons under
//  the panel, so the player pressed CLEAN in a list while a painted switch sat
//  above it doing nothing. Now the painted switch IS the control. You flick it.
//
//  Three pieces, and each answers something the strip did for free:
//
//  • `PanelToggle` — the switch itself. Tapping advances it one position and the
//    bat SWINGS there, because a switch that changes state without moving reads
//    as a mis-tap. Two-position switches flip; a three-way cycles and wraps.
//  • `PanelLamp` — the jewel next to it, lit while the switch sits on one of the
//    positions the artwork lights up for. Amps say which channel is live with a
//    lamp, not with a highlighted button.
//  • `PanelTooltip` — what the strip's caption used to say. A switch on a panel
//    is a shape with no label at arm's length, so touching one names it, says
//    which way it is now, and gets out of the way after a moment.
//
//  THE MARK GOES ON WHAT WORKS, not on what doesn't — see `LiveRing`. Most of
//  these switches do nothing to the sound yet (the engine reads an amp's profile
//  from its NAME, and only the channel selector reaches the signal path), and the
//  first cut shaded every one of them. That scales backwards: an amp with more
//  unmodelled controls than modelled ones ends up a field of grey patches and
//  reads as broken. So a live switch is RINGED and a dead one is simply left as
//  the artwork drew it — and it still flicks, and its bubble still says plainly
//  that nothing is listening.
//

import SwiftUI
import StreetRigEngine

// MARK: - What's live

/// THE MARK GOES ON WHAT WORKS. Shading everything dead was the obvious way round
/// and it scales backwards: the Ketana has seven unmodelled controls out of
/// thirteen, so a panel full of grey patches reads as a broken amp rather than as
/// a working one with limits. Ringing the live controls instead means the marks
/// thin out as an amp gets less supported, never thicken, and the eye lands on
/// what it can actually use.
///
/// Two rings, not one: amber says live, and the hairline outside it is what keeps
/// the amber visible on a plate that is nearly the same colour — the Rockervert's
/// orange face is within a few points of the app's amber, and a bare ring would
/// vanish into it.
struct LiveRing: View {
    let diameter: CGFloat
    /// The mark has to beat the artwork. Half these plates print a coloured ring
    /// around every knob already, so a hairline reads as more decoration — it has
    /// to be thick, and it has to GLOW, which is the one thing screen-printing
    /// cannot do. That is what makes it look switched on rather than drawn on.
    @State private var lit = false

    var body: some View {
        let gap = max(1, diameter * 0.10)
        let outer = diameter + gap * 2
        ZStack {
            // The halo. Sits under the ring and does the work at arm's length.
            Circle()
                .stroke(RigTheme.amber.opacity(0.75), lineWidth: max(2, diameter * 0.22))
                .frame(width: outer, height: outer)
                .blur(radius: max(1.5, diameter * 0.16))
            // A dark seat, so the amber still reads on a plate that IS amber —
            // the Rockervert's orange face is within a few points of it.
            Circle()
                .strokeBorder(.black.opacity(0.5), lineWidth: max(1.5, diameter * 0.20))
                .frame(width: outer + gap, height: outer + gap)
            Circle()
                .strokeBorder(RigTheme.amber, lineWidth: max(1.5, diameter * 0.15))
                .frame(width: outer, height: outer)
        }
        // One pulse as it arrives — on opening the panel, and again whenever the
        // channel switch hands the rings to the other row. Motion is what a first
        // look actually notices; the ring alone was something you had to be told.
        .scaleEffect(lit ? 1 : 0.82)
        .opacity(lit ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.55)) { lit = true }
        }
        .allowsHitTesting(false)
    }
}

/// The ring, shrunk to sit next to words. The legend has to be the SAME mark or
/// it teaches the wrong thing.
struct LiveRingSwatch: View {
    var diameter: CGFloat = 9
    var body: some View {
        ZStack {
            Circle().fill(RigTheme.cabinet)
                .frame(width: diameter, height: diameter)
            Circle().strokeBorder(RigTheme.amber, lineWidth: max(1.2, diameter * 0.18))
                .frame(width: diameter + 3, height: diameter + 3)
                .shadow(color: RigTheme.amber.opacity(0.8), radius: 2.5)
        }
        .frame(width: diameter + 6, height: diameter + 6)
    }
}

// MARK: - The switch

struct PanelToggle: View {
    @Binding var value: Double
    /// The switch's positions, in order.
    let options: [String]
    /// Drawn size of the toggle body. The frame around it is the touch target.
    let diameter: CGFloat
    /// Nothing behind it is listening yet — so it simply goes unmarked. It still
    /// flicks, and its bubble still says so.
    let inert: Bool
    /// Fired after the flick, with the position it landed on.
    var onFlick: (Int) -> Void = { _ in }

    private var index: Int {
        min(max(Int(value.rounded()), 0), max(0, options.count - 1))
    }

    /// Where the bat points: −1 at the first position, +1 at the last, and
    /// evenly spaced between, so a three-way sits centred in the middle.
    private var throwOffset: CGFloat {
        guard options.count > 1 else { return 0 }
        let t = CGFloat(index) / CGFloat(options.count - 1)
        return (t * 2 - 1) * diameter * 0.22
    }

    var body: some View {
        ZStack {
            // The bezel, sized to cover the toggle painted underneath it.
            Circle()
                .fill(
                    RadialGradient(colors: [Color(white: 0.42), Color(white: 0.13)],
                                   center: .topLeading, startRadius: 0, endRadius: diameter)
                )
                .overlay(Circle().strokeBorder(.black.opacity(0.55), lineWidth: max(0.5, diameter * 0.06)))
                .frame(width: diameter, height: diameter)

            // The bat. It moves; that movement is the whole point.
            Capsule()
                .fill(
                    LinearGradient(colors: [Color(white: 0.96), Color(white: 0.62)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .frame(width: diameter * 0.30, height: diameter * 0.62)
                .offset(y: throwOffset)
                .shadow(color: .black.opacity(0.5), radius: diameter * 0.05, y: diameter * 0.03)
        }
        .frame(width: diameter, height: diameter)
        .overlay { if !inert { LiveRing(diameter: diameter) } }
        .animation(.spring(response: 0.22, dampingFraction: 0.55), value: index)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Circle())
        .onTapGesture {
            guard options.count > 1 else { return }
            let next = (index + 1) % options.count
            value = Double(next)
            onFlick(next)
        }
    }
}

// MARK: - The selector that is a knob, not a toggle

/// Some selectors are ROTARY on the real chassis — the Jazzy Chorus picks
/// VIB / OFF / CHOR with a knob, not a flick switch, and the artwork draws one.
/// A bat toggle sitting in a painted knob well would read as the wrong part.
///
/// So this is the same face `InteractiveKnob` draws, with a pointer that SNAPS
/// between detents instead of sweeping: tapping advances one position and the
/// pointer springs to it. Discrete underneath — the stored value is the option
/// index, exactly as the segmented strip would have written it.
struct PanelSelector: View {
    @Binding var value: Double
    let options: [String]
    let diameter: CGFloat
    let onLight: Bool
    let inert: Bool
    /// Degrees between neighbouring positions. The detents are painted on the
    /// plate, so this matches the artwork rather than filling a full sweep.
    var stepDegrees: Double = 45
    var onFlick: (Int) -> Void = { _ in }

    private var index: Int {
        min(max(Int(value.rounded()), 0), max(0, options.count - 1))
    }

    private var angle: Angle {
        guard options.count > 1 else { return .degrees(0) }
        let span = stepDegrees * Double(options.count - 1)
        return .degrees(-span / 2 + Double(index) * stepDegrees)
    }

    var body: some View {
        ZStack {
            Circle().fill(onLight ? RigTheme.cabinet : Color(white: 0.85))
            Circle().strokeBorder(onLight ? RigTheme.trim : .black.opacity(0.4),
                                  lineWidth: max(1, diameter * 0.06))
            Capsule()
                .fill(RigTheme.amber)
                .frame(width: max(1.5, diameter * 0.09), height: diameter * 0.4)
                .offset(y: -diameter * 0.2)
                .rotationEffect(angle)
        }
        .frame(width: diameter, height: diameter)
        .overlay { if !inert { LiveRing(diameter: diameter) } }
        .animation(.spring(response: 0.24, dampingFraction: 0.6), value: index)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Circle())
        .onTapGesture {
            guard options.count > 1 else { return }
            let next = (index + 1) % options.count
            value = Double(next)
            onFlick(next)
        }
    }
}

// MARK: - The lamp beside it

struct PanelLamp: View {
    let color: Color
    let diameter: CGFloat
    let lit: Bool

    var body: some View {
        Circle()
            .fill(lit
                  ? RadialGradient(colors: [.white.opacity(0.9), color], center: .center,
                                   startRadius: 0, endRadius: diameter * 0.6)
                  : RadialGradient(colors: [color.opacity(0.30), .black.opacity(0.45)],
                                   center: .center, startRadius: 0, endRadius: diameter * 0.6))
            .overlay(Circle().strokeBorder(.black.opacity(0.5), lineWidth: max(0.5, diameter * 0.08)))
            .frame(width: diameter, height: diameter)
            // The glow is what reads from standing height, not the disc.
            .shadow(color: lit ? color.opacity(0.95) : .clear, radius: diameter * 0.75)
            .animation(.easeOut(duration: 0.16), value: lit)
            .allowsHitTesting(false)
    }
}

// MARK: - What the strip's caption used to say

/// Named, stated, and gone again — a switch on a faceplate has no room for a
/// caption, so touching one puts the caption over the panel for a moment.
struct PanelTooltip: View {
    let title: String
    let detail: String
    /// True when nothing behind the control is listening yet.
    let inert: Bool

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 5) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold)).tracking(1)
                    .foregroundStyle(RigTheme.textMuted)
                Text(detail.uppercased())
                    .font(.system(size: 9, weight: .heavy)).tracking(0.6)
                    .foregroundStyle(RigTheme.amber)
            }
            if inert {
                Text("not wired to the sound yet")
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundStyle(RigTheme.textMuted.opacity(0.9))
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.black.opacity(0.86))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
                )
        )
        .allowsHitTesting(false)
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }
}

// MARK: - Colours out of the sidecar

extension Color {
    /// `"#rrggbb"` as written in a panel sidecar; anything unreadable falls back
    /// to the app's amber so a typo shows as a lamp rather than as nothing.
    init(panelHex: String?) {
        guard let raw = panelHex?.trimmingCharacters(in: CharacterSet(charactersIn: "# ")),
              raw.count == 6, let v = Int(raw, radix: 16) else {
            self = RigTheme.amber
            return
        }
        self = Color(red: Double((v >> 16) & 0xff) / 255,
                     green: Double((v >> 8) & 0xff) / 255,
                     blue: Double(v & 0xff) / 255)
    }
}
