//
//  DeviceBarView.swift
//  StreetRig
//
//  Bottom bar: input / output device dropdowns and a Proceed button.
//  All inactive for now — placeholders until audio I/O is wired up.
//

import SwiftUI

struct DeviceBarView: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            FakeDropdown(label: "INPUT", value: "—")
            FakeDropdown(label: "OUTPUT", value: "—")

            Button(action: {}) {
                Text("Proceed")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(RigTheme.amber)
                    )
            }
            .frame(width: 110)
            .opacity(0.4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RigTheme.background.opacity(0.95))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
        }
        .disabled(true) // entire bar inactive for now
    }
}

private struct FakeDropdown: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1)
                .foregroundStyle(RigTheme.textMuted)
            HStack {
                Text(value).font(.footnote)
                Spacer()
                Image(systemName: "chevron.down").font(.caption2)
            }
            .foregroundStyle(RigTheme.textMuted)
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
        .opacity(0.55)
    }
}

#Preview {
    VStack {
        Spacer()
        DeviceBarView()
    }
    .background(RigTheme.background)
    .preferredColorScheme(.dark)
}
