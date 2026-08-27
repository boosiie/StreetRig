//
//  Faceplate.swift
//  StreetRig
//
//  WHAT AN AMP'S PANEL IS MADE OF. Every amp used to bake the same plate: one
//  cream rectangle, because `GearArtView.panelColor` answered `RigTheme.panel`
//  for the whole category. Eleven amps, eleven identical PNGs — a per-component
//  seam that had nothing per-component in it.
//
//  So the faceplate is a MODEL fact now, not a category one: gold brushed acrylic
//  on the Marswells, silver on the Fandor, copper on the Volt, gunmetal on the
//  Mesa, matte black on the Freedman and the Katana. Colour carries most of it;
//  the finish and the chassis trim band carry the rest, so the four black-panel
//  amps still read as four different amps.
//
//  TWO THINGS COME OUT OF ONE TABLE, and they have to: the plate's colour and
//  whether the plate is LIGHT. Knob captions are drawn dark on a light panel and
//  light on a dark one, so baking a black plate while the category still claimed
//  "amps are light" would print black labels on black metal.
//
//  Matched by SUBSTRING on the model name, like `PedalSpec.parameters` and
//  `GearArtView.spec` — the catalog is re-badged, and a name that doesn't match
//  simply keeps the old cream plate.
//
//  This is only the BASELINE. The plate the app actually draws is
//  `<slug>-panel.png` (see PanelArtLoader); this is what gets baked into that
//  file and what draws when no file exists. Repaint the PNG and none of this
//  matters — which is the point.
//

import SwiftUI
import StreetRigEngine

enum Faceplate {

    /// How the surface is worked. Purely cosmetic; each one is a thin overlay on
    /// the base colour, drawn once at bake time and free thereafter.
    enum Finish {
        /// Flat colour — every pedal, and any amp with no entry in the table.
        case flat
        /// Rolled aluminium: fine horizontal grain under a broad sheen.
        case brushed
        /// Brushed gold acrylic, the Marshall-style panel: vertical sheen band.
        case plexi
        /// Matte paint: no grain, a faint speckle and a soft vignette.
        case painted
        /// Woven cloth, for the tweed-era combo.
        case tweed
    }

    struct Spec {
        var base: Color
        var finish: Finish = .flat
        /// Labels and knob captions go DARK on a light plate, light on a dark one.
        var isLight: Bool = true
        /// The chassis edge along the top and bottom. `nil` = no band.
        var trim: Color? = nil
    }

    /// The faceplate for an amp head or combo, or `nil` for anything else (a
    /// pedal, a cabinet) — those keep the colours `GearArtView` has always given
    /// them. Kept free of any call back into `GearArtView`, which consults this.
    static func ampSpec(for item: GearItem?) -> Spec? {
        guard let item, item.category == .amp || item.category == .comboAmp else { return nil }
        let n = item.name.lowercased()

        // --- Gold-panel Marswells -------------------------------------------
        if n.contains("jcm800") {
            return Spec(base: Color(red: 0.76, green: 0.60, blue: 0.24), finish: .plexi,
                        isLight: true, trim: Color(red: 0.20, green: 0.15, blue: 0.07))
        }
        if n.contains("plexi") || n.contains("plaxi") || n.contains("super lead") {
            // Brighter and brassier than the JCM800's — the plexi panels were.
            return Spec(base: Color(red: 0.83, green: 0.69, blue: 0.33), finish: .plexi,
                        isLight: true, trim: Color(red: 0.24, green: 0.18, blue: 0.08))
        }
        if n.contains("dsl40c") {
            // Black panel, gold chassis band: the modern Marswell, and the cue
            // that keeps it apart from the other three black plates.
            return Spec(base: Color(red: 0.10, green: 0.09, blue: 0.09), finish: .painted,
                        isLight: false, trim: RigTheme.trim)
        }

        // --- Black-panel boutique / high gain -------------------------------
        if n.contains("be-100") || n.contains("freedman") {
            // Cream, not black: the BE-100's own faceplate art is a tan panel, and
            // this table decides the CAPTION COLOUR as well as the plate colour —
            // left dark, the knob pointers and labels were drawn light on light.
            // Sampled from the artwork itself: rgb(224, 193, 131).
            return Spec(base: Color(red: 0.88, green: 0.76, blue: 0.51), finish: .brushed,
                        isLight: true, trim: Color(red: 0.30, green: 0.22, blue: 0.11))
        }
        if n.contains("rectifier") || n.contains("ractifier") || n.contains("mesa") {
            // Metal, not paint — the Rectifier's plate is a visibly brushed one.
            return Spec(base: Color(red: 0.24, green: 0.25, blue: 0.27), finish: .brushed,
                        isLight: false, trim: Color(red: 0.55, green: 0.11, blue: 0.11))
        }
        if n.contains("katana") || n.contains("ketana") {
            return Spec(base: Color(red: 0.13, green: 0.13, blue: 0.15), finish: .painted,
                        isLight: false, trim: RigTheme.amber)
        }

        // --- The orange one --------------------------------------------------
        if n.contains("rockerver") || n.contains("tangerine") {
            return Spec(base: Color(red: 0.85, green: 0.42, blue: 0.10), finish: .painted,
                        isLight: true, trim: Color(red: 0.16, green: 0.09, blue: 0.03))
        }

        // --- Silver / copper combos -----------------------------------------
        if n.contains("twin reverb") {
            // Silverface: bright, faintly cool aluminium.
            return Spec(base: Color(red: 0.78, green: 0.79, blue: 0.80), finish: .brushed,
                        isLight: true, trim: Color(red: 0.20, green: 0.28, blue: 0.45))
        }
        if n.contains("jc-120") || n.contains("jazz chorus") {
            // Greyer and cooler than the Fandor's silver, with the blue hairline.
            return Spec(base: Color(red: 0.60, green: 0.62, blue: 0.65), finish: .brushed,
                        isLight: true, trim: Color(red: 0.14, green: 0.32, blue: 0.58))
        }
        if n.contains("ac30") || n.contains("volt") {
            // Sampled from its own faceplate art: a pink-magenta panel, which is
            // not a colour anyone guesses. rgb(197, 81, 128).
            return Spec(base: Color(red: 0.77, green: 0.32, blue: 0.50), finish: .brushed,
                        isLight: true, trim: Color(red: 0.24, green: 0.08, blue: 0.14))
        }
        if n.contains("bassman") || n.contains("bassdude") {
            // Brushed grey chassis, from the artwork: rgb(150, 148, 150).
            return Spec(base: Color(red: 0.59, green: 0.58, blue: 0.59), finish: .brushed,
                        isLight: true, trim: Color(red: 0.22, green: 0.21, blue: 0.21))
        }

        return nil          // an amp nobody has voiced — keep the cream plate
    }

