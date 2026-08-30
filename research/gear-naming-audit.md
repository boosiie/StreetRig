# Gear naming audit — trademark exposure across the 61-model catalog

**Status: proposal for human review. No source file was changed by this audit.**
**Not legal advice.** Everything below is a risk assessment written by reading the
catalog against publicly known product names. A human — ideally counsel — should sign
off before submission. Prompt 010 applies whatever survives that review, literally.

Source of truth read for this audit:
- `StreetRigEngine/Models/RigStore.swift` — `allModels` (lines 716–795), `withheldModels`
  (lines 686–705), `seed()` (lines 626–655), `catalogVersion` doc comment (lines 558–578)
- `StreetRig/Views/GearIconLoader.swift` — `slug(_:)` (lines 51–56)
- `StreetRigEngine/Audio/ParameterMap.swift` — `ampProfile(name:values:)` (601–625),
  `cabSlot(name:)` (630–636), `pedalVoicing(name:category:)` (277–319)
- `StreetRigEngine/Models/Gear.swift` — `PedalSpec.parameters(forName:category:)` (290–700)
- `StreetRig/Views/Faceplate.swift`, `GearArt.swift`, `PedalArchetypes3D.swift`,
  `PedalFinish.swift`, `PanelArtLoader.swift`, `GearModelLoader.swift`

Row count reconciliation: `grep -c 'mk(' StreetRigEngine/Models/RigStore.swift` → **36**,
but that counts *lines*, and `allModels` puts two `mk(...)` calls on most lines. The
occurrence count is the one that reconciles: `grep -o 'mk(' … | wc -l` → **62**, which is
the 61 catalog entries plus the one `func mk(...)` declaration on line 717. The table
below has **61 rows, numbered 1–61 with no gaps** (verified). `ls -d
StreetRig/Assets.xcassets/*.imageset | wc -l` → **61**, and every current slug computed
below matches an existing imageset directory exactly (verified programmatically — no
misses, no extras).

Every proposed name was also checked by Levenshtein distance against the specific mark it
replaces, fragment by fragment (72 pairs): **minimum distance 3**, so no proposal is
within two characters of its mark. Three first drafts failed that check — `1055` vs
`1959`, `1450A` vs `1960A`, `TSC412` vs `PPC412`, all at distance 2 — and were moved to
`1042`, `2415A` and `TSV412` before this table was written.

---

## 1. Summary

### How the verdicts were assigned

The prompt's three buckets overlap at the edges, so they were applied this way, and the
rule is stated here so a reviewer can disagree with the rule rather than with 60 rows:

- **INFRINGING** — reproduces a registered mark verbatim, or differs from it only by
  letters that read as a *misspelling or homophone* rather than as a different word
  (`Dunlap`, `Morlee`, `Boogey`, `Ractifier`, `Ketana`, `Plaxi`, `Ibonez`, `Fullstone`,
  `Empriss`, `Fortis`, `DigiTek`, `harmonium`, `strymo`, `Keenly`, `ITP`, `MXP`, `VOSS`).
- **RISKY** — a coinage that *is* a different word, but either still invites confusion
  or collides with a different real audio company's mark.
- **CLEAR** — generic/descriptive, or a coinage at Marswell distance (a real, unrelated
  morpheme substituted in, not a letter swapped out).

Note this test is not raw edit distance. `Marswell` is two characters from `Marshall`
and is the benchmark, because `-well` is a real English word, not a typo of `-shall`.
`Dunlap` is one character from `Dunlop` and fails, because `-lap` there reads as a
misspelling. That distinction is the whole standard.

### Counts

**By catalog row (61 rows):**

| Verdict | Rows |
|---|---|
| CLEAR (no change proposed) | **1** |
| RISKY | **0** |
| INFRINGING | **60** |

**60 of 61 names change.** The single row that does not is `Fandor Bassdude '59`.

The row verdict is the worse of its two halves, which is why RISKY is empty: every row
that has a risky half also has an infringing half. The per-half breakdown is where the
three buckets actually separate, and it is the more useful number:

**By brand (27 distinct brands in the catalog):**

| Verdict | Count | Brands |
|---|---|---|
| CLEAR | 6 | `Marswell`, `Fandor`, `Tangerine`, `Chiron` |
| RISKY | 1 | `Volt` / `VOLT` |
| INFRINGING | 20 | `Mesa Boogey`, `VOSS`, `DUNLAP`, `MORLEE`, `MXP`, `Keenly`, `Ibonez`, `ProCon`, `analogue.man`, `Fullstone`, `electro-harmonium`, `DALLAS ARBITOR`, `Z.HEX`, `Exotiq`, `strymo`, `EMPRISS`, `ITP`, `FORTIS`, `DigiTek`, `ERNIE BELL` |

**21 of 27 brands change.** `Chiron` is CLEAR and survives untouched, so two rows
(`Chiron CENTAUR`, `Marswell BLUES BREAKER`) change only their model half.

**By model half (61 halves):**

| Verdict | Count |
|---|---|
| CLEAR — generic/descriptive, kept verbatim | 20 |
| INFRINGING — verbatim mark or one-letter obfuscation | 41 |

The 20 model halves kept as-is: `Chromatic Tuner`, `Compressor`, `Distortion`,
`Equalizer`, `ten band eq`, `Noise Suppressor`, `Chorus`, `flanger`, `Tremolo`,
`Octave`, `Digital Delay`, `Reverb`, `Oversized 4x12`, `4x12` (×2), `100` (×2),
`Bassdude '59`, plus the `booster` and `Parametric` tails of two renamed models.

### The headline finding

The v3/v4 passes re-badged the brands but left model designations verbatim, so the
catalog still ships **41 registered model marks in plain text** — `JCM800`, `2203`,
`Super Lead`, `1959`, `1960A`, `BE-100`, `AC30`, `DSL40C`, `JC-120`, `PPC412`,
`Twin Reverb`, `Tube Screamer`, `RAT`, `CENTAUR`, `KING of TONE`, `BLUES BREAKER`,
`OCD`, `BIG MUFF π`, `FUZZ FACE`, `FUZZ FACTORY`, `CRY BABY`, `BAD HORSIE`,
`dyna comp`, `phase 90`, `WHAMMY`, `ECHOPLEX`, `MEMORY MAN`, `HOLY GRAIL`,
`SMALL CLONE`, `small stone`, `electric mistress`, `micro POG`, `FREEZE`,
`Deja'Vibe`, `DECIMATOR II`, `ZUUL`, `EP booster`, `IRIDIUM`, `V847`, `FV-500H`,
`VP JR`, `Loop Station`, `Compression Sustainer`, `Harmonist`, `Metal Zone`, `ParaEq`.

**And the artwork is a second, independent copy of every one of them** — see §5. That
is the more serious exposure and it is *not* fixed by this rename.

---

## 2. Rename table

`Current slug` / `New slug` are computed by applying `GearIconLoader.slug()` literally:
lowercase, replace every maximal `[^a-z0-9]+` run with a single `-`, trim leading and
trailing `-`. Every current slug in this column was verified to match an existing
`StreetRig/Assets.xcassets/<slug>.imageset` directory.

`Voicing token` is the substring that selects the model's DSP profile or cab slot today
(`ParameterMap.ampProfile` / `ParameterMap.cabSlot`). `—` for pedals, per spec; the
pedal-side matcher tokens are listed separately in §3.3, because pedals are matched the
same way and would break just as silently.

### Amp heads

