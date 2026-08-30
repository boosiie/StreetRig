//
//  PanelArtExporter.swift
//  StreetRig
//
//  Bakes every component's knob panel to an editable PNG — the 2D sibling of
//  ModelExporter, and the same round trip: run once, get real files, edit them,
//  drop them back.
//
//  What it writes is `ProceduralPlate` — the exact surface the panel has always
//  drawn — at that piece's own panel proportions, into `Documents/PanelArt/`.
//  Rendering the live view rather than re-deriving the colours means a baked
//  plate is pixel-for-pixel the panel it replaces: the app looks identical the
//  moment the plates land, and every change after that is yours.
//
//  Run it with `STREETRIG_EXPORT_PANELS=1` in the scheme's launch environment
//  (Debug). It NEVER overwrites a plate that already exists — those are edits —
//  so re-running only fills in what is missing. `STREETRIG_EXPORT_PANELS=force`
//  overwrites, which is how you get back to a clean baseline.
//
//  Two homes for the result, and the difference matters:
//    • Leave them in `Documents/PanelArt/` and edit them in the Files app —
//      changes show on the next look at the panel, no rebuild.
//    • Copy them into `StreetRig/PanelArt/` in the repo and they ship with the
//      app, which is where the plates every player sees belong.
//

import SwiftUI
import StreetRigEngine
import UIKit

enum PanelArtExporter {

    /// Bake a plate for every catalog piece that HAS a knob panel, plus one
    /// shared plate per category so a piece nobody has drawn yet still lands on
    /// something authored. Returns the files written.
    @MainActor
    @discardableResult
    static func exportAll(force: Bool = false) -> [URL] {
        let dir = PanelArtLoader.overrideDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var written: [URL] = []
        var skipped = 0

        // Every catalog piece, by name — this is what makes a plate PER COMPONENT
        // rather than per category: the ValveShrieker and the SHREW are both
        // overdrives and both get their own file to paint.
        var plates: [(name: String, item: GearItem)] = RigStore.catalog.compactMap { item in
            let name = PanelArt.plateName(for: item)
            guard !name.isEmpty, !item.parameters.isEmpty else { return nil }
            return (name, item)
        }

        // One fallback plate per category with knobs, for pieces added later.
        // `GearItem(name:)` here is a stand-in for "some piece of this category",
        // so the plate takes the category's generic colour and knob count.
        for category in GearCategory.allCases {
            let probe = GearItem(name: "category \(category.rawValue)", category: category)
            guard !probe.parameters.isEmpty else { continue }
            plates.append((PanelArt.categoryPlateName(for: probe), probe))
        }

        var authored = 0

        for (name, item) in plates {
            let url = dir.appendingPathComponent("\(name).png")
            // HAND ART IS NEVER RE-BAKED, force or not. A piece that ships a knob
            // layout (`<slug>-panel.json`) has a real faceplate drawn for it, with
            // the knobs placed against ITS artwork; overwriting that with a flat
            // baseline would leave the knobs sitting on plain colour and the
            // placement pointing at wells that are no longer painted.
            if PanelArtLoader.knobLayout(for: item) != nil { authored += 1; continue }
            if !force, FileManager.default.fileExists(atPath: url.path) { skipped += 1; continue }
            guard let data = plateData(for: item) else { continue }
            do {
                try data.write(to: url, options: .atomic)
                written.append(url)
            } catch {
                print("panel export failed for \(name): \(error)")
            }
        }

        writeControlManifest(into: dir)

        print("=== StreetRig panel export → \(dir.path) ===")
        print("wrote \(written.count) plate(s)"
              + (skipped > 0 ? ", kept \(skipped) already on disk (STREETRIG_EXPORT_PANELS=force to replace)" : "")
              + (authored > 0 ? ", left \(authored) hand-drawn plate(s) alone" : ""))
        print("=== end panel export ===")
        return written
    }

    /// WHAT TO PUT IN A SIDECAR. Anchors name controls by `GearParameter.name`,
    /// which is not always what the panel prints — the MSW900's PRE-AMP VOLUME is
    /// `Gain`, the GX-140's MIDDLE is `Mid`. Guessing gets you a layout that is
    /// silently ignored, so the exporter writes the real list beside the plates:
    /// every piece with knobs, its dials in panel order, and its switches.
    @MainActor
    private static func writeControlManifest(into dir: URL) {
        var out = ["# StreetRig controls — the names a <slug>-panel.json must use.",
                   "# KNOB  <name>  (printed as <label>)   SWITCH <name> [options]", ""]
        for item in RigStore.catalog where !item.parameters.isEmpty {
            let name = PanelArt.plateName(for: item)
            guard !name.isEmpty else { continue }
            let dials = KnobPanelLayout.dials(item.parameters)
            out.append("\(name).json   — \(item.name)")
            out.append("  \(dials.count) knob(s):")
            for d in dials {
                out.append("    KNOB   \(d.name.padding(toLength: max(16, d.name.count), withPad: " ", startingAt: 0))"
                           + (d.displayName == d.name ? "" : "(printed \(d.displayName))")
                           + (d.isDisabled ? "  [no engine behind it]" : ""))
            }
            let switches = item.parameters.filter { $0.isDiscrete && $0.group == nil }
            if !switches.isEmpty {
                out.append("  \(switches.count) switch(es):")
                for w in switches {
                    out.append("    SWITCH \(w.name.padding(toLength: max(16, w.name.count), withPad: " ", startingAt: 0))"
                               + "\(w.options ?? [])")
                }
            }
            out.append("")
        }
        try? out.joined(separator: "\n").write(to: dir.appendingPathComponent("controls.txt"),
                                                atomically: true, encoding: .utf8)
    }

    /// One piece's plate as PNG data, at the size its panel actually gets.
    @MainActor
    static func plateData(for item: GearItem) -> Data? {
        let size = CGSize(width: PanelArt.referenceWidth,
                          height: KnobPanelLayout.height(item.parameters))
        let renderer = ImageRenderer(
            content: ProceduralPlate(item: item).frame(width: size.width, height: size.height)
        )
        renderer.scale = PanelArt.exportScale
        renderer.isOpaque = true
        return renderer.uiImage?.pngData()
    }
}
