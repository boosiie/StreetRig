//
//  KnobMark.metal
//  StreetRig
//
//  The shading for the three-knob mark. Everything that makes it read as a
//  PHOTOGRAPH of three amp knobs rather than three vector circles happens here:
//  procedural knurling with a lit face and a shadowed face on every ridge, an
//  anisotropic brushed-metal highlight, a bevel rim arc, the ember pointer's
//  bloom, and the ground contact that seats the mark in space.
//
//  Why this can't be SwiftUI gradients: a gradient can fake a round specular dot,
//  but it cannot make 34 ridges each catch the light on one flank and lose it on
//  the other, and it cannot stretch a highlight ALONG a brush direction. Those two
//  are the whole difference between "metal" and "grey circle with a shine".
//
//  FIRST .metal FILE IN THE PROJECT — two things follow from that:
//    • The app target is a PBXFileSystemSynchronizedRootGroup, so this file being
//      under StreetRig/ IS the wiring. Nothing was added to project.pbxproj.
//    • `ShaderLibrary.default` resolves against the app bundle's default.metallib,
//      which exists only because this file compiles into the target. A renamed or
//      mistyped entry point below is NOT a build error — it is a blank knob at
//      run time. Change a name here, then look at a screenshot, not at the log.
//
//  NO HEX LIVES IN THIS FILE. Every colour arrives as an argument, sourced from
//  RigTheme at the call site. A palette with two homes drifts, and the one that
//  drifts is always the copy nobody greps for.
//
//  COORDINATES: `position` arrives in SwiftUI POINTS with +x right and +y DOWN.
//  So "up" is negative y, and a positive angle rotates clockwise on screen. Every
//  angle below is in that space.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

// MARK: - The one light
//
// ONE key light for all three knobs, upper-left and slightly in front of the
// camera. Stated once, here, because three knobs lit from three directions is the
// single fastest way to make a mark look like clip art — the eye reads mismatched
// highlights long before it can say why the thing looks wrong.
//
// Pre-normalised by hand: Metal wants a constant expression at program scope and
// normalize() is not one.
//   raw (-0.52, -0.66,  0.54), length 0.9988
constant float3 kKeyLight   = float3(-0.5206, -0.6608, 0.5406);
//   the same light flattened into the screen plane and re-normalised. This is the
//   vector that decides WHICH ARC of a knob lights up, so it needs its own unit
//   length — the 3-D one's xy is 0.84 long and would quietly dim every rim.
//   raw (-0.52, -0.66), length 0.8402
constant float2 kKeyLightXY = float2(-0.6189, -0.7855);

// Knurl ridge count is now an ARGUMENT (`ridges`), not a constant. It used to be
// a flat 40 — a real 1/4"-shaft amp knob carries 30–45 flutes, and 40 is what
// reads right at the splash's 22.6pt knob radius. But the app-icon bake draws the
// same knob at a 171pt radius, seven and a half times bigger, and 40 flutes across
// that circumference is a coarse cog, not a grip. The count therefore ramps with
// radius; see `AmpLogoView.ridgeCount(forRadius:)` for the ramp and the numbers it
// was fitted to.
//
// Whatever the caller passes must be an INTEGER — that is what makes the pattern
// close across atan2()'s ±π seam. A fractional count leaves a visible join running
// out of the knob at nine o'clock. Swift rounds before it hands the value over.

// Antialiasing width for the pointer, in POINTS — not pixels. The shader has no
// idea what the display scale is and does not need one: 0.75pt softens to ≈2.3px
// on a 3× phone, and stays a crisp 0.75px when the mark is rasterised at 1× for
// the 1024 icon bake. A pixel-derived constant would be wrong at one of those ends.
constant float kEdgeAA = 0.75;

