//
//  RigPreset.swift
//  StreetRigEngine
//
//  A WHOLE RIG AS DATA: an amp, its knobs, and a board — enough to put a named
//  tone on the stage in one tap.
//
//  WHY THIS EXISTS. Everything the app has built up to now is a builder: drag a
//  cab onto a head, drag a pedal off the rail, tap it, turn six knobs. That is
//  the point of the app and it is not going away — but it is also the wrong
//  first five minutes for somebody who just wants to hear what a Reactor
//  sounds like. A preset is the answer to "make it sound like X" without
//  learning what a presence control does first, and it is a teaching surface as
//  much as a shortcut: the detail pane prints every knob it is about to set, so
//  loading one and then looking at the amp shows you where those numbers went.
//
//  THE NUMBERS ARE THE POINT, AND THEY ARE REAL. A preset is not a hidden DSP
//  mode — there is nothing here the player could not dial by hand. Each one
//  names catalog models by the name the library shows and sets knobs by the name
//  the faceplate prints, which is why `ampValues` for a Reactor talks about
//  "Gain 2" and one for a MSW900 talks about "Gain": those are the keys those
//  two panels actually persist (see `PedalSpec` in Gear.swift).
//
//  THE CHANNEL RULE IS COPIED FROM THE COMPILER, DELIBERATELY. `RigGraphCompiler`
//  resolves a two-channel amp's knobs by preferring the " 2"-suffixed key when
//  CHANNEL is on 1, and `ampHeadline` below does exactly the same thing — so the
//  six numbers this screen prints are the six numbers the engine reads. If that
//  rule ever changes in the compiler, it changes here in the same commit, or the
//  preset page starts quietly lying about the amp.
//
//  EVERY NAME IN HERE IS LOAD-BEARING. Models are matched against
//  `RigStore.catalog` by exact name, so a typo or a model that gets withheld
//  makes the whole preset refuse to load rather than half-load — see
//  `RigStore.apply(_:)`, which resolves everything before it mutates anything.
//

import Foundation

// MARK: - The shape of a preset

public struct RigPreset: Identifiable, Hashable {

    /// A head + cabinet, or a combo. The same two shapes `AmpSection` has, named
    /// by MODEL rather than by id — a preset is written before the player owns
    /// any of it, so it cannot carry ids.
    public enum Amp: Hashable {
        case stack(head: String, cab: String)
        case combo(String)
    }

    /// One pedal and the knobs the preset sets on it. Knobs it does not name keep
    /// whatever they already had, which for a pedal the player has never owned is
    /// that control's own default.
    public struct Pedal: Hashable {
        public let model: String
        public let values: [String: Double]
        public init(_ model: String, _ values: [String: Double]) {
            self.model = model
            self.values = values
        }
    }

    public let id: String
    /// Short, and in the words a player would use to ask for it.
    public let name: String
    /// One line under the name in the list. It has to say what it SOUNDS like,
    /// not what it contains — the gear is printed right underneath anyway.
    public let tagline: String
    /// Two or three sentences: what it is for, and what makes it that.
    public let blurb: String
    public let symbol: String
    public let amp: Amp
    public let ampValues: [String: Double]
    public let pedals: [Pedal]
    /// The one thing worth saying out loud about how it is set — usually the
    /// trick that makes the tone rather than the tone itself.
    public let note: String?

