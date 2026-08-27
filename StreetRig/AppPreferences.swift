//
//  AppPreferences.swift
//  StreetRig
//
//  The KEY REGISTRY for everything the preferences panel writes, and the
//  non-SwiftUI readers for the same values.
//
//  It exists because a `UserDefaults` key is a contract between two files that
//  never see each other: the panel that writes `streetrig.stage3D` and the rig
//  stage that reads it agree only on a string, and a typo in either one is a
//  preference that silently does nothing. Both sides now spell it once, here.
//
//  DISTINCT FROM `FeatureFlags`, which sits next to this file and looks similar.
//  A flag there is COMPILE-TIME and belongs to the developer: "is this subsystem
//  built in at all". A key here is RUNTIME and belongs to the player: "do I want
//  it on today". `stage3D` reads both — `FeatureFlags.amp3D` decides whether the
//  3D stage is even an option, the preference decides whether it is used — and
//  that is the intended relationship, not a redundancy.
//
//  NAMING: new keys use the lower-case `streetrig.` prefix set by
//  `streetrig.railLiftHintShown` in `CollectionTabView`. The two audio keys keep
//  their original capitalised `StreetRig.` spelling because they are ALREADY ON
//  DISK on every device that has run this app — renaming them would silently
//  reset a preference the player set months ago, which is a worse crime than an
//  inconsistent prefix.
//

import Foundation

enum AppPreferences {

    // MARK: - Audio devices
    //
    // WHY THE PROFILE PAGE WRITES THESE KEYS DIRECTLY INSTEAD OF BINDING TO
    // `AudioEngineController`'s published properties — the one real design
    // decision in this file.
    //
    // The controller is owned by `ControlPanelView` as a private `@StateObject`,
    // so the profile page cannot reach that instance. The two ways out were:
    //
    //   (a) hoist the controller to an `@EnvironmentObject` in `StreetRigApp`,
    //       alongside `RigStore`; or
    //   (b) have the preferences read and write the same `UserDefaults` keys.
    //
    // (b), for a reason that is about lifetime rather than tidiness. Hoisting
    // moves the engine host's creation from "when the control panel first
    // appears" — i.e. after the splash, once, on the main screen — to "at app
    // launch, before anything is on screen", and lengthens its life to the whole
    // process. That object owns the `AVAudioSession`, the `AVAudioEngine` graph,
    // the interruption and route-change observers and the mic-permission state.
    // Its `init` is deliberately inert today, but "deliberately inert" is a
    // property somebody has to keep true forever, and the cost of getting it
    // wrong is a permission prompt or a session activation at the wrong moment —
    // in an audio app, the loudest possible class of bug. Every `#Preview` that
    // renders the panel would also need the object injected or it crashes.
    //
    // What (b) costs: the panel's controller holds its own copies of these two
    // values, read once in `init`. So `AudioEngineController` gained a small
    // `UserDefaults.didChangeNotification` observer that re-reads exactly these
    // two `Bool`s — see `observeDevicePreferenceChanges()`. That is eight lines
    // touching two booleans, against hoisting the audio engine's whole lifetime.
    //
    // If a THIRD surface ever needs live engine state, revisit this: at that
    // point (a) is probably right, and this comment is the argument to answer.

    /// "Ask when something is plugged in." Mirrors
    /// `AudioEngineController.asksAboutNewDevices`. Default: true.
    static let asksAboutNewDevices = "StreetRig.asksAboutNewDevices"

    /// "Switch to new devices automatically" — the standing answer used once
    /// asking is off. Mirrors `AudioEngineController.autoAdoptNewDevices`.
    /// Default: true.
    static let autoAdoptNewDevices = "StreetRig.autoAdoptNewDevices"

    // MARK: - Display

    /// Render the rig stage as the SceneKit diorama rather than the flat vector
    /// layout. Read by `RigStageView.use3DStage`, ANDed with `FeatureFlags.amp3D`.
    static let stage3D = "streetrig.stage3D"

    /// Hold the screen awake while the rig is live. Read by
    /// `AudioEngineController` at engage time.
    ///
    /// The engine has always forced `isIdleTimerDisabled` on while engaged, which
    /// is right for a phone propped up in front of a player and wrong for a phone
    /// left running on a desk. Now it asks.
    static let keepScreenAwake = "streetrig.keepScreenAwake"

    // MARK: - Onboarding

    /// "This player has been shown around." Set when the first-launch chain —
    /// setup guide, then coach-mark tour — either finishes or is skipped, and
    /// cleared by "Reset onboarding" in Preferences.
    ///
    /// DELIBERATELY NOT IN `oneShotHintKeys`. "Show hints again" re-arms the
    /// small in-place tips that fire on the page you are already looking at; it
    /// is a low-stakes button someone might press out of curiosity. This flag
    /// hijacks the next launch with two full-screen guides, which is not
    /// something to hand someone by surprise from a button labelled "hints". It
    /// gets its own, explicitly-named control in the "Help & guides" section.
    static let onboardingComplete = "streetrig.onboardingComplete"

    /// For the non-SwiftUI side. Defaults to false — a fresh install has not
    /// been shown around.
    static var onboardingCompleted: Bool { flag(onboardingComplete, default: false) }

    // MARK: - Reading (for the non-SwiftUI side)

    /// `@AppStorage` is a SwiftUI property wrapper and needs a view to live in;
    /// these are for the readers that are not views. Defaults are expressed as
    /// `object(forKey:) as? Bool ?? true` rather than `bool(forKey:)`, because
    /// `bool(forKey:)` cannot tell "absent" from "false" and every one of these
    /// defaults to ON.
    static var stage3DEnabled: Bool { flag(stage3D, default: true) }
    static var keepScreenAwakeEnabled: Bool { flag(keepScreenAwake, default: true) }
    static var asksAboutNewDevicesEnabled: Bool { flag(asksAboutNewDevices, default: true) }
    static var autoAdoptNewDevicesEnabled: Bool { flag(autoAdoptNewDevices, default: true) }

    static func flag(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    // MARK: - One-shot hints

    /// Flags for hints that are shown once, ever, and then never again. Listed
    /// here so "Show hints again" clears ALL of them: a reset that misses one is
    /// worse than no reset, because the player presses it, sees nothing change
    /// and concludes the button is broken.
    ///
    /// Add a one-shot hint anywhere in the app → add its key to this array.
    static let oneShotHintKeys: [String] = [
        "streetrig.railLiftHintShown"   // CollectionTabView — the rail's first card hops once
    ]

    /// Clear every one-shot hint flag. `removeObject` rather than `set(false)` so
    /// the keys go back to genuinely absent — the same state a fresh install is in,
    /// which is the state the hints were written and tested against.
    static func resetOneShotHints() {
        for key in oneShotHintKeys { UserDefaults.standard.removeObject(forKey: key) }
    }
}
