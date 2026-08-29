//
//  CatalogIntegrityCheck.swift
//  StreetRig
//
//  THE CHECK FOR THE FAILURES YOU CANNOT SEE.
//
//  Six seams resolve a gear model to something it needs — its icon, its faceplate
//  PNG, that plate's knob-layout sidecar, its DSP amp voicing, its cab IR and its
//  per-model knob set — and every one of them has a WORKING fallback. Miss one and
//  the build is green, the app launches, nothing logs: a piece just quietly shows
//  the procedural outline, or plays `ampLegacy` (a real amp voicing, merely the
//  wrong one), or draws a Small Slate's two knobs on a univibe. That last one had
//  been shipping for two catalog generations before this file existed: the vibe
//  pedal's BRAND happened to contain the phaser row's matcher token, so the brand
//  quietly chose the panel.
//
//  So the seams are checked here, against tables written out model by model rather
//  than derived from the same code they are testing. `catalogVersion` 5 moved every
//  seam onto a frozen `catalogID`; this is what proves it stayed moved.
//
//  RUNS HEADLESS with the rest of the offline suite (`-RunOfflineRender`), because
//  the project has no XCTest target and a check nobody runs is not a check. It
//  touches no audio and needs no device, so it is also the cheapest thing in the
//  report — see `AudioEngineController+OfflineRender.swift`.
//
//  WHAT IT CANNOT SEE: imageset ORPHANS. `Assets.xcassets` compiles to a single
//  `Assets.car` that cannot be enumerated at runtime, so this proves every catalog
//  id RESOLVES an image, not that every shipped image is reachable from the
//  catalog. The reverse direction is a repo-level check — one `ls` against
//  `RigStore.allModels` — and belongs to whatever runs over the working tree.
//

import Foundation
import SwiftUI
import StreetRigEngine
import UIKit

enum CatalogIntegrityCheck {

    /// (report text, did everything pass).
    static func run() -> (text: String, pass: Bool) {
        var checks: [(String, Bool, String)] = []
        let models = RigStore.allModels

        // ---- 0. Every model has an id, and no two share one. ------------------
        let ids = models.compactMap(\.catalogID)
        checks.append(("every model carries a catalogID", ids.count == models.count,
                       "\(ids.count)/\(models.count)"))
        checks.append(("catalogIDs are unique", Set(ids).count == ids.count,
                       "\(Set(ids).count) distinct"))

        // ---- 1. Art: icon, plate, sidecar. ------------------------------------
        // Resolved through the SAME loaders the app draws with, so a check can
        // only pass by the picture genuinely being findable.
        var missingIcon: [String] = []
        for m in models where GearIconLoader.uiImage(for: m) == nil { missingIcon.append(m.name) }
        checks.append(("every model resolves an icon", missingIcon.isEmpty,
                       missingIcon.isEmpty ? "\(models.count)/\(models.count)" : missingIcon.joined(separator: ", ")))

        // A category plate is a legitimate answer for a piece with no bespoke
        // plate, so the assertion is per-id against the bundle, not via the
        // loader's fallback chain — otherwise six models would pass on someone
        // else's art and nothing would notice a plate had gone missing.
        var missingPlate: [String] = []
        for m in models {
            guard let id = GearCatalog.id(for: m), !platelessIDs.contains(id) else { continue }
            if Bundle.main.url(forResource: "\(id)-panel", withExtension: "png") == nil {
                missingPlate.append(m.name)
            }
        }
        checks.append(("every model with a plate resolves it", missingPlate.isEmpty,
                       missingPlate.isEmpty ? "\(models.count - platelessIDs.count) plates"
                                            : missingPlate.joined(separator: ", ")))

        var missingLayout: [String] = []
        for m in models where sidecarIDs.contains(GearCatalog.id(for: m) ?? "") {
            if PanelArtLoader.knobLayout(for: m) == nil { missingLayout.append(m.name) }
        }
        checks.append(("every plate with a sidecar loads its knob layout", missingLayout.isEmpty,
                       missingLayout.isEmpty ? "\(sidecarIDs.count) layouts"
                                             : missingLayout.joined(separator: ", ")))

        // Orphans, the direction that catches "renamed the model, not its art".
        // Only the flat-file plates can be enumerated (see the header).
        let bundledPlates = Set((Bundle.main.urls(forResourcesWithExtension: "png", subdirectory: nil) ?? [])
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0.hasSuffix("-panel") && !$0.hasPrefix("category-") }
            .map { String($0.dropLast("-panel".count)) })
        let orphanPlates = bundledPlates.subtracting(ids)
        checks.append(("no orphaned panel plates", orphanPlates.isEmpty,
                       orphanPlates.isEmpty ? "\(bundledPlates.count) reachable"
                                            : orphanPlates.sorted().joined(separator: ", ")))

