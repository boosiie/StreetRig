//
//  ControlPanelView.swift
//  StreetRig
//
//  THE PANEL — the ONE place the audio I/O lives: where the guitar comes in,
//  where the sound goes out, how loud, and the button that starts it.
//
//  TWO HOMES, ONE PANEL. `ControlPanelView` is the shell's copy along the bottom
//  of every page and owns the engine; `ControlPanelSurface` is the panel proper,
//  which the PLAY page (see PlayView) puts across its top with the pedals under
//  it. Same view, same engine instance, so the two can never disagree about the
//  route, the level or whether anything is running.
//
//  FOUR ZONES, ONE THING EACH: INPUT · OUTPUT · MASTER · transport, split by
//  hairlines. The bar this replaces packed a route picker, a 9pt diagnostic line
//  ("LIVE 48k · load 3%") and the engage button into a single undivided row at a
//  size you had to lean in to read. Everything here is sized to be read from
//  standing height with a guitar on, which is the only distance that matters.
//
//  ROUTES, BOTH TAPPABLE — but not equally. INPUT picks a port outright: tap the
//  name, choose one. OUTPUT cannot, because which DEVICE plays is iOS's call
//  (Control Center, plugging in headphones) and the only override a session gets
//  is speaker-or-not — so that, exactly, is what its menu offers and no more.
//  It was plain text here on the grounds that iOS owned the output entirely,
//  which left anyone whose rig was coming out of the EARPIECE nothing to press.
//
//  OUTPUT ALSO CARRIES THE LATENCY, because the port and its cost are one fact.
//  The session has always measured input, output and buffer latency and shown the
//  player none of it, so a 172 ms Bluetooth route looked exactly like a 25 ms
//  wired one and the only symptom was "it feels laggy" with nothing to point at.
//  Measured on the phone: 163 of those 172 ms were the output port alone. Naming
//  a route "wireless" is worth more than the number next to it.
//
//  LEVELS LIVE HERE NOW. Each route carries its own lamp (dark → green when
//  signal arrives → red on clip) and segment bar. That read-out is what the
//  full-screen SIGNAL CHECK existed to show; folded into the panel it answers
//  "am I getting signal" without a second screen to open, collapse and dismiss.
//
//  RE-RENDER ISOLATION: `SignalLamp` and `LevelMeterView` are the only observers
//  of `audio.levels` (~30 Hz), so a meter tick redraws a lamp and a bar — never
//  the panel, the rig stage or the camera preview. The panel body observes the
//  controller, whose published state (routes, status, render load) is all slow.
//
//  NOTE: the Simulator forwards the MAC'S microphone, so Proceed engages and the
//  meters move there — what it can't give you is the iRig's real DI levels. The
//  DEBUG render-test button runs the offline harness over the same graph.
//

import SwiftUI
import StreetRigEngine

/// ONE GRID FOR ALL FOUR ZONES. Every zone is a caption row of the same height
/// over a body of the same height, so the four captions sit on one line across
/// the panel and the four bodies sit on another. Laid out zone-by-zone instead,
/// the rows stagger by a few points each — which is exactly what makes a strip of
/// controls look thrown together rather than built.
private enum PanelMetrics {
    static let caption: CGFloat = 14
    static let body: CGFloat = 41
    static let rowGap: CGFloat = 6
    static let zonePadding: CGFloat = 16
    /// Above and below the rows.
    static let vPadding: CGFloat = 8

    /// The two rows together. Pinned rather than left to the content, because the
    /// dividers are full-height (`maxHeight: .infinity`) and a greedy child inside
    /// the shell's VStack makes the whole panel greedy: it grew ~50pt taller than
    /// its own contents and took the room out of the rig stage.
    static let rows = caption + rowGap + body
}

/// The shell's copy: it OWNS the engine, sits at the bottom of every page, and
/// opens the PLAY page when the player engages.
struct ControlPanelView: View {
    @EnvironmentObject var store: RigStore
    /// Held only to hand onward to the play page's cover — see the injection below.
    @EnvironmentObject private var drag: RigDragController
    @EnvironmentObject private var slotLift: ARSlotLift
    @StateObject private var audio = AudioEngineController()
    @State private var showingPlay = false