| # | Category | Current name | Verdict | Proposed name | Current slug | New slug | Voicing token | Rationale |
|---|---|---|---|---|---|---|---|---|
| 1 | amp | Marswell JCM800 2203 | INFRINGING | Marswell MSW900 2140 | `marswell-jcm800-2203` | `marswell-msw900-2140` | `jcm800`, `2203` → `ampJCM800` (ParameterMap:610) | `JCM800` and `2203` are both Marshall model designations, shipped verbatim. Letters *and* digits both move, per the alphanumeric rule; `MSW` reads as the house brand's own initials the way `JCM` read as Jim Marshall's. Brand half CLEAR. |
| 2 | amp | Marswell Plaxi Super Lead 1959 | INFRINGING | Marswell Clearpane Stellar Lead 1042 | `marswell-plaxi-super-lead-1959` | `marswell-clearpane-stellar-lead-1042` | `plaxi` (also `plexi`, `super lead`) → `ampPlexi1959` (:615) | `Super Lead` and `1959` are Marshall marks; `Plaxi` is one vowel from `Plexi`. `Clearpane` names the same thing (the plexiglass front panel) with two real English words; `Stellar Lead` keeps SU-per LEAD's 2+1 rhythm and S onset with a different word; `1042` is not a Marshall code. |
| 3 | amp | Freedman BE-100 | INFRINGING | Fremont GX-140 | `freedman-be-100` | `fremont-gx-140` | `be-100` / `be100` → `ampBE100` (:616) | `BE-100` is Friedman's model designation. Both letters and both digits shift. Brand INFRINGING: `Freedman` is one vowel from `Friedman`. `Fremont` is a real, unrelated place name keeping the 2-syllable `Fre-` onset. (Resolved OQ1.) |
| 4 | amp | Mesa Boogey Dual Ractifier | INFRINGING | Mesquite Bootleg Dual Reactor | `mesa-boogey-dual-ractifier` | `mesquite-bootleg-dual-reactor` | `ractifier` (also `rectifier`, `recto`) → `ampDualRect` (:617) | `Mesa` is verbatim, `Boogey` is one letter from `Boogie`, `Ractifier` is one vowel from Mesa's registered `Rectifier`. `Mesquite`/`Bootleg` are real, unrelated English words keeping the two-word 2+2 shape and both onsets; `Reactor` is a different real word with the same Re- onset and the same "device that converts" idea. |
| 5 | amp | Tangerine Rockervert 100 | INFRINGING | Tangerine Rumblecrest 100 | `tangerine-rockervert-100` | `tangerine-rumblecrest-100` | `rockerver` → `ampRockerverb` (:618) | `Rockervert` is one letter from Orange's `Rockerverb`, and `Rocker` alone is also an Orange model line — so the whole stem has to move, not just the tail. `Rumblecrest` keeps the 3-syllable R-onset shape from real words. `100` is wattage, descriptive, kept. Brand CLEAR. |

### Cabinets

| # | Category | Current name | Verdict | Proposed name | Current slug | New slug | Voicing token | Rationale |
|---|---|---|---|---|---|---|---|---|
| 6 | cabinet | Marswell 1960A 4x12 | INFRINGING | Marswell 2415A 4x12 | `marswell-1960a-4x12` | `marswell-2415a-4x12` | none → `cabSlot` default slot 0 (:630–636) | `1960A` is Marshall's cab designation, verbatim. Digits move; the `A` suffix (angled) and `4x12` are descriptive and stay. Brand CLEAR. |
| 7 | cabinet | Mesa Boogey Oversized 4x12 | INFRINGING | Mesquite Bootleg Oversized 4x12 | `mesa-boogey-oversized-4x12` | `mesquite-bootleg-oversized-4x12` | none → `cabSlot` default slot 0 | Brand half only (see row 4). `Oversized 4x12` is descriptive and needs no change. |
| 8 | cabinet | Tangerine PPC412 | INFRINGING | Tangerine TSV412 | `tangerine-ppc412` | `tangerine-tsv412` | none → `cabSlot` default slot 0 | `PPC412` is Orange's registered cab designation. All three letters shift; `412` describes the speaker array and stays. Brand CLEAR. |

### Combo amps

