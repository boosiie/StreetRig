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

    var body: some View {
        VStack(spacing: 0) {
            SignalCheckHeader(audio: audio) { dismiss() }
            SignalCheckStrip(audio: audio)
            Divider().overlay(Color.white.opacity(0.07))
            ARPedalContentView()
        }
        .background(RigTheme.background)
    }
}

// MARK: - Header: what the engine is doing, and how to stop it

private struct SignalCheckHeader: View {
    @ObservedObject var audio: AudioEngineController
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("SIGNAL CHECK")
                .font(.system(size: 12, weight: .heavy))
                .tracking(2)
                .foregroundStyle(RigTheme.panel)

            statusPill

            Spacer(minLength: 8)

            Text(audio.latencyLine())
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(RigTheme.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            transportButton
            doneButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(RigTheme.backgroundLift)
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: audio.isEngaged ? statusColor : .clear, radius: 4)
            Text(statusLabel)
                .font(.system(size: 10, weight: .bold))
                .tracking(1)
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
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
                .font(.footnote.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 66)
                .padding(.vertical, 8)
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
                .font(.footnote.weight(.semibold))
                .foregroundStyle(RigTheme.textPrimary)
                .frame(width: 62)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(RigTheme.surface)
                )
        }
    }
}

// MARK: - Strip: levels, routing, monitoring volume

private struct SignalCheckStrip: View {
    @ObservedObject var audio: AudioEngineController

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 18) {
                meters
                routes.frame(width: 190)
                masterVolume.frame(width: 170)
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
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(RigTheme.textMuted)
                Spacer()
                Text(masterText)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(RigTheme.textPrimary)
            }
            TapSlider(value: masterBinding, in: 0...2)
            Text("Monitoring level (DSP output stage)")
                .font(.system(size: 9))
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

// MARK: - Shared dropdown chrome

/// The dropdown look from the device bar, shared so the two route pickers can
/// never drift apart. (Defined in DeviceBarView.swift.)

#Preview("Signal check") {
    SignalCheckView(audio: AudioEngineController())
        .environmentObject(RigStore.preview)
        .preferredColorScheme(.dark)
}
