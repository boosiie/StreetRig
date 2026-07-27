//
//  GearArt.swift
//  StreetRig
//
//  Scalable vector art for each gear model — a stylized-but-recognizable
//  drawing of the real-life unit (Tube Screamer green 3-knob, Big Muff "π",
//  MXR boxes, Boss compacts with the big tread plate, Cry Baby treadle,
//  Marshall head + 4x12, a combo). Derived from the item's name/category so
//  it works with already-persisted data; unknown items fall back to a
//  category-appropriate generic. Used on cards, the rig stage, and zoom.
//

import SwiftUI

struct GearArtView: View {
    let item: GearItem?

    var body: some View {
        let category = item?.category ?? .overdrive
        switch category {
        case .guitar:   GuitarBodyArt()
        case .amp:      AmpHeadArt()
        case .cabinet:  CabinetArt()
        case .comboAmp: ComboArt()
        case .wah:      WahArt()
        default:
            let s = Self.spec(name: (item?.name ?? "").lowercased(), category: category)
            PedalArt(tint: s.tint, knobs: s.knobs, label: s.label, treadle: s.treadle, light: s.light)
        }
    }

    /// Map a specific model (by name) or a category to a pedal drawing spec.
    private static func spec(name n: String, category: GearCategory)
        -> (tint: Color, knobs: Int, label: String?, treadle: Bool, light: Bool) {
        if n.contains("tube screamer") { return (.tsGreen, 3, "TS", true, false) }
        if n.contains("big muff")      { return (.muffGray, 3, "π", false, false) }
        if n.contains("dyna")          { return (.dynaRed, 2, "DYNA", false, false) }
        if n.contains("phase")         { return (.phaseOrange, 1, "90", false, false) }
        if n.contains("carbon copy")   { return (.ccGreen, 3, "CC", false, false) }
        if n.contains("ditto")         { return (.dittoWhite, 1, "DITTO", true, true) }
        if n.contains("tu-3")          { return (.tunerGray, 1, "TU-3", true, true) }
        if n.contains("ce-2")          { return (.chorusBlue, 2, "CE-2", true, false) }
        if n.contains("rv-6")          { return (.reverbTeal, 3, "RV-6", true, false) }

        switch category {
        case .delay:      return (.delayGreen, 3, nil, false, false)
        case .reverb:     return (.reverbTeal, 3, nil, true, false)
        case .modulation: return (.chorusBlue, 2, nil, true, false)
        case .compressor: return (.dynaRed, 2, nil, false, false)
        case .tuner:      return (.tunerGray, 1, nil, true, true)
        case .eq:         return (.tunerGray, 3, nil, false, true)
        case .pitch:      return (.chorusBlue, 2, nil, false, false)
        case .looper:     return (.dittoWhite, 1, nil, true, true)
        case .volume:     return (.tunerGray, 1, nil, true, true)
        default:          return (RigTheme.cabinet, 2, nil, false, false)
        }
    }
}

// MARK: - Pedal (Boss compact, MXR box, Tube Screamer, Big Muff, generic)

private struct PedalArt: View {
    var tint: Color
    var knobs: Int
    var label: String?
    var treadle: Bool
    var light: Bool = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let r = w * 0.16
            let knobSize = min(w * 0.24, h * 0.16)
            let labelColor: Color = light ? .black.opacity(0.7) : .white.opacity(0.9)

            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(tint)
                .overlay(
                    LinearGradient(colors: [.white.opacity(0.14), .clear, .black.opacity(0.18)],
                                   startPoint: .top, endPoint: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
                )
                .overlay(
                    VStack(spacing: h * 0.05) {
                        HStack(spacing: w * 0.12) {
                            ForEach(0..<max(1, knobs), id: \.self) { _ in Knob(size: knobSize) }
                        }
                        if let label {
                            Text(label)
                                .font(.system(size: max(6, h * 0.11), weight: .heavy, design: .rounded))
                                .foregroundStyle(labelColor)
                                .lineLimit(1)
                                .minimumScaleFactor(0.4)
                        }
                        Spacer(minLength: 0)
                        ZStack {
                            if treadle {
                                RoundedRectangle(cornerRadius: r * 0.7, style: .continuous)
                                    .fill(.black.opacity(0.22))
                            }
                            Footswitch(size: min(w * 0.4, h * 0.24))
                        }
                        .frame(height: treadle ? h * 0.34 : min(w * 0.4, h * 0.24))
                    }
                    .padding(.vertical, h * 0.10)
                    .padding(.horizontal, w * 0.14)
                )
                .overlay(alignment: .topTrailing) {
                    LEDDot(size: w * 0.12).padding(w * 0.13)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: r, style: .continuous)
                        .strokeBorder(.black.opacity(0.35), lineWidth: max(1, w * 0.05))
                )
        }
    }
}

