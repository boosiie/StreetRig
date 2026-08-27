//
//  ProfileStore.swift
//  StreetRigEngine
//
//  WHO is playing. Everything else in StreetRig is about gear; this is the one
//  record about the person holding it — a name, a chosen avatar and the colour
//  they picked for it.
//
//  LOCAL, AND THAT IS THE POINT. There is no account, no sign-in and no network
//  call anywhere in this file: the profile is a JSON file in the app's own
//  Documents folder, sitting beside `rig_state.json`, and it goes wherever the
//  app goes and nowhere else. The profile page states that in visible text next
//  to the name field, because a text box asking for a "username" reads as the
//  first step of a signup and the player is owed the truth about it. If a future
//  change ever gives this thing a network path, that promise has to be revisited
//  in the UI at the same time — the sentence is a contract, not decoration.
//
//  WHY THIS MIRRORS `RigStore` RATHER THAN USING `@AppStorage`. The profile is a
//  small structured record, not three loose scalars: the avatar identity and its
//  tint only mean anything together, and a schema version has to travel with
//  them. `RigStore` already proves this exact shape works in this app — an
//  `ObservableObject` over one `Codable` value, JSON on disk, a debounced
//  autosave, and a `persist: false` mode so SwiftUI previews never touch the
//  filesystem. Three `@AppStorage` keys would have saved perhaps twenty lines and
//  cost the app a second, differently-shaped persistence story. Consistency wins.
//
//  `schemaVersion` is here from day one because `RigStore` learned that lesson the
//  expensive way with `catalogVersion`: a file written before versioning existed
//  cannot be told apart from a current one, so the first migration has nothing to
//  branch on. Unlike `catalogVersion`, a stale version here must NOT throw the
//  file away — a player's name is theirs, not seeded content we can regenerate.
//

import SwiftUI
import Combine

// MARK: - Avatar identity

/// The built-in avatars. Identity only — how one is DRAWN lives in the app's
/// `AvatarView`, so the same case can be rendered at 28pt in a header and 96pt
/// on the profile page without either size owning the artwork.
///
/// Deliberately a `String`-backed enum rather than an `Int`: the raw values land
/// in a JSON file a human may well read, and "pick" survives a reordering of the
/// cases in a way that `3` does not.
///
/// **There is no "photo from your library" case, and that is a decision.** Photo
/// import would need a `PhotosPicker`, a Photos usage entitlement and a system
/// permission dialog — and a dialog asking for access to the player's camera roll
/// is the exact opposite of the message this page exists to deliver. Built-in
/// artwork needs no permission at all, so the privacy story stays a single
/// sentence with no asterisk on it.
public enum AvatarStyle: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    // Gear — the vocabulary the rest of the app already speaks.
    case guitar, amp, cabinet, headphones
    // Drawn in-app rather than borrowed from SF Symbols, because SF Symbols has
    // no plectrum, no amp knob, no quarter-inch jack and no vacuum tube, and those
    // four are the most StreetRig things on the list. See `AvatarView` in the app.
    case pick, knob, jack, tube
    // Signal and sound.
    case waveform, note, chord, bolt
    // Character.
    case flame, star

    public var id: String { rawValue }

    /// The SF Symbol that draws this avatar, or `nil` for the four procedural ones.
    /// Kept in the model rather than the view so the picker's ordering, the
    /// accessibility label and the artwork can never disagree about what a case is.
    public var symbolName: String? {
        switch self {
        case .guitar:     return "guitars.fill"
        case .amp:        return "hifispeaker.fill"      // same symbol GearCategory uses for an amp
        case .cabinet:    return "hifispeaker.2.fill"
        case .headphones: return "headphones"
        case .waveform:   return "waveform"
        case .note:       return "music.note"
        case .chord:      return "music.quarternote.3"
        case .bolt:       return "bolt.fill"
        case .flame:      return "flame.fill"
        case .star:       return "star.fill"
        case .pick, .knob, .jack, .tube: return nil
        }
    }

    /// Spoken name, for VoiceOver and for the picker's accessibility labels.
    public var displayName: String {
        switch self {
        case .guitar:     return "Guitar"
        case .amp:        return "Amp"
        case .cabinet:    return "Cabinet"
        case .headphones: return "Headphones"
        case .pick:       return "Plectrum"
        case .knob:       return "Amp knob"
        case .jack:       return "Jack plug"
        case .tube:       return "Valve"
        case .waveform:   return "Waveform"
        case .note:       return "Note"
        case .chord:      return "Chord"
        case .bolt:       return "Bolt"
        case .flame:      return "Flame"
        case .star:       return "Star"
        }
    }
}

