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
    /// Bad Horsie (white treadle over a pink box), the Whammy (black treadle over
    /// red), and the Holy Grail and Keenly (silver footswitch on a black box).
    static let byModel: [String: (r: Double, g: Double, b: Double)] = [
    // Tuner
    "voss chromatic tuner"                  : (1.00, 1.00, 1.00),
    // Wah / filter
    "dunlap cry baby"                       : (0.27, 0.27, 0.20),
    "volt v847"                             : (0.20, 0.27, 0.27),
    "morlee bad horsie"                     : (0.73, 0.47, 0.53),
    // Compressor
    "mxp dyna comp"                         : (0.93, 0.07, 0.13),
    "voss compression sustainer"            : (0.00, 0.40, 0.73),
    "keenly compressor"                     : (0.13, 0.13, 0.13),
    // Overdrive / distortion / fuzz / boost
    "voss distortion"                       : (0.93, 0.47, 0.13),
    "ibonez tube screamer"                  : (0.33, 0.80, 0.33),
    "procon rat"                            : (0.13, 0.13, 0.13),
    "voss metal zone"                       : (0.27, 0.27, 0.33),
    "chiron centaur"                        : (0.67, 0.20, 0.20),
    "analogue.man king of tone"             : (0.53, 0.27, 0.47),
    "marswell blues breaker"                : (0.13, 0.13, 0.13),
    "fullstone ocd"                         : (0.87, 0.87, 0.73),
    "electro-harmonium big muff π"          : (0.87, 0.80, 0.80),
    "dallas arbitor fuzz face"              : (0.80, 0.07, 0.07),
    "z.hex fuzz factory"                    : (0.73, 0.80, 0.80),
    "exotiq ep booster"                     : (0.13, 0.13, 0.13),
    "strymo iridium"                        : (0.07, 0.07, 0.07),
    // EQ
    "voss equalizer"                        : (0.93, 0.93, 0.87),
    "mxp ten band eq"                       : (0.80, 0.87, 0.87),
    "empriss paraeq"                        : (0.00, 0.53, 0.93),
    // Noise gate
    "voss noise suppressor"                 : (0.87, 0.87, 0.87),
    "itp decimator ii"                      : (0.67, 0.67, 0.67),
    "fortis zuul"                           : (0.27, 0.27, 0.27),
    // Modulation
    "voss chorus"                           : (0.13, 0.67, 0.80),
    "mxp phase 90"                          : (1.00, 0.53, 0.07),
    "mxp flanger"                           : (0.47, 0.47, 0.53),
    "voss tremolo"                          : (0.00, 0.53, 0.60),
    "electro-harmonium small clone"         : (0.13, 0.13, 0.13),
    "electro-harmonium small stone"         : (0.73, 0.73, 0.73),
    "electro-harmonium electric mistress"   : (0.07, 0.07, 0.07),
    "fullstone deja'vibe"                   : (0.73, 0.73, 0.73),
    // Pitch / octave
    "voss octave"                           : (0.20, 0.13, 0.13),
    "voss harmonist"                        : (0.13, 0.47, 0.67),
    "electro-harmonium micro pog"           : (0.87, 0.07, 0.07),
    "digitek whammy"                        : (0.80, 0.33, 0.33),
    // Delay
    "voss digital delay"                    : (1.00, 0.93, 0.87),
    "dunlap echoplex"                       : (0.13, 0.13, 0.13),
    "electro-harmonium memory man"          : (0.07, 0.07, 0.07),
    // Reverb
    "voss reverb"                           : (0.20, 0.20, 0.20),
    "electro-harmonium holy grail"          : (0.13, 0.13, 0.13),
    // Volume
    "voss fv-500h"                          : (0.20, 0.20, 0.20),
    "ernie bell vp jr"                      : (0.07, 0.07, 0.07),
    // Looper / sustain
    "voss loop station"                     : (0.80, 0.07, 0.07),
    "electro-harmonium freeze"              : (0.93, 0.93, 0.93),
    ]

    static func rgb(for item: GearItem) -> (r: Double, g: Double, b: Double)? {
        byModel[item.name.lowercased()]
    }

    /// Whether a finish is light enough that labels and knobs on it must go dark.
    /// Derived from the colour itself rather than a hand-set flag, so a model
    /// whose paint changes can never keep a contrast choice made for the old one.
    static func isLight(_ rgb: (r: Double, g: Double, b: Double)) -> Bool {
        0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b > 0.55
    }
}
