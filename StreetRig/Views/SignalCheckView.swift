//
//  SignalCheckView.swift
//  StreetRig
//
//  THE SIGNAL CHECK. Full-screen, opened by Proceed: the one place where
//  plugging a guitar into the iRig produces something you can SEE (live input /
//  output meters) and HEAR (live monitoring through the rig) at the same time —
//  standing over your pedals, where you'd actually be.
//
//  Before this screen the only feedback was a 9pt "LIVE 48k · load 3%" label. If
//  the guitar was silent — bad cable, wrong input route, volume rolled off, iRig
//  not seated — nothing on screen told you, and the app looked broken when the
//  signal chain was. A meter turns that guess into a fact.
//
//  WHY IT OPENS EVEN WHEN ENGAGING FAILED: diagnosing "why is there no sound" is
//  the screen's whole job, so it has to be visible exactly when `engage()` threw.
//  (It is also the only way to see it on the Simulator, which has no audio input
//  and therefore always fails.) The failure is shown on the screen itself.
//
//  Dismissing returns to the rig with monitoring STILL LIVE — closing the check
//  is not the same as stopping. Stop is its own control here.
//
//  Gated by `FeatureFlags.signalCheck`.
//

import SwiftUI
import StreetRigEngine

struct SignalCheckView: View {
    /// Held UNOBSERVED on purpose. Every live read-out below sits in a subview
    /// that observes what it needs, so a meter tick (~30 Hz) or a render-load
    /// update never re-renders this body — and therefore never re-renders the
    /// AR slots or the camera preview underneath it.
    let audio: AudioEngineController

    @Environment(\.dismiss) private var dismiss

    /// Collapsed, the level panel folds away and the pedals get the whole screen —
    /// which is what you want once the signal is confirmed and you're playing.
    /// The header stays: it is the only way back to the panel, and to Stop.
    @State private var panelCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            SignalCheckHeader(audio: audio) { dismiss() }
            if !panelCollapsed {
                SignalCheckStrip(audio: audio)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            collapseHandle
            ARPedalContentView()
        }
        .background(RigTheme.background)
        .animation(.easeInOut(duration: 0.22), value: panelCollapsed)
        .overlay {
            // Asked here rather than as a system alert so the "don't ask again"
            // choice can sit in the same card as the answer it qualifies.
            DeviceOfferPrompt(audio: audio)
        }
    }

    /// The panel's bottom edge, and the grab handle for folding it away. It sits
    /// OUTSIDE the collapsed content on purpose — it is the only way to get the
    /// panel back, so it has to survive the collapse. Full width and tappable
    /// across all of it: this is a control you reach for with a guitar in your
    /// hands, so it should not demand aim.
    private var collapseHandle: some View {
        Button {
            panelCollapsed.toggle()
        } label: {
            ZStack {
                RigTheme.backgroundLift
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(RigTheme.amber)
                    // Up = fold the panel away; down = pull it back.
                    .rotationEffect(.degrees(panelCollapsed ? 180 : 0))
            }
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { hairline }
        .overlay(alignment: .bottom) { hairline }
        .accessibilityLabel(panelCollapsed ? "Show levels" : "Hide levels")
    }

    private var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
    }
}

// MARK: - Header: what the engine is doing, and how to stop it

private struct SignalCheckHeader: View {
    @ObservedObject var audio: AudioEngineController
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("SIGNAL CHECK")
                .font(.system(size: 14, weight: .heavy))
                .tracking(2)
                .foregroundStyle(RigTheme.panel)

            statusPill

            Spacer(minLength: 8)

            Text(audio.latencyLine())
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(RigTheme.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            transportButton
            doneButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(RigTheme.backgroundLift)
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: audio.isEngaged ? statusColor : .clear, radius: 4)
            Text(statusLabel)
                .font(.system(size: 12, weight: .bold))
                .tracking(1)
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(statusColor.opacity(0.14)))
    }

    private var statusLabel: String {
        switch audio.status {
        case .running:
            let load = Int((audio.renderLoad * 100).rounded())
            return "LIVE · LOAD \(load)%"
        case .interrupted: return "PAUSED"
        case .error:       return "NO SIGNAL PATH"
        case .idle:        return "STOPPED"
        }
    }

    private var statusColor: Color {
        switch audio.status {
        case .running: return RigTheme.signal
        case .error:   return RigTheme.clip
        default:       return RigTheme.textMuted
        }
    }

    /// Covers the device bar's Stop button while this screen is up — and offers
    /// the way back in, so a failed engage can be retried without dismissing.
    private var transportButton: some View {
        Button {
            if audio.isEngaged { audio.disengage() }
            else { Task { await audio.engage() } }
        } label: {
            Text(audio.isEngaged ? "Stop" : "Start")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 74)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(audio.isEngaged ? RigTheme.emberSoft : RigTheme.amber)
                )
        }
    }

    /// Closing the check screen does NOT stop monitoring.
    private var doneButton: some View {
        Button(action: onDone) {
            Text("Done")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(RigTheme.textPrimary)
                .frame(width: 70)
                .padding(.vertical, 9)
                .rigRaised(cornerRadius: 8)
        }
    }
}

// MARK: - Strip: levels, routing, monitoring volume

private struct SignalCheckStrip: View {
    @ObservedObject var audio: AudioEngineController