/// The colour an avatar is drawn in. A NAMED selection rather than a stored
/// `Color`: `Color` is not meaningfully `Codable`, and — more to the point — a
/// literal RGB triple frozen into a save file would survive a palette change and
/// leave one player's avatar sitting outside "Burnt Tan" forever. Storing the
/// name means the artwork follows `RigTheme` wherever it goes.
///
/// Every case resolves to a token that already exists in the palette. Do not add
/// a bespoke colour here; add it to `RigTheme` first, with its reasoning.
public enum AvatarTint: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case amber, ember, brass, cream, signal, ready, clip

    public var id: String { rawValue }

    public var color: Color {
        switch self {
        case .amber:  return RigTheme.amber
        case .ember:  return RigTheme.emberSoft
        case .brass:  return RigTheme.trim
        case .cream:  return RigTheme.panel
        case .signal: return RigTheme.signal
        case .ready:  return RigTheme.ready
        case .clip:   return RigTheme.clip
        }
    }

    public var displayName: String {
        switch self {
        case .amber:  return "Ember"
        case .ember:  return "Soft ember"
        case .brass:  return "Brass"
        case .cream:  return "Cream"
        case .signal: return "Signal green"
        case .ready:  return "Bright green"
        case .clip:   return "Red"
        }
    }
}

// MARK: - The record

/// The player's local profile.
public struct Profile: Codable, Equatable, Sendable {
    /// Bumped when the SHAPE of this struct changes in a way a migration has to
    /// know about. Absent in files written before this field existed → treated as
    /// 1, which is what every such file is.
    public var schemaVersion: Int
    /// Raw as typed, minus leading/trailing whitespace. May be empty — an empty
    /// name is a legitimate state (someone who has not filled it in), not an
    /// error, which is why every read goes through `displayName`.
    public var username: String
    public var avatar: AvatarStyle
    public var tint: AvatarTint

    /// The longest name the layout can hold without the field scrolling under the
    /// player's own finger. Enforced by `clamp`, which every write goes through —
    /// not merely suggested. A "limit" that only appears as helper text is not a
    /// limit, and one enforced where the player cannot see it is barely better;
    /// the field itself stops dead at this count. See `ProfileView.draft`.
    public static let usernameLimit = 24

    /// The current schema. See `schemaVersion`.
    public static let currentSchemaVersion = 1

    public init(schemaVersion: Int = Profile.currentSchemaVersion,
                username: String = "",
                avatar: AvatarStyle = .guitar,
                tint: AvatarTint = .amber) {
        self.schemaVersion = schemaVersion
        self.username = username
        self.avatar = avatar
        self.tint = tint
    }

    /// What to PRINT wherever the name appears. Never empty.
    ///
    /// The fallback is a real name rather than "Unnamed" or an empty gap on
    /// purpose: a blank where a name should be reads as a rendering bug, and
    /// "Unnamed" reads as a scolding. "Player One" reads as somebody.
    public var displayName: String {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Player One" : trimmed
    }

    /// True when the player has actually chosen a name, as opposed to being shown
    /// the fallback. Anything that wants to nudge them ("finish setting up") should
    /// branch on this and NOT on `username.isEmpty`, which ignores whitespace.
    public var hasChosenName: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Truncate-and-trim, applied on every write so the limit cannot be beaten by
    /// pasting. Leading/trailing whitespace survives while the player is TYPING
    /// (deleting a space you just typed would be maddening otherwise) and is
    /// stripped on commit — see `ProfileStore.commitUsername()`.
    public static func clamp(_ raw: String) -> String {
        // Newlines can arrive by paste even though the field is single-line.
        let flattened = raw.replacingOccurrences(of: "\n", with: " ")
        return String(flattened.prefix(usernameLimit))
    }

    /// A brand-new player. Empty name, the guitar avatar, the app's accent colour.
    public static let empty = Profile()

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, username, avatar, tint
    }

    /// Hand-written on purpose, and it is the whole reason `schemaVersion` can be a
    /// plain `Int` instead of the `Int?` `RigStore.PersistedState` had to settle for.
    ///
    /// The synthesised decoder throws on ANY missing or unrecognised key, and the
    /// three ways this file can legitimately arrive malformed all end there:
    ///   • written before a field existed  → missing key
    ///   • written by a newer build that added an avatar → unknown raw value
    ///   • hand-edited by somebody poking around Documents
    /// A throw loses the player's name. Every field here falls back instead, so the
    /// worst case is one setting reverting to its default rather than the record
    /// evaporating. Add a field → give it a `decodeIfPresent` and a default here.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `try?` around `decodeIfPresent` gives `T??` — the outer level is "the key
        // held the wrong type", the inner "the key was absent". Both mean the same
        // thing here, so they are flattened together.
        func lenient<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            ((try? c.decodeIfPresent(type, forKey: key)) ?? nil)
        }
        schemaVersion = lenient(Int.self, .schemaVersion) ?? 1
        username = lenient(String.self, .username) ?? ""
        avatar = AvatarStyle(rawValue: lenient(String.self, .avatar) ?? "") ?? .guitar
        tint = AvatarTint(rawValue: lenient(String.self, .tint) ?? "") ?? .amber
    }
}

