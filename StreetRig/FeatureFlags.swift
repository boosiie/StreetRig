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

    /// Run the AR page's placement-readiness layer: horizontal plane detection, the
    /// grey → green readiness outline, tap-to-anchor the pedal row onto the real
    /// floor, and the auto-unlock when the phone gets bumped. Strictly additive: the
    /// camera feed, the Vision foot-stomp detection and every tap-to-toggle path are
    /// outside this gate and behave identically either way.
    ///
    /// Off = today's behaviour — the slots sit in their fixed bottom row, stomps are
    /// binned by thirds of the screen, and the banner is the static instruction line.
    /// It also drops ARKit from world tracking to 3-DOF orientation tracking, so
    /// "off" is a real CPU saving rather than a hidden subsystem still running.
    ///
    /// Note this does NOT gate ARKit itself. ARKit is the camera now — it owns the
    /// device exclusively, so there is no second capture stack to fall back to, and
    /// every device that can run this app supports world tracking anyway. What falls
    /// back when ARKit is genuinely unavailable (the Simulator) is the page's own
    /// no-camera path: gradient, placeholder, tap-to-toggle.
    static let arPlacement = true

    /// Stand the anchored AR floor pedals on a real board: a tiered, raked,
    /// open-slat chassis on the floor plane, with the pedals mounted on its deck and
    /// tilted by its rake instead of lying flat on the carpet. See
    /// ARFloorPedalboard.swift for why the board's width is derived from the slot
    /// spacing rather than from a catalogue dimension.
    ///
    /// Off = today's behaviour, exactly: no board node is built, every slot centre
    /// stays at floor level, pedals get yaw and nothing else, and the SwiftUI chrome
    /// and the stomp binner project the same untouched offsets they always did. The
    /// gate is read in ONE place — `ARFloorPedalboard.mountLift` / `.mountRake` /
    /// `.ringLift` — so there is no second path that could drift out of step with it.
    ///
    /// `nonisolated` because that one place is reached from `slotOffsets`, which runs
    /// off the main actor on the way to the ARSession's delegate queue. The value is
    /// an immutable `Bool`; there is nothing here for a thread to race over.
    nonisolated static let arPedalboard = true
}
