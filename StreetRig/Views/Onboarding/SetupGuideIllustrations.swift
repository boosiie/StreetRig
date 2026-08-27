//
//  SetupGuideIllustrations.swift
//  StreetRig
//
//  THE MOVING HALF OF THE SETUP GUIDE. Four drawings, each one animated because
//  the thing it is teaching is a thing that HAPPENS: a plug seating, a signal
//  arriving late, sound leaving a speaker, a meter answering a string.
//
//  WHY DRAWN AND NOT PHOTOGRAPHED. The subject is hardware sitting outside the
//  phone, and the honest options were a photo of an iRig, an SF Symbol, or this.
//  A photo dates the moment a manufacturer changes a moulding and implies we are
//  recommending one product; a symbol cannot show a plug going IN, which is the
//  entire content of the first page. These are shapes and gradients from
//  `RigTheme`, so they age with the palette and weigh nothing.
//
//  EVERY ONE IS LAID OUT IN FRACTIONS OF ITS CONTAINER, never in points. The
//  guide is landscape-only but that still spans a 430-point-wide pane on a phone
//  and better than double that on an iPad, and a drawing pinned to point
//  coordinates would be a postage stamp in the middle of the iPad's pane.
//
//  REDUCE MOTION IS A DIFFERENT DRAWING, NOT A SLOWER ONE — see the note in
//  `GestureGhostView`. Each illustration takes `reduceMotion` and renders the
//  END STATE of its animation with the information that the motion carried
//  written out instead: the plug already seated, both signal paths shown with
//  their arrival times side by side, the waves drawn rather than expanding.
//

import SwiftUI
import StreetRigEngine

// MARK: - Shared pieces

/// The phone, drawn once. Every page needs one and they must not drift apart.
private struct PhoneShape: View {
    var lit: Bool = false
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(RigTheme.cabinet)
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(RigTheme.trim.opacity(0.55), lineWidth: 1.2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(lit
                          ? AnyShapeStyle(LinearGradient(colors: [RigTheme.amber.opacity(0.45),
                                                                  RigTheme.amber.opacity(0.10)],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(RigTheme.background))
                    .padding(3.5)
            }
    }
}

/// A travelling signal dot with a soft halo. The halo does the work: on a dark
/// espresso page a 6pt amber dot is a dust speck without it.
private struct SignalDot: View {
    var size: CGFloat = 9
    var colour: Color = RigTheme.amber
    var body: some View {
        Circle()
            .fill(colour)
            .frame(width: size, height: size)
            .shadow(color: colour.opacity(0.9), radius: size * 0.8)
            .shadow(color: colour.opacity(0.5), radius: size * 1.9)
    }
}

/// One leg of a signal path — the rail a dot runs along.
private struct SignalRail: View {
    var body: some View {
        Capsule()
            .fill(RigTheme.hairline)
            .frame(height: 3)
    }
}

/// A small caption under a piece of the drawing.
private struct PartLabel: View {
    let text: String
    var colour: Color = RigTheme.textMuted
    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold))
            .tracking(0.9)
            .foregroundStyle(colour)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

private struct GearBox: View {
    var label: String
    var symbol: String
    var tint: Color = RigTheme.trim
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
            PartLabel(text: label)
        }
    }
}

// MARK: - 1. Get signal in

/// A guitar interface arriving at the phone: the cable slides in from the left
/// and the plug SEATS, with the port lighting as it lands. The seat is the whole
/// point of the animation — "plug it in" is not the instruction anybody needs,
/// "this is the shape of the thing that goes in the bottom" is.
struct PlugInIllustration: View {
    let reduceMotion: Bool

    /// THE FIRST PAGE IS A CHAIN, NOT A SCENE.
    ///
    /// It was one drawing of a lead being pushed into a port: accurate, and
    /// useless as an instruction, because it showed the LAST of three moves and
    /// nothing of the order. Three numbered boxes with the signal running
    /// between them say the order, which is the only thing a first page has to
    /// say. The prose beside it now follows the same three beats.
    ///
    /// THE PHONE IS SIDEWAYS AND THE LEAD GOES INTO THE BOTTOM OF IT. Standing
    /// it upright drew a phone in an orientation this app cannot even run in —
    /// StreetRig is landscape-locked — and ran the cable into its side, where
    /// there is no socket. Sideways, with the lead turning up into the bottom
    /// edge, is both what the hardware does and what the player is holding.
    private struct Frame {
        var pulse: CGFloat = 0      // 0…1 along the whole chain
        var lit: CGFloat = 0        // the screen coming alive at the end
    }

