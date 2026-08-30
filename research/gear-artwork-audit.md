# Gear artwork audit — what is actually painted in the 116 shipped images

**Status: inventory for human review. PHASE 1 ONLY. Not one pixel was changed by this
audit.** Prompt 011's re-lettering pass is deliberately held until a human has read the
orphan-mark list (§4) and ruled on the trade-dress calls (§5).

**Not legal advice.** Everything below is a risk observation written by opening each PNG
and reading what is drawn in it. A human — ideally counsel — should sign off before
submission.

## What was actually done

Every one of the 116 in-scope images was **opened and read as an image**, not listed from
a directory. Icons were upscaled 3× before reading so 8–12 px lettering resolved; the
2400 px-wide panel strips read legibly at native width. Three findings below (`Bassman`,
`Deluxe Reverb-Amp`, the twelve Boss model codes) exist only in pixels and appear in no
catalog string, old or new — no rename could ever have surfaced them.

Method notes worth keeping:

- The 61 icon PNGs are **all byte-distinct**. The 67 PanelArt PNGs collapse to **42
  distinct images** by MD5 — several "model-specific" plates are byte-identical copies of
  each other and of the `category-*` generics. Groups are listed in §3.2 so a reviewer
  knows a single edit lands in several files (or, better, that several files should just
  keep pointing at one generic).
- A scanline colour-count scan (max distinct colours within any single row) separates the
  two populations cleanly and corroborates the visual read: the 11 amp/combo plates score
  **267–917**, every pedal and category plate scores **3–8**. Eight colours across a
  2400 px row cannot form a glyph. That is the machine confirmation that all 44 pedal
  plates are pure vertical gradients.

---

## 1. Headline findings

1. **The art still paints the OLD catalog names.** Prompt 010 renamed the strings and the
   files; it could not touch pixels. `proforge-shrew.png` still prints `ProCon` and `RAT`.
   `brig-distortion.png` still prints `VOSS`. **60 of 61 icons now paint a name the app no
   longer uses** — this is both the trademark exposure and a straightforward correctness
   bug: the library shows one name and the picture shows another.

2. **`chiron-centaur.png` was not a one-off. There are at least 23 orphan marks.** The
   worst are:
   - **`Bassman`** — painted on the nameplate of `fandor-bassdude-59.png`. A Fender
     registered mark, printed correctly and in full, appearing in **no catalog string,
     before or after 010**. The catalog has said `Bassdude` since v3.
   - **`Deluxe Reverb-Amp`** — painted in Fender's script on
     `fandor-tandem-reverb-panel.png`. Also a Fender mark, also in no catalog string —
     and it is on the wrong model: the piece is a *Twin*, wearing a *Deluxe* plate.
   - **Twelve Boss model codes** — `TU-3`, `CS-3`, `DS-1`, `MT-2`, `GE-7`, `NS-2`,
     `CE-2w`, `TR-2`, `OC-5`, `PS-6`, `DD-8`, `RV-6`, `RC-5`. Every BRIG icon carries one.
     None has ever appeared in a catalog name.
   - **Correctly-spelled marks the catalog only ever obfuscated** — the art prints
     `Dual Rectifier`, `ROCKERVERB 100` and `JAZZ CHORUS-120`, while the catalog only ever
     said `Ractifier`, `Rockervert` and `Jazzy Chorus`. The art is *worse* than the strings
     were.

3. **The panel plates are far less work than expected.** Only **11** of the 55
   model-specific plates carry any lettering — the amp and combo faceplates, which are
   exactly the 11 with knob-layout JSON sidecars. **All 44 pedal plates are flat vertical
   colour gradients with no text at all** and need no re-lettering.

4. **Three logo *devices* are painted, not just words** — the Mesa oval badge, the Orange
   crest shield, and the Roland boxed `R`. Removing text does not address these; they have
   to be redrawn or deleted.

5. **`PedalFinish.swift` is a third, independent copy of the trade dress.** 010 renamed
   its dictionary keys but left every RGB triple untouched, so Tube Screamer green
   `(0.33, 0.80, 0.33)`, Phase 90 orange `(1.00, 0.53, 0.07)`, Dyna Comp red and Big Muff
   grey all still ship. Out of scope for this prompt; flagged so it is not forgotten.
   (`GearArt.swift` was already cleaned by 010 — the five dead badge rows are gone.)

---

## 2. Classification counts

| Class | Icons (61) | Plates (55) | Total (116) |
|---|---|---|---|
| **CLEAN** — nothing to change | 0 | 44 | **44** |
| **TEXT ONLY** — a wordmark to re-letter | 25 | 1 | **26** |
| **TEXT + DRESS** — wordmark *and* an identifying colourway/layout | 36 | 7 | **43** |
| **DRESS / JUDGMENT ONLY** — no wordmark, but see §5 | 0 | 3 | **3** |

**72 of 116 images need work. Zero icons are clean.**

---

## 3. The inventory

`Current name` is the model's approved post-010 name from the naming audit §2 — the name
the app uses today, and therefore the replacement text.

### 3.1 Icons — `StreetRig/Assets.xcassets/<id>.imageset/<id>.png`

**Dimensions are load-bearing here.** See §6.

#### Amp heads

