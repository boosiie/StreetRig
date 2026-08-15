# StreetRig AUv3 — Hands-on device & Mac guide (Phases 5–6)

**What this is:** the steps **you** run on real hardware to finish the AUv3 rollout — hear StreetRig
as a plugin in GarageBand on your **iPhone/iPad** (Phase 5), then validate and use it on your
**Mac/laptop** (Phase 6). These cannot run in the Simulator, which is why they were left for you.
Phases 1–4 (the plugin itself) are built and Simulator-verified.

Companion: `research/auv3-daw-linking-plan.md` (the design & rationale).

---

## Before you start

**Build state.** Phases 1–3 are committed (`2345558`); **Phase 4 (the editor UI) is uncommitted in
the working tree.** To deploy *with* the editor, build from the current tree — don't `git reset`
first, or you'll drop back to the Phase-2 placeholder view. Committing Phase 4 first is cleaner.

**You need:**
- A physical **iPhone or iPad on iOS/iPadOS 26.2+** (the deployment target), connected by cable.
- Your **iRig** (or any audio interface) for guitar input.
- A signing team already configured — the project uses **`HHM5CMKKMJ`** with automatic signing.
- For Phase 6: a **Mac with Xcode**.

**Identifiers (already in the project):**

| Thing | Value |
|---|---|
| App bundle id | `streetrig.StreetRig` |
| Extension bundle id | `streetrig.StreetRig.AUv3` |
| Framework bundle id | `streetrig.StreetRigEngine` |
| Team | `HHM5CMKKMJ` |
| AU identity (type/subtype/manufacturer) | `aufx` / `srds` / `Strg` |
| Xcode schemes | `StreetRig` (app), `StreetRig AUv3` (ext), `StreetRigEngine` (fmwk) |

**Known gap (by design):** the App-Group "**Load current rig from StreetRig**" hand-off is **not
wired yet** (deferred in Phase 4). The plugin is still fully usable — it has its own editor
(add/remove/swap gear) and factory/user presets. You just can't yet import a rig you built in the
standalone app; that's a small follow-up.

---

## Phase 5 — Hear it on your device

### 5.1 Deploy the app (this installs the extension)

The extension ships *inside* the app bundle (`StreetRig.app/PlugIns/StreetRig AUv3.appex`), so
installing the app registers the AU with iOS.

1. Open `StreetRig.xcodeproj` in Xcode; select the **`StreetRig`** scheme and your connected device.
2. For **all three targets** (app, `StreetRig AUv3`, `StreetRigEngine`): Signing & Capabilities →
   *Automatically manage signing* on, Team = `HHM5CMKKMJ`.
3. **Product → Run** (⌘R). This builds the framework + app + embedded extension and installs them.
4. **Launch the StreetRig app once** on the device so the OS registers the extension, then **fully
   quit it** (swipe it away) — you don't want the standalone app holding the audio session while a
   host uses the plugin.

### 5.2 First smoke test in AUM (recommended before GarageBand)

**AUM** (Audio Unit host, App Store) is the cleanest place to first confirm the plugin works — it
makes input → insert → output routing trivial and its AU handling is stricter/simpler than
GarageBand's.

1. In AUM: add an **input** channel (your iRig), add **StreetRig** as an **insert effect** on it
   (it appears under Audio-Unit effects, manufacturer **StreetRig / `Strg`**), route the channel to
   the **output**.
2. Play guitar → you should **hear the amp sim**. Tap the plugin to open its **editor UI** (try the
   compact and expanded sizes).
3. Turn a knob → the sound changes in real time.

If it works in AUM, the hard part is done.

### 5.3 GarageBand for iOS

1. New song → add a track fed by your iRig (an **Amp** or **Audio Recorder** track).
2. Open the track's **plug-in controls** (the track/mixer controls area), tap **Edit**, then **+**
   to add an **Audio Unit Extension**, and pick **StreetRig** (under *Audio Units*).
   *(The exact tap-path shifts between GarageBand versions — look for "Audio Units" in the plug-in
   picker.)*
3. Play → hear it; tap the plugin tile to open StreetRig's editor.

