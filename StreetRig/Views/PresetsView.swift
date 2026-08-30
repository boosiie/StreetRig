//
//  PresetsView.swift
//  StreetRig
//
//  THE PRESETS PAGE: the player's own four rigs, and nine finished ones to start
//  from. Opened by the floating square on the right edge of the rig page (see
//  `MainView.presetsTab`).
//
//  IT IS CALLED PRESETS AND NOT TONES, and the rename came with the four slots
//  rather than before them. A "tone" is what comes out of the speaker; a preset
//  is a stored setup. While the page only held nine of ours the looser word was
//  survivable. The moment the top four rows are things the PLAYER stored, the
//  word has to mean the stored thing or the page is lying about what they are.
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
//  faceplate. `RigPreset.ampHeadline` and `UserPreset.ampHeadline` both resolve
//  the six through `AmpHeadline`, which resolves them the same way
//  `RigGraphCompiler` does, so what is printed is what the engine reads.
//
//  FOUR EMPTY ROWS, NOT AN "+ ADD" BUTTON. The four slots are drawn whether or
//  not they hold anything, because "you get four" is legible at a glance in a way
//  a button is not, and because the slot NUMBER is then stable — which matters
//  the day a release maps a slot to a footswitch. An empty row is selectable and
//  its pane is the save affordance.
//
//  LOADING CLOSES THE PAGE, on purpose, and that is as true of a saved slot as of
//  a factory preset. Everything a preset changes is behind this page — the stage,
//  the rail, the control panel — so staying open would show the player a
//  confirmation instead of the result. The result IS the confirmation.
//
//  THE TWO FAILURE MESSAGES ARE DIFFERENT ON PURPOSE. A factory preset can only
//  fail because THIS APP'S data names gear it does not ship, which is our bug and
//  the copy says so. A saved slot can fail because a catalog update withdrew a
//  model the player's own file names — nobody's bug, and telling them "this app's
//  data is wrong" would be false. One message per cause; see `Failure`.
//
//  LANDSCAPE SHAPE: the list left, the recipe right, the action bar pinned under
//  the recipe rather than scrolling with it. The page is ~340 pt tall once the
//  safe area is off it, and a primary button you have to scroll to find is a
//  button that does not exist.
//

import SwiftUI
import StreetRigEngine

// MARK: - What the page is pointing at

/// Which row is selected. TWO KINDS, one selection: the list now holds the
/// player's four slots and this app's nine presets, and a bare `String` id could
/// not tell them apart — `"2"` is a plausible factory id as well as a slot index.
///
/// `storageID` is the namespaced form that goes into
/// `AppPreferences.lastPresetLoaded`, which is one key holding one answer to
/// "what did you load last". `"slot:2"` cannot collide with `"metal"`, and the
/// prefix is a word rather than a symbol so a developer reading the defaults
/// plist can see what it is.
enum PresetChoice: Hashable {
    case slot(Int)
    case factory(String)

    var storageID: String {
        switch self {
        case .slot(let index):  return UserPresetStore.storageID(forSlot: index)
        case .factory(let id):  return id
        }
    }

    /// The inverse. Returns `nil` for anything unparseable, which the caller
    /// treats the same way it treats an id that no longer names anything: fall
    /// through to the top of the list.
    init?(storageID: String) {
        if storageID.hasPrefix("slot:") {
            guard let index = Int(storageID.dropFirst(5)) else { return nil }
            self = .slot(index)
        } else if storageID.isEmpty {
            return nil
        } else {
            self = .factory(storageID)
        }
    }
}

struct PresetsView: View {
    @EnvironmentObject var store: RigStore
    /// The player's four. Injected alongside `RigStore` in `StreetRigApp` — see
    /// `UserPresetStore`'s header for why it is a store rather than four
    /// `@AppStorage` strings.
    @EnvironmentObject var userPresets: UserPresetStore

    /// Back to the rig. Called by the chrome, by the scrim, and by LOAD.
    var onClose: () -> Void

    @AppStorage(AppPreferences.lastPresetLoaded) private var lastLoadedID = ""

    @State private var selection: PresetChoice = .factory(RigPresets.all.first?.id ?? "")