        // ---- 2. DSP: the voicing and the cab, model for model. ----------------
        var wrongProfile: [String] = []
        for m in models where m.category == .amp || m.category == .comboAmp {
            let id = GearCatalog.id(for: m)
            let got = ParameterMap.ampProfile(id: id, name: m.name, values: [:])
            let want = expectedProfile[id ?? ""] ?? -1
            if got != want { wrongProfile.append("\(m.name): \(got) != \(want)") }
            // Said separately because it is the failure that is INAUDIBLE as a
            // bug: ampLegacy is a working amp, just not this one.
            if got == ParameterMap.ampLegacy { wrongProfile.append("\(m.name): fell to ampLegacy") }
        }
        checks.append(("every amp keeps its own voicing (never ampLegacy)", wrongProfile.isEmpty,
                       wrongProfile.isEmpty ? "\(expectedProfile.count) amps/combos"
                                            : wrongProfile.joined(separator: "; ")))

        var wrongCab: [String] = []
        for m in models where m.category == .cabinet || m.category == .comboAmp {
            let id = GearCatalog.id(for: m)
            let got = ParameterMap.cabSlotForCheck(id: id, name: m.name)
            if got != (expectedCabSlot[id ?? ""] ?? -1) { wrongCab.append("\(m.name): \(got)") }
        }
        checks.append(("every cabinet/combo keeps its IR slot", wrongCab.isEmpty,
                       wrongCab.isEmpty ? "\(expectedCabSlot.count) boxes" : wrongCab.joined(separator: "; ")))

        // ---- 3. Knobs, per pedal. ---------------------------------------------
        var wrongKnobs: [String] = []
        for m in models where m.category.isPedal {
            let got = m.parameters.map(\.name)
            let want = expectedKnobs[GearCatalog.id(for: m) ?? ""] ?? ["<no row>"]
            if got != want { wrongKnobs.append("\(m.name): \(got) != \(want)") }
        }
        checks.append(("every pedal keeps its own knobs", wrongKnobs.isEmpty,
                       wrongKnobs.isEmpty ? "\(expectedKnobs.count) pedals" : wrongKnobs.joined(separator: "; ")))

        // ---- 4. Finishes. -----------------------------------------------------
        var missingFinish: [String] = []
        for m in models where m.category.isPedal {
            if PedalFinish.rgb(for: m) == nil { missingFinish.append(m.name) }
        }
        checks.append(("every pedal resolves its enclosure colour", missingFinish.isEmpty,
                       missingFinish.isEmpty ? "\(expectedKnobs.count) pedals"
                                             : missingFinish.joined(separator: ", ")))

