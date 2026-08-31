import Foundation

/// GroupMe wraps most responses as `{ "response": …, "meta": { "code", "errors" } }`.
nonisolated struct Envelope<T: Decodable & Sendable>: Decodable, Sendable {
    var response: T?
    var meta: Meta?
}

nonisolated struct Meta: Decodable, Hashable, Sendable {
    var code: Int?
    var errors: [String]?

    /// `meta.code` is five digits whose first three *usually* mirror the HTTP
    /// status. The 450xx family arrives on 403, so this is a hint, not a truth.
    var impliedStatus: Int? {
        guard let code, code >= 10000 else { return code }
        return code / 100
    }
}

nonisolated enum APIError: Error, Sendable {
    /// No network, DNS failure, timeout. Always worth retrying.
    case transport(URLError)
    /// Server answered with a non-2xx.
    case http(status: Int, meta: Meta?, retryAfter: TimeInterval?)
    /// 2xx but the body did not decode.
    case decoding(String)
    /// The request succeeded and there is nothing in it.
    ///
    /// Not a failure, and the reason it needs a case of its own: GroupMe says
    /// "no results" with a status rather than with an empty collection. A page
    /// of messages past either end of a conversation comes back `304`, and some
    /// endpoints answer `204`. Both carry no body, so the decoder would throw
    /// and the caller would log a failure over an ordinary, correct answer.
    case noContent(status: Int)
    /// The caller has no token.
    case unauthenticated

    var isRetryable: Bool {
        switch self {
        case .transport: true
        case .http(let status, _, _): status == 408 || status == 429 || (500...599).contains(status)
        case .decoding, .noContent, .unauthenticated: false
        }
    }

    /// Server-advertised backoff. GroupMe sends this on at least some 429s.
    var retryAfter: TimeInterval? {
        if case .http(_, _, let after) = self { return after }
        return nil
    }

    var status: Int? {
        if case .http(let status, _, _) = self { return status }
        return nil
    }

    /// The first human-readable error the server offered, if any. Not stable
    /// enough to branch on; fine to show.
    var serverMessage: String? {
        if case .http(_, let meta, _) = self { return meta?.errors?.first }
        return nil
    }
}

/// A short phrase for a failed request, fit for a banner or a log line.
///
/// A free function rather than a member on `Error`: this is only ever applied to
/// an `any Error` existential, and it has no business appearing on every error
/// type in the app just so three call sites can read a little tidier.
///
/// Deliberately vague about what the server said. `meta.errors` is not stable
/// enough to branch on, only to repeat, and a decoding failure's detail belongs
/// in a log rather than in front of somebody who just wanted to read a message.
nonisolated func failureText(_ error: Error) -> String {
    guard let api = error as? APIError else { return "\(error)" }
    switch api {
    case .transport: return "offline"
    case .http(let status, _, _): return api.serverMessage ?? "HTTP \(status)"
    case .decoding: return "unreadable response"
    case .noContent: return "nothing there"
    case .unauthenticated: return "signed out"
    }
}

/// The same failure, with the detail a log wants and a banner does not.
///
/// ``failureText(_:)`` deliberately throws away a decoding error's contents,
/// which is right in front of a person and wrong in a log: "unreadable
/// response" names the symptom and hides the one fact that would explain it.
nonisolated func diagnosticText(_ error: Error) -> String {
    guard let api = error as? APIError else { return "\(error)" }
    switch api {
    case .transport(let urlError): return "transport \(urlError.code.rawValue): \(urlError.localizedDescription)"
    case .http(let status, let meta, _):
        let detail = meta?.errors?.joined(separator: ", ") ?? "no meta"
        return "HTTP \(status) (\(detail))"
    case .decoding(let detail): return "undecodable: \(detail)"
    case .noContent(let status): return "no content (HTTP \(status))"
    case .unauthenticated: return "no token"
    }
}