| # | Category | Current name | Verdict | Proposed name | Current slug | New slug | Voicing token | Rationale |
|---|---|---|---|---|---|---|---|---|
| 9 | comboAmp | Fandor Twin Reverb | INFRINGING | Fandor Tandem Reverb | `fandor-twin-reverb` | `fandor-tandem-reverb` | `twin` → `ampTwinReverb` (:619); cab: none → `ampProfileCabSlot(ampTwinReverb)` = slot 1 | `Twin Reverb` is Fender's registered mark. `Tandem` is a real, unrelated English word carrying the same "two of them" idea; `Reverb` is the effect and is descriptive. Brand CLEAR. |
| 10 | comboAmp | Volt AC30 | INFRINGING | Vane HV28 | `volt-ac30` | `vane-hv28` | `ac30` → `ampAC30` (:620) **and** `ac30` in `cabSlot` (:632) → slot 1 | `AC30` is Vox's registered model. Brand `Volt` is separately RISKY: it is two characters from `VOX` *and* is in current use by real audio companies (Universal Audio Volt interfaces, Volt Loudspeakers), which the standard forbids outright. `Vane` is a real unrelated word keeping the 1-syllable V- onset. **Two matchers to edit, not one** — see §3.2. |
| 11 | comboAmp | Marswell DSL40C | INFRINGING | Marswell VCX45C | `marswell-dsl40c` | `marswell-vcx45c` | `dsl` → `ampDSL40C` (:614); cab: none → `ampProfileCabSlot` default = slot 1 | `DSL40C` is Marshall's model designation. All three letters and the leading digit move; the `C` (combo) suffix is descriptive. Brand CLEAR. |
| 12 | comboAmp | Rolund JC-120 Jazzy Chorus | INFRINGING | Rondell RM-140 Velvet Chorus | `rolund-jc-120-jazzy-chorus` | `rondell-rm-140-velvet-chorus` | `jc-120` → `ampJC120` (:621–622); cab: none → `ampProfileCabSlot(ampJC120)` = slot 1 | `JC-120` is Roland's model designation and `Jazz Chorus` its mark; `Jazzy` is one letter off. `Velvet` is a real unrelated word describing the amp's actual clean; `Chorus` is the effect and stays. Brand INFRINGING: `Rolund` is one vowel from `Roland`. `Rondell` substitutes a real unrelated morpheme behind the shared `Ro-` onset. (Resolved OQ1.) Note the `jazz chorus` token already matches nothing today (`Jazzy Chorus` ≠ `jazz chorus`); only `jc-120` is live. |
| 13 | comboAmp | Fandor Bassdude '59 | **CLEAR** | *(no change)* | `fandor-bassdude-59` | `fandor-bassdude-59` | `bassdude` → `ampBassman59` (:623) | `Bass` is descriptive; `-dude` is a real, unrelated English word substituted for `-man`, which is exactly the Marswell pattern. `'59` is a year. Nothing to move. |
| 14 | comboAmp | VOSS Ketana 100 | INFRINGING | BRIG Kabuto 100 | `voss-ketana-100` | `brig-kabuto-100` | `ketana` (also `katana`) → `ampKatanaBase` family (:603–609) | `Ketana` is one vowel from Boss's `Katana`; `VOSS` is one letter from `BOSS`. `Kabuto` (a samurai helmet) keeps the 3-syllable Ka- shape and the same Japanese martial register from a genuinely different word. `100` is wattage. **This token drives the whole 10-slot profile family plus the Character/Variation panel — see §3.2.** |

### Pedals — tuner, wah, compressor

| # | Category | Current name | Verdict | Proposed name | Current slug | New slug | Voicing token | Rationale |
|---|---|---|---|---|---|---|---|---|
| 15 | tuner | VOSS Chromatic Tuner | INFRINGING | BRIG Chromatic Tuner | `voss-chromatic-tuner` | `brig-chromatic-tuner` | — | Brand only: `VOSS` is one letter from `BOSS`, the exact failure mode the standard names. `BRIG` is a real unrelated English word at the same 1-syllable B- onset. `Chromatic Tuner` is descriptive. *(withheld model)* |
| 16 | wah | DUNLAP CRY BABY | INFRINGING | DUNRIDGE WEEPING WILLOW | `dunlap-cry-baby` | `dunridge-weeping-willow` | — | `CRY BABY` is Dunlop's registered mark; `DUNLAP` is one letter from `Dunlop`. `DUNRIDGE` swaps a real morpheme in behind the shared `Dun-`. `WEEPING WILLOW` is a real phrase carrying the same crying idea from entirely different words. *(Chosen over the tighter-scanning "WEEP WILLOW", which would contain the `ep ` matcher token — see §3.4.)* |
| 17 | wah | VOLT V847 | INFRINGING | VANE V921 | `volt-v847` | `vane-v921` | — | `V847` is Vox's registered wah designation. All three digits move; the `V` is the house brand's own initial. Brand: see row 10. |
| 18 | wah | MORLEE BAD HORSIE | INFRINGING | MORDANT WILD PONY | `morlee-bad-horsie` | `mordant-wild-pony` | — | `BAD HORSIE` is Morley's registered mark; `MORLEE` is a homophone of `Morley`. `MORDANT` (biting) is a real word at the same 2-syllable Mor- onset. `WILD PONY` keeps BAD HOR-sie's 1+2 rhythm and the same idea from different words. |
| 19 | compressor | MXP dyna comp | INFRINGING | KRX damper comp | `mxp-dyna-comp` | `krx-damper-comp` | — | `dyna comp` is MXR's registered mark; `MXP` is one letter from `MXR`. `KRX` is a fresh 3-letter initialism differing in all three positions. `damper` is a real English word for the thing a compressor does, at `dyna`'s 2-syllable d- onset; `comp` is descriptive shorthand. |
| 20 | compressor | VOSS Compression Sustainer | INFRINGING | BRIG Compression Leveller | `voss-compression-sustainer` | `brig-compression-leveller` | — | `Compression Sustainer` is Boss's CS-3 product designation, shipped verbatim. `Compression` is descriptive and stays; `Leveller` is a real word for the same function. **See Open Question 3** — this one is arguably descriptive enough to leave alone. |
| 21 | compressor | Keenly Compressor | INFRINGING | Keswick Compressor | `keenly-compressor` | `keswick-compressor` | — | Brand only: `Keenly` is one inserted letter from `Keeley` and a near-homophone. `Keswick` is a real English place name at the same 2-syllable Ke- onset. `Compressor` is generic. *(withheld model)* |

### Pedals — overdrive / distortion / fuzz / boost

| # | Category | Current name | Verdict | Proposed name | Current slug | New slug | Voicing token | Rationale |
|---|---|---|---|---|---|---|---|---|
| 22 | overdrive | VOSS Distortion | INFRINGING | BRIG Distortion | `voss-distortion` | `brig-distortion` | — | Brand only (row 15). `Distortion` is generic and keeps its `distortion` voicing token intact. |
| 23 | overdrive | Ibonez Tube Screamer | INFRINGING | Iberon Valve Shrieker | `ibonez-tube-screamer` | `iberon-valve-shrieker` | — | `Tube Screamer` is Ibanez's registered mark; `Ibonez` is one vowel from `Ibanez`. `Iberon` keeps the `Ib-` onset and 3-syllable shape with a genuinely different tail. `Valve Shrieker` is the same 1+2 rhythm and the same idea — a valve that screams — built from two different real words. |
| 24 | overdrive | ProCon RAT | INFRINGING | ProForge SHREW | `procon-rat` | `proforge-shrew` | — | `RAT` is Pro Co's registered mark; `ProCon` is one inserted letter from `Pro Co` (and is itself a real non-audio company). `ProForge` keeps the CamelCase `Pro-` compound with a real unrelated morpheme. `SHREW` is a different 1-syllable animal with the same aggressive small-rodent register. |
| 25 | overdrive | VOSS Metal Zone | INFRINGING | BRIG Metal Realm | `voss-metal-zone` | `brig-metal-realm` | — | `Metal Zone` is Boss's registered mark. `Metal` is a descriptive genre word and stays (it is also the live voicing token); `Realm` is a real unrelated word meaning the same as `Zone`, at the same 1-syllable length. |
| 26 | overdrive | Chiron CENTAUR | INFRINGING | Chiron SATYR | `chiron-centaur` | `chiron-satyr` | — | `CENTAUR` is Klon's registered mark, verbatim. **Brand `Chiron` is CLEAR** — nothing like `Klon` — so only the model half moves. `SATYR` is a different mythological hybrid at the same 2-syllable length, keeping the evocation without the mark. **The art on this icon also prints `KTR`, a second Klon mark — see §5.** |
| 27 | overdrive | analogue.man KING of TONE | INFRINGING | analogue.smith DUKE of DRIVE | `analogue-man-king-of-tone` | `analogue-smith-duke-of-drive` | — | `KING of TONE` is Analog Man's registered mark, and `analogue.man` reproduces `Analog Man` with only a spelling variant. `analogue` is descriptive of analog circuitry and stays; `smith` is a real unrelated noun. `DUKE of DRIVE` holds the 1+1+1 "X of Y" rhythm and the regal idea from different words. **See Open Question 4.** |
| 28 | overdrive | Marswell BLUES BREAKER | INFRINGING | Marswell BLUES BLAZER | `marswell-blues-breaker` | `marswell-blues-blazer` | — | `BLUES BREAKER` is Marshall's `Bluesbreaker` with a space inserted — trivial obfuscation. Brand CLEAR, so only the model moves. `BLUES` is a descriptive genre word (and the live voicing token, preserved); `BLAZER` is a real unrelated word at the same 2-syllable B- onset. |
| 29 | overdrive | Fullstone OCD | INFRINGING | Fullbrook FIXATION | `fullstone-ocd` | `fullbrook-fixation` | — | `OCD` is Fulltone's registered mark; `Fullstone` is one letter from `Fulltone`. `Fullbrook` swaps a real morpheme in behind the shared `Full-`. `FIXATION` is a real 3-syllable word (matching `OCD` spoken as three) carrying the same obsession idea — the outright re-coining an initialism calls for. *(withheld model)* |
| 30 | overdrive | electro-harmonium BIG MUFF π | INFRINGING | electro-galvanic BIG MITT Ω | `electro-harmonium-big-muff` | `electro-galvanic-big-mitt` | — | `BIG MUFF π` is EHX's registered mark; `electro-harmonium` is `Electro-Harmonix` with `ix`→`ium`. `electro-galvanic` is a **6-syllable, identically-stressed** match (har-MON-ix → gal-VAN-ic) built from a real electrical word. `MITT` is a different real word for the same woolly hand-covering idea; the Greek letter shifts to `Ω`. Note the slug drops the Greek letter in both cases. |
| 31 | overdrive | DALLAS ARBITOR FUZZ FACE | INFRINGING | DALTON ARMATURE FUZZ DOME | `dallas-arbitor-fuzz-face` | `dalton-armature-fuzz-dome` | — | `FUZZ FACE` is a registered mark; `DALLAS` is verbatim and `ARBITOR` one vowel from `Arbiter`. `DALTON ARMATURE` keeps the 2+3 two-word shape and both onsets from real words (`armature` is an electrical term, in period). `FUZZ` is the effect and stays (live voicing token); `DOME` describes the same round enclosure. |
| 32 | overdrive | Z.HEX FUZZ FACTORY | INFRINGING | Z.FLUX FUZZ FOUNDRY | `z-hex-fuzz-factory` | `z-flux-fuzz-foundry` | — | `FUZZ FACTORY` is Z.Vex's registered mark; `Z.HEX` is one letter from `Z.Vex`. `FLUX` is a real electrical word at the same 1-syllable length behind the kept `Z.` shape. `FOUNDRY` keeps the alliteration and the "place where things are made" idea; it drops one syllable from `FAC-to-ry`, the one place this table trades rhythm for a stronger word. |
| 33 | overdrive | Exotiq EP booster | INFRINGING | Exalt PREAMP booster | `exotiq-ep-booster` | `exalt-preamp-booster` | — | `EP booster` is Xotic's registered mark; `Exotiq` is a homophone of `Xotic`. `Exalt` is a real word at the same Ex- onset. `EP` had to become a *word*, not another two-letter code: any 2-letter code is by definition within two characters of `EP`. `PREAMP` is purely descriptive, holds the 2-syllable slot, and — usefully — still matches the existing `booster` token, so no matcher edit is needed here. |
| 34 | overdrive | strymo IRIDIUM | INFRINGING | strider BERYLLIUM | `strymo-iridium` | `strider-beryllium` | — | `IRIDIUM` is Strymon's registered mark; `strymo` is `Strymon` minus one letter. `strider` is a real word at the same lowercase 2-syllable Str- onset. `BERYLLIUM` is a different element with the same 4-syllable `-ium` shape. Neither name matches any overdrive token, before or after — both fall to the same default voicing, so nothing to edit. *(withheld model)* |

### Pedals — EQ, noise gate

| # | Category | Current name | Verdict | Proposed name | Current slug | New slug | Voicing token | Rationale |
|---|---|---|---|---|---|---|---|---|
| 35 | eq | VOSS Equalizer | INFRINGING | BRIG Equalizer | `voss-equalizer` | `brig-equalizer` | — | Brand only (row 15). `Equalizer` is generic and keeps its `equalizer` token. *(withheld model)* |
| 36 | eq | MXP ten band eq | INFRINGING | KRX ten band eq | `mxp-ten-band-eq` | `krx-ten-band-eq` | — | Brand only (row 19). `ten band eq` is purely descriptive and keeps its `ten` token. |
| 37 | eq | EMPRISS ParaEq | INFRINGING | EMBLEM Parametric EQ | `empriss-paraeq` | `emblem-parametric-eq` | — | `EMPRISS` is one vowel from `Empress`, a homophone. `EMBLEM` is a real word at the same 2-syllable Em- onset. `ParaEq` is Empress's product name; spelling it out as `Parametric EQ` makes it plainly descriptive and — deliberately — still matches the existing `para` token. *(withheld model)* |
| 38 | noiseGate | VOSS Noise Suppressor | INFRINGING | BRIG Noise Silencer | `voss-noise-suppressor` | `brig-noise-silencer` | — | `Noise Suppressor` is Boss's NS-2 product designation, structurally identical to `Compression Sustainer` (row 20), so it gets the same treatment. `Noise` is descriptive and stays; `Silencer` is a real unrelated word for the same function. (Resolved OQ3 — change both, not one.) |
| 39 | noiseGate | ITP DECIMATOR II | INFRINGING | QUELL NULLIFIER II | `itp-decimator-ii` | `quell-nullifier-ii` | — | `DECIMATOR` is ISP's registered mark; `ITP` is one letter from `ISP`. `QUELL` re-coins the initialism outright as a real word naming the function. `NULLIFIER` is a real word with the same agent-noun shape and the same reduce-to-nothing idea; the `II` revision marker is generic. *(withheld model)* |
| 40 | noiseGate | FORTIS ZUUL | INFRINGING | FORNAX KRAAL | `fortis-zuul` | `fornax-kraal` | — | `ZUUL` is Fortin's registered mark; `FORTIS` is one letter from `Fortin`. `FORNAX` keeps only the `For-` onset with a genuinely different word. `KRAAL` is a real word (an enclosure) — an apt, coined-feeling 1-syllable name for a gate, with the same doubled-vowel look as `ZUUL`. *(withheld model)* |

### Pedals — modulation

| # | Category | Current name | Verdict | Proposed name | Current slug | New slug | Voicing token | Rationale |
|---|---|---|---|---|---|---|---|---|
| 41 | modulation | VOSS Chorus | INFRINGING | BRIG Chorus | `voss-chorus` | `brig-chorus` | — | Brand only (row 15). `Chorus` is the effect name; generic. |
| 42 | modulation | MXP phase 90 | INFRINGING | KRX swirl 72 | `mxp-phase-90` | `krx-swirl-72` | — | `phase 90` is MXR's registered mark, and MXR also owns `Phase 45/95/100` — so any `phase NN` still reads as theirs and the *word* has to move too. `swirl` is a real 1-syllable word describing what a phaser does; the number shifts as well. |
| 43 | modulation | MXP flanger | INFRINGING | KRX flanger | `mxp-flanger` | `krx-flanger` | — | Brand only (row 19). `flanger` is the effect name; generic, and keeps its `flang` token. |
| 44 | modulation | VOSS Tremolo | INFRINGING | BRIG Tremolo | `voss-tremolo` | `brig-tremolo` | — | Brand only (row 15). `Tremolo` is generic; keeps its `trem` token. |
| 45 | modulation | electro-harmonium SMALL CLONE | INFRINGING | electro-galvanic SMALL MIME | `electro-harmonium-small-clone` | `electro-galvanic-small-mime` | — | `SMALL CLONE` is EHX's registered mark. `SMALL` describes the enclosure and stays; `MIME` is a different real 1-syllable word with the same imitation idea. Brand as row 30. |
| 46 | modulation | electro-harmonium small stone | INFRINGING | electro-galvanic small slate | `electro-harmonium-small-stone` | `electro-galvanic-small-slate` | — | `small stone` is EHX's registered mark. `slate` is a different real 1-syllable rock, same rhythm, lowercase style preserved. Brand as row 30. |
| 47 | modulation | electro-harmonium electric mistress | INFRINGING | electro-galvanic electric siren | `electro-harmonium-electric-mistress` | `electro-galvanic-electric-siren` | — | `electric mistress` is EHX's registered mark. `electric` is descriptive and stays; `siren` is a real 2-syllable word holding both halves of the original's idea — the alluring female figure *and* a sweeping sound, which is what a flanger is. Brand as row 30. |
| 48 | modulation | Fullstone Deja'Vibe | INFRINGING | Fullbrook Lucid'Vibe | `fullstone-deja-vibe` | `fullbrook-lucid-vibe` | — | `Deja Vibe` is Fulltone's registered mark. `Vibe` is now the generic category word for the effect and stays (it is also the live voicing token); `Lucid` is a real word in the same dream register at the same 2-syllable length, and the apostrophe styling is preserved. Brand as row 29. |

### Pedals — pitch, delay, reverb, volume, looper

| # | Category | Current name | Verdict | Proposed name | Current slug | New slug | Voicing token | Rationale |
|---|---|---|---|---|---|---|---|---|
| 49 | pitch | VOSS Octave | INFRINGING | BRIG Octave | `voss-octave` | `brig-octave` | — | Brand only (row 15). `Octave` is generic; keeps its `octave` token. *(withheld model)* |
| 50 | pitch | VOSS Harmonist | INFRINGING | BRIG Chorister | `voss-harmonist` | `brig-chorister` | — | `Harmonist` is Boss's PS-6 product designation, verbatim. `Harmonizer` was not available as a replacement — it is Eventide's registered mark — and `Harmonics` would sit two letters away. `Chorister` is a real 3-syllable word in the same harmony register, and (checked) does **not** contain the `chorus` substring. *(withheld model)* |
| 51 | pitch | electro-harmonium micro POG | INFRINGING | electro-galvanic micro STACK | `electro-harmonium-micro-pog` | `electro-galvanic-micro-stack` | — | `micro POG` is EHX's registered mark. `micro` is descriptive and stays; `STACK` re-coins the acronym as a real word naming what stacked octaves do. Brand as row 30. *(withheld model)* |
| 52 | pitch | DigiTek WHAMMY | INFRINGING | DigiVault SLINGSHOT | `digitek-whammy` | `digivault-slingshot` | — | `WHAMMY` is DigiTech's registered mark; `DigiTek` is a homophone of `DigiTech` (and a real non-audio company). `DigiVault` keeps the CamelCase `Digi-` compound with a real unrelated morpheme. `SLINGSHOT` is a real 2-syllable word for launching pitch up and down. |
| 53 | delay | VOSS Digital Delay | INFRINGING | BRIG Digital Delay | `voss-digital-delay` | `brig-digital-delay` | — | Brand only (row 15). `Digital Delay` is generic; falls to the same `delayDigital` default before and after. |
| 54 | delay | DUNLAP ECHOPLEX | INFRINGING | DUNRIDGE ECHOREEL | `dunlap-echoplex` | `dunridge-echoreel` | — | `ECHOPLEX` is Dunlop's registered mark. `ECHO` is descriptive and stays; `REEL` is a real word naming the tape mechanism the pedal models, keeping the 3-syllable shape. Brand as row 16. |
| 55 | delay | electro-harmonium MEMORY MAN | INFRINGING | electro-galvanic REVERIE MATE | `electro-harmonium-memory-man` | `electro-galvanic-reverie-mate` | — | `MEMORY MAN` is EHX's registered mark. Both halves move — keeping `MAN` behind a changed first word would leave half the mark intact. `REVERIE MATE` holds the 3+1 rhythm with two real, unrelated words in the same remembering register. Brand as row 30. |
| 56 | reverb | VOSS Reverb | INFRINGING | BRIG Reverb | `voss-reverb` | `brig-reverb` | — | Brand only (row 15). `Reverb` is generic; falls to the same `reverbPlate` default before and after. |
| 57 | reverb | electro-harmonium HOLY GRAIL | INFRINGING | electro-galvanic GOLDEN FLEECE | `electro-harmonium-holy-grail` | `electro-galvanic-golden-fleece` | — | `HOLY GRAIL` is EHX's registered mark. `GOLDEN FLEECE` is a different legendary object at exactly the same 2+1 rhythm, from two real unrelated words. Brand as row 30. |
| 58 | volume | VOSS FV-500H | INFRINGING | BRIG LV-320H | `voss-fv-500h` | `brig-lv-320h` | — | `FV-500H` is Boss's registered model designation. The letter and two of the digits move; the `H` (high-impedance) suffix is descriptive. Brand as row 15. |
| 59 | volume | ERNIE BELL VP JR | INFRINGING | ERROL BRASS SWELL MINI | `ernie-bell-vp-jr` | `errol-brass-swell-mini` | — | `VP JR` is Ernie Ball's product designation; `ERNIE` is verbatim and `BELL` one letter from `Ball`. `ERROL BRASS` keeps the personal-name shape and the `Er-` onset from real words. Both halves of `VP JR` move: `SWELL` names what a volume pedal is for, `MINI` its size — both purely descriptive. |
| 60 | looper | VOSS Loop Station | INFRINGING | BRIG Loop Depot | `voss-loop-station` | `brig-loop-depot` | — | `Loop Station` is Boss's registered mark. `Loop` is descriptive and stays; `Depot` is a real unrelated word meaning the same as `Station`, at the same 2-syllable length. Brand as row 15. *(withheld model)* |
| 61 | looper | electro-harmonium FREEZE | INFRINGING | electro-galvanic FROST | `electro-harmonium-freeze` | `electro-galvanic-frost` | — | `FREEZE` is EHX's registered mark. `FROST` is a different real 1-syllable word at the same `Fr-` onset with the same idea. Brand as row 30. *(withheld model)* |

**Withheld models covered:** all 18 entries in `RigStore.withheldModels` appear above
(rows 15, 21, 26, 27, 29, 33, 34, 35, 37, 39, 40, 46, 48, 49, 50, 51, 60, 61). They are
reachable in saved state and in code, so they are renamed with the rest.

---

## 3. Collision check

### 3.1 Slug uniqueness

All 61 proposed names were slugged with the literal `slug()` rule and sorted: **61
distinct slugs, no duplicates.** The 61 current slugs were likewise verified to be
distinct and to match the 61 `.imageset` directories on disk one-for-one — no missing
directory, no orphan.

Three slugs hand-checked by applying the regex literally, including punctuation cases:

| Name | Lowercased | `[^a-z0-9]+` runs replaced | Trimmed |
|---|---|---|---|
| `Fullbrook Lucid'Vibe` | `fullbrook lucid'vibe` | space→`-`, `'`→`-` | `fullbrook-lucid-vibe` |
| `electro-galvanic BIG MITT Ω` | `electro-galvanic big mitt ω` | `-`→`-`, spaces→`-`, trailing `" ω"` is **one** run→`-` | `electro-galvanic-big-mitt` (trailing `-` trimmed) |
| `analogue.smith DUKE of DRIVE` | `analogue.smith duke of drive` | `.`→`-`, spaces→`-` | `analogue-smith-duke-of-drive` |