// MARK: - Knob face
//
// Drawn into a square tile that the knob exactly inscribes. The caller stacks this
// on a filled `Circle()`, so `src.a` arrives as SwiftUI's own antialiased coverage
// for the silhouette — we multiply it back in at the end rather than smoothstepping
// our own edge, which is both cheaper and a cleaner curve than anything computed
// from a radius here.
//
// `pointerAngle` is screen-space radians: 0 = three o'clock, +ve clockwise.
[[stitchable]] half4 knobFace(float2 pos,
                              half4  src,
                              float2 tile,
                              float  pointerAngle,
                              float  ridges,    // knurl flute count — see the note above
                              half4  body,      // RigTheme.cabinet  — the knob's dark core
                              half4  brass,     // RigTheme.trim     — the machined skirt
                              half4  cream,     // RigTheme.panel    — the hot end of a highlight
                              half4  ember,     // RigTheme.amber    — the pointer
                              half4  emberHot)  // RigTheme.emberSoft— the pointer's lit tip
{
    float  R  = min(tile.x, tile.y) * 0.5;
    float2 d  = pos - tile * 0.5;
    float  r  = max(length(d), 1e-4);
    float  t  = r / R;                      // 0 at the spindle, 1 at the skirt's outer wall
    float2 dn = d / r;                      // unit radial
    float2 tg = float2(-dn.y, dn.x);        // unit tangent — also the brushing direction

    // ---- Surface, as a height field ---------------------------------------
    //
    // Slope = how hard the surface tilts outward at radius t. Three terms, one per
    // feature of a real skirted knob: a barely-domed top, the bevel rolling over
    // to the skirt at ~0.6, and the near-vertical outer wall in the last 12%.
    // Modelled as slope rather than height because lighting only ever wants the
    // derivative, so computing the height and differentiating it would be work
    // thrown away.
    float slope = 0.22 * t
                + 1.35 * smoothstep(0.56, 0.84, t)
                + 3.20 * smoothstep(0.88, 1.00, t);

    // ---- Knurling ----------------------------------------------------------
    //
    // The grip flutes. Perturb the normal TANGENTIALLY by a periodic function of
    // the polar angle: one flank of every ridge then turns into the key light and
    // the other turns away, which is what makes the ridges read as geometry
    // instead of as stripes painted on.
    //
    // rsqrt() squares the cosine off toward ±1 so each flute is a flat facet with a
    // fast edge, the way a machined flute actually is. A raw cosine gives soft
    // corduroy. 0.16 rather than a smaller constant: at 0.08 the facets were hard
    // enough to read as sawtooth, which is a gear, not a grip.
    float ang       = atan2(dn.y, dn.x);
    float k         = cos(ang * ridges);
    float faceted   = k * rsqrt(k * k + 0.16);

    // Two envelopes on the amplitude:
    //  • radial — the knurl is a SKIRT texture. Faded to nothing inside t=0.66 so
    //    it never crawls up onto the cap, and eased off again at the very rim so
    //    the silhouette stays a clean circle rather than a gear.
    //  • size — below ~18pt of radius the flutes land under 2px apart and moiré.
    //    They retire on their own so the mark stays clean at nav-bar scale; the
    //    metal and the pointer carry the read down there.
    float knurlEnv  = smoothstep(0.66, 0.80, t) * (1.0 - smoothstep(0.93, 1.00, t));
    float sizeFade  = smoothstep(6.0, 18.0, R);
    float knurl     = faceted * 0.80 * knurlEnv * sizeFade;

    float3 N = normalize(float3(dn * slope + tg * knurl, 1.0));

    // ---- Diffuse -----------------------------------------------------------
    // Ambient is high (0.30) on purpose: this mark sits on a near-black page, and a
    // physically-honest 0.05 ambient would drop the unlit half of every knob into
    // the background and leave three crescents floating.
    float ndl     = max(dot(N, kKeyLight), 0.0);
    float diffuse = 0.30 + 0.70 * ndl;

    // ---- Anisotropic brushed metal -----------------------------------------
    //
    // Amp knobs are turned on a lathe, so the brushing runs CIRCUMFERENTIALLY. The
    // microfacets are therefore aligned with `tg`, and the specular lobe spreads in
    // the plane perpendicular to them — i.e. radially. The highlight is bright
    // exactly where the radial direction lines up with the light and dark ninety
    // degrees away, which produces the two opposing arcs ("bowtie") that you see on
    // any real brushed dial and never on a gradient.
    //
    // |cos|^16 by four squarings — no pow(), because this runs on every pixel of a
    // splash screen that also has a breathing glow animating behind it. ^16, not
    // ^8: at ^8 the two arcs are 45° wide each and merge into an all-over pale
    // smear that reads as fog on the cap rather than as a highlight on metal. The
    // broad |cos|^4 term is kept separately, at a fifth of the weight, as the
    // low sheen the tight lobe sits inside.
    float ra    = dot(dn, kKeyLightXY);
    float a2    = ra * ra;
    float a4    = a2 * a2;
    float a8    = a4 * a4;
    float aniso = a8 * a8;

    // The brushing itself: fine concentric grooves. Radial frequency, because
    // circular brushing varies ACROSS the grooves, not along them. Same size fade —
    // at splash scale these land ~0.9pt apart and any finer would shimmer.
    float grooves = sin(t * 26.0) * 0.06 * sizeFade;

    float spec = (aniso * 0.88 + a4 * 0.20) * (0.55 + 0.45 * ndl) + grooves;
    spec *= (1.0 - smoothstep(0.88, 1.00, t));    // the vertical outer wall holds no highlight
    spec *= smoothstep(0.04, 0.20, t);            // nor does the spindle dimple

    // ---- Bevel rim ---------------------------------------------------------
    // One bright arc where the top edge of the skirt turns into the key light,
    // squared so it decays fast and is gone by the time it reaches the shadow side.
    float rimBand   = smoothstep(0.86, 0.96, t) * (1.0 - smoothstep(0.985, 1.00, t));
    float rimFacing = max(dot(dn, kKeyLightXY), 0.0);
    float rim       = rimBand * rimFacing * rimFacing;

    // ...and its opposite number: the far edge losing the light. Without this the
    // knob reads as a lit disc rather than a lit cylinder.
    float edgeShade = smoothstep(0.78, 1.00, t) * max(-dot(dn, kKeyLightXY), 0.0);

    // ---- Colour ------------------------------------------------------------
    //
    // HUE DISCIPLINE — the reason the metal is built the way it is, measured off
    // the first screenshot of this shader, which came out army khaki.
    //
    // The trap is that "warm" is not the same as "in family". `trim` is hue 41°
    // and `panel` is hue 43°; amber is 22°. RigTheme's own ladder note says as
    // much about cream — it is the single most olive thing in the palette. Lerping
    // a dark brown 52% toward brass and then 42% toward cream produced exactly
    // that: G/R 0.85, hue 38°, sand. Correct in isolation, khaki next to an amber
    // pointer, because desaturating a brown beside a saturated orange makes the eye
    // push the brown further green still.
    //
    // So the metal is mixed toward brass and then PULLED BACK toward `amber`, which
    // is the only token that can lower the hue. Measured: cabinet →34% trim →30%
    // amber lands at RGB (0.51, 0.31, 0.13), G/R 0.61, hue 28° — inside the family,
    // and a deeper bronze than brass alone. Cream survives only in the hottest core
    // of a highlight, where a few percent of it reads as glint rather than as tint.
    half3 bronze    = mix(body.rgb, brass.rgb, half(0.34));
    bronze          = mix(bronze,   ember.rgb, half(0.30));
    half3 capBase   = mix(body.rgb, bronze,    half(0.46));   // the cap is darker: it is the moulded top
    half3 base      = mix(capBase, bronze, half(smoothstep(0.55, 0.72, t)));

    // Highlights lerp toward SHEEN, not toward raw brass. Sampled off the second
    // screenshot: lerping 0.44 toward `trim` put the brightest skirt pixel at
    // #B38D4F — hue 37°, G/R 0.788 — which is the exact band the ladder note names
    // as the army-khaki cut of the palette. `trim` is a hue-41° gold, so a strong
    // lerp toward it walks a bronze straight out of the family however warm it
    // looks in isolation. A quarter of `emberSoft` folded in drags the target to
    // hue 35°, G/R 0.736, and the resulting peak lands near hue 32 / G-R 0.70 —
    // still unmistakably brass, no longer khaki.
    half3 sheen = mix(brass.rgb, emberHot.rgb, half(0.25));

    half3 col = base * half(diffuse);
    col = mix(col, sheen, half(saturate(spec) * 0.44));
    // spec³, not spec² — cubing keeps cream out of everything but the glint itself.
    float specCore = saturate(spec); specCore = specCore * specCore * specCore;
    col = mix(col, cream.rgb, half(specCore * 0.20));
    col = mix(col, sheen, half(saturate(rim) * 0.52));
    col = mix(col, cream.rgb, half(saturate(rim * rim) * 0.20));
    col *= half(1.0 - 0.55 * edgeShade);

    // The groove where the cap rolls down onto the skirt. Without it the two read
    // as one continuous dome and the knob loses the step that says "cap on skirt".
    float capGroove = smoothstep(0.50, 0.58, t) * (1.0 - smoothstep(0.58, 0.68, t));
    col *= half(1.0 - 0.30 * capGroove);

    // ---- Pointer -----------------------------------------------------------
    // A capsule from 0.16R to 0.90R along `pointerAngle`, measured as the distance
    // to that clamped segment so the ends are round without a second shape.
    float2 pd    = float2(cos(pointerAngle), sin(pointerAngle));
    float  along = clamp(dot(d, pd), R * 0.16, R * 0.90);
    float  dSeg  = length(d - pd * along);
    float  halfW = max(R * 0.055, 0.9);
    float  core  = 1.0 - smoothstep(halfW - kEdgeAA, halfW + kEdgeAA, dSeg);

    // Seat it: a hair of occlusion in the groove the pointer is sunk into. Without
    // it the line reads as painted on, which is the one thing an indicator never is.
    float groove = (1.0 - smoothstep(halfW, halfW + max(R * 0.05, 1.0), dSeg)) * (1.0 - core);
    col *= half(1.0 - 0.45 * groove);

    // Bloom. An exponential falloff, so the ember bleeds past the pointer's own
    // edge and picks up on the metal beside it. One exp() per pixel and no second
    // pass — cheaper than sampling a neighbourhood, and the atmospheric halo that
    // spills OUTSIDE the knob is a SwiftUI .blur layer at the call site, per the
    // performance note in the task.
    float bloom = exp(-dSeg / max(R * 0.17, 1.0));
    col += ember.rgb * half(bloom * 0.50);

    col = mix(col, ember.rgb, half(core));
    // The tip runs hotter than the shaft — that is where the light pipe on a real
    // pointer collects. emberSoft, not white: see the hue note above.
    float tipHeat = smoothstep(R * 0.50, R * 0.86, dot(d, pd)) * core;
    col = mix(col, emberHot.rgb, half(tipHeat * 0.70));

    col = clamp(col, half3(0.0), half3(1.0));

    // Premultiplied out, weighted by SwiftUI's own edge coverage.
    half a = src.a;
    return half4(col * a, a);
}

