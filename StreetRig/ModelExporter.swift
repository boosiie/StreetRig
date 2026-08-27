//
//  ModelExporter.swift
//  StreetRig
//
//  Bakes the procedural 3D gear (built in code from SceneKit primitives) into
//  real, editable 3D asset files so they can be opened and refined in Blender:
//  a `.usdz` (keeps the PBR materials; also the app's own swap-seam format) and
//  a `.obj` (universal — imports straight into Blender). Debug-only: runs at
//  launch when the `STREETRIG_EXPORT=1` environment variable is set, writes into
//  the app's Documents folder, and prints the paths. Nothing runs in release.
//
//  Round-trip: edit a baked file in Blender → export a clean `.usdz` → bundle it
//  → set the item's `GearItem.modelName` and it loads via `AmpScene.load(usdzNamed:)`.
//

import Foundation
import StreetRigEngine
import SceneKit
import ModelIO
import SceneKit.ModelIO

enum ModelExporter {

    /// Build every gear model into its own scene and write `.usdz` + `.obj`.
    @discardableResult
    static func exportAll() -> [URL] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        var written: [URL] = []

        // Amp head + 4x12 cab
        written += export(name: "StreetRig_Amp", into: docs) { root in
            ProceduralAmp.build(into: root)
        }
        // One file per ENCLOSURE ARCHETYPE, not one representative stompbox.
        // A designer refining "the pedal" used to be handed a generic box and
        // had to guess what the wah or the Boss compact was supposed to be; each
        // family now bakes the shape it is actually replacing. Driven off
        // `allCases` so a new archetype exports itself with no edit here.
        for archetype in PedalArchetype.allCases {
            written += export(name: archetype.exportName, into: docs) { root in
                root.addChildNode(ProceduralPedal.build(for: archetype.representativeItem))
            }
        }
        // Guitar body (no stand) — the model the app ACTUALLY renders, already
        // fitted to the diorama's envelope by `GearModelLoader.guitarNode`.
        //
        // This deliberately no longer bakes `ProceduralGuitar.buildGuitar`: that
        // body is retired and exporting it would hand you an editable baseline for
        // something the app doesn't draw. What you get instead is the real guitar
        // at its exact in-app scale, pivot and facing — which is the useful thing
        // to author a replacement against, since dropping your own
        // `category-guitar.usdz` in has to land in that same box.
        //
        // Note this is the heaviest export of the four (the bundled Stratocaster is
        // ~150k triangles with 2048² textures), so it is the slow one to write.
        written += export(name: "StreetRig_Guitar", into: docs) { root in
            root.addChildNode(GearModelLoader.guitarNode(for: GearItem(name: "Guitar", category: .guitar)))
        }
        // Guitar stand on its own — bind the refined file as "guitar-stand.usdz"
        written += export(name: "StreetRig_Stand", into: docs) { root in
            ProceduralGuitar.buildStand(into: root)
        }

        print("=== StreetRig model export → \(docs.path) ===")
        written.forEach { print("wrote \($0.lastPathComponent)") }
        print("=== end export: \(written.count) file(s) ===")
        return written
    }

    /// Write one model to `.usdz` and `.obj`; returns the files that succeeded.
    private static func export(name: String, into dir: URL, build: (SCNNode) -> Void) -> [URL] {
        let scene = SCNScene()
        let root = SCNNode()
        root.name = name
        build(root)
        scene.rootNode.addChildNode(root)

        var out: [URL] = []

        // USDZ — SceneKit-native, preserves PBR materials.
        let usdz = dir.appendingPathComponent("\(name).usdz")
        try? FileManager.default.removeItem(at: usdz)
        if scene.write(to: usdz, options: nil, delegate: nil, progressHandler: nil) {
            out.append(usdz)
        }

        // OBJ — universal mesh; opens directly in Blender.
        if MDLAsset.canExportFileExtension("obj") {
            let obj = dir.appendingPathComponent("\(name).obj")
            try? FileManager.default.removeItem(at: obj)
            let mdl = MDLAsset(scnScene: scene)
            if (try? mdl.export(to: obj)) != nil {
                out.append(obj)
            }
        }
        return out
    }
}
