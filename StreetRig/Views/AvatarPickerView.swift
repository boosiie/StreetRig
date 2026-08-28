//
//  AvatarPickerView.swift
//  StreetRig
//
//  The player's face, and the strip they choose it from.
//
//  ARTWORK AND CHOOSING ARE SEPARATE, and the split matters. `AvatarView` answers
//  exactly one question — "draw avatar X, at size N, tinted T" — and knows nothing
//  about choosing, storing or the profile page. `AvatarStripView` and
//  `AvatarTintRow` are the choosers and own none of the artwork. The profile page
//  draws the big live preview, the strip draws fourteen small ones, and a
//  forthcoming tutorial (and, quite likely, the top nav) will draw one smaller
//  still; all of them go through `AvatarView`, so an avatar cannot look like one
//  thing in the strip and another on the page. Everything scales off the single
//  `size` parameter for that reason — there are no hard-coded point values in the
//  artwork below.
//
//  DRAWN, NOT SHIPPED AS IMAGES. Fourteen avatars as PNGs would be fourteen
//  assets × three scales × one per tint — or a tinting pipeline — for artwork
//  that is a symbol on a disc. Ten of them are SF Symbols in the same vocabulary
//  `GearGlyphView` already uses for gear; the other four are drawn here because
//  SF Symbols has no plectrum, no amp knob, no quarter-inch jack and no vacuum
//  tube, and those four are the most StreetRig things on the list. They follow
//  `GearGlyphView`'s approach — simple SwiftUI shapes, one tint, nothing that
//  needs an asset catalogue — which also means they work identically inside the
//  framework should the plugin editor ever want one.
//
//  SELECTION IS AN AMBER RING, because that is what selection already looks like
//  in this app (the library's owned tiles, the drag ghost's edge). A brighter
//  fill was tried first and read as "disabled" against the tinted discs, which
//  are themselves coloured — on a page where the CONTENT is colour, the only
//  reliable way to say "this one" is a shape the unselected ones do not have.
//

import SwiftUI
import StreetRigEngine

// MARK: - Drawing one avatar

/// Draw avatar `style` at `size` points, tinted `tint`. The whole app's answer to
/// "show me this player" — see the file header for why nothing else draws one.
struct AvatarView: View {
    let style: AvatarStyle
    let tint: AvatarTint
    let size: CGFloat
    /// The warm hairline around the disc. Off for the tiny in-line uses where a
    /// 1pt ring on a 22pt circle is just noise.
    var showsEdge: Bool = true

    private var colour: Color { tint.color }

    var body: some View {
        ZStack {
            // The disc sits on the RAISED rung by hand rather than through
            // `.rigRaised()`: that modifier is a background+border pair sized to
            // its content, and this needs the fill to carry a radial gradient of
            // the player's own tint. Same fill colour, same edge colour — the
            // ladder is respected, the gradient is the addition.
            Circle().fill(RigTheme.surfaceRaised)
            Circle().fill(
                // Kept low. Fourteen discs at full strength turned the identity
                // column into a wall of one colour, and `amber` is the app's
                // accent — it stops meaning "interact with me" if it is the
                // background of a quarter of the page.
                RadialGradient(colors: [colour.opacity(0.24), colour.opacity(0.03)],
                               center: .init(x: 0.5, y: 0.34),
                               startRadius: 0, endRadius: size * 0.62)
            )
            glyph
                .frame(width: size * 0.50, height: size * 0.50)
            if showsEdge {
                Circle().strokeBorder(colour.opacity(0.55), lineWidth: max(1, size * 0.028))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(style.displayName) avatar in \(tint.displayName)")
    }

    @ViewBuilder
    private var glyph: some View {
        if let symbol = style.symbolName {
            Image(systemName: symbol)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(colour)
        } else {
            switch style {
            case .pick: PlectrumGlyph(tint: colour)
            case .knob: KnobGlyph(tint: colour)
            case .jack: JackGlyph(tint: colour)
            case .tube: TubeGlyph(tint: colour)
            default:    Image(systemName: "person.fill").resizable().aspectRatio(contentMode: .fit)
                            .foregroundStyle(colour)   // unreachable; keeps the switch total
            }
        }
    }
}

// MARK: - The four procedural glyphs
//
// All four draw into whatever box they are handed, in unit coordinates scaled by
// the shorter side, so a 14pt glyph and a 60pt one are the same drawing. Nothing
// here reads a point value from outside.

/// A plectrum: wide rounded shoulders, a soft point. Four curves rather than a
/// triangle with rounded corners — a real pick's sides bow outward, and the
/// straight-sided version read as a road sign.
private struct PlectrumShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }
        var path = Path()
        path.move(to: p(0.50, 0.05))
        path.addCurve(to: p(0.95, 0.44), control1: p(0.80, 0.05), control2: p(0.95, 0.20))
        path.addCurve(to: p(0.50, 0.97), control1: p(0.95, 0.70), control2: p(0.66, 0.97))
        path.addCurve(to: p(0.05, 0.44), control1: p(0.34, 0.97), control2: p(0.05, 0.70))
        path.addCurve(to: p(0.50, 0.05), control1: p(0.05, 0.20), control2: p(0.20, 0.05))
        path.closeSubpath()
        return path
    }
}

