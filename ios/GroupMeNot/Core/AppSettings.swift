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
        static let lastTopic = "sh.dunkirk.GroupMeNot.settings.lastTopic"
    }

    /// Which topic was last open in each group, by group id.
    ///
    /// Not a preference in the sense the rest of this file is, but it belongs
    /// here for the same reason: it is small, it is the user's, and it should
    /// survive a relaunch. Opening a group and landing back in the topic you
    /// were reading is the difference between topics being a place and topics
    /// being a menu you have to visit every time.
    private var lastTopics: [String: String] {
        didSet { defaults.set(lastTopics, forKey: Key.lastTopic) }
    }

    func lastTopic(inGroup groupID: String) -> String? { lastTopics[groupID] }

    /// Passing the group's own id forgets the topic, which is what choosing the
    /// main conversation means.
    func rememberTopic(_ topicID: String, inGroup groupID: String) {
        if topicID == groupID {
            lastTopics.removeValue(forKey: groupID)
        } else {
            lastTopics[groupID] = topicID
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
        self.lastTopics = defaults.dictionary(forKey: Key.lastTopic) as? [String: String] ?? [:]
    }
}
