//
//  RigMaterials.swift
//  StreetRigEngine
//
//  THE APP'S OWN SURFACES — the chrome bars, and nothing that draws gear.
//
//  One material lives here, and it is the one the whole redesign turns on: the
//  black anodised plate behind the top nav and the control panel. Gear surfaces
//  are NOT here. `Faceplate`, `GearArt` and `PanelArtLoader` own those, they are
//  per-model, and they are deliberately untouched.
//
//  A GRADIENT ON METAL IS A REFLECTION, NOT A FADE.
//
//  This is the whole idea, and it is why `chromeFace` looks strange written down.
//  A smooth top-to-bottom light-to-dark ramp is what MATTE material does — paper,
//  powder coat, plastic. Metal is a mirror, so its tone map is a picture of the
//  room in front of it: a lip that turns away from the key light and so is the
//  DARKEST part, an immediate catch just below it, a NARROW specular where the
//  panel sees the lamp, a fast falloff into the dark room it reflects, a secondary
//  LIFT low down where light bounces back off the surface below, and a dark bottom
//  edge. The stops are deliberately uneven and the profile is deliberately
//  non-monotonic. Evenly spacing them reads as plastic at any colour, so do not
//  "tidy" them.
//
//  AMPLITUDE IS NOT STRUCTURE. An earlier cut of this ran a mid-grey plate across
//  a 150-level range and read as dirty rather than machined — the panel looked
//  shadowed instead of lit. The range here is ~39 levels and every stop POSITION is
//  unchanged from that version. Structure is what says metal; amplitude only says
//  how polished. If this ever needs to move, move the amplitude.
//

import SwiftUI

public enum RigMaterials {

    // MARK: - The anodised chrome plate

    /// The reflection profile. See the header for why the stops sit where they do.
    public static let chromeFace = LinearGradient(
        stops: [
            .init(color: RigTheme.chromeLip,   location: 0.00),
            .init(color: Color(red: 0.173, green: 0.169, blue: 0.161), location: 0.025),
            .init(color: RigTheme.chromeCatch, location: 0.025),
            .init(color: RigTheme.chromeSheen, location: 0.07),
            .init(color: Color(red: 0.137, green: 0.133, blue: 0.129), location: 0.17),
            .init(color: RigTheme.chromeBody,  location: 0.52),
            .init(color: RigTheme.chromeLow,   location: 0.76),
            .init(color: Color(red: 0.114, green: 0.110, blue: 0.106), location: 0.93),
            .init(color: Color(red: 0.078, green: 0.075, blue: 0.071), location: 1.00)
        ],
        startPoint: .top, endPoint: .bottom)

    // MARK: - Brushed grain

    /// A 2×2 tile: one light column, one dark. Tiled, it gives the fine hairlines
    /// that say *brushed* rather than *polished* — the single cheapest cue that a
    /// dark surface is metal and not paint.
    ///
    /// GENERATED ONCE. This is a `static let`, so the bitmap is built on first use
    /// and reused for the life of the process. Regenerating a noise or grain field
    /// per frame — or worse, per `body` evaluation — next to a live audio graph is
    /// how a UI pass turns into dropouts. If you add another textured surface, cache
    /// it here beside this one rather than drawing it at the call site.
    ///
    /// Drawn at scale 1 deliberately: at 2x or 3x the renderer would smooth the
    /// 1pt columns into a grey wash and the grain would disappear.
    public static let brushedGrain: Image = {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let size = CGSize(width: 2, height: 2)
        let ui = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(white: 1, alpha: 0.030).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: 1, height: 2))
            c.setFillColor(UIColor(white: 0, alpha: 0.055).cgColor)
            c.fill(CGRect(x: 1, y: 0, width: 1, height: 2))
        }
        return Image(uiImage: ui).resizable(resizingMode: .tile)
    }()
}

public extension View {

    /// The app's chrome bar: anodised plate, brushed grain, and the two-tone brass
    /// hairline along its lit edge.
    ///
    /// - Parameter piped: draws the brass hairline on the top edge. `true` for a bar
    ///   whose lit edge faces up (the control panel, sitting below the content);
    ///   the top nav passes `true` as well, because the light is overhead and its
    ///   own top edge is what catches it.
    ///
    /// The piping is TWO 1pt lines, not one 3pt line: `trimLit` directly above
    /// `trim`. That is how piping reads on real gear, and it is thinner than the eye
    /// expects, which is exactly why it reads as expensive rather than applied. It
    /// was 3pt and became the loudest thing on a screen whose whole argument is
    /// restraint.
    /// THE PLATE IGNORES THE HORIZONTAL SAFE AREA; THE CONTENT DOES NOT.
    ///
    /// In landscape the safe-area insets sit left and right — around 45pt each on a
    /// device with a Dynamic Island — and a chassis that stops 45pt short of the
    /// glass reads as a window onto the app rather than the app itself. But pushing
    /// the whole stack out put the island on top of the gear rail and clipped the
    /// centre column's headers, so the extension belongs HERE, on the background,
    /// where it costs the content nothing: the plate runs to the glass and the
    /// controls stay where the system says they are safe.
    func rigChrome(piped: Bool = true) -> some View {
        background {
            RigMaterials.chromeFace
                .overlay { RigMaterials.brushedGrain.opacity(1) }
                .overlay(alignment: .top) {
                    if piped {
                        VStack(spacing: 0) {
                            RigTheme.trimLit.frame(height: RigTheme.hairlineWidth)
                            RigTheme.trim.frame(height: RigTheme.hairlineWidth)
                        }
                    }
                }
                .ignoresSafeArea(edges: .horizontal)
        }
    }
}