    /// Why the last LOAD refused, or `nil`. TWO CASES, because there are two
    /// causes and only one of them is our fault — see the file header.
    private enum Failure: Equatable {
        /// This app's own preset data names a model the catalog does not have.
        case ourData
        /// The player's saved slot names gear this build no longer offers.
        case missingGear(String)
    }
    @State private var failure: Failure?

    /// The slot whose name/icon is being edited, and whether to raise the
    /// keyboard for it. `Identifiable` so the editor is rebuilt when the target
    /// changes rather than kept with a stale `draft`.
    private struct EditorTarget: Identifiable, Equatable {
        let slot: Int
        let focusesName: Bool
        var id: Int { slot }
    }
    @State private var editing: EditorTarget?

    /// Slots awaiting a yes. Both destructive and both unrecoverable, so both ask
    /// by name — "Replace MY CRUNCH?" rather than "Replace this preset?".
    @State private var confirmingOverwrite: Int?
    @State private var confirmingDelete: Int?

    private var presets: [RigPreset] { RigPresets.all }

    /// The factory preset the selection names, or the first one. Only read on the
    /// `.factory` branch; the `?? presets[0]` is what keeps it non-optional for
    /// the recipe views rather than a claim that a bad id is fine.
    private var factoryPreset: RigPreset {
        guard case .factory(let id) = selection else { return presets[0] }
        return presets.first { $0.id == id } ?? presets[0]
    }