    var body: some View {
        ControlPanelSurface(audio: audio, onEngage: { showingPlay = true })
            .onAppear {
                audio.attach(store: store)   // bind the built rig + knobs to the engine
                audio.primeRoutes()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-ShowDeviceOffer") {
                    audio.seedDebugDeviceOffer()
                }
                #endif
            }
            // PROCEED takes you to the pedals. Presented BEFORE `engage()` runs, so
            // if engaging fails the error lands on the page you are already looking
            // at rather than behind it.
            .fullScreenCover(isPresented: $showingPlay) {
                // Every object the play page and its AR slots read, re-injected by
                // hand. A cover is presented from a detached hierarchy, which is why
                // `store` was already passed explicitly — and a missing
                // `@EnvironmentObject` is not a degraded page, it is a crash the
                // moment PROCEED is pressed.
                PlayView(audio: audio)
                    .environmentObject(store)
                    .environmentObject(drag)
                    .environmentObject(slotLift)
            }
            // The new-hardware question, for when something is plugged in while the
            // player is on the rig screen — which is usually WHERE the iRig gets
            // connected, just before Proceed. Forced nil while the play page is up,
            // because that page presents its own copy over its own content and two
            // covers must not race.
            .fullScreenCover(item: Binding(get: { showingPlay ? nil : audio.deviceOffer },
                                           set: { _ in })) { _ in
                DeviceOfferPrompt(audio: audio)
                    .presentationBackground(.clear)
            }
    }
}

