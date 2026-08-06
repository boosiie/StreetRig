//
//  RigStage3DView.swift
//  StreetRig
//
//  The whole rig as ONE 3D diorama in a single SceneKit view: the amp (center),
//  the pedalboard (in front), and the guitar (to the right) all placed on a
//  common floor and lit together. Dragging orbits the entire scene at once —
//  "moving the living room" — instead of the old split model where a SwiftUI
//  rotation3DEffect warped a flat snapshot while each model orbited on its own.
//
//  Reuses the same procedural builders as the standalone views (ProceduralAmp,
//  PedalboardScene, ProceduralGuitar) so there's one source of truth per model.
//  A single tap is hit-tested to the amp / a pedal / the guitar and routed to
//  the stage's zoom overlay. The amp's knobs still turn live from GearItem.values.
//  Gated by FeatureFlags.amp3D (stacks only; a combo falls back to vector art).
//

import SwiftUI
import SceneKit
import UIKit

struct RigStage3DView: UIViewRepresentable {
    var amp: GearItem?
    var pedals: [GearItem]
    var guitar: GearItem?
    /// Routes a tapped component to the stage so it can open the zoom overlay.
    var onFocus: ((RigComponent) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onFocus: onFocus) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.autoenablesDefaultLighting = false

        // One camera controller orbits the whole diorama around its center.
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.defaultCameraController.target = RigDiorama.lookTarget
        view.defaultCameraController.minimumVerticalAngle = -6      // don't dip under the floor
        view.defaultCameraController.maximumVerticalAngle = 80