private struct PlectrumGlyph: View {
    let tint: Color
    var body: some View { PlectrumShape().fill(tint) }
}

/// An amp knob seen head-on: a fat ring with a pointer running from the centre
/// out THROUGH it, and three ticks marking the sweep a real control has.
///
/// The first cut had five thin ticks radiating past a thin ring and a stub of a
/// pointer that stopped inside it, and at 29pt that is the brightness icon. What
/// separates a knob from a sun is the pointer crossing the rim, so the pointer is
/// now the boldest thing here and the ticks are the quietest.
private struct KnobGlyph: View {
    let tint: Color
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(tint.opacity(0.45))
                        .frame(width: s * 0.05, height: s * 0.10)
                        .offset(y: -s * 0.45)
                        .rotationEffect(.degrees(Double(i) * 120 - 120))
                }
                Circle()
                    .strokeBorder(tint, lineWidth: s * 0.14)
                    .frame(width: s * 0.60, height: s * 0.60)
                // Pointer parked off twelve o'clock. A ring with a vertical bar
                // through the top of it IS the power symbol, and no amount of tick
                // marks argues with that; a knob turned down to about eight is
                // unmistakably a knob. Rotated as a full-size layer so the anchor
                // is the glyph's centre rather than the capsule's own.
                ZStack {
                    Capsule()
                        .fill(tint)
                        .frame(width: s * 0.12, height: s * 0.36)
                        .offset(y: -s * 0.14)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .rotationEffect(.degrees(-38))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// A quarter-inch jack plug, tip upward: tip, insulating gap, sleeve, then the
/// fatter barrel you actually hold. The gaps are transparent rather than a second
/// colour — at 29pt a two-tone plug is mud.
///
/// The shaft segments are TALL and narrow (roughly 2:1) because the first cut made
/// them squat enough to be circles, and a circle above a wider block is a person
/// icon, not a plug.
private struct JackGlyph: View {
    let tint: Color
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            VStack(spacing: s * 0.035) {
                Capsule().fill(tint).frame(width: s * 0.15, height: s * 0.32)
                Capsule().fill(tint).frame(width: s * 0.15, height: s * 0.20)
                RoundedRectangle(cornerRadius: s * 0.06, style: .continuous)
                    .fill(tint).frame(width: s * 0.42, height: s * 0.27)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// The filament inside the valve — up, over the top, back down.
private struct FilamentShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }
        var path = Path()
        path.move(to: p(0.18, 1.0))
        path.addLine(to: p(0.18, 0.34))
        path.addLine(to: p(0.50, 0.04))
        path.addLine(to: p(0.82, 0.34))
        path.addLine(to: p(0.82, 1.0))
        return path
    }
}

/// A preamp valve: glass envelope, lit filament, base. The filament carries a
/// coloured shadow — the ONE glow in this file, and it is here because the tube
/// glow is where `RigTheme.amberChrome` came from in the first place.
private struct TubeGlyph: View {
    let tint: Color
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.24, style: .continuous)
                    .strokeBorder(tint.opacity(0.8), lineWidth: s * 0.08)
                    .frame(width: s * 0.50, height: s * 0.66)
                    .offset(y: -s * 0.12)
                // Bold and short. A delicate filament reads as a scribble at 29pt;
                // what has to survive is "there is something lit inside the glass".
                FilamentShape()
                    .stroke(tint, style: StrokeStyle(lineWidth: s * 0.10, lineCap: .round, lineJoin: .round))
                    .frame(width: s * 0.24, height: s * 0.30)
                    .offset(y: -s * 0.16)
                    .shadow(color: tint.opacity(0.9), radius: s * 0.10)
                RoundedRectangle(cornerRadius: s * 0.05, style: .continuous)
                    .fill(tint)
                    .frame(width: s * 0.56, height: s * 0.15)
                    .offset(y: s * 0.30)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// MARK: - Choosing one
