//
//  AmpLogoView.swift
//  StreetRig
//
//  The StreetRig mark: an amp cabinet whose body + "feet" read as a
//  beamed eighth-note. Amp read is priority, note read is secondary.
//  Everything is drawn relative to `size` so it scales cleanly and can
//  later be lifted straight into an app-icon renderer.
//

import SwiftUI

struct AmpLogoView: View {
    var size: CGFloat = 120

    var body: some View {
        ZStack {
            // Cabinet body (the "beam + stems" of the eighth-note).
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .fill(RigTheme.cabinet)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                        .strokeBorder(RigTheme.trim, lineWidth: size * 0.045)
                )
                .frame(width: size * 0.74, height: size * 0.62)
                .position(x: size * 0.5, y: size * 0.42)
                .shadow(color: RigTheme.amber.opacity(0.25), radius: size * 0.12, y: size * 0.02)

            // Cream faceplate / control panel.
            RoundedRectangle(cornerRadius: size * 0.03, style: .continuous)
                .fill(RigTheme.panel)
                .frame(width: size * 0.54, height: size * 0.185)
                .position(x: size * 0.5, y: size * 0.28)

            // Three dials in the cabinet space.
            ForEach(0..<3, id: \.self) { i in
                Knob(diameter: size * 0.10)
                    .position(x: size * (0.35 + 0.15 * CGFloat(i)), y: size * 0.28)
            }

            // Speaker grille suggestion under the panel.
            GrilleLines(count: 5)
                .stroke(RigTheme.trim.opacity(0.30), lineWidth: max(1, size * 0.007))
                .frame(width: size * 0.56, height: size * 0.14)
                .position(x: size * 0.5, y: size * 0.575)

            // Two eighth-note "heads" as amp feet (the secondary note read).
            NoteFoot(size: size)
                .position(x: size * 0.32, y: size * 0.775)
            NoteFoot(size: size)
                .position(x: size * 0.68, y: size * 0.80)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("StreetRig")
    }
}

/// A single amp control knob with an amber pointer.
private struct Knob: View {
    var diameter: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(RigTheme.cabinet)
            Circle().strokeBorder(RigTheme.trim, lineWidth: max(1, diameter * 0.12))
            Capsule()
                .fill(RigTheme.amber)
                .frame(width: max(1, diameter * 0.12), height: diameter * 0.40)
                .offset(y: -diameter * 0.16)
        }
        .frame(width: diameter, height: diameter)
    }
}

/// Evenly spaced horizontal grille lines.
private struct GrilleLines: Shape {
    var count: Int = 5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard count > 1 else { return path }
        let step = rect.height / CGFloat(count - 1)
        for i in 0..<count {
            let y = rect.minY + step * CGFloat(i)
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

/// A note-head foot: a tilted amber ellipse with a short stem.
private struct NoteFoot: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            Capsule()
                .fill(RigTheme.trim)
                .frame(width: size * 0.022, height: size * 0.075)
                .offset(x: size * 0.045, y: -size * 0.03)
            Ellipse()
                .fill(RigTheme.amber)
                .frame(width: size * 0.145, height: size * 0.10)
                .rotationEffect(.degrees(-22))
        }
    }
}

#Preview {
    ZStack {
        RigTheme.background.ignoresSafeArea()
        AmpLogoView(size: 220)
    }
    .preferredColorScheme(.dark)
}