// MARK: - Amp head / cabinet / combo

private struct AmpHeadArt: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let s = min(w, h)
            RoundedRectangle(cornerRadius: s * 0.12, style: .continuous)
                .fill(RigTheme.cabinet)
                .overlay(
                    VStack(spacing: h * 0.10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: s * 0.04, style: .continuous).fill(RigTheme.panel)
                            HStack(spacing: w * 0.045) {
                                ForEach(0..<5, id: \.self) { _ in
                                    Knob(size: h * 0.17, fill: RigTheme.cabinet, pointer: RigTheme.trim)
                                }
                            }
                        }
                        .frame(height: h * 0.40)
                        RoundedRectangle(cornerRadius: s * 0.03, style: .continuous)
                            .fill(.black.opacity(0.35))
                            .overlay(
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(RigTheme.trim.opacity(0.85))
                                    .frame(width: w * 0.32, height: max(3, h * 0.09))
                            )
                    }
                    .padding(s * 0.07)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: s * 0.12, style: .continuous)
                        .strokeBorder(RigTheme.trim, lineWidth: max(2, s * 0.045))
                )
        }
    }
}

private struct CabinetArt: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let s = min(w, h)
            RoundedRectangle(cornerRadius: s * 0.10, style: .continuous)
                .fill(RigTheme.cabinet)
                .overlay(
                    RoundedRectangle(cornerRadius: s * 0.07, style: .continuous)
                        .fill(.black.opacity(0.30))
                        .overlay(
                            VStack(spacing: h * 0.07) {
                                HStack(spacing: w * 0.07) { SpeakerCone(); SpeakerCone() }
                                HStack(spacing: w * 0.07) { SpeakerCone(); SpeakerCone() }
                            }
                            .padding(s * 0.11)
                        )
                        .padding(s * 0.07)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: s * 0.10, style: .continuous)
                        .strokeBorder(RigTheme.trim, lineWidth: max(2, s * 0.04))
                )
        }
    }
}

private struct ComboArt: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let s = min(w, h)
            RoundedRectangle(cornerRadius: s * 0.11, style: .continuous)
                .fill(RigTheme.cabinet)
                .overlay(
                    VStack(spacing: h * 0.06) {
                        ZStack {
                            RoundedRectangle(cornerRadius: s * 0.03, style: .continuous).fill(RigTheme.panel.opacity(0.85))
                            HStack(spacing: w * 0.05) {
                                ForEach(0..<4, id: \.self) { _ in
                                    Knob(size: h * 0.11, fill: RigTheme.cabinet, pointer: RigTheme.trim)
                                }
                            }
                        }
                        .frame(height: h * 0.22)
                        RoundedRectangle(cornerRadius: s * 0.06, style: .continuous)
                            .fill(.black.opacity(0.30))
                            .overlay(SpeakerCone().padding(w * 0.12))
                    }
                    .padding(s * 0.07)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: s * 0.11, style: .continuous)
                        .strokeBorder(RigTheme.trim, lineWidth: max(2, s * 0.04))
                )
        }
    }
}

// MARK: - Cry Baby wah (rocker treadle)

private struct WahArt: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // Base (near bottom-center)
                RoundedRectangle(cornerRadius: w * 0.10, style: .continuous)
                    .fill(RigTheme.cabinet)
                    .overlay(
                        RoundedRectangle(cornerRadius: w * 0.10, style: .continuous)
                            .strokeBorder(RigTheme.trim.opacity(0.6), lineWidth: max(1, w * 0.03))
                    )
                    .frame(width: w * 0.86, height: h * 0.24)
                    .position(x: w * 0.5, y: h * 0.70)

                // Treadle (tilted, above the base)
                RoundedRectangle(cornerRadius: w * 0.12, style: .continuous)
                    .fill(Color(white: 0.13))
                    .overlay(
                        VStack(spacing: h * 0.045) {
                            ForEach(0..<4, id: \.self) { _ in
                                Capsule().fill(.black.opacity(0.5)).frame(height: max(1, h * 0.02))
                            }
                        }
                        .padding(.horizontal, w * 0.14)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: w * 0.12, style: .continuous)
                            .strokeBorder(RigTheme.trim.opacity(0.5), lineWidth: max(1, w * 0.03))
                    )
                    .frame(width: w * 0.88, height: h * 0.40)
                    .rotationEffect(.degrees(-18))
                    .position(x: w * 0.5, y: h * 0.40)
            }
            .frame(width: w, height: h)
        }
    }
}

