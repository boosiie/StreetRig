//
//  KnobPanelLayout.swift
//  StreetRig
//
//  HOW TALL A KNOB PANEL IS, and how its dials fall into rows. Lifted out of
//  ComponentDetailView unchanged, because a second caller now needs to ask the
//  same question: `PanelArtExporter` bakes each component's faceplate to a PNG
//  at the panel's own proportions, and a plate whose shape disagrees with the
//  panel it sits behind is a plate that gets cropped. One definition, two
//  callers — the view that lays the knobs out and the exporter that paints the
//  surface under them.
//
//  Pure functions of a component's parameter list: no view state, no store, no
//  geometry. Everything here was a `private var` on the view and behaves exactly
//  as it did there.
//

import CoreGraphics
import StreetRigEngine

enum KnobPanelLayout {

    /// One row of the panel: an optional caption (a channel name) and its dials.
    typealias Row = (label: String?, dials: [GearParameter])

    /// A rotary is for a value that sweeps; a Katana's Character selector has
    /// five detents and its Power switch three, and both live in the same knob
    /// list as Gain and Bass. The MAIN panel is everything with no group — a
    /// grouped control belongs to a named sub-panel instead (the Katana's five FX
    /// blocks are one group each).
    static func dials(_ params: [GearParameter]) -> [GearParameter] {
        params.filter { !$0.isDiscrete && $0.group == nil }
    }

    /// THE KNOB PANEL'S ROWS. Panels are faithful to the chassis and some amps
    /// have a lot of controls — the Friedman has nineteen — so one row is not a
    /// safe assumption. Explicit `rowLabel`s win (an amp with two channels reads
    /// as two named rows, which is how the hardware is laid out); otherwise a row
    /// that would squeeze knobs below legibility is split in half. One row is
    /// still preferred and still what most amps get.
    static func rows(_ params: [GearParameter]) -> [Row] {
        var order: [String] = []
        var byRow: [String: [GearParameter]] = [:]
        var loose: [GearParameter] = []
        for d in dials(params) {
            if let r = d.rowLabel {
                if byRow[r] == nil { order.append(r) }
                byRow[r, default: []].append(d)
            } else { loose.append(d) }
        }
        if !order.isEmpty {
            var rows: [(String?, [GearParameter])] = order.map { ($0, byRow[$0] ?? []) }
            // UNLABELLED DIALS NEVER JOIN A CHANNEL ROW. They are the amp's shared
            // controls — the Orange's reverb serves both channels, the Vox's
            // reverb and tremolo likewise — and folding one in dimmed a shared
            // control whenever the other channel was selected. A long shared row
            // splits in two rather than crowding.
            if !loose.isEmpty {
                if loose.count > 4 {
                    let half = (loose.count + 1) / 2
                    rows.insert((nil, Array(loose.dropFirst(half))), at: 0)
                    rows.insert((nil, Array(loose.prefix(half))), at: 0)
                } else {
                    rows.insert((nil, loose), at: 0)
                }
            }
            return rows.map { (label: $0.0, dials: $0.1) }
        }
        guard loose.count > 7 else { return [(nil, loose)] }
        let half = (loose.count + 1) / 2
        return [(nil, Array(loose.prefix(half))), (nil, Array(loose.dropFirst(half)))]
    }

    /// The grouped controls, in declaration order, one entry per group.
    static func groups(_ params: [GearParameter]) -> [(name: String, controls: [GearParameter])] {
        var order: [String] = []
        var byName: [String: [GearParameter]] = [:]
        for p in params {
            guard let g = p.group else { continue }
            if byName[g] == nil { order.append(g) }
            byName[g, default: []].append(p)
        }
        return order.map { ($0, byName[$0] ?? []) }
    }

    /// An amp with an FX SECTION is fighting for every point of height — the app
    /// is landscape-only — so its fixed furniture is trimmed and its panel capped
    /// lower. Every other amp keeps the original proportions exactly.
    static func isDense(_ params: [GearParameter]) -> Bool { !groups(params).isEmpty }

    /// More dials than the dock can show at once, so the dock has to be worth
    /// scrolling. Such an amp gets the same trimmed furniture an FX amp gets —
    /// see `cap(_:)` for why the height comes off the faceplate rather than the
    /// controls.
    static func isDialHeavy(_ params: [GearParameter]) -> Bool { dials(params).count > 8 }

    /// What the panel WANTS: 56 pt a knob row, plus every labelled row's caption,
    /// plus the gaps between them.
    ///
    /// Every LABELLED row needs its caption's height too. Counting only the knob
    /// rows is what clipped "CHANNEL 1" off the top of the Mesa and the Orange:
    /// the panel was sized for the dials and the text had nowhere to go.
    static func naturalHeight(_ params: [GearParameter]) -> CGFloat {
        let panelRows = rows(params)
        let count = max(1, panelRows.count)
        let labels = panelRows.filter { $0.label != nil }.count
        let spacing = max(0, count * 2 - 1) * 4
        return CGFloat(count) * 56 + CGFloat(labels) * 13 + CGFloat(spacing) + 12
    }

    /// What the panel actually GETS: what it wants, capped so it can never crowd
    /// out the slider dock. A tall panel on a ~400 pt landscape sheet used to push
    /// the sliders — the controls the player actually drags — off the bottom.
    static func height(_ params: [GearParameter]) -> CGFloat {
        min(naturalHeight(params), cap(params))
    }

    /// THE CAP, and why it is not one number.
    ///
    /// An amp with an FX section is short of height for a layout reason: it has a
    /// whole extra pane to fit. A DIAL-HEAVY amp is short of it for a different
    /// one — every dial it owns has to be REACHABLE in the dock below, and the
    /// dock is a scrolling window, so the window has to be big enough to be worth
    /// scrolling. At the old flat 178 the Friedman's fifteen dials and the
    /// Rockerverb's ten were left a ~26 pt dock: not a cramped dock, no dock at
    /// all — two sliders visible and the rest off the bottom of the screen with
    /// nothing to scroll, because the sheet had overflowed rather than fitted.
    ///
    /// The faceplate is what gives, and it gives cheaply: `knobPanel` sizes its
    /// dials from the height it is handed (down to a 20 pt floor), so a shorter
    /// panel is a panel with smaller knobs, not a clipped one. The dock is where
    /// the player actually works.
    static func cap(_ params: [GearParameter]) -> CGFloat {
        if isDense(params) { return 132 }
        switch dials(params).count {
        case 13...:  return 120     // Friedman BE-100 — fifteen
        case 9...12: return 140     // Rockerverb, DSL, Twin
        default:     return 178     // the six-knob amps, exactly as before
        }
    }
}
