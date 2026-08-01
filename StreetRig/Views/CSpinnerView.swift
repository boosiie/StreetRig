//
//  CSpinnerView.swift
//  StreetRig
//
//  A "C"-shaped loading spinner. Wobble-free by construction: a stroked,
//  trimmed Circle is perfectly centered in its frame, so rotating about
//  the frame center produces pure spin with no orbiting/wobble. We drive
//  it with a single continuous linear rotation (no autoreverse, no spring).
//

import SwiftUI

struct CSpinnerView: View {
    var size: CGFloat = 40
    var lineWidth: CGFloat = 4
    /// Seconds per full revolution.
    var period: Double = 1.0

    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.0, to: 0.75)                 // 270° arc → open "C"
            .stroke(
                RigTheme.amber,
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .animation(
                .linear(duration: period).repeatForever(autoreverses: false),
                value: isSpinning
            )
            .onAppear { isSpinning = true }
            .accessibilityHidden(true)
    }
}

#Preview {
    ZStack {
        RigTheme.background.ignoresSafeArea()
        CSpinnerView(size: 60, lineWidth: 6)
    }
    .preferredColorScheme(.dark)
}
