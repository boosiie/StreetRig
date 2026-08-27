//
//  AppIconMark.swift
//  StreetRig
//
//  The app icon, as a view. `AppIconExporter` rasterises this to the three PNGs
//  in `Assets.xcassets/AppIcon.appiconset`; nothing in the running app draws it.
//
//  It is NOT the splash mark pasted into a square, and the differences are all
//  forced by what an icon has to survive:
//
//    • FULL BLEED. An icon has no transparency and no margin of its own — iOS
//      masks it to a squircle and composites it on whatever is behind. So the
//      ground here goes edge to edge and is opaque everywhere.
//    • NO WORDMARK. The splash hangs "STREETRIG" off the mark's bottom edge. At
//      the ~60pt an icon is actually displayed, that logotype is four pixels tall
//      and turns to mush, and it would cost the knobs the room they need. The
//      knobs are the whole read; the name is on the label underneath.
//    • INSET FOR THE MASK. See `markScale`.
//    • THREE VARIANTS. iOS 26 asks for light, dark and tinted, and they are three
//      different pictures — see `Variant`.
//
//  Everything else is deliberately shared with the splash: same `AmpLogoView`,
//  same shader, same palette. There is no second copy of the mark, which is the
//  point — an icon that drifts from the splash is a bug no test catches.
//

import SwiftUI
import StreetRigEngine

struct AppIconMark: View {

    /// The three appearances iOS 26 composites, matching the three slots already
    /// declared in `AppIcon.appiconset/Contents.json`.
    enum Variant: String, CaseIterable {
        /// Full colour on a warm lit ground. The default.
        case light
        /// Composited on a dark system backdrop, so it has to be genuinely dimmer
        /// than `light` rather than the same file twice — the ground drops most of
        /// the way to black and the ember pointers pick up the read.
        case dark
        /// Rendered by iOS as a MONOCHROME luminance map with a system tint on top.
        /// Hue does not survive, so this variant is designed for luminance only:
        /// `AppIconExporter` flattens it to grey and pushes contrast after
        /// rasterising. Anything that reads here reads because of its brightness.
        case tinted

        /// Ember-halo multiplier handed to `AmpLogoView.glow`.
        var glow: CGFloat {
            switch self {
            case .light:  return 1.0
            // The dark ground measures a median luminance of 7.5/255 against the
            // light variant's 19.8 — 38% of it — so the knobs lose most of the
            // separation the page was giving them. 1.7 puts the read back on the
            // pointers instead. Set by looking at the two bakes side by side, not
            // derived: it is as far as the halo goes before the three of them start
            // fusing into one amber cloud over the middle of the icon.
            case .dark:   return 1.7
            // Hot, and for a reason that only shows up at real size: at the ~60pt
            // an icon is displayed the pointer is UNDER A PIXEL wide, so what
            // actually survives downsampling is the halo around it, not the line.
            // With colour gone that halo is the only thing separating the pointer
            // from the metal it sits on, so it is worth more here than anywhere.
            case .tinted: return 1.3
            }
        }
    }

    /// Side of the square, in points. The bake runs this at 1024.
    var side: CGFloat = 1024
    var variant: Variant = .light

    /// Whether to shade the knobs with Metal. Threaded straight through to
    /// `AmpLogoView.shaded` so the exporter's probe can render both, and so a
    /// rasteriser that drops shaders has somewhere to fall back to. See the
    /// finding recorded in `AppIconExporter`.
    var shaded: Bool = true

    // MARK: - Layout

    /// `AmpLogoView`'s frame as a fraction of the icon's side.
    ///
    /// The mark's INK is 0.92 of its own frame across (radius 0.195 + halfSpan
    /// 0.265, doubled), so 0.86 here puts the knob triangle at 0.79 of the icon —
    /// the "central 80%" that clears the squircle's corner cut.
    ///
    /// That inset is chosen for AIR, not for clearance; clearance is not close.
    /// Checked against the superellipse the mask approximates (|u|⁵+|v|⁵ = 1 on
    /// coordinates normalised to the half-side): the lower-left knob's most
    /// exposed point, its edge on the diagonal toward the corner, lands at
    /// |u|⁵+|v|⁵ = 0.21 — a fifth of the way to the cut. The mark could grow a
    /// long way before the mask touched it. It should not: an icon whose glyph
    /// runs to the mask edge reads as cropped at every size it is displayed.
    private static let markScale: CGFloat = 0.86

    /// A SECOND optical lift, on top of the 0.030 `AmpLogoView` already applies —
    /// and the measured answer is that the icon does not want one.
    ///
    /// Worth asking, because the mark's own 0.030 was judged on the SPLASH, where a
    /// wordmark hangs off the bottom edge and adds mass below the triangle. Take the
    /// wordmark away and the balance could easily have moved. So the exporter's
    /// probe baked the same icon at −0.020, 0 and +0.012 and the three were looked
    /// at side by side: −0.020 sits the cluster on the floor, +0.012 leaves a
    /// visibly bigger gap under the mark than over it, and 0 reads centred.
    ///
    /// The arithmetic agrees, for what it is worth. At 0 the ink's bounding box is
    /// centred 26px ABOVE the icon's centre and the three knob centres average 41px
    /// BELOW it; weight those the way the eye appears to (≈60/40 toward the box) and
    /// the perceived centre lands at 512.6 of 1024.
    ///
    /// Kept as a named zero rather than deleted: it is where to look if the mark's
    /// proportions ever change.
    private static let extraLift: CGFloat = 0