Confirming the rule against a current name: `Fandor Bassdude '59` → `fandor bassdude '59`
→ the `" '"` pair is a single non-alnum run → `fandor-bassdude-59`, which is exactly the
directory that exists.

**Near-misses resolved:** none required. Two proposals share a leading word
(`electro-galvanic SMALL MIME` / `electro-galvanic small slate`) but slug distinctly.
Twelve proposals share the `BRIG` brand and eight share `electro-galvanic`; all differ in
their model half.

### 3.2 Matcher-token collisions — amps and cabs

Every proposed name was checked against the full amp/cab matcher token list
(`jcm800`, `2203`, `dsl`, `plexi`/`plaxi`, `super lead`, `be-100`/`be100`,
`rectifier`/`ractifier`/`recto`, `rockerver`, `twin`, `ac30`, `jc-120`/`jc120`,
`jazz chorus`, `bassman`/`bassdude`, `katana`/`ketana`, `1x12`, `deluxe`, `ac15`).

**Exactly one hit, and it is intentional:** `Fandor Bassdude '59` still contains
`bassdude`, because that row does not change. **No proposed name introduces a stray
amp or cab matcher token.** In particular no new pedal name contains `recto`, `twin`,
`dsl`, `plexi` or `1x12`, and `Mesquite Bootleg Dual Reactor` was checked
character-by-character: `reactor` contains `acto`, not `recto`.

