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
    /// Slightly lifted espresso for gradient depth.
    public static let backgroundLift = Color(red: 0.133, green: 0.098, blue: 0.075) // #221913

    /// Cabinet body (warm near-black tolex).
    public static let cabinet = Color(red: 0.106, green: 0.078, blue: 0.051)        // #1B140D
    /// Raised surface behind cards / controls.
    public static let surface = Color(red: 0.180, green: 0.141, blue: 0.098)        // #2E2419
    /// Hairline / divider.
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
