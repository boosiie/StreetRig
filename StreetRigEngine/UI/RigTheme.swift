//
//  RigTheme.swift
//  StreetRigEngine
//
//  Central palette — "Burnt Tan": warm espresso body, cream/tan faceplate,
//  brass trim, and a burnt-orange ember accent (the tube glow).
//
//  RELOCATED to the shared framework (Phase 4) so BOTH the standalone app and
//  the AUv3 plugin editor read from one palette — the plugin's SwiftUI knobs are
//  the app's knobs, not a copy. All members are `public`; the app keeps using
//  `RigTheme.*` unqualified via `import StreetRigEngine`.
//

import SwiftUI

public enum RigTheme {
    /// Deep warm espresso background. Sits at hue 26°, in the same red-dominant
    /// family as `amber` (22°) — see the hue note on the ladder below.
    public static let background = Color(red: 0.090, green: 0.059, blue: 0.035)     // #170F09
    /// Slightly lifted espresso, for gradient depth in a PAGE background — the top
    /// stop of the loading and panel gradients, and nothing else. It is only 1.09:1
    /// against `background`, so a card filled with it is invisible; cards belong on
    /// the elevation ladder below. (They used to live here. That was the bug.)
    public static let backgroundLift = Color(red: 0.145, green: 0.094, blue: 0.063) // #251810

    /// Cabinet body (warm near-black tolex) — the amp and pedal glyphs drawn on the
    /// cards. Hue 25°, in the family; it is small but it sits inside every card.
    public static let cabinet = Color(red: 0.118, green: 0.078, blue: 0.051)        // #1E140D

    // MARK: - Elevation ladder
    //
    // Three rungs, and deliberately only three, so every surface in the app is on a
    // rung you can name:
    //
    //   PAGE    `background`     #170F09     —       the floor
    //   CARD    `surface`        #33221A   1.25:1    cards, panels, list rows, sheets
    //   RAISED  `surfaceRaised`  #412C1F   1.45:1    controls sitting ON a card
    //
    // (WCAG relative-luminance contrast against `background`. The numbers are small
    // on purpose — this is depth read on a dark stage, not text legibility. Tone
    // alone was never going to carry it, which is why `surfaceEdge` and
    // `elevationShadow` below are part of the same ladder and applied with it.)
    //
    // Each rung is an explicit warm RGB, NOT `Color.white.opacity(x)` layered over
    // the page the way Material's dark theme fakes elevation. A white scrim raises
    // contrast and desaturates straight to grey, which would cost "Burnt Tan" its
    // whole identity to fix a flatness problem. Every rung holds R > G > B.
    //
    // HUE DISCIPLINE — the reason these are the values they are. R > G > B alone is
    // not enough: a brown can satisfy it and still read olive. What decides it is how
    // far G sits from R. The first cut of this ladder ran G/R ≈ 0.78 at hue 31–35°,
    // and on a real phone in real light it looked like army khaki — the surfaces were
    // a full 10° yellower than `amber`, and next to a saturated orange the eye pushes
    // a desaturated neighbour further green still. Every rung now sits at hue 19–27°
    // with G/R ≈ 0.67, inside `amber`'s family. Keep new surfaces there; if you add a
    // rung, check its hue against `amber` (22°), not just that R > G > B.

    /// CARD rung: cards, panels, list rows, sheets — a bounded container resting on
    /// the page. Hue 19°, G/R 0.67 — see the hue note above.
    public static let surface = Color(red: 0.200, green: 0.133, blue: 0.102)        // #33221A
    /// RAISED rung: one step above `surface` for things sitting ON a card — chips,
    /// capsules, segmented wells, search fields, keypad keys, slider tracks, glyph
    /// tiles. Never fill a card with it: a card and its own controls at one tone is
    /// exactly the flatness this ladder exists to undo.
    public static let surfaceRaised = Color(red: 0.255, green: 0.173, blue: 0.122)  // #412C1F

    /// The lit edge of a lifted surface — over `surface` it composites to ≈#4D3528,
    /// 1.69:1 against the page, so the border genuinely draws the card's outline. This
    /// does most of the separating; the tone step only backs it up.
    ///
    /// Copper, NOT the cream `panel`. Cream is itself yellow (hue 43°, G/R 0.95), and
    /// thinned over a brown card it dragged the composite to G/R 0.86 — the single
    /// most olive thing on screen, and the most visible, since an edge is what the eye
    /// traces. Copper composites to G/R 0.69 and holds the family hue.
    public static let surfaceEdge = Color(red: 0.851, green: 0.620, blue: 0.451).opacity(0.16)

    /// The ambient drop shadow cast by a lifted surface. Colour only — radius and
    /// offset belong to the `.rigCard()` / `.rigRaised()` modifiers so that every
    /// surface in the app casts the same shadow. Distinct from the coloured glows on
    /// `amber` and the meter LEDs: those are light sources, this is elevation.
    public static let elevationShadow = Color.black.opacity(0.5)

