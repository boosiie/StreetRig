//
//  RigTheme.swift
//  StreetRig
//
//  Central palette so the whole app reads like a warm tube amp:
//  black tolex cabinet, cream/gold faceplate, amber tube glow.
//

import SwiftUI

enum RigTheme {
    /// Deep near-black background (amp tolex).
    static let background = Color(red: 0.051, green: 0.051, blue: 0.063)   // #0D0D10
    /// Slightly lifted charcoal used for gradient depth.
    static let backgroundLift = Color(red: 0.098, green: 0.098, blue: 0.114) // #19191D

    /// Cabinet body.
    static let cabinet = Color(red: 0.094, green: 0.094, blue: 0.106)      // #18181B
    /// Cream faceplate / control panel.
    static let panel = Color(red: 0.922, green: 0.878, blue: 0.784)        // #EBE0C8
    /// Gold trim / piping.
    static let trim = Color(red: 0.788, green: 0.635, blue: 0.294)         // #C9A24B
    /// Warm amber "tube glow" accent.
    static let amber = Color(red: 1.0, green: 0.604, blue: 0.180)          // #FF9A2E

    /// Primary text (cream).
    static let textPrimary = Color(red: 0.925, green: 0.902, blue: 0.831)  // #ECE6D4
    /// Muted status text.
    static let textMuted = Color(red: 0.541, green: 0.522, blue: 0.482)    // #8A857B
}
