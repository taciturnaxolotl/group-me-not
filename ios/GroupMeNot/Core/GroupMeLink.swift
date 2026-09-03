import Foundation

/// A GroupMe link that means something to this app rather than to a browser.
///
/// Share links are how groups actually spread: somebody posts one in a chat and
/// everybody taps it. Left as an ordinary URL it leaves the app, opens Safari,
/// and hands the reader to a web page whose only job is to talk them into
/// installing the official client. Recognising the shape here is what keeps
/// that traffic inside.
nonisolated enum GroupMeLink: Hashable, Sendable {
    /// `groupme.com/join_group/{groupID}/{shareToken}`.
    case groupInvite(groupID: String, shareToken: String)

    /// Nil for every link that is not one of ours, which is nearly all of them.
    init?(url: URL) {
        guard let host = url.host()?.lowercased() else { return nil }
        // `groupme.com`, `app.groupme.com`, `web.groupme.com`, and whatever
        // subdomain they add next.
        guard host == "groupme.com" || host.hasSuffix(".groupme.com") else { return nil }

        let parts = url.pathComponents.filter { $0 != "/" }
        switch parts.first {
        case "join_group" where parts.count >= 3:
            self = .groupInvite(groupID: parts[1], shareToken: parts[2])
        default:
            return nil
        }
    }

    /// The conversation this link points at, whether or not we are in it yet.
    var conversation: ConversationID {
        switch self {
        case .groupInvite(let groupID, _): .group(groupID)
        }
    }
}