| Asset (`id`) | px | Current name | Class | What is actually painted | Replacement text |
|---|---|---|---|---|---|
| `marswell-msw900-2140` | 499×240 | Marswell MSW900 2140 | TEXT+DRESS | `Marswell` set in **Marshall's cursive script logotype**, swoosh underline and all; **`JCM 800`** + **`LEAD SERIES`** in black italic on a gold control panel | `MSW900` / `2140`; brand stays `Marswell` but the *script* must change — see §5.1 |
| `marswell-clearpane-stellar-lead-1042` | 493×234 | Marswell Clearpane Stellar Lead 1042 | TEXT+DRESS | Marshall cursive script; **`1959`** in a black boxed inset on gold | `1042` |
| `fremont-gx-140` | 493×234 | Fremont GX-140 | TEXT | **`FREEDMAN`** — the *pre-010* brand, one vowel from Friedman — on a gold nameplate. No model code | `FREMONT` |
| `mesquite-bootleg-dual-reactor` | 474×234 | Mesquite Bootleg Dual Reactor | TEXT+DRESS | **`MESA`** + **`BOOGEY`** inside **Mesa's oval badge device**; **`Dual Rectifier`** in script — *correctly spelled*, an orphan | `MESQUITE` / `BOOTLEG` / `Dual Reactor`; badge device must be redrawn |
| `tangerine-rumblecrest-100` | 371×221 | Tangerine Rumblecrest 100 | TEXT+DRESS | `TANGERINE` in **Orange's custom outlined display face**; **`ROCKERVERB 100`** — *correctly spelled*, an orphan; **Orange's picture-frame device** in the top-right box | `RUMBLECREST 100`; device must go |

#### Cabinets

| Asset (`id`) | px | Current name | Class | What is actually painted | Replacement text |
|---|---|---|---|---|---|
| `marswell-2415a-4x12` | 512×595 | Marswell 2415A 4x12 | TEXT+DRESS | Marshall cursive script; **`1960A`** on a gold plate — an orphan (catalog now says 2415A) | `2415A` |
| `mesquite-bootleg-oversized-4x12` | 512×640 | Mesquite Bootleg Oversized 4x12 | TEXT+DRESS | **`MESA`** + **`BOOGEY`** in the oval badge device | `MESQUITE` / `BOOTLEG`; badge redrawn |
| `tangerine-tsv412` | 512×544 | Tangerine TSV412 | TEXT+DRESS | `TANGERINE` in Orange's display face on a white nameplate; **Orange's crest shield device** (orange + blue dots, red bar, green triangle) drawn above it. No model code | brand re-set; **shield device must be deleted or replaced** |

#### Combo amps

| Asset (`id`) | px | Current name | Class | What is actually painted | Replacement text |
|---|---|---|---|---|---|
| `fandor-tandem-reverb` | 442×365 | Fandor Tandem Reverb | TEXT+DRESS | `Fandor` in **Fender's outlined drop-shadow script**, in Fender's signature top-left-of-grille position; **`Twin Reverb`** in Fender script on the black panel | `Tandem Reverb`; script — see §5.1 |
| `vane-hv28` | 467×400 | Vane HV28 | TEXT+DRESS | **`VOLT`** — the *pre-010* brand — in Vox's gold serif logotype. No model code. Brown diamond-lattice grille with cream trim | `VANE`; grille — see §5.3 |
| `marswell-vcx45c` | 410×362 | Marswell VCX45C | TEXT+DRESS | Marshall cursive script; **`DSL 40C`** on the gold panel | `VCX 45C` |
| `rondell-rm-140-velvet-chorus` | 512×454 | Rondell RM-140 Velvet Chorus | TEXT+DRESS | **Roland's boxed `R` logo device** with **`Rolund`** (pre-010 brand) under it; **`JAZZ CHORUS-120`** — *correctly spelled*, an orphan | `RM-140` / `VELVET CHORUS`; **`R` badge must be deleted or replaced** |
| `fandor-bassdude-59` | 403×378 | Fandor Bassdude '59 | TEXT+DRESS | Nameplate reads **`Fandor Bassman`** — **`Bassman` is an ORPHAN MARK**, see §4. Tweed diagonal weave + oxblood grille + script nameplate | `Fandor Bassdude` |
| `brig-kabuto-100` | 358×342 | BRIG Kabuto 100 | TEXT+EMBLEM | **`VOSS`** (pre-010 brand) in Boss's bold rounded logotype; a white badge carrying a **black katana/sword glyph** — a Katana-product emblem, orphan to the new `Kabuto` name | `BRIG`; sword glyph should go (a *kabuto* helmet would suit the new name) |

#### Pedals — the BRIG (Boss) family

All 14 share the Boss compact-pedal get-up: rounded chassis, full-width treadle, `CHECK`
LED, and the `► OUTPUT … INPUT ◄` legend row. All carry a ghosted `VOSS` on the treadle
and **an orphan Boss model code**. Knob labels are descriptive and must be kept.

