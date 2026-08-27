//
//  AmpLogoView.swift
//  StreetRig
//
//  THE MARK: three amp tone knobs in an apex-up triangle.
//
//  It used to be an amp cabinet whose body and feet were meant to read as a beamed
//  eighth-note. Two things were wrong with that. It carried FOUR ideas — cabinet,
//  faceplate, grille, note — and at 24pt all four collapsed into one grey rounded
//  rectangle indistinguishable from every other app's "settings" glyph. And the
//  note read never landed anyway: you have to be told it's there.
//
//  Three knobs say "guitar amp" with no explaining, and a triangle is the most
//  stable arrangement three circles have. There is deliberately NO backing plate:
//  a rectangle behind the knobs is exactly what turns a sharp mark mushy at icon
//  sizes, so the knobs ARE the mark and the page shows through between them.
//
//  THE FRAME CONTRACT: this view is exactly `size × size` and must stay that way.
//  LoadingView centres the mark by centring this view and hangs the STREETRIG
//  wordmark off its bottom edge, so a view that reports a larger frame silently
//  pushes the wordmark down and knocks the whole splash off centre. The glow, the
//  ground shadow and the pointer halo all ride as `.background` / `.overlay`,
//  which are sized to the host and therefore cannot grow it — while still being
//  free to DRAW outside it, since SwiftUI does not clip either one. That is the
//  only reason the mark can cast a shadow past its own edge at all.
//
//  Everything derives from `size`; nothing is absolute — with ONE deliberate
//  exception, `ridgeCount(forRadius:)`, where texture has to be read against the
//  object rather than the frame. `AppIconMark` bakes this same view at 1024 for the
//  app icon, so a change here is a change to the icon; re-run the exporter.
//

import SwiftUI
import StreetRigEngine

struct AmpLogoView: View {
    var size: CGFloat = 120

    /// THE SHADER SEAM — and the escape hatch.
    ///
    /// `true` shades the knobs with the Metal in `Shaders/KnobMark.metal`:
    /// knurling, anisotropic brushed metal, bevel lighting, pointer bloom, ground
    /// occlusion. `false` draws the SAME geometry, the SAME palette and the same
    /// key-light direction with nothing but SwiftUI gradients.
    ///
    /// It exists because Metal shaders are not available everywhere the mark is.
    /// They no-op or fail in some offscreen rasterisation paths and can misbehave
    /// in Xcode Previews. The 1024×1024 app-icon bake was expected to be one of
    /// those paths and turned out NOT to be — `ImageRenderer` carries `.colorEffect`
    /// intact, measured, see the FINDING on `AppIconExporter.route` — so the icon
    /// ships shaded and this stays an escape hatch rather than a shipping path.
    /// Keep the two paths geometrically identical: the unshaded one is not a
    /// degraded mark, it is the same mark with the lighting painted by hand.
    var shaded: Bool = true

    /// Multiplier on the ATMOSPHERIC half of the ember bloom — the blurred halo
    /// that spills off the metal into the air (see `pointerHalo`). 1 is the splash,
    /// and the splash is the reference: do not tune this to fix the splash, tune
    /// `pointerHalo`'s own constants for that.
    ///
    /// It exists for the app icon's DARK variant. iOS composites a dark icon on a
    /// dark backdrop, so the ground has to drop away — and once it does, the read
    /// has to come from somewhere. Turning the pointers up is the honest answer: a
    /// dimmer amp with its tubes still lit. The on-surface half of the bloom stays
    /// where it is, in the shader, so the knob's own lighting never changes — only
    /// how far the glow carries past the skirt.
    var glow: CGFloat = 1

    // MARK: - Geometry
    //
    // All fractions of `size`.

    /// Knob radius ÷ size. 0.195 puts the mark's bounding box at 0.92 of the frame
    /// across — against the old cabinet's 0.74. A mark that floats inside its own
    /// box loses to one that fills it, and loses hardest at small sizes where the
    /// wasted margin is most of the glyph.
    private static let radius: CGFloat = 0.195

