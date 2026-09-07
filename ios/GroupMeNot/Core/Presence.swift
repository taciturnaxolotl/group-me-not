import Foundation

/// Whether somebody is at their phone.
///
/// GroupMe keeps this outside the conversation API entirely: presence lives on
/// the v1 host, under `/presence`, and it is the one family of routes that
/// answers with the object rather than with the `{response, meta}` envelope
/// everything else uses. It is also not pushed. The official client learns a
/// status by asking for it, and keeps its own current by sending "online" every
/// three minutes for as long as somebody is looking at the app, so a status is
/// only ever a few minutes old and "offline" mostly means "has not said
/// anything for a while".
///
/// Which is worth stating plainly, because it decides how this is drawn: a dot
/// here is a claim about the last few minutes, not about this instant.
nonisolated struct Presence: Hashable, Sendable {
    var status: Status
    /// When they were last seen, as the server reckons it. Absent for somebody
    /// who is here now, and for somebody who has never been seen at all.
    var lastActive: Date?

    nonisolated enum Status: Sendable, Hashable {
        case online
        case away
        case offline

        /// The wire has more words than there are states. `clear` is what the
        /// server calls a manually-set status that has been cleared again, and
        /// `active` turns up beside `online`; both mean here. Anything
        /// unrecognised is offline, which is the honest reading of a word we do
        /// not know.
        init(wire: String?) {
            switch wire {
            case "online", "active", "clear": self = .online
            case "away": self = .away
            default: self = .offline
            }
        }

        /// What to send when *we* are the subject.
        var apiValue: String {
            switch self {
            case .online: "online"
            case .away: "away"
            case .offline: "offline"
            }
        }
    }

    /// A line for under a name, or nil when there is nothing worth saying.
    ///
    /// The wording and the six-hour cut-off are GroupMe's, kept deliberately:
    /// past that the number stops being news and starts being a record of
    /// somebody's evening.
    var summary: String? {
        switch status {
        case .online: "Online"
        case .away: "Idle"
        case .offline: lastActive.flatMap { Self.sinceSeen($0) }
        }
    }

    private static func sinceSeen(_ date: Date, now: Date = Date()) -> String? {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        guard minutes >= 0, minutes <= 360 else { return nil }
        if minutes >= 60 { return "Active \(minutes / 60)h ago" }
        return "Active \(max(1, minutes))m ago"
    }
}

// MARK: - Wire

nonisolated extension Presence: Decodable {
    private enum CodingKeys: String, CodingKey {
        case response, status, lastActive
    }

    /// `GET /v1/presence/users/{id}` hands back `{user_id, status, last_active,
    /// sms_enabled}` with nothing around it, which is why the client is asked
    /// not to unwrap. The envelope is still tried, because one unenveloped
    /// family in an API of enveloped ones is a thing to be careful about rather
    /// than certain of, and the fallback costs three lines.
    ///
    /// `last_active` is **milliseconds**, unlike every timestamp elsewhere in
    /// this API, which are seconds. Measured against the Android client, which
    /// subtracts it straight from `System.currentTimeMillis()`.
    init(from decoder: any Decoder) throws {
        let outer = try decoder.container(keyedBy: CodingKeys.self)
        let body = (try? outer.nestedContainer(keyedBy: CodingKeys.self, forKey: .response)) ?? outer
        status = Status(wire: (try? body.decodeIfPresent(String.self, forKey: .status)) ?? nil)
        let millis = ((try? body.decodeIfPresent(Double.self, forKey: .lastActive)) ?? nil) ?? 0
        lastActive = millis > 0 ? Date(timeIntervalSince1970: millis / 1000) : nil
    }
}

/// `PUT /v1/presence/status`.
///
/// `manual` is sent only when the status was chosen rather than inferred: it is
/// what separates "I have set myself to offline" from "this client has stopped
/// saying anything". Omitted for the heartbeat, which is not a choice.
nonisolated struct PresenceUpdate: Encodable, Sendable {
    var status: String
    var manual: Bool?
}
