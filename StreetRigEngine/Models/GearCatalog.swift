//
//  GearCatalog.swift
//  StreetRig
//
//  WHAT A PIECE OF GEAR *IS*, kept apart from what it is called.
//
//  Six seams used to resolve a model by its display name — the icon
//  (`GearIconLoader`), the faceplate PNG and its knob sidecar (`PanelArtLoader`),
//  the DSP amp profile and cab IR (`ParameterMap`), the per-model knob set
//  (`PedalSpec`) and the enclosure colour (`PedalFinish`). Every one of them
//  degrades SILENTLY: a name the table does not recognise resolves to procedural
//  art, a working-but-wrong amp voicing, or a different control set, and neither
//  the compiler nor the console says a word. Twice now that has forced a
//  `RigStore.catalogVersion` bump — the only tool available for "the names moved,
//  throw the save away".
//
//  This file retires that. Every catalog model carries a `catalogID`, assigned
//  once in `RigStore.allModels` and frozen forever; the seams key off THAT. The
//  display name becomes ordinary text.
//
//  THE ONE RULE: an id is never edited, never re-derived, never reused. It was
//  seeded from the v5 names because the artwork on disk was already filed under
//  those slugs, and that is the last time the two have anything to do with each
//  other. Renaming a model means editing its `name` string and nothing else.
//
//  BACK-COMPAT LIVES HERE, not in the matchers. A rig can arrive from a DAW
//  session or a `.srpreset` written before ids existed, carrying a v2/v3/v4
//  display name and no id at all. `retiredNames` maps every one of those onto the
//  id it became, so the session keeps its exact voicing — WITHOUT the retired
//  names surviving as live substring tokens in the shipped matchers, which is the
//  whole reason they were replaced rather than appended to.
//

import Foundation

public enum GearCatalog {

    /// The stable identity of a piece, or `nil` when it has none.
    ///
    /// `nil` is a real answer, not a failure: gear the player named themselves has
    /// no catalog entry and never will, and every seam has a documented fallback
    /// for it (procedural art, the generic per-category knobs, `ampLegacy`).
    public static func id(for item: GearItem) -> String? {
        if let id = item.catalogID, !id.isEmpty { return id }
        return retiredID(forName: item.name)
    }

    /// The id a retired display name resolves to, or `nil` if it names nothing
    /// this build has ever shipped.
    public static func retiredID(forName name: String) -> String? {
        if let id = idByCurrentName[name.lowercased()] { return id }
        return idByRetiredName[fingerprint(name)]
    }

    /// FNV-1a (64-bit) over the lowercased name's UTF-8 bytes.
    ///
    /// Hand-rolled rather than `Hasher`, which is seeded randomly per process:
    /// its values differ between launches, so a table keyed by them would resolve
    /// nothing after the first relaunch. FNV-1a is fixed by its constants, so a
    /// fingerprint computed today matches one computed by any future build.
    static func fingerprint(_ name: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.lowercased().utf8 {
            h ^= UInt64(byte)
            h &*= 0x0000_0100_0000_01b3
        }
        return h
    }

    /// The name the catalog ships for an id, or nil if the id names nothing.
    ///
    /// Exists so a matcher that keys off the display name can resolve a RETIRED
    /// name to the name it became and match that instead. Without it the matcher
    /// would have to list the retired names as literals, which is exactly what
    /// `idByRetiredName` is fingerprinted to avoid.
    public static func currentName(forID id: String) -> String? { nameByID[id] }

    static let nameByID: [String: String] = {
        var out: [String: String] = [:]
        for m in RigStore.allModels {
            if let id = m.catalogID { out[id] = m.name }
        }
        return out
    }()

    /// Every id the catalog ships, for the integrity checks in `CatalogCheck`.
    public static var allIDs: [String] { RigStore.allModels.compactMap(\.catalogID) }

    /// Current display name → id. Built from the catalog rather than written out,
    /// because it is derived data: it exists so a rig saved by THIS build, whose
    /// items already carry ids, is not the only thing that resolves.
    static let idByCurrentName: [String: String] = {
        var out: [String: String] = [:]
        for m in RigStore.allModels {
            if let id = m.catalogID { out[m.name.lowercased()] = id }
        }
        return out
    }()

