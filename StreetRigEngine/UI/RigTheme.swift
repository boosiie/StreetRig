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
    /// Deep warm espresso background.
    public static let background = Color(red: 0.082, green: 0.063, blue: 0.039)     // #15100A
    /// Slightly lifted espresso, for gradient depth in a PAGE background — the top
    /// stop of the loading and panel gradients, and nothing else. It is only 1.09:1
    /// against `background`, so a card filled with it is invisible; cards belong on
    /// the elevation ladder below. (They used to live here. That was the bug.)
    public static let backgroundLift = Color(red: 0.133, green: 0.098, blue: 0.075) // #221913

    /// Cabinet body (warm near-black tolex).
    public static let cabinet = Color(red: 0.106, green: 0.078, blue: 0.051)        // #1B140D

    // MARK: - Elevation ladder
    //
    // Three rungs, and deliberately only three, so every surface in the app is on a
    // rung you can name:
    //
    //   PAGE    `background`     #15100A     —       the floor
    //   CARD    `surface`        #2E2419   1.24:1    cards, panels, list rows, sheets
    //   RAISED  `surfaceRaised`  #3A2E20   1.43:1    controls sitting ON a card
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

    /// CARD rung: cards, panels, list rows, sheets — a bounded container resting on
    /// the page. Unchanged in value; the fix was getting the app to actually use it.
    public static let surface = Color(red: 0.180, green: 0.141, blue: 0.098)        // #2E2419
    /// RAISED rung: one step above `surface` for things sitting ON a card — chips,
    /// capsules, segmented wells, search fields, keypad keys, slider tracks, glyph
    /// tiles. Never fill a card with it: a card and its own controls at one tone is
    /// exactly the flatness this ladder exists to undo.
    public static let surfaceRaised = Color(red: 0.227, green: 0.180, blue: 0.125)  // #3A2E20

    /// The lit edge of a lifted surface. Cream faceplate thinned to a hairline rather
    /// than white — over `surface` it composites to ≈#484033, 1.81:1 against the page,
    /// so the border genuinely draws the card's outline while staying in the warm
    /// family. This does most of the separating; the tone step only backs it up. The
    /// `Color.white.opacity(0.06)` edge it replaces was both grey and invisible.
    public static let surfaceEdge = Color(red: 0.918, green: 0.874, blue: 0.769).opacity(0.14)

    /// The ambient drop shadow cast by a lifted surface. Colour only — radius and
    /// offset belong to the `.rigCard()` / `.rigRaised()` modifiers so that every
    /// surface in the app casts the same shadow. Distinct from the coloured glows on
    /// `amber` and the meter LEDs: those are light sources, this is elevation.
    public static let elevationShadow = Color.black.opacity(0.5)

    /// Hairline / divider — a drawn RULE or groove (panel splits, the unlit meter
    /// segments, an unfilled slider track), opaque and independent of whatever is
    /// behind it. Not `surfaceEdge`, which is the translucent outline of a surface,
    /// and not a rung of the ladder: a groove is cut INTO a card, not stacked on it.
    public static let hairline = Color(red: 0.255, green: 0.200, blue: 0.122)       // #41331F

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

    /// Semantic — "this position works": the AR page's placement-ready outline, and
    /// nothing else. Deliberately NOT `amber`, which already means "this pedal is
    /// engaged"; a player standing over their phone has to be able to tell the two
    /// apart at a glance. Deliberately not `signal` either, which is a meter LED —
    /// muted enough to read on the espresso panel, and far too quiet to survive being
    /// drawn as a hairline over a live camera image of a carpet.
    public static let ready = Color(red: 0.322, green: 0.827, blue: 0.478)          // #52D37A
}
