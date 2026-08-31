import Foundation

// Collapsing runs of system notices.
//
// When six people are added to a group at once, GroupMe sends six messages and a
// naive transcript draws six grey lines. This file turns a consecutive run of
// them into one row that says "6 people joined" and expands, on a tap, back into
// the six original lines.
//
// The rule that governs everything here: **never re-derive what the server
// already told us.** GroupMe composes those sentences server-side, and their
// shape varies by event type and by locale. So the collapsed row is a *count* by
// family, and the expanded rows are the server's own strings, verbatim. Nothing
// in this file parses a name, a verb, or a preposition out of `text`.

/// The kind of change a system notice announces, coarse enough to summarise.
///
/// Derived from `event.type`, which is the structured half of a system message
/// and the only part safe to reason about. Older messages carry no `event` at
/// all; they land in ``other`` and still group with each other, which is the
/// right answer for a wall of notices we cannot classify.
nonisolated enum SystemMessageFamily: Hashable, Sendable {
    /// `membership.announce.joined` / `.added` / `.rejoined` / `.coco.added`
    case joins
    /// `membership.notifications.removed` / `.exited`
    case departures
    /// `group.*`: name, avatar, topic, and settings changes.
    case group
    /// `group.subgroup_*`: topics inside a group.
    case topics
    /// Anything else, including a message with no `event.type`.
    case other

    init(eventType: String?) {
        guard let eventType else {
            self = .other
            return
        }
        // Topics are spelled `group.subgroup_…`, so they have to be tested
        // before the general `group.` prefix or they would be swallowed by it.
        if eventType.hasPrefix("group.subgroup_") {
            self = .topics
        } else if eventType.hasPrefix("membership.announce.") {
            self = .joins
        } else if eventType.hasPrefix("membership.notifications.") {
            self = .departures
        } else if eventType.hasPrefix("group.") {
            self = .group
        } else {
            self = .other
        }
    }

    /// What a collapsed run of `count` of these is called.
    ///
    /// Deliberately vague where the family is vague. "4 group updates" says less
    /// than the four sentences underneath it, and that is the point: the summary
    /// is a lid, not a translation.
    func summary(count: Int) -> String {
        switch self {
        case .joins: "\(count) people joined"
        case .departures: "\(count) people left"
        case .group: "\(count) group updates"
        case .topics: "\(count) topic updates"
        case .other: "\(count) updates"
        }
    }
}

/// A run of consecutive system notices, drawn as one row until it is opened.
nonisolated struct SystemMessageRun: Identifiable, Hashable, Sendable {
    var family: SystemMessageFamily
    /// The notices themselves, in transcript order. Shown verbatim when the run
    /// is expanded; never parsed.
    var items: [MessageDisplay]

    /// The first notice's id. Stable across rebuilds, which is what keeps a run
    /// the user opened from snapping shut when a new message arrives.
    var id: String { items.first?.id ?? "system-run" }

    var count: Int { items.count }
    var summary: String { family.summary(count: count) }
}

nonisolated extension SystemMessageRun {
    /// Runs shorter than this stay as individual rows.
    ///
    /// Two notices read better in full than behind a lid that says "2 updates":
    /// the lid is the same height as the thing it hides, and hiding costs a tap.
    /// Three is where the collapse starts paying.
    static let minimumRunLength = 3

    /// Fold consecutive same-family system notices into ``TranscriptRow/systemRun``.
    ///
    /// A post-pass over built rows rather than a branch inside the builder, so
    /// day separators, run boundaries and outbox echoes are all already decided
    /// and this only has to look for neighbours. Anything that is not a system
    /// notice, including a day heading, ends the run, which is exactly right: a
    /// collapsed run must never straddle midnight.
    static func collapsing(_ rows: [TranscriptRow]) -> [TranscriptRow] {
        var out: [TranscriptRow] = []
        out.reserveCapacity(rows.count)

        var pending: [MessageDisplay] = []
        var pendingFamily: SystemMessageFamily?

        func flush() {
            defer {
                pending.removeAll(keepingCapacity: true)
                pendingFamily = nil
            }
            guard let family = pendingFamily else { return }
            if pending.count >= minimumRunLength {
                out.append(.systemRun(SystemMessageRun(family: family, items: pending)))
            } else {
                out.append(contentsOf: pending.map(TranscriptRow.message))
            }
        }

        for row in rows {
            guard case .message(let item) = row, let family = item.message.systemFamily else {
                flush()
                out.append(row)
                continue
            }
            if family != pendingFamily { flush() }
            pendingFamily = family
            pending.append(item)
        }
        flush()
        return out
    }
}