//
// TWO VIEWS, NOT ONE PICKER. They were one, stacked, and the stack did not fit:
// the identity column has roughly 230 points of height on a phone in landscape,
// and a heading + two rows of discs + a heading + a swatch row came to 275. Split
// apart, the profile page can put the swatches directly under the name field —
// beside the large live preview, where changing the colour is something you WATCH
// happen — and give the strip the room that buys.
//
// They are also the two things a caller might want separately: the forthcoming
// tutorial wants the strip without the swatch row.

/// The avatar strip: fourteen discs on two rows that scroll sideways. Sideways
/// because the app is landscape-only, and a fourteen-item vertical list would eat
/// the entire viewport — see the layout note at the top of `ProfileView`.
struct AvatarStripView: View {
    @Binding var avatar: AvatarStyle
    let tint: AvatarTint
    /// The diameter of one disc. Passed in so the profile page owns the layout
    /// budget and this view owns only the behaviour.
    var tileSize: CGFloat = 34

    private var rows: [GridItem] {
        [GridItem(.fixed(tileSize), spacing: 7), GridItem(.fixed(tileSize), spacing: 7)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("AVATAR")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: rows, spacing: 7) {
                    ForEach(AvatarStyle.allCases) { style in
                        tile(style)
                    }
                }
                .padding(.vertical, 3)   // room for the selection ring to sit proud
                .padding(.horizontal, 3)
            }
        }
    }

    private func tile(_ style: AvatarStyle) -> some View {
        let isSelected = style == avatar
        return Button {
            // Animated so the ring travels rather than teleports — with fourteen
            // near-identical discs, a hard cut leaves you unsure which one moved.
            withAnimation(.easeOut(duration: 0.16)) { avatar = style }
        } label: {
            AvatarView(style: style, tint: tint, size: tileSize, showsEdge: !isSelected)
                .overlay {
                    if isSelected {
                        Circle().strokeBorder(RigTheme.amberChrome, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

}

/// The colour row. Sits directly under the name field on the profile page, next
/// to the large live preview, so a tap on a swatch is something you see land.
struct AvatarTintRow: View {
    @Binding var tint: AvatarTint

    var body: some View {
        HStack(spacing: 4) {
            // The label rides ON the row rather than above it — a second stacked
            // heading is 18 points this layout does not have.
            SectionLabel("TINT")
                .padding(.trailing, 2)
            ForEach(AvatarTint.allCases) { option in
                swatch(option)
            }
            Spacer(minLength: 0)
        }
        // Seven swatches plus a label do not fit beside a 66pt avatar, so this row
        // gets the column's full width. It was nested next to the name field once
        // and SwiftUI resolved the overflow by squeezing the label to nothing — a
        // row of unlabelled coloured dots that could just as easily have been more
        // avatars.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func swatch(_ option: AvatarTint) -> some View {
        let isSelected = option == tint
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { tint = option }
        } label: {
            Circle()
                .fill(option.color)
                .frame(width: 18, height: 18)
                .overlay {
                    Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1)
                }
                .padding(3)
                .overlay {
                    // Same amber ring as the avatar tiles. A tick mark was the
                    // alternative and it disappears on the cream and brass swatches.
                    if isSelected { Circle().strokeBorder(RigTheme.amberChrome, lineWidth: 2) }
                }
                // The dot is 18pt; the thing you can HIT is 26. Drawn small so
                // seven of them fit the column, tappable large so seven of them
                // are still seven separate targets.
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The app's small-bold-caps heading, as used by the top nav and the MY GEAR
/// rail. Defined once here because the profile page and the preferences panel
/// stamp a dozen of them between them.
struct SectionLabel: View {
    let text: String
    var color: Color = RigTheme.textMuted

    init(_ text: String, color: Color = RigTheme.textMuted) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .rigLegend(9, weight: .bold)
            .foregroundStyle(color)
    }
}

#Preview("Every avatar, every tint") {
    ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(AvatarTint.allCases) { tint in
                HStack(spacing: 8) {
                    ForEach(AvatarStyle.allCases) { style in
                        AvatarView(style: style, tint: tint, size: 40)
                    }
                }
            }
        }
        .padding(20)
    }
    .background(RigTheme.background)
    .preferredColorScheme(.dark)
}

#Preview("Picker") {
    @Previewable @State var avatar: AvatarStyle = .tube
    @Previewable @State var tint: AvatarTint = .amber
    VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 12) {
            AvatarView(style: avatar, tint: tint, size: 66)
            AvatarTintRow(tint: $tint)
        }
        AvatarStripView(avatar: $avatar, tint: tint)
    }
    .frame(width: 262)
    .padding(24)
    .background(RigTheme.background)
    .preferredColorScheme(.dark)
}