| Asset (`id`) | Current name | Class | Painted | Orphan code | Replacement |
|---|---|---|---|---|---|
| `brig-chromatic-tuner` | BRIG Chromatic Tuner | TEXT+DRESS | `VOSS`, `Chromatic Tuner` | **`TU-3`** | `BRIG`, `Chromatic Tuner`, drop code |
| `brig-compression-leveller` | BRIG Compression Leveller | TEXT+DRESS | `VOSS`, `Compression Sustainer` | **`CS-3`** | `BRIG`, `Compression Leveller` |
| `brig-distortion` | BRIG Distortion | TEXT+DRESS | `VOSS`, `Distortion` | **`DS-1`** | `BRIG`, `Distortion` |
| `brig-metal-realm` | BRIG Metal Realm | TEXT+DRESS | `VOSS`, `Metal Zone` | **`MT-2`** | `BRIG`, `Metal Realm` |
| `brig-equalizer` | BRIG Equalizer | TEXT+DRESS | `VOSS`, `Equalizer` | **`GE-7`** | `BRIG`, `Equalizer` |
| `brig-noise-silencer` | BRIG Noise Silencer | TEXT+DRESS | `VOSS`, `Noise Suppressor` | **`NS-2`** | `BRIG`, `Noise Silencer` |
| `brig-chorus` | BRIG Chorus | TEXT+DRESS | `VOSS`, `Chorus` | **`CE-2w`** | `BRIG`, `Chorus` |
| `brig-tremolo` | BRIG Tremolo | TEXT+DRESS | `VOSS`, `Tremolo` | **`TR-2`** | `BRIG`, `Tremolo` |
| `brig-octave` | BRIG Octave | TEXT+DRESS | `VOSS`, `Octave` | **`OC-5`** | `BRIG`, `Octave` |
| `brig-chorister` | BRIG Chorister | TEXT+DRESS | `VOSS`, `Harmonist` | **`PS-6`** | `BRIG`, `Chorister` |
| `brig-digital-delay` | BRIG Digital Delay | TEXT+DRESS | `VOSS`, `Digital Delay` | **`DD-8`** | `BRIG`, `Digital Delay` |
| `brig-reverb` | BRIG Reverb | TEXT+DRESS | `VOSS`, `Reverb` | **`RV-6`** | `BRIG`, `Reverb` |
| `brig-loop-depot` | BRIG Loop Depot | TEXT+DRESS | `VOSS`, `Loop Station` | **`RC-5`** | `BRIG`, `Loop Depot` |
| `brig-lv-320h` | BRIG LV-320H | TEXT | `VOSS`, `FV-500H` on a volume treadle (stale, not orphan) | — | `BRIG`, `LV-320H` |

#### Pedals — the rest

