import Foundation
import Observation

// MARK: - Preferences

/// Where the messages you sent yourself sit in the transcript.
nonisolated enum OwnMessageAlignment: String, CaseIterable, Identifiable, Sendable {
    /// Mine on the right, everyone else's on the left. What iMessage does, and
    /// what most people expect from a phone.
    case sided
    /// Every message in one leading column, the way GroupMe's own clients draw
    /// a conversation. Mine keep the accent tint: with both sides on the same
    /// edge the colour is the only thing left saying who spoke, so dropping it
    /// would make the transcript genuinely harder to read, not merely plainer.
    case uniform

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sided: "Two Sides"
        case .uniform: "One Column"
        }
    }

    /// One line under the picker, because "One Column" on its own does not say
    /// what changes.
    var detail: String {
        switch self {
        case .sided: "Your messages sit on the right."
        case .uniform: "Your messages line up with everyone else's, GroupMe style."
        }
    }
}

// MARK: - Store

/// The user's preferences, and nothing else.
///
/// Deliberately not part of `AppModel`. Nothing here talks to the network, the
/// database or the sync engine, and a view that only wants to know how to draw
/// a bubble should not have to reach through the object that owns all three.
///
/// Every value is read off `UserDefaults` at init and kept in memory after
/// that, so a `body` can ask for one without an await or a hop. Writes go
/// straight back out, which is cheap: `UserDefaults` batches its own flushing.
@Observable @MainActor
final class AppSettings {
    private let defaults: UserDefaults

    private enum Key {
        static let ownMessageAlignment = "sh.dunkirk.GroupMeNot.settings.ownMessageAlignment"
        static let pinned = "sh.dunkirk.GroupMeNot.settings.pinnedConversations"
        static let sharesPresence = "sh.dunkirk.GroupMeNot.settings.sharesPresence"
    }

    /// Conversations kept at the top of the list, by storage key.
    ///
    /// A device preference, and only that. GroupMe has no notion of a pinned
    /// conversation — its `pin` routes are about pinning a *message* inside one
    /// — so there is nothing to sync this with and nothing that could disagree
    /// with it. An ordered array rather than a set: the order they were pinned
    /// in is the order they are drawn in, and a set would shuffle them on every
    /// launch.
    private(set) var pinned: [String] {
        didSet { defaults.set(pinned, forKey: Key.pinned) }
    }

    /// Three to a row, three rows. Past that the strip is taller than the list
    /// it sits above and has stopped being a shortcut.
    static let pinLimit = 9

    func isPinned(_ key: String) -> Bool { pinned.contains(key) }

    var canPinMore: Bool { pinned.count < Self.pinLimit }

    /// Newest pin last, so the strip reads in the order things were put there.
    func togglePin(_ key: String) {
        if let index = pinned.firstIndex(of: key) {
            pinned.remove(at: index)
        } else if canPinMore {
            pinned.append(key)
        }
    }

    /// Whether to tell GroupMe when you are here.
    ///
    /// Off by default, which is the only defensible default for a switch that
    /// changes what other people see. Reading somebody's status is between you
    /// and the server; publishing your own puts a green dot next to your name on
    /// every phone that knows you.
    var sharesPresence: Bool {
        didSet {
            guard sharesPresence != oldValue else { return }
            defaults.set(sharesPresence, forKey: Key.sharesPresence)
        }
    }

    var ownMessageAlignment: OwnMessageAlignment {
        didSet {
            guard ownMessageAlignment != oldValue else { return }
            defaults.set(ownMessageAlignment.rawValue, forKey: Key.ownMessageAlignment)
        }
    }

    /// The injection point is here so a test can hand in its own suite rather
    /// than scribbling on the real one.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // An unset or unrecognised value falls back to the default rather than
        // failing, which is what makes it safe to add cases later.
        self.ownMessageAlignment = defaults.string(forKey: Key.ownMessageAlignment)
            .flatMap(OwnMessageAlignment.init(rawValue:)) ?? .sided
        self.pinned = defaults.stringArray(forKey: Key.pinned) ?? []
        self.sharesPresence = defaults.bool(forKey: Key.sharesPresence)
    }
}
