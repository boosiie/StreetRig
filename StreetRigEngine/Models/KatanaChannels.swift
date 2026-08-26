//
//  KatanaChannels.swift
//  StreetRig
//
//  CHANNEL MEMORIES for a modelling amp — the four buttons on a Katana that
//  recall "the whole panel, stored".
//
//  WHY THERE IS NO NEW SCHEMA HERE. A channel memory IS the amp's
//  `GearItem.values` dictionary: `[String: Double]`, already carrying Gain,
//  Bass, Mid, Treble, Presence, Volume, Master, Character, Variation, Power and
//  every FX block's type / on / level. Storing channels as a `channels: [[String:
//  Double]]?` field on `GearItem` would have been the obvious move and is
//  exactly the wrong one: `GearItem` is the persisted shape,
//  `RigStore.catalogVersion` gates it, and `RigStore.load` returns nil for any
//  state older than the current version — so bumping it to make room DISCARDS
//  THE PLAYER'S SAVED RIG and re-seeds. The version therefore stays at 3, and
//  channels live beside the rig instead of inside it.
//
//  They live in the SAME directory as the AUv3's `.srpreset` user presets
//  (Application Support / StreetRigUserPresets), because they are the same idea
//  at two scales: a user preset is the whole rig, a channel is the amp's panel.
//  A host that saves a session already round-trips the panel inside the rig
//  blob, so the plugin needs nothing added — this is the in-app half.
//
//  Threading: plain file I/O on the main thread, in the same class as
//  `RigStore.save`. Nothing here is reachable from the audio thread.
//

import Foundation

public enum KatanaChannelStore {

    /// Four, matching the channel buttons on the hardware. The count is the one
    /// thing the sources disagree about across Katana generations (some bank
    /// them), so it is a single constant rather than an assumption spread across
    /// the UI.
    public static let channelCount = 4

    /// A stored channel: the amp's whole panel plus the model it was captured
    /// from, so recalling a channel saved off a Katana onto some other amp
    /// cannot quietly write Katana-only keys into it.
    public struct Channel: Codable, Equatable {
        public var ampName: String
        public var values: [String: Double]
        public init(ampName: String, values: [String: Double]) {
            self.ampName = ampName
            self.values = values
        }
    }

    /// Save the amp's current panel into a channel slot.
    @discardableResult
    public static func save(ampName: String, values: [String: Double], channel: Int) -> Bool {
        guard let url = url(channel), let data = try? JSONEncoder().encode(
            Channel(ampName: ampName, values: values)) else { return false }
        return (try? data.write(to: url, options: [.atomic])) != nil
    }

    /// Recall a channel, or nil if the slot is empty / was stored from a
    /// different amp model.
    public static func load(channel: Int, ampName: String) -> Channel? {
        guard let url = url(channel),
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Channel.self, from: data),
              stored.ampName.caseInsensitiveCompare(ampName) == .orderedSame else { return nil }
        return stored
    }

    /// Is anything stored in this slot for this amp?
    public static func isOccupied(channel: Int, ampName: String) -> Bool {
        load(channel: channel, ampName: ampName) != nil
    }

    public static func clear(channel: Int) {
        guard let url = url(channel) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// One file per channel, beside the AUv3 user presets.
    private static func url(_ channel: Int) -> URL? {
        guard channel >= 0, channel < channelCount else { return nil }
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("StreetRigUserPresets", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("KatanaChannel\(channel + 1).srchannel")
    }
}

@MainActor
public extension RigStore {

    /// Write a whole dictionary of knob values onto one item in ONE mutation.
    ///
    /// Recalling a channel through `binding(itemId:param:)` twenty-six times
    /// would publish twenty-six times, and every publish is a compile — which
    /// for a channel that changes Character means twenty-six chances to hit the
    /// fade/park barrier on the way to the settings the player actually asked
    /// for. One mutation is one compile, so a channel change is a single
    /// structural swap through the barrier: click-free, and the same path
    /// switching amps already takes.
    func applyValues(_ values: [String: Double], toItem itemId: UUID) {
        guard let idx = collection.firstIndex(where: { $0.id == itemId }) else { return }
        var item = collection[idx]
        for (k, v) in values { item.values[k] = v }
        collection[idx] = item
    }

    /// Save the item's panel into a channel slot.
    @discardableResult
    func saveKatanaChannel(_ channel: Int, itemId: UUID) -> Bool {
        guard let item = item(itemId) else { return false }
        return KatanaChannelStore.save(ampName: item.name, values: item.values, channel: channel)
    }

    /// Recall a channel onto the item. Returns false when the slot is empty.
    @discardableResult
    func recallKatanaChannel(_ channel: Int, itemId: UUID) -> Bool {
        guard let item = item(itemId),
              let stored = KatanaChannelStore.load(channel: channel, ampName: item.name) else { return false }
        applyValues(stored.values, toItem: itemId)
        return true
    }
}