| Asset (`id`) | Current name | Class | What is actually painted | Replacement text |
|---|---|---|---|---|
| `krx-damper-comp` | KRX damper comp | TEXT+DRESS | **`MXP`** in MXR's boxed-logo device; **`dyna comp`**. Dyna Comp red. Keeps `OUTPUT`/`SENS` | `KRX`, `damper comp` |
| `krx-swirl-72` | KRX swirl 72 | TEXT+DRESS | `MXP` boxed; **`phase 90`**. Phase 90 orange. Keeps `SPEED` | `KRX`, `swirl 72` |
| `krx-flanger` | KRX flanger | TEXT | `MXP`; `flanger`. Keeps MANUAL/WIDTH/SPEED/REGEN | `KRX`, `flanger` |
| `krx-ten-band-eq` | KRX ten band eq | TEXT | `MXP`; `ten band eq` | `KRX`, `ten band eq` |
| `electro-galvanic-big-mitt` | electro-galvanic BIG MITT Ω | TEXT+DRESS | `electro-harmonium`; **`BIG MUFF π`** in the Big Muff's own serif. Big Muff grey. Keeps VOLUME/TONE/SUSTAIN | `electro-galvanic`, `BIG MITT Ω` |
| `electro-galvanic-small-mime` | electro-galvanic SMALL MIME | TEXT | `electro-harmonium` boxed; **`SMALL CLONE`**. Keeps `RATE` | `electro-galvanic`, `SMALL MIME` |
| `electro-galvanic-small-slate` | electro-galvanic small slate | TEXT | `electro-harmonium`; **`small stone`**; `PHASE SHIFTER` (descriptive — still accurate, keep) | `electro-galvanic`, `small slate` |
| `electro-galvanic-electric-siren` | electro-galvanic electric siren | TEXT | `electro-harmonium`; **`electric mistress`**. Keeps RATE/FLANGER/CHORUS | `electro-galvanic`, `electric siren` |
| `electro-galvanic-micro-stack` | electro-galvanic micro STACK | TEXT | `electro-harmonium`; **`micro POG`**. Keeps DRY/SUB OCT/OCT UP | `electro-galvanic`, `micro STACK` |
| `electro-galvanic-reverie-mate` | electro-galvanic REVERIE MATE | TEXT | `electro-harmonium`; **`MEMORY MAN`** + **`DELUXE`** (orphan) | `electro-galvanic`, `REVERIE MATE`, drop `DELUXE` |
| `electro-galvanic-golden-fleece` | electro-galvanic GOLDEN FLEECE | TEXT | `electro-harmonium` boxed; **`HOLY GRAIL`**. Keeps `REVERB` | `electro-galvanic`, `GOLDEN FLEECE` |
| `electro-galvanic-frost` | electro-galvanic FROST | TEXT | `electro-harmonium` boxed; **`FREEZE`**. Keeps `LEVEL` | `electro-galvanic`, `FROST` |
| `iberon-valve-shrieker` | Iberon Valve Shrieker | TEXT+DRESS | **`Ibonez`** in Ibanez's blue bold-italic logotype. **No model text** — but green chassis + white plate + blue script + DRIVE/TONE/LEVEL *is* the complete TS9 get-up | `Iberon`; see §5.2 |
| `proforge-shrew` | ProForge SHREW | TEXT+DRESS | **`ProCon`**; **`RAT`** inside the signature boxed rectangle; the boxed `DISTORTION | FILTER | VOLUME` header strip | `ProForge`, `SHREW` |
| `chiron-satyr` | Chiron SATYR | TEXT+DRESS | `Chiron` (brand is approved, keep); **`CENTAUR`**; **`KTR`** — the known orphan. Klon red. Keeps GAIN/TREBLE/OUTPUT | `SATYR`; **delete `KTR` outright** |
| `analogue-smith-duke-of-drive` | analogue.smith DUKE of DRIVE | TEXT+DRESS | **`KING of TONE`**, **`analogue.man`**, a gold compass-rose device. King of Tone purple. Keeps V/D/`Tone` | `analogue.smith`, `DUKE of DRIVE` |
| `marswell-blues-blazer` | Marswell BLUES BLAZER | TEXT | `Marswell` (correct); **`BLUES BREAKER`**. Keeps GAIN/TONE/VOLUME | `BLUES BLAZER` |
| `fullbrook-fixation` | Fullbrook FIXATION | TEXT | **`Fullstone`**; **`OCD`**; **`v1.4`** (Fulltone revision marker, orphan-adjacent) | `Fullbrook`, `FIXATION`, drop `v1.4` |
| `dalton-armature-fuzz-dome` | DALTON ARMATURE FUZZ DOME | TEXT+DRESS | **`FUZZ FACE`**, **`DALLAS ARBITOR`**; the round enclosure with two knobs as "eyes" is itself the Fuzz Face get-up | `DALTON ARMATURE`, `FUZZ DOME`; see §5.4 |
| `z-flux-fuzz-foundry` | Z.FLUX FUZZ FOUNDRY | TEXT | **`Z.HEX`**; **`FUZZ FACTORY`**. Keeps VOL/GATE/COMP/DRIVE/STAB | `Z.FLUX`, `FUZZ FOUNDRY` |
| `exalt-preamp-booster` | Exalt PREAMP booster | TEXT | **`Exotiq`** boxed; **`EP booster`**. Keeps `BOOST` | `Exalt`, `PREAMP booster` |
| `strider-beryllium` | strider BERYLLIUM | TEXT | **`strymo`**; **`IRIDIUM`**. Keeps six descriptive labels | `strider`, `BERYLLIUM` |
| `fullbrook-lucid-vibe` | Fullbrook Lucid'Vibe | TEXT | **`Fullstone`**; **`Deja'Vibe`**; **`CS-MDV mkII`** (orphan) | `Fullbrook`, `Lucid'Vibe`, drop code |
| `keswick-compressor` | Keswick Compressor | TEXT | **`Keenly`** boxed; `Compressor` (descriptive, keep) | `Keswick` |
| `dunridge-weeping-willow` | DUNRIDGE WEEPING WILLOW | TEXT+DRESS | **`DUNLAP`**, **`CRY BABY`** on the treadle | `DUNRIDGE`, `WEEPING WILLOW` |
| `vane-v921` | VANE V921 | TEXT | **`VOLT`**, **`V847`** on the treadle | `VANE`, `V921` |
| `mordant-wild-pony` | MORDANT WILD PONY | TEXT | **`MORLEE`**, **`BAD HORSIE`** | `MORDANT`, `WILD PONY` |
| `dunridge-echoreel` | DUNRIDGE ECHOREEL | TEXT | **`DUNLAP`** boxed; **`ECHOPLEX`**. Labels read `VOL SUSTAINDELAY` — a spacing bug, see §7 | `DUNRIDGE`, `ECHOREEL` |
| `digivault-slingshot` | DigiVault SLINGSHOT | TEXT+DRESS | **`DigiTek`**, **`WHAMMY`**. Whammy red | `DigiVault`, `SLINGSHOT` |
| `quell-nullifier-ii` | QUELL NULLIFIER II | TEXT | **`ITP`**; **`DECIMATOR II`**; **`G STRING`** (orphan) | `QUELL`, `NULLIFIER II`, drop `G STRING` |
| `fornax-kraal` | FORNAX KRAAL | TEXT | **`FORTIS`** boxed; **`ZUUL`**. Keeps `GATE` | `FORNAX`, `KRAAL` |
| `emblem-parametric-eq` | EMBLEM Parametric EQ | TEXT | **`EMPRISS`**; **`ParaEq`**. Keeps LOW/MID/HI F+G | `EMBLEM`, `Parametric EQ` |
| `errol-brass-swell-mini` | ERROL BRASS SWELL MINI | TEXT | **`ERNIE BELL`**, **`VP JR`** | `ERROL BRASS`, `SWELL MINI` |

### 3.2 Panel plates — `StreetRig/PanelArt/<id>-panel.png`

#### The 11 that carry lettering (all 2000×216; all have a JSON sidecar)