    /// Half the distance between the two lower centres. 0.265 leaves a 0.10·size
    /// gap between adjacent skirts: close enough that the crevice occlusion reads
    /// as one cluster, far enough that the three circles never fuse into a trefoil
    /// blob at 24pt (measured — at 0.24 they touch and it does).
    private static let halfSpan: CGFloat = 0.265

    /// Centre-to-centre row gap for an EQUILATERAL triangle of centres. Derived,
    /// not typed in, so moving `halfSpan` can't leave the triangle lopsided.
    private static let rowSeparation: CGFloat = halfSpan * 2 * CGFloat(sin(Double.pi / 3))

    /// OPTICAL CENTRING. An apex-up triangle carries two thirds of its mass on the
    /// bottom row, so its visual centre sits well below the centre of its bounding
    /// box — box-centred, the mark reads as having slumped. Lifting it 0.030·size
    /// (3.5pt at the splash's 116) puts the perceived centre back on the frame's
    /// centre. Judged on a rendered screenshot, not derived: the arithmetic centre
    /// of mass wants ~0.043 and that overshoots — it reads as floating.
    private static let opticalLift: CGFloat = 0.030

    private static let topRowY: CGFloat =
        (1 - (rowSeparation + 2 * radius)) / 2 + radius - opticalLift
    private static let bottomRowY: CGFloat = topRowY + rowSeparation

    /// THREE DIFFERENT SETTINGS, on purpose. Three knobs at the same angle read as
    /// a repeated pattern — wallpaper. Three at different angles read as a rig
    /// somebody has already dialled in, which is the whole promise of the app.
    /// Left is backed off to nine o'clock, the apex sits just past noon where a
    /// master usually lives, the right one is cranked to about 4:20. They also
    /// happen to fan outward from the centre of the triangle, which keeps the
    /// silhouette from developing a direction.
    private static let knobs: [Knob] = [
        Knob(cx: 0.5,            cy: topRowY,    pointer: .degrees(-90 + 20)),   // just past noon
        Knob(cx: 0.5 - halfSpan, cy: bottomRowY, pointer: .degrees(-90 - 95)),   // rolled off, ~9 o'clock
        Knob(cx: 0.5 + halfSpan, cy: bottomRowY, pointer: .degrees(-90 + 130))   // cranked, ~4:20
    ]

    /// How far the ground layer reaches past the mark's own frame, so cast shadows
    /// have somewhere to fall. See the frame contract in the header: this is a
    /// `.background`, so an oversized child draws outside the frame and still
    /// contributes exactly nothing to layout.
    private static let shadowPad: CGFloat = 0.18

    /// The key light, as an ANGLE, for the unshaded path. Must agree with
    /// `kKeyLightXY` in KnobMark.metal — that is the screen-plane vector
    /// (-0.6189, -0.7855), i.e. upper-left, whose atan2 is -128.25°. If these two
    /// drift, the shaded and unshaded marks light from different directions and
    /// the app-icon bake stops matching the splash.
    private static let keyLightAngle = Angle.degrees(-128.25)

    private var diameter: CGFloat { Self.radius * 2 * size }

    /// Knurl flute count for a knob of the given radius IN POINTS, handed to the
    /// shader (which no longer hard-codes it).
    ///
    /// The mark is otherwise scale-invariant — every length is a fraction of
    /// `size`, so a flute count that is constant across sizes draws *the same
    /// picture* at 24 and at 1024. That is right for shape and wrong for texture:
    /// texture is the one thing a viewer reads relative to the object, not to the
    /// frame, and the same 40 facets that are a convincing grip on a 45pt splash
    /// knob are a visible cog on a 343pt icon knob. So the count ramps.
    ///
    /// Anchored at the splash, which is the mark's reference size: 0.195 × 116 =
    /// 22.6pt radius → 40, the value this shader shipped with and was tuned on.
    /// The exponent is a THIRD-ish power on purpose. Holding the arc-length pitch
    /// constant (exponent 1) asks for 304 flutes at the icon's 171.6pt radius,
    /// which is finer than the 1024 grid can resolve and turns to moiré the moment
    /// the home screen downsamples it. 0.35 lands on 81 there — twice the detail,
    /// still 13px of circumference per flute at 1024, and still inside the count a
    /// real machined knob could plausibly carry.
    static func ridgeCount(forRadius r: CGFloat) -> Float {
        let ratio = max(r, 1) / (radius * 116)          // 1.0 at the splash
        let n = 40 * pow(ratio, 0.35)
        // Rounded, because a fractional count will not close across atan2()'s ±π
        // seam and leaves a join running out of the knob at nine o'clock.
        return Float(min(96, max(28, n.rounded())))
    }

