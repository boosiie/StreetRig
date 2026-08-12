//
//  StreetRigAUFactory.swift
//  StreetRig AUv3
//
//  Principal class of the StreetRig AUv3 audio-effect app extension (`aufx`).
//  This is a THIN packaging shim around the shared engine: it vends the
//  framework's existing `StreetRigDSPUnit` (the real DSP insertion point) to a
//  host with ZERO DSP duplication. Every sample of audio math lives in
//  StreetRigEngine.framework — which BOTH the standalone app and this extension
//  link — so the extension merely lets an out-of-process host (GarageBand, AUM,
//  Logic for iPad, …) discover and instantiate that same Audio Unit as a track
//  insert. The component identity (`aufx`/`srds`/`Strg`) is declared once in the
//  framework's `StreetRigDSPUnit.componentDescription` and advertised to the OS
//  by this appex's Info.plist `AudioComponents` block.
//
//  PHASE 2 SCOPE: discoverable + instantiable, passing audio with the current
//  default rig. The view returned here is a MINIMAL PLACEHOLDER — the real
//  SwiftUI editor (reusing the app's knob/rig components) is Phase 4. No
//  parameter-tree expansion / fullState / presets yet (Phase 3).
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

    // MARK: - AUAudioUnitFactory

    /// Construct the shared engine's Audio Unit across the module boundary and
    /// hand it to the host. `nonisolated` because a host may call this off the
    /// main thread; `StreetRigDSPUnit` is itself `nonisolated` and its designated
    /// initializer was made `public` in Phase 2, so this is a straight hand-off
    /// with no DSP re-implementation. The default rig / tone assets load lazily
    /// inside the unit's `allocateRenderResources`, resolving from the linked
    /// framework bundle via `Bundle(for: StreetRigDSPUnit.self)`.
    public nonisolated func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        try StreetRigDSPUnit(componentDescription: componentDescription)
    }

    // MARK: - Placeholder editor (the real editor is Phase 4)

    public override func viewDidLoad() {
        super.viewDidLoad()

        preferredContentSize = CGSize(width: 480, height: 272)
        view.backgroundColor = UIColor(white: 0.07, alpha: 1.0)

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "StreetRig"
        label.textAlignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        view.addSubview(label)

        let caption = UILabel()
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.text = "AUv3 · editor coming soon"
        caption.textAlignment = .center
        caption.textColor = UIColor(white: 0.6, alpha: 1.0)
        caption.font = .systemFont(ofSize: 12, weight: .regular)
        view.addSubview(caption)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            caption.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            caption.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
        ])
    }
}