| Plate | Current name | Class | What is actually painted | Replacement text |
|---|---|---|---|---|
| `marswell-msw900-2140-panel` | Marswell MSW900 2140 | TEXT+DRESS | **`JCM 800`** / **`LEAD SERIES`** in italic on the gold gradient plate. All knob legends (PRESENCE, BASS, MIDDLE, TREBLE, MASTER VOLUME, PRE-AMP VOLUME, HIGH/LOW SENSITIVITY) descriptive — **keep** | `MSW900` / `2140` |
| `marswell-clearpane-stellar-lead-1042-panel` | Marswell Clearpane Stellar Lead 1042 | DRESS only | **No wordmark.** `AMP`, `OFF`/`ON`, `VOLUME I`/`II`, `INPUTS I`/`II` — all descriptive | none needed; see §5.1 for the gold plate |
| `fremont-gx-140-panel` | Fremont GX-140 | JUDGMENT | **No wordmark.** But switch legends read `C45`, `VOICE`, `BRIGHT`, **`CLN-BE-HBE`** — `BE`/`HBE` are Friedman's own channel designations (BE = "Brown Eye", the source of `BE-100`) | see §5.5 |
| `mesquite-bootleg-dual-reactor-panel` | Mesquite Bootleg Dual Reactor | TEXT | **`Ractifier`** in large script (the obfuscated spelling — stale, not orphan). Rest descriptive | `Reactor` |
| `tangerine-rumblecrest-100-panel` | Tangerine Rumblecrest 100 | TEXT+DRESS | **`Tangerine`** in Orange's display face; **`ROCKERVERT 100`**; **`MKIII`**; plus **Orange's hieroglyphic control legends** — the pictogram symbols in place of words are a distinctive Orange design signature | `RUMBLECREST 100`; see §5.6 for the hieroglyphs |
| `fandor-tandem-reverb-panel` | Fandor Tandem Reverb | TEXT+DRESS | **`Deluxe Reverb-Amp`** in Fender script — **ORPHAN, and the wrong model**; **`FANDOR MUSICAL INSTRUMENTS`** mimicking Fender's plate legend. `NORMAL`/`VIBRATO` and knob labels descriptive — keep | `Tandem Reverb-Amp`; drop or re-word the "MUSICAL INSTRUMENTS" line |
| `vane-hv28-panel` | Vane HV28 | TEXT+DRESS | **`A VOLT PRODUCT`** bottom-right — imitates Vox's "A VOX PRODUCT" plate legend, *and* carries the pre-010 brand. `TOP BOOST` is Vox's circuit designation (arguably technical/descriptive). Plate is bright pink `rgb(197,81,128)` — see §7 | `A VANE PRODUCT` or drop the line |
| `marswell-vcx45c-panel` | Marswell VCX45C | TEXT+DRESS | **`DSL 40`** at right on the gold gradient plate. CLASSIC GAIN / ULTRA GAIN / EQUALISATION / REVERB / MASTER and all knob legends descriptive — keep | `VCX 45` |
| `rondell-rm-140-velvet-chorus-panel` | Rondell RM-140 Velvet Chorus | TEXT | **`JAZZY CHORUS-120`** in a boxed nameplate; **`ROLUND`** below it. CHANNEL-1/2, VIB/CHOR descriptive — keep | `VELVET CHORUS-140`, `RONDELL` |
| `fandor-bassdude-59-panel` | Fandor Bassdude '59 | JUDGMENT | **No wordmark.** Visible text at the far left is `S AMP` — a clipped label, see §7. Knob dials numbered **1–12**, the tweed-Bassman signature | none; see §5.7 |
| `brig-kabuto-100-panel` | BRIG Kabuto 100 | TEXT+EMBLEM | **`KETANA 100`** (pre-010 name) and a **`刀` kanji** (literally "katana"). AMP TYPE positions BROWN/LEAD/CRUNCH/PUSHED/CLEAN/ACOUSTIC and all section legends are the control set — keep | `KABUTO 100`; replace 刀 with 兜 (kabuto) or delete |

#### The 44 that are CLEAN

Every remaining model plate is a **pure vertical colour gradient with no text, no logo and
no device**. Confirmed visually and by the scanline scan (3–8 distinct colours per row).
**No re-lettering needed on any of them.**

`analogue-smith-duke-of-drive`, `brig-chorister`, `brig-chorus`, `brig-compression-leveller`,
`brig-digital-delay`, `brig-distortion`, `brig-equalizer`, `brig-lv-320h`, `brig-metal-realm`,
`brig-noise-silencer`, `brig-octave`, `brig-reverb`, `brig-tremolo`, `chiron-satyr`,
`dalton-armature-fuzz-dome`, `digivault-slingshot`, `dunridge-echoreel`,
`dunridge-weeping-willow`, `electro-galvanic-big-mitt`, `electro-galvanic-electric-siren`,
`electro-galvanic-golden-fleece`, `electro-galvanic-micro-stack`,
`electro-galvanic-reverie-mate`, `electro-galvanic-small-mime`, `electro-galvanic-small-slate`,
`emblem-parametric-eq`, `errol-brass-swell-mini`, `exalt-preamp-booster`, `fornax-kraal`,
`fullbrook-fixation`, `fullbrook-lucid-vibe`, `iberon-valve-shrieker`, `keswick-compressor`,
`krx-damper-comp`, `krx-flanger`, `krx-swirl-72`, `krx-ten-band-eq`, `marswell-blues-blazer`,
`mordant-wild-pony`, `proforge-shrew`, `quell-nullifier-ii`, `strider-beryllium`,
`vane-v921`, `z-flux-fuzz-foundry`.

**Duplicate groups** (byte-identical; several also match a `category-*` generic, meaning
those models are already falling back to the generic look and could simply be deleted):

| MD5 | Files |
|---|---|
| `35d14cdc…` | `category-noiseGate`, `category-overdrive`, `category-wah`, `analogue-smith-duke-of-drive`, `chiron-satyr`, `exalt-preamp-booster`, `fornax-kraal`, `fullbrook-fixation`, `quell-nullifier-ii`, `strider-beryllium` |
| `81fe7c37…` | `category-modulation`, `category-pitch`, `brig-chorister`, `brig-octave`, `electro-galvanic-micro-stack`, `electro-galvanic-small-slate`, `fullbrook-lucid-vibe` |
| `8fb7ae29…` | `dunridge-echoreel`, `electro-galvanic-golden-fleece`, `electro-galvanic-small-mime`, `marswell-blues-blazer`, `proforge-shrew` |
| `3d948b58…` | `electro-galvanic-electric-siren`, `electro-galvanic-reverie-mate`, `errol-brass-swell-mini` |
| `04bf5f81…` | `category-eq`, `category-volume`, `emblem-parametric-eq` |
| `ae5dbf64…` | `category-compressor`, `keswick-compressor` |
| `c1f56cc7…` | `brig-lv-320h`, `brig-reverb` |

