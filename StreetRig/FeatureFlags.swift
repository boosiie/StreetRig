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

    /// Open the full-screen SIGNAL CHECK when the player taps Proceed: live
    /// input/output level meters, the capture-route picker, monitoring volume and
    /// the working AR stomp slots on one landscape screen. Strictly additive:
    /// Proceed still engages the engine exactly as before, and the AR page keeps
    /// its place in the pager. Off = Proceed starts monitoring with only the
    /// device bar's status line for feedback, i.e. today's behaviour.
    static let signalCheck = true
}