    /// The plate for ANY piece: the amp's own, or the flat colour every other
    /// category has always used. What `ProceduralPlate` draws and what the
    /// exporter bakes.
    static func spec(for item: GearItem?) -> Spec {
        ampSpec(for: item)
            ?? Spec(base: GearArtView.panelColor(for: item),
                    finish: .flat,
                    isLight: GearArtView.panelIsLight(for: item))
    }
}

// MARK: - Drawing a finish

/// The worked surface, drawn over the base colour. Deliberately low contrast:
/// this is metal under a row of knobs, not a texture to look at.
struct FaceplateFinishView: View {
    let spec: Faceplate.Spec
    /// Stable per piece, so re-baking a plate produces the same file rather than
    /// a fresh scatter of grain every time (`hashValue` is seeded per process and
    /// would not).
    let seed: UInt64

    var body: some View {
        switch spec.finish {
        case .flat:
            EmptyView()
        case .brushed:
            ZStack {
                grain(count: 3.0, maxAlpha: 0.055, thickness: 1.4)
                LinearGradient(colors: [.white.opacity(0.10), .clear, .black.opacity(0.06)],
                               startPoint: .top, endPoint: .bottom)
            }
        case .plexi:
            ZStack {
                grain(count: 2.2, maxAlpha: 0.040, thickness: 1.1)
                // The sheen runs ACROSS a plexi panel, not down it.
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.10), location: 0),
                    .init(color: .white.opacity(0.16), location: 0.34),
                    .init(color: .clear, location: 0.62),
                    .init(color: .black.opacity(0.12), location: 1),
                ], startPoint: .leading, endPoint: .trailing)
            }
        case .painted:
            ZStack {
                speckle(density: 0.9, maxAlpha: 0.05)
                RadialGradient(colors: [.clear, .black.opacity(0.22)],
                               center: .center, startRadius: 0, endRadius: 520)
            }
        case .tweed:
            weave
        }
    }

    // MARK: - Pieces

    /// Horizontal hairlines: rolled metal. `count` is lines per point of height.
    private func grain(count: Double, maxAlpha: Double, thickness: Double) -> some View {
        Canvas { ctx, size in
            var rng = Random(seed: seed)
            let lines = max(1, Int(size.height * count))
            for _ in 0..<lines {
                let y = rng.unit() * size.height
                let h = 0.3 + rng.unit() * thickness
                let a = maxAlpha * (0.25 + rng.unit() * 0.75)
                let light = rng.unit() > 0.5
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: h)),
                         with: .color(light ? .white.opacity(a) : .black.opacity(a)))
            }
        }
    }

    /// Fine dust: matte paint under a light.
    private func speckle(density: Double, maxAlpha: Double) -> some View {
        Canvas { ctx, size in
            var rng = Random(seed: seed &+ 977)
            let dots = max(1, Int(size.width * density))
            for _ in 0..<dots {
                let x = rng.unit() * size.width
                let y = rng.unit() * size.height
                let r = 0.4 + rng.unit() * 0.9
                let a = maxAlpha * (0.3 + rng.unit() * 0.7)
                let light = rng.unit() > 0.42
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                         with: .color(light ? .white.opacity(a) : .black.opacity(a)))
            }
        }
    }

    /// Crosshatch: the tweed combo's cloth, seen through its chrome.
    private var weave: some View {
        Canvas { ctx, size in
            let step: CGFloat = 6
            let span = size.width + size.height
            var x: CGFloat = -size.height
            while x < span {
                for (dx, tone) in [(CGFloat(0), Color.black.opacity(0.06)),
                                   (CGFloat(step / 2), Color.white.opacity(0.05))] {
                    var down = Path()
                    down.move(to: CGPoint(x: x + dx, y: 0))
                    down.addLine(to: CGPoint(x: x + dx + size.height, y: size.height))
                    ctx.stroke(down, with: .color(tone), lineWidth: 1.2)

                    var up = Path()
                    up.move(to: CGPoint(x: x + dx, y: size.height))
                    up.addLine(to: CGPoint(x: x + dx + size.height, y: 0))
                    ctx.stroke(up, with: .color(tone), lineWidth: 1.2)
                }
                x += step
            }
        }
    }

    /// SplitMix64 — small, fast and, unlike `Hasher`, the same every run.
    struct Random {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func unit() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }
    }

    /// FNV-1a over the piece's name — stable across processes and builds.
    static func seed(for item: GearItem?) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (item?.name ?? "").utf8 {
            h ^= UInt64(byte)
            h = h &* 0x1000_0000_01b3
        }
        return h
    }
}