    /// Hairline / divider — a drawn RULE or groove (panel splits, the unlit meter
    /// segments, an unfilled slider track), opaque and independent of whatever is
    /// behind it. Not `surfaceEdge`, which is the translucent outline of a surface,
    /// and not a rung of the ladder: a groove is cut INTO a card, not stacked on it.
    public static let hairline = Color(red: 0.290, green: 0.200, blue: 0.125)       // #4A3320

    /// Cream / tan faceplate (control panels).
    public static let panel = Color(red: 0.918, green: 0.874, blue: 0.769)          // #EADFC4
    /// Brass trim / piping.
    public static let trim = Color(red: 0.788, green: 0.635, blue: 0.294)           // #C9A24B
    /// Burnt-orange ember accent — primary actions, active states, tube glow.
    public static let amber = Color(red: 0.878, green: 0.400, blue: 0.118)          // #E0661E
    /// Softer ember — the ENGAGED transport state (a lit Stop reads as "running",
    /// distinct from the amber "go" of Proceed without shouting like `clip`).
    public static let emberSoft = Color(red: 0.9, green: 0.5, blue: 0.3)            // #E68044

    /// Primary text (warm cream).
    public static let textPrimary = Color(red: 0.957, green: 0.925, blue: 0.855)    // #F4ECDA
    /// Muted status text (warm taupe).
    public static let textMuted = Color(red: 0.690, green: 0.631, blue: 0.533)      // #B0A188

    /// Semantic — "signal present" LED (vintage green) and clip / peak (red),
    /// kept distinct from the ember accent so meters read at a glance.
    public static let signal = Color(red: 0.353, green: 0.663, blue: 0.506)         // #5AA981
    public static let clip = Color(red: 0.812, green: 0.290, blue: 0.196)           // #CF4A32

    // MARK: - Chrome — the app's own bars, and NOTHING that draws gear
    //
    // These are the top nav, the control panel and any surface the APP owns. They
    // are deliberately separate tokens from `panel`, which is a GEAR colour: it is
    // the fallback faceplate in `Faceplate.ampSpec(for:) ?? RigTheme.panel`, it
    // fills the drawn plates in `GearArt`, and it is handed to the logo shader as
    // "cream". Re-grading `panel` to darken the app's bars would repaint every
    // amp's faceplate and the app icon along with them. Two roles, two tokens.
    //
    // Black anodised aluminium, and near-black rather than black: a true black has
    // no surface, takes no light, and would swallow the brass piping.
    //
    // NEUTRAL, NOT COOL. The first cut ran B - R = +8, chosen so the panel would
    // separate from the warm tolex on hue as well as luminance. On a real phone that
    // read plainly BLUE — a near-black carries its cast much further than a swatch
    // suggests, because there is no colour around it to judge it against. It is now
    // B - R = -1, a hair warm of neutral, and the separation rests on the luminance
    // step alone, which is the cue that was doing the work anyway.
    //
    // WHY THESE VALUES. `chromeBody` measures 1.29:1 against `background`, matching
    // the CARD rung's documented-working step above. An earlier cut sat at #191A1D
    // — a more convincing "black" — which measures 1.09:1, the exact ratio the
    // elevation-ladder note above records as the bug that made `backgroundLift`
    // invisible. Hue alone will not hold two near-blacks apart on a cheap screen in
    // daylight, so the panel separates on THREE cues: a real luminance step, a cool
    // cast (B > R, against the warm tolex behind it), and the brass hairline.

    /// The chrome's lip, top and bottom. An edge turns away from the key light, so
    /// it is the darkest part of a lit panel — not the lightest.
    public static let chromeLip = Color(red: 0.090, green: 0.090, blue: 0.086)     // #171716
    /// The chamfer catch: thin, at 2.5% of the panel's height, and the brightest
    /// thing on it. On a dark surface a reflection genuinely IS narrow and faint,
    /// which is why anodised gear reads as expensive and flat at the same time.
    public static let chromeCatch = Color(red: 0.263, green: 0.259, blue: 0.255)   // #434241
    public static let chromeSheen = Color(red: 0.208, green: 0.204, blue: 0.196)   // #353432
    /// The flat field — most of the panel, and it stays flat.
    public static let chromeBody = Color(red: 0.161, green: 0.157, blue: 0.157)    // #292828
    /// The faint bounce low down, where light comes back off the surface below.
    public static let chromeLow = Color(red: 0.169, green: 0.165, blue: 0.161)     // #2B2A29
    /// Legend printed ON the chrome. Light, because the chrome is dark — 10.5:1.
    public static let chromeInk = Color(red: 0.855, green: 0.847, blue: 0.831)     // #DAD8D4
    /// Muted legend on the chrome — captions, units, secondary labels. 4.5:1.
    public static let chromeInkMuted = Color(red: 0.557, green: 0.549, blue: 0.533) // #8E8C88

