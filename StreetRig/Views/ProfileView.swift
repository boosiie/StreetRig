//
//  ProfileView.swift
//  StreetRig
//
//  The PROFILE page — the fourth page in the shell's pager, to the right of AR.
//
//  Every other screen in this app is about gear. This one is about the person
//  holding it: a name, an avatar, and the way into the app's settings.
//
//  SETTINGS LIVES BEHIND A BUTTON, not in the right-hand column. It was that
//  column for one release, which made this two unrelated screens sharing a
//  hairline and left neither with the width it wanted. `PreferencesView` is now
//  its own page (see `settingsEntry`), and this one is about the player.
//
//  THE GEAR RAIL STANDS DOWN HERE. `MainView` hides it on this page and only
//  this page — there is nothing on PROFILE to drag gear onto, so all it did was
//  take 150 points off the one page whose subject is not gear. That reclaimed
//  width is why `identityWidth` is 360 rather than the 262 it started at.
//
//  Identity scrolls. Not because it is long, but because the page height is a
//  number that changes: an iPhone SE in landscape, or a taller error strip on
//  the control panel below, both eat into it, and content that scrolls a little
//  is content that never clips.
//
//  THE KEYBOARD IS THE HARD PART HERE. In landscape it covers well over half the
//  screen, and SwiftUI's default answer — shrink the whole hierarchy to sit above
//  it — would squeeze the shell's top nav plus the control panel into what is
//  left and leave the page about 45 points tall. `MainView` therefore tells the
//  shell to ignore the keyboard's safe area (see the comment there), which puts
//  the burden back here: the name field has to be near the TOP of this page so
//  the keyboard never reaches it. That is why identity is the first thing in the
//  left column and the avatar strip is below it, and not the other way round.
//

import SwiftUI
import StreetRigEngine

struct ProfileView: View {
    @EnvironmentObject private var profile: ProfileStore
    @FocusState private var nameFocused: Bool

    /// What the FIELD holds, mirrored back into the store on every change.
    ///
    /// The obvious version binds the field straight to the store through a
    /// clamping `Binding`, and it half-works: the stored name is correctly cut to
    /// 24 characters, but the field goes on showing all 29 you typed. UIKit owns
    /// the text view's buffer, and a binding whose setter quietly returns a
    /// different value than it was given does not reliably make SwiftUI push the
    /// correction back down into it — so the limit is enforced somewhere the
    /// player cannot see, which is the same as not enforced.
    ///
    /// Writing the clamped value back into a `@State` the field is bound to DOES
    /// push it down: the field stops dead at 24 characters, which is what a limit
    /// is supposed to look like.
    @State private var draft = ""

    /// Settings is a page of its own now, reached from `settingsEntry`. Page
    /// state rather than a sheet: the app is landscape-locked and a sheet on a
    /// ~400 pt-tall screen is a letterbox with a settings list inside it.
    @State private var showingSettings = false

    /// Cap, not a fixed width — see the header. Sized off the widest thing in the
    /// column (a 66pt avatar plus a name field that has to hold 24 characters),
    /// and no wider: every point spent here comes straight out of the preferences
    /// column, where it buys a preference row one fewer wrapped line.
    private let identityWidth: CGFloat = 360

    var body: some View {
        ZStack {
            // Tapping the empty page puts the keyboard away. Sits behind the
            // columns so it only ever catches taps that hit nothing else.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { nameFocused = false }

            // SETTINGS IS A PLACE YOU GO, NOT A COLUMN YOU SCROLL PAST.
            //
            // It used to be the right-hand half of this page, which made the
            // profile page two unrelated screens sharing a divider: who you are
            // on the left, every switch in the app on the right. Neither got the
            // width it wanted and the page had no subject. Behind a button, the
            // profile page is about the player and the settings page is about
            // settings, and each gets the whole screen.
            if showingSettings {
                PreferencesView(onClose: {
                    withAnimation(.easeInOut(duration: 0.26)) { showingSettings = false }
                })
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                HStack(alignment: .top, spacing: 18) {
                    identityColumn
                        .frame(maxWidth: identityWidth)
                        .layoutPriority(1)
                        // The tour's last stop, and its second in-page target. Like
                        // the rig stage's, this one reports from inside the pager
                        // bridge and is validated before it is believed.
                        .coachMarkTarget(.profileIdentity)

                    Rectangle()
                        .fill(RigTheme.hairline)
                        .frame(width: 1)

                    settingsEntry
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        // The keyboard's own way out, for the case where the field is the only
        // thing on screen and there is no empty page left to tap.
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { nameFocused = false }
                    .tint(RigTheme.amberChrome)
            }
        }
    }

    // MARK: - The way into settings

    /// One button, and what is behind it. The list of section names is not
    /// decoration: a button labelled only SETTINGS makes you open it to find out
    /// whether the thing you want is in there, and the four words underneath
    /// answer that without a tap.
    private var settingsEntry: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                nameFocused = false
                withAnimation(.easeInOut(duration: 0.26)) { showingSettings = true }
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(RigTheme.amberChrome)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Settings")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(RigTheme.textPrimary)
                        Text("Audio devices · Display · Data & privacy · Help & guides")
                            .font(.system(size: 10))
                            .foregroundStyle(RigTheme.textMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(RigTheme.textMuted.opacity(0.7))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
                .rigCard(cornerRadius: RigTheme.Radius.control)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 360, alignment: .leading)
            .accessibilityHint("Opens settings")

            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    // MARK: - Identity

    private var identityColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                nameRow
                AvatarTintRow(tint: tintBinding)
                privacyNote
                AvatarStripView(avatar: avatarBinding, tint: profile.profile.tint, tileSize: 29)
            }
            .padding(.bottom, 2)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    /// The live preview, the name it belongs to, and the field that sets it.
    ///
    /// The tint swatches sit on the line BELOW this rather than under the avatar
    /// strip further down: tapping a colour has to change something you are
    /// already looking at, and from down there they were both off the bottom of
    /// the column and 150pt away from the only thing they visibly affect.
    private var nameRow: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(style: profile.profile.avatar, tint: profile.profile.tint, size: 62)

