import Foundation

nonisolated extension Error {
    /// A short phrase for a failed request, fit to put in a banner or a log line.
    ///
    /// The sync loop and the outbox both need exactly this and used to carry a
    /// private copy each. It is deliberately vague about what the server said:
    /// `meta.errors` is not stable enough to branch on, only to repeat, and a
    /// decoding failure's detail belongs in a log rather than in front of
    /// somebody who just wanted to read their messages.
    var shortFailureText: String {
        guard let api = self as? APIError else { return "\(self)" }
        switch api {
        case .transport: return "offline"
        case .http(let status, _, _): return api.serverMessage ?? "HTTP \(status)"
        case .decoding: return "unreadable response"
        case .unauthenticated: return "signed out"
        }
    }
}