    /// The UI-chrome accent: primary action, engaged state, selection, focus.
    ///
    /// Matured DOWN from `amber` on purpose, and the reasoning is physical rather
    /// than aesthetic. A control is a PAINTED SURFACE, and paint at 79% saturation
    /// is a toy. `amber` stays exactly where it is because it is LIGHT — LEDs, meter
    /// segments, the tube glow, the logo's pointers — and light IS saturated. One
    /// colour doing both jobs is why the accent used to read as loud everywhere and
    /// special nowhere; now nothing in the interface is allowed to be as hot as a
    /// thing that is actually lit.
    ///
    /// NOTE the direction of this split. `amber` was NOT re-graded, because
    /// `AmpLogoView` hands it to the Metal shader as the pointer ember and the app
    /// icon is baked from that view — maturing it in place would desaturate the
    /// logo and leave the shipped icon out of step with the splash.
    public static let amberChrome = Color(red: 0.761, green: 0.416, blue: 0.173)   // #C26A2C
    public static let amberChromeLit = Color(red: 0.831, green: 0.510, blue: 0.247) // #D4823F
    public static let amberChromeDeep = Color(red: 0.584, green: 0.318, blue: 0.122) // #95511F

    // MARK: - Geometry
    //
    // RADII COLLAPSE. Was 19 distinct values across the codebase, running up to 22.
    // A rounded corner is visual softness applied uniformly to things that are not
    // uniformly soft, and pro audio hardware is square because its controls are
    // machined rather than moulded. At r16 a 52pt button reads as a web CTA.
    // The one radius NOT on this scale is a device bezel, which is a real radius on
    // a real object.
    public enum Radius {
        public static let flush: CGFloat = 0    // full-bleed bars, list rows, dividers
        public static let tight: CGFloat = 2    // chips, wells, text fields
        public static let control: CGFloat = 3  // buttons, cards, segmented
        public static let panel: CGFloat = 4    // modals, sheets, footswitch
        public static let sheet: CGFloat = 6    // the largest permitted
    }

    /// 4pt base. Use these rather than typing a number.
    public enum Space {
        public static let hair: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    /// Brass is a HAIRLINE. It was 3pt on panel edges and 2pt on rings, and at that
    /// weight it stopped being trim and became a stripe — the loudest thing on a
    /// screen whose whole argument is restraint. It still reads at 1pt because the
    /// piping is two-tone: `trim` with a lit `trimLit` line directly above it.
    public static let hairlineWidth: CGFloat = 1

    /// Lit top edge of the brass piping — the bright half of the two-tone hairline.
    public static let trimLit = Color(red: 0.894, green: 0.761, blue: 0.478)       // #E4C27A

    /// Semantic — "this position works": the AR page's placement-ready outline, and
    /// nothing else. Deliberately NOT `amber`, which already means "this pedal is
    /// engaged"; a player standing over their phone has to be able to tell the two
    /// apart at a glance. Deliberately not `signal` either, which is a meter LED —
    /// muted enough to read on the espresso panel, and far too quiet to survive being
    /// drawn as a hairline over a live camera image of a carpet.
    public static let ready = Color(red: 0.322, green: 0.827, blue: 0.478)          // #52D37A
}

// MARK: - Legends

public extension RigTheme {

    /// Letter-spacing for an UPPERCASE legend, in points, derived from the point
    /// size rather than typed in.
    ///
    /// THE BUG THIS FIXES. Tracking was a CONSTANT across the app — 1.2pt on a 9pt
    /// caption and 1.2pt on a 12pt title — while the sizes varied. Constant tracking
    /// means the SMALLER the label, the tighter it reads: `MASTER` at 11/1.2 was
    /// 0.109em and `HOLD TO PLACE` at 8/0.8 was 0.100em, against a page title at
    /// 0.167em. Uppercase needs MORE air as it shrinks, not less, so the app's
    /// smallest legends were its most cramped — which is what makes a panel read as
    /// cartoonish rather than engraved.
    ///
    /// The coefficient falls slightly as size rises (0.228em at 8pt, 0.216 at 11,
    /// 0.212 at 12, 0.196 at 16): small caps want proportionally more space, large
    /// ones want less or they fall apart into separate letters. This is for
    /// UPPERCASE only — running text and the wordmark are untouched, and the
    /// wordmark sets its own tracking from its own size.
    static func legendTracking(_ size: CGFloat) -> CGFloat {
        size * (0.26 - size * 0.004)
    }
}

public extension View {

    /// An uppercase legend printed on a panel: font and tracking together, so the
    /// two cannot drift apart at a call site the way they did before.
    func rigLegend(_ size: CGFloat, weight: Font.Weight = .bold) -> some View {
        font(.system(size: size, weight: weight))
            .tracking(RigTheme.legendTracking(size))
    }
}