        context.coordinator.view = view
        rebuild(view, context: context)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onFocus = onFocus
        let sig = RigDiorama.signature(amp: amp, pedals: pedals, guitar: guitar)
        if context.coordinator.signature != sig {
            rebuild(view, context: context)          // gear set changed → rebuild
        } else {
            context.coordinator.applyAmp(values: amp?.values ?? [:])   // just knob values
        }
    }

    /// Rebuild the scene but keep the user's current camera orientation.
    private func rebuild(_ view: SCNView, context: Context) {
        let scene = RigDiorama.make(amp: amp, pedals: pedals, guitar: guitar)
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: false)
        view.defaultCameraController.target = RigDiorama.lookTarget
        context.coordinator.cacheKnobs(in: scene)
        context.coordinator.applyAmp(values: amp?.values ?? [:])
        context.coordinator.signature = RigDiorama.signature(amp: amp, pedals: pedals, guitar: guitar)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onFocus: ((RigComponent) -> Void)?
        weak var view: SCNView?
        var signature = ""
        private var knobs: [String: SCNNode] = [:]

        init(onFocus: ((RigComponent) -> Void)?) { self.onFocus = onFocus }

        func cacheKnobs(in scene: SCNScene) {
            knobs.removeAll()
            for p in AmpScene.knobParamNames {
                knobs[p] = scene.rootNode.childNode(withName: AmpScene.knobNodeName(p), recursively: true)
            }
        }

        func applyAmp(values: [String: Double]) {
            for (name, node) in knobs {
                node.eulerAngles.z = Studio3D.knobAngle(forValue: values[name] ?? 5)
            }
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let view else { return }
            let hits = view.hitTest(g.location(in: view),
                                    options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
            for hit in hits {
                var node: SCNNode? = hit.node
                while let n = node {                       // walk up to a named group
                    if let name = n.name {
                        if name.hasPrefix("pedal_"),
                           let id = UUID(uuidString: String(name.dropFirst("pedal_".count))) {
                            onFocus?(.pedal(id)); return
                        }
                        if name == "ampRoot"    { onFocus?(.amp); return }
                        if name == "guitarRoot" { onFocus?(.guitar); return }
                    }
                    node = n.parent
                }
            }
        }

        // Let taps coexist with the camera controller's orbit gesture.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

// MARK: - Diorama assembly

/// Places the three procedural models on a shared floor and frames them. All
/// positions are in a single world so one camera orbit moves everything together.
enum RigDiorama {
    /// The point the camera orbits around (roughly the middle of the arrangement).
    static let lookTarget = SCNVector3(0.55, 0.7, 0.3)

    static func signature(amp: GearItem?, pedals: [GearItem], guitar: GearItem?) -> String {
        "\(amp?.id.uuidString ?? "-")|\(guitar?.id.uuidString ?? "-")|"
            + pedals.map { $0.id.uuidString }.joined(separator: ",")
    }

    static func make(amp: GearItem?, pedals: [GearItem], guitar: GearItem?) -> SCNScene {
        let scene = SCNScene()
        let world = SCNNode()
        world.name = "world"

        // ---- Amp: center, slightly back. Bottom (local y ≈ −2.15) sits on the floor.
        let ampRoot = SCNNode()
        ampRoot.name = "ampRoot"
        if let name = amp?.modelName, let loaded = AmpScene.load(usdzNamed: name) {
            ampRoot.addChildNode(loaded)
        } else {
            ProceduralAmp.build(into: ampRoot)
        }
        let ampScale: Float = 0.55
        ampRoot.scale = SCNVector3(ampScale, ampScale, ampScale)
        ampRoot.position = SCNVector3(-0.4, 2.15 * ampScale, -0.9)
        world.addChildNode(ampRoot)

        // ---- Pedalboard: in front of the amp (toward the camera).
        if !pedals.isEmpty {
            let board = PedalboardScene.boardNode(pedals: pedals)
            let bScale: Float = 0.5
            board.scale = SCNVector3(bScale, bScale, bScale)
            board.position = SCNVector3(-0.2, 0.16 * bScale, 1.7)
            board.eulerAngles.x = -0.12                 // slight rake toward the camera
            world.addChildNode(board)
        }

        // ---- Guitar: to the right of the amp, angled toward center.
        let guitarRoot = SCNNode()
        guitarRoot.name = "guitarRoot"
        ProceduralGuitar.buildGuitar(into: guitarRoot)
        ProceduralGuitar.buildStand(into: guitarRoot)
        let gScale: Float = 0.34
        guitarRoot.scale = SCNVector3(gScale, gScale, gScale)
        guitarRoot.position = SCNVector3(2.2, 2.1 * gScale, -0.3)
        guitarRoot.eulerAngles.y = -0.5
        world.addChildNode(guitarRoot)

        scene.rootNode.addChildNode(world)

        // ---- Lighting + grounding shadows + camera.
        Studio3D.addLighting(to: scene)
        Studio3D.addContactShadow(to: scene.rootNode, width: 2.8, height: 2.0, at: SCNVector3(-0.4, 0.02, -0.85))
        if !pedals.isEmpty {
            Studio3D.addContactShadow(to: scene.rootNode, width: 3.0, height: 1.2, at: SCNVector3(-0.2, 0.02, 1.65))
        }
        Studio3D.addContactShadow(to: scene.rootNode, width: 1.3, height: 1.1, at: SCNVector3(2.2, 0.02, -0.2))

        // Zoomed-in, natural 3/4 "living-room" view. Horizontal projection makes
        // the fov span the rig's width so it fills the portrait width; a gentle
        // downward angle keeps the gear faces visible. User can pinch to zoom/orbit.
        let camNode = Studio3D.addCamera(to: scene, position: SCNVector3(0.6, 2.7, 5.3), tilt: -0.36, fov: 43)
        camNode.camera?.projectionDirection = .horizontal
        return scene
    }
}

#Preview {
    RigStage3DView(
        amp: GearItem(name: "Marshall JCM800", category: .amp,
                      values: ["Gain": 8, "Bass": 6, "Mid": 4, "Treble": 7, "Presence": 5, "Master": 6]),
        pedals: [GearItem(name: "Tube Screamer", category: .overdrive),
                 GearItem(name: "Carbon Copy", category: .delay),
                 GearItem(name: "Boss RV-6", category: .reverb)],
        guitar: GearItem(name: "Les Paul Standard", category: .guitar)
    )
    .frame(height: 460)
    .background(RigTheme.background)
    .preferredColorScheme(.dark)
}