// MARK: - Ground contact
//
// Drawn as one layer UNDER all three knobs, in a tile deliberately larger than the
// mark's own frame so the cast shadows have somewhere to fall. Two separate things
// are happening, and they are separate because they behave differently:
//
//   • CAST — the shadow each knob throws onto the page, offset along the key light
//     and squashed vertically, the way a shadow on a floor plane is.
//   • OCCLUSION — a tight halo hugging each knob's own edge. Combined by screening
//     rather than max(), which is the whole point: in the crevices where two knobs
//     nearly touch, two halos overlap and compound into a darker seam. That seam is
//     what makes three knobs read as three OBJECTS near each other instead of three
//     shapes on one plane.
[[stitchable]] half4 knobGroundContact(float2 pos,
                                       half4  src,
                                       float2 c0,
                                       float2 c1,
                                       float2 c2,
                                       float  radius,
                                       half4  floorTint)  // RigTheme.background
{
    // Shadows fall AWAY from the key light: down and to the right.
    float2 drop = -kKeyLightXY * radius * 0.26;

    float occ  = 0.0;
    float cast = 0.0;

    float2 centres[3] = { c0, c1, c2 };
    for (int i = 0; i < 3; ++i) {
        float2 c = centres[i];

        // Occlusion halo — screened, so overlaps in the crevices go darker.
        float dAO = length(pos - c);
        float ao  = (1.0 - smoothstep(radius * 1.00, radius * 1.70, dAO)) * 0.52;
        occ = occ + ao - occ * ao;

        // Cast shadow — 1.16× vertical squash, which is a shallow floor angle. A
        // circular blob reads as a hovering ball; the squash is what puts it on
        // the ground.
        float2 q = pos - (c + drop);
        q.y *= 1.16;
        float dS = length(q);
        float s  = 1.0 - smoothstep(radius * 0.55, radius * 1.40, dS);
        cast = max(cast, s);
    }

    float a = saturate(occ * 0.62 + cast * 0.42);

    // A shadow on this page has to stay WARM. Pure black on espresso reads as a
    // punched hole, and lifting it toward grey would desaturate straight into the
    // olive this palette exists to avoid — so the shadow is the PAGE's own colour
    // driven down to a fifth of its value. Same hue, less light, which is what a
    // shadow physically is.
    half3 shade = floorTint.rgb * half(0.20);

    a *= float(src.a);
    return half4(shade * half(a), half(a));
}