/// The panel itself, in both the places it appears: along the bottom of the shell,
/// and across the top of the PLAY page. One view rather than two so the two can't
/// drift apart, and it takes the engine rather than making one — two panels must
/// never mean two engines.
struct ControlPanelSurface: View {
    @ObservedObject var audio: AudioEngineController
    /// Run in ADDITION to engaging, when the player taps PROCEED. The shell uses it
    /// to open the play page; on the page itself there is nowhere left to go, so it
    /// is nil and PROCEED just starts the engine.
    var onEngage: (() -> Void)?
    /// Adds the closing zone at the trailing end. Only the play page passes this —
    /// the shell's panel is not something you dismiss.
    var onDone: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if case .error(let message) = audio.status {
                errorStrip(message)
            }
            HStack(spacing: 0) {
                inputZone
                zoneDivider
                outputZone
                zoneDivider
                masterZone
                zoneDivider
                transportZone
                if let onDone {
                    zoneDivider
                    doneZone(onDone)
                }
            }
            .frame(height: PanelMetrics.rows)
            .padding(.vertical, PanelMetrics.vPadding)
        }
        // Same plate as the nav bar — see `rigChrome`. The two are the top and
        // bottom of one chassis and must be made of the same thing.
        .rigChrome()
        // The error strip changes the panel's height, so the strip arriving would
        // otherwise snap whatever is next to it by 30pt.
        .animation(.easeInOut(duration: 0.2), value: audio.status)
    }

    private var zoneDivider: some View {
        Rectangle()
            .fill(RigTheme.hairline.opacity(0.6))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }

    // MARK: - Routes

    /// The one route that is ours to set. The whole zone is the control, so it
    /// can be hit without aiming.
    private var inputZone: some View {
        Menu {
            if audio.availableInputs.isEmpty {
                Text("No inputs available")
            } else {
                ForEach(audio.availableInputs) { option in
                    Button(option.name) { audio.selectInput(option) }
                }
            }
        } label: {
            RouteZone(title: "INPUT",
                      name: audio.currentInputName,
                      channel: .input,
                      monitor: audio.levels,
                      isLive: audio.isEngaged,
                      selectable: true)
        }
        .frame(maxWidth: .infinity)
    }

    /// iOS names the device; the session may only say speaker-or-not. So this is
    /// a control like INPUT, but a two-item one — the zone still reports the port
    /// that is actually playing, and the menu sets the policy behind it. It also
    /// carries the round-trip read-out, because the port and its latency are the
    /// same fact and belong on the same zone.
    private var outputZone: some View {
        Menu {
            Picker("Output", selection: outputBinding) {
                ForEach(AudioEngineController.OutputChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
        } label: {
            RouteZone(title: "OUTPUT",
                      name: audio.currentOutputName,
                      channel: .output,
                      monitor: audio.levels,
                      isLive: audio.isEngaged,
                      selectable: true,
                      badge: latencyBadge)
        }
        .frame(maxWidth: .infinity)
    }

    private var outputBinding: Binding<AudioEngineController.OutputChoice> {
        Binding(get: { audio.outputChoice }, set: { audio.selectOutput($0) })
    }

    /// THE NUMBER THAT EXPLAINS THE DELAY. The session has always measured input,
    /// output and buffer latency — it just logged them and showed the player
    /// nothing, so a 200 ms wireless route looked identical to an 8 ms wired one
    /// and the only symptom was "it feels laggy". Round trip lives next to the
    /// route that causes it, because on this app the route IS the answer almost
    /// every time: no DSP change can beat A2DP's buffering.
    private var latencyBadge: RouteZone.Badge? {
        let ms = audio.roundTripMs
        guard ms > 0 else { return nil }
        if audio.outputIsWireless {
            // Named explicitly: "wireless" is the actionable word, not the number.
            return .init(text: String(format: "%.0f ms · wireless", ms), warn: true)
        }
        return .init(text: String(format: "%.0f ms", ms), warn: !audio.latencyIsPlayable)
    }

    // MARK: - Master

    private var masterZone: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowGap) {
            HStack(spacing: 6) {
                Text("MASTER")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(RigTheme.textMuted)
                Spacer(minLength: 4)
                Text(masterText)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(RigTheme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(height: PanelMetrics.caption)

            TapSlider(value: masterBinding, in: Self.masterMinDB...Self.masterMaxDB, tint: masterTint)
                .frame(height: PanelMetrics.body)
        }
        .padding(.horizontal, PanelMetrics.zonePadding)
        .frame(width: 186)
    }

    /// MASTER TRAVELS IN DECIBELS, and the stage behind it is a linear gain.
    /// Laid out linearly in gain over a run this wide the fader is unusable —
    /// unity lands a twentieth of the way along and the top of the travel moves
    /// in whole decibels per pixel. In dB the run is even: the same distance
    /// means the same change wherever your thumb is on it.
    ///
    /// The top matches the DSP's own ceiling (128.0 linear = +42 dB); the bottom
    /// is silence rather than −40 dB, because a monitor fader you can't close is
    /// one you have to reach past.
    static let masterMinDB: Double = -40
    static let masterMaxDB: Double = 42

    private var masterBinding: Binding<Double> {
        Binding(get: {
            let db = Double(AudioLevelBus.dbfs(audio.masterLevel))
            return min(Self.masterMaxDB, max(Self.masterMinDB, db))
        }, set: { db in
            audio.masterLevel = db <= Self.masterMinDB ? 0 : Float(pow(10, db / 20))
        })
    }

    /// WHERE CLEAN ENDS. Above this the output stage starts trading the waveform
    /// for level — mirrored from `DSPKernel::kCleanUpToDB`, which is the side that
    /// actually does it.
    static let cleanUpToDB: Double = 12

    /// The fader warms as it crosses out of clean, so the trade the output stage
    /// is making is visible on the control that makes it — no legend to read, and
    /// nothing new to find on a panel meant to be read from standing height.
    private var masterTint: Color {
        let db = Double(AudioLevelBus.dbfs(audio.masterLevel))
        let t = min(1, max(0, (db - Self.cleanUpToDB) / (Self.masterMaxDB - Self.cleanUpToDB)))
        return RigTheme.amber.mix(with: RigTheme.clip, by: t * 0.9)
    }

    private var masterText: String {
        audio.masterLevel < 0.005
            ? "MUTE"
            : String(format: "%+.1f dB", AudioLevelBus.dbfs(audio.masterLevel))
    }

    // MARK: - Transport

    private var transportZone: some View {
        VStack(spacing: PanelMetrics.rowGap) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: audio.isEngaged ? statusColor : .clear, radius: 4)
                Text(statusText)
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .tracking(1.2)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                #if DEBUG
                renderTestButton
                #endif
            }
            .frame(height: PanelMetrics.caption)

            engageButton
                .frame(height: PanelMetrics.body)
                // Just the button, not the whole zone: the tour's step here is
                // about pressing PROCEED, and a spotlight that also took in the
                // status line would be pointing at two things at once.
                .coachMarkTarget(.transportZone)
        }
        .padding(.horizontal, PanelMetrics.zonePadding)
        .frame(width: 188)
    }

    /// One word for what the engine is doing, plus the render load while it runs —
    /// the load is the one number worth a glance on a real-time DSP path. The
    /// sample rate the old bar printed is not: it never changes.
    private var statusText: String {
        switch audio.status {
        case .running:     return "LIVE · \(Int((audio.renderLoad * 100).rounded()))%"
        case .interrupted: return "PAUSED"
        case .error:       return "CAN'T START"
        case .idle:        return "READY"
        }
    }

    private var statusColor: Color {
        switch audio.status {
        case .running: return RigTheme.signal
        case .error:   return RigTheme.clip
        default:       return RigTheme.textMuted
        }
    }

    private var engageButton: some View {
        Button {
            if audio.isEngaged {
                audio.disengage()
            } else {
                onEngage?()
                Task { await audio.engage() }
            }
        } label: {
            Text(audio.isEngaged ? "STOP" : "PROCEED")
                .font(.system(size: 16, weight: .heavy))
                .tracking(1)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(audio.isEngaged ? RigTheme.emberSoft : RigTheme.amber)
                )
        }
    }

    #if DEBUG
    private var renderTestButton: some View {
        Button {
            Task { await audio.runOfflineRender() }
        } label: {
            Image(systemName: audio.lastRenderReport == nil
                  ? "waveform.badge.magnifyingglass"
                  : "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RigTheme.trim)
                .frame(width: 28, height: 20)
                .contentShape(Rectangle())
        }
        .help("Run offline render harness")
    }
    #endif

    // MARK: - Done (play page only)

    /// The way off the play page. Deliberately a zone like any other rather than a
    /// floating X over the camera: it belongs to the panel, and closing the page is
    /// not the same as stopping — the engine keeps running when you leave.
    private func doneZone(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .bold))
                Text("DONE")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1)
            }
            .foregroundStyle(RigTheme.textMuted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .frame(width: 76)
    }

    // MARK: - Failure

    /// Full width across the top of the panel, and only when there is something to
    /// say. The remedy sits beside the message because a failure to engage is
    /// nearly always one of three physical things.
    private func errorStrip(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 12, weight: .semibold))
            Text("· \(Self.remedy(for: message))")
                .font(.system(size: 12))
                .foregroundStyle(RigTheme.textPrimary.opacity(0.85))
            Spacer(minLength: 0)
        }
        .foregroundStyle(RigTheme.clip)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RigTheme.clip.opacity(0.16))
        .overlay(alignment: .bottom) {
            Rectangle().fill(RigTheme.clip.opacity(0.4)).frame(height: 1)
        }
    }

    // Short enough to survive the one line it gets: the message in front of it is
    // the OS's, and can be long.
    private static let captureRemedy = "check the iRig is seated and pick an INPUT."
    private static let noAmpRemedy = "add an amp from the Gear Library."

    /// Nearly every refusal is the capture path failing, so that remedy is the
    /// default. A rig with no amp is the one that isn't: telling someone to reseat
    /// an interface when what's missing is the amp sends them to the wrong end of
    /// the signal chain entirely.
    private static func remedy(for message: String) -> String {
        message == AudioEngineController.noAmpStatus ? noAmpRemedy : captureRemedy
    }
}

