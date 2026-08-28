//
//  PresetsView.swift
//  StreetRig
//
//  THE TONES PAGE: nine finished rigs, one tap each. Opened by the floating
//  square on the right edge of the rig page (see `MainView.presetsTab`).
//
//  WHY IT IS A PAGE OVER THE SHELL AND NOT A FIFTH PAGER PAGE. `AppPage`'s four
//  are places you LIVE — build a rig, browse gear, set the floor up, be
//  yourself. This is a thing you do and leave, in about ten seconds, and the
//  pager charges a permanent fifth dot and a longer swipe for it. It is also a
//  destructive-feeling action, and putting it behind a deliberate button rather
//  than one swipe past the rig is the right amount of friction.
//
//  IT PRINTS EVERY KNOB IT IS ABOUT TO TURN, and that is the whole design. A
//  preset page that says "METAL" and a button is a black box, and a black box in
//  an app whose subject is what knobs do teaches nothing. The detail pane is a
//  RECIPE: this head, this cab, these three pedals, these six amp settings. Load
//  it, then go and look at the amp — every number on this screen is on that
//  faceplate. `RigPreset.ampHeadline` resolves the six the same way
//  `RigGraphCompiler` does, so what is printed is what the engine reads.
//
//  LOADING CLOSES THE PAGE, on purpose. Everything a preset changes is behind
//  this page — the stage, the rail, the control panel — so staying open would
//  show the player a confirmation instead of the result. The result IS the
//  confirmation.
//
//  LANDSCAPE SHAPE: the list left, the recipe right, the LOAD bar pinned under
//  the recipe rather than scrolling with it. The page is ~340 pt tall once the
//  safe area is off it, and a primary button you have to scroll to find is a
//  button that does not exist.
//

import SwiftUI
import StreetRigEngine

struct PresetsView: View {
    @EnvironmentObject var store: RigStore

    /// Back to the rig. Called by the chrome, by the scrim, and by LOAD.
    var onClose: () -> Void

    @AppStorage(AppPreferences.lastPresetLoaded) private var lastLoadedID = ""

    @State private var selectedID: String = RigPresets.all.first?.id ?? ""
    /// Set only when `RigStore.apply` refuses — which means this app's own preset
    /// data names a model the catalog does not have. It cannot be caused by
    /// anything the player did, so it says so rather than blaming them.
    @State private var failed = false

    private var presets: [RigPreset] { RigPresets.all }
    private var preset: RigPreset {
        presets.first { $0.id == selectedID } ?? presets[0]
    }