    public init(id: String, name: String, tagline: String, blurb: String, symbol: String,
                amp: Amp, ampValues: [String: Double], pedals: [Pedal] = [], note: String? = nil) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.blurb = blurb
        self.symbol = symbol
        self.amp = amp
        self.ampValues = ampValues
        self.pedals = pedals
        self.note = note
    }

    // MARK: What it is made of, in words

    public var ampName: String {
        switch amp {
        case .stack(let head, _): return head
        case .combo(let combo):   return combo
        }
    }

    public var cabName: String? {
        switch amp {
        case .stack(_, let cab): return cab
        case .combo:             return nil
        }
    }

    /// Every model this preset needs, amp section first. What `RigStore.apply`
    /// has to be able to resolve, and what the debug check below walks.
    public var modelNames: [String] {
        var names = [ampName]
        if let cabName { names.append(cabName) }
        names.append(contentsOf: pedals.map(\.model))
        return names
    }

    /// THE SIX THE ENGINE ACTUALLY READS, resolved the way the compiler resolves
    /// them — see the file header. A knob the preset leaves alone is omitted
    /// rather than printed at a guessed value, because the honest answer for it
    /// is "whatever that amp's panel defaults to", which is not a number this
    /// screen knows.
    public var ampHeadline: [(label: String, value: Double)] {
        let onChannelTwo = (ampValues["CHANNEL"] ?? 0) >= 0.5
        func role(_ keys: [String]) -> Double? {
            if onChannelTwo {
                for key in keys { if let v = ampValues[key + " 2"] { return v } }
            }
            for key in keys { if let v = ampValues[key] { return v } }
            return nil
        }
        var out: [(String, Double)] = []
        if let v = role(["Gain", "GAIN"])     { out.append(("GAIN", v)) }
        if let v = role(["Bass", "BASS"])     { out.append(("BASS", v)) }
        if let v = role(["Mid", "MIDDLE"])    { out.append(("MID", v)) }
        if let v = role(["Treble", "TREBLE"]) { out.append(("TREBLE", v)) }
        // CUT and PRESENCE are the same destination under two names (the HV28
        // prints CUT and it runs backwards); print whichever the panel shows.
        if let v = role(["Cut"])              { out.append(("CUT", v)) }
        else if let v = role(["Presence"])    { out.append(("PRESENCE", v)) }
        if let v = role(["Master"])           { out.append(("MASTER", v)) }
        if let v = role(["Volume"])           { out.append(("VOLUME", v)) }
        return out
    }

    /// A pedal's settings IN PANEL ORDER, labelled the way its own faceplate
    /// labels them. Built from a throwaway `GearItem` rather than from the
    /// dictionary, because a dictionary has no order and "Level 7 · Tone 6 ·
    /// Overdrive 3" is a ValveShrieker described backwards.
    public func settings(for pedal: Pedal) -> [(label: String, value: Double)] {
        guard let entry = RigPreset.catalogItem(named: pedal.model) else { return [] }
        let spec = GearItem(catalogID: entry.catalogID, name: entry.name, category: entry.category)
        return spec.parameters.compactMap { parameter in
            pedal.values[parameter.name].map { (parameter.displayName, $0) }
        }
    }

    static func catalogItem(named name: String) -> GearItem? {
        RigStore.catalog.first { $0.name == name }
    }
}

// MARK: - The presets

public enum RigPresets {

