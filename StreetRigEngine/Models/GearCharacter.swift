//
//  GearCharacter.swift
//  StreetRigEngine
//
//  ONE LINE THAT SAYS WHY YOU WOULD REACH FOR THIS ONE.
//
//  The library used to show a picture, a name and a category and then stop. With
//  thirteen overdrives in the catalogue that means the card answers "what is it
//  called" and leaves "which of these do I want" to opening all thirteen — the
//  grid's whole speed advantage spent on a second navigation step.
//
//  THE RULE THESE STRINGS FOLLOW: they must DISCRIMINATE, not describe. "Transparent
//  boost" and "hard clip, filter sweep" tell a player which to reach for. "Great
//  overdrive tone" tells them nothing and would be worse than an empty line, because
//  it costs the same space and teaches nothing. Anything that could be said of every
//  pedal in its category does not belong here.
//
//  Kept to about four words. This is a caption on a card in a four-column grid, not
//  a description — the detail view is where a piece gets sentences.
//
//  MATCHED BY SUBSTRING on the model name, the same dispatch `PedalSpec.parameters`
//  and `GearArtView.spec` already use, and for the same reason: the catalog names are
//  re-badged parodies that shift, and a name with no match falls back to its category
//  rather than showing nothing. Specific entries are checked before generic ones, so
//  "big muff" wins over a bare "fuzz".
//

import Foundation

public enum GearCharacter {

    /// The line for a piece, or `nil` if neither its name nor its category has one —
    /// in which case the card simply omits the row. An empty line is better than a
    /// filler line; see the rule in the header.
    public static func line(forName name: String, category: GearCategory) -> String? {
        let n = name.lowercased()
        for (needle, line) in byName where n.contains(needle) { return line }
        return byCategory[category]
    }

    /// Ordered: the first match wins, so anything specific must precede anything
    /// general. `big muff` before `fuzz`, `phase 90` before `phase`.
    private static let byName: [(String, String)] = [
        // ---- Amps -------------------------------------------------------------
        ("jcm800",          "Crunch, mid-forward"),
        ("plaxi",           "Bright, cleans up"),
        ("be-100",          "Modern high gain"),
        ("ractifier",       "Scooped, saturated"),
        ("rockervert",      "Thick British gain"),
        ("1960a",           "Tight, mid punch"),
        ("oversized 4x12",  "Deep, scooped lows"),
        ("ppc412",          "Warm, rounded"),
        ("twin reverb",     "Clean headroom, spring"),
        ("ac30",            "Chimey, top boost"),
        ("dsl40c",          "Two channels, crunch"),
        ("jc-120",          "Glassy clean, stereo chorus"),
        ("bassdude",        "Loose, early breakup"),
        ("ketana",          "Modelled, versatile"),

        // ---- Drive ------------------------------------------------------------
        ("tube screamer",   "Warm mid hump, cleans up"),
        ("centaur",         "Transparent boost"),
        ("king of tone",    "Low gain, two sides"),
        ("blues breaker",   "Soft knee, low gain"),
        ("ocd",             "Amp-like, HP/LP switch"),
        ("rat",             "Hard clip, filter sweep"),
        ("metal zone",      "Scooped, extreme gain"),
        ("big muff",        "Sustaining wall"),
        ("fuzz face",       "Germanium, cleans up"),
        ("fuzz factory",    "Unstable, gated splutter"),
        ("ep booster",      "Clean lift, slight sparkle"),
        ("iridium",         "Amp and cab in a box"),
        ("voss distortion", "Hard, aggressive"),

        // ---- Dynamics and filter ---------------------------------------------
        ("dyna comp",       "Squashy, percussive"),
        ("compression sustainer", "Long sustain, even"),
        ("keenly",          "Transparent, studio-style"),
        ("cry baby",        "Classic vocal sweep"),
        ("v847",            "Wide, gentle sweep"),
        ("bad horsie",      "Switchless, always on"),

        // ---- EQ and gate ------------------------------------------------------
        ("ten band",        "Ten bands, precise"),
        ("paraeq",          "Parametric, surgical"),
        ("voss equalizer",  "Six bands, ±15 dB"),
        ("decimator",       "Tracks fast, no chop"),
        ("zuul",            "Gate built for high gain"),
        ("noise suppressor","Gate and cut"),

        // ---- Modulation -------------------------------------------------------
        ("phase 90",        "One knob, swirl"),
        ("small clone",     "Deep, watery chorus"),
        ("small stone",     "Warm, hollow phase"),
        ("electric mistress", "Flange with filter matrix"),
        ("deja",            "Rotary-style throb"),
        ("flanger",         "Jet sweep"),
        ("tremolo",         "Amplitude pulse"),
        ("voss chorus",     "Lush, wide"),

        // ---- Pitch, time, utility ---------------------------------------------
        ("micro pog",       "Clean polyphonic octaves"),
        ("whammy",          "Pitch bend by pedal"),
        ("harmonist",       "Key-aware harmonies"),
        ("octave",          "Sub octave, mono"),
        ("echoplex",        "Tape warble, dark"),
        ("memory man",      "Analog, modulated"),
        ("digital delay",   "Clean repeats, long"),
        ("holy grail",      "Spring, hall, flerb"),
        ("voss reverb",     "Room to hall"),
        ("fv-500",          "Volume swells"),
        ("vp jr",           "Smooth taper"),
        ("loop station",    "Layer and overdub"),
        ("freeze",          "Holds a note forever"),
        ("chromatic tuner", "Mutes while you tune"),

        // ---- Guitar -----------------------------------------------------------
        ("les paul",        "Humbuckers, thick"),
        ("strat",           "Single coils, bright")
    ]

    /// The fallback when a name matches nothing. Deliberately thin: a category line
    /// is only worth showing because it still separates a delay from a fuzz.
    private static let byCategory: [GearCategory: String] = [
        .overdrive:  "Gain stage",
        .modulation: "Movement and swirl",
        .delay:      "Repeats",
        .reverb:     "Space",
        .eq:         "Tone shaping",
        .noiseGate:  "Silence between notes",
        .compressor: "Evens out dynamics",
        .pitch:      "Shifts pitch",
        .wah:        "Sweeping filter",
        .volume:     "Level by foot",
        .looper:     "Layers phrases",
        .tuner:      "Tuning"
    ]
}