// MARK: - Panel colors (used by the zoomed-in control panel)

extension GearArtView {
    /// The component's signature surface color (amp faceplate cream, pedal body, …).
    static func panelColor(for item: GearItem?) -> Color {
        let category = item?.category ?? .overdrive
        switch category {
        case .amp, .comboAmp:   return RigTheme.panel
        case .cabinet, .guitar: return RigTheme.cabinet
        case .wah:              return Color(white: 0.16)
        default:                return spec(name: (item?.name ?? "").lowercased(), category: category).tint
        }
    }

    /// Whether that surface is light (so knobs/labels pick a dark contrast).
    static func panelIsLight(for item: GearItem?) -> Bool {
        let category = item?.category ?? .overdrive
        switch category {
        case .amp, .comboAmp:          return true
        case .cabinet, .guitar, .wah:  return false
        default:                       return spec(name: (item?.name ?? "").lowercased(), category: category).light
        }
    }
}

// MARK: - Shared primitives

private struct Knob: View {
    var size: CGFloat
    var fill: Color = Color(white: 0.82)
    var pointer: Color = .black.opacity(0.7)

    var body: some View {
        ZStack {
            Circle().fill(fill)
            Circle().strokeBorder(.black.opacity(0.35), lineWidth: max(1, size * 0.09))
            Capsule()
                .fill(pointer)
                .frame(width: max(1, size * 0.12), height: size * 0.42)
                .offset(y: -size * 0.15)
        }
        .frame(width: size, height: size)
    }
}

private struct Footswitch: View {
    var size: CGFloat
    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [Color(white: 0.78), Color(white: 0.33)],
                                 center: .topLeading, startRadius: 0, endRadius: size))
            .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: max(1, size * 0.08)))
            .frame(width: size, height: size)
    }
}

private struct LEDDot: View {
    var size: CGFloat
    var body: some View {
        Circle()
            .fill(RigTheme.amber)
            .frame(width: size, height: size)
            .shadow(color: RigTheme.amber, radius: size * 0.7)
    }
}

private struct SpeakerCone: View {
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            ZStack {
                Circle().fill(Color(white: 0.09))
                    .overlay(Circle().strokeBorder(RigTheme.trim.opacity(0.45), lineWidth: max(1, s * 0.05)))
                Circle().fill(Color(white: 0.16)).frame(width: s * 0.45, height: s * 0.45)
            }
            .frame(width: s, height: s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private extension Color {
    static let tsGreen     = Color(red: 0.36, green: 0.55, blue: 0.20)
    static let muffGray    = Color(red: 0.20, green: 0.20, blue: 0.22)
    static let dynaRed     = Color(red: 0.70, green: 0.16, blue: 0.14)
    static let phaseOrange = Color(red: 0.92, green: 0.46, blue: 0.09)
    static let ccGreen     = Color(red: 0.15, green: 0.32, blue: 0.24)
    static let dittoWhite  = Color(red: 0.88, green: 0.88, blue: 0.86)
    static let tunerGray   = Color(red: 0.62, green: 0.64, blue: 0.66)
    static let chorusBlue  = Color(red: 0.16, green: 0.40, blue: 0.70)
    static let reverbTeal  = Color(red: 0.10, green: 0.44, blue: 0.48)
    static let delayGreen  = Color(red: 0.20, green: 0.45, blue: 0.30)
}

#Preview {
    let names = ["Tube Screamer", "Big Muff", "Dyna Comp", "Phase 90", "Carbon Copy",
                 "Ditto Looper", "Boss TU-3", "CE-2 Chorus", "Boss RV-6", "Cry Baby"]
    return ScrollView(.horizontal) {
        HStack(spacing: 12) {
            ForEach(names, id: \.self) { name in
                let cat: GearCategory = name == "Cry Baby" ? .wah : .overdrive
                VStack {
                    GearArtView(item: GearItem(name: name, category: cat))
                        .frame(width: 40, height: 54)
                    Text(name).font(.caption2)
                }
            }
            GearArtView(item: GearItem(name: "Marshall JCM800", category: .amp)).frame(width: 80, height: 54)
            GearArtView(item: GearItem(name: "1960A", category: .cabinet)).frame(width: 70, height: 64)
        }
        .padding()
    }
    .background(RigTheme.background)
    .preferredColorScheme(.dark)
}