    var body: some View {
        ZStack {
            ForEach(Self.knobs.indices, id: \.self) { i in
                knobFace(Self.knobs[i])
                    .frame(width: diameter, height: diameter)
                    .position(Self.knobs[i].centre(in: size))
            }
        }
        .frame(width: size, height: size)
        .background { groundContact }       // under the knobs; cannot grow the frame
        .overlay { pointerHalo }            // over them; likewise
        .accessibilityElement()
        .accessibilityLabel("StreetRig")    // LoadingView's wordmark is hidden because of this
    }

    // MARK: - One knob

    @ViewBuilder
    private func knobFace(_ knob: Knob) -> some View {
        if shaded {
            // The `Circle().fill()` underneath is not decoration — it is the
            // shader's coverage mask. `.colorEffect` hands the fragment its
            // existing premultiplied colour, so the circle's own antialiased edge
            // arrives as `src.a` and the shader multiplies it back in. Cheaper and
            // smoother than any silhouette the shader could compute for itself.
            Circle()
                .fill(RigTheme.cabinet)
                .colorEffect(
                    ShaderLibrary.knobFace(
                        .float2(Float(diameter), Float(diameter)),
                        .float(Float(knob.pointer.radians)),
                        .float(Self.ridgeCount(forRadius: diameter / 2)),
                        .color(RigTheme.cabinet),       // body
                        .color(RigTheme.trim),          // brass
                        .color(RigTheme.panel),         // cream
                        .color(RigTheme.amber),         // ember
                        .color(RigTheme.emberSoft)      // emberHot
                    )
                )
        } else {
            GradientKnobFace(diameter: diameter,
                             pointer: knob.pointer,
                             keyLightAngle: Self.keyLightAngle)
        }
    }

    // MARK: - Ground contact