        // ---- 5. Factory presets. -----------------------------------------------
        // Two failures, not one: a preset can name gear the catalog does not
        // offer, and it can set a knob the model's panel never draws — which is
        // silent, because a value simply sits in `values` unread.
        var presetProblems: [String] = []
        for preset in RigPresets.all {
            for name in preset.modelNames where !RigStore.catalog.contains(where: { $0.name == name }) {
                presetProblems.append("\(preset.id) names \(name)")
            }
            func knobs(_ modelName: String, _ keys: [String]) {
                guard let m = models.first(where: { $0.name == modelName }) else { return }
                let panel = Set(m.parameters.map(\.name))
                for k in keys.sorted() where !panel.contains(k) {
                    presetProblems.append("\(preset.id) sets \(modelName) \"\(k)\", not on its panel")
                }
            }
            knobs(preset.ampName, Array(preset.ampValues.keys))
            for p in preset.pedals { knobs(p.model, Array(p.values.keys)) }
        }
        checks.append(("every factory preset resolves, and sets only real knobs",
                       presetProblems.isEmpty,
                       presetProblems.isEmpty ? "\(RigPresets.all.count) presets"
                                              : presetProblems.joined(separator: "; ")))

        // ---- 6. Withheld list still matches something. -------------------------
        let names = Set(models.map(\.name))
        let strayWithheld = RigStore.withheldModels.subtracting(names)
        checks.append(("every withheld name matches a model", strayWithheld.isEmpty,
                       strayWithheld.isEmpty ? "\(RigStore.withheldModels.count) withheld"
                                             : strayWithheld.sorted().joined(separator: ", ")))