    /// Override for `extraLift`, so `AppIconExporter`'s probe can bake the same
    /// icon at several lifts and let the number be chosen by looking rather than by
    /// arguing. `nil` is the shipping value.
    var lift: CGFloat?

    var body: some View {
        ZStack {
            ground
            AmpLogoView(size: side * Self.markScale,
                        shaded: shaded,
                        glow: variant.glow)
                .offset(y: -side * (lift ?? Self.extraLift))
        }
        .frame(width: side, height: side)
        // The mark's ground-contact layer deliberately overhangs its own frame by
        // 0.18·size so shadows have somewhere to fall. In the splash that spills
        // harmlessly onto the page; here the icon's edge is a hard cut, so say so.
        .clipped()
    }

    // MARK: - Ground

    /// Edge-to-edge, opaque, and warm. A radial lift centred slightly ABOVE the
    /// middle — the light in this mark comes from the upper left, and a ground lit
    /// from dead centre fights it.
    ///
    /// Never a neutral. Every stop is a `RigTheme` espresso or that espresso mixed
    /// toward black, which scales its value without touching its hue. Mixing toward
    /// grey or white to get a gradient is exactly the move that lands this palette
    /// in olive next to the amber pointers.
    @ViewBuilder
    private var ground: some View {
        switch variant {
        case .light:
            ZStack {
                RadialGradient(
                    stops: [
                        .init(color: RigTheme.backgroundLift, location: 0.00),
                        .init(color: RigTheme.cabinet,        location: 0.45),
                        .init(color: RigTheme.background,     location: 1.00)
                    ],
                    center: UnitPoint(x: 0.5, y: 0.44),
                    startRadius: 0,
                    endRadius: side * 0.80)
                emberWash(0.055)
                vignette(0.30)
            }
        case .dark:
            ZStack {
                RadialGradient(
                    stops: [
                        .init(color: RigTheme.background,                                location: 0.00),
                        .init(color: RigTheme.background.mix(with: .black, by: 0.35),    location: 0.50),
                        .init(color: RigTheme.background.mix(with: .black, by: 0.62),    location: 1.00)
                    ],
                    center: UnitPoint(x: 0.5, y: 0.44),
                    startRadius: 0,
                    endRadius: side * 0.80)
                emberWash(0.085)        // more, because the ground gives back less
                vignette(0.34)
            }
        case .tinted:
            // Hue is about to be thrown away by the flatten pass, so this ground is
            // chosen purely for VALUE: near-zero at the edges so the system tint has
            // a dark field to sit in, with just enough lift under the cluster that
            // the mark isn't a cut-out floating on flat black.
            ZStack {
                RadialGradient(
                    stops: [
                        .init(color: RigTheme.background.mix(with: .black, by: 0.42), location: 0.00),
                        .init(color: RigTheme.background.mix(with: .black, by: 0.80), location: 1.00)
                    ],
                    center: UnitPoint(x: 0.5, y: 0.44),
                    startRadius: 0,
                    endRadius: side * 0.80)
                vignette(0.22)
            }
        }
    }

    /// The tube glow reaching the back wall. Additive and very quiet — this is the
    /// difference between a mark sitting ON a background and a mark lighting one.
    private func emberWash(_ strength: Double) -> some View {
        RadialGradient(
            colors: [RigTheme.amber.opacity(strength), .clear],
            center: UnitPoint(x: 0.5, y: 0.46),
            startRadius: side * 0.04,
            endRadius: side * 0.46)
        .blendMode(.plusLighter)
    }

    /// Corner darkening. Not decoration: the squircle eats the corners, and a ground
    /// that is still bright where it gets bitten makes the cut look like damage.
    /// Black at partial alpha, which scales value and leaves hue alone.
    private func vignette(_ strength: Double) -> some View {
        RadialGradient(
            colors: [.clear, Color.black.opacity(strength)],
            center: .center,
            startRadius: side * 0.42,
            endRadius: side * 0.80)
    }
}

// The three variants at the size they are actually judged at, under the mask iOS
// actually applies. A 1024 render tells you nothing about whether an icon works —
// this does. `AppIconExporter` bakes the same view at 1024.
#Preview("Icon variants") {
    VStack(spacing: 28) {
        ForEach(AppIconMark.Variant.allCases, id: \.self) { variant in
            HStack(spacing: 24) {
                ForEach([180.0, 120.0, 60.0], id: \.self) { s in
                    AppIconMark(side: s, variant: variant)
                        .clipShape(RoundedRectangle(cornerRadius: s * 0.2237, style: .continuous))
                }
            }
        }
    }
    .padding(40)
    .background(Color(white: 0.35))
}
