//
//  RigTheme.swift
//  StreetRigEngine
//
//  Central palette so the whole app reads like a warm tube amp:
//  black tolex cabinet, cream/gold faceplate, amber tube glow.
//
//  RELOCATED to the shared framework (Phase 4) so BOTH the standalone app and
//  the AUv3 plugin editor read from one palette — the plugin's SwiftUI knobs are
//  the app's knobs, not a copy. All members are `public`; the app keeps using
//  `RigTheme.*` unqualified via `import StreetRigEngine`.
//

import SwiftUI

public enum RigTheme {
    /// Deep near-black background (amp tolex).
    public static let background = Color(red: 0.051, green: 0.051, blue: 0.063)   // #0D0D10
    /// Slightly lifted charcoal used for gradient depth.
    public static let backgroundLift = Color(red: 0.098, green: 0.098, blue: 0.114) // #19191D

    /// Cabinet body.
    public static let cabinet = Color(red: 0.094, green: 0.094, blue: 0.106)      // #18181B
    /// Cream faceplate / control panel.
    public static let panel = Color(red: 0.922, green: 0.878, blue: 0.784)        // #EBE0C8
    /// Gold trim / piping.
    public static let trim = Color(red: 0.788, green: 0.635, blue: 0.294)         // #C9A24B
    /// Warm amber "tube glow" accent.
    public static let amber = Color(red: 1.0, green: 0.604, blue: 0.180)          // #FF9A2E

    /// Primary text (cream).
    public static let textPrimary = Color(red: 0.925, green: 0.902, blue: 0.831)  // #ECE6D4
    /// Muted status text.
    public static let textMuted = Color(red: 0.541, green: 0.522, blue: 0.482)    // #8A857B
}
