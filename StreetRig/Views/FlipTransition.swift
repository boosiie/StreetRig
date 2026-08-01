//
//  FlipTransition.swift
//  StreetRig
//
//  A vertical flip-board transition for swapping the loading mantra:
//  the outgoing line hinges DOWN and out, while the incoming line hinges
//  IN from the top. A 3D x-axis rotation gives the "flip" feel; a small
//  vertical offset locks in the downward direction regardless of the
//  rotation sign, so it always reads as new-from-top / old-to-bottom.
//

import SwiftUI

struct FlipModifier: ViewModifier {
    var angle: Double        // rotation about the horizontal (x) axis
    var yOffset: CGFloat     // vertical displacement (guarantees "down")
    var opacity: Double
    var anchor: UnitPoint    // hinge edge

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .rotation3DEffect(
                .degrees(angle),
                axis: (x: 1, y: 0, z: 0),
                anchor: anchor,
                perspective: 0.5
            )
            .offset(y: yOffset)
    }
}

extension AnyTransition {
    /// Incoming view flips in from the top; outgoing view flips down and out.
    static var flipDown: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: FlipModifier(angle: -80, yOffset: -16, opacity: 0, anchor: .top),
                identity: FlipModifier(angle: 0, yOffset: 0, opacity: 1, anchor: .top)
            ),
            removal: .modifier(
                active: FlipModifier(angle: 80, yOffset: 16, opacity: 0, anchor: .bottom),
                identity: FlipModifier(angle: 0, yOffset: 0, opacity: 1, anchor: .bottom)
            )
        )
    }
}