    var body: some View {
        GeometryReader { geo in
            if reduceMotion {
                chain(geo.size, pulse: nil, lit: 1)
            } else {
                KeyframeAnimator(initialValue: Frame(), repeating: true) { f in
                    chain(geo.size, pulse: f.pulse, lit: f.lit)
                } keyframes: { _ in
                    KeyframeTrack(\.pulse) {
                        LinearKeyframe(0, duration: 0.30)
                        LinearKeyframe(1, duration: 1.70)
                        LinearKeyframe(1, duration: 1.10)
                    }
                    KeyframeTrack(\.lit) {
                        LinearKeyframe(0, duration: 1.85)
                        CubicKeyframe(1, duration: 0.22)
                        LinearKeyframe(1, duration: 0.83)
                        CubicKeyframe(0, duration: 0.20)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - The chain

    @ViewBuilder
    private func chain(_ size: CGSize, pulse: CGFloat?, lit: CGFloat) -> some View {
        let w = size.width, h = size.height
        // One baseline for the lead, with the phone raised off it so the cable
        // has somewhere to turn UP into. Guitar and interface sit on the line;
        // the phone sits above it and reaches down.
        let y0 = h * 0.60
        let x1 = w * 0.15, x2 = w * 0.50, x3 = w * 0.85
        // ASPECT FIRST, SIZE SECOND. Sizing the two edges off the pane
        // independently (w * 0.22 by h * 0.30) let the pane's own proportions
        // decide the phone's, and on the real pane that came out 80 x 85 — a
        // square, which is the one shape that does not read as a phone at all,
        // let alone a sideways one. Height is what is scarce here, so it is
        // taken from whichever edge is tighter and the width follows it.
        let phoneH = min(h * 0.20, w * 0.115)
        let phoneW = phoneH * 1.95
        let phoneY = y0 - h * 0.30
        let plugTop = phoneY + phoneH / 2
        let plugBottom = plugTop + h * 0.11

        ZStack {
            rail(from: CGPoint(x: x1 + w * 0.07, y: y0), to: CGPoint(x: x2 - w * 0.07, y: y0))
            elbow(fromX: x2 + w * 0.07, toX: x3, y: y0, upTo: plugBottom)

            if let pulse {
                travellingDot(pulse: pulse, x1: x1, x2: x2, x3: x3,
                              y0: y0, plugBottom: plugBottom, w: w)
            }

            // 1 — the guitar
            stepBadge(1).position(x: x1, y: y0 - h * 0.30)
            Image(systemName: "guitars.fill")
                .font(.system(size: min(30, h * 0.20), weight: .semibold))
                .foregroundStyle(RigTheme.trim)
                .position(x: x1, y: y0 - h * 0.10)
            PartLabel(text: "GUITAR").position(x: x1, y: y0 + h * 0.16)

            // 2 — the interface
            stepBadge(2).position(x: x2, y: y0 - h * 0.30)
            interfaceBox
                .frame(width: w * 0.13, height: h * 0.22)
                .position(x: x2, y: y0 - h * 0.10)
            PartLabel(text: "INTERFACE").position(x: x2, y: y0 + h * 0.16)

            // 3 — the phone, on its side, socket down
            stepBadge(3).position(x: x3, y: phoneY - phoneH * 0.78)
            PhoneShape(lit: lit > 0.5)
                .frame(width: phoneW, height: phoneH)
                .position(x: x3, y: phoneY)
            plug
                .frame(width: 5.5, height: plugBottom - plugTop)
                .position(x: x3, y: (plugTop + plugBottom) / 2)
            // The socket lighting as the signal lands — the "it's in" moment.
            Capsule()
                .fill(RigTheme.amber)
                .frame(width: phoneW * 0.30, height: 3.5)
                .shadow(color: RigTheme.amber.opacity(0.95), radius: 7)
                .position(x: x3, y: plugTop)
                .opacity(lit)
            PartLabel(text: "PHONE, SIDEWAYS").position(x: x3, y: y0 + h * 0.16)
        }
    }

    /// The step number. What makes three drawings read as one sequence rather
    /// than as three things that happen to be next to each other.
    private func stepBadge(_ n: Int) -> some View {
        Text("\(n)")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(RigTheme.background)
            .frame(width: 16, height: 16)
            .background(Circle().fill(RigTheme.amber))
    }

    private func rail(from a: CGPoint, to b: CGPoint) -> some View {
        Path { p in p.move(to: a); p.addLine(to: b) }
            .stroke(RigTheme.hairline, style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }

    /// The last leg: along the floor, then UP into the phone's bottom edge.
    private func elbow(fromX: CGFloat, toX: CGFloat, y: CGFloat, upTo: CGFloat) -> some View {
        Path { p in
            p.move(to: CGPoint(x: fromX, y: y))
            p.addLine(to: CGPoint(x: toX - 10, y: y))
            p.addQuadCurve(to: CGPoint(x: toX, y: y - 10),
                           control: CGPoint(x: toX, y: y))
            p.addLine(to: CGPoint(x: toX, y: upTo))
        }
        .stroke(RigTheme.hairline, style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }

    /// One dot for the whole chain, so the eye is told the ORDER rather than
    /// shown three things blinking independently.
    @ViewBuilder
    private func travellingDot(pulse: CGFloat, x1: CGFloat, x2: CGFloat, x3: CGFloat,
                               y0: CGFloat, plugBottom: CGFloat, w: CGFloat) -> some View {
        let legA = (x1 + w * 0.07, x2 - w * 0.07)
        let legB = (x2 + w * 0.07, x3)
        if pulse < 0.42 {
            let t = pulse / 0.42
            SignalDot().position(x: legA.0 + (legA.1 - legA.0) * t, y: y0)
        } else if pulse < 0.84 {
            let t = (pulse - 0.42) / 0.42
            SignalDot().position(x: legB.0 + (legB.1 - legB.0) * t, y: y0)
        } else {
            let t = (pulse - 0.84) / 0.16
            SignalDot().position(x: x3, y: y0 + (plugBottom - y0) * t)
        }
    }

    private var interfaceBox: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(RigTheme.surfaceRaised)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(RigTheme.surfaceEdge, lineWidth: 1)
            }
            .overlay {
                VStack(spacing: 3) {
                    Circle().fill(RigTheme.signal).frame(width: 4, height: 4)
                    Capsule().fill(RigTheme.hairline).frame(width: 14, height: 3)
                }
            }
    }

    private var plug: some View {
        Capsule()
            .fill(LinearGradient(colors: [RigTheme.panel, RigTheme.trim],
                                 startPoint: .leading, endPoint: .trailing))
    }
}
// MARK: - 2. The Bluetooth lesson

/// TWO ROUTES, ONE STARTING GUN. The same note leaves the guitar on both paths
/// at the same instant; the wired one arrives while the wireless one is still
/// sitting in a buffer that visibly fills before it is allowed to move on.
///
/// The buffer is drawn, and drawn as the CAUSE, because that is what the engine
/// controller actually documents: A2DP buffers by protocol design, and no amount
/// of DSP work touches it. A cartoon of "wireless = slow" would teach a
/// superstition; this teaches where the time goes.
struct WirelessDelayIllustration: View {
    let reduceMotion: Bool

    private struct Frame {
        var wired: CGFloat = 0
        var wireless: CGFloat = 0
        var buffer: CGFloat = 0
        var wiredLanded: CGFloat = 0
        var wirelessLanded: CGFloat = 0
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            if reduceMotion {
                lanes(w: w, h: h, frame: Frame(wired: 1, wireless: 1, buffer: 1,
                                               wiredLanded: 1, wirelessLanded: 1))
            } else {
                KeyframeAnimator(initialValue: Frame(), repeating: true) { frame in
                    lanes(w: w, h: h, frame: frame)
                } keyframes: { _ in
                    KeyframeTrack(\.wired) {
                        LinearKeyframe(0, duration: 0.25)
                        CubicKeyframe(1, duration: 0.80)
                        LinearKeyframe(1, duration: 2.35)
                        LinearKeyframe(0, duration: 0.01)
                    }
                    KeyframeTrack(\.wiredLanded) {
                        LinearKeyframe(0, duration: 1.05)
                        CubicKeyframe(1, duration: 0.2)
                        LinearKeyframe(1, duration: 2.15)
                        LinearKeyframe(0, duration: 0.01)
                    }
                    // Same start. Reaches the buffer at the same moment the wired
                    // one has already arrived — then waits.
                    KeyframeTrack(\.wireless) {
                        LinearKeyframe(0, duration: 0.25)
                        CubicKeyframe(0.42, duration: 0.55)
                        LinearKeyframe(0.42, duration: 1.35)      // held in the buffer
                        CubicKeyframe(1, duration: 0.65)
                        LinearKeyframe(1, duration: 0.60)
                        LinearKeyframe(0, duration: 0.01)
                    }
                    KeyframeTrack(\.buffer) {
                        LinearKeyframe(0, duration: 0.80)
                        LinearKeyframe(1, duration: 1.35)
                        LinearKeyframe(1, duration: 1.25)
                        LinearKeyframe(0, duration: 0.01)
                    }
                    KeyframeTrack(\.wirelessLanded) {
                        LinearKeyframe(0, duration: 2.80)
                        CubicKeyframe(1, duration: 0.2)
                        LinearKeyframe(1, duration: 0.40)
                        LinearKeyframe(0, duration: 0.01)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func lanes(w: CGFloat, h: CGFloat, frame: Frame) -> some View {
        // The source sits a full 0.22 of the pane in from the left, not 0.13. At
        // 0.13 the "ONE NOTE" caption — which is wider than the icon above it —
        // ran straight through the vertical line that splits the two lanes.
        let startX = w * 0.24, endX = w * 0.87
        let topY = h * 0.28, bottomY = h * 0.70

        return ZStack {
            // WIRED lane
            lane(y: topY, startX: startX, endX: endX,
                 title: "WIRED", titleColour: RigTheme.signal)
            SignalDot(size: 9, colour: RigTheme.signal)
                .position(x: startX + (endX - startX) * frame.wired, y: topY)
                .opacity(frame.wired > 0 ? 1 : 0)
            GearBox(label: "OUT", symbol: "headphones", tint: RigTheme.signal)
                .position(x: endX + w * 0.055, y: topY)
            arrivalChip("≈25 ms", tone: RigTheme.signal)
                .position(x: endX - w * 0.10, y: topY - h * 0.15)
                .opacity(frame.wiredLanded)

            // WIRELESS lane, with the buffer that causes the wait.
            lane(y: bottomY, startX: startX, endX: endX,
                 title: "BLUETOOTH", titleColour: RigTheme.clip)
            bufferBox(fill: frame.buffer)
                .frame(width: w * 0.075, height: h * 0.16)
                .position(x: startX + (endX - startX) * 0.42, y: bottomY)
            PartLabel(text: "BUFFER", colour: RigTheme.clip.opacity(0.9))
                .position(x: startX + (endX - startX) * 0.42, y: bottomY + h * 0.16)
            SignalDot(size: 9, colour: RigTheme.clip)
                .position(x: startX + (endX - startX) * frame.wireless, y: bottomY)
                .opacity(frame.wireless > 0 ? 1 : 0)
            GearBox(label: "OUT", symbol: "airpods.gen3", tint: RigTheme.clip)
                .position(x: endX + w * 0.055, y: bottomY)
            arrivalChip("≈180 ms", tone: RigTheme.clip)
                .position(x: endX - w * 0.10, y: bottomY - h * 0.15)
                .opacity(frame.wirelessLanded)

            // One source, both lanes — the point being that the guitar did
            // nothing different.
            GearBox(label: "ONE NOTE", symbol: "guitars.fill")
                .position(x: startX - w * 0.155, y: (topY + bottomY) / 2)
            Path { path in
                let splitX = startX - w * 0.045
                let midY = (topY + bottomY) / 2
                path.move(to: CGPoint(x: startX - w * 0.105, y: midY))
                path.addLine(to: CGPoint(x: splitX, y: midY))
                path.move(to: CGPoint(x: splitX, y: topY))
                path.addLine(to: CGPoint(x: splitX, y: bottomY))
                path.move(to: CGPoint(x: splitX, y: topY))
                path.addLine(to: CGPoint(x: startX, y: topY))
                path.move(to: CGPoint(x: splitX, y: bottomY))
                path.addLine(to: CGPoint(x: startX, y: bottomY))
            }
            .stroke(RigTheme.hairline, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }

    private func lane(y: CGFloat, startX: CGFloat, endX: CGFloat,
                      title: String, titleColour: Color) -> some View {
        ZStack {
            SignalRail()
                .frame(width: endX - startX)
                .position(x: (startX + endX) / 2, y: y)
            PartLabel(text: title, colour: titleColour)
                .position(x: startX + 26, y: y - 14)
        }
    }

    private func bufferBox(fill: CGFloat) -> some View {
        GeometryReader { box in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(RigTheme.surfaceRaised)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(RigTheme.clip.opacity(0.75))
                    .frame(height: box.size.height * fill)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(RigTheme.clip.opacity(0.8), lineWidth: 1)
            }
        }
    }

    private func arrivalChip(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold).monospacedDigit())
            .foregroundStyle(tone)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(RigTheme.background.opacity(0.9)))
            .overlay(Capsule().strokeBorder(tone.opacity(0.6), lineWidth: 1))
    }
}

// MARK: - 3. What to use instead

/// The three routes that work, with the one the app was actually designed
/// around — phone on the floor, no headphones — drawn as the phone lying flat
/// and pushing sound out. A cycling highlight steps through the three so none of
/// them reads as the only answer.
struct OutputChoicesIllustration: View {
    let reduceMotion: Bool

    private struct Frame {
        var highlight: CGFloat = 0     // 0…3, the tile currently lit
        var waves: CGFloat = 0
    }

    private let options: [(String, String)] = [
        ("WIRED BUDS", "headphones"),
        ("INTERFACE", "cable.connector"),
        ("THE PHONE", "iphone.gen3.radiowaves.left.and.right")
    ]

    var body: some View {
        GeometryReader { geo in
            if reduceMotion {
                board(geo.size, frame: Frame(highlight: 2, waves: 1), animated: false)
            } else {
                KeyframeAnimator(initialValue: Frame(), repeating: true) { frame in
                    board(geo.size, frame: frame, animated: true)
                } keyframes: { _ in
                    KeyframeTrack(\.highlight) {
                        LinearKeyframe(0, duration: 1.1)
                        LinearKeyframe(1, duration: 0.35)
                        LinearKeyframe(1, duration: 0.75)
                        LinearKeyframe(2, duration: 0.35)
                        LinearKeyframe(2, duration: 1.5)
                        LinearKeyframe(0, duration: 0.35)
                    }
                    KeyframeTrack(\.waves) {
                        LinearKeyframe(0, duration: 0.9)
                        LinearKeyframe(1, duration: 1.6)
                        LinearKeyframe(0, duration: 1.6)
                        LinearKeyframe(0, duration: 0.4)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func board(_ size: CGSize, frame: Frame, animated: Bool) -> some View {
        let w = size.width, h = size.height
        let lit = Int(frame.highlight.rounded())

        return ZStack {
            HStack(spacing: w * 0.045) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    optionTile(option.0, symbol: option.1, lit: index == lit)
                }
            }
            .frame(width: w * 0.94)
            .position(x: w / 2, y: h * 0.22)

            // The intended posture, stated as a picture: the phone flat on the
            // floor, pushing sound up at the player.
            //
            // BOTTOM-ALIGNED, not offset. `Arc` draws from the bottom edge of
            // whatever frame it is given, so three arcs sharing a bottom edge are
            // concentric for free — whereas three centred frames of different
            // heights put three arcs at three different origins, which is how the
            // first cut ended up drawing the waves underneath the phone.
            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    ForEach(0..<3, id: \.self) { ring in
                        Arc()
                            .stroke(RigTheme.amber.opacity(0.70 - Double(ring) * 0.17),
                                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .frame(width: w * (0.22 + CGFloat(ring) * 0.13),
                                   height: h * (0.10 + CGFloat(ring) * 0.055))
                            .opacity(animated
                                     ? Double(max(0, min(1, frame.waves * 3 - Double(ring))))
                                     : 1)
                    }
                }
                .frame(width: w * 0.5, height: h * 0.23, alignment: .bottom)

                PhoneShape(lit: true)
                    .frame(width: w * 0.26, height: h * 0.085)
                // The floor the phone is lying on, so it reads as lying down
                // rather than as a button someone forgot to label.
                Capsule()
                    .fill(RigTheme.hairline)
                    .frame(width: w * 0.46, height: 2)
                    .padding(.top, 5)
            }
            .position(x: w * 0.5, y: h * 0.60)

            PartLabel(text: "PHONE ON THE FLOOR · NO HEADPHONES")
                .position(x: w * 0.5, y: h * 0.93)
        }
    }

    private func optionTile(_ title: String, symbol: String, lit: Bool) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(lit ? RigTheme.amber : RigTheme.textMuted)
            PartLabel(text: title, colour: lit ? RigTheme.textPrimary : RigTheme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .rigRaised(cornerRadius: 9,
                   stroke: lit ? RigTheme.amber.opacity(0.85) : RigTheme.surfaceEdge,
                   lineWidth: lit ? 1.5 : 1)
        .animation(.easeInOut(duration: 0.25), value: lit)
    }

    /// A half-arc opening upward — the sound leaving a phone that is lying down.
    private struct Arc: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.addArc(center: CGPoint(x: rect.midX, y: rect.maxY),
                        radius: rect.width / 2,
                        startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
            return path
        }
    }
}

// MARK: - 4. Levels and PROCEED

/// A working miniature of the real control panel: the INPUT zone with a meter
/// that answers, the MASTER slider, the latency badge, and PROCEED.
///
/// It is a MINIATURE OF THE REAL THING rather than an abstract diagram on
/// purpose — the next screen the player sees is the panel itself, and a drawing
/// that does not look like it makes the guide a separate app.
struct LevelsIllustration: View {
    let reduceMotion: Bool

    private struct Frame {
        var level: CGFloat = 0
        var master: CGFloat = 0.25
        var proceed: CGFloat = 0
    }

    var body: some View {
        GeometryReader { geo in
            // Centred by SPACERS, not by a greedy frame on the panel itself. The
            // first cut let the card fill the pane, and a control strip stretched
            // to 300 points tall stops being a control strip: the zones drifted
            // apart, the dividers ran floor to ceiling and it read as a table.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if reduceMotion {
                    panel(geo.size, frame: Frame(level: 0.62, master: 0.62, proceed: 1))
                } else {
                    animated(geo.size)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityHidden(true)
    }

    private func animated(_ size: CGSize) -> some View {
        KeyframeAnimator(initialValue: Frame(), repeating: true) { frame in
            panel(size, frame: frame)
        } keyframes: { _ in
            // A guitar is transients: the meter jumps and decays, it does not
            // slide up and down. Same reasoning as the input trim's crest-factor
            // note in AudioEngineController.
            KeyframeTrack(\.level) {
                LinearKeyframe(0.08, duration: 0.35)
                CubicKeyframe(0.72, duration: 0.08)
                CubicKeyframe(0.22, duration: 0.55)
                CubicKeyframe(0.61, duration: 0.08)
                CubicKeyframe(0.16, duration: 0.62)
                CubicKeyframe(0.80, duration: 0.08)
                CubicKeyframe(0.10, duration: 0.85)
                LinearKeyframe(0.08, duration: 0.4)
            }
            KeyframeTrack(\.master) {
                LinearKeyframe(0.25, duration: 0.6)
                CubicKeyframe(0.68, duration: 0.9)
                LinearKeyframe(0.68, duration: 1.1)
                CubicKeyframe(0.25, duration: 0.4)
            }
            KeyframeTrack(\.proceed) {
                LinearKeyframe(0, duration: 1.9)
                CubicKeyframe(1, duration: 0.35)
                LinearKeyframe(1, duration: 0.5)
                CubicKeyframe(0, duration: 0.25)
            }
        }
    }

    private func panel(_ size: CGSize, frame: Frame) -> some View {
        let w = size.width

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                zone(title: "INPUT") {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(frame.level > 0.5 ? RigTheme.signal : RigTheme.hairline)
                                .frame(width: 6, height: 6)
                            Text("iRig HD")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(RigTheme.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(RigTheme.amber)
                        }
                        meter(level: frame.level)
                    }
                }
                divider
                zone(title: "OUTPUT") {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text("Speaker")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(RigTheme.textPrimary)
                                .lineLimit(1)
                                .fixedSize()
                            Text("24 ms")
                                .lineLimit(1)
                                .fixedSize()
                                .font(.system(size: 8.5, weight: .bold).monospacedDigit())
                                .foregroundStyle(RigTheme.signal)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .overlay(Capsule().strokeBorder(RigTheme.signal.opacity(0.6), lineWidth: 1))
                        }
                        meter(level: frame.level * 0.85)
                    }
                }
                divider
                zone(title: "MASTER") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(format: "%+.1f dB", -12 + frame.master * 18))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(RigTheme.textPrimary)
                            .lineLimit(1)
                            .fixedSize()
                        slider(frame.master)
                    }
                }
                divider
                VStack(spacing: 6) {
                    PartLabel(text: "READY")
                    Text("PROCEED")
                        .font(.system(size: 13, weight: .heavy))
                        .tracking(0.8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(RigTheme.amber))
                        .scaleEffect(1 + frame.proceed * 0.05)
                        .shadow(color: RigTheme.amber.opacity(0.7 * frame.proceed), radius: 12)
                }
                .padding(.horizontal, 10)
                .frame(width: w * 0.25)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 12)
        }
        .background(RigTheme.background)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
        .rigCard(cornerRadius: 12)
    }

    /// Full-height inside the strip, but the STRIP is only as tall as its rows —
    /// the same trick `PanelMetrics.rows` plays in the real panel, and for the
    /// same reason: a greedy child makes its parent greedy.
    private var divider: some View {
        Rectangle().fill(RigTheme.hairline.opacity(0.6))
            .frame(width: 1).frame(maxHeight: .infinity)
    }

    private func zone<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PartLabel(text: title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }

    private func meter(level: CGFloat) -> some View {
        HStack(spacing: 1.5) {
            ForEach(0..<14, id: \.self) { segment in
                let threshold = CGFloat(segment) / 14
                Capsule()
                    .fill(threshold < level
                          ? (threshold > 0.82 ? RigTheme.clip : RigTheme.signal)
                          : RigTheme.hairline)
                    .frame(width: 4, height: 8)
            }
        }
    }

    private func slider(_ value: CGFloat) -> some View {
        GeometryReader { track in
            ZStack(alignment: .leading) {
                Capsule().fill(RigTheme.hairline).frame(height: 5)
                Capsule().fill(RigTheme.amber)
                    .frame(width: max(6, track.size.width * value), height: 5)
                Circle().fill(RigTheme.panel)
                    .frame(width: 13, height: 13)
                    .offset(x: max(0, track.size.width * value - 6.5))
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 14)
    }
}

#Preview("Setup guide illustrations") {
    VStack(spacing: 10) {
        PlugInIllustration(reduceMotion: false).frame(height: 130)
        WirelessDelayIllustration(reduceMotion: false).frame(height: 130)
        OutputChoicesIllustration(reduceMotion: false).frame(height: 150)
        LevelsIllustration(reduceMotion: false).frame(height: 110)
    }
    .padding(18)
    .frame(width: 520)
    .background(RigTheme.background)
    .preferredColorScheme(.dark)
}
