//
//  PresetEditorView.swift
//  StreetRig
//
//  NAMING A SAVED SLOT, and choosing the mark that stands for it.
//
//  IN-PAGE, NEVER A SHEET, and that is the first decision here. The app is
//  landscape-locked and `PresetsView` is under 390 points tall on a phone; a
//  `.sheet` on a screen that shape is a letterbox with a text field in it, and
//  the system's own sheet chrome eats a third of what is left. So this follows
//  the pattern `ProfileView` uses for `PreferencesView` — a `@State` flag in the
//  parent and a `.move(edge:).combined(with: .opacity)` transition — and takes
//  the whole page while it is up.
//
//  THE KEYBOARD IS THE HARD PART, exactly as it is on the profile page, and the
//  answer is the same one. `MainView` tells the shell to ignore the keyboard's
//  safe area (its comment explains why: insetting the hierarchy would leave every
//  page about 45 points tall), so the keyboard simply COVERS the bottom of the
//  app. That puts the burden here: the name field is the FIRST thing in this
//  view, above everything else, so ~230 points of keyboard can come up without
//  ever reaching it. The icon grid is below it and does not have to be reachable
//  with the keyboard up — you pick a picture, or you dismiss and pick one.
//
//  IT WRITES THROUGH AS YOU TYPE. There is no OK/Cancel pair: the slot is already
//  saved by the time this appears (see `PresetsView.saveCurrentRig`), so this is
//  editing a thing that exists, not filling in a form that might be abandoned.
//  DONE is a way out, not a commit. That also means a player who backs out of
//  here still has their rig — which is the whole point of the feature and worth
//  more than a tidy transaction.
//
//  THE NAME LIMIT IS ENFORCED IN `@State`, NOT IN THE BINDING. `ProfileView.draft`
//  carries the full reasoning and it applies here verbatim: a clamping `Binding`
//  leaves the store correct while the field on screen goes on showing the
//  characters it dropped, because UIKit owns the text view's buffer. Writing the
//  clamped value back into the `@State` the field is bound to is what actually
//  stops the field dead.
//

import SwiftUI
import StreetRigEngine

// MARK: - Drawing one preset icon

/// One `PresetIcon`, at `size` points. The whole app's answer to "draw this
/// slot's mark", so the list row, the recipe pane and the picker cannot disagree
/// about what a case looks like.
///
/// The nine SF Symbols are drawn bare, which is how the nine factory rows draw
/// theirs — a saved slot has to sit visually alongside them, not announce itself
/// as a different kind of thing. The four StreetRig marks go through `AvatarView`
/// rather than being redrawn here, so a plectrum on a preset row is the same
/// plectrum as a plectrum on the profile page; that view draws a disc, which at
/// this size reads as a small badge and is the price of not having a second
/// slightly-different plectrum in the codebase.
struct PresetIconView: View {
    let icon: PresetIcon
    var size: CGFloat = 16
    /// Drawn back, for an unselected row. TWO MECHANISMS FOR ONE EFFECT, because
    /// the two halves of the set are drawn by different things: a symbol simply
    /// takes `RigTheme.textMuted`, while a drawn mark goes through `AvatarView`,
    /// which only accepts an `AvatarTint` — and that enum has no muted case. The
    /// palette rule says do not invent a colour here, so the drawn ones dim
    /// instead. Both land at about the same weight against the row's ground; the
    /// alternative was an unselected plectrum sitting bright amber next to nine
    /// grey symbols, which is what this exists to stop.
    var muted: Bool = false

    var body: some View {
        Group {
            if let symbol = icon.systemImage {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.78, weight: .semibold))
                    .foregroundStyle(muted ? RigTheme.textMuted : RigTheme.amber)
            } else if let style = icon.drawnStyle {
                // `AvatarTint.amber` IS `RigTheme.amber`, so a drawn mark and a
                // symbol land on the same colour when neither is muted.
                AvatarView(style: style, tint: .amber, size: size, showsEdge: false)
                    .opacity(muted ? 0.55 : 1)
            }
        }
        .frame(width: size, height: size)
        // The artwork never speaks for itself — the row or the tile that contains
        // it owns the label, so VoiceOver says "MY CRUNCH, Marswell JCM800" once
        // instead of that plus "Plectrum avatar in Ember".
        .accessibilityHidden(true)
    }
}

