//
//  CreditsView.swift
//  StreetRig
//
//  Attribution for third-party assets. This is a LEGAL SURFACE, not decoration:
//  the stage model ships under CC BY 4.0, whose one condition is that the
//  attribution travels with the work and stays reachable by whoever has the app.
//  A comment in the source would not satisfy that — a shipped user cannot read it.
//
//  CC BY 4.0 asks for four things, and "indicate if changes were made" is the one
//  that is easy to forget: StreetRig strips the source scene's bass and combo amps
//  and rescales the platform, so `modifications` is filled in and rendered.
//
//  Adding an asset later means appending one `Credit` to `Credits.all` — the view
//  is a list, so nothing else needs touching.
//

import SwiftUI
import StreetRigEngine

// MARK: - Data

/// One third-party asset and everything its licence requires be shown.
struct Credit: Identifiable {
    let id = UUID()
    /// What the thing is inside StreetRig, in the user's terms — not the filename.
    let usedFor: String
    let title: String
    let author: String
    /// Where the original lives. Shown and tappable, because "source" under CC
    /// means a link to the material, not just a name.
    let sourceURL: URL
    let licenseName: String
    let licenseURL: URL
    /// What StreetRig changed. `nil` for an asset used verbatim.
    let modifications: String?
}

enum Credits {
    static let all: [Credit] = [
        Credit(
            usedFor: "Rig stage — the wooden platform, mic stand, stool, cables and overhead lamp",
            title: "Before concert",
            author: "LP Cupcake",
            sourceURL: URL(string: "https://skfb.ly/oDS96")!,
            licenseName: "CC BY 4.0",
            licenseURL: URL(string: "http://creativecommons.org/licenses/by/4.0/")!,
            modifications: "Bass and combo amps removed; platform rescaled and rotated to fit the rig."
        )
    ]
}

// MARK: - View

struct CreditsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            RigTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("StreetRig is built on work generously shared by others. "
                             + "Each asset below is used under the licence named with it.")
                            .font(.footnote)
                            .foregroundStyle(RigTheme.textMuted)
                            .padding(.bottom, 2)

                        ForEach(Credits.all) { credit in
                            card(for: credit)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("CREDITS")
                .rigLegend(12, weight: .bold)
                .foregroundStyle(RigTheme.textMuted)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(RigTheme.amberChrome)
                    .frame(width: 44, height: 30)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
        }
    }

    private func card(for credit: Credit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(credit.usedFor.uppercased())
                .rigLegend(11, weight: .bold)
                .foregroundStyle(RigTheme.amberChrome)

            // Title and author, the two things attribution is actually about.
            (Text(credit.title).font(.headline).foregroundStyle(RigTheme.textPrimary)
             + Text("  by  ").font(.subheadline).foregroundStyle(RigTheme.textMuted)
             + Text(credit.author).font(.subheadline.weight(.semibold)).foregroundStyle(RigTheme.textPrimary))

            HStack(spacing: 16) {
                Link(destination: credit.sourceURL) {
                    Label("View original", systemImage: "arrow.up.right.square")
                        .font(.footnote.weight(.medium))
                }
                Link(destination: credit.licenseURL) {
                    Label(credit.licenseName, systemImage: "checkmark.seal")
                        .font(.footnote.weight(.medium))
                }
            }
            .tint(RigTheme.amberChrome)

            if let mods = credit.modifications {
                Text("Changes made: \(mods)")
                    .font(.caption)
                    .foregroundStyle(RigTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RigTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(RigTheme.surfaceEdge, lineWidth: 1)
        }
    }
}

#Preview {
    CreditsView()
}
