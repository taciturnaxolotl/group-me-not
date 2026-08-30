import Foundation

/// A conversation is either a group or a direct message.
///
/// GroupMe addresses DMs by joining the two user ids, smaller first, but the
/// separator differs by surface: `+` in REST paths, `_` in push channel names.
/// Getting this wrong is the usual way to build a client that half works, so it
/// lives in one type rather than at call sites.
nonisolated enum ConversationID: Hashable, Sendable {
    case group(String)
    case direct(otherUserID: String)

    /// The id used in `/conversations/{id}/…` REST paths.
    func restID(myUserID: String) -> String {
        switch self {
        case .group(let id): id
        case .direct(let other): Self.joined(other, myUserID, separator: "+")
        }
    }

    /// The Faye channel this conversation publishes on.
    func pushChannel(myUserID: String) -> String {
        switch self {
        case .group(let id): "/group/\(id)"
        case .direct(let other): "/direct_message/\(Self.joined(other, myUserID, separator: "_"))"
        }
    }

    /// Stable key for local storage. Groups use the group id; DMs use the other
    /// user's id, so a row does not need to know who "me" is.
    var storageKey: String {
        switch self {
        case .group(let id): id
        case .direct(let other): "dm:\(other)"
        }
    }

    var isGroup: Bool {
        if case .group = self { return true }
        return false
    }

    /// Smaller numeric id first. Falls back to string ordering if either id is
    /// not numeric, which the official client does not do: it gives up and sends
    /// nothing. Ordering something is strictly better than addressing nothing.
    static func joined(_ a: String, _ b: String, separator: String) -> String {
        if let x = UInt64(a), let y = UInt64(b) {
            return x < y ? "\(x)\(separator)\(y)" : "\(y)\(separator)\(x)"
        }
        return a < b ? "\(a)\(separator)\(b)" : "\(b)\(separator)\(a)"
    }
}