    /// NINE TONES, ORDERED BY GAIN — clean at the top, fuzz and ambient at the
    /// bottom, which is the order a player scans for "somewhere near what I
    /// want" and the order the knob settings themselves climb.
    ///
    /// EVERY AVAILABLE AMP EXCEPT THREE IS USED ONCE. That is not tidiness for
    /// its own sake: a preset list where six entries are the same head with
    /// different pedals teaches nothing about the amps, and the amps are the
    /// part of this app that took the most work to get right.
    ///
    /// THREE PEDALS IS THE CEILING, because `RigStore.maxPedalsOnBoard` is 3 and
    /// a preset does not get to break the rule every other add path obeys. It is
    /// also enough: past three the fourth pedal is nearly always a second thing
    /// doing the first thing's job.
    ///
    /// GATES ON THE HIGH-GAIN ONES, on purpose. A Reactor on channel 2 with a
    /// boost in front of it roars between notes — that is what the amp does and
    /// what this app is copying — so the presets that ask for that gain ship the
    /// pedal that answers for it. See `FAQView`.
    public static let all: [RigPreset] = [

        // ---- 1. CLEAN ----------------------------------------------------
        RigPreset(
            id: "clean",
            name: "CLEAN",
            tagline: "Big, bright and undistorted. Headroom for days.",
            blurb: "A blackface combo on the vibrato channel with the volume set below "
                 + "where it starts to break up, a compressor evening out the picking "
                 + "hand and a slow chorus behind it. Chords stay separate no matter how "
                 + "hard you hit them.",
            symbol: "drop",
            amp: .combo("Fandor Tandem Reverb"),
            ampValues: [
                // VIBRATO — the channel with the reverb on it, so the compiler
                // reads the " 2" row (see the header's channel rule).
                "CHANNEL": 1,
                "Gain 2": 4.5, "Treble 2": 6.5, "Bass 2": 5.5,
                "REVERB": 3.5, "SPEED": 4, "INTENSITY": 0,
                // The normal channel left somewhere sensible, so switching to it
                // on the amp panel is a usable tone rather than a surprise.
                "Gain": 4, "Treble": 6, "Bass": 5
            ],
            pedals: [
                RigPreset.Pedal("KRX damper comp", ["Sensitivity": 4, "Output": 6]),
                RigPreset.Pedal("BRIG Chorus", ["Rate": 3, "Depth": 3.5]),
                RigPreset.Pedal("BRIG Reverb", ["Decay": 3.5, "Tone": 6, "Mix": 2.5])
            ],
            note: "The volume sits at 4½ on purpose. This amp is loud and clean until "
                + "about 6 and then it isn't — the headroom IS the tone."
        ),

        // ---- 2. BLUES ----------------------------------------------------
        RigPreset(
            id: "blues",
            name: "BLUES",
            tagline: "Cleans up when you back off the guitar volume.",
            blurb: "A top-boost class-A combo pushed just far enough to be rude, with a "
                 + "low-gain overdrive in front of it. Play softly and it is nearly "
                 + "clean; dig in and it breaks up. That is the whole trick, and it is "
                 + "in the amp rather than the pedal.",
            symbol: "flame",
            amp: .combo("Vane HV28"),
            ampValues: [
                "CHANNEL": 0,                       // TOP BOOST
                "Gain": 7, "Treble": 6, "Bass": 5.5,
                // CUT RUNS BACKWARDS on this amp — turning it up removes top end —
                // so 4 is a bright setting, not a dull one.
                "Cut": 4, "Master": 6,
                "REVERB LEVEL": 2.5, "REVERB TONE": 5,
                "TREMOLO SPEED": 4, "TREMOLO DEPTH": 0,
                "Gain 2": 5
            ],
            pedals: [
                RigPreset.Pedal("KRX damper comp", ["Sensitivity": 5, "Output": 6]),
                RigPreset.Pedal("Marswell BLUES BLAZER", ["Gain": 4.5, "Tone": 6, "Volume": 6]),
                RigPreset.Pedal("BRIG Reverb", ["Decay": 3, "Tone": 5.5, "Mix": 2])
            ],
            note: "No noise gate here, and that is a choice: this much gain is quiet "
                + "enough to live with, and a gate would cut the tail off exactly the "
                + "notes this tone exists for."
        ),

        // ---- 3. CRUNCH ---------------------------------------------------
        RigPreset(
            id: "crunch",
            name: "CRUNCH",
            tagline: "A cranked clearpane at the edge of breakup.",
            blurb: "No master volume, so the only way this amp distorts is to turn it "
                 + "all the way up — which is what makes it sound the way it does. The "
                 + "ValveShrieker is set as a PUSH, not a distortion: barely any drive, "
                 + "level well past noon, so it hits the front end harder.",
            symbol: "bolt",
            amp: .stack(head: "Marswell Clearpane Stellar Lead 1042", cab: "Marswell 2415A 4x12"),
            ampValues: [
                "PATCH": 2,                          // JUMPERED, as everybody runs it
                "Presence": 6, "Bass": 5.5, "Mid": 6, "Treble": 7,
                "Gain": 7.5, "Volume": 6
            ],
            pedals: [
                RigPreset.Pedal("Iberon Valve Shrieker", ["Overdrive": 3, "Tone": 5.5, "Level": 7]),
                RigPreset.Pedal("BRIG Noise Silencer", ["Threshold": 3, "Decay": 4])
            ],
            note: "Drive down, level up. A green overdrive in front of an already-loud "
                + "amp is a volume pedal with a mid hump, and that is the job."
        ),

        // ---- 4. CLASSIC ROCK ---------------------------------------------
        RigPreset(
            id: "classic-rock",
            name: "CLASSIC ROCK",
            tagline: "The 4x12 sound. Mids up, gain past halfway.",
            blurb: "A master-volume Marswell through its own 4x12 — the rhythm tone most "
                 + "guitar records are made of. Mids are UP rather than scooped, which is "
                 + "what lets it be heard next to a snare, and a short delay sits behind "
                 + "it for size.",
            symbol: "amplifier",
            amp: .stack(head: "Marswell MSW900 2140", cab: "Marswell 2415A 4x12"),
            ampValues: [
                "Presence": 6, "Bass": 5, "Mid": 6.5, "Treble": 6.5,
                "Master": 6, "Gain": 7
            ],
            pedals: [
                RigPreset.Pedal("Iberon Valve Shrieker", ["Overdrive": 3.5, "Tone": 6, "Level": 6.5]),
                RigPreset.Pedal("BRIG Noise Silencer", ["Threshold": 3.5, "Decay": 4]),
                RigPreset.Pedal("BRIG Digital Delay", ["Time": 4.5, "Feedback": 3, "Mix": 2])
            ],
            note: "MID at 6½ is the setting people undo first and miss most. Scooping it "
                + "sounds enormous alone and vanishes the moment anything else plays."
        ),

        // ---- 5. LEAD -----------------------------------------------------
        RigPreset(
            id: "lead",
            name: "LEAD",
            tagline: "Singing sustain, a mid hump and a long delay.",
            blurb: "A dirty-channel British head with the mids pushed and a boost in "
                 + "front to keep single notes from thinning out. The delay is set long "
                 + "and low — you should feel it rather than hear repeats.",
            symbol: "waveform.path",
            amp: .stack(head: "Tangerine Rumblecrest 100", cab: "Tangerine TSV412"),
            ampValues: [
                "CHANNEL": 0,                        // DIRTY
                "Gain": 7.5, "Bass": 5, "Mid": 7, "Treble": 6,
                "Master": 6, "REVERB": 3
            ],
            pedals: [
                RigPreset.Pedal("Iberon Valve Shrieker", ["Overdrive": 2.5, "Tone": 6.5, "Level": 7.5]),
                RigPreset.Pedal("BRIG Noise Silencer", ["Threshold": 4, "Decay": 3.5]),
                RigPreset.Pedal("BRIG Digital Delay", ["Time": 5.5, "Feedback": 4, "Mix": 2.5])
            ],
            note: "Sustain comes from the mids and the boost, not from more gain. Turning "
                + "GAIN up from here makes it fuzzier and shorter, not longer."
        ),

        // ---- 6. DISTORTION -----------------------------------------------
        RigPreset(
            id: "distortion",
            name: "DISTORTION",
            tagline: "Modern high gain, straight out of the amp.",
            blurb: "A boutique high-gain head doing all of it on its own — no distortion "
                 + "pedal in the chain, because this amp does not need one and stacking "
                 + "a pedal on top only makes it woollier. Tight, saturated and even "
                 + "across the neck.",
            symbol: "bolt.fill",
            amp: .stack(head: "Fremont GX-140", cab: "Marswell 2415A 4x12"),
            ampValues: [
                "CHANNEL": 1,                        // BE
                "Presence": 6, "Bass": 5.5, "Mid": 5.5, "Treble": 6.5,
                "Master": 6, "Gain": 8
            ],
            pedals: [
                RigPreset.Pedal("BRIG Noise Silencer", ["Threshold": 4.5, "Decay": 3]),
                RigPreset.Pedal("BRIG Digital Delay", ["Time": 4, "Feedback": 2.5, "Mix": 1.5])
            ],
            note: "The gate is not optional at this gain. Take it off the board and the "
                + "rig roars the moment your hands leave the strings — which is what the "
                + "amp being modelled does too."
        ),

        // ---- 7. METAL ----------------------------------------------------
        RigPreset(
            id: "metal",
            name: "METAL",
            tagline: "Scooped, tight, and shut up between notes.",
            blurb: "A Reactor on channel two through an oversized cab, boosted by an "
                 + "overdrive with the drive almost off — the standard way to tighten a "
                 + "high-gain amp's low end without adding distortion. A graphic EQ "
                 + "carves the mids and a fast gate kills everything in the gaps.",
            symbol: "square.stack.3d.down.right",
            amp: .stack(head: "Mesquite Bootleg Dual Reactor", cab: "Mesquite Bootleg Oversized 4x12"),
            ampValues: [
                "CHANNEL": 1, "MODE": 1, "VOICE": 1,      // CH2 / PUSHED / MODERN
                "Gain 2": 8.5, "Bass 2": 7, "Mid 2": 2.5, "Treble 2": 7,
                "Presence 2": 6.5, "Master 2": 5.5,
                // Channel 1 left as a usable rhythm tone rather than at noon.
                "Gain": 6, "Bass": 6, "Mid": 4, "Treble": 6, "Presence": 6, "Master": 5
            ],
            pedals: [
                RigPreset.Pedal("Iberon Valve Shrieker",
                                ["Overdrive": 0.5, "Tone": 6.5, "Level": 8]),
                // The three bands the engine reads are 125, 500 and 4k (see
                // ParameterMap.pedalParams); the rest are set so the drawn
                // sliders are the V-shape the sound actually is.
                RigPreset.Pedal("KRX ten band eq",
                                ["31": 5, "62": 6, "125": 6.5, "250": 4, "500": 2.5,
                                 "1k": 3, "2k": 5, "4k": 6.5, "8k": 6, "16k": 5, "Volume": 5]),
                RigPreset.Pedal("BRIG Noise Silencer", ["Threshold": 5.5, "Decay": 2.5])
            ],
            note: "OVERDRIVE at ½ and LEVEL at 8. The boost is there to shave bass off "
                + "the amp's input, not to add gain — the amp has plenty."
        ),

        // ---- 8. FUZZ -----------------------------------------------------
        RigPreset(
            id: "fuzz",
            name: "FUZZ",
            tagline: "Torn, spitting and gloriously unstable.",
            blurb: "Two transistors and almost nothing else, into a cranked clearpane. Fuzz "
                 + "is not distortion with more of it — it squares the wave off and "
                 + "collapses, which is why it sputters as a note dies. A phaser sits "
                 + "behind it because that is where it has always sat.",
            symbol: "aqi.high",
            amp: .stack(head: "Marswell Clearpane Stellar Lead 1042", cab: "Marswell 2415A 4x12"),
            ampValues: [
                "PATCH": 2,
                "Presence": 5.5, "Bass": 6, "Mid": 5.5, "Treble": 6.5,
                "Gain": 8, "Volume": 7
            ],
            pedals: [
                RigPreset.Pedal("DALTON ARMATURE FUZZ DOME", ["Volume": 6.5, "Fuzz": 8.5]),
                // Set LOW and SLOW deliberately: the sputter as a fuzz note dies is
                // the sound, and a gate set the way the metal preset sets one would
                // remove exactly that.
                RigPreset.Pedal("BRIG Noise Silencer", ["Threshold": 3.5, "Decay": 5.5]),
                RigPreset.Pedal("KRX swirl 72", ["Speed": 3.5])
            ],
            note: "Roll your guitar's volume back and a fuzz cleans up further than any "
                + "overdrive will. Most of what people dislike about fuzz is it sitting "
                + "on 10."
        ),

        // ---- 9. AMBIENT --------------------------------------------------
        RigPreset(
            id: "ambient",
            name: "AMBIENT",
            tagline: "Clean, wide, and a long way away.",
            blurb: "A solid-state clean that refuses to distort, with chorus, a long "
                 + "delay and a hall reverb piled behind it. Built for held chords and "
                 + "single notes rather than riffs — everything here is about the "
                 + "space after the note.",
            symbol: "cloud",
            amp: .combo("Rondell RM-140 Velvet Chorus"),
            ampValues: [
                "CHANNEL": 1,                        // the channel with reverb and chorus
                "Gain 2": 5, "Treble 2": 6.5, "Mid 2": 4.5, "Bass 2": 5.5,
                "DISTORTION": 0, "REVERB": 4.5, "EFFECT": 2, "SPEED": 3, "DEPTH": 5,
                "Gain": 5, "Treble": 6, "Mid": 5, "Bass": 5
            ],
            pedals: [
                RigPreset.Pedal("BRIG Chorus", ["Rate": 2.5, "Depth": 5]),
                RigPreset.Pedal("BRIG Digital Delay", ["Time": 6.5, "Feedback": 5.5, "Mix": 4]),
                RigPreset.Pedal("electro-galvanic GOLDEN FLEECE", ["Reverb": 7])
            ],
            note: "This amp's own chorus is on the faceplate and not in the engine yet, "
                + "which is why there is a chorus pedal on the board doing that job."
        )
    ]
}