            VStack(alignment: .leading, spacing: 6) {
                // `displayName`, never the raw field — an empty name renders as
                // "Player One" here rather than as a hole where a name should be.
                Text(profile.profile.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(RigTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                nameField
            }
        }
    }

    private var nameField: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                // Hand-rolled placeholder rather than `prompt:`. The system
                // placeholder colour is `.placeholderText` — a neutral grey, and
                // the one colour this palette does not contain.
                if draft.isEmpty {
                    Text("Add your name")
                        .font(.system(size: 12))
                        .foregroundStyle(RigTheme.textMuted.opacity(0.8))
                }
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RigTheme.textPrimary)
                    .tint(RigTheme.amberChrome)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .onSubmit {
                        profile.commitUsername()
                        nameFocused = false
                    }
                    .accessibilityLabel("Your name, stored on this device only")
            }

            // Only appears when the limit is actually in reach. A permanent "3/24"
            // beside an empty box is a demand, not information.
            if draft.count >= Profile.usernameLimit - 6 {
                Text("\(draft.count)/\(Profile.usernameLimit)")
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(draft.count >= Profile.usernameLimit
                                     ? RigTheme.amberChrome : RigTheme.textMuted)
            }

            if nameFocused {
                // A visible exit that does not depend on finding the keyboard's
                // accessory bar — which, on a short landscape screen, is easy to
                // miss and easy to cover with a thumb.
                Button("DONE") { nameFocused = false }
                    .buttonStyle(.rigSecondary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .rigRaised(cornerRadius: RigTheme.Radius.tight,
                   stroke: nameFocused ? RigTheme.amberChrome.opacity(0.8) : RigTheme.edgeBrass)
        .animation(.easeOut(duration: 0.15), value: nameFocused)
        // The field is loaded from the store once, then mirrors INTO it. See
        // `draft` for why the field does not simply bind to the store.
        .onAppear { draft = profile.profile.username }
        .onChange(of: draft) { _, typed in
            let clamped = Profile.clamp(typed)
            if clamped != typed { draft = clamped }   // this is what stops the field
            profile.profile.username = clamped
        }
        .onChange(of: profile.profile.username) { _, stored in
            // ONLY while the field is not being typed into, and that guard is the
            // whole trick. Without it the two directions race: a keystroke sets the
            // store, the store's change comes back here, and by then `draft` has
            // moved on again — so this hands the field the PREVIOUS value and eats
            // the character. "Ruby Kowalczyk-Fitzgerald III" arrived as "Ruby Kowa".
            //
            // Nothing legitimately writes the name from the other direction while
            // the player is typing. What does write it is `commitUsername()` when
            // focus leaves (trimming), and that fires after `nameFocused` is
            // already false — so this still catches it.
            guard !nameFocused, stored != draft else { return }
            draft = stored
        }
        .onChange(of: nameFocused) { _, focused in
            // Trim on the way OUT, not on every keystroke: eating the space you
            // just typed between two words is maddening.
            if !focused { profile.commitUsername() }
        }
    }

    /// The promise, in plain sight and in plain words.
    ///
    /// Permanently visible — not a tooltip, not behind an info button. A box
    /// asking for a "username" in 2026 reads as the first step of an account
    /// signup, and someone who assumes that and types a name they use elsewhere
    /// has been misled by our silence. Saying it once, here, costs three lines.
    ///
    /// If StreetRig ever gains a network path for any of this, this sentence is
    /// the first thing that has to change.
    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(RigTheme.amberChrome)
                .padding(.top, 1)
            Text("Stored on this device only. No account, no sign-in, never uploaded.")
                .font(.system(size: 10.5))
                .foregroundStyle(RigTheme.textPrimary.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .rigCard(cornerRadius: RigTheme.Radius.control)
    }

    // MARK: - Bindings
    //
    // Written out rather than `$profile.profile.avatar` so the picker takes plain
    // `Binding`s and knows nothing about the store — it is reused by the preview
    // above with local `@State`, and will be reused again by the tutorial.

    private var avatarBinding: Binding<AvatarStyle> {
        Binding(get: { profile.profile.avatar },
                set: { profile.profile.avatar = $0 })
    }

    private var tintBinding: Binding<AvatarTint> {
        Binding(get: { profile.profile.tint },
                set: { profile.profile.tint = $0 })
    }
}

#Preview("Profile — empty") {
    ProfileView()
        .environmentObject(ProfileStore.preview)
        .environmentObject(RigStore.preview)
        .environmentObject(OnboardingCoordinator())
        .frame(width: 620, height: 250)
        .background(RigTheme.background)
        .preferredColorScheme(.dark)
}

#Preview("Profile — filled in") {
    ProfileView()
        .environmentObject(ProfileStore.previewFilled)
        .environmentObject(RigStore.preview)
        .environmentObject(OnboardingCoordinator())
        .frame(width: 620, height: 250)
        .background(RigTheme.background)
        .preferredColorScheme(.dark)
}