    @ViewBuilder
    private var groundContact: some View {
        let pad = Self.shadowPad * size
        let ext = size + pad * 2

        if shaded {
            // One shader for all three shadows, because the crevice darkening
            // between two knobs is a property of the PAIR — it cannot be produced
            // by two independent per-knob layers without one of them lying about
            // where its neighbour is. Centres are passed in this layer's own
            // coordinates, which are the mark's shifted by `pad`.
            Rectangle()
                .fill(Color.black)          // opaque source, so the effect runs on every pixel of the tile
                .frame(width: ext, height: ext)
                .colorEffect(
                    ShaderLibrary.knobGroundContact(
                        .float2(Float(Self.knobs[0].cx * size + pad), Float(Self.knobs[0].cy * size + pad)),
                        .float2(Float(Self.knobs[1].cx * size + pad), Float(Self.knobs[1].cy * size + pad)),
                        .float2(Float(Self.knobs[2].cx * size + pad), Float(Self.knobs[2].cy * size + pad)),
                        .float(Float(diameter / 2)),
                        .color(RigTheme.background)     // floorTint — see the warm-shadow note in the .metal
                    )
                )
                .allowsHitTesting(false)
        } else {
            // Pure black at partial alpha, which is the one place a NEUTRAL is safe
            // in this palette: it scales whatever is behind it rather than tinting
            // it, so the page keeps its hue and only loses light. That is what a
            // shadow physically does. Mixing toward grey here would desaturate the
            // espresso straight into the olive the palette exists to avoid.
            ZStack {
                ForEach(Self.knobs.indices, id: \.self) { i in
                    Ellipse()
                        .fill(RadialGradient(colors: [Color.black.opacity(0.55), .clear],
                                             center: .center,
                                             startRadius: diameter * 0.26,
                                             endRadius: diameter * 0.78))
                        .frame(width: diameter * 1.72, height: diameter * 1.48)
                        .position(x: Self.knobs[i].cx * size + pad + diameter * 0.07,
                                  y: Self.knobs[i].cy * size + pad + diameter * 0.09)
                }
            }
            .frame(width: ext, height: ext)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Pointer halo

    /// The half of the ember bloom that spills off the metal and into the air.
    ///
    /// A SwiftUI `.blur` on its own layer, deliberately, and not a gather loop in
    /// the shader: this mark sits under a glow that breathes on a 2.6s loop, and a
    /// per-pixel neighbourhood sample is precisely the cost that budget will not
    /// take. The ON-SURFACE half of the bloom stays in the shader, where it has to
    /// be — it must respect the knob's own lighting and the pointer's groove.
    private var pointerHalo: some View {
        ZStack {
            ForEach(Self.knobs.indices, id: \.self) { i in
                // 0.22 and 0.36, down from 0.34 and 0.50. Measured on a screenshot:
                // the first pass put a 15pt blob 4pt outside the skirt, and it did
                // not read as a halo — it read as the needle poking out through the
                // side of the knob, which is a manufacturing defect, not a glow.
                //
                // `glow` scales the disc's opacity and its blur, not its radius:
                // growing the disc would walk the halo's centre of mass off the
                // tip, which is the exact failure the 0.22 above was cut back to
                // fix. Opacity is capped at 0.85 so a boosted halo still reads as
                // air around a light and never as a solid amber blob.
                Circle()
                    .fill(RigTheme.amber.opacity(min(0.85, 0.36 * glow)))
                    .frame(width: diameter * 0.22, height: diameter * 0.22)
                    .position(Self.knobs[i].tip(in: size, radius: diameter / 2))
                    .blur(radius: diameter * 0.13 * (0.82 + 0.18 * glow))
            }
        }
        .frame(width: size, height: size)
        .blendMode(.plusLighter)            // light ADDS; a plain overlay would dim the pointer it is lighting
        .allowsHitTesting(false)
    }

    // MARK: - Placement

    /// One knob's place in the mark. `pointer` is a SCREEN-SPACE direction: 0° is
    /// three o'clock and positive rotates clockwise, because SwiftUI's y grows
    /// downward. Noon is therefore −90°, which is why every angle above is written
    /// as `-90 + something` — the offset from noon is the part a reader cares about.
    private struct Knob {
        var cx: CGFloat
        var cy: CGFloat
        var pointer: Angle

        func centre(in size: CGFloat) -> CGPoint {
            CGPoint(x: cx * size, y: cy * size)
        }

        /// Where the pointer's lit tip lands. 0.74 of the radius, not the 0.90R the
        /// shader's capsule actually ends at: the halo is a blurred disc, so seating
        /// it ON the tip throws half its mass off the knob. Pulled in until the glow
        /// sits inside the skirt and only bleeds over the rim.
        func tip(in size: CGFloat, radius: CGFloat) -> CGPoint {
            CGPoint(x: cx * size + CGFloat(cos(pointer.radians)) * radius * 0.74,
                    y: cy * size + CGFloat(sin(pointer.radians)) * radius * 0.74)
        }
    }
}

// MARK: - Unshaded knob

/// The shader-free knob face. Same silhouette, same palette, same key light —
/// everything the Metal computes per pixel, approximated with layered gradients.
///
/// The one effect that genuinely cannot survive the trip is the knurling: the
/// shader's 40 lit-and-shadowed flutes are not expressible as a gradient, and
/// faking them with an angular gradient of 80 stops costs more than it buys. The
/// bowtie highlight, the bevel, the cast shadow and the pointer glow all come
/// across — verified on a simulator screenshot with `shaded` forced to false.
private struct GradientKnobFace: View {
    var diameter: CGFloat
    var pointer: Angle
    var keyLightAngle: Angle

    /// The same sheen the shader mixes: brass pulled a quarter of the way toward
    /// `emberSoft`. Raw `trim` is a hue-41° gold and a strong lerp toward it walks
    /// the bronze out of amber's family into khaki — measured off a screenshot, see
    /// the long note in KnobMark.metal. Both paths must make the same mistake or
    /// neither, so this number tracks the shader's.
    private var sheen: Color { RigTheme.trim.mix(with: RigTheme.emberSoft, by: 0.25) }

    var body: some View {
        ZStack {
            Circle().fill(RigTheme.cabinet)

            // The anisotropic bowtie: TWO opposing bright arcs, on the axis of the
            // key light, because circular brushing spreads its specular radially.
            // Painted over the dark body rather than mixed into a solid colour —
            // compositing gives the blend for free.
            Circle()
                .fill(AngularGradient(
                    stops: [
                        .init(color: sheen.opacity(0.95), location: 0.00),
                        .init(color: sheen.opacity(0.38), location: 0.14),
                        .init(color: sheen.opacity(0.14), location: 0.25),
                        .init(color: sheen.opacity(0.38), location: 0.36),
                        .init(color: sheen.opacity(0.95), location: 0.50),
                        .init(color: sheen.opacity(0.38), location: 0.64),
                        .init(color: sheen.opacity(0.14), location: 0.75),
                        .init(color: sheen.opacity(0.38), location: 0.86),
                        .init(color: sheen.opacity(0.95), location: 1.00)
                    ],
                    center: .center,
                    angle: keyLightAngle))

            // Outer wall: lit on the upper-left, lost on the lower-right.
            Circle()
                .strokeBorder(
                    LinearGradient(colors: [RigTheme.panel.opacity(0.55),
                                            sheen.opacity(0.14),
                                            Color.black.opacity(0.50)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: max(0.5, diameter * 0.05))

            // The cap, sitting proud of the skirt. Its radial gradient is offset
            // toward the light so the dome reads as a dome and not as a disc.
            Circle()
                .fill(RadialGradient(colors: [sheen.opacity(0.34), RigTheme.cabinet],
                                     center: UnitPoint(x: 0.34, y: 0.28),
                                     startRadius: 0,
                                     endRadius: diameter * 0.60))
                .frame(width: diameter * 0.72, height: diameter * 0.72)

            // The bevel where cap rolls into skirt.
            Circle()
                .strokeBorder(
                    LinearGradient(colors: [RigTheme.panel.opacity(0.50), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: max(0.5, diameter * 0.030))
                .frame(width: diameter * 0.74, height: diameter * 0.74)

            // Pointer: 0.16R to 0.90R, matching the capsule the shader draws. Two
            // shadows, tight and wide, stand in for the exponential bloom.
            Capsule()
                .fill(RigTheme.amber)
                .frame(width: max(1, diameter * 0.055), height: diameter * 0.37)
                .offset(y: -diameter * 0.265)
                .rotationEffect(.degrees(pointer.degrees + 90))  // the capsule points at noon; noon is −90°
                .shadow(color: RigTheme.amber.opacity(0.85), radius: diameter * 0.075)
                .shadow(color: RigTheme.emberSoft.opacity(0.40), radius: diameter * 0.17)
        }
        .frame(width: diameter, height: diameter)
    }
}

// The mark has to survive a 42× size range: the app icon at 1024, the splash at
// 116, and a nav-bar glyph at 24. Showing all three together is the only way to
// see that the knurl retires gracefully instead of turning into moiré, and that
// the pointers still read once the knob is 9pt across. Both rendering paths are
// here because they must stay the same drawing.
#Preview("Scale ladder") {
    ScrollView([.horizontal, .vertical]) {
        VStack(alignment: .leading, spacing: 44) {
            HStack(alignment: .center, spacing: 40) {
                AmpLogoView(size: 24)
                AmpLogoView(size: 116)
                AmpLogoView(size: 240)
            }
            HStack(alignment: .center, spacing: 40) {
                AmpLogoView(size: 24, shaded: false)
                AmpLogoView(size: 116, shaded: false)
                AmpLogoView(size: 240, shaded: false)
            }
            AmpLogoView(size: 1024)
        }
        .padding(64)
    }
    .background(RigTheme.background)
    .preferredColorScheme(.dark)
}
