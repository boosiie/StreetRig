//
//  FeatureFlags.swift
//  StreetRig
//
//  One obvious home for compile-time toggles. Flip a flag here to turn a
//  whole subsystem on or off without hunting through views. Today it gates
//  the experimental real-time 3D amp on the rig stage (see AmpModel3DView);
//  set `amp3D` to false to instantly fall back to the original vector art.
//

import Foundation

enum FeatureFlags {
    /// Render the rig-stage amp as an interactive, PBR-lit 3D model instead of
    /// the flat `GearArtView` vector drawing. Strictly additive: only the amp
    /// head slot (or items flagged `has3DModel`) is affected — every other piece
    /// of gear, the collection cards, and the zoom overlay stay on vector art.
    /// Off = the stage renders exactly as it did before 3D existed.
    static let amp3D = true
}