// MARK: - The editor

struct PresetEditorView: View {
    /// The slot being edited, 0-based.
    let slot: Int
    /// What it is called and what it looks like right now.
    let preset: UserPreset
    /// Whether to put the keyboard up on appear. True when the player has just
    /// pressed SAVE and this is the naming step; false when they came in from
    /// CHANGE ICON, where raising a keyboard over the grid they came to use would
    /// be actively unhelpful.
    var focusesName: Bool = true
    var onRename: (String) -> Void
    var onPickIcon: (PresetIcon) -> Void
    var onClose: () -> Void

    @FocusState private var nameFocused: Bool

    /// What the FIELD holds. See the file header, and `ProfileView.draft` for the
    /// full argument about why this is not a clamping `Binding` onto the store.
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // FIRST, and it has to stay first — see the header's note on
                    // the keyboard.
                    nameField
                    livePreview
                    iconGrid
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .background(RigTheme.background)
        .onAppear {
            draft = preset.name
            if focusesName { nameFocused = true }
        }
        .toolbar {
            // The keyboard's own way out, for the case where the field is the only
            // thing not covered. Same as `ProfileView`'s.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { commit() }
                    .tint(RigTheme.amberChrome)
            }
        }
    }

    // MARK: - Chrome

    private var titleBar: some View {
        HStack(spacing: 10) {
            Button {
                commit()
                onClose()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                    Text("Presets")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(RigTheme.amber)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to the preset list")

            Spacer(minLength: 0)
            VStack(spacing: 1) {
                Text("SLOT \(slot + 1)")
                    .rigLegend(10, weight: .bold)
                    .foregroundStyle(RigTheme.textMuted)
                Text("name it, and pick its mark")
                    .font(.system(size: 8.5))
                    .foregroundStyle(RigTheme.textMuted.opacity(0.7))
            }
            Spacer(minLength: 0)

            Button {
                commit()
                onClose()
            } label: {
                Text("DONE")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(RigTheme.amber))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done editing this preset")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(RigTheme.hairline).frame(height: 1)
        }
    }

    // MARK: - The name

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel("NAME")
            HStack(spacing: 6) {
                ZStack(alignment: .leading) {
                    // Hand-rolled placeholder rather than `prompt:`, for the reason
                    // `ProfileView` gives: the system placeholder colour is a
                    // neutral grey, the one colour this palette does not contain.
                    if draft.isEmpty {
                        Text("Name this rig")
                            .font(.system(size: 12))
                            .foregroundStyle(RigTheme.textMuted.opacity(0.8))
                    }
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RigTheme.textPrimary)
                        .tint(RigTheme.amberChrome)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .onSubmit { commit() }
                        .accessibilityLabel("The name of this preset")
                }

                // Only once the limit is actually in reach. A permanent "3/18"
                // beside an empty box is a demand, not information.
                if draft.count >= UserPreset.nameLimit - 5 {
                    Text("\(draft.count)/\(UserPreset.nameLimit)")
                        .font(.system(size: 9, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(draft.count >= UserPreset.nameLimit
                                         ? RigTheme.amberChrome : RigTheme.textMuted)
                }

                if nameFocused {
                    // A visible exit that does not depend on finding the keyboard's
                    // accessory bar, which on a short landscape screen is easy to
                    // miss and easy to cover with a thumb.
                    Button("DONE") { commit() }
                        .buttonStyle(.rigSecondary)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .rigRaised(cornerRadius: RigTheme.Radius.tight,
                       stroke: nameFocused ? RigTheme.amberChrome.opacity(0.8) : RigTheme.surfaceEdge)
            .animation(.easeOut(duration: 0.15), value: nameFocused)
            .onChange(of: draft) { _, typed in
                let clamped = UserPreset.clamp(typed)
                if clamped != typed { draft = clamped }   // this is what stops the field
                onRename(clamped)
            }
        }
    }

    /// The row as the list will draw it, live. Cheap, and it is the only way to
    /// see that a 16-character name and a plectrum actually sit together before
    /// leaving the page — the grid below shows the marks in isolation, which is
    /// not the same question.
    private var livePreview: some View {
        HStack(alignment: .top, spacing: 9) {
            PresetIconView(icon: preset.icon, size: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.isEmpty ? UserPreset.fallbackName(forSlot: slot) : draft)
                    .font(.system(size: 11.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(RigTheme.textPrimary)
                Text(preset.summary)
                    .font(.system(size: 9))
                    .foregroundStyle(RigTheme.textMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 250, alignment: .leading)
        .rigCard(cornerRadius: RigTheme.Radius.control)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview: \(draft.isEmpty ? UserPreset.fallbackName(forSlot: slot) : draft), \(preset.summary)")
    }

    // MARK: - The icons

    /// Thirteen discs. A grid rather than the horizontal two-row strip
    /// `AvatarStripView` uses, because this page has the whole width — the profile
    /// page had to share its column with a 66pt avatar and a name field, which is
    /// why fourteen avatars had to scroll sideways there and thirteen marks do not
    /// have to here.
    private var iconGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("ICON")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 40, maximum: 40), spacing: 9,
                                         alignment: .leading)],
                      alignment: .leading, spacing: 9) {
                ForEach(PresetIcon.allCases) { option in
                    tile(option)
                }
            }
            .padding(.vertical, 3)      // room for the selection ring to sit proud
            .padding(.horizontal, 3)
        }
    }

    private func tile(_ option: PresetIcon) -> some View {
        let isSelected = option == preset.icon
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { onPickIcon(option) }
        } label: {
            // EVERY TILE IS A DISC, symbols included. Four of the thirteen are
            // drawn by `AvatarView`, which is a disc by construction; leaving the
            // other nine as bare glyphs made the grid read as two sets of things
            // rather than one set of choices.
            ZStack {
                if option.drawnStyle == nil {
                    Circle().fill(RigTheme.surfaceRaised)
                    if !isSelected {
                        Circle().strokeBorder(RigTheme.surfaceEdge, lineWidth: 1)
                    }
                }
                // A symbol sits INSIDE the 32pt disc; a drawn mark IS the disc, so
                // it is handed the full 32 rather than being inset twice.
                PresetIconView(icon: option, size: option.drawnStyle == nil ? 20 : 32)
            }
            .frame(width: 32, height: 32)
            .overlay {
                // The same amber ring the avatar strip uses. On a page where the
                // tiles are all the same colour, a ring is the only mark that
                // cannot be mistaken for the artwork.
                if isSelected { Circle().strokeBorder(RigTheme.amberChrome, lineWidth: 2) }
            }
            .padding(3)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Committing

    /// Trim on the way OUT, not on every keystroke — eating the space you just
    /// typed between two words is maddening. An empty name falls back to the slot
    /// number in `UserPresetStore.rename`, which is the one place that decision
    /// lives.
    private func commit() {
        nameFocused = false
        onRename(draft)
    }
}

#Preview("Preset editor", traits: .landscapeLeft) {
    @Previewable @State var name = "MY CRUNCH"
    @Previewable @State var icon: PresetIcon = .pick
    let store = UserPresetStore.previewFilled
    var preset = store.slots[0]!
    preset.name = name
    preset.icon = icon
    return PresetEditorView(slot: 0,
                            preset: preset,
                            focusesName: false,
                            onRename: { name = $0 },
                            onPickIcon: { icon = $0 },
                            onClose: {})
        .frame(width: 854, height: 372)
        .background(RigTheme.background)
        .preferredColorScheme(.dark)
}
