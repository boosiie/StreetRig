//
//  GuitarOnStandView.swift
//  StreetRig
//
//  A single stylized electric guitar (Les-Paul-ish) resting on an A-frame
//  guitar stand. GuitarBodyArt (the guitar alone) is reused by GearArtView
//  so the zoomed guitar matches the one on the stage.
//

import SwiftUI

/// A single guitar on an A-frame stand.
struct GuitarOnStandView: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                GuitarStand(w: w, h: h)
                GuitarBodyArt()
                    .frame(width: w * 0.64, height: h * 0.9)
                    .position(x: w * 0.5, y: h * 0.5)
                    .rotationEffect(.degrees(-6), anchor: .bottom)
            }
        }
    }
}

/// A single electric guitar, vertical, filling its frame (headstock at top).
struct GuitarBodyArt: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // Neck (long + slim)
                Capsule()
                    .fill(Color(red: 0.32, green: 0.19, blue: 0.10))
                    .frame(width: w * 0.105, height: h * 0.52)
                    .position(x: w * 0.5, y: h * 0.34)
                // Headstock
                RoundedRectangle(cornerRadius: w * 0.03, style: .continuous)
                    .fill(Color(white: 0.11))
                    .frame(width: w * 0.16, height: h * 0.065)
                    .position(x: w * 0.5, y: h * 0.09)
                    .overlay(
                        HStack(spacing: w * 0.025) {
                            ForEach(0..<3, id: \.self) { _ in
                                Circle().fill(RigTheme.trim).frame(width: w * 0.025, height: w * 0.025)
                            }
                        }
                        .position(x: w * 0.5, y: h * 0.09)
                    )
                // Body (sunburst, elongated single-cutaway feel)
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [Color(red: 0.87, green: 0.57, blue: 0.20), Color(red: 0.36, green: 0.17, blue: 0.06)],
                            center: .init(x: 0.5, y: 0.42), startRadius: w * 0.04, endRadius: w * 0.4
                        )
                    )
                    .frame(width: w * 0.54, height: h * 0.42)
                    .position(x: w * 0.5, y: h * 0.71)
                    .overlay(
                        Ellipse()
                            .strokeBorder(.black.opacity(0.4), lineWidth: max(1, w * 0.02))
                            .frame(width: w * 0.54, height: h * 0.42)
                            .position(x: w * 0.5, y: h * 0.71)
                    )
                // Pickguard, pickups, bridge
                Group {
                    RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.07))
                        .frame(width: w * 0.20, height: h * 0.024).position(x: w * 0.5, y: h * 0.63)
                    RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.07))
                        .frame(width: w * 0.20, height: h * 0.024).position(x: w * 0.5, y: h * 0.69)
                    RoundedRectangle(cornerRadius: 1).fill(Color(white: 0.16))
                        .frame(width: w * 0.13, height: h * 0.018).position(x: w * 0.5, y: h * 0.77)
                }
            }
            .frame(width: w, height: h)
        }
    }
}

/// A-frame guitar stand drawn behind the guitar.
private struct GuitarStand: View {
    let w: CGFloat
    let h: CGFloat
    private let gray = Color(white: 0.32)

    var body: some View {
        ZStack {
            // Legs (A-frame) + a rear kickstand line
            Path { p in
                p.move(to: CGPoint(x: w * 0.5, y: h * 0.17))
                p.addLine(to: CGPoint(x: w * 0.15, y: h * 0.97))
                p.move(to: CGPoint(x: w * 0.5, y: h * 0.17))
                p.addLine(to: CGPoint(x: w * 0.85, y: h * 0.97))
            }
            .stroke(gray, style: StrokeStyle(lineWidth: max(3, w * 0.05), lineCap: .round))

            // Cross support
            Path { p in
                p.move(to: CGPoint(x: w * 0.29, y: h * 0.68))
                p.addLine(to: CGPoint(x: w * 0.71, y: h * 0.68))
            }
            .stroke(gray.opacity(0.85), style: StrokeStyle(lineWidth: max(2, w * 0.035), lineCap: .round))

            // Body cradle arms
            Path { p in
                p.move(to: CGPoint(x: w * 0.32, y: h * 0.68)); p.addLine(to: CGPoint(x: w * 0.26, y: h * 0.58))
                p.move(to: CGPoint(x: w * 0.68, y: h * 0.68)); p.addLine(to: CGPoint(x: w * 0.74, y: h * 0.58))
            }
            .stroke(gray, style: StrokeStyle(lineWidth: max(3, w * 0.05), lineCap: .round))

            // Neck yoke
            Path { p in
                p.move(to: CGPoint(x: w * 0.41, y: h * 0.22))
                p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.16))
                p.addLine(to: CGPoint(x: w * 0.59, y: h * 0.22))
            }
            .stroke(gray, style: StrokeStyle(lineWidth: max(3, w * 0.05), lineCap: .round, lineJoin: .round))

            // Feet
            Capsule().fill(gray).frame(width: w * 0.2, height: max(3, h * 0.018)).position(x: w * 0.15, y: h * 0.97)
            Capsule().fill(gray).frame(width: w * 0.2, height: max(3, h * 0.018)).position(x: w * 0.85, y: h * 0.97)
        }
    }
}

#Preview {
    HStack(spacing: 30) {
        GuitarOnStandView().frame(width: 130, height: 240)
        GuitarBodyArt().frame(width: 90, height: 220)
    }
    .padding()
    .background(RigTheme.background)
    .preferredColorScheme(.dark)
}