### 5.4 Device checklist (what "done" looks like)

- [ ] Plugin appears in the host's AU **effect** list (manufacturer `Strg`, name "StreetRig").
- [ ] Loads with no error; **passes audio** — you hear amp + cab (the default rig is amp+cab, **no
      pedals** until you add them or load a preset).
- [ ] The **editor UI renders** (compact + full) and is usable; knobs change the sound live.
- [ ] Load a **factory preset** (Clean Combo / British Crunch / High-Gain Stack) → sound changes.
- [ ] **Host automation:** record an automation lane on, e.g., *Amp · Drive* → on playback the sound
      changes and the on-screen knob follows.
- [ ] **Save the host project, reopen** → the whole rig recalls (topology + gear + knob values), not
      just gain.
- [ ] Plugin reports ~**2.7 ms** latency; multitrack stays time-aligned.

### 5.5 Troubleshooting

| Symptom | Fix |
|---|---|
| Plugin doesn't appear in the host | Relaunch the StreetRig app once; delete + reinstall the app (clears stale AU registration); **reboot the device** (iOS caches AU registration hard); confirm the `.appex` is embedded (Xcode → app target → *Frameworks, Libraries, and Embedded Content*). |
| "Failed to instantiate" / no sound | Check signing — the extension needs a valid profile under `HHM5CMKKMJ`; make sure the standalone StreetRig app is **force-quit** (audio-session contention). |
| Glitchy / distorted | Raise the host's buffer size (256 or 512). The neural amp has headroom, but device thermals/buffers matter. |
| Editor blank | Confirm you deployed the **current working tree** (Phase 4), not a reset-to-`2345558` build (that has the placeholder view). |

---

## Phase 6 — Into your laptop (Mac Catalyst + `auval`)

This is the literal "link the amp sim to your laptop" answer, and the only way to run Apple's
`auval` validator (macOS-only).

### 6.1 Enable Mac Catalyst (one-time — it's currently off)

In Xcode, for **both** the `StreetRig` app target **and** the `StreetRig AUv3` extension target:
**General → Supported Destinations → +  Mac (Mac Catalyst)** (equivalently `SUPPORTS_MACCATALYST =
YES`). The framework follows automatically. Re-check signing for the Mac destination under
`HHM5CMKKMJ`.

### 6.2 Build & register the AU on the Mac

1. Select the **"My Mac (Mac Catalyst)"** destination with the `StreetRig` scheme.
2. **Product → Run** once. Running the Catalyst app **registers the extension** with the Mac's Audio
   Unit system — this is the prerequisite for `auval` and for desktop DAWs to see it.

### 6.3 Validate with `auval` (the gold standard)

List all Audio Units and confirm StreetRig is present:

```bash
auval -a | grep -i streetrig
```

Run the full conformance suite (argument order is **type subtype manufacturer**):

```bash
auval -v aufx srds Strg
```

You want a final **`* PASS`**. `auval` exercises the parameter tree, state round-trip, rendering at
multiple sample rates and buffer sizes, the `[1,1]`/`[2,2]` channel configs, in-place rendering, and
latency reporting — all of which Phases 1–3 implemented, so it should come back clean. Any failure
it prints is specific (e.g., a channel-config or render-edge case) and becomes a targeted fix.

### 6.4 Use it in a desktop DAW

Open **Logic Pro** or **GarageBand for Mac**, add **StreetRig** as an insert on an audio track, feed
guitar through your Mac's interface, and run the same checks as §5.4 (audio, editor, automation,
save/recall).

### 6.5 Caveats

- Catalyst maps touch → mouse; the editor was built for touch, so expect minor interaction polish.
- The plan (`auv3-daw-linking-plan.md` §5.I/§8) always treated macOS as a **fast-follow with its own
  QA**, not a v1 gate — budget a little time for Catalyst-specific edge cases.

---

## If something fails

Capture the exact error (host message, `auval` output tail, or a screen recording) and hand it back
— each failure can become a focused fix. The most likely real work is in **Phase 6** (`auval` edge
cases, Catalyst UI), since Phases 1–4 are Simulator-clean and Phase 5 is mostly deployment +
listening.
