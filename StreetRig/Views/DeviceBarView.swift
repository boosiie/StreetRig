//
//  DeviceBarView.swift
//  StreetRig
//
//  Bottom bar: input / output device pickers and the engage ("Proceed") button.
//  This is the UI hook onto the audio engine — Proceed starts/stops live
//  monitoring through the AVAudioEngine graph, and the INPUT picker chooses the
//  capture route (the iRig, once connected). Output shows the current route.
//
//  NOTE: the Simulator has no audio input, so Proceed will report an error there
//  by design; the DEBUG "render test" affordance runs the offline harness, which
//  is the Simulator verification path. Live monitoring is a physical-device test.
//
//  With `FeatureFlags.signalCheck` on, Proceed ALSO opens the full-screen signal
//  check (SignalCheckView) — meters, routing and the working stomp slots. It is
//  presented on every tap, not only on a successful engage: a screen whose job is
//  explaining why there's no sound has to be visible precisely when there isn't.
//

import SwiftUI
import StreetRigEngine

struct DeviceBarView: View {
    @EnvironmentObject var store: RigStore
    @StateObject private var audio = AudioEngineController()
    @State private var showingSignalCheck = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            inputPicker
            outputDisplay

            VStack(alignment: .trailing, spacing: 4) {
                statusLine
                HStack(spacing: 8) {
                    #if DEBUG
                    renderTestButton
                    #endif
                    engageButton
                }
            }
            .frame(width: 190)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RigTheme.background.opacity(0.95))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
        }
        .onAppear {
            audio.attach(store: store)   // bind the built rig + knobs to the engine
            audio.primeRoutes()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ShowDeviceOffer") {
                audio.seedDebugDeviceOffer()
            }
            #endif
        }
        .fullScreenCover(isPresented: $showingSignalCheck) {
            // Dismissing this cover leaves the engine running by design — the
            // player goes back to the rig still hearing themselves.
            SignalCheckView(audio: audio)
                .environmentObject(store)
        }
        // The new-hardware question, for when something is plugged in while the
        // player is on the rig screen — which is usually WHERE the iRig gets
        // connected, just before Proceed. Forced nil while the check is up,
        // because that screen presents its own copy over its own content and two
        // covers must not race. Presented as a cover rather than an overlay so it
        // can darken the whole app: this bar is 70pt tall.
        .fullScreenCover(item: Binding(get: { showingSignalCheck ? nil : audio.deviceOffer },
                                       set: { _ in })) { _ in
            DeviceOfferPrompt(audio: audio)
                .presentationBackground(.clear)
        }
    }

    // MARK: - Input / output

    private var inputPicker: some View {
        Menu {
            if audio.availableInputs.isEmpty {
                Text("No inputs available")
            } else {
                ForEach(audio.availableInputs) { option in
                    Button(option.name) { audio.selectInput(option) }
                }
            }
        } label: {
            DropdownChrome(label: "INPUT", value: audio.currentInputName)
        }
        .frame(maxWidth: .infinity)
    }

    private var outputDisplay: some View {
        DropdownChrome(label: "OUTPUT", value: audio.currentOutputName)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Status + engage

    private var statusLine: some View {
        Text(statusText)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(statusColor)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var statusText: String {
        switch audio.status {
        case .running:
            let load = Int((audio.renderLoad * 100).rounded())
            let sr = audio.grantedSampleRate > 0 ? " · \(Int(audio.grantedSampleRate/1000))k" : ""
            return "LIVE\(sr) · load \(load)%"
        case .interrupted: return "PAUSED"
        case .error(let m): return m.uppercased()
        case .idle:        return "READY"
        }
    }

    private var statusColor: Color {
        switch audio.status {
        case .running: return RigTheme.amber
        case .error:   return Color(red: 0.9, green: 0.4, blue: 0.3)
        default:       return RigTheme.textMuted
        }
    }

    private var engageButton: some View {
        Button {
            if audio.isEngaged {
                audio.disengage()
            } else {
                // Present FIRST, engage second: the check screen has to be up to
                // show the failure if `engage()` throws (always, on the Simulator).
                //
                // The no-amp refusal is the ONE case that deliberately does not
                // open it, for the same reason the rest of them do. The signal
                // check is about the CAPTURE path — its fixed remedy line is
                // "check the iRig is seated" — which is the wrong advice for a
                // rig with no amp in it, and it would cover the stage banner and
                // the status line that do explain it. `engage()` refuses and
                // reports on its own (see AudioEngineController.noAmpStatus), so
                // the reason lands in the status line right beside this button.
                // The button itself is never disabled: a dead button with no
                // explanation is exactly the failure this is here to prevent.
                if FeatureFlags.signalCheck && store.hasAmp { showingSignalCheck = true }
                Task { await audio.engage() }
            }
        } label: {
            Text(audio.isEngaged ? "Stop" : "Proceed")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(audio.isEngaged ? RigTheme.emberSoft : RigTheme.amber)
                )
        }
        .frame(maxWidth: .infinity)
    }

    #if DEBUG
    private var renderTestButton: some View {
        Button {
            Task { await audio.runOfflineRender() }
        } label: {
            Image(systemName: audio.lastRenderReport == nil
                  ? "waveform.badge.magnifyingglass"
                  : "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(RigTheme.trim)
                .frame(width: 40, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(RigTheme.backgroundLift)
                )
        }
        .help("Run offline render harness")
    }
    #endif
}

/// The dropdown look from the original bar, reused for the live pickers here and
/// on the signal-check screen, so the two route UIs can't drift apart.
struct DropdownChrome: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1)
                .foregroundStyle(RigTheme.textMuted)
            HStack {
                Text(value).font(.footnote).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down").font(.caption2)
            }
            .foregroundStyle(RigTheme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(RigTheme.backgroundLift)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    VStack {
        Spacer()
        DeviceBarView()
    }
    .background(RigTheme.background)
    .preferredColorScheme(.dark)
    .environmentObject(RigStore.preview)
}