### 3.3 The exact `ParameterMap` token edits this rename implies

**`ampProfile(name:values:)` — ParameterMap.swift:601–625**

| Line | Current token(s) | Replace with | Consequence if missed |
|---|---|---|---|
| 603 | `katana`, `ketana` | `kabuto` (keep `katana`/`ketana` if back-compat with saved rigs matters) | The whole 10-id Katana profile family collapses to `ampLegacy`; Character/Variation stop changing the topology signature |
| 610 | `jcm800`, `2203` | `msw900`, `2140` | JCM800 head → `ampLegacy` |
| 614 | `dsl` | `vcx` | DSL40C combo → `ampLegacy` **and** it loses its priority-over-Plexi position; keep the new token in the same slot |
| 615 | `plexi`, `plaxi`, `super lead` | `clearpane`, `stellar lead` | Super Lead head → `ampLegacy` |
| 616 | `be-100`, `be100` | `gx-140`, `gx140` | BE-100 head → `ampLegacy` |
| 617 | `rectifier`, `ractifier`, `recto` | `reactor` | Rectifier head → `ampLegacy` |
| 618 | `rockerver` | `rumblecrest` | Rockerverb head → `ampLegacy` |
| 619 | `twin` | `tandem` | Twin combo → `ampLegacy` |
| 620 | `ac30` | `hv28` | AC30 combo → `ampLegacy` |
| 621–622 | `jc-120`, `jc120`, `jazz chorus` | `rm-140`, `rm140`, `velvet chorus` | JC-120 combo → `ampLegacy`. Note `jazz chorus` matches nothing today |
| 623 | `bassman`, `bassdude` | *(unchanged)* | — |

**`cabSlot(name:)` — ParameterMap.swift:630–636**

| Line | Current token | Replace with | Consequence if missed |
|---|---|---|---|
| 632 | `ac30` | `hv28` | **The seeded starter combo silently changes IR.** `RigStore.seed()` comments at line 630–633 say this combo is picked *specifically* because its name routes to the brighter 1x12 IR. Miss this and it drops to slot 0 |
| 632 | `1x12`, `deluxe`, `ac15` | *(dead tokens — no current catalog name matches them)* | — |

`ampProfileCabSlot(_:)` (:646–654) is keyed on profile ids, not names, so it needs no edit —
but it is what keeps the Twin, DSL40C, JC-120 and Katana on their intended IRs, and it
only fires if `ampProfile` still resolves. That is the real reason the table above matters.

