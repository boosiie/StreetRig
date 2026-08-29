# Adding an Amp — the playbook

**Status:** current as of 2026-08-19 · **Scope:** how to voice another amp now that the profile
architecture exists, and what to paste into a fresh Claude Code session to do it.

> Companion to `research/amp-emulation-approaches.md` (the architecture + spec) and
> `research/amp-profile-implementation-notes.md` (what actually shipped, and §2's worked example).

---

## The headline: do NOT repeat the Kabuto process

The Kabuto took three prompts — research → architecture → FX blocks — because it was building the
*template*, not an amp. That work is done. **Adding amp number seven is one id, one table row, and
one name match.** No new class, no parameter address, no signature change, no UI, no migration, no
`catalogVersion` bump.

If a fresh session starts by proposing a research doc for a new amp, it has misread the situation.
Point it at `research/amp-profile-implementation-notes.md` §2, which contains the entire diff for
adding a Clearpane 1042.

---

## How the Kabuto work actually went, in one pass

Useful mainly as a record of what the three-prompt arc was *for*:

1. **Diagnose before designing.** The finding that unlocked everything was that all amps shared one
   fixed `AnalogAmp` voicing and one fixed `ToneStack`, and that `ToneStack` had no `noonDB` — no
   concept of what a stack does at noon. Every amp was flat-at-noon and therefore identical. That
   single missing field was the bug; the rest was consequence.
2. **Find the precedent already in the repo.** `DrivePedal::Voice` / `voiceFor()` already solved
   this exact problem for pedals. The amp schema is a copy of its shape, not an invention. Look for
   the existing pattern before designing a new one.
3. **Make the hard case the test case.** The Kabuto is itself a modeling amp, so its five characters
   are five different amps in one box — a free stress test. Two schema fields exist *because* it
   pushed back: `bypassCab` and negative `rangeScale` (which is what lets the Vane Cut work
   backwards). Both came out general rather than Kabuto-specific.
4. **Prove generality by implementing five more amps**, not by asserting it. MSW900, Tandem, HV28,
   RM-140, Bassdude shipped alongside the Kabuto for exactly this reason.
5. **Verify by measurement, not argument.** The offline harness renders through the real AU graph.
   It caught two things reasoning did not: the doc's default `PowerAmpVoicing` silently clipped the
   Legacy path, and the RM-140's 25 kHz Miller poles sat above Nyquist and rendered the entire amp
   as NaN.

---

## Which tier is your amp?

**Tier 1 — the schema already fits it.** Almost every guitar amp. Tube or solid-state, any number
of preamp stages up to four, any tone-stack topology, any power section. One table row.

**Tier 2 — it stresses the schema.** Only if the amp's identity comes from something the profile
cannot express: a built-in rotary/Leslie, a genuinely unusual topology, or another modeling amp
with its own onboard FX personality. Then extend the schema first — and the extension should come
out *general*, the way `bypassCab` did.

When unsure, assume Tier 1. If the row can't express it, that surfaces immediately and cheaply.

### Ids in use

**Every amp in the catalog is now profiled** — 11 of them. `Legacy` (0) remains the fallback for
any name the matcher does not recognise, and is bit-exact with the pre-profile engine.

| id | amp | id | amp |
|---|---|---|---|
| 0 | Legacy (fallback) | 7 | Fremont GX-140 |
| 1 | Marswell MSW900 2140 | 8 | Mesquite Bootleg Dual Reactor |
| 2 | Fandor Tandem Reverb | 9 | Tangerine Rumblecrest 100 |
| 3 | Vane HV28 | 10–19 | BRIG Kabuto 100 (5 characters × A/B) |
| 4 | Rondell RM-140 | 20 | Marswell VCX45C |
| 5 | Fandor Bassdude '59 | 21+ | **open** |
| 6 | Marswell Clearpane Stellar Lead 1042 | | |

A new amp takes **21 or higher**. Ids are append-only and must never be reused — they appear in
`RigDSPPlan.signature` and a saved rig's amp name resolves to one.

Because the catalog is complete, a new amp now means a new catalog entry in `RigStore.swift` too
(and artwork — `GearIconLoader.slug(name)` keys off the name, so names are load-bearing).

---

## Tier 1 — paste this into a fresh session

Replace the bracketed parts.

```
Voice [AMP NAME] in StreetRig's amp profile system. It is [in the catalog as
"[CATALOG NAME]" / a new catalog entry].

Read these first, in order:
- research/amp-profile-implementation-notes.md — §2 is a complete worked example of
  adding an amp (the Clearpane 1042). Your change should look exactly like it.
- research/amp-emulation-approaches.md — §2 is the schema field-by-field, §3 has six
  filled-in amps to calibrate against, §11 is the tuning table format.
- StreetRigEngine/Audio/AmpProfile.hpp and .cpp — the enum and the one auditable table.

This is a table-row task, NOT an architecture task. Do not write a research doc, do not
add a class, do not add a parameter address, do not touch the topology signature, and do
NOT bump RigStore.catalogVersion (it discards saved rigs). If you find the schema genuinely
cannot express this amp, stop and tell me before designing anything — that is a different
and much larger job.

What the amp needs:
1. One id in `enum AmpVoicing` (use a reserved id if this amp has one, else 20+).
2. One `case` in `profileFor()` with every field given a real value — preamp stages,
   tone stack, power amp, cab slot, out trim. Ground each in what the real circuit does,
   and put the "what to listen for" cue in a comment beside any value you are unsure of,
   matching the style of the existing rows.
3. One name match in `ParameterMap.swift`, substring-based like the others.
4. Add it to the `catalog` array in `runAmpProfileVerification` so the offline suite
   covers it.

Then build and verify for real — do not report success from reasoning:
- xcodebuild (the Simulator MCP is broken here; use the CLI with DerivedData in a scratch
  dir), both the app and the AUv3 extension, Debug and Release.
- Run the offline harness (-RunOfflineRender or STREETRIG_OFFLINE_RENDER=1) and report the
  verbatim pass/fail lines. The new amp must differ measurably from every existing amp at
  matched level, and the Legacy null test must stay bit-exact.
- Watch for the two traps that have already bitten: filter corners at or above Nyquist
  render the amp as NaN, and a non-neutral PowerAmpVoicing default silently clips Legacy.

Report what you shipped, the measurements, and which values most need ear-tuning.
Do not commit.
```

## Tier 2 — if the schema needs extending

Same as above, but insert before "What the amp needs":

```
This amp likely needs a schema extension: [WHAT IT DOES THAT THE PROFILE CANNOT EXPRESS].
Design the extension to be GENERAL, not specific to this amp — the precedent is `bypassCab`
and negative `rangeScale`, both added because the Kabuto pushed back and both usable by any
amp. Add the field to the struct with a NEUTRAL default so every existing profile is
unaffected, and prove that with the bit-exact Legacy null test.
```

---

## The parts of the prompt that are load-bearing

If you write your own instead of pasting the above, keep these — each maps to something that
actually went wrong or was nearly missed:

- **"This is a table-row task, not an architecture task."** Without it a fresh session will
  reasonably propose the full research arc again.
- **"Do NOT bump catalogVersion."** It discards the player's saved rig. Additive `values` keys
  don't need it.
- **"Build and verify for real, report verbatim output."** Both device builds and the offline
  suite have caught real bugs that reasoning passed over.
- **"Stop and tell me if the schema can't express it."** Turns a silent special-case hack into a
  decision you get to make.
- **Name the two known traps** (Nyquist NaN, non-neutral power defaults). They are cheap to avoid
  and expensive to debug.
- **"Do not commit."** Keeps the branch yours.

---

## What still needs ears, for any amp you add

Nothing in the amp system has been heard by anyone yet — every result to date is measured, not
listened to. The offline harness writes `StreetRig_amp_ab.wav` and `StreetRig_kabuto_ab.wav` to
Documents for A/B on the same DI. §11 of `amp-emulation-approaches.md` is the tuning table: every
hard-coded value with its plausible range, what to listen for, and a confidence flag, so iRig time
goes where it pays. Values are all in one table by design — say what sounds wrong and it is a
one-place fix.