    var body: some View {
        ZStack {
            RigTheme.background.ignoresSafeArea()

            // The editor takes the WHOLE page while it is up, exactly as
            // `PreferencesView` does inside `ProfileView` — see
            // `PresetEditorView`'s header for why it is not a sheet.
            if let editing, let preset = userPresets.preset(at: editing.slot) {
                PresetEditorView(
                    slot: editing.slot,
                    preset: preset,
                    focusesName: editing.focusesName,
                    onRename: { userPresets.rename(editing.slot, to: $0) },
                    onPickIcon: { userPresets.setIcon($0, for: editing.slot) },
                    onClose: { withAnimation(.easeInOut(duration: 0.26)) { self.editing = nil } })
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(spacing: 0) {
                    titleBar
                    HStack(alignment: .top, spacing: 0) {
                        presetList
                            .frame(width: 250)
                        Rectangle()
                            .fill(RigTheme.hairline)
                            .frame(width: 1)
                            .frame(maxHeight: .infinity)
                        detail
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        // The shell's `.ignoresSafeArea(.keyboard, edges: .bottom)` is on the page
        // stack, and this view is a SIBLING of it in `MainView`'s ZStack — so it
        // has to say the same thing for itself. `MainView`'s comment carries the
        // reasoning: insetting the hierarchy in landscape leaves ~45pt of page.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear {
            // Land on the one they last chose. Falls through to the first factory
            // preset when the stored id names nothing that exists any more — a
            // slot they have since deleted, or a preset id we retired.
            if let choice = PresetChoice(storageID: lastLoadedID), resolves(choice) {
                selection = choice
            }
            #if DEBUG
            // THE DATA CHECKS ITSELF, HERE, because the two ways a preset can be
            // wrong are both silent: a renamed model refuses to load only on the
            // preset that names it, and a mistyped KNOB loads fine and writes the
            // value into a key nothing reads. Both are typos in this app's own
            // data, so they are caught where a developer will see them rather
            // than left for a player to hear. See `RigPresets.problems`.
            //
            // The player's own slots are NOT checked here: their equivalent
            // (`UserPreset.missingModels`) is a runtime check that renders in the
            // shipping UI, because their data is not ours to assert about.
            let problems = RigPresets.problems()
            if !problems.isEmpty {
                print("[presets] \(problems.count) problem(s):\n  " + problems.joined(separator: "\n  "))
            }
            UserDefaults.standard.set(problems, forKey: "streetrig.debug.presetProblems")
            #endif
        }
        .alert("Replace \(confirmingOverwrite.flatMap { userPresets.preset(at: $0)?.displayName } ?? "this preset")?",
               isPresented: Binding(get: { confirmingOverwrite != nil },
                                    set: { if !$0 { confirmingOverwrite = nil } }),
               presenting: confirmingOverwrite) { slot in
            Button("Replace", role: .destructive) {
                confirmingOverwrite = nil
                saveCurrentRig(to: slot, openEditor: false)
            }
            Button("Cancel", role: .cancel) { confirmingOverwrite = nil }
        } message: { slot in
            Text(overwriteMessage(slot))
        }
        .alert("Delete \(confirmingDelete.flatMap { userPresets.preset(at: $0)?.displayName } ?? "this preset")?",
               isPresented: Binding(get: { confirmingDelete != nil },
                                    set: { if !$0 { confirmingDelete = nil } }),
               presenting: confirmingDelete) { slot in
            Button("Delete", role: .destructive) {
                userPresets.clear(slot)
                confirmingDelete = nil
                failure = nil
            }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: { _ in
            Text("The slot goes back to empty. Your rig and your gear are untouched — "
               + "this only forgets the saved copy.")
        }
        .accessibilityAddTraits(.isModal)
    }

    /// Whether a remembered selection still names something. An empty slot does
    /// NOT count: landing the page on the row where a deleted rig used to be is a
    /// small lie about what happened.
    private func resolves(_ choice: PresetChoice) -> Bool {
        switch choice {
        case .slot(let index):  return userPresets.preset(at: index) != nil
        case .factory(let id):  return presets.contains { $0.id == id }
        }
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
                Text("PRESETS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(RigTheme.textMuted)
                // The old line — "a whole rig, dialled in, in one tap" — is now
                // only true of the bottom nine, so it names both halves.
                Text("your four, and nine to start from")
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
                // A GROUP LABEL IS HOW THE PLAYER KNOWS WHICH FOUR ARE THEIRS.
                // Without it, four rows called SLOT 1…4 sitting above CLEAN and
                // BLUES read as more of ours that we forgot to finish.
                groupLabel("MY PRESETS")
                ForEach(0..<UserPreset.slotCount, id: \.self) { index in
                    slotRow(index)
                }
                groupLabel("BUILT IN")
                ForEach(presets) { item in
                    factoryRow(item)
                }
            }
            .padding(.bottom, 10)
        }
        .scrollIndicators(.hidden)
    }

    /// The app's small-bold-caps legend, at the size and weight
    /// `PreferencesView.section(_:)` uses, so the two pages read as one app.
    private func groupLabel(_ text: String) -> some View {
        HStack(spacing: 0) {
            Text(text)
                .rigLegend(9.5, weight: .bold)
                .foregroundStyle(RigTheme.textMuted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 5)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: The two kinds of row
    //
    // Both go through `rowShell`, which is not tidiness: the four slots have to be
    // in the SAME row format as the nine below them or they read as a different
    // kind of object, and two hand-maintained copies of a 40-line row drift within
    // a release. Only the icon, the words and the dimming differ.

    private func factoryRow(_ item: RigPreset) -> some View {
        let isSelected = selection == .factory(item.id)
        return rowShell(isSelected: isSelected,
                        showsLastLoaded: lastLoadedID == item.id,
                        title: item.name,
                        subtitle: item.tagline,
                        accessibility: "\(item.name). \(item.tagline)") {
            Image(systemName: item.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? RigTheme.amber : RigTheme.textMuted)
        } action: {
            select(.factory(item.id))
        }
    }

    private func slotRow(_ index: Int) -> some View {
        let isSelected = selection == .slot(index)
        let saved = userPresets.preset(at: index)
        let loadable = saved?.isLoadable ?? true
        let title = saved?.displayName ?? "EMPTY SLOT"
        // Three second lines for three states, and the empty one says what to DO
        // rather than restating that it is empty.
        let subtitle: String
        if let saved {
            subtitle = loadable ? saved.summary : "Can't load — gear this build no longer has"
        } else {
            subtitle = "Save your rig here"
        }

        return rowShell(isSelected: isSelected,
                        dimmed: saved == nil || !loadable,
                        showsLastLoaded: saved != nil && lastLoadedID == PresetChoice.slot(index).storageID,
                        title: title,
                        subtitle: subtitle,
                        accessibility: "Slot \(index + 1). \(title). \(subtitle)") {
            if let saved {
                PresetIconView(icon: saved.icon, size: 16, muted: !isSelected)
                    .opacity(loadable ? 1 : 0.5)
            } else {
                // A DASHED OUTLINE, not a faded glyph. An empty slot is a place,
                // and a dashed edge is what this app already draws around a place
                // something goes.
                Circle()
                    .strokeBorder(RigTheme.textMuted.opacity(0.55),
                                  style: StrokeStyle(lineWidth: 1, dash: [2.5, 2.5]))
                    .frame(width: 13, height: 13)
            }
        } action: {
            select(.slot(index))
        }
    }

    /// ONE ROW FORMAT for both kinds: icon, bold name, a 9pt muted second line, an
    /// amber left-edge bar when selected, a hairline rule below.
    private func rowShell<Icon: View>(isSelected: Bool,
                                      dimmed: Bool = false,
                                      showsLastLoaded: Bool,
                                      title: String,
                                      subtitle: String,
                                      accessibility: String,
                                      @ViewBuilder icon: () -> Icon,
                                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                icon()
                    .frame(width: 16)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 11.5, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(isSelected ? RigTheme.textPrimary
                                                        : RigTheme.textPrimary.opacity(0.84))
                            .opacity(dimmed ? 0.55 : 1)
                            .lineLimit(1)
                        if showsLastLoaded {
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
                    Text(subtitle)
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
        .accessibilityLabel(accessibility)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func select(_ choice: PresetChoice) {
        withAnimation(.easeInOut(duration: 0.18)) {
            selection = choice
            failure = nil
        }
    }

    // MARK: - The right-hand pane

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .factory:
            factoryDetail
        case .slot(let index):
            if let saved = userPresets.preset(at: index) {
                savedDetail(saved, slot: index)
            } else {
                emptySlotDetail(slot: index)
            }
        }
    }

    // MARK: A factory preset

    private var factoryDetail: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    Text(factoryPreset.blurb)
                        .font(.system(size: 11))
                        .foregroundStyle(RigTheme.textPrimary.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)

                    ampBlock(name: factoryPreset.ampName,
                             cab: factoryPreset.cabName,
                             headline: factoryPreset.ampHeadline)
                    if !factoryPreset.pedals.isEmpty {
                        boardBlock(factoryPreset.pedals.map {
                            (model: $0.model, settings: factoryPreset.settings(for: $0))
                        })
                    }
                    if let note = factoryPreset.note { noteBlock(note) }
                }
                .frame(maxWidth: 500, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            // Keyed on the preset so switching starts at the top of the new
            // recipe rather than halfway down the last one.
            .id(factoryPreset.id)

            factoryLoadBar
        }
    }

    private var factoryLoadBar: some View {
        HStack(spacing: 10) {
            if failure == .ourData {
                // OUR fault, and the copy says so. A factory preset can only fail
                // because this app ships data naming gear it does not ship.
                Label("That preset names gear this build doesn't have. That's ours, not yours.",
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
            loadButton(label: "Load the \(factoryPreset.name) rig")
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
        let count = factoryPreset.pedals.count
        let board = count == 0 ? "" : "\(count) pedal\(count == 1 ? "" : "s")"
        // "the amp and its cab and 3 pedals" is two ANDs in a row; the list only
        // reads as a list once the first join is a comma.
        let what: String
        switch (factoryPreset.cabName == nil, board.isEmpty) {
        case (true, true):   what = "the combo"
        case (true, false):  what = "the combo and \(board)"
        case (false, true):  what = "the amp and its cab"
        case (false, false): what = "the amp, its cab and \(board)"
        }
        return "Loads \(what) onto the rig, and sets every knob above. "
             + "Nothing you own is deleted."
    }

    // MARK: A saved slot

    private func savedDetail(_ saved: UserPreset, slot: Int) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    // WHERE A FACTORY PRESET SHOWS ITS BLURB, this shows what it
                    // is and when it was taken. There is no blurb, tagline or note
                    // for a rig the player saved and inventing one would be this
                    // page making something up about their work.
                    savedHeader(saved)

                    if let problem = saved.loadProblem {
                        brokenBlock(problem)
                    } else {
                        ampBlock(name: saved.ampName,
                                 cab: saved.cabName,
                                 headline: saved.ampHeadline)
                        if !saved.pedals.isEmpty {
                            boardBlock(saved.pedals.map {
                                (model: $0.model, settings: saved.settings(for: $0))
                            })
                        }
                        footswitchBlock(saved)
                        Text("Loads the whole rig above and sets every knob back to where it "
                           + "was when you saved. Nothing you own is deleted.")
                            .font(.system(size: 9.5))
                            .foregroundStyle(RigTheme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 500, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .id(saved.id)

            savedActionBar(saved, slot: slot)
        }
    }

    private func savedHeader(_ saved: UserPreset) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                PresetIconView(icon: saved.icon, size: 18)
                Text(saved.displayName)
                    .font(.system(size: 14, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(RigTheme.textPrimary)
                Spacer(minLength: 0)
            }
            Text("\(saved.summary) · saved \(saved.savedAtText)")
                .font(.system(size: 9.5))
                .foregroundStyle(RigTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The honest sentence for a slot that names gear this build withdrew. It is
    /// deliberately NOT the "that's ours, not yours" line the factory bar prints:
    /// nobody typed this wrong, a catalog update moved under a file the player
    /// wrote months ago, and the only useful thing to say is which gear and what
    /// they can still do.
    private func brokenBlock(_ problem: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(RigTheme.clip)
                    .padding(.top, 1)
                Text(problem)
                    .font(.system(size: 10.5))
                    .foregroundStyle(RigTheme.textPrimary.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Nothing is wrong with your rig — this slot just points at gear the app "
               + "no longer offers, so it can't be put back. You can delete the slot and "
               + "save over it.")
                .font(.system(size: 9.5))
                .foregroundStyle(RigTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rigCard(cornerRadius: 9, stroke: RigTheme.clip.opacity(0.45))
    }

    /// WHAT A FACTORY PRESET HAS NO EQUIVALENT FOR. A recipe has no opinion about
    /// where your feet go; a snapshot recorded exactly that, so the pane prints it
    /// — otherwise the one thing the slot restores that no other preset does would
    /// be invisible until the player walked to the AR page.
    private func footswitchBlock(_ saved: UserPreset) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            heading("FOOTSWITCHES")
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(saved.arSlots.enumerated()), id: \.offset) { index, slot in
                    HStack(spacing: 6) {
                        Text("\(index + 1)")
                            .font(.system(size: 8, weight: .heavy).monospacedDigit())
                            .foregroundStyle(.black)
                            .frame(width: 13, height: 13)
                            .background(Circle().fill(RigTheme.trim))
                        Text(slot.model ?? "empty")
                            .font(.system(size: 10.5, weight: slot.model == nil ? .regular : .semibold))
                            .foregroundStyle(slot.model == nil ? RigTheme.textMuted
                                                               : RigTheme.textPrimary)
                        if slot.model != nil {
                            Text(slot.isOn ? "ON" : "OFF")
                                .font(.system(size: 7.5, weight: .heavy))
                                .tracking(0.6)
                                .foregroundStyle(slot.isOn ? RigTheme.signal : RigTheme.textMuted)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .overlay(Capsule().strokeBorder(
                                    (slot.isOn ? RigTheme.signal : RigTheme.textMuted).opacity(0.55),
                                    lineWidth: 1))
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Footswitch \(index + 1): "
                        + (slot.model.map { "\($0), \(slot.isOn ? "on" : "off")" } ?? "empty"))
                }
            }
        }
    }

    /// RENAME · ICON · REPLACE · DELETE on the left, LOAD on the right — in the
    /// same bar the factory pane pins its LOAD to, so the primary action never
    /// moves between the two kinds of row.
    ///
    /// A BROKEN SLOT LOSES LOAD AND KEEPS EVERYTHING ELSE. LOAD goes because it
    /// is the one thing the slot cannot honestly offer. REPLACE deliberately
    /// STAYS: saving the current rig over a dead slot is exactly the repair the
    /// message in `brokenBlock` tells the player about, and removing the button
    /// would leave that sentence pointing at nothing.
    private func savedActionBar(_ saved: UserPreset, slot: Int) -> some View {
        HStack(spacing: 6) {
            Button("RENAME") { openEditor(slot: slot, focusesName: true) }
                .buttonStyle(.rigSecondary)
                .accessibilityLabel("Rename \(saved.displayName)")
            Button("ICON") { openEditor(slot: slot, focusesName: false) }
                .buttonStyle(.rigSecondary)
                .accessibilityLabel("Change the icon for \(saved.displayName)")
            Button("REPLACE") { confirmingOverwrite = slot }
                .buttonStyle(.rigSecondary)
                .accessibilityLabel("Save the current rig over \(saved.displayName)")
            Button("DELETE") { confirmingDelete = slot }
                .buttonStyle(.rigDestructive)
                .accessibilityLabel("Delete \(saved.displayName)")

            Spacer(minLength: 6)

            if case .missingGear(let why) = failure {
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(RigTheme.clip)
                    .fixedSize(horizontal: false, vertical: true)
            } else if saved.isLoadable {
                loadButton(label: "Load \(saved.displayName)")
            }
        }
        .font(.system(size: 10, weight: .bold))
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Rectangle().fill(RigTheme.hairline).frame(height: 1)
        }
    }

    // MARK: An empty slot

    /// SAYS WHAT IS ABOUT TO BE SAVED, from the actual snapshot rather than from a
    /// description of one. `store.snapshot` is cheap and it is the same call SAVE
    /// makes, so the list on this pane cannot drift away from what lands in the
    /// slot the way a hand-written summary would.
    private func emptySlotDetail(slot: Int) -> some View {
        let preview = store.snapshot(slot: slot, name: "", icon: .fallback)
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SLOT \(slot + 1) IS EMPTY")
                            .font(.system(size: 14, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(RigTheme.textPrimary)
                        Text("Save the rig you have right now here, then load it back any "
                           + "time — the amp, the board, every knob, and your footswitches.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(RigTheme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if store.hasAmp {
                        VStack(alignment: .leading, spacing: 5) {
                            heading("WHAT GETS SAVED")
                            ampBlock(name: preview.ampName,
                                     cab: preview.cabName,
                                     headline: preview.ampHeadline)
                            if !preview.pedals.isEmpty {
                                boardBlock(preview.pedals.map {
                                    (model: $0.model, settings: preview.settings(for: $0))
                                })
                            }
                            Text("\(preview.knobCount) knob values in all, plus the three "
                               + "footswitches as they stand.")
                                .font(.system(size: 9.5))
                                .foregroundStyle(RigTheme.textMuted)
                        }
                    } else {
                        // A rig with no amp is a legal, loudly-signposted state
                        // (see `RigStore.hasAmp`) — it is just not a rig worth
                        // photographing, and SAVE says why rather than going grey
                        // for no stated reason.
                        Label("Your rig has no amp, so there is nothing to save yet. "
                            + "Put an amp on the stage first.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(RigTheme.clip)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 500, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .id("empty-\(slot)")

            saveBar(slot: slot)
        }
    }

    /// The SAVE action sits exactly where LOAD sits for a factory preset. Same
    /// bar, same corner, same size: the pane's primary action does not move around
    /// depending on which row you are on.
    private func saveBar(slot: Int) -> some View {
        HStack(spacing: 10) {
            Text("Saved here on this device only. Nothing is uploaded.")
                .font(.system(size: 9.5))
                .foregroundStyle(RigTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button {
                saveCurrentRig(to: slot, openEditor: true)
            } label: {
                Text("SAVE CURRENT RIG")
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(1.4)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(store.hasAmp ? RigTheme.amber
                                                            : RigTheme.surfaceRaised))
            }
            .buttonStyle(.plain)
            .disabled(!store.hasAmp)
            .accessibilityLabel("Save the current rig into slot \(slot + 1)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Rectangle().fill(RigTheme.hairline).frame(height: 1)
        }
    }

    // MARK: - Blocks shared by both kinds of pane

    private func ampBlock(name: String, cab: String?,
                          headline: [(label: String, value: Double)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            heading("THE AMP")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RigTheme.textPrimary)
                if let cab {
                    Text("→ \(cab)")
                        .font(.system(size: 10))
                        .foregroundStyle(RigTheme.textMuted)
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            settingRow(headline)
        }
    }

    private func boardBlock(_ pedals: [(model: String,
                                        settings: [(label: String, value: Double)])]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            heading("THE BOARD")
            ForEach(Array(pedals.enumerated()), id: \.offset) { index, pedal in
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
                    settingRow(pedal.settings)
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

    private func loadButton(label: String) -> some View {
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
        .accessibilityLabel(label)
    }

    // MARK: - Doing things

    private func load() {
        switch selection {
        case .factory(let id):
            guard let preset = presets.first(where: { $0.id == id }) else { return }
            guard store.apply(preset) else {
                withAnimation(.easeOut(duration: 0.2)) { failure = .ourData }
                return
            }
            lastLoadedID = id
        case .slot(let index):
            guard let saved = userPresets.preset(at: index) else { return }
            guard store.apply(saved) else {
                // `apply` only refuses for one reason, and `loadProblem` is the
                // player-facing form of it. The fallback covers the case where a
                // slot claims to be loadable and the store still says no, which
                // would be a bug here rather than in their file.
                let why = saved.loadProblem ?? "That slot names gear this build doesn't have."
                withAnimation(.easeOut(duration: 0.2)) { failure = .missingGear(why) }
                return
            }
            lastLoadedID = PresetChoice.slot(index).storageID
        }
        onClose()
    }

    /// Photograph the rig into a slot.
    ///
    /// THE SLOT IS FILLED FIRST AND NAMED SECOND, which is why `openEditor` is a
    /// parameter rather than something this decides. A first save opens the editor
    /// immediately so naming is one continuous gesture; a REPLACE does not, because
    /// the slot already has a name the player chose and reopening the editor would
    /// look like the app had forgotten it. Either way the rig is on disk before the
    /// editor appears, so backing out of naming never costs the save.
    private func saveCurrentRig(to slot: Int, openEditor: Bool) {
        guard store.hasAmp else { return }
        let existing = userPresets.preset(at: slot)
        let snapshot = store.snapshot(slot: slot,
                                      name: existing?.name ?? "",
                                      icon: existing?.icon ?? .fallback)
        userPresets.save(snapshot, to: slot)
        withAnimation(.easeInOut(duration: 0.18)) {
            selection = .slot(slot)
            failure = nil
        }
        guard openEditor else { return }
        withAnimation(.easeInOut(duration: 0.26)) {
            editing = EditorTarget(slot: slot, focusesName: true)
        }
    }

    private func openEditor(slot: Int, focusesName: Bool) {
        withAnimation(.easeInOut(duration: 0.26)) {
            editing = EditorTarget(slot: slot, focusesName: focusesName)
        }
    }

    /// NAMES WHAT IS BEING LOST, because a slot is unrecoverable once overwritten
    /// and "are you sure?" over an unnamed thing is a question nobody can answer.
    private func overwriteMessage(_ slot: Int) -> String {
        guard let existing = userPresets.preset(at: slot) else { return "" }
        let incoming = store.snapshot(slot: slot, name: "", icon: .fallback)
        return "\(existing.displayName) — \(existing.summary), saved \(existing.savedAtText) — "
             + "is replaced by your rig as it is now: \(incoming.summary). "
             + "The old one can't be got back."
    }
}

#Preview("Presets — empty slots", traits: .landscapeLeft) {
    // Fails loudly here rather than quietly under a LOAD button — see
    // `RigPresets.problems`.
    let problems = RigPresets.problems()
    assert(problems.isEmpty, "preset data: \(problems)")
    return PresetsView(onClose: {})
        .environmentObject(RigStore.preview)
        .environmentObject(UserPresetStore.preview)
        .preferredColorScheme(.dark)
}

#Preview("Presets — two slots filled", traits: .landscapeLeft) {
    // `previewFilled` deliberately includes a slot naming withdrawn gear, so the
    // greyed "can't load" row and its pane are checkable without hand-editing a
    // JSON file on a device.
    PresetsView(onClose: {})
        .environmentObject(RigStore.preview)
        .environmentObject(UserPresetStore.previewFilled)
        .preferredColorScheme(.dark)
}