**`pedalVoicing(name:category:)` — ParameterMap.swift:277–319.** The prompt scopes the
`Voicing token` column to amps, but pedals are matched by the same substring mechanism
and break the same way, so the pedal edits are listed here rather than left for 010 to
rediscover:

| Line | Current token(s) | Replace with | Notes |
|---|---|---|---|
| 282 | `screamer`, `tube screamer` | `shrieker` | keep `ts808`/`ts9` |
| 283 | `centaur`, `klon` | `satyr`, `chiron` | |
| 284 | `king` | `duke` | |
| 285 | `ocd` | `fixation` | |
| 286 | `blues` | *(unchanged)* | BLUES BLAZER still matches |
| 287 | `metal`, `zone` | keep `metal`, drop `zone` | |
| 288 | `rat` | `shrew` | `rat` is a 3-letter substring hazard; retiring it is a small win |
| 289 | `distortion` | *(unchanged)* | |
| 290 | `muff` | `mitt` | |
| 291 | `factory` | `foundry` | **must stay ABOVE line 292**, or `FUZZ FOUNDRY` falls into `fuzz` |
| 292 | `fuzz`, `face` | keep `fuzz`, drop `face` | |
| 293 | `boost`, `booster`, `ep ` | keep `boost`/`booster`, **drop `ep `** | `PREAMP booster` already matches `booster`; dropping `ep ` also clears the incidental hit described in §3.4 |
| 298 | `flang`, `mistress` | keep `flang`, `mistress`→`siren` | must stay above line 299 |
| 299 | `phase`, `stone` | `swirl`, `slate` | |
| 305 | `echoplex`, `ep-3`, `ep3`, `tape` | `echoreel` (keep `tape`) | |
| 307 | `memory`, `bbd`, `analog`, `analogue` | `reverie` (keep the rest) | |
| 311 | `holy`, `grail`, `spring` | `fleece` (keep `spring`) | |

### 3.4 Category-gated substring overlaps (no action needed, listed so 010 does not panic)

These proposals contain a token that belongs to a *different* category's matcher.
`pedalVoicing` and `PedalSpec.parameters` both switch on `GearCategory` **before** doing
any substring test, so none of these can fire. They are recorded because a future
refactor that flattens the switch would turn every one of them into a live bug.

| Proposed name | Category | Contains | Token belongs to | Pre-existing? |
|---|---|---|---|---|
| `Marswell Clearpane Stellar Lead 1042` | amp | `10` | `.eq` ten-band | new (but `100` already appears in two amp names today) |
| `Tangerine Rumblecrest 100` | amp | `10` | `.eq` | yes, unchanged |
| `BRIG Kabuto 100` | comboAmp | `10` | `.eq` | yes, unchanged |
| `Rondell RM-140 Velvet Chorus` | comboAmp | `chorus` | `.modulation` | yes (`Jazzy Chorus`) |
| `analogue.smith DUKE of DRIVE` | overdrive | `analog`, `analogue` | `.delay` BBD | yes (`analogue.man`) |

One proposal was **changed** rather than gated: `DUNRIDGE WEEP WILLOW` would contain
`ep ` (from "we**ep w**illow"). Even though it is a `.wah` and the token is `.overdrive`,
it was rewritten to `DUNRIDGE WEEPING WILLOW`, which contains no matcher token at all.

### 3.5 Non-`ParameterMap` matchers that also key off these names

Four more seams substring-match or exact-match on `GearItem.name`. The prompt's blast
radius did not list them; they are load-bearing and each one silently degrades rather
than failing to compile.

**`StreetRigEngine/Models/Gear.swift` → `PedalSpec.parameters(forName:category:)`
(lines 290–700)** — this decides *which knobs a piece has*, per model. Tokens to edit:
`dyna`→`damper` (312), `sustainer`→`leveller` (313), `keeley`/`keenly`→`keswick` (314),
`para` *(unchanged — `Parametric` still matches)* (318), `decimator`→`nullifier` (322),
`zuul`→`kraal` (323), `phase 90`/`phase90`→`swirl 72`/`swirl72` (326), `stone`→`slate`
(327), `mistress`→`siren` (328), `clone`→`mime` (332), `pog`→`stack` (336),
`harmonist`/`ps-6`→`chorister` (338), `whammy`→`slingshot` (339), `echoplex`/`ep-3`/
`ep103`→`echoreel` (342), `memory`→`reverie` (343), `holy`/`grail`→`fleece` (346),
`muff`→`mitt` (298), `klon`/`centaur`→`chiron`/`satyr` (299), `rat`→`shrew` (300),
`metal`/`zone`→`metal` (301), `ocd`→`fixation` (303), `king`→`duke` (304),
`factory`→`foundry` (306), `screamer`/`tube`→`shrieker`/`valve` (308), plus the amp
tokens at 395, 421, 445, 461, 484, 494, 506, 548, 605, 635, 648, 697 mirroring §3.3.
**A missed token here does not fall back gracefully — the model gets the wrong knob set,
and `RigPreset` sets knobs by name, so presets start writing keys the panel never shows.**

**`StreetRig/Views/Faceplate.swift` (lines 65–130)** — the amp's plate colour and chassis
trim. Tokens: `jcm800` (68), `plexi`/`plaxi`/`super lead` (72), `dsl40c` (77),
`be-100`/`freedman` (85), `rectifier`/`ractifier`/`mesa` (93), `katana`/`ketana` (98),
`rockerver`/`tangerine` (104), `twin reverb` (110), `jc-120`/`jazz chorus` (115),
`ac30`/`volt` (120), `bassman`/`bassdude` (126). **Note the brand fallbacks**: `freedman`
and `tangerine` survive the rename, but `mesa` and `volt` do not — those two need
`mesquite` and `vane`.

**`StreetRig/Views/PedalFinish.swift` (lines 30–92)** — a `byModel` dictionary keyed on
the **exact lowercased catalog name**. All 47 pedal keys change. A missed key is a silent
fallback to a category default colour.

**`StreetRig/Views/GearArt.swift` (lines 77–85)** and **`PedalArchetypes3D.swift`
(lines 130–170)** — procedural fallback art and 3D enclosure shape. Tokens:
`tube screamer`→`valve shrieker`, `big muff`→`big mitt`, `dyna`→`damper`,
`phase`→`swirl` (and the printed `"90"` label → `"72"`); `cry baby`→ *(droppable — the
`.wah` category check already covers it)*, `fuzz face`→`fuzz dome`, `voss`→`brig`,
`ibonez`→`iberon`, `electro-harmonium`→`electro-galvanic`, `mxp`→`krx`,
`dunlap`→`dunridge`, `metal zone`→`metal realm`.

**`StreetRigEngine/Models/KatanaChannels.swift`** — `KatanaChannelStore` persists
`ampName` **into a JSON file on disk** and `load(channel:ampName:)` refuses to recall a
channel whose stored name does not match (line 63). Renaming `VOSS Ketana 100` orphans
every saved channel memory. That is arguably correct (the `catalogVersion` bump discards
the rig anyway), but it is a separate persistence store that the version bump does *not*
clear, so 010 should either migrate or explicitly delete those files.

---

## 4. Blast radius

Hit counts are real `grep` output from the worktree root, not estimates.

**A. Files containing a full catalog name** (`grep -rIn -F -f <61 names>`, hits per file):