// MARK: - Loading one

extension RigStore {

    /// Put a preset on the stage: own everything it names, set every knob it
    /// names, and rebuild the rig around it.
    ///
    /// RESOLVE EVERYTHING FIRST, MUTATE NOTHING UNTIL IT ALL RESOLVES. A preset
    /// naming a model the catalog no longer offers is a bug in this app's own
    /// data, and the player should not pay for it with half a rig — half is
    /// worse than the one they already had, and much harder to explain. So a
    /// failed lookup returns `false` having changed nothing.
    ///
    /// IT ADDS, IT NEVER DELETES. Gear already on the board that the preset does
    /// not want comes OFF the board and stays in the collection; nothing is ever
    /// disowned. The player's rail after loading nine presets is every model
    /// those presets use, which is a fair way to end up owning gear.
    ///
    /// KNOBS ARE MERGED, NOT REPLACED. A control the preset does not mention
    /// keeps its value — its own panel default for a model being owned for the
    /// first time, and the player's setting for one they already had. That is
    /// the difference between "a preset sets these nine knobs" and "a preset
    /// resets your pedal", and the detail pane promises the former.
    ///
    /// AR FOOTSWITCHES ARE LEFT ALONE, the same way `removePedal` leaves them.
    /// A slot bound to a pedal that just came off the board is a state the app
    /// already reaches every time somebody drags a pedal off the stage; loading
    /// a preset is not the moment to start silently rewriting the player's AR
    /// page as well as their rig.
    @discardableResult
    public func apply(_ preset: RigPreset) -> Bool {
        // 1. Resolve. `wanted` keeps catalog order — amp, cab, then pedals.
        var wanted: [(entry: GearItem, values: [String: Double])] = []
        for name in preset.modelNames {
            guard let entry = RigStore.catalog.first(where: { $0.name == name }) else {
                assertionFailure("preset \"\(preset.id)\" names \"\(name)\", which the catalog does not offer")
                return false
            }
            let values: [String: Double]
            switch entry.category {
            case .amp, .comboAmp:  values = preset.ampValues
            case .cabinet:         values = [:]           // a cab has no controls
            default:               values = preset.pedals.first { $0.model == name }?.values ?? [:]
            }
            wanted.append((entry, values))
        }

        // 2. Own it and dial it in. `ownedInstance` matches by MODEL, so a preset
        //    reuses the copy already in the rail rather than adding a second one.
        var ids: [String: UUID] = [:]
        for (entry, values) in wanted {
            let id: UUID
            if let owned = ownedInstance(of: entry) {
                id = owned.id
            } else {
                let fresh = GearItem(catalogID: entry.catalogID, name: entry.name, category: entry.category)
                collection.append(fresh)
                id = fresh.id
            }
            if let index = collection.firstIndex(where: { $0.id == id }) {
                for (key, value) in values { collection[index].values[key] = value }
            }
            ids[entry.name] = id
        }

        // 3. Wire it up.
        switch preset.amp {
        case .stack(let head, let cab):
            guard let headId = ids[head], let cabId = ids[cab] else { return false }
            rig.ampSection = .stack(ampId: headId, cabinetId: cabId)
        case .combo(let combo):
            guard let comboId = ids[combo] else { return false }
            rig.ampSection = .combo(comboId: comboId)
        }

        // Chain order is the board's invariant everywhere else (`apply`,
        // `replacePedal`), so a preset holds to it too rather than trusting the
        // order they happen to be written in here.
        var board = preset.pedals.compactMap { ids[$0.model] }
        board.sort { order(of: $0) < order(of: $1) }
        rig.pedalIds = Array(board.prefix(RigStore.maxPedalsOnBoard))
        return true
    }

