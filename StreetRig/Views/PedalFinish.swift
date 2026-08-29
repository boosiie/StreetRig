//
//  PedalFinish.swift
//  StreetRig
//
//  What colour each shipped pedal actually is, in one place.
//
//  Sampled from every model's own icon in Assets.xcassets, so the piece on the 3D
//  stage and the zoomed-in knob panel are both the colour of the card that placed
//  them. Before this the two surfaces each kept their own guesses and neither
//  matched the art: one blue on every modulation box, one green on every delay,
//  one teal on every reverb.
//
//  Framework-neutral RGB on purpose — SceneKit wants a UIColor and the 2D art
//  wants a SwiftUI Color, and neither should own the numbers.
//

import Foundation
import CoreGraphics
import StreetRigEngine

enum PedalFinish {
    /// Keyed by the EXACT catalog name, lowercased — the same string
    /// `GearIconLoader.slug` keys artwork off, so a model's paint and its icon can
    /// only be renamed together. A miss falls back to a category default at the
    /// call site rather than guessing.
    ///
    /// Where the biggest area of an icon was a treadle, a label plate or lettering
    /// rather than the chassis, the value was read off the icon by eye instead:
    /// Wild Pony (white treadle over a pink box), the Slingshot (black treadle over
    /// red), and the GoldenFleece and Keswick (silver footswitch on a black box).
    static let byModel: [String: (r: Double, g: Double, b: Double)] = [
    // Tuner
    "brig chromatic tuner"            : (1.00, 1.00, 1.00),
    // Wah / filter
    "dunridge weeping willow"         : (0.27, 0.27, 0.20),
    "vane v921"                       : (0.20, 0.27, 0.27),
    "mordant wild pony"               : (0.73, 0.47, 0.53),
    // Compressor
    "krx damper comp"                 : (0.93, 0.07, 0.13),
    "brig compression leveller"       : (0.00, 0.40, 0.73),
    "keswick compressor"              : (0.13, 0.13, 0.13),
    // Overdrive / distortion / fuzz / boost
    "brig distortion"                 : (0.93, 0.47, 0.13),
    "iberon valve shrieker"           : (0.33, 0.80, 0.33),
    "proforge shrew"                  : (0.13, 0.13, 0.13),
    "brig metal realm"                : (0.27, 0.27, 0.33),
    "chiron satyr"                    : (0.67, 0.20, 0.20),
    "analogue.smith duke of drive"    : (0.53, 0.27, 0.47),
    "marswell blues blazer"           : (0.13, 0.13, 0.13),
    "fullbrook fixation"              : (0.87, 0.87, 0.73),
    "electro-galvanic big mitt ω"     : (0.87, 0.80, 0.80),
    "dalton armature fuzz dome"       : (0.80, 0.07, 0.07),
    "z.flux fuzz foundry"             : (0.73, 0.80, 0.80),
    "exalt preamp booster"            : (0.13, 0.13, 0.13),
    "strider beryllium"               : (0.07, 0.07, 0.07),
    // EQ
    "brig equalizer"                  : (0.93, 0.93, 0.87),
    "krx ten band eq"                 : (0.80, 0.87, 0.87),
    "emblem parametric eq"            : (0.00, 0.53, 0.93),
    // Noise gate
    "brig noise silencer"             : (0.87, 0.87, 0.87),
    "quell nullifier ii"              : (0.67, 0.67, 0.67),
    "fornax kraal"                    : (0.27, 0.27, 0.27),
    // Modulation
    "brig chorus"                     : (0.13, 0.67, 0.80),
    "krx swirl 72"                    : (1.00, 0.53, 0.07),
    "krx flanger"                     : (0.47, 0.47, 0.53),
    "brig tremolo"                    : (0.00, 0.53, 0.60),
    "electro-galvanic small mime"     : (0.13, 0.13, 0.13),
    "electro-galvanic small slate"    : (0.73, 0.73, 0.73),
    "electro-galvanic electric siren" : (0.07, 0.07, 0.07),
    "fullbrook lucid'vibe"            : (0.73, 0.73, 0.73),
    // Pitch / octave
    "brig octave"                     : (0.20, 0.13, 0.13),
    "brig chorister"                  : (0.13, 0.47, 0.67),
    "electro-galvanic micro stack"    : (0.87, 0.07, 0.07),
    "digivault slingshot"             : (0.80, 0.33, 0.33),
    // Delay
    "brig digital delay"              : (1.00, 0.93, 0.87),
    "dunridge echoreel"               : (0.13, 0.13, 0.13),
    "electro-galvanic reverie mate"   : (0.07, 0.07, 0.07),
    // Reverb
    "brig reverb"                     : (0.20, 0.20, 0.20),
    "electro-galvanic golden fleece"  : (0.13, 0.13, 0.13),
    // Volume
    "brig lv-320h"                    : (0.20, 0.20, 0.20),
    "errol brass swell mini"          : (0.07, 0.07, 0.07),
    // Looper / sustain
    "brig loop depot"                 : (0.80, 0.07, 0.07),
    "electro-galvanic frost"          : (0.93, 0.93, 0.93),
    ]

    static func rgb(for item: GearItem) -> (r: Double, g: Double, b: Double)? {
        if let id = GearCatalog.id(for: item), let c = byID[id] { return c }
        return byModel[item.name.lowercased()]
    }

    /// The same table, keyed by frozen `catalogID` — what actually resolves a
    /// shipped pedal. `byModel` above stays as the fallback for gear with no
    /// catalog entry, and as the readable record of which name each colour was
    /// sampled off.
    static let byID: [String: (r: Double, g: Double, b: Double)] = {
        var out: [String: (r: Double, g: Double, b: Double)] = [:]
        for m in RigStore.allModels {
            if let id = m.catalogID, let c = byModel[m.name.lowercased()] { out[id] = c }
        }
        return out
    }()

    /// Whether a finish is light enough that labels and knobs on it must go dark.
    /// Derived from the colour itself rather than a hand-set flag, so a model
    /// whose paint changes can never keep a contrast choice made for the old one.
    static func isLight(_ rgb: (r: Double, g: Double, b: Double)) -> Bool {
        0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b > 0.55
    }
}
