//
//  StreetRigAUFactory.swift
//  StreetRig AUv3
//
//  Principal class of the StreetRig AUv3 audio-effect app extension (`aufx`).
//  This is a THIN packaging shim around the shared engine: it vends the
//  framework's existing `StreetRigDSPUnit` (the real DSP insertion point) to a
//  host with ZERO DSP duplication, and embeds the framework's SwiftUI editor as
//  the plugin UI. Every sample of audio math AND every knob of the editor live in
//  StreetRigEngine.framework — which BOTH the standalone app and this extension
//  link — so the extension merely lets an out-of-process host (GarageBand, AUM,
//  Logic for iPad, …) discover, instantiate, AND edit that same Audio Unit.
//
//  PHASE 4 SCOPE: the placeholder "editor coming soon" label is replaced with the
//  real editor. `createAudioUnit(with:)` vends the shared unit; the view controller
//  embeds `StreetRigPluginEditorViewController`, which owns a plugin-side
//  `RigStore(persist:false)` + the two-way `RigAUParameterBridge` (knob ⇄
//  AUParameter). The unit advertises compact + full view configurations
//  (`supportedViewConfigurations` / `select`) so the host can pick a size.
//
//  RUNTIME NAMING: `@objc(StreetRigAUFactory)` pins the Obj-C runtime name so the
//  Info.plist `NSExtensionPrincipalClass` and `AudioComponents.factoryFunction`
//  (both the bare string "StreetRigAUFactory") resolve regardless of the Swift
//  module name ("StreetRig_AUv3").
//

import CoreAudioKit
import AVFoundation
import UIKit
import StreetRigEngine

@objc(StreetRigAUFactory)
public final class StreetRigAUFactory: AUViewController, AUAudioUnitFactory {

    /// The vended unit (retained so the editor can bind to it once the view loads).
    private var dspUnit: StreetRigDSPUnit?
    /// The embedded SwiftUI editor shell (framework-owned).
    private var editor: StreetRigPluginEditorViewController?

    // MARK: - AUAudioUnitFactory

    /// Construct the shared engine's Audio Unit across the module boundary and hand
    /// it to the host. `nonisolated` because a host may call this off the main
    /// thread; `StreetRigDSPUnit` is itself `nonisolated`. We also stash the unit
    /// and (on the main actor) install the editor once both the unit and the view
    /// exist — the host may call this before or after loading the view.
    public nonisolated func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let unit = try StreetRigDSPUnit(componentDescription: componentDescription)
        Task { @MainActor in
            self.dspUnit = unit
            self.installEditorIfReady()
        }
        return unit
    }

    // MARK: - Editor hosting (the real Phase-4 UI)

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.05, alpha: 1.0)
        installEditorIfReady()
    }

    /// Embed the framework editor once the unit is vended AND the view is loaded
    /// (whichever order the host does them in). Idempotent.
    @MainActor
    private func installEditorIfReady() {
        guard isViewLoaded, let dsp = dspUnit, editor == nil else { return }

        let vc = StreetRigPluginEditorViewController(dsp: dsp)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(vc)
        view.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            vc.view.topAnchor.constraint(equalTo: view.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        vc.didMove(toParent: self)

        editor = vc
        preferredContentSize = CGSize(width: 640, height: 420)
    }
}