    /// `RigStore`'s own `chainOrder(of:)` is `private`, which in Swift means
    /// file-scoped — this extension lives in another file, so it needs its own.
    /// Same expression, and it has to stay that way.
    private func order(of id: UUID) -> Int { item(id)?.category.chainOrder ?? Int.max }
}

#if DEBUG
extension RigPresets {

    /// EVERYTHING IN THIS FILE THAT COULD BE A TYPO, CHECKED.
    ///
    /// Two failures live here and both are silent without this. A model name
    /// that has been renamed or withheld makes one preset refuse to load, which
    /// nobody notices until they tap LOAD on that one. A KNOB name that does not
    /// exist on the model's panel is worse: the preset loads, the value is
    /// written into `values` under a key no panel draws and no compiler reads,
    /// and the tone is quietly not the tone the recipe printed.
    ///
    /// Returns a human-readable list, empty when the data is sound. Cheap — a
    /// few hundred string compares — so it is called on the preset page's first
    /// appearance in DEBUG builds as well as from its `#Preview`.
    @MainActor
    public static func problems() -> [String] {
        var found: [String] = []
        let available = Dictionary(RigStore.catalog.map { ($0.name, $0) },
                                   uniquingKeysWith: { a, _ in a })

        for preset in all {
            for name in preset.modelNames where available[name] == nil {
                found.append("\(preset.id): \"\(name)\" is not in the catalog")
            }

            /// The knob names a model's panel actually persists.
            func keys(of name: String) -> Set<String>? {
                guard let entry = available[name] else { return nil }
                return Set(GearItem(catalogID: entry.catalogID, name: entry.name, category: entry.category)
                            .parameters.map(\.name))
            }

            if let ampKeys = keys(of: preset.ampName) {
                for key in preset.ampValues.keys.sorted() where !ampKeys.contains(key) {
                    found.append("\(preset.id): \(preset.ampName) has no knob \"\(key)\"")
                }
            }
            for pedal in preset.pedals {
                guard let pedalKeys = keys(of: pedal.model) else { continue }
                for key in pedal.values.keys.sorted() where !pedalKeys.contains(key) {
                    found.append("\(preset.id): \(pedal.model) has no knob \"\(key)\"")
                }
            }

            if preset.pedals.count > RigStore.maxPedalsOnBoard {
                found.append("\(preset.id): \(preset.pedals.count) pedals, board holds \(RigStore.maxPedalsOnBoard)")
            }
        }
        return found
    }
}
#endif
