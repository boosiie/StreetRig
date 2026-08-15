//
//  ARDiagnostics.swift
//  StreetRig
//
//  TEMPORARY on-device instrumentation for the AR pedal page. Flip
//  `ARDiagnostics.enabled` to false (or strip this file) once the tunables in
//  `ARPlacementCoordinator` and `StompPoseTracker` have been set from real numbers.
//
//  WHY IT EXISTS. ARKit cannot run in the Simulator, so every threshold on that page
//  — minimum plane extent, the below-the-camera lift, the unlock drift, the stomp
//  velocity — was a first-pass guess made from the physical situation rather than from
//  measurement. Guessing is fine; guessing with no way to see which gate is failing is
//  not. "The outline never went green" is a bug report with no information in it; the
//  same session with this on says WHICH of the four readiness gates rejected the frame
//  and by how much, which is the difference between tuning and flailing.
//
//  WHY `print` AND NOT `os.Logger`. This is read over `devicectl device process launch
//  --console`, which wires the app's standard streams to the Mac. `os_log` does not go
//  to stdout, so it would be invisible exactly where it is needed. `stdout` is
//  block-buffered when it is a pipe rather than a terminal, hence the flush: without
//  it the interesting lines sit in a 4 KB buffer until the app exits, which is far too
//  late to be watching a floor with.
//
//  THREADING. Deliberately stateless. Every throttle counter lives in the caller,
//  which is confined to the ARSession's serial delegate queue — so this adds no shared
//  mutable state to a 60 Hz path that already runs alongside a real-time audio thread.
//

import ARKit
import Foundation
import QuartzCore

nonisolated enum ARDiagnostics {

    /// One switch for the whole page. Debug-only by default so a release build cannot
    /// pay for this, however the flag is left.
    #if DEBUG
    static let enabled = true
    #else
    static let enabled = false
    #endif

    /// Every line is prefixed so it can be grepped out of the console's other traffic.
    private static let tag = "[ARDIAG]"

    /// `@autoclosure` so the interpolation is not built when logging is off — the gate
    /// costs a branch, the string it would have made costs an allocation per frame.
    @inline(__always)
    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        print("\(tag) \(String(format: "%7.2f", CACurrentMediaTime())) \(message())")
        fflush(stdout)
    }

    /// Fixed-width floats, because these are read as columns scrolling past rather than
    /// as prose, and ragged numbers hide the trend that is the entire point.
    @inline(__always)
    static func f(_ value: Float, _ places: Int = 2) -> String {
        String(format: "%.\(places)f", value)
    }

    @inline(__always)
    static func f(_ value: CGFloat, _ places: Int = 2) -> String {
        String(format: "%.\(places)f", Double(value))
    }
}

// MARK: - Compact names for the things being watched
//
// Kept HERE rather than on the production types so that deleting this file and its
// call sites removes the instrumentation completely, with nothing left behind on the
// enums the page actually runs on.
//
// `nonisolated` on every one of them, because the project defaults declarations to the
// main actor (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) and every caller is on the
// ARSession's delegate queue. Without it these are main-actor properties read from a
// background thread — the diagnostic would itself be the data race.

nonisolated extension ARPlacementState {
    var diagName: String {
        switch self {
        case .idle:                 return "idle"
        case .unsupported:          return "unsupported"
        case .denied:               return "denied"
        case .running:              return "running"
        case .searching(let hint):  return "searching(\(hint.diagName))"
        case .ready:                return "READY"
        case .locked:               return "LOCKED"
        case .lost:                 return "LOST"
        }
    }
}

nonisolated extension ARPlacementHint {
    var diagName: String {
        switch self {
        case .lookingForFloor: return "lookingForFloor"
        case .holdStill:       return "holdStill"
        case .aimLower:        return "aimLower"
        }
    }
}

nonisolated extension ARCamera.TrackingState {
    var diagName: String {
        switch self {
        case .normal:                                return "normal"
        case .notAvailable:                          return "notAvailable"
        case .limited(.excessiveMotion):             return "limited(motion)"
        case .limited(.initializing):                return "limited(init)"
        case .limited(.relocalizing):                return "limited(reloc)"
        case .limited(.insufficientFeatures):        return "limited(features)"
        case .limited:                               return "limited(?)"
        @unknown default:                            return "unknown"
        }
    }
}