    var body: some View {
        ZStack {
            RigTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                titleBar
                HStack(alignment: .top, spacing: 0) {
                    presetList
                        .frame(width: 250)
                    Rectangle()
                        .fill(RigTheme.hairline)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                    recipe
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear {
            // Land on the one they last chose. Falls through to the first when
            // the stored id names a preset that no longer exists.
            if presets.contains(where: { $0.id == lastLoadedID }) { selectedID = lastLoadedID }
            #if DEBUG
            // THE DATA CHECKS ITSELF, HERE, because the two ways a preset can be
            // wrong are both silent: a renamed model refuses to load only on the
            // preset that names it, and a mistyped KNOB loads fine and writes the
            // value into a key nothing reads. Both are typos in this app's own
            // data, so they are caught where a developer will see them rather
            // than left for a player to hear. See `RigPresets.problems`.
            let problems = RigPresets.problems()
            if !problems.isEmpty {
                print("[presets] \(problems.count) problem(s):\n  " + problems.joined(separator: "\n  "))
            }
            UserDefaults.standard.set(problems, forKey: "streetrig.debug.presetProblems")
            #endif
        }
        .accessibilityAddTraits(.isModal)
    }

    // MARK: - Chrome

    private var titleBar: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                    Text("Rig")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(RigTheme.amber)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to the rig")

            Spacer(minLength: 0)
            VStack(spacing: 1) {
                Text("TONE PRESETS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(RigTheme.textMuted)
                Text("a whole rig, dialled in, in one tap")
                    .font(.system(size: 8.5))
                    .foregroundStyle(RigTheme.textMuted.opacity(0.7))
            }
            Spacer(minLength: 0)
            // Balances the back button so the title sits centred — the same
            // trick `PreferencesView.titleBar` plays.
            Color.clear.frame(width: 44, height: 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(RigTheme.hairline).frame(height: 1)
        }
    }

    // MARK: - The list

    private var presetList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(presets) { item in
                    row(item)
                }
            }
            .padding(.bottom, 10)
        }
        .scrollIndicators(.hidden)
    }

    private func row(_ item: RigPreset) -> some View {
        let isSelected = item.id == preset.id
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedID = item.id
                failed = false
            }
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? RigTheme.amber : RigTheme.textMuted)
                    .frame(width: 16)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(item.name)
                            .font(.system(size: 11.5, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(isSelected ? RigTheme.textPrimary
                                                        : RigTheme.textPrimary.opacity(0.84))
                        if item.id == lastLoadedID {
                            // "LAST LOADED", not "current" — see the note on
                            // `AppPreferences.lastPresetLoaded` for why the
                            // weaker claim is the only true one.
                            Text("LAST LOADED")
                                .font(.system(size: 6.5, weight: .heavy))
                                .tracking(0.6)
                                .foregroundStyle(RigTheme.signal)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .overlay(Capsule().strokeBorder(RigTheme.signal.opacity(0.55), lineWidth: 1))
                        }
                        Spacer(minLength: 0)
                    }
                    Text(item.tagline)
                        .font(.system(size: 9))
                        .foregroundStyle(RigTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(alignment: .leading) {
                if isSelected {
                    HStack(spacing: 0) {
                        Rectangle().fill(RigTheme.amber).frame(width: 2.5)
                        Rectangle().fill(RigTheme.amber.opacity(0.08))
                    }
                }
            }
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(RigTheme.hairline).frame(height: 1).padding(.leading, 16)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.name). \(item.tagline)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - The recipe

    private var recipe: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    Text(preset.blurb)
                        .font(.system(size: 11))
                        .foregroundStyle(RigTheme.textPrimary.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)

                    ampBlock
                    if !preset.pedals.isEmpty { boardBlock }
                    if let note = preset.note { noteBlock(note) }
                }
                .frame(maxWidth: 500, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            // Keyed on the preset so switching starts at the top of the new
            // recipe rather than halfway down the last one.
            .id(preset.id)

            loadBar
        }
    }

    private var ampBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            heading("THE AMP")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(preset.ampName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RigTheme.textPrimary)
                if let cab = preset.cabName {
                    Text("→ \(cab)")
                        .font(.system(size: 10))
                        .foregroundStyle(RigTheme.textMuted)
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            settingRow(preset.ampHeadline)
        }
    }

    private var boardBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading("THE BOARD")
            ForEach(Array(preset.pedals.enumerated()), id: \.offset) { index, pedal in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("\(index + 1)")
                            .font(.system(size: 8, weight: .heavy).monospacedDigit())
                            .foregroundStyle(.black)
                            .frame(width: 13, height: 13)
                            .background(Circle().fill(RigTheme.trim))
                        Text(pedal.model)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(RigTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    settingRow(preset.settings(for: pedal))
                        .padding(.leading, 19)
                }
            }
        }
    }

    private func noteBlock(_ note: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "lightbulb")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(RigTheme.trim)
                .padding(.top, 1)
            Text(note)
                .font(.system(size: 10))
                .foregroundStyle(RigTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rigCard(cornerRadius: 9)
    }

    /// The knob settings as a wrapping row of chips. A chip rather than a line of
    /// text because the eye reads "GAIN 8" as one thing, and because at nine
    /// settings a comma-separated sentence stops being scannable.
    private func settingRow(_ settings: [(label: String, value: Double)]) -> some View {
        // `WrappingHStack` does not exist in this project and a Layout for four
        // chips is not worth writing — a flow of fixed-size chips inside a
        // `FlowLayout` is what `ViewThatFits` cannot do, so this uses SwiftUI's
        // own wrapping via a lazy grid with adaptive columns.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 78, maximum: 130), spacing: 5,
                                    alignment: .leading)],
                  alignment: .leading, spacing: 5) {
            ForEach(Array(settings.enumerated()), id: \.offset) { _, setting in
                HStack(spacing: 4) {
                    Text(setting.label)
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(RigTheme.textMuted)
                        .lineLimit(1)
                    Text(Self.dial(setting.value))
                        .font(.system(size: 9.5, weight: .heavy).monospacedDigit())
                        .foregroundStyle(RigTheme.amber)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .rigRaised(cornerRadius: 5)
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold))
            .tracking(1.5)
            .foregroundStyle(RigTheme.trim)
    }

    /// 6.0 prints as "6" and 4.5 as "4.5" — a knob is spoken about in halves, and
    /// "6.0" reads like a measurement rather than a setting.
    private static func dial(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    // MARK: - Loading

    private var loadBar: some View {
        HStack(spacing: 10) {
            if failed {
                Label("That preset names gear this build doesn't have.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(RigTheme.clip)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // SAID EVERY TIME, not once in a corner. Loading rearranges the
                // board somebody may have spent an hour on, and the one thing
                // they need to know before pressing is that it is only the BOARD
                // — no gear is deleted, so the way back is a drag, not a
                // reinstall.
                Text(loadSummary)
                    .font(.system(size: 9.5))
                    .foregroundStyle(RigTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button(action: load) {
                Text("LOAD")
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(1.4)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(RigTheme.amber))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Load the \(preset.name) rig")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Rectangle().fill(RigTheme.hairline).frame(height: 1)
        }
    }

    /// SAYS WHAT IT WILL ACTUALLY DO, which for a combo is not "the amp and the
    /// cab" — a combo IS the cab, and a sentence that names a second box the
    /// preset never adds is the kind of small wrongness that makes a player stop
    /// reading the rest.
    private var loadSummary: String {
        let count = preset.pedals.count
        let board = count == 0 ? "" : "\(count) pedal\(count == 1 ? "" : "s")"
        // "the amp and its cab and 3 pedals" is two ANDs in a row; the list only
        // reads as a list once the first join is a comma.
        let what: String
        switch (preset.cabName == nil, board.isEmpty) {
        case (true, true):   what = "the combo"
        case (true, false):  what = "the combo and \(board)"
        case (false, true):  what = "the amp and its cab"
        case (false, false): what = "the amp, its cab and \(board)"
        }
        return "Loads \(what) onto the rig, and sets every knob above. "
             + "Nothing you own is deleted."
    }

    private func load() {
        guard store.apply(preset) else {
            withAnimation(.easeOut(duration: 0.2)) { failed = true }
            return
        }
        lastLoadedID = preset.id
        onClose()
    }
}

#Preview(traits: .landscapeLeft) {
    // Fails loudly here rather than quietly under a LOAD button — see
    // `RigPresets.problems`.
    let problems = RigPresets.problems()
    assert(problems.isEmpty, "preset data: \(problems)")
    return PresetsView(onClose: {})
        .environmentObject(RigStore.preview)
        .preferredColorScheme(.dark)
}