// MARK: - The store

/// Owns the profile and persists it, in the same shape and the same folder as
/// `RigStore` owns the gear. See the file header for why it is a store at all.
@MainActor
public final class ProfileStore: ObservableObject {
    @Published public var profile: Profile

    private let saveURL: URL
    private let persist: Bool
    private var cancellables = Set<AnyCancellable>()

    /// `persist: false` keeps everything in memory (SwiftUI previews), so the
    /// preview sandbox never touches the filesystem or the autosave loop —
    /// exactly as `RigStore(persist:)` does, for exactly the same reason.
    public init(persist: Bool = true) {
        self.persist = persist
        saveURL = Self.stateURL()

        if persist, let loaded = Self.load(from: saveURL) {
            profile = loaded
        } else {
            // First launch. NOT written to disk here, unlike `RigStore`'s seed:
            // the seeded gear collection is content the player would notice
            // missing, while an empty profile is indistinguishable from no file
            // at all. Nothing is written until they actually choose something.
            profile = .empty
        }

        guard persist else { return }

        // Debounced autosave, 0.4s — the same window `RigStore` uses, and for the
        // same reason: a name is typed one character at a time and a save per
        // keystroke is a file write per keystroke.
        $profile
            .dropFirst()
            .debounce(for: .seconds(0.4), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &cancellables)
    }

    /// In-memory store for SwiftUI previews (no disk I/O).
    public static var preview: ProfileStore { ProfileStore(persist: false) }

    /// A preview with the page in its "filled in" state, for checking that a long
    /// name and a non-default avatar actually fit the landscape layout.
    public static var previewFilled: ProfileStore {
        let store = ProfileStore(persist: false)
        store.profile = Profile(username: "Ruby Kowalczyk", avatar: .tube, tint: .brass)
        return store
    }

    // MARK: - Mutation

    // NOTE: there is deliberately no `usernameBinding` here. A clamping `Binding`
    // straight onto `profile.username` is the obvious shape and it does not work —
    // the store ends up correct while the text field on screen goes on showing the
    // characters it dropped. The field keeps a local `@State` mirror and writes
    // through instead; `ProfileView.draft` carries the full reasoning. `clamp` is
    // public so that mirror can call it, and every write that reaches this store
    // from anywhere else goes through `Profile.clamp` in the decoder.

    /// Called when the field gives up focus or the player hits return. Trimming
    /// happens HERE rather than on every keystroke so that typing a space between
    /// two words does not have the space eaten out from under the cursor.
    public func commitUsername() {
        let trimmed = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != profile.username else { return }
        profile.username = trimmed
    }

    public func select(avatar: AvatarStyle) { profile.avatar = avatar }
    public func select(tint: AvatarTint)    { profile.tint = tint }

    // MARK: - Persistence

    public func save() {
        guard persist else { return }
        var state = profile
        state.schemaVersion = Profile.currentSchemaVersion
        Self.write(state, to: saveURL)
    }

    /// Beside `rig_state.json`, in the folder `RigStore` already chose — see
    /// `RigStore.stateDirectory()`. A second location would mean two answers to
    /// "where is my stuff", and any future "reset everything" would find one of
    /// them and miss the other.
    private static func stateURL() -> URL {
        RigStore.stateDirectory().appendingPathComponent("profile.json")
    }

    private static func load(from url: URL) -> Profile? {
        guard let data = try? Data(contentsOf: url),
              var profile = try? JSONDecoder().decode(Profile.self, from: data)
        else { return nil }
        // A file from a FUTURE schema is still read rather than discarded. Unlike
        // `RigStore`'s catalog — which is seeded content we can regenerate — this
        // is the player's own name, and throwing it away to be safe is not safe.
        profile.username = Profile.clamp(profile.username)
        return profile
    }

    private static func write(_ profile: Profile, to url: URL) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