| File | Hits | What they are |
|---|---|---|
| `StreetRigEngine/Models/RigStore.swift` | 66 | `allModels` (716–795), `withheldModels` (686–705), `seed()` (626–655), `catalogVersion` doc comment (558–578) |
| `StreetRigEngine/Models/RigPreset.swift` | 34 | 9 factory presets referencing models as strings — `.combo(...)`, `.stack(head:cab:)`, `RigPreset.Pedal(...)` at lines 196, 208–210, 226, 238–240, 257, 264–265, 281, 287–289, 304, 311–313, 329, 336–337, 354, 363, 368, 371, 387, 394, 398–399, 416, 424–426 |
| `StreetRig/Audio/AudioEngineController+OfflineRender.swift` | 32 | the offline verification harness names models literally (1243, 1284–1300, 1428, 1506–1540, 1786, 2255–2457, 2811, 2862) |
| `research/amp-emulation-approaches.md` | 22 | catalog documentation |
| `research/amp-profile-implementation-notes.md` | 12 | catalog documentation |
| `CUSTOMIZING-GEAR.md` | 9 | designer-facing docs |
| `StreetRig/Views/PedalArchetypes3D.swift` | 8 | 3D enclosure archetype matcher |
| `StreetRig/Views/ARFloorPedalboard.swift` | 8 | doc comments / example names |
| `StreetRig/Views/GearArt.swift` | 7 | procedural art matcher |
| `StreetRig/GearIcons-README.md` | 7 | the slug-rule worked examples |
| `StreetRigEngine/Audio/AmpProfile.cpp` | 6 | C++ profile comments naming the amps |
| `StreetRig/Views/PedalModel3DView.swift` | 6 | doc comments |
| `research/adding-an-amp.md` | 5 | catalog documentation |
| `StreetRig/Views/RigStage3DView.swift` | 5 | doc comments |
| `StreetRig/Views/GearIconLoader.swift` | 5 | the `slug()` doc-comment examples (lines 51–56) and the `"ProCon RAT" -> "procon-rat"` example at line 30 |
| `StreetRigEngine/Audio/Pedals/ReverbPedal.hpp` | 4 | comments |
| `StreetRigEngine/Audio/Pedals/DelayPedal.hpp` | 3 | comments |
| `StreetRigEngine/Audio/ParameterMap.swift` | 3 | comments (the *tokens* are counted separately below) |
| `StreetRig/Views/GearCardView.swift` | 3 | doc comments |
| `research/pedal-emulation-approaches.md` | 2 | catalog documentation |
| `StreetRigEngine/Audio/Pedals/ReverbPedal.cpp` | 2 | comments |
| `StreetRigEngine/Audio/Pedals/DelayPedal.cpp` | 2 | comments |
| `StreetRig/Views/PedalFinish.swift` | 2 | *(full-name grep undercounts — the dictionary keys are lowercased; see B)* |
| `StreetRig/Views/Onboarding/FAQView.swift` | 2 | player-facing copy naming gear |
| `StreetRig/Views/AmpModel3DView.swift` | 2 | doc comments |
| `StreetRig/PanelArt/README.md` | 2 | designer docs |
| `research/strat-model-evaluation.md` | 1 | documentation |
| `StreetRigEngine/Audio/AmpProfile.hpp` | 1 | comment |
| `StreetRig/GearModels/README.md` | 1 | designer docs |

**`StreetRig/Audio/AudioEngineController+VerifyAUv3.swift`: 0 hits.** The prompt expected
this file to name models literally; it does not. Only `+OfflineRender.swift` does.

**B. Files containing a catalog *brand*** (catches the lowercased `PedalFinish` keys and
the `Faceplate`/`PedalArchetypes3D` brand tokens that A misses):

| File | Hits |
|---|---|
| `StreetRigEngine/Models/RigStore.swift` | 68 |
| `StreetRig/Audio/AudioEngineController+OfflineRender.swift` | 60 |
| `research/amp-emulation-approaches.md` | 39 |
| `StreetRigEngine/Models/RigPreset.swift` | 34 |
| `research/amp-profile-implementation-notes.md` | 18 |
| `StreetRigEngine/Audio/AmpProfile.cpp` | 13 |
| `CUSTOMIZING-GEAR.md` | 12 |
| `StreetRig/Views/PedalFinish.swift` | 11 |
| `StreetRig/Views/GearArt.swift` | 9 |
| `StreetRig/Views/PedalArchetypes3D.swift` | 9 |
| `StreetRig/GearIcons-README.md` | 8 |
| `StreetRig/Views/ARFloorPedalboard.swift` | 8 |
| `research/adding-an-amp.md` | 7 |
| `StreetRig/Views/PedalModel3DView.swift` | 6 |
| `StreetRig/Views/GearIconLoader.swift` | 6 |
| `StreetRig/PanelArt/README.md` | 6 |
| `StreetRig/Views/Faceplate.swift` | 5 |
| `StreetRig/Views/RigStage3DView.swift` | 5 |
| `research/pedal-tone-reference.md` | 5 |
| `StreetRigEngine/Audio/ParameterMap.swift` | 4 |
| `StreetRigEngine/Audio/Pedals/ReverbPedal.hpp` | 4 |
| `StreetRigEngine/Audio/Pedals/DelayPedal.hpp` | 3 |
| `StreetRig/Views/GearCardView.swift` | 3 |
| `StreetRigEngine/Audio/StreetRigDSPUnit.swift` | 2 |
| `StreetRigEngine/Audio/Pedals/ReverbPedal.cpp` | 2 |
| `StreetRigEngine/Audio/Pedals/DelayPedal.cpp` | 2 |
| `StreetRig/Views/AmpModel3DView.swift` | 2 |
| `StreetRig/Views/Onboarding/FAQView.swift` | 2 |
| `research/strat-model-evaluation.md` | 2 |
| `research/pedal-emulation-approaches.md` | 2 |
| `StreetRig/Views/PanelArtLoader.swift` | 1 |
| `StreetRig/Views/LibraryView.swift` | 1 |
| `StreetRigEngine/Audio/AmpProfile.hpp` | 1 |
| `StreetRig/GearModels/README.md` | 1 |

**C. On-disk assets keyed by slug** — three separate name-keyed asset seams, not one:

| Location | Count | Rename needed |
|---|---|---|
| `StreetRig/Assets.xcassets/<slug>.imageset/` | **61 directories** | rename the directory **and** the PNG inside it (each holds `Contents.json` + one PNG named after the slug — 122 files total) |
| `StreetRig/PanelArt/<slug>-panel.png` | **55 files** | 6 catalog entries have no plate: `marswell-1960a-4x12`, `mesa-boogey-oversized-4x12`, `tangerine-ppc412`, `voss-chromatic-tuner`, `voss-loop-station`, `electro-harmonium-freeze` |
| `StreetRig/PanelArt/<slug>-panel.json` | **11 files** | the knob-layout sidecars: all 5 amp heads' + 6 combos' plates (`marswell-jcm800-2203`, `marswell-plaxi-super-lead-1959`, `freedman-be-100`, `mesa-boogey-dual-ractifier`, `tangerine-rockervert-100`, `fandor-twin-reverb`, `volt-ac30`, `marswell-dsl40c`, `rolund-jc-120-jazzy-chorus`, `fandor-bassdude-59`, `voss-ketana-100`) |
| `StreetRig/GearModels/*.usdz` | 0 per-piece | only `category-guitar.usdz` exists; `GearModelLoader` resolves `<slug>.usdz` but no catalog piece ships one today |

Because the imagesets, plates and layout sidecars are three independent slug consumers,
a rename that updates the asset catalog and forgets `PanelArt/` leaves every amp panel
falling back to `ProceduralPlate` and every plate's knob layout reverting to automatic
rows — a visible regression with no error.

**D. Persistence.** `RigStore.catalogVersion` (line 578) must go **4 → 5** in the same
commit: the icon, plate and profile seams all key off the name, so a saved rig left on
old names resolves no asset and shows procedural art forever (the comment at 570–575
says exactly this). Separately, `KatanaChannelStore`'s JSON channel files are **not**
covered by that version bump — see §3.5.

---

## 5. Artwork notes

**This is the most serious finding in the audit, and the rename does not fix it.**

`GearIconLoader` resolves one PNG per piece and `ProceduralAmp` textures the 3D amp's
front face from that same image, so re-slugging carries both 2D and 3D. But the art
itself is untouched by a rename — and **the art prints the marks.** Four icons were
opened and read directly:

