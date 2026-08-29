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
//  "big mitt" wins over a bare "fuzz".
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
    /// general. `big mitt` before `fuzz`, `swirl 72` before `phase`.
    private static let byName: [(String, String)] = [
        // ---- Amps -------------------------------------------------------------
        ("msw900",          "Crunch, mid-forward"),
        ("clearpane",           "Bright, cleans up"),
        ("gx-140",          "Modern high gain"),
        ("reactor",       "Scooped, saturated"),
        ("rumblecrest",      "Thick British gain"),
        ("2415a",           "Tight, mid punch"),
        ("oversized 4x12",  "Deep, scooped lows"),
        ("tsv412",          "Warm, rounded"),
        ("tandem reverb",     "Clean headroom, spring"),
        ("hv28",            "Chimey, top boost"),
        ("vcx45c",          "Two channels, crunch"),
        ("rm-140",          "Glassy clean, stereo chorus"),
        ("bassdude",        "Loose, early breakup"),
        ("kabuto",          "Modelled, versatile"),

        // ---- Drive ------------------------------------------------------------
        ("valve shrieker",   "Warm mid hump, cleans up"),
        ("satyr",         "Transparent boost"),
        ("duke of drive",    "Low gain, two sides"),
        ("blues blazer",   "Soft knee, low gain"),
        ("fixation",        "Amp-like, HP/LP switch"),
        ("shrew",           "Hard clip, filter sweep"),
        ("metal realm",      "Scooped, extreme gain"),
        ("big mitt",        "Sustaining wall"),
        ("fuzz dome",       "Germanium, cleans up"),
        ("fuzz foundry",    "Unstable, gated splutter"),
        ("preamp booster",      "Clean lift, slight sparkle"),
        ("beryllium",         "Amp and cab in a box"),
        ("brig distortion", "Hard, aggressive"),

        // ---- Dynamics and filter ---------------------------------------------
        ("damper comp",       "Squashy, percussive"),
        ("compression leveller", "Long sustain, even"),
        ("keswick",          "Transparent, studio-style"),
        ("weeping willow",        "Classic vocal sweep"),
        ("v921",            "Wide, gentle sweep"),
        ("wild pony",      "Switchless, always on"),

        // ---- EQ and gate ------------------------------------------------------
        ("ten band",        "Ten bands, precise"),
        ("parametric eq",          "Parametric, surgical"),
        ("brig equalizer",  "Six bands, ±15 dB"),
        ("nullifier",       "Tracks fast, no chop"),
        ("kraal",            "Gate built for high gain"),
        ("noise silencer","Gate and cut"),

        // ---- Modulation -------------------------------------------------------
        ("swirl 72",        "One knob, swirl"),
        ("small mime",     "Deep, watery chorus"),
        ("small slate",     "Warm, hollow phase"),
        ("electric siren", "Flange with filter matrix"),
        ("lucid",            "Rotary-style throb"),
        ("flanger",         "Jet sweep"),
        ("tremolo",         "Amplitude pulse"),
        ("brig chorus",     "Lush, wide"),

        // ---- Pitch, time, utility ---------------------------------------------
        ("micro stack",       "Clean polyphonic octaves"),
        ("slingshot",          "Pitch bend by pedal"),
        ("chorister",       "Key-aware harmonies"),
        ("octave",          "Sub octave, mono"),
        ("echoreel",        "Tape warble, dark"),
        ("reverie mate",      "Analog, modulated"),
        ("digital delay",   "Clean repeats, long"),
        ("golden fleece",      "Spring, hall, flerb"),
        ("brig reverb",     "Room to hall"),
        ("lv-320",          "Volume swells"),
        ("swell mini",      "Smooth taper"),
        ("loop depot",    "Layer and overdub"),
        ("frost",           "Holds a note forever"),
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
