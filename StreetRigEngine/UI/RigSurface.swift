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
//  SHADOWS WERE REMOVED FROM BOTH OF THESE, deliberately, and that is the biggest
//  change this file has ever taken. Every card, row, chip and well used to cast one.
//  A shadow is a claim that one surface floats above another in space, and almost
//  nothing in a control panel does: the rail, the cards, the chips and the buttons
//  are all IN the panel. A screen where everything floats is a screen where nothing
//  does. Depth is now the tone ladder plus a 1pt hairline — which is what the ladder
//  and `surfaceEdge` were always for, and what pro audio software actually does.
//
//  Exactly three things in the app may cast a drop shadow: a modal or sheet over
//  the app, the drag ghost, and real gear on the stage. The first two come through
//  here as `lifted: true`; the third is not a SwiftUI surface at all.
//
//  Two modifiers, one per upper rung of `RigTheme`'s elevation ladder:
//
//    .rigCard()   → `surface`       + BRASS edge   cards, panels, sheets
//
//  The edge defaults to `edgeBrass` and not `surfaceEdge`. Copper at low alpha over
//  a warm brown card composites to a slightly lighter brown — technically an edge,
//  visibly nothing. Brass reads as trim, which is what a card edge is for here.
//    .rigRaised() → `surfaceRaised` + warm edge + tight shadow     chips, wells, buttons
//
//  Corner radius is a PARAMETER, but the SCALE is not: pass a `RigTheme.Radius`
//  case, never a number. The 19 distinct radii this app used to carry are why it
//  read as soft — see the note on `RigTheme.Radius`.
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
    ///     NOT a way to mark state: on this near-black ground a deeper shadow is
    ///     close to invisible, so it cannot carry a distinction on its own.
    func rigCard(cornerRadius: CGFloat = RigTheme.Radius.control,
                 stroke: Color = RigTheme.edgeBrass,
                 lineWidth: CGFloat = 1,
                 lifted: Bool = false) -> some View {
        rigCard(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                stroke: stroke, lineWidth: lineWidth, lifted: lifted)
    }

    /// Shape-taking form, for surfaces that aren't rounded rectangles — the plugin
    /// editor's `Capsule()` chips, mainly. Kept generic over `InsettableShape` so the
    /// stroke can still inset itself and sit flush inside the fill.
    func rigCard<S: InsettableShape>(_ shape: S,
                                     stroke: Color = RigTheme.edgeBrass,
                                     lineWidth: CGFloat = 1,
                                     lifted: Bool = false) -> some View {
        background {
            shape
                .fill(RigTheme.surface)
                // ONLY a genuinely floating thing casts. `lifted` means the drag
                // ghost or a modal — something actually in the air above the app.
                // A resting card gets NOTHING: see the shadow note in the header.
                .shadow(color: lifted ? RigTheme.elevationShadow : .clear,
                        radius: lifted ? 44 : 0,
                        y: lifted ? 18 : 0)
        }
        .overlay { shape.strokeBorder(stroke, lineWidth: lineWidth) }
    }

    // MARK: - RAISED — the rung a card sits things on

    /// A control sitting ON a card: chip, capsule, segmented well, search field,
    /// keypad key, slider track, glyph tile. One step lighter than the card so it
    /// still reads as pressable, with a much tighter shadow — it is a few points
    /// off its card, not a card off the page.
    func rigRaised(cornerRadius: CGFloat = RigTheme.Radius.tight,
                   stroke: Color = RigTheme.edgeBrass,
                   lineWidth: CGFloat = 1) -> some View {
        rigRaised(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                  stroke: stroke, lineWidth: lineWidth)
    }

    /// Shape-taking form. See `rigCard(_:stroke:lineWidth:lifted:)`.
    func rigRaised<S: InsettableShape>(_ shape: S,
                                       stroke: Color = RigTheme.edgeBrass,
                                       lineWidth: CGFloat = 1) -> some View {
        background {
            // No shadow at all. A chip, a well or a keypad key sits IN its card,
            // not above it — the tone step and the hairline do the separating.
            shape.fill(RigTheme.surfaceRaised)
        }
        .overlay { shape.strokeBorder(stroke, lineWidth: lineWidth) }
    }
}
