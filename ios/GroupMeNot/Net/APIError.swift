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
