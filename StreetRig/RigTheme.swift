//
//  RigTheme.swift
//  StreetRig
//
//  Central palette — "Burnt Tan": warm espresso body, cream/tan faceplate,
//  brass trim, and a burnt-orange ember accent (the tube glow).
//

import SwiftUI

enum RigTheme {
    /// Deep warm espresso background.
    static let background = Color(red: 0.082, green: 0.063, blue: 0.039)     // #15100A
    /// Slightly lifted espresso for gradient depth.
    static let backgroundLift = Color(red: 0.133, green: 0.098, blue: 0.075) // #221913

    /// Cabinet body (warm near-black tolex).
    static let cabinet = Color(red: 0.106, green: 0.078, blue: 0.051)        // #1B140D
    /// Raised surface behind cards / controls.
    static let surface = Color(red: 0.180, green: 0.141, blue: 0.098)        // #2E2419
    /// Hairline / divider.
    static let hairline = Color(red: 0.255, green: 0.200, blue: 0.122)       // #41331F

    /// Cream / tan faceplate (control panels).
    static let panel = Color(red: 0.918, green: 0.874, blue: 0.769)          // #EADFC4
    /// Brass trim / piping.
    static let trim = Color(red: 0.788, green: 0.635, blue: 0.294)           // #C9A24B
    /// Burnt-orange ember accent — primary actions, active states, tube glow.
    static let amber = Color(red: 0.878, green: 0.400, blue: 0.118)          // #E0661E

    /// Primary text (warm cream).
    static let textPrimary = Color(red: 0.957, green: 0.925, blue: 0.855)    // #F4ECDA
    /// Muted status text (warm taupe).
    static let textMuted = Color(red: 0.690, green: 0.631, blue: 0.533)      // #B0A188

    /// Semantic — "signal present" LED (vintage green) and clip / peak (red),
    /// kept distinct from the ember accent so meters read at a glance.
    static let signal = Color(red: 0.353, green: 0.663, blue: 0.506)         // #5AA981
    static let clip = Color(red: 0.812, green: 0.290, blue: 0.196)           // #CF4A32
}
