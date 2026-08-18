//
//  RigSurface.swift
//  StreetRigEngine
//
//  The one place elevation gets drawn.
//
//  Before this file, every card in the app hand-rolled its own
//  `RoundedRectangle(...).fill(...)` plus a `.strokeBorder(Color.white.opacity(0.06))`,
//  and the values drifted: five different stroke alphas, eight corner radii, no
//  shadows, and a fill (`backgroundLift`) sitting 1.09:1 above the page — close
//  enough to invisible that collection, library, detail and device bar all read as
//  one flat dark field. Centralising it here is the only way that stays fixed.
//
//  Two modifiers, one per upper rung of `RigTheme`'s elevation ladder:
//
//    .rigCard()   → `surface`       + warm edge + ambient shadow   cards, panels, sheets
//    .rigRaised() → `surfaceRaised` + warm edge + tight shadow     chips, wells, buttons
//
//  Corner radius is a PARAMETER, not a constant. The device bar's dropdowns are 8pt
//  and the detail keypad is 22pt; forcing one radius would visibly break those
//  layouts. What has to be consistent is the ELEVATION, not the geometry.
//
//  Lives in the shared framework alongside `RigTheme`, so the AUv3 plugin editor's
//  cards are literally the app's cards rather than a copy that drifts.
//

import SwiftUI

public extension View {

    // MARK: - CARD — the rung a page sits things on

    /// A card, panel, list row or sheet resting on the page background.
    ///
    /// - Parameters:
    ///   - cornerRadius: this call site's own radius. Pass what the layout already
    ///     used; the ladder unifies tone and shadow, not shape.
    ///   - stroke: override ONLY when the edge itself carries meaning — the library's
    ///     amber "you already own this", the drag ghost's amber "this is in the air".
    ///     Everything else wants the default warm `surfaceEdge` hairline.
    ///   - lineWidth: stroke width; 1pt reads correctly across the 8…24pt range here.
    ///   - lifted: `true` for something genuinely floating ABOVE the UI (the drag
    ///     ghost, a modal offer). It deepens the shadow rather than the fill, so the
    ///     tone ladder stays three steps instead of quietly growing a fourth.
    func rigCard(cornerRadius: CGFloat = 14,
                 stroke: Color = RigTheme.surfaceEdge,
                 lineWidth: CGFloat = 1,
                 lifted: Bool = false) -> some View {
        rigCard(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                stroke: stroke, lineWidth: lineWidth, lifted: lifted)
    }

    /// Shape-taking form, for surfaces that aren't rounded rectangles — the plugin
    /// editor's `Capsule()` chips, mainly. Kept generic over `InsettableShape` so the
    /// stroke can still inset itself and sit flush inside the fill.
    func rigCard<S: InsettableShape>(_ shape: S,
                                     stroke: Color = RigTheme.surfaceEdge,
                                     lineWidth: CGFloat = 1,
                                     lifted: Bool = false) -> some View {
        background {
            shape
                .fill(RigTheme.surface)
                .shadow(color: RigTheme.elevationShadow,
                        radius: lifted ? 22 : 9,
                        y: lifted ? 10 : 4)
        }
        .overlay { shape.strokeBorder(stroke, lineWidth: lineWidth) }
    }

    // MARK: - RAISED — the rung a card sits things on

    /// A control sitting ON a card: chip, capsule, segmented well, search field,
    /// keypad key, slider track, glyph tile. One step lighter than the card so it
    /// still reads as pressable, with a much tighter shadow — it is a few points
    /// off its card, not a card off the page.
    func rigRaised(cornerRadius: CGFloat = 10,
                   stroke: Color = RigTheme.surfaceEdge,
                   lineWidth: CGFloat = 1) -> some View {
        rigRaised(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                  stroke: stroke, lineWidth: lineWidth)
    }

    /// Shape-taking form. See `rigCard(_:stroke:lineWidth:lifted:)`.
    func rigRaised<S: InsettableShape>(_ shape: S,
                                       stroke: Color = RigTheme.surfaceEdge,
                                       lineWidth: CGFloat = 1) -> some View {
        background {
            shape
                .fill(RigTheme.surfaceRaised)
                .shadow(color: RigTheme.elevationShadow.opacity(0.55), radius: 3, y: 1)
        }
        .overlay { shape.strokeBorder(stroke, lineWidth: lineWidth) }
    }
}