---

## 4. Orphan marks — the section to read first

Text or devices belonging to a real manufacturer that appear in **no catalog string,
before or after 010**. No rename would ever have surfaced these; only opening the images
did. This is the list that justified holding the re-letter for review.

| # | Mark | Owner | Where | Note |
|---|---|---|---|---|
| 1 | **`Bassman`** | Fender | `fandor-bassdude-59.png` | Printed in full on the nameplate. The catalog has said `Bassdude` since v3. **The most serious find in this audit.** |
| 2 | **`Deluxe Reverb-Amp`** | Fender | `fandor-tandem-reverb-panel.png` | In Fender's script — *and on the wrong model*. The piece is a Twin. |
| 3 | **`KTR`** | Klon | `chiron-satyr.png` | The known one. Confirmed still present. |
| 4–15 | **`TU-3`, `CS-3`, `DS-1`, `MT-2`, `GE-7`, `NS-2`, `CE-2w`, `TR-2`, `OC-5`, `PS-6`, `DD-8`, `RV-6`, `RC-5`** | Boss | the 13 BRIG pedal icons | Every BRIG icon carries one. A systematic family, not scattered accidents. |
| 16 | **`G STRING`** | ISP | `quell-nullifier-ii.png` | From "Decimator II G String". |
| 17 | **`DELUXE`** | EHX | `electro-galvanic-reverie-mate.png` | From "Deluxe Memory Man". Also the dead `deluxe` amp matcher token noted in the naming audit §3.2. |
| 18 | **`CS-MDV mkII`** | Fulltone | `fullbrook-lucid-vibe.png` | Fulltone's actual model code. |
| 19 | **`Dual Rectifier`** | Mesa | `mesquite-bootleg-dual-reactor.png` | **Correctly spelled.** The catalog only ever shipped `Ractifier`. |
| 20 | **`ROCKERVERB 100`** | Orange | `tangerine-rumblecrest-100.png` | **Correctly spelled.** The catalog only ever shipped `Rockervert`. |
| 21 | **`JAZZ CHORUS-120`** | Roland | `rondell-rm-140-velvet-chorus.png` | **Correctly spelled**, with the `-120` suffix. Catalog said `JC-120 Jazzy Chorus`. |
| 22 | **Mesa oval badge device** | Mesa | `mesquite-bootleg-dual-reactor.png`, `mesquite-bootleg-oversized-4x12.png` | A *device*, not text. |
| 23 | **Orange crest shield device** | Orange | `tangerine-tsv412.png` | A *device*, not text. |
| 24 | **Roland boxed `R` device** | Roland | `rondell-rm-140-velvet-chorus.png` | A *device*, not text. |
| 25 | **`刀` (katana kanji)** | — | `brig-kabuto-100.png`, `brig-kabuto-100-panel.png` | Not a registered mark, but it *names the Katana* and is now orphaned by the `Kabuto` rename. |
| 26 | **`A VOLT PRODUCT`** | Vox (form) | `vane-hv28-panel.png` | Imitates the "A VOX PRODUCT" plate legend *and* carries the pre-010 brand. |
| 27 | **`v1.4`** | Fulltone | `fullbrook-fixation.png` | Weakest of the set; a revision marker, but Fulltone's own. |
| 28 | **`MKIII`** | Orange | `tangerine-rumblecrest-100-panel.png` | Generic revision marker; listed for completeness. |

**Not orphan marks — descriptive labels that must be KEPT.** These read like model text
but are not: `Drive`, `Tone`, `Level`, `Volume`, `Sustain`, `Gain`, `Rate`, `Depth`,
`Speed`, `Sens`, `Blend`, `Attack`, `Threshold`, `Decay`, `Mix`, `Presence`, `Bass`,
`Middle`, `Treble`, `Master`, `Reverb`, `Intensity`, `Manual`, `Width`, `Regen`, `Wave`,
`Mode`, `Time`, `E.Level`, `F.Back`, `Direct`, `Oct+1`, `Oct-1`, `Range`, `Key`, `Shift`,
`Bal`, `Dry`, `Sub Oct`, `Oct Up`, `Low/Mid/Hi F` and `G`, `Vol`, `Gate`, `Comp`, `Stab`,
`Boost`, `Filter`, `Dist`, `High`, `Mid`, `Input`, `Output`, `Check`, `Power`, `Standby`,
`On`/`Off`, `Fuse`, `Normal`, `Vibrato`, `Bright`, `Channel-1/2`, `Classic Gain`,
`Ultra Gain`, `Equalisation`, `Phase Shifter`, `Top Boost`, `Loop Active Master`,
`Tone Setting`, `Power Control`, `Amp Type`. `PedalSpec` and the panel JSON expect these.

---

## 5. Trade dress — the judgment calls

These are **not** legal cleanups. Repainting a colourway is a visible product change and
the user may have opinions. Each is stated as a recommendation for a human to accept or
reject; **nothing here should be changed without sign-off.**

### 5.1 The four house logotypes are drawn in the originals' scripts — **the biggest call**

