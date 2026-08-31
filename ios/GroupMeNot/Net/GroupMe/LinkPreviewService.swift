import Foundation
import os

/// Fetches and remembers link previews.
///
/// `GET /v1/urls/preview?url=…` is the endpoint the official clients hit once
/// per link that scrolls into view. Doing that literally would mean a request
/// every time a row is recycled, so this actor sits in front of it with a small
/// in-memory cache and single-flight coalescing: N rows asking about the same
/// URL at the same moment share one request, and the answer is reused for the
/// rest of the session or until it goes stale.
///
/// Nothing here throws. A preview that does not load is not a failure the user
/// should hear about; the card simply does not appear. Callers get `nil` and
/// carry on.
///
/// Deliberately memory-only. Previews are cosmetic, they go stale, and the
/// offline story for a link is the link itself, so they never earn a row in the
/// database.
actor LinkPreviewService {

    /// How long a good preview stays fresh. Long enough that a conversation
    /// reads without refetching, short enough that a corrected headline shows
    /// up the next time the app is opened.
    static let successTTL: TimeInterval = 30 * 60
    /// Failures are remembered too, briefly, so a dead link does not get
    /// retried on every scroll pass.
    static let failureTTL: TimeInterval = 5 * 60
    /// Past this, the oldest entries go. A transcript never has this many
    /// distinct links in view.
    static let capacity = 256

    private nonisolated struct Entry {
        var preview: LinkPreview?
        var expires: Date
    }

    private var cache: [String: Entry] = [:]
    private var inFlight: [String: Task<LinkPreview?, Never>] = [:]

    private let session: URLSession
    private let tokenProvider: @Sendable () async -> String?
    private let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "linkpreview")

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .useDefaultKeys  // the model looks keys up itself
        return d
    }()

    /// Its own session rather than `APIClient`'s, because this endpoint is
    /// outside the envelope contract the client enforces and because a preview
    /// must never queue behind, or retry like, a real request.
    init(tokenProvider: @escaping @Sendable () async -> String?) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false
        // One at a time per host would stall a screen full of links; four is
        // plenty and stays polite.
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        self.session = URLSession(configuration: config)
        self.tokenProvider = tokenProvider
    }

    // MARK: - Reading

    /// What we already know, with no network and no waiting.
    ///
    /// The render path: ask this first so a re-appearing row draws its card in
    /// the same frame, then kick off ``preview(for:dark:)`` only if it comes
    /// back empty.
    func cached(for url: URL, dark: Bool = false) -> LinkPreview? {
        guard let entry = cache[key(url, dark)], entry.expires > .now else { return nil }
        return entry.preview
    }

    /// Fetch, or join the fetch already running for this URL.
    ///
    /// Returns `nil` for anything that does not work out: an unsupported
    /// scheme, a network failure, a body that does not decode, a preview too
    /// thin to draw.
    func preview(for url: URL, dark: Bool = false) async -> LinkPreview? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }

        let key = key(url, dark)
        if let entry = cache[key], entry.expires > .now { return entry.preview }
        if let running = inFlight[key] { return await running.value }

        let task = Task<LinkPreview?, Never> { [weak self] in
            await self?.fetch(url, dark: dark) ?? nil
        }
        inFlight[key] = task
        let preview = await task.value
        inFlight[key] = nil

        store(preview, for: key)
        return preview
    }

    func clear() {
        cache.removeAll(keepingCapacity: false)
    }

    // MARK: - Fetching

    private func fetch(_ url: URL, dark: Bool) async -> LinkPreview? {
        guard var components = URLComponents(string: APIClient.Host.v1.rawValue + "/urls/preview")
        else { return nil }
        var query = [URLQueryItem(name: "url", value: url.absoluteString)]
        if dark {
            // Both spellings, the way the official client sends them. Which one
            // the server reads is anybody's guess.
            query.append(URLQueryItem(name: "theme", value: "dark"))
            query.append(URLQueryItem(name: "_theme", value: "dark"))
        }
        components.queryItems = query
        guard let endpoint = components.url else { return nil }

        var request = URLRequest(url: endpoint)
        if let token = await tokenProvider() {
            request.setValue(token, forHTTPHeaderField: "X-Access-Token")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
            else { return nil }
            let preview = try decoder.decode(LinkPreview.self, from: data)
            return preview.isRenderable ? preview : nil
        } catch {
            // Debug level on purpose. This is not an error, it is a link that
            // declined to describe itself.
            log.debug("no preview for \(url.absoluteString, privacy: .public): \(error)")
            return nil
        }
    }

    // MARK: - Cache

    private func key(_ url: URL, _ dark: Bool) -> String {
        dark ? "dark\u{1}" + url.absoluteString : url.absoluteString
    }

    private func store(_ preview: LinkPreview?, for key: String) {
        let ttl = preview == nil ? Self.failureTTL : Self.successTTL
        cache[key] = Entry(preview: preview, expires: .now + ttl)
        guard cache.count > Self.capacity else { return }
        let now = Date.now
        cache = cache.filter { $0.value.expires > now }
        guard cache.count > Self.capacity else { return }
        // Still over: drop the entries closest to expiring, which are the ones
        // that have been sitting the longest.
        let survivors = cache.sorted { $0.value.expires > $1.value.expires }.prefix(Self.capacity)
        cache = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
    }
}