    /// EVERY display name this app has ever shipped that no longer exists, mapped
    /// to the id its model became. Append-only: a row here is a promise to a save
    /// file somewhere, so rows are added when a name is retired and never removed.
    ///
    /// KEYED BY FINGERPRINT, NOT BY NAME, and that is the whole point. Most of these
    /// 79 retired names ARE the third-party marks this catalog exists to stop
    /// shipping — the pre-v3 rows name real makers outright. Writing them as string
    /// literals to match against would put every one of them straight back into the
    /// binary, which is precisely what retiring them was meant to prevent; a table of
    /// opaque integers resolves the same saved sessions and carries no mark at all.
    ///
    /// Append-only: a row here is a promise to a save file somewhere, so rows are
    /// added when a name is retired and never removed.
    ///
    /// TO ADD A ROW: compute `fingerprint("Old Display Name")` and paste the hex.
    /// The plaintext name → id mapping is recorded in `research/gear-naming-audit.md`,
    /// which is repo-only and never bundled, so the human-readable side is not lost.
    static let idByRetiredName: [UInt64: String] = {
        let table: [UInt64: String] = [
        0x45cd169685165057: "marswell-msw900-2140",
        0xebc26f999f0a9c05: "marswell-clearpane-stellar-lead-1042",
        0x5b0a67049af971c2: "fremont-gx-140",
        0xe3199f10b323cfc3: "mesquite-bootleg-dual-reactor",
        0xfb66c5a54b57fc5e: "tangerine-rumblecrest-100",
        0x5ec532e6ed2354fa: "marswell-2415a-4x12",
        0x153e560a2bb7957e: "mesquite-bootleg-oversized-4x12",
        0xf0a8e7aebe17d22c: "tangerine-tsv412",
        0xcfcd21321ca23c79: "fandor-tandem-reverb",
        0x7a85b05d81cd21d1: "vane-hv28",
        0x76a84f57e70d0c74: "marswell-vcx45c",
        0x392cb6cb6da7a6c8: "rondell-rm-140-velvet-chorus",
        0x3a882fec87ea0025: "brig-kabuto-100",
        0x1922ade49185e906: "brig-chromatic-tuner",
        0xb7eb9c3ea7968073: "dunridge-weeping-willow",
        0x41aa759d47a68931: "vane-v921",
        0xfba60f4612bed4a6: "mordant-wild-pony",
        0xca27105b9a971c81: "krx-damper-comp",
        0x27b028d125772034: "brig-compression-leveller",
        0x756f47a2befb6686: "keswick-compressor",
        0x7c4d9670197fc48f: "brig-distortion",
        0xde1bd7bc097b10c8: "iberon-valve-shrieker",
        0x56712f4513c700b7: "proforge-shrew",
        0x807dc5108585fbfb: "brig-metal-realm",
        0x17ef55d59768347e: "chiron-satyr",
        0x85cf8f44836e82cf: "analogue-smith-duke-of-drive",
        0x6fd5883a1a9f019d: "marswell-blues-blazer",
        0xd40d817ae4b9942b: "fullbrook-fixation",
        0xe41632dccdb79881: "electro-galvanic-big-mitt",
        0x4730eeae031b7c6b: "dalton-armature-fuzz-dome",
        0x059a3a00d22c7f21: "z-flux-fuzz-foundry",
        0x9ae67823ed906466: "exalt-preamp-booster",
        0x2c249fbe2cbf8698: "strider-beryllium",
        0x6e01b52afde37af8: "brig-equalizer",
        0x9ec7f54298a9cf74: "krx-ten-band-eq",
        0x7ce5d7b42dd455da: "emblem-parametric-eq",
        0xbaebe0d9e3e9c0f0: "brig-noise-silencer",
        0xc96978adb1cc3958: "quell-nullifier-ii",
        0x0e45b6768cdb0a44: "fornax-kraal",
        0xbd180941d3987f92: "brig-chorus",
        0xfd59de997b676bac: "krx-swirl-72",
        0x06b523724426a169: "krx-flanger",
        0xe13e327d9d85e254: "brig-tremolo",
        0xf8194651701ba344: "electro-galvanic-small-mime",
        0xbaf546a467148a0c: "electro-galvanic-small-slate",
        0xa02b42d5e25406c1: "electro-galvanic-electric-siren",
        0xbfea3ffff8d2baca: "fullbrook-lucid-vibe",
        0xa8b6ad2669d989c0: "brig-octave",
        0xf9bb5b968823d041: "brig-chorister",
        0x854677492e5cd138: "electro-galvanic-micro-stack",
        0x977d68ee48e5df69: "digivault-slingshot",
        0x483328bb651dd24f: "brig-digital-delay",
        0x79c71589b57e7153: "dunridge-echoreel",
        0x3f7db602696820b5: "electro-galvanic-reverie-mate",
        0x13f5249278cb6294: "brig-reverb",
        0xff132a4db6b9f761: "electro-galvanic-golden-fleece",
        0xf552f3816652743e: "brig-lv-320h",
        0x38985647f0c77f85: "errol-brass-swell-mini",
        0x16624bd823f3f616: "brig-loop-depot",
        0xdc578c867f803835: "electro-galvanic-frost",
        0x874d65a38552f069: "marswell-clearpane-stellar-lead-1042",
        0x4bcb39c0b34b174f: "mesquite-bootleg-dual-reactor",
        0x96171c354a2180cd: "fandor-bassdude-59",
        0x198ffed34b75dc73: "rondell-rm-140-velvet-chorus",
        0x473b3b67fd5a5634: "tangerine-rumblecrest-100",
        0xcdb3a9ac9ffefa89: "brig-kabuto-100",
        0x8a91198f34fbc38b: "marswell-msw900-2140",
        0x1d53dd30cab30a40: "marswell-msw900-2140",
        0x2f41080c32e3b9f3: "marswell-2415a-4x12",
        0x77a8f6528c97f3bb: "fandor-tandem-reverb",
        0xedfe0e96dbff708d: "vane-hv28",
        0xd8b6d572a578bfa5: "marswell-vcx45c",
        0x16cc18fb743d4516: "rondell-rm-140-velvet-chorus",
        0xdf47b98e3f2351c8: "fandor-bassdude-59",
        0xd91e2af522c0698e: "fremont-gx-140",
        0x8bb1085ba1265419: "tangerine-rumblecrest-100",
        0xa2f6097b55f4c5ad: "brig-kabuto-100",
        0xf978fbf506cec286: "mesquite-bootleg-oversized-4x12",
        0xb6ba92b9f11e278d: "tangerine-tsv412",
        ]
        return table
    }()
}