`Marswell` (5 images), `Fandor` (2), `Tangerine` (3) and the Mesa oval are not merely
words: each is set in a **close imitation of the original manufacturer's logotype**.
Marshall's cursive-with-swoosh, Fender's outlined drop-shadow script and Orange's custom
outlined display face are each protectable as a design mark independent of the word.
Changing `JCM 800` to `MSW900` leaves the *logo shape* untouched, which is arguably the
more recognisable half.

- **Recommendation:** commission **one** StreetRig house logotype and apply it to all four
  in-house brands. That reads as an intentional design system rather than four separate
  imitations, and it is the only option that actually resolves the exposure.
- **Cost:** this is the single largest design task in the whole re-letter, and it changes
  the look of every amp in the app.
- **Do not** attempt this by substituting a system script font — see §8.

### 5.2 `iberon-valve-shrieker` — dress with no text to fix

This icon has **no infringing word on it** (`Ibonez` becomes `Iberon` and that is all the
text there is). What identifies it is the combination: bright green chassis + white
rectangular plate + blue italic script + the exact DRIVE/TONE/LEVEL triangle. That is the
TS9 get-up in full, and `PedalFinish` reinforces it with Tube Screamer green
`(0.33, 0.80, 0.33)`.

- **Recommendation:** shift the green (toward teal or a yellower green) **or** change the
  plate geometry. Doing neither leaves a pedal that is identifiably a Tube Screamer with a
  different word on it.
- **Counter-argument:** green overdrives are near-generic in 2026; a reviewer may find
  this acceptable. Reasonable people differ. **Human decides.**

### 5.3 `vane-hv28` — the Vox grille

Brown/maroon diamond-lattice grille cloth with cream piping is the AC30's most recognisable
feature and is not functional.

- **Recommendation:** change the lattice colour, or the weave geometry. Low effort, and it
  is the clearest dress-only signal in the set.

### 5.4 `dalton-armature-fuzz-dome` — the round enclosure

The circular enclosure with two knobs positioned as eyes above a name *is* the Fuzz Face.
Removing the words leaves the joke, and the joke is the mark.

- **Recommendation:** keep the round enclosure (round pedals are not exclusive) but move
  the knobs off the "face" positions. Or accept it. **Human decides.**

### 5.5 `fremont-gx-140-panel` — the `BE`/`HBE` channel legends

`CLN-BE-HBE` and `C45` are switch legends, which argues descriptive. But `BE` stands for
"Brown Eye" and is the source of the `BE-100` mark the catalog just spent effort renaming
away from.

- **Recommendation:** relabel to neutral equivalents (`CLN-DRV-HOT`, `C45`→`VTG`). Low
  cost, removes the last thread back to the mark.

### 5.6 `tangerine-rumblecrest-100-panel` — the Orange hieroglyphs

Orange famously replaced control words with pictograms. The panel reproduces that scheme.
It is highly distinctive and carries no words at all.

- **Recommendation:** this one leans toward *change*, because the pictogram scheme is the
  thing people recognise. But it is also charming art and the most expensive to redraw.
  **Human decides.**

### 5.7 Gold plates and tweed — probably fine

`marswell-*` gold control panels, `fandor-bassdude-59` tweed, `fandor-tandem-reverb`
silver grille. These are period-typical amp conventions used by many builders.

- **Recommendation:** **leave alone.** Flagged only so the decision is on the record.

### 5.8 `PedalFinish.swift` — out of scope, but the same problem

010 renamed the dictionary keys and left every RGB untouched. Tube Screamer green, Phase 90
orange, Dyna Comp red, Big Muff grey and Klon red all still ship as literal constants. Any
decision made above about a colourway should be applied here too, or the 3D pedal and the
icon will disagree.

---

## 6. Constraint: pixel dimensions are 3D geometry

`ProceduralAmp` lives in **`StreetRig/Views/AmpModel3DView.swift:207`**. Its private
`aspect(_:)` at **lines 334–336** reads

```swift
guard let image, image.size.height > 0 else { return nil }
return Float(image.size.width / image.size.height)
```

and `headBox`/`cabBox`/`comboBox` (lines ~290–320) size the 3D boxes from that ratio,
solving for a common width so the head and cab aspects add to a fixed height budget. The
same PNG is also the texture on the front face.

**Any change to an icon's pixel dimensions silently changes the geometry of the 3D stage.**
Re-lettering must be strictly in-place: same width, same height, same format (PNG), same
colour space (all 61 are `RGB`). This binds the 13 amp/cabinet/combo icons directly; apply
it to all 116 as a rule, since nothing is gained by resizing.

For the record, the current dimensions: pedal icons are uniformly **228×330**; the amp
family varies (`marswell-msw900-2140` 499×240, `marswell-2415a-4x12` 512×595,
`mesquite-bootleg-oversized-4x12` 512×640, etc. — see §3.1). Panel plates are **2400×216**
for pedals, **2400×408** for the two ten-band EQs, **2000×216** for the 11 amp faceplates.

Also unchanged by this prompt: the 11 `<id>-panel.json` sidecars hold knob coordinates
only. No re-lettering listed above moves a knob, so none of them should be touched.

---

## 7. Cosmetic bugs found in passing (not trademark issues)

Reported because they were found while reading the art, and the re-letter is the natural
time to fix them.

1. **`fandor-bassdude-59-panel.png`** — the leftmost label renders as **`S AMP`**. It is
   the tail of a longer string clipped by the canvas edge; the rest does not exist in the
   raster. Given the icon's nameplate says "Bassman", the original almost certainly read
   `BASSMAN AMP`. Whatever it was, `S AMP` is meaningless on screen.
