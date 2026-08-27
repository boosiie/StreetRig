# StreetRig — Professional UI Design Directions

Three competing visual directions for the iOS app, with the mechanism analysis behind them and a
literal, implementable token + control-kit spec for each.

**Status:** design spec only. No `.swift` file was modified in producing this document.
**Deployment target:** iOS 26.2, Swift 5 — every API named below is available unconditionally.
**Scope:** iOS app visual style. Landscape-only, dark-only. AR page (`ARPedalSetupView`, `ARFloor*`)
and the AUv3 plugin editor (`PluginEditorView`) are explicitly **out of scope**.

Published artifacts (one per direction) are linked in [Part 8](#part-8--published-artifacts).

---

## Part 0 — The diagnosis, measured

Numbers from the tree at `claude/music-app-professional-ui-dc1ec8`, not impressions.

| Symptom | Measurement | Command |
|---|---|---|
| No custom button styling exists | **33** `.buttonStyle(` call sites, **all** `.plain`. **Zero** `ButtonStyle` conformances. | `grep -rn "\.buttonStyle(" --include="*.swift" .` |
| No press state exists anywhere | **Zero** matches for `isPressed`, `ButtonStyle`, or a press-driven `@GestureState` | `grep -rn "isPressed\|ButtonStyle" --include="*.swift" .` |
| Haptics are nearly absent | **6** call sites app-wide, **none** on a button | see [0.1](#01-the-six-existing-haptic-sites) |
| Corner radii have no scale | **19 distinct values** in use: 0,1,2,3,4,5,6,7,8,9,10,12,13,14,16,18,22,24,40 | `grep -rhon "cornerRadius: [0-9]*"` |
| Touch targets below HIG minimum | 3 controls in `MainView.swift` alone (see [0.2](#02-touch-target-violations)) | — |

`.buttonStyle(.plain)` by file — this is the work queue:

| File | Count |
|---|---|
| `StreetRig/Views/ComponentDetailView.swift` | 10 |
| `StreetRig/Views/LibraryView.swift` | 5 |
| `StreetRig/Views/RigStageView.swift` | 3 |
| `StreetRig/Views/PreferencesView.swift` | 3 |
| `StreetRig/Views/ARPedalSetupView.swift` | 3 *(out of scope)* |
| `StreetRig/Views/ProfileView.swift` | 2 |
| `StreetRig/Views/Onboarding/SetupGuideView.swift` | 2 |
| `StreetRig/Views/Onboarding/CoachMarkOverlay.swift` | 2 |
| `StreetRig/Views/AvatarPickerView.swift` | 2 |
| `StreetRig/Views/DeviceOfferPrompt.swift` | 1 |

### 0.1 The six existing haptic sites

| File:line | Call | Note |
|---|---|---|
| `StreetRigEngine/UI/TapSlider.swift:111` | `.sensoryFeedback(.selection, trigger: jumps)` | correct; keep |
| `StreetRig/Views/GearCardView.swift:149` | `.sensoryFeedback(.impact(weight: .medium, intensity: 0.8), trigger: charged)` | hold-to-lift charge |
| `StreetRig/Views/ARPedalSetupView.swift:809` | same as above | out of scope |
| `StreetRig/Views/GearRemoval.swift:190` | `.sensoryFeedback(trigger: hot) { … .impact(flexibility: .rigid) }` | trash target arm |
| `StreetRig/Views/CameraStompDetector.swift:207` | `UINotificationFeedbackGenerator()` | out of scope |

**Convention to preserve:** `TapSlider.swift:19-21` documents a real constraint — files that ship
inside `StreetRigEngine` are also linked into the AUv3 extension, where a UIKit haptic engine is
unavailable. SwiftUI's `.sensoryFeedback` no-ops there instead of crashing. **All new haptics in
`StreetRigEngine/` MUST use `.sensoryFeedback`.** The `UIImpactFeedbackGenerator` styles named in
this spec are given as the *semantic* choice; the table in [Part 2.6](#26-haptics-map) gives the
`.sensoryFeedback` equivalent for each, which is what actually gets written.

### 0.2 Touch-target violations

HIG minimum is 44×44pt. This app is operated **while holding a guitar**, so the real target is larger.

| File:symbol | Current frame | Verdict |
|---|---|---|
| `MainView.swift` → `navArrow(systemName:target:)` | `.frame(width: 46, height: 30)` | **height fails** (30 < 44) |
| `MainView.swift` → `creditsButton` | `.frame(width: 34, height: 30)` | **both fail** |
| `MainView.swift` → immersive back button | `.frame(width: 34, height: 34)` | **both fail** *(AR page; fix anyway, it is shell code)* |

All three are inside the 50pt-tall `topNav`, which is why they were shrunk. The fix is not to grow
the bar — it is `.contentShape(Rectangle())` over a 44pt-tall hit area that **overhangs** the visual
bar, which costs zero layout height. Specified per direction below.

---

## Part 1 — What makes professional amp-sim UI read as professional

Mechanisms, not vibes. Drawn from Neural DSP Archetype, Positive Grid BIAS FX 2 / Spark, IK
AmpliTube 5, IK ToneX, Line 6 Helix Native, Fender Tone, Logic Pro Amp Designer, GarageBand's amp
view, and Apple's own Logic/Music iPad apps.

### 1.1 What a professional button actually does

A professional button is a **body with a rim**, lit by a scene light. Six states, each with a
specific mechanism:

**REST.** Two things, always: (a) a *bevel* — a 1pt rim that is light along the top edge and dark
along the bottom edge, which is what tells the eye the surface has thickness; (b) an *ambient drop
shadow*, `y` positive, `x` zero, which grounds it on the panel. The body fill is a vertical gradient
running light→dark top→bottom. That gradient must be shallow (8–14% luminance across the whole
run); a steep one reads as a 2011 web button.

**PRESSED.** The mechanism is **inversion of the light**, not a scale-down. Four simultaneous moves:
1. The bevel flips — dark at top, light at bottom. The rim is now a groove.
2. The body gradient flips — dark at top, light at bottom.
3. The ambient drop shadow *collapses* to near zero (radius and `y` → ~0). This is the single most
   important one: a button that keeps its shadow while pressed looks like it is sliding, not sinking.
4. The whole button translates **+1 to +2pt on y**, and the label goes with it.

Scale-down (`scaleEffect(0.96)`) is the cheap substitute. It reads as "the button shrank", not "the
button went in". Positive Grid uses scale; Neural DSP and Logic's Amp Designer do the light
inversion. The light inversion is what this spec calls for.

**Timing is asymmetric, and this is where most iOS apps give themselves away.** Press-down must be
effectively instant (0–80ms); release is slower (140–200ms, ease-out). A symmetric 200ms in both
directions feels mushy and disconnected from the finger. In SwiftUI, inside a `ButtonStyle`:

```swift
.animation(configuration.isPressed ? .easeOut(duration: 0.06)
                                   : .easeOut(duration: 0.18),
           value: configuration.isPressed)
```

**DISABLED.** Not `.opacity(0.4)` on the whole control — that greys the material and reads as
broken rendering. Professional apps *flatten* it back into the panel: remove the drop shadow
entirely, remove the bevel entirely, move the fill to the panel's own tone, and drop **only the
label** to 32–38%. The button stops being an object and becomes a printed area.

**ENGAGED / LATCHED.** This is the stompbox distinction and it is load-bearing for this app. A
footswitch is a **latch**, not a momentary tap. On real hardware the switch does *not* stay
depressed — an LED lights. So the correct model is: *momentary press geometry + persistent emissive
indicator*. When a pedal is engaged, the button returns to REST geometry and gains (a) a lit LED or
lit rim, and (b) a coloured ambient glow — a `.shadow` in the accent hue, not a border. Drawing
"engaged" as "permanently pressed-in" is wrong, and it also collides with the pressed state, so the
player cannot tell whether their finger is down.

**FOCUS.** A 2pt ring, offset 2pt outside the shape, in the accent — *in addition to* the rim, never
replacing it.

**HAPTICS.** The rule is that the haptic fires on **press-down**, not on release or on action
completion, because it is simulating the mechanical closing of the switch. Firing on release
decouples the sensation from the finger and is the most common iOS mistake. Weight maps to mass: a
footswitch latch is `.rigid` (sharp, high-frequency click), a normal tap is `.light`, a primary
commit is `.medium`, a segmented change is `.selection`.

### 1.2 How hierarchy is expressed without shouting

The hard case, and exactly StreetRig's case: everything is dark and textured, and the accent colour
is already spoken for (`amber` means *engaged*).

**Containment is the hierarchy channel, not colour.** A three-rung ladder that is orthogonal to the
tone ladder:

| Rung | Treatment | Example |
|---|---|---|
| Primary | the only **filled** element on the surface | PROCEED |
| Secondary | **raised but unfilled** — bevel + border, panel-tone body | Back, Cancel |
| Tertiary | **no container at all** — label only | Credits, Skip |

**One saturated fill per view, maximum.** Professional amp sims allow exactly one accent-filled
control on screen at a time. The moment there are two, neither is primary.

**Emission, not brightness.** On a dark ground the primary gets a *coloured ambient shadow in its
own hue* at low opacity, so it appears to emit light onto the panel around it. Nothing else on the
panel emits. This makes it unambiguously primary without being bigger or louder — and for this app
it is thematically exact: it is the tube glow.

**Size carries the rest.** The primary gets more *height* and heavier type, not a brighter colour.

**Destructive is not a red fill.** This is a real and common error. A red-filled Delete next to an
amber Save reads as two primaries competing. Professional practice: destructive is a **quiet**
control with red *label* and no fill; it becomes red-filled **only at the confirmation step**, when
it is the primary action of that moment.

### 1.3 How texture is used without becoming noise

**Grain scale is fixed in device pixels and does not scale with the element.** Real materials have a
fixed grain — a knob and a faceplate cut from the same aluminium share the same brush pitch. The
amateur look comes from scaling a texture to fit each element. One tile, one scale, applied globally.

**Opacity is 2–5%, and it modulates rather than covers.** Noise composited with `.overlay` or
`.softLight` blend modulates the luminance of what is underneath; noise composited `.normal` adds a
grey film and desaturates the whole palette. On a warm brown palette that difference is the entire
identity.

**Texture is deliberately absent in three places:** under small text, on the accent fill, and inside
the active region of meters. Under text the simplest correct treatment is a 1pt dark text shadow so
the label holds regardless of what grain lands behind it.

**Moiré at retina density comes from *scaling* the tile, not from the tile.** A 128×128 or 256×256
noise tile drawn at exactly 1:1 device pixels never beats against the pixel grid. Non-integer scale
factors do. The rule: generate once at `UIScreen.main.scale`, cache, draw at 1:1, tile.

**Directional texture must be continuous across the panel, not per-element.** Brushed metal that
restarts inside every button is the single clearest "skinned" giveaway. The brush belongs to the
*panel*; buttons are cut out of it and only get their own bevel.

### 1.4 Where the light comes from

Professional panels are lit from **one fixed direction — above, straight down or ~10–15° off
vertical.** The amateur look is per-element gradients pointing in different directions and drop
shadows with different `y` offsets and opacities.

One global light vector produces exactly three consequences, and they must be applied without
exception:

1. **Every convex bevel:** light line at top, dark line at bottom.
2. **Every drop shadow:** positive `y`, zero `x`, one shared opacity per elevation rung.
3. **Every specular highlight on a curved thing** (knob cap, LED dome, jewel light) sits at the same
   clock position — 11 to 12 o'clock.

**Concave things invert all three.** A groove, a recessed well, an unfilled slider track, a screen
cutout: dark line at *top*, light line at *bottom*, and an inner shadow instead of a drop shadow.
This inversion is what makes a groove read as cut *into* the panel rather than sitting *on* it, and
it is the mechanism that lets one palette express both "raised" and "recessed" without new colours.

`RigTheme.swift` already understands this distinction conceptually — `hairline` is documented as *"a
drawn RULE or groove … cut INTO a card, not stacked on it"*. What is missing is that it is drawn as
a single flat 1pt line rather than as the two-line inverted bevel that would make it read as a groove.

### 1.5 What StreetRig currently doesn't do — specifically

1. **Nothing on screen has a light direction.** `StreetRigEngine/UI/RigSurface.swift` draws
   `shape.strokeBorder(stroke, lineWidth: 1)` with a **single uniform colour on all four edges**.
   Every card in the app therefore has the same rim at top and bottom, which is the definition of an
   unlit surface. The tone ladder and the drop shadows are both correct; the missing piece is the
   gradient stroke. **This is the highest-leverage single fix in the codebase** — it is roughly ten
   lines in one file and it lights every card in the app at once.

2. **The app's most important button is its least finished element.**
   `StreetRig/Views/ControlPanelView.swift` → `engageButton`:

   ```swift
   Text(audio.isEngaged ? "STOP" : "PROCEED")
       .font(.system(size: 16, weight: .heavy))
       .tracking(1)
       .foregroundStyle(.black)
       .frame(maxWidth: .infinity, maxHeight: .infinity)
       .background(
           RoundedRectangle(cornerRadius: 12, style: .continuous)
               .fill(audio.isEngaged ? RigTheme.emberSoft : RigTheme.amber)
       )
   ```

   A flat fill. No gradient, no bevel, no drop shadow, no glow, no press state, no haptic.

3. **Elevation is real but invisible at the rim.** The three-rung ladder in `RigTheme.swift` is
   well-reasoned and the contrast ratios (1.25:1, 1.45:1) are deliberately small because
   `surfaceEdge` and `elevationShadow` were meant to carry the separation. `surfaceEdge` at
   `opacity(0.16)` uniform cannot carry it. The tone step is doing all the work and it was never
   designed to.

4. **The two most visible rules in the app use the exact scrim `RigTheme.swift` argues against.**
   `MainView.swift` `topNav` bottom rule and `CollectionTabView.swift` rail trailing rule are both
   `Rectangle().fill(Color.white.opacity(0.07))`. The palette file's central argument is that white
   scrims "desaturate straight to grey, which would cost Burnt Tan its whole identity". These two
   lines frame every screen.

5. **No type scale.** Sizes 8, 9, 10, 11, 13, 14, 15, 16 appear as raw `.system(size:)` *alongside*
   semantic styles `.caption2`, `.caption`, `.footnote`, `.title3`. Mixing the two means Dynamic Type
   scales some labels and not others, so the layout breaks unevenly at large text sizes.

6. **No texture anywhere.** Every surface in the app is a flat fill.

7. **`backgroundLift` (#251810) is a documented dead token** — `RigTheme.swift` says it is for "the
   top stop of the loading and panel gradients, and nothing else", and that filling a card with it
   was "the bug". It is a one-purpose token that reads like a rung. See disposition in
   [Part 6](#part-6--rigthemeswift-token-disposition).

---

## Part 2 — Shared foundations

Adopted by **all three** directions. These are not the differentiators; they are the floor.

### 2.1 The brown generator (hue discipline, satisfied by construction)

`RigTheme.swift` documents a real bug: the first cut of the elevation ladder ran G/R ≈ 0.78 at hue
31–35° and read as army khaki on a real phone. Every rung was re-cut to hue 19–27° with G/R ≈ 0.67.

Rather than hand-pick new browns and hope, both warm directions generate them from a rule derived
from the existing, known-good rungs. Solving `H = 60·(G−B)/(R−B)` for `H = 23°` with `G = 0.67·R`:

> **G = 0.67 · R, B = 0.465 · R**

Every warm neutral in Directions A and C is produced by this rule, so hue discipline is satisfied by
construction rather than by inspection.

Verification against the existing ladder:

| Token | Actual | Rule predicts | Hue | G/R |
|---|---|---|---|---|
| `background` #170F09 | R23 G15 B9 | G15 B11 | 26° | 0.652 |
| `surface` #33221A | R51 G34 B26 | G34 B24 | 19° | 0.667 |
| `surfaceRaised` #412C1F | R65 G44 B31 | G44 B30 | 23° | 0.677 |
| `amber` #E0661E | R224 G102 B30 | — | 22° | 0.455 |

Generated values used later in this document:

| R | Hex | Hue | G/R |
|---|---|---|---|
| 16 | `#100B07` | 27° | 0.688 |
| 18 | `#120C08` | 24° | 0.667 |
| 26 | `#1A110C` | 21° | 0.654 |
| 28 | `#1C130D` | 24° | 0.679 |
| 30 | `#1E140E` | 23° | 0.667 |
| 36 | `#241811` | 22° | 0.667 |
| 42 | `#2A1C14` | 22° | 0.667 |
| 58 | `#3A271B` | 23° | 0.672 |
| 76 | `#4C3323` | 23° | 0.671 |

### 2.2 The bevel — the one mechanism every direction needs

The missing primitive. A convex rim is a **gradient stroke**, not a solid one:

```swift
// CONVEX — sits ON the surface
.overlay {
    shape.strokeBorder(
        LinearGradient(colors: [rimLight, rimDark],
                       startPoint: .top, endPoint: .bottom),
        lineWidth: 1
    )
}
```

```swift
// CONCAVE — cut INTO the surface. Same stroke, reversed, plus an inner shadow.
.background {
    shape
        .fill(fill.shadow(.inner(color: .black.opacity(0.55), radius: 3, y: 2)))
}
.overlay {
    shape.strokeBorder(
        LinearGradient(colors: [rimDark, rimLight],
                       startPoint: .top, endPoint: .bottom),
        lineWidth: 1
    )
}
```

`ShapeStyle.shadow(.inner(…))` is iOS 16+; the deployment target is 26.2, so it is available with no
availability check. This is what lets a groove be drawn without a mask-and-blur hack.

### 2.3 Type scale

One scale, used by all three directions; only the weights and tracking differ per direction. All
sizes are `.system(size:weight:)` with an explicit `Font.TextStyle` relative baseline via
`.system(size:weight:design:)` + `@ScaledMetric` where Dynamic Type must apply.

| Role | Size | Tracking | Use |
|---|---|---|---|
| `display` | 34pt | −0.5 | splash wordmark only |
| `title` | 20pt | 0 | onboarding step title, detail item name |
| `heading` | 16pt | +0.5 | primary button label, section titles |
| `body` | 14pt | 0 | onboarding paragraphs, list rows |
| `label` | 13pt | +0.3 | secondary button labels, field text |
| `caption` | 11pt | +1.2 | zone captions (INPUT/OUTPUT/MASTER), status |
| `micro` | 10pt | +1.5 | rail section headers, silkscreen legends |
| `nano` | 8pt | +0.8 | "HOLD TO PLACE" — the smallest permitted size |

**Rule:** nothing below 8pt, ever. `CollectionTabView.swift` already sits at the floor with
`.system(size: 8, weight: .medium)`.

### 2.4 Spacing scale

4pt base. `2, 4, 6, 8, 12, 16, 20, 24, 32, 40`. Nothing off-scale. Existing off-scale values to
correct: `PanelMetrics.rowGap = 6` (on scale, keep), `.padding(.horizontal, 14)` in
`CollectionTabView` → 12 or 16, `.padding(.top, 14)` → 16.

### 2.5 Touch targets

| Control | Minimum visual | Minimum hit area |
|---|---|---|
| Primary action | 48×120 | 48×120 |
| Secondary / icon | 40×40 | **44×44** via `.contentShape` |
| Footswitch latch | 56×56 | 56×56 |
| Segmented segment | 36 tall | **44** tall via `.contentShape` |
| Chip | 32 tall | **44** tall via `.contentShape` |
| Nav arrow / credits | as drawn | **44×44** via `.contentShape`, overhanging the bar |

The overhang pattern for the `topNav` violations in [0.2](#02-touch-target-violations), which costs
zero layout height:

```swift
Image(systemName: systemName)
    .frame(width: 46, height: 30)          // visual, unchanged
    .contentShape(Rectangle().inset(by: -7)) // 44pt hit area, overhangs the bar
```

### 2.6 Haptics map

Fires on **press-down**. `StreetRigEngine/` files must use the `.sensoryFeedback` column (AUv3
safety — see [0.1](#01-the-six-existing-haptic-sites)).

| Control / event | Semantic (UIKit) | `.sensoryFeedback` equivalent |
|---|---|---|
| Primary action press | `UIImpactFeedbackGenerator(style: .medium)` | `.impact(weight: .medium, intensity: 0.9)` |
| Secondary action press | `.light` | `.impact(weight: .light, intensity: 0.7)` |
| Icon button press | `.light` | `.impact(weight: .light, intensity: 0.6)` |
| **Footswitch latch ON** | `.rigid` | `.impact(flexibility: .rigid, intensity: 1.0)` |
| **Footswitch latch OFF** | `.soft` | `.impact(flexibility: .soft, intensity: 0.7)` |
| Segmented change | `UISelectionFeedbackGenerator` | `.selection` |
| Chip toggle | `.light` | `.impact(weight: .light, intensity: 0.6)` |
| Slider detent | — | `.selection` *(already implemented, `TapSlider.swift:111`)* |
| Destructive **confirm** | `UINotificationFeedbackGenerator(.warning)` | `.warning` |
| Engine engaged (PROCEED lands) | `UINotificationFeedbackGenerator(.success)` | `.success` |
| Tertiary / text field | none | none |

### 2.7 Motion

| Event | Curve | Duration |
|---|---|---|
| Button press-down | `.easeOut` | 0.06s |
| Button release | `.easeOut` | 0.18s |
| Latch engage/disengage | `.spring(response: 0.28, dampingFraction: 0.7)` | — |
| Segmented selection slide | `.spring(response: 0.32, dampingFraction: 0.85)` | — |
| Page change (existing) | `.easeInOut` | 0.28s — **keep**, `MainView.swift` |
| Detail overlay (existing) | `.easeInOut` | 0.25s — **keep**, `MainView.swift` |
| Glow ramp on engage | `.easeOut` | 0.22s |

**Reduced motion:** gate every `scaleEffect` and every translation on
`@Environment(\.accessibilityReduceMotion)`. Colour and shadow transitions stay — they are not
motion. The light-inversion press state therefore still works fully under Reduce Motion, which is
another argument for it over `scaleEffect`.

### 2.8 The noise primitive — one implementation, three tunings

Every direction needs cached procedural grain. One shared helper, generated once, held for the
process lifetime:

```swift
enum RigNoise {
    /// Generated ONCE at device scale, cached for the process lifetime, drawn 1:1
    /// and tiled. Never scaled — a non-integer scale factor is what produces moiré
    /// at retina density (see Part 1.3).
    static let fine: Image = make(size: 128, coarse: false)
    static let brushed: Image = make(size: 256, coarse: true)   // anisotropic

    private static func make(size: CGFloat, coarse: Bool) -> Image {
        let renderer = ImageRenderer(content:
            Canvas { ctx, sz in
                var rng = SeededGenerator(seed: 0x5721)   // fixed seed = reproducible
                // …fill with per-pixel alpha, or 1pt horizontal streaks when `coarse`
            }
            .frame(width: size, height: size)
        )
        renderer.scale = UIScreen.main.scale
        return Image(uiImage: renderer.uiImage ?? UIImage())
    }
}
```

Applied as:

```swift
.overlay {
    RigNoise.fine
        .resizable(resizingMode: .tile)
        .blendMode(.overlay)          // modulates luminance; NOT .normal
        .opacity(0.035)
        .allowsHitTesting(false)
}
```

**Runtime cost — this matters, there is a live audio graph on the same device.**

| Concern | Ruling |
|---|---|
| Generation | Once per process. ~4ms for a 256×256 tile at 3×. Do it lazily on first use, never per frame. |
| Per-frame | Tiling a cached `Image` is a single GPU draw. Negligible. |
| **Forbidden** | A `Canvas` that regenerates noise inside `body`. On the rig stage (SceneKit, 60fps) or the play page this competes with the render thread and will produce audio dropouts. |
| `.blendMode(.overlay)` | Forces an offscreen compositing pass. Fine on static panels. **Do not** put it on a view that animates every frame — put it on the static backdrop underneath instead. |
| Rig stage | `RigStageView`/`RigStage3DView` is SceneKit. Texture belongs on the SceneKit materials or on the surrounding SwiftUI chrome — **not** as a SwiftUI overlay on top of the live 3D view. |

---

## Part 3 — Direction A: **Tolex & Brass**

> **Thesis.** The app is a piece of gear you own. The screen is the amp's own faceplate, and the
> chrome is made of something: black tolex over ply, a cream control plate, brass piping, and the
> ember accent as the tube glow behind it. It is the warmest and most literal of the three, and it
> argues that a guitarist's tool should feel like it was built in a workshop rather than compiled.

**Disagreement it stakes out:** the shell should be *material*. Maximum chrome, loosest density,
largest touch targets, hard light from directly overhead.

### 3.1 Palette

Keeps `RigTheme.background` unchanged — it is already correct — and re-cuts the surfaces.

| Token | Hex | R,G,B | Hue | G/R | Role |
|---|---|---|---|---|---|
| `page` *(= existing `background`)* | `#170F09` | 23,15,9 | 26° | 0.652 | the floor. **unchanged** |
| `grille` | `#100B07` | 16,11,7 | 27° | 0.688 | speaker-cloth recess, below the page |
| `tolexBody` | `#1C130D` | 28,19,13 | 24° | 0.679 | CARD rung — takes the weave texture |
| `tolexRaised` | `#2A1C14` | 42,28,20 | 22° | 0.667 | RAISED rung — controls on a card |
| `tolexHigh` | `#3A271B` | 58,39,27 | 23° | 0.672 | **new 4th rung** — button bodies only |
| `rimLight` | `#6B4A33` @ 0.85 | 107,74,51 | 24° | 0.692 | top edge of every convex bevel |
| `rimDark` | `#0A0705` @ 0.90 | 10,7,5 | 24° | 0.700 | bottom edge of every convex bevel |
| `faceplate` *(= existing `panel`)* | `#EADFC4` | 234,223,196 | 43° | 0.953 | cream control plate. **unchanged** |
| `faceplateShade` | `#D6C9A8` | 214,201,168 | 43° | 0.939 | bottom stop of the plate gradient |
| `brass` *(= existing `trim`)* | `#C9A24B` | 201,162,75 | 41° | 0.806 | piping. **unchanged** |
| `brassLit` | `#E4C27A` | 228,194,122 | 41° | 0.851 | lit top edge of brass piping |
| `brassDark` | `#8A6A28` | 138,106,40 | 40° | 0.768 | shadowed bottom edge of piping |
| `amber` *(unchanged)* | `#E0661E` | 224,102,30 | 22° | 0.455 | engaged / primary / tube glow |
| `amberLit` | `#F08A3A` | 240,138,58 | 22° | 0.575 | top stop of the primary fill gradient |
| `amberDeep` | `#B04E14` | 176,78,20 | 22° | 0.443 | bottom stop + pressed body |
| `amberSkirt` | `#7A3410` | 122,52,16 | 20° | 0.426 | the 2pt "wall" under a resting primary |
| `textPrimary` *(unchanged)* | `#F4ECDA` | 244,236,218 | 41° | 0.967 | — |
| `textMuted` *(unchanged)* | `#B0A188` | 176,161,136 | 37° | 0.915 | — |
| `textOnPlate` | `#2A1C14` | 42,28,20 | 22° | 0.667 | type printed on the cream plate |
| `signal` / `clip` / `ready` *(unchanged)* | `#5AA981` / `#CF4A32` / `#52D37A` | — | — | — | meter LEDs, AR ready |

**Elevation:** this direction **adds a fourth rung** (`tolexHigh`, button bodies only) and says so
plainly. `RigSurface.swift`'s header warns that `lifted:` deepens the shadow "so the tone ladder
stays three steps instead of quietly growing a fourth". Tolex & Brass grows one on purpose: with a
gradient bevel now doing the separating, a fourth tone step is legible where previously it would not
have been, and a button needs to sit above the chip next to it. The reasoning in that file should be
amended, not deleted.

### 3.2 Geometry

| Property | Value |
|---|---|
| Radii | `4, 8, 12, 16, 20` — `.continuous` everywhere. Amp corners are radiused, so this is the softest of the three. |
| Primary button | 52pt tall, 16pt radius |
| Secondary button | 44pt tall, 12pt radius |
| Icon button | 44×44, 12pt radius |
| Footswitch latch | 64×64, 16pt radius |
| Chip | 32pt tall (44pt hit), capsule |
| Segmented | 44pt tall, 12pt outer / 8pt inner |
| Card | 16pt |
| Text field | 40pt tall, 8pt radius, **concave** |
| Rail width | 150pt *(unchanged)* |
| Control panel height | 77pt *(unchanged)* — but the top 3pt become the brass piping |

### 3.3 Materials, as SwiftUI

**Tolex weave** (the card/body surface). Two crossed high-frequency gradients over the base tone,
plus fine grain. Cached — this is a static backdrop.

```swift
RoundedRectangle(cornerRadius: 16, style: .continuous)
    .fill(RigTheme.tolexBody)
    .overlay {
        // weave: two 45° repeating stripes, 3pt pitch, crossed
        LinearGradient(stops: [.init(color: .white.opacity(0.030), location: 0.0),
                               .init(color: .clear,                location: 0.5)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
        .blendMode(.overlay)
    }
    .overlay { RigNoise.fine.resizable(resizingMode: .tile)
                 .blendMode(.overlay).opacity(0.045) }
```

**Cream faceplate band** (top nav + control panel background). This is the direction's signature.

```swift
LinearGradient(colors: [RigTheme.faceplate, RigTheme.faceplateShade],
               startPoint: .top, endPoint: .bottom)
    .overlay(alignment: .top) {          // brass piping, lit on top
        LinearGradient(colors: [RigTheme.brassLit, RigTheme.brass, RigTheme.brassDark],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: 3)
    }
    .overlay { RigNoise.fine.resizable(resizingMode: .tile)
                 .blendMode(.multiply).opacity(0.030) }   // multiply on a LIGHT surface
```

Note the blend-mode switch: `.overlay` on dark surfaces, `.multiply` on the cream plate. `.overlay`
on a near-white surface does almost nothing.

**Primary button body** (resting):

```swift
RoundedRectangle(cornerRadius: 16, style: .continuous)
    .fill(LinearGradient(stops: [.init(color: RigTheme.amberLit,  location: 0.00),
                                 .init(color: RigTheme.amber,     location: 0.45),
                                 .init(color: RigTheme.amberDeep, location: 1.00)],
                         startPoint: .top, endPoint: .bottom))
    .shadow(color: RigTheme.amberSkirt, radius: 0, y: 2)        // the wall
    .shadow(color: .black.opacity(0.55), radius: 10, y: 5)      // ambient
    .shadow(color: RigTheme.amber.opacity(0.30), radius: 18, y: 4) // tube glow
    .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous)
                 .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .black.opacity(0.30)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1) }
```

**Light direction:** straight down, 0° off vertical. Every drop shadow `x = 0`, `y > 0`. Every
specular at 12 o'clock.

### 3.4 Control-kit state spec

State transforms are shared across all controls in this direction — that is what makes it a system.

| State | Body gradient | Bevel | Drop shadow | Offset | Label |
|---|---|---|---|---|---|
| **Rest** | light→dark, top→bottom | white .45 → black .30 | skirt 0/y2 + ambient 10/y5 | 0 | 100% |
| **Pressed** | dark→light, top→bottom *(flipped)* | black .40 → white .22 *(flipped)* | skirt **removed**, ambient → radius 3 / y 1 | **y +2** | 100% |
| **Engaged** | rest gradient | rest bevel + `amber` .55 inner ring 1pt | rest + glow radius 22 / opacity 0.42 | 0 | 100% |
| **Disabled** | **flat** `tolexRaised`, no gradient | **none** | **none** | 0 | 34% |

Per control:

| Control | Rest body | Engaged indicator | Notes |
|---|---|---|---|
| Primary (`PROCEED`) | amber gradient + skirt + glow | — *(it is not a latch)* | 52pt tall. On engage becomes `STOP` in `emberSoft` `#E68044`. Haptic `.medium` down, `.success` on engine start. |
| Secondary (`Back`, `Cancel`) | `tolexHigh` gradient | — | 44pt, no glow, no skirt |
| Destructive (`Remove`) | **no fill**, 1pt `clip` @0.55 border | — | label `clip` `#CF4A32`. Fills `clip` **only** in the confirm sheet. Haptic `.warning` on confirm. |
| Quiet / tertiary (`Skip`, credits) | **no container** | — | label `textMuted`, 44pt hit area |
| Icon button | `tolexHigh` gradient, 12pt radius | — | 44×44 |
| **Footswitch latch** | `tolexHigh` gradient, 64×64 | **LED**: 8pt `Circle` `amber`, `.shadow(color: amber, radius: 6)`, + body glow radius 22 @0.42 | Press geometry is **momentary**; the LED is what latches. Haptic `.rigid` on, `.soft` off. |
| Segmented (`Amp`/`Pedal`, `LEVELS`/`FX`/`CHANNELS`) | **concave** well `grille` + inner shadow; selected thumb `tolexHigh` convex | thumb slides `.spring(0.32, 0.85)` | Well is concave (inverted bevel); thumb is convex. Haptic `.selection`. |
| Chip / tag (category filters) | `tolexRaised` capsule, 1pt bevel | selected: `amber` @0.18 fill + `amber` @0.70 border + label `amber` | 32pt visual / 44pt hit |
| Slider track (`TapSlider`) | **concave** groove `hairline` `#4A3320` + inner shadow | filled portion `amber`→`clip` mix *(existing `masterTint` logic — keep)* | Thumb gains a 12 o'clock specular. Existing `.selection` haptic kept. |
| Text field (search, name) | **concave** `grille` + inner shadow radius 3 y 2, inverted bevel | focus: 2pt `amber` ring, offset 2pt | 40pt tall |

### 3.5 What this direction gives up

The cream band is 50pt of top nav plus 77pt of control panel out of a **390pt-tall** landscape
screen — 33% of the vertical budget rendered in near-white on a dark-adapted stage. In a dim room
that is a lot of glare aimed at someone reading their pedalboard. Mitigation, if chosen: drop the
plate to `faceplateShade` `#D6C9A8` as the top stop and add a 30% scrim, or reserve the cream for
the control panel only and leave the top nav dark.

---

## Part 4 — Direction B: **Rack Unit**

> **Thesis.** The app is a piece of studio equipment, not a stage instrument. A 19" rack face:
> anodised aluminium, machined edges, screen-printed micro-legends, and the tightest density of the
> three. It argues that the ground should be *neutral* so the gear's own colour is the only colour —
> and that a player who owns 47 pedals needs to see more of them at once, not fewer and prettier.

**Disagreement it stakes out:** the neutrals should be **cool**, and this is the direction that
breaks with "Burnt Tan" outright. Medium chrome, tightest density, raking light from 15° off vertical.

### 4.1 Palette — and an explicit argument against the hue rule

`RigTheme.swift`'s hue discipline exists to stop warm browns drifting to army khaki. **Rack Unit
does not satisfy that rule; it removes the failure mode instead.** Its surfaces are cool neutrals at
hue 210–213° with **B > G > R** — the deliberate inverse of the ladder's `R > G > B` invariant. A
cool grey cannot drift to khaki, because khaki drift is a warm-desaturated-neighbour effect: the eye
pushes a desaturated warm surface further green when a saturated orange sits next to it. Put the
surface in a *complementary* family instead and the interaction disappears.

**What this costs, stated plainly:** `panel` (cream) and `trim` (brass) are **retired** in this
direction — nothing on screen is warm except `amber` and the gear's own paint. "Burnt Tan" as an
identity does not survive. What is bought: `amber` becomes the only warm thing on screen, so it
reads *louder while being used less*, and the 47 pedals' real finishes (`PedalFinish.swift` —
Tube Screamer green, Big Muff white, RAT black, Phase 90 orange) sit on a neutral ground that does
not tint them.

| Token | Hex | R,G,B | Hue | Role |
|---|---|---|---|---|
| `rackVoid` | `#0E1012` | 14,16,18 | 210° | PAGE — the floor |
| `chassis` | `#1A1D21` | 26,29,33 | 210° | CARD rung — the rack face |
| `chassisRaised` | `#24282D` | 36,40,45 | 212° | RAISED rung |
| `anodise` | `#2E3339` | 46,51,57 | 213° | button body base |
| `brushLit` | `#3C424A` | 60,66,74 | 213° | top stop of the brushed gradient |
| `brushDark` | `#16181B` | 22,24,27 | 213° | bottom stop / groove floor |
| `rimLight` | `#565E68` @ 0.90 | 86,94,104 | 212° | top edge, convex bevel |
| `rimDark` | `#08090A` @ 0.95 | 8,9,10 | 210° | bottom edge, convex bevel |
| `machinedEdge` | `#7C8792` | 124,135,146 | 209° | 1pt chamfer on a machined corner |
| `silkscreen` | `#8A939C` | 138,147,156 | 210° | screen-printed micro-legends |
| `silkscreenDim` | `#5C646C` | 92,100,108 | 210° | secondary legends |
| `textPrimary` | `#D6DCE2` | 214,220,226 | 210° | replaces `#F4ECDA` |
| `textMuted` | `#8A939C` | 138,147,156 | 210° | replaces `#B0A188` |
| `amber` *(unchanged)* | `#E0661E` | 224,102,30 | 22° | engaged / primary / the only warm thing |
| `amberLit` | `#F5813B` | 245,129,59 | 22° | top stop of primary fill |
| `amberDeep` | `#A8480F` | 168,72,15 | 22° | bottom stop / pressed |
| `signal` / `clip` / `ready` *(unchanged)* | `#5AA981` / `#CF4A32` / `#52D37A` | — | — | meter LEDs, AR ready |

**Elevation:** the three-rung ladder is **kept in structure but re-based to cool**. Contrast against
`rackVoid`: `chassis` 1.32:1, `chassisRaised` 1.58:1 — wider than the warm ladder's 1.25:1/1.45:1 by
+0.07 and +0.13 respectively, because a cool neutral reads flatter than a warm one at equal luminance
and needs the extra step. No fourth rung.

### 4.2 Geometry — machined, near-square

| Property | Value |
|---|---|
| Radii | `2, 3, 4, 6, 8` — `.continuous`. Deliberately the tightest of the three: machined aluminium has a chamfer, not a fillet. |
| Primary button | 44pt tall, 4pt radius |
| Secondary button | 40pt tall (44 hit), 4pt radius |
| Icon button | 40×40 (44 hit), 3pt radius |
| Footswitch latch | 56×56, 4pt radius |
| Chip | 26pt tall (44 hit), 3pt radius — **not** a capsule |
| Segmented | 36pt tall (44 hit), 4pt outer / 2pt inner |
| Card | 6pt |
| Text field | 34pt tall, 3pt radius, concave |
| Rail width | **132pt** (from 150) — the density argument, reclaims 18pt for the centre |
| Control panel height | **68pt** (from 77) — `PanelMetrics.body` 41→36, `vPadding` 8→6 |

### 4.3 Materials, as SwiftUI

**Brushed aluminium** — anisotropic, and **continuous across the panel, never per-button** (see
[1.3](#13-how-texture-is-used-without-becoming-noise)). The brush belongs to the chassis; buttons
are cut out of it.

```swift
// On the PANEL, once. Buttons draw only their bevel on top.
Rectangle()
    .fill(LinearGradient(colors: [RigTheme.brushLit, RigTheme.anodise, RigTheme.brushDark],
                         startPoint: .top, endPoint: .bottom))
    .overlay {
        RigNoise.brushed                    // 256×256, 1pt HORIZONTAL streaks only
            .resizable(resizingMode: .tile)
            .blendMode(.overlay)
            .opacity(0.055)
    }
```

`RigNoise.brushed` is the anisotropic tuning from [2.8](#28-the-noise-primitive--one-implementation-three-tunings):
1pt horizontal lines at random alpha 0.0–1.0, no vertical variation. That is what makes it read as
brushed rather than as sandblasted.

**Machined chamfer** — the direction's signature detail. A 1pt bright line on the *top and left*
edges only (light is raking from 15°, i.e. top-left):

```swift
.overlay {
    RoundedRectangle(cornerRadius: 4, style: .continuous)
        .strokeBorder(LinearGradient(stops: [.init(color: RigTheme.machinedEdge.opacity(0.55), location: 0.00),
                                             .init(color: RigTheme.rimLight.opacity(0.30),     location: 0.25),
                                             .init(color: RigTheme.rimDark,                    location: 1.00)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing),
                      lineWidth: 1)
}
```

**Screen-printed legend** — micro-labels under every control, 10pt/`+1.5` tracking in `silkscreen`
`#8A939C`, `.medium` weight. This is the direction's density move: because every control is
labelled, controls themselves can be smaller and unlabelled internally.

**Light direction:** raking, 15° off vertical, from top-left. Every drop shadow `x = 1, y = 3`.
Every specular at 11 o'clock. (Consistently — this is the whole point of [1.4](#14-where-the-light-comes-from).)

### 4.4 Control-kit state spec

| State | Body gradient | Chamfer | Drop shadow | Offset | Label |
|---|---|---|---|---|---|
| **Rest** | `brushLit`→`anodise`→`brushDark` | top-left bright, bottom-right dark | `black .50, r 6, x 1, y 3` | 0 | `textPrimary` |
| **Pressed** | flipped: `brushDark`→`anodise` | flipped: top-left dark, bottom-right bright | → `r 2, x 0, y 1` | **y +1** | `textPrimary` |
| **Engaged** | rest | rest + `amber` @0.60 1pt inner ring | rest + `amber` glow `r 14, opacity 0.35` | 0 | `amber` |
| **Disabled** | **flat** `chassis` | **none** | **none** | 0 | `silkscreenDim` @ 60% |

Per control — differences from Direction A only:

| Control | Rack Unit treatment |
|---|---|
| Primary (`PROCEED`) | 44pt tall, 4pt radius, amber gradient. **No skirt** — a machined face has no proud wall. Glow radius 14 (tighter than Tolex's 18). |
| Secondary | `anodise` gradient, 40pt, silkscreen legend beneath |
| Destructive | `clip` 1pt border, no fill, `clip` label. Confirm step fills `clip`. |
| Quiet / tertiary | label only in `silkscreen`, 44pt hit |
| Icon button | 40×40, 3pt radius, brushed |
| **Footswitch latch** | 56×56. Indicator is a **rectangular 10×3pt LED bar**, not a round dome — rack gear uses bar indicators. `amber`, `.shadow(color: amber, radius: 5)`. Haptic `.rigid`/`.soft`. |
| Segmented | 36pt, 4pt outer / 2pt inner. Well is a **milled recess**: `brushDark` + inner shadow r 3 y 2. Thumb `anodise` + chamfer. |
| Chip | 26pt, **3pt radius rectangle** — the clearest visual break from Tolex's capsule |
| Slider track | 4pt groove (from 6pt) — tighter. `brushDark` + inner shadow. Thumb is a **6×16pt vertical bar with a centre score line**, not a circle: a console fader cap. |
| Text field | 34pt, 3pt radius, `brushDark` concave, `silkscreen` placeholder |

### 4.5 What this direction gives up

"Burnt Tan" as a brand. The warm espresso/cream/brass identity documented at length in
`RigTheme.swift` is retired wholesale, and the reasoning in that file becomes historical rather than
current. It also runs the tightest type in the app (10pt silkscreen legends) on a device operated at
arm's length by someone holding a guitar — the density that makes it feel professional on a desk is
the density that makes it hard to read on a strap. If chosen, the 10pt legend floor should be
re-tested at standing distance before it ships.

---

## Part 5 — Direction C: **House Lights**

> **Thesis.** The house lights go down and only the rig is lit. The app is not a piece of gear — it
> is the dark room the gear stands in. Chrome recedes to almost nothing: no faceplate, no chassis,
> no visible container. Texture is reserved *entirely* for the gear itself, and the only light in
> the room comes from the gear's own indicators. It is the closest to Apple-native, and it argues
> that in an app whose content is 47 beautifully-photographed pedals, the UI's job is to disappear.

**Disagreement it stakes out:** the shell should be made of **nothing**. Minimum chrome, ambient
light rather than directional, elevation carried by shadow and glow instead of tone.

### 5.1 Palette

Warm-neutral near-black, generated by the same rule as Direction A ([2.1](#21-the-brown-generator-hue-discipline-satisfied-by-construction)),
but with the rungs deliberately **compressed**.

| Token | Hex | R,G,B | Hue | G/R | Role |
|---|---|---|---|---|---|
| `houseBlack` | `#120C08` | 18,12,8 | 24° | 0.667 | PAGE — deeper than today's `#170F09` |
| `veil` | `#1A110C` | 26,17,12 | 21° | 0.654 | CARD rung — 1.14:1, deliberately faint |
| `veilRaised` | `#241811` | 36,24,17 | 22° | 0.667 | RAISED rung — 1.26:1 |
| `rimLight` | `#F4ECDA` @ 0.10 | — | — | — | top rim. **Cream at low alpha, not white** |
| `rimDark` | `#000000` @ 0.55 | — | — | — | bottom rim |
| `hairline` *(unchanged)* | `#4A3320` | 74,51,32 | 27° | 0.689 | grooves, unlit meter segments |
| `amber` *(unchanged)* | `#E0661E` | 224,102,30 | 22° | 0.455 | engaged / primary / the only colour on screen |
| `amberLit` | `#EE7A2C` | 238,122,44 | 24° | 0.513 | top stop of primary fill |
| `amberDeep` | `#BB5417` | 187,84,23 | 22° | 0.449 | bottom stop / pressed |
| `textPrimary` *(unchanged)* | `#F4ECDA` | 244,236,218 | 41° | 0.967 | — |
| `textMuted` *(unchanged)* | `#B0A188` | 176,161,136 | 37° | 0.915 | — |
| `textFaint` | `#6E6154` | 110,97,84 | 30° | 0.882 | tertiary / disabled labels |
| `signal` / `clip` / `ready` *(unchanged)* | `#5AA981` / `#CF4A32` / `#52D37A` | — | — | — | meter LEDs, AR ready |

**Elevation — this direction explicitly supersedes the mechanism.** `RigTheme.swift` separates rungs
by tone (1.25:1 and 1.45:1) backed by an edge and a shadow. House Lights **compresses the tone steps
to 1.14:1 and 1.26:1** and moves the separating work onto two other channels:

1. A **top-only rim light** — `rimLight` on the top edge only, fading to nothing by 40% down the
   shape. Not a full border. This is the "ambient light from above the stage" cue.
2. A **wider, softer ambient shadow** — radius 18 / y 8 for cards (vs. `RigSurface`'s 9 / y 4).

The argument: the existing ladder's own comment concedes *"the numbers are small on purpose… Tone
alone was never going to carry it."* House Lights takes that further — if tone is not carrying it,
stop spending contrast on tone and spend it on shadow, where the effect is real on a near-black
ground. **Risk, stated:** `RigSurface.swift` warns that on a near-black ground "a deeper shadow is
close to invisible, so it cannot carry a distinction on its own." That warning applies directly to
this direction and is its principal technical risk. It is mitigated by the rim light doing the
outline work, but it must be verified on a real device in a dim room before committing.

### 5.2 Geometry

| Property | Value |
|---|---|
| Radii | `6, 10, 14, 20, 999` — capsules used freely. Softest, most Apple-native of the three. |
| Primary button | 50pt tall, **capsule** |
| Secondary button | 44pt tall, capsule |
| Icon button | 44×44, circle |
| Footswitch latch | 60×60, 20pt radius |
| Chip | 34pt tall (44 hit), capsule |
| Segmented | 40pt tall (44 hit), capsule outer / capsule inner |
| Card | 14pt |
| Text field | 40pt tall, capsule, concave |
| Rail width | **140pt** (from 150), and **no background fill** — the rail is a hairline and a column of cards |
| Control panel height | 77pt *(unchanged)*, **no background fill** — a hairline and the controls, over the page |

### 5.3 Materials, as SwiftUI

The point of this direction is how *little* material there is.

**Cards** — no texture at all:

```swift
RoundedRectangle(cornerRadius: 14, style: .continuous)
    .fill(RigTheme.veil)
    .shadow(color: .black.opacity(0.62), radius: 18, y: 8)
    .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
                LinearGradient(stops: [.init(color: RigTheme.rimLight, location: 0.00),
                                       .init(color: .clear,            location: 0.40)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
    }
```

Note the stroke fades to `.clear` by 40% — there is **no bottom rim**. That asymmetry is what
produces "lit from above by a soft ambient source" rather than "outlined".

**Grain** — the *only* place noise appears is a whole-page atmospheric vignette, drawn once behind
everything, at half the opacity of the other two directions:

```swift
RigTheme.houseBlack
    .overlay {
        RadialGradient(colors: [.clear, .black.opacity(0.45)],
                       center: .center, startRadius: 200, endRadius: 620)
    }
    .overlay {
        RigNoise.fine.resizable(resizingMode: .tile)
            .blendMode(.overlay).opacity(0.018)     // half of Tolex's 0.045
    }
    .ignoresSafeArea()
```

**The gear is the hero.** Pedal art (`GearArt.swift` / the shipped `Assets.xcassets` icons) gets a
warm **contact shadow** and a floor reflection, which is where all the visual richness goes:

```swift
GearArtView(item: item)
    .shadow(color: .black.opacity(0.70), radius: 10, y: 6)   // contact
    .background(alignment: .bottom) {
        Ellipse().fill(RadialGradient(colors: [RigTheme.amber.opacity(0.10), .clear],
                                      center: .center, startRadius: 0, endRadius: 60))
            .frame(height: 22).blur(radius: 8).offset(y: 8)
    }
```

**Light direction:** ambient from above, no single hard source. Drop shadows `x = 0, y` positive and
large. Specular highlights are broad and soft rather than a point — a 12 o'clock highlight at 30%
opacity spread over 40% of the curve, not a 10% dot.

### 5.4 Control-kit state spec

| State | Body | Rim | Drop shadow | Scale/offset | Label |
|---|---|---|---|---|---|
| **Rest** | `veilRaised` flat *(no gradient)* | top-only `rimLight`, fade to clear @40% | `black .55, r 10, y 4` | 0 | `textPrimary` |
| **Pressed** | `veilRaised` → `houseBlack` (darkens 22%) | rim **removed** | → `r 2, y 1` | **y +1** | `textPrimary` |
| **Engaged** | `amber` @0.16 fill | full `amber` @0.55 rim, all four edges | rest + `amber` glow `r 20, opacity 0.38` | 0 | `amber` |
| **Disabled** | `veil` flat | **none** | **none** | 0 | `textFaint` `#6E6154` |

House Lights is the one direction where the pressed state is a **darken**, not a light-inversion —
because there is no gradient to invert. Stated as a deliberate consequence of the material story:
with no bevel and no gradient there is nothing to flip, so the press reads as the surface absorbing
light. Its risk is that this is the weakest press feedback of the three; it is compensated by the
strongest haptic (`.medium` where the others use `.light` for secondary controls).

Per control — differences only:

| Control | House Lights treatment |
|---|---|
| Primary (`PROCEED`) | 50pt **capsule**, `amber` fill (still a gradient — this is the one gradient in the direction), glow radius 24 @0.45. The single brightest object on any screen. |
| Secondary | 44pt capsule, `veilRaised`, top rim |
| Destructive | label-only in `clip`, no container at all. Confirm step is a capsule filled `clip`. |
| Quiet / tertiary | label only, `textFaint` |
| Icon button | 44×44 **circle**, `veilRaised` |
| **Footswitch latch** | 60×60, 20pt radius. Indicator is the **whole button glowing** — `amber` @0.16 fill + full rim + radius-20 glow — plus a 6pt LED dot. Most emissive of the three. Haptic `.rigid`/`.soft`. |
| Segmented | 40pt capsule. Well `houseBlack` + inner shadow r 2 y 1; thumb `veilRaised` capsule + top rim. |
| Chip | 34pt capsule, largest of the three |
| Slider track | 6pt groove `hairline` *(unchanged from today)*. Thumb stays the existing white circle — `TapSlider.swift` needs almost no change in this direction. |
| Text field | 40pt **capsule**, `houseBlack` concave, focus = 2pt `amber` ring |

### 5.5 What this direction gives up

Character. It is the safest of the three and the least likely to be remembered — an app that looks
like a well-made Apple app rather than like StreetRig. It also puts almost all of its quality budget
into shadow rendering on a near-black ground, which is exactly the thing `RigSurface.swift` already
warns is hard to see, and exactly the thing that will look worst on a phone with a dimmed screen in
a bright room. And it makes the gear photography load-bearing: if a pedal icon is weak, nothing else
on the screen is carrying the visual interest.

---

## Part 6 — `RigTheme.swift` token disposition

Every existing token, per direction. **K** = keep as-is, **C** = change (new value given),
**R** = retire.

| Token | Current | A · Tolex | B · Rack | C · House Lights |
|---|---|---|---|---|
| `background` | `#170F09` | **K** | **C** → `#0E1012` | **C** → `#120C08` |
| `backgroundLift` | `#251810` | **R** — superseded by the page vignette; it is a one-purpose gradient stop that reads like a rung | **R** | **R** |
| `cabinet` | `#1E140D` | **C** → `#1C130D` (`tolexBody`) | **C** → `#1A1D21` | **C** → `#1A110C` |
| `surface` | `#33221A` | **C** → `#1C130D` | **C** → `#1A1D21` | **C** → `#1A110C` |
| `surfaceRaised` | `#412C1F` | **C** → `#2A1C14` | **C** → `#24282D` | **C** → `#241811` |
| *(new)* `surfaceHigh` | — | **new** `#3A271B` (4th rung) | — | — |
| `surfaceEdge` | `#D99E73` @0.16 | **C** → gradient pair `rimLight`/`rimDark` | **C** → gradient pair | **C** → top-only fade |
| `elevationShadow` | black @0.5 | **K** | **C** → black @0.50, offset `x1 y3` | **C** → black @0.62 |
| `hairline` | `#4A3320` | **K** | **C** → `#16181B` | **K** |
| `panel` | `#EADFC4` | **K** | **R** — nothing warm survives | **R** — no faceplate exists |
| `trim` | `#C9A24B` | **K** + `brassLit`/`brassDark` | **R** | **R** |
| `amber` | `#E0661E` | **K** | **K** | **K** |
| `emberSoft` | `#E68044` | **K** | **K** | **K** |
| `textPrimary` | `#F4ECDA` | **K** | **C** → `#D6DCE2` | **K** |
| `textMuted` | `#B0A188` | **K** | **C** → `#8A939C` | **K** |
| `signal` | `#5AA981` | **K** | **K** | **K** |
| `clip` | `#CF4A32` | **K** | **K** | **K** |
| `ready` | `#52D37A` | **K** | **K** | **K** |

**No direction changes the meaning of `amber`, `ready`, `signal` or `clip`.** The semantics
documented in `RigTheme.swift` — amber = engaged/primary/tube glow, ready = AR placement only,
signal/clip = meter LEDs — survive all three unmodified.

---

## Part 7 — File-by-file change list

Ordered so that each step is independently shippable and visible. Hours are for **one** chosen
direction, not all three.

### Phase 1 — the primitives (no visual change until Phase 2 lands)

| # | File | Change | Hrs |
|---|---|---|---|
| 1 | `StreetRigEngine/UI/RigTheme.swift` | Apply the chosen direction's palette. Add `rimLight`/`rimDark`. Retire `backgroundLift`. **Amend the hue-discipline comment** rather than deleting it — for A and C add the `G=0.67R, B=0.465R` generator; for B replace it with the complementary-family argument from [4.1](#41-palette--and-an-explicit-argument-against-the-hue-rule). | 1.5 |
| 2 | `StreetRigEngine/UI/RigSurface.swift` | Replace the uniform `strokeBorder(stroke,…)` with the gradient bevel from [2.2](#22-the-bevel--the-one-mechanism-every-direction-needs). Add `concave:` parameter for grooves/wells. **Highest-leverage change in the codebase** — lights every card at once. | 2 |
| 3 | *new* `StreetRigEngine/UI/RigNoise.swift` | Cached procedural grain, both tunings, per [2.8](#28-the-noise-primitive--one-implementation-three-tunings). *(C: ~1h, less texture needed)* | 1.5 |
| 4 | *new* `StreetRigEngine/UI/RigButtonStyle.swift` | **The core deliverable.** `RigButtonStyle` with `.primary`, `.secondary`, `.destructive`, `.quiet`, `.icon` roles; `RigLatchStyle` for footswitch semantics; `RigSegmentedStyle`; `RigChipStyle`. Each implements the direction's state table. Haptic on press-down via `.sensoryFeedback`. | 5 |
| 5 | *new* `StreetRigEngine/UI/RigType.swift` | The type scale from [2.3](#23-type-scale) as `Font` statics, replacing the mixed `.caption2`/`.system(size:)` usage. | 1 |

### Phase 2 — adoption (this is where it becomes visible)

| # | File | Change | Hrs |
|---|---|---|---|
| 6 | `StreetRig/Views/ControlPanelView.swift` | `engageButton` → `.buttonStyle(RigButtonStyle(.primary))`. Panel background → direction's material. `PanelMetrics` per direction (B changes `body` 41→36, `vPadding` 8→6). Zone dividers → concave groove. `renderTestButton` → `.icon`. | 2.5 |
| 7 | `StreetRig/Views/MainView.swift` | `navArrow` + `creditsButton` + immersive back → `.icon` role with **44pt `.contentShape` overhang** ([2.5](#25-touch-targets)) — fixes the three HIG violations. Replace both `Color.white.opacity(0.07)` rules with the direction's hairline. `pageDots` → direction treatment. | 2 |
| 8 | `StreetRig/Views/ComponentDetailView.swift` | **10** `.plain` sites. Pane picker (`LEVELS`/`FX`/`CHANNELS`) → `RigSegmentedStyle`. Keypad `Cancel`/`Set` → `.secondary`/`.primary`. Channel buttons (`CH 1`…) → `RigChipStyle`. Knob panel per direction. Back (`Rig`) → `.quiet`. | 4 |
| 9 | `StreetRig/Views/LibraryView.swift` | **5** `.plain` sites. `Amp`/`Pedal` segmented → `RigSegmentedStyle`. Category chips → `RigChipStyle`. `Back` → `.secondary`. Gear tiles → direction's card. | 2.5 |
| 10 | `StreetRig/Views/RigStageView.swift` | **3** `.plain` sites. Slot affordances → `RigLatchStyle` (a pedal slot **is** a footswitch). Note: the stage backdrop is `#1D96C5` (`RigStageView.swift:321`) — a bright blue that is the one surface outside Burnt Tan. Each direction must decide: A keeps it (a photographed sky behind a real amp), B and C should re-grade it toward the ground tone. **Flag for the owner.** | 2.5 |
| 11 | `StreetRig/Views/GearCardView.swift` | Card material + press state. Keep the existing hold-to-lift haptic at line 149. | 1.5 |
| 12 | `StreetRig/Views/CollectionTabView.swift` | Rail background + trailing rule per direction (B: width 150→132; C: remove background fill). Section headers → `RigType.micro`. | 1 |
| 13 | `StreetRig/Views/ProfileView.swift`, `PreferencesView.swift`, `AvatarPickerView.swift` | **7** `.plain` sites → roles. Toggles → direction's switch. | 2.5 |
| 14 | `StreetRig/Views/LoadingView.swift` | Splash per direction. Wordmark `STREETRIG` → `RigType.display`. Rotating status messages (`"Warming up the tubes"` et al.) → `RigType.caption`. | 1.5 |
| 15 | `StreetRig/Views/Onboarding/SetupGuideView.swift`, `CoachMarkOverlay.swift` | **4** `.plain` sites. `chrome(_:filled:action:)` → `.primary`/`.secondary` — it is already the right shape, it just needs the style. 4 steps, kickers `1 · GET SIGNAL IN` … `4 · THEN PLAY`. | 2 |
| 16 | `StreetRig/Views/DeviceOfferPrompt.swift`, `CreditsView.swift`, `GearRemoval.swift` | Remaining sites; `GearRemoval` destructive → `.destructive` + `.warning` haptic on confirm. | 1.5 |

### Phase 3 — verification

| # | Task | Hrs |
|---|---|---|
| 17 | Device pass in a dim room **and** in daylight — the elevation/shadow legibility risk, especially for Direction C ([5.1](#51-palette)). | 1.5 |
| 18 | Instruments: confirm no `Canvas` noise regeneration in `body`, and no offscreen `.blendMode` pass on the rig stage or play page while audio runs ([2.8](#28-the-noise-primitive--one-implementation-three-tunings)). | 1 |
| 19 | Dynamic Type + Reduce Motion + VoiceOver pass over the new styles. | 1.5 |

**Out of scope, deliberately:** `ARPedalSetupView.swift` (3 sites), `ARFloor*`, `PluginEditorView.swift`.
The AUv3 editor will inherit `RigTheme`/`RigSurface`/`RigButtonStyle` automatically since they live
in `StreetRigEngine` — that inheritance should be **verified**, not assumed, in its own pass.

### Rough totals

| Direction | Phase 1 | Phase 2 | Phase 3 | **Total** |
|---|---|---|---|---|
| A · Tolex & Brass | 11.5 | 25 | 4 | **~40 h** |
| B · Rack Unit | 11 | 26 | 4 | **~41 h** |
| C · House Lights | 9.5 | 20 | 4.5 | **~34 h** |

Direction C is cheapest because it needs the least texture work and leaves `TapSlider` and the
`hairline` groove essentially unchanged. Direction B carries extra cost from re-basing every neutral
and re-flowing two layouts (rail 150→132, panel 77→68).

---

## Part 8 — Published artifacts

| Direction | Artifact |
|---|---|
| A · Tolex & Brass | https://claude.ai/code/artifact/b74f58ab-3857-4abc-9106-93bf3b3759ad |
| B · Rack Unit | https://claude.ai/code/artifact/82164d7a-7a0b-4a29-8176-e66ba69d19c3 |
| C · House Lights | https://claude.ai/code/artifact/ff18f8fc-13a5-494b-88d5-25a423a1fcad |

---

## Part 9 — Comparison and recommendation

### The three pairwise disagreements

| Pair | The concrete disagreement |
|---|---|
| **A vs B** | Whether the neutrals are warm or cool: A keeps Burnt Tan's espresso-and-cream and frames the rig in material chrome; B retires cream and brass entirely for cool graphite so the gear's own paint is the only colour on screen. |
| **B vs C** | Whether a chassis should be visible at all: B draws a machined metal face with a screen-printed legend under every control at the tightest density in the set; C deletes the chassis, the faceplate and the rail background so the controls float on unlit ground. |
| **A vs C** | What the shell is made of: A says the app **is** the amp, so chrome is gear you can see the grain of; C says the app is the dark room the amp stands in, so chrome is a hairline and a shadow. |

### Comparison

| | A · Tolex & Brass | B · Rack Unit | C · House Lights |
|---|---|---|---|
| Thesis | The app is a piece of gear you own | The app is studio equipment | The app is the dark room the gear stands in |
| Material | Tolex weave, cream plate, brass piping | Brushed anodised aluminium, silkscreen | Matte near-black, no material |
| Light | Hard, 0° overhead | Raking, 15° top-left | Ambient, no hard source |
| Neutrals | Warm (hue 21–27°) | **Cool (hue 210–213°)** | Warm (hue 21–24°) |
| Density | Loosest (52pt primary) | Tightest (44pt, rail 132) | Medium (50pt capsule) |
| Chrome | Maximum | Medium | Minimum |
| Radii | 4–20 soft | 2–8 machined | 6–999 capsule |
| Biggest risk | 33% of a 390pt screen is near-white glare in a dim room | Retires "Burnt Tan"; 10pt legends at guitar distance | Weakest press feedback; leans on shadow the codebase already warns is invisible on near-black |
| Cost | ~40 h | ~41 h | ~34 h |

### Recommendation — **A · Tolex & Brass**

It is the only direction that makes the app's own documented identity pay off: "Burnt Tan" already
specifies espresso, cream, brass and an ember accent with a fully-reasoned hue discipline, and this
direction supplies the two things that palette was always missing — a light direction and a bevel —
without discarding a single argument in `RigTheme.swift`. Its one real risk, cream-band glare, is a
scoped and reversible tuning problem (drop the plate to `#D6C9A8` and scrim it), whereas Direction B
asks the owner to abandon the app's identity outright and Direction C's central bet is on shadow
legibility that `RigSurface.swift` already documents as unreliable on this ground.

---

## Part 10 — The build: **Direction A′**

Decided 2026-08-27 by the app's owner after reviewing all three artifacts. A′ is Direction A
(Part 3) with two refinements and one explicit carve-out. **Where A′ and Part 3 disagree, A′ wins.**
Everything in Part 3 not contradicted here still stands as written.

Artifact (revised in place, same URL):
<https://claude.ai/code/artifact/b74f58ab-3857-4abc-9106-93bf3b3759ad>

### 10.1 Refinement one — texture differentiated by rung

**The problem with A as first drawn.** The tolex weave sat at effectively one opacity on every dark
surface: page `rgba(255,255,255,.014)` / `rgba(0,0,0,.22)` at a 4px pitch, card rung `.016` / `.25`
at the same 4px pitch. Texture was *present* but did no work, because a surface sharing its
neighbour's grain does not separate from it. That is what "almost there" meant.

**The fix — each elevation rung gets its own surface character, not its own opacity of one surface.**

| Rung | Weave | Extra | Reasoning |
|---|---|---|---|
| **PAGE** `#170F09` | 45°/−45° crossed, **5px** pitch, `rgba(255,255,255,.012)` / `rgba(0,0,0,.20)` | broad top-down falloff `rgba(255,255,255,.020) → transparent 22%` | Coarsest cloth, furthest from the eye. The falloff puts the 0° overhead key light on the ground itself, so every bevel above it agrees with its own backdrop. |
| **CARD** `#1C130D` | 45°/−45° crossed, **3px** pitch, `rgba(255,255,255,.013)` / `rgba(0,0,0,.18)` | — | Tighter weave = a finer cloth pulled over ply. Lower contrast than the page despite being lighter, which is what stops the two reading as one field. |
| **RAISED** `#2A1C14` | **none** | top sheen `rgba(255,255,255,.055) → transparent 34%` | The important one. Vinyl stretched over a lifted edge *catches light*; it does not show grain. Removing texture here is what makes the rung read as a separate layer. |

Net: **less** texture per surface than A shipped with, and more perceived layering. If a surface
needs to feel higher, it gets *less* grain and *more* specular, never more grain.

### 10.2 Refinement two — pedals wear their artwork under a clear coat

**Scope, stated as a boundary.** Every established icon and model is **kept**: the amp and cabinet
models, the guitar, `GearArtView`'s hand-drawn vector art, and every custom icon resolved through
`GearIconLoader`. **Pedals on the 3D stage are the single exception**, and only there.

**Why they are the exception.** `AmpModel3DView.swift:192` already maps a piece's PNG onto the
cabinet front, and `GearArt.swift:55` already prefers the PNG in 2D. `PedalArchetypes3D.swift` does
not: by its own header it builds a correct silhouette per enclosure family carrying "no logo,
script, badge or graphic", and `PedalFinish` paints it one flat colour. So the hero screen shows a
branded amp standing over anonymous coloured bricks. That inconsistency is the gap.

**The change, in three moves.**

1. **Keep the geometry.** Enclosure family, chamfer and footprint are unchanged. The wah treadle,
   the round Fuzz Face and the Boss tread plate were the point of that file and they stay.
2. **Map the artwork** onto the enclosure's **top face**: `GearIconLoader.uiImage(for:)` as
   `diffuse.contents` — the same asset, resolved by the same slug, that already dresses the cards.
3. **Clear coat** over it: `.physicallyBased`, roughness **0.18**, metalness **0.0**,
   clearCoat **0.85**, clearCoatRoughness **0.06**, lit by the same 0° overhead key as every other
   bevel in the app. Flat vector art becomes painted enamel under a stage light.

**THE TRAP — the artwork already draws the controls.** Every catalogue PNG is a top-down
illustration that *includes* its own knobs, LED and tread plate (verified: `ibonez-tube-screamer.png`
is 228×330 with Drive/Tone/Level knobs, a red LED and a tread plate drawn in). Mapping it onto an
archetype that still builds procedural knobs yields two sets, one floating over the other. So move 2
must **also suppress the archetype's top-face detail geometry** — knob cylinders, switch plate, LED
dome — keeping only enclosure, chamfer and footprint. Make it conditional on whether a slug
resolves, so a piece with no artwork still gets the procedural treatment it has today.

**One exception to the suppression, and it is not optional.** The engaged **LED stays real, emissive
geometry**, registered over the LED the artwork paints. A painted LED cannot light, and the lit LED
is how a player reads which pedals are on — the footswitch latch semantics in §3.4 depend on it.
Off = emission 0; on = `amber #E0661E` emission plus the radius-22 body glow.

**2D is already done.** Cards, rail and library need no change — `GearArt.swift:55` prefers the PNG
already. The clear coat is a SceneKit material and does not apply to flat icon rendering.

### 10.3 Correction to §3.4 — haptics inside the framework

§3.4 lists `UIImpactFeedbackGenerator` styles. **In `StreetRigEngine/` that is wrong.**
`TapSlider.swift:19-21` documents that those files ship inside the AUv3, where a UIKit haptic engine
is unavailable. Anything in the framework — which includes the whole control kit — must use
SwiftUI's `.sensoryFeedback`. Mapping: `.medium` → `.impact(weight: .medium)`, `.light` →
`.impact(weight: .light)`, `.rigid` → `.impact(flexibility: .rigid)`, `.soft` →
`.impact(flexibility: .soft)`, `.selection` → `.selection`, `.success`/`.warning` → `.success` /
`.warning`. Note haptics are **inert in the Simulator**, so this is code-review-verified, not
screenshot-verified.

### 10.4 Still open — the owner's call, do not decide it silently

`RigStageView.swift:321` paints the stage backdrop `#1D96C5`, a bright sky blue and the one surface
in the app outside Burnt Tan. A′ inherits A's position — **keep it**, read as a photographed sky
behind a real amp. Flagged here because it is the one colour decision that was never argued for in
`RigTheme.swift`, and it is worth a second look on a real device before ship.

### 10.5 Cost

~46 hours: the ~40 from Part 3 plus ~6 for the pedal treatment. The pedal work is the
highest-visibility-per-hour item in the whole plan, because it lands on the hero screen.
