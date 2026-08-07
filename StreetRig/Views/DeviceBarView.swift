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

import SwiftUI

struct DeviceBarView: View {
    @EnvironmentObject var store: RigStore
    @StateObject private var audio = AudioEngineController()

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
            if audio.isEngaged { audio.disengage() }
            else { Task { await audio.engage() } }
        } label: {
            Text(audio.isEngaged ? "Stop" : "Proceed")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(audio.isEngaged ? Color(red: 0.9, green: 0.5, blue: 0.3) : RigTheme.amber)
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

/// The dropdown look from the original bar, reused for the live pickers.
private struct DropdownChrome: View {
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