// MARK: - A route: what it is, what it's called, what's coming through it

/// One routing zone. Identical for input and output on purpose — the two read as
/// a pair — except that only a selectable route wears the chevron.
private struct RouteZone: View {
    let title: String
    let name: String
    let channel: LevelMeterView.Channel
    let monitor: AudioLevelMonitor
    let isLive: Bool
    /// Draws the "tapping this opens something" chevron. Both routes now do —
    /// INPUT an in-app menu, OUTPUT the system route sheet.
    let selectable: Bool

    /// Optional read-out on the caption row (OUTPUT uses it for round-trip
    /// latency). It rides the CAPTION line, not the body, so it cannot push the
    /// route name around or change the zone's height — the panel is on one shared
    /// grid and a zone that grows steals space from the rig stage.
    struct Badge { let text: String; let warn: Bool }
    var badge: Badge? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowGap) {
            HStack(spacing: 7) {
                SignalLamp(monitor: monitor, channel: channel, isLive: isLive)
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(RigTheme.textMuted)
                    .fixedSize()
                Spacer(minLength: 0)
                if let badge {
                    Text(badge.text)
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(badge.warn ? RigTheme.amber : RigTheme.textMuted)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(height: PanelMetrics.caption)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(RigTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.7)
                    if selectable {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(RigTheme.amber)
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                }
                LevelMeterView(monitor: monitor, channel: channel, isLive: isLive)
            }
            .frame(height: PanelMetrics.body)
        }
        .padding(.horizontal, PanelMetrics.zonePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

#Preview {
    VStack {
        Spacer()
        ControlPanelView()
    }
    .background(RigTheme.background)
    .preferredColorScheme(.dark)
    .environmentObject(RigStore.preview)
    .environmentObject(RigDragController())
    .environmentObject(ARSlotLift())
}