    var body: some View {
        VStack(spacing: 6) {
            // The meters no longer take whatever is left over: the route pickers
            // and the master are the controls you actually reach for, and at the
            // old widths their labels were truncating.
            // Widths are a three-way compromise on a phone in landscape: the route
            // pickers need enough room for a real device name, the master needs a
            // slider worth dragging, and the meters need to fit a title, a level
            // and a CLIP lamp on one line at the larger type.
            HStack(alignment: .top, spacing: 20) {
                meters.frame(maxWidth: .infinity)
                routes.frame(width: 205)
                masterVolume.frame(width: 190)
            }
            if case .error(let message) = audio.status {
                errorBanner(message)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    // MARK: Meters

    /// Route names come from `audio` (rare changes); the bars come from
    /// `audio.levels`, which only `LevelMeterView` observes.
    private var meters: some View {
        VStack(spacing: 10) {
            LevelMeterView(monitor: audio.levels, channel: .input,
                           title: "INPUT", subtitle: audio.currentInputName,
                           isLive: audio.isEngaged)
            LevelMeterView(monitor: audio.levels, channel: .output,
                           title: "OUTPUT", subtitle: audio.currentOutputName,
                           isLive: audio.isEngaged)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Routing

    private var routes: some View {
        VStack(spacing: 8) {
            Menu {
                if audio.availableInputs.isEmpty {
                    Text("No inputs available")
                } else {
                    ForEach(audio.availableInputs) { option in
                        Button(option.name) { audio.selectInput(option) }
                    }
                }
            } label: {
                DropdownChrome(label: "INPUT (CAPTURE)", value: audio.currentInputName)
            }
            // Read-only: iOS picks the output route (Control Center / plugging in
            // headphones changes it), so this reports rather than commands.
            DropdownChrome(label: "OUTPUT (iOS PICKS)", value: audio.currentOutputName)
        }
    }

    // MARK: Monitoring volume

    private var masterVolume: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("MASTER")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(RigTheme.textMuted)
                Spacer()
                Text(masterText)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(RigTheme.textPrimary)
            }
            TapSlider(value: masterBinding, in: 0...2)
            Text("Monitoring level (DSP output stage)")
                .font(.system(size: 11))
                .foregroundStyle(RigTheme.textMuted.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var masterBinding: Binding<Double> {
        Binding(get: { Double(audio.masterLevel) },
                set: { audio.masterLevel = Float($0) })
    }

    private var masterText: String {
        audio.masterLevel < 0.005
            ? "MUTE"
            : String(format: "%+.1f dB", AudioLevelBus.dbfs(audio.masterLevel))
    }

    // MARK: Failure

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 11, weight: .semibold))
            Text("· \(Self.remedy)")
                .font(.system(size: 11))
                .foregroundStyle(RigTheme.textPrimary.opacity(0.85))
            Spacer(minLength: 0)
        }
        .foregroundStyle(RigTheme.clip)
        .lineLimit(2)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(RigTheme.clip.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(RigTheme.clip.opacity(0.5), lineWidth: 1)
        )
    }

    private static let remedy =
        "Check the iRig is seated, pick INPUT above, and confirm the guitar volume is up. "
        + "The Simulator has no audio input, so live monitoring is a physical-device test."
}

// MARK: - "Something got plugged in" — ask before switching

/// Asked when hardware appears while the app is running. Nothing is switched
/// until it is answered, EXCEPT that iOS has already moved the output route by
/// the time we hear about it — so for an output this asks whether to keep what
/// iOS chose or fall back to the speaker, which is the only override a session
/// gets. Inputs are ours to set, so nothing changes unless you say so.
struct DeviceOfferPrompt: View {
    @ObservedObject var audio: AudioEngineController
    @State private var remember = false

    var body: some View {
        if let offer = audio.deviceOffer {
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea()
                card(offer)
            }
            .transition(.opacity)
        }
    }

    private func card(_ offer: AudioEngineController.DeviceOffer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: offer.kind == .input ? "cable.connector" : "headphones")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(RigTheme.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text(offer.kind == .input ? "New input detected" : "New output detected")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(RigTheme.textPrimary)
                    Text(offer.name)
                        .font(.system(size: 14))
                        .foregroundStyle(RigTheme.textMuted)
                        .lineLimit(1)
                }
            }

            Text(offer.kind == .input
                 ? "Switch the guitar input over to it?"
                 : "Keep listening through it?")
                .font(.system(size: 14))
                .foregroundStyle(RigTheme.textPrimary.opacity(0.9))

            Button {
                remember.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: remember ? "checkmark.square.fill" : "square")
                        .font(.system(size: 15))
                        .foregroundStyle(remember ? RigTheme.amber : RigTheme.textMuted)
                    Text("Don't ask me this again")
                        .font(.system(size: 13))
                        .foregroundStyle(RigTheme.textMuted)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                choice("Not now", filled: false) {
                    audio.resolveDeviceOffer(offer, adopt: false, remember: remember)
                    remember = false
                }
                choice(offer.kind == .input ? "Use it" : "Keep it", filled: true) {
                    audio.resolveDeviceOffer(offer, adopt: true, remember: remember)
                    remember = false
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        // A modal asking a question over the live screen, so it floats.
        .rigCard(cornerRadius: 16, lifted: true)
    }

    private func choice(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(filled ? .black : RigTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                // Filled = amber IS the surface; the other choice is a raised key
                // on the sheet it sits in.
                .background {
                    if filled {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(RigTheme.amber)
                    } else {
                        Color.clear.rigRaised(cornerRadius: 10)
                    }
                }
        }
    }
}

// MARK: - Shared dropdown chrome

/// The dropdown look from the device bar, shared so the two route pickers can
/// never drift apart. (Defined in DeviceBarView.swift.)

#Preview("Signal check") {
    SignalCheckView(audio: AudioEngineController())
        .environmentObject(RigStore.preview)
        .preferredColorScheme(.dark)
}