| Asset | What the art actually paints |
|---|---|
| `electro-harmonium-big-muff.png` | the brand `electro-harmonium` across the top **and `BIG MUFF π` in the Big Muff's own serif**, on the grey enclosure |
| `procon-rat.png` | `ProCon` at the top and **`RAT` inside the boxed rectangle lettering that is the RAT's signature**, plus the boxed `DISTORTION / FILTER / VOLUME` header strip |
| `chiron-centaur.png` | `Chiron` and `CENTAUR` — **and `KTR` beneath it, which is a Klon product mark that appears nowhere in the catalog name.** A rename of the catalog string would not touch it |
| `marswell-jcm800-2203.png` | **`JCM 800` and `LEAD SERIES`** on a gold control panel under a white script logo in Marshall's cursive style — the model marks *and* the trade dress |
| `StreetRig/PanelArt/marswell-jcm800-2203-panel.png` | the same `JCM 800 / LEAD SERIES` lettering again on the gold plate — the faceplate art is an **independent second copy** of every mark |

The pattern is consistent across all four samples: every icon prints the brand and the
model name as artwork. It is safe to assume **all 61 imagesets and all 55 panel plates
carry lettering that must be re-drawn**, and a re-lettering pass is therefore a hard
prerequisite for shipping, not a follow-up.

Signature colorways are additionally encoded in code, in
`StreetRig/Views/PedalFinish.swift` — a `byModel` table of RGB triples that deliberately
reproduces each pedal's recognisable colour: Tube Screamer green `(0.33, 0.80, 0.33)`,
Phase 90 orange `(1.00, 0.53, 0.07)`, Dyna Comp red, Big Muff grey `(0.87, 0.80, 0.80)`,
Metal Zone charcoal-blue, Klon/Centaur red. `GearArt.swift` (lines 77–85) prints short
wordmark badges procedurally too: `"TS"`, `"π"`, `"DYNA"`, `"90"`, and dead entries for
`"CC"`, `"DITTO"`, `"TU-3"`, `"CE-2"`, `"RV-6"` — five badges naming products the catalog
no longer even ships.

**For the follow-up (do not edit art in this prompt):**
1. Re-letter all 61 icon PNGs and 55 panel plates to the approved names.
2. `chiron-centaur.png` — remove `KTR`, a mark the catalog name never mentions.
3. `marswell-jcm800-2203.png` — the gold-panel-under-white-script combination is
   Marshall trade dress independent of any wording; consider re-colouring, not just
   re-lettering.
4. `GearArt.swift:81–85` — delete the `carbon copy` / `ditto` / `tu-3` / `ce-2` / `rv-6`
   badge rows. They name real products and match nothing in the catalog.
5. Review the `PedalFinish` colorway table: a re-badged pedal that keeps the exact
   signature colour is still trading on the original's look.

---

## 6. Open questions

> ### RESOLVED 2026-08-28 (human decision) — these override the discussion below
>
> - **OQ1 — Rolund and Freedman are NOT clear; change them.** The audit's objection was
>   accepted: both are one vowel from the real mark, the same failure condemned in
>   `Ibonez` and `Dunlap`. Row 3 → `Fremont GX-140`, row 12 → `Rondell RM-140 Velvet
>   Chorus`. `Marswell`, `Fandor`, `Tangerine` and `Chiron` remain genuinely CLEAR.
> - **OQ3 — change BOTH Boss product designations, not one.** `Compression Sustainer`
>   (CS-3) and `Noise Suppressor` (NS-2) are structurally identical, so they get the same
>   answer. Row 20 → `Compression Leveller`, row 38 → `Noise Silencer`. The earlier
>   keep-as-is instruction for `Noise Suppressor` was wrong and is withdrawn.
> - **OQ8 — REPLACE the old `ampProfile` tokens; do not append.** Preserve back-compat for
>   saved AUv3 host sessions through the stable-ID mapping instead of live substring
>   matches, so `jcm800`, `plexi` and `rectifier` do not remain as literal strings in the
>   shipped binary.
> - **Artwork is a prerequisite, not a follow-up.** §5's finding stands: the icons and
>   panel plates paint the marks independently of any filename. Re-lettering is scoped to
>   its own prompt (011) that must land before submission.
>
> Still open and needing a human with market knowledge: **OQ2** (Mesquite stress pattern),
> **OQ4** (`analogue.smith` retains `analogue`), **OQ5** (availability check on `Dual
> Reactor` / `Kabuto` / `Velvet`), **OQ6** (the eight alphanumeric model codes), **OQ7**
> (`.usdz` pre-population). None blocks prompt 010.


1. **`Rolund` and `Freedman` are marked CLEAR only because the prompt says so, and I
   disagree.** `Rolund` is one vowel from `Roland` (a→u) and `Freedman` is one vowel
   from `Friedman` (i→e). Both are precisely the "reads as a misspelling, not a
   different word" failure this audit condemns in `Dunlap`, `Ibonez` and `Fullstone`.
   They were listed in the task as reference points for "already fine", so they are
   left alone — but if a human agrees with me, add them and their models cost nothing
   extra since both rows are already changing. Suggested if so: `Rolund` → `Roamer` or
   `Rondell`; `Freedman` → `Freeling` or `Fremont`. `Marswell`, `Fandor` and
   `Tangerine` I agree are genuinely fine.

2. **`Mesquite Bootleg` shifts the stress pattern.** `MEsa BOOgie` is trochee+trochee;
   `mesQUITE BOOTleg` puts the first stress on the second syllable. It is the one
   proposal in the table that trades rhythm for distance. `Medley Bootleg` or
   `Mercer Bootleg` scan closer if a reviewer prefers rhythm.

3. **`Compression Sustainer` may not need to change at all.** It is a Boss product
   designation shipped verbatim, which is why it is marked INFRINGING — but it is also
   very close to purely descriptive, and the task explicitly lists the structurally
   identical `Noise Suppressor` (also a Boss product name, NS-2) as *fine, leave alone*.
   Those two should get the same answer. Either keep both (drop row 20's model change)
   or change both (and row 38 needs a proposal). I changed one and kept the other
   because the task said to; a human should reconcile it.

4. **`analogue.smith` keeps the word `analogue`.** `Analog Man` is the mark, and
   `analog` is descriptive of the goods, so substituting a different second noun should
   distinguish it — but it is the one proposal that retains a recognisable half of the
   original mark. If that is too close, `valve.smith` or `discrete.smith` go further at
   the cost of the 3-syllable first morpheme.

5. **Three proposals want a real-world availability check I could not do offline:**
   `Dual Reactor` (is there an existing amp called a Reactor?), `Kabuto` (used by a
   motorcycle-helmet maker, not audio, but worth confirming), and `Velvet` (used loosely
   in plugin naming). None is a known guitar-audio mark to me, but "not known to me" is
   not the same as "clear", and the standard forbids coining onto someone else's mark.

6. **Alphanumeric replacements are the weakest part of this table.** `MSW900 2140`,
   `GX-140`, `TSV412`, `HV28`, `VCX45C`, `RM-140`, `V921`, `LV-320H` are all defensible
   — every letter and enough digits move — but they are also flavourless compared to the
   originals, and model codes are cheap to get wrong (e.g. `DX`, `TB`, `VX`, `MPX`, `NDX`
   were all rejected during drafting because they are live marks at Yamaha, Vox, Lexicon
   or Naim). A human with more market knowledge should re-read just those eight.

7. **Should the `.usdz` seam be pre-populated?** `GearModelLoader` resolves `<slug>.usdz`
   and no catalog piece ships one, so the rename costs nothing there today. If bespoke
   models are planned before 010 runs, they should be authored against the *new* slugs.

8. **`ampProfile` back-compat.** The doc comment at ParameterMap:596–600 says the
   `ampLegacy` fallback exists so pre-rename names ("Marshall JCM800", "Fender Deluxe")
   keep sounding the same. This rename adds a third generation of names. A human should
   decide whether 010 *replaces* the old tokens or *appends* the new ones beside them —
   appending preserves every saved AUv3 host session at the cost of leaving the literal
   strings `jcm800`, `plexi` and `rectifier` in the shipped binary, which is itself part
   of what Guideline 5.2.1 review looks at.
