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
    /// The caller has no token.
    case unauthenticated

    var isRetryable: Bool {
        switch self {
        case .transport: true
        case .http(let status, _, _): status == 408 || status == 429 || (500...599).contains(status)
        case .decoding, .unauthenticated: false
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
    case .unauthenticated: return "signed out"
    }
}
