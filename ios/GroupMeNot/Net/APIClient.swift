import Foundation
import os

/// Talks to GroupMe. Knows about hosts, the `X-Access-Token` header, the
/// response envelope, and retrying. Knows nothing about what the app does.
actor APIClient {
    nonisolated enum Host: String, Sendable {
        case v1 = "https://api.groupme.com/v1"
        case v2 = "https://api.groupme.com/v2"
        case v3 = "https://api.groupme.com/v3"
        case v4 = "https://api.groupme.com/v4"
        /// The legacy host. Still owns login, registration, invites and push.
        case legacy = "https://v2.groupme.com"
    }

    private let session: URLSession
    private let tokenProvider: @Sendable () async -> String?
    private let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "api")

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    init(tokenProvider: @escaping @Sendable () async -> String?) {
        let config = URLSessionConfiguration.default
        // Generous per-request timeouts; the retry policy owns the overall budget.
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        self.session = URLSession(configuration: config)
        self.tokenProvider = tokenProvider
    }

    // MARK: - Requests

    /// - Parameter repeating: query keys that appear more than once, which a
    ///   dictionary cannot spell. GroupMe's `include` is the one that needs it:
    ///   the group index sends `&include=visibility&include=locations`, and a
    ///   builder that silently kept only the last value would drop half of it.
    func get<T: Decodable & Sendable>(
        _ host: Host, _ path: String,
        query: [String: String?] = [:],
        repeating: [String: [String]] = [:],
        retry: RetryPolicy = .interactive
    ) async throws -> T {
        try await send(
            host, path, method: "GET", query: query, repeating: repeating,
            body: Optional<Empty>.none, retry: retry)
    }

    @discardableResult
    func post<T: Decodable & Sendable, B: Encodable & Sendable>(
        _ host: Host, _ path: String,
        query: [String: String?] = [:],
        body: B?,
        retry: RetryPolicy = .interactive
    ) async throws -> T {
        try await send(host, path, method: "POST", query: query, body: body, retry: retry)
    }

    /// Edits. GroupMe puts them on `PUT` and, unlike the send routes, does not
    /// document what comes back, so the response is read for `meta` and nothing
    /// else. Anything the caller wants to show comes from its own optimistic
    /// copy or from the next `message.update`.
    @discardableResult
    func putIgnoringResponse<B: Encodable & Sendable>(
        _ host: Host, _ path: String,
        query: [String: String?] = [:],
        body: B?,
        retry: RetryPolicy = .interactive
    ) async throws -> Meta? {
        let env: Envelope<Discard> = try await send(host, path, method: "PUT", query: query, body: body, retry: retry, unwrap: false)
        return env.meta
    }

    /// For calls whose body we do not care about.
    @discardableResult
    func postIgnoringResponse<B: Encodable & Sendable>(
        _ host: Host, _ path: String,
        query: [String: String?] = [:],
        body: B?,
        retry: RetryPolicy = .interactive
    ) async throws -> Meta? {
        let env: Envelope<Discard> = try await send(host, path, method: "POST", query: query, body: body, retry: retry, unwrap: false)
        return env.meta
    }

    /// A delete has no body going out and nothing worth reading coming back.
    /// `204` is the usual answer, which `perform` turns into `.noContent`, so
    /// that is caught here rather than left for every caller to know about.
    func deleteIgnoringResponse(
        _ host: Host, _ path: String,
        query: [String: String?] = [:],
        retry: RetryPolicy = .interactive
    ) async throws {
        do {
            let _: Envelope<Discard> = try await send(
                host, path, method: "DELETE", query: query,
                body: Optional<Discard>.none, retry: retry, unwrap: false)
        } catch APIError.noContent {
            return
        }
    }

    // MARK: - Core

    private func send<T: Decodable & Sendable, B: Encodable & Sendable>(
        _ host: Host, _ path: String,
        method: String,
        query: [String: String?],
        repeating: [String: [String]] = [:],
        body: B?,
        retry: RetryPolicy,
        unwrap: Bool = true
    ) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await perform(
                    host, path, method: method, query: query, repeating: repeating,
                    body: body, unwrap: unwrap)
            } catch let error as APIError {
                guard retry.shouldRetry(error, attempt: attempt) else { throw error }
                let wait = retry.wait(after: error, attempt: attempt)
                log.debug("retry \(attempt + 1) for \(method) \(path) in \(wait, format: .fixed(precision: 2))s")
                try await Task.sleep(for: .seconds(wait))
                attempt += 1
            }
        }
    }

    private func perform<T: Decodable & Sendable, B: Encodable & Sendable>(
        _ host: Host, _ path: String,
        method: String,
        query: [String: String?],
        repeating: [String: [String]] = [:],
        body: B?,
        unwrap: Bool
    ) async throws -> T {
        guard let token = await tokenProvider() else { throw APIError.unauthenticated }

        var components = URLComponents(string: host.rawValue + path)!
        var items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        // Appended rather than merged: `queryItems` is an array and happily
        // carries the same name twice, which is the whole point of this
        // parameter. Sorted so a URL is the same string every time, which
        // matters to `URLCache` and to anyone reading a log.
        for key in repeating.keys.sorted() {
            items += repeating[key, default: []].map { URLQueryItem(name: key, value: $0) }
        }
        if !items.isEmpty { components.queryItems = items }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "X-Access-Token")
        if let body {
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw APIError.transport(urlError)
        }

        let http = response as! HTTPURLResponse
        // Answered, with nothing in it. GroupMe signals "no results" this way
        // rather than with an empty collection: a page of messages past either
        // end of a conversation is a `304`, and some endpoints use `204`. Both
        // arrive with no body, so this has to be settled before either the
        // status check or the decoder gets a look, or an ordinary answer is
        // reported as a failure.
        // An empty body only means "nothing" when the request succeeded. A 500
        // with no body is still a 500, and calling it "no content" would make it
        // unretryable.
        if http.statusCode == 304 || http.statusCode == 204
            || ((200...299).contains(http.statusCode) && data.isEmpty) {
            throw APIError.noContent(status: http.statusCode)
        }
        guard (200...299).contains(http.statusCode) else {
            let meta = (try? decoder.decode(Envelope<Discard>.self, from: data))?.meta
            let after = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Self.parseRetryAfter)
            throw APIError.http(status: http.statusCode, meta: meta, retryAfter: after)
        }

        do {
            if unwrap {
                let envelope = try decoder.decode(Envelope<T>.self, from: data)
                guard let value = envelope.response else {
                    throw APIError.decoding("missing `response` for \(path)")
                }
                return value
            }
            return try decoder.decode(T.self, from: data)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.decoding("\(path): \(error)")
        }
    }

    /// `Retry-After` is either delta-seconds or an HTTP date.
    private static func parseRetryAfter(_ value: String) -> TimeInterval? {
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}

nonisolated struct Empty: Codable, Sendable {}
/// Decodes anything and keeps nothing. Used to reach `meta` on a body we ignore.
nonisolated struct Discard: Codable, Sendable {
    init() {}
    init(from decoder: Decoder) throws {}
    func encode(to encoder: Encoder) throws {}
}
