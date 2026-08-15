//
//  StreetRigPluginEditorViewController.swift
//  StreetRigEngine
//
//  Phase 4 — the UIKit shell the AUv3 appex embeds to show the SwiftUI plugin
//  editor. It lives in the FRAMEWORK (not the appex) so both the extension AND the
//  headless self-test construct the exact same editor, and so the app never needs
//  to know about it. Its jobs:
//
//    1. Own a plugin-side `RigStore(persist:false)`, seeded from the unit's CURRENT
//       rig (decoded from `dsp.fullState`'s `streetrig.rig.v1` blob) so the editor
//       reflects whatever the host restored — not a stale default.
//    2. Own the `RigAUParameterBridge` that keeps that store and the unit's
//       `AUParameterTree` in two-way sync (knob ⇄ automation).
//    3. Host `PluginEditorView` in a `UIHostingController`, pinned to the edges.
//    4. Flip the compact/full layout when the host calls the unit's `select(_:)`.
//
//  Self-contained in the extension sandbox: no app-only singletons, no host-app
//  state. Main-actor only; adds no audio-thread work.
//

import UIKit
import SwiftUI
import CoreAudioKit   // AUAudioUnitViewConfiguration (`selectedViewConfiguration`)

@MainActor
public final class StreetRigPluginEditorViewController: UIViewController {

    private let dsp: StreetRigDSPUnit
    /// The editor's in-memory store (exposed for tests / hand-off wiring).
    public let store: RigStore
    private let bridge: RigAUParameterBridge
    private let config: EditorConfig
    private var hosting: UIHostingController<PluginEditorView>?

    /// True once the SwiftUI editor is embedded — the headless self-test asserts it.
    public private(set) var editorIsHosted = false

    public init(dsp: StreetRigDSPUnit) {
        self.dsp = dsp

        // Reflect the unit's CURRENT rig (host-restored or the default seed), so
        // opening the editor never silently changes the sound. `fullState` is the
        // public seam; the blob decodes to the same `PersistedState` the unit owns.
        let store = RigStore(persist: false)
        if let data = dsp.fullState?["streetrig.rig.v1"] as? Data,
           let snapshot = try? JSONDecoder().decode(RigStore.PersistedState.self, from: data) {
            store.collection = snapshot.collection
            store.rig = snapshot.rig
        }
        self.store = store

        // Two-way bridge: knob ⇄ AUParameter (built AFTER the store reflects the rig
        // so its initial apply matches the unit).
        self.bridge = RigAUParameterBridge(store: store, dsp: dsp)

        // Initial layout from the host's last selection (default = full).
        let initialCompact: Bool
        if let sel = dsp.selectedViewConfiguration {
            initialCompact = sel.height > 0 && sel.height < StreetRigDSPUnit.compactHeightThreshold
        } else {
            initialCompact = false
        }
        self.config = EditorConfig(isCompact: initialCompact)

        super.init(nibName: nil, bundle: nil)

        // Live layout switch when the host picks a view configuration.
        dsp.viewConfigurationHandler = { [weak self] isCompact in
            self?.config.isCompact = isCompact
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(RigTheme.background)

        let host = UIHostingController(rootView: PluginEditorView(store: store, config: config))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        self.hosting = host
        self.editorIsHosted = true
        preferredContentSize = CGSize(width: 640, height: 420)
    }
}