        let pass = checks.allSatisfy(\.1)
        let body = checks.map { "  \($0.1 ? "PASS" : "FAIL")  \($0.0)\n        \($0.2)" }
                         .joined(separator: "\n")
        return ("""
        === CATALOG INTEGRITY (the seams that fail silently) ===
        Models        : \(models.count)   catalogVersion \(RigStore.catalogVersion)
        \(body)
        CATALOG INTEGRITY OVERALL: \(pass ? "PASS" : "FAIL")
        === END CATALOG INTEGRITY ===
        """, pass)
    }

    /// The six models that ship no bespoke plate and legitimately fall back to
    /// their category's. Listed so "has no plate" and "lost its plate" stay
    /// different answers.
    private static let platelessIDs: Set<String> = [
        "marswell-2415a-4x12", "mesquite-bootleg-oversized-4x12", "tangerine-tsv412",
        "brig-chromatic-tuner", "brig-loop-depot", "electro-galvanic-frost",
    ]

    /// The plates detailed enough to place their own knobs — every amp head and
    /// combo. A missing sidecar reverts that panel to automatic rows, which looks
    /// deliberate and is not.
    private static let sidecarIDs: Set<String> = [
        "marswell-msw900-2140", "marswell-clearpane-stellar-lead-1042", "fremont-gx-140",
        "mesquite-bootleg-dual-reactor", "tangerine-rumblecrest-100", "fandor-tandem-reverb",
        "vane-hv28", "marswell-vcx45c", "rondell-rm-140-velvet-chorus",
        "fandor-bassdude-59", "brig-kabuto-100",
    ]

    // ---- expected knob set, per pedal (47) ----
    private static let expectedKnobs: [String: [String]] = [
        "brig-chromatic-tuner"                : [],
        "dunridge-weeping-willow"             : ["Position"],
        "vane-v921"                           : ["Position"],
        "mordant-wild-pony"                   : ["Position"],
        "krx-damper-comp"                     : ["Sensitivity", "Output"],
        "brig-compression-leveller"           : ["Level", "Tone", "Attack", "Sustain"],
        "keswick-compressor"                  : ["Sustain", "Level", "Blend", "Tone"],
        "brig-distortion"                     : ["Tone", "Level", "Dist"],
        "iberon-valve-shrieker"               : ["Overdrive", "Tone", "Level"],
        "proforge-shrew"                      : ["Distortion", "Filter", "Volume"],
        "brig-metal-realm"                    : ["Level", "Dist", "Low", "Mid", "Mid Freq", "High"],
        "chiron-satyr"                        : ["Gain", "Treble", "Output"],
        "analogue-smith-duke-of-drive"        : ["Volume", "Tone", "Drive"],
        "marswell-blues-blazer"               : ["Gain", "Tone", "Volume"],
        "fullbrook-fixation"                  : ["Volume", "Drive", "Tone"],
        "electro-galvanic-big-mitt"           : ["Sustain", "Tone", "Volume"],
        "dalton-armature-fuzz-dome"           : ["Volume", "Fuzz"],
        "z-flux-fuzz-foundry"                 : ["Volume", "Gate", "Comp", "Drive", "Stab"],
        "exalt-preamp-booster"                : ["Gain"],
        "strider-beryllium"                   : ["Drive", "Tone", "Level"],
        "brig-equalizer"                      : ["100", "200", "400", "800", "1.6k", "3.2k", "6.4k", "Level"],
        "krx-ten-band-eq"                     : ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k", "Volume"],
        "emblem-parametric-eq"                : ["Low Freq", "Low Gain", "Mid Freq", "Mid Gain", "High Freq", "High Gain"],
        "brig-noise-silencer"                 : ["Threshold", "Decay"],
        "quell-nullifier-ii"                  : ["Threshold"],
        "fornax-kraal"                        : ["Threshold", "Hold", "Release"],
        "brig-chorus"                         : ["Rate", "Depth"],
        "krx-swirl-72"                        : ["Speed"],
        "krx-flanger"                         : ["Manual", "Width", "Speed", "Regen"],
        "brig-tremolo"                        : ["Rate", "Wave", "Depth"],
        "electro-galvanic-small-mime"         : ["Rate", "Depth"],
        "electro-galvanic-small-slate"        : ["Rate", "Color"],
        "electro-galvanic-electric-siren"     : ["Rate", "Range", "Color"],
        "fullbrook-lucid-vibe"                : ["Volume", "Intensity", "Speed"],   // corrected: see the Lucid'Vibe note
        "brig-octave"                         : ["Direct", "+1 Oct", "-1 Oct", "-2 Oct"],
        "brig-chorister"                      : ["Balance", "Shift", "Key"],
        "electro-galvanic-micro-stack"        : ["Dry", "Sub", "Octave Up"],
        "digivault-slingshot"                 : ["Position"],
        "brig-digital-delay"                  : ["Time", "Feedback", "Mix"],
        "dunridge-echoreel"                   : ["Volume", "Sustain", "Delay"],
        "electro-galvanic-reverie-mate"       : ["Blend", "Feedback", "Delay", "Depth", "Rate"],
        "brig-reverb"                         : ["Decay", "Tone", "Mix"],
        "electro-galvanic-golden-fleece"      : ["Reverb"],
        "brig-lv-320h"                        : ["Position"],
        "errol-brass-swell-mini"              : ["Position"],
        "brig-loop-depot"                     : [],
        "electro-galvanic-frost"              : [],
    ]

    // ---- expected amp voicing profile, per amp/combo (14) ----
    private static let expectedProfile: [String: Int] = [
        "marswell-msw900-2140"                : 1,
        "marswell-clearpane-stellar-lead-1042": 6,
        "fremont-gx-140"                      : 7,
        "mesquite-bootleg-dual-reactor"       : 8,
        "tangerine-rumblecrest-100"           : 9,
        "fandor-tandem-reverb"                : 2,
        "vane-hv28"                           : 3,
        "marswell-vcx45c"                     : 20,
        "rondell-rm-140-velvet-chorus"        : 4,
        "fandor-bassdude-59"                  : 5,
        "brig-kabuto-100"                     : 14,
    ]

    // ---- expected cab IR slot, per cabinet/combo (9) ----
    private static let expectedCabSlot: [String: Int] = [
        "marswell-2415a-4x12"                 : 0,
        "mesquite-bootleg-oversized-4x12"     : 0,
        "tangerine-tsv412"                    : 0,
        "fandor-tandem-reverb"                : 0,
        "vane-hv28"                           : 1,
        "marswell-vcx45c"                     : 0,
        "rondell-rm-140-velvet-chorus"        : 0,
        "fandor-bassdude-59"                  : 0,
        "brig-kabuto-100"                     : 0,
    ]
}