2. **`dunridge-echoreel.png`** — knob labels render as `VOL SUSTAINDELAY`; `SUSTAIN` and
   `DELAY` are colliding with no space.
3. **`vane-hv28-panel.png`** — the plate is bright pink, `rgb(197, 81, 128)`. Every other
   amp plate is a plausible metal or paint colour. This looks like a tint bug, not a
   design choice.
4. **`brig-metal-realm.png`** — the `HIGH` / `MID` knob labels are partially occluded by
   the divider rule drawn over them.
5. **Seven model plates are byte-identical to a `category-*` generic** (§3.2). Those five
   models are already showing the generic plate; the per-model files add nothing and could
   be deleted so the loader falls back cleanly.

---

## 8. Tooling assessment — what this environment can and cannot do

### What is actually installed

| Tool | Status | Useful for |
|---|---|---|
| `sips` (macOS built-in) | ✅ present | resize, crop (`--cropOffset`), format and colour-profile conversion. **Cannot draw text or composite.** |
| `swiftc` + CoreGraphics / CoreText / ImageIO | ✅ present, **verified working** | full raster compositing, arbitrary crops, resampling, PNG encode. I built and ran a crop tool and a pixel-scanner during this audit. CoreText can set text in any installed font. **This is the only real image-editing capability here.** |
| `python3` | ⚠️ Xcode's 3.9 | **no Pillow, no numpy.** `pip` exists but a network install is unverified and likely sandboxed. |
| ImageMagick / GraphicsMagick | ❌ absent | — |
| Inkscape, `rsvg-convert`, `potrace` | ❌ absent | no SVG path, no vectorisation |
| `node` / `npm` | ❌ absent | no canvas/sharp |
| `brew` | ✅ present | could install ImageMagick given network + time |
| Fonts | system only | Helvetica, Helvetica Neue, Avenir, Avenir Next Condensed, Courier, Lucida Grande, Geneva, Arial. **No script, display or custom faces.** |

There is **no generator script** in the repo — no `tools/`, no `scripts/`, nothing that
built these PNGs. They are hand-authored assets. There is no source to re-render from.

### Honest assessment: can I re-letter these convincingly?

**Partly. About two thirds, yes; the rest needs a designer.**

**Where programmatic re-lettering will be genuinely indistinguishable (~45 of 61 icons):**

The pedal icons are flat vector-style illustrations: solid colour fields, plain
grotesque/serif text, no gradients behind the lettering. Painting the old string out with
the sampled local background colour and setting the new string in Helvetica or Avenir at
the measured size and baseline will look exactly like the original, because the original
*is* a system-sans-alike. This covers the whole BRIG family, all four KRX pedals, the EHX
family, and the boxed-logo pedals (`ITP`, `FORTIS`, `Keenly`, `Exotiq`, `Z.HEX`, `DUNLAP`).

**Deleting the orphan marks is the easiest operation in the whole job** — fill with the
background colour, no replacement text to match. That alone clears items 3–18 and 27–28 of
§4 and is where most of the legal risk sits.

**Where it will NOT look like the same designer made it:**

- **The four logotypes (§5.1).** `Marswell` in Marshall's cursive, `Fandor` in Fender's
  outlined script, `TANGERINE` in Orange's display face. No installed font is close.
  Substituting Snell Roundhand or Zapfino produces something that reads as *edited*, not
  as *designed* — it will look worse than what is there now, and obviously so. **This
  needs a designer, or the §5.1 house-logotype decision.**
- **The three logo devices** (Mesa oval, Orange crest, Roland `R`). These are drawn
  artwork, not text. Deleting them leaves a hole in a composition that was balanced around
  them. Redrawing a replacement badge is illustration work, not scripting.
- **`BIG MUFF π` in the Big Muff's own serif.** A system serif gets close-ish, but the
  letterforms are the recognisable part. Borderline — worth attempting, worth reviewing.
- **The gold amp panels.** The lettering sits on a *lit gradient*. Flood-filling behind
  removed text will band visibly unless the fill reconstructs the local gradient. Doable
  in CoreGraphics with care, but this is exactly where a sloppy edit shows, and these are
  the largest, most-looked-at images in the app.

**My recommendation for sequencing:**

1. **Do the safe two thirds programmatically now** — the flat-field pedal icons and every
   orphan-mark deletion. High legal value, low visual risk, and I can verify each result by
   reading the image back.
2. **Hold the 13 amp/cab/combo icons and the 11 amp plates** for the §5.1 logotype
   decision. Re-lettering them before that decision means doing them twice.
3. **Do not touch any colourway** until §5 is signed off.

I would rather deliver 45 images that nobody notices were changed than 61 where 16 look
wrong. Overstating what a font substitution can do here would be the easiest way to make
the app look cheaper than it does today.

---

## 9. Verification checklist for phase 2 (not yet run)

- [ ] Every modified image re-read and confirmed: mark gone, new name legible **at MY GEAR
      rail icon size**, not just at full resolution.
- [ ] Pixel dimensions byte-identical for all 116 (§6). Compare before/after with `sips`.
- [ ] Format still PNG, colour space still `RGB`, for all 116.
- [ ] Re-scan for orphan marks: no manufacturer text remains that is absent from the
      catalog.
- [ ] Asset resolution intact: 61 imagesets, 55 model plates, 11 sidecars, zero misses,
      zero orphans (`CatalogIntegrityCheck`).
- [ ] Build green; icons render in MY GEAR rail, GEAR LIBRARY, cards, zoom detail, and the
      3D stage — the amp's textured front face especially.
- [ ] Tests green, with real output reported.
