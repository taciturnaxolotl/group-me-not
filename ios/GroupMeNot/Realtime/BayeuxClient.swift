import Foundation
import os

/// GroupMe's realtime feed: Faye speaking Bayeux over a WebSocket.
///
/// Lifecycle, in one place: `start(as:)` opens a socket, handshakes, subscribes
/// to `/user/{me}`, and keeps the socket alive with a `/meta/connect` every
/// `advice.timeout - 30s`. If anything drops it reconnects with jittered
/// exponential backoff and re-subscribes, because Faye has no replay: on every
/// resume it emits `.connectionDidResume(afterGap:)` so the sync layer can close
/// the hole over REST. This client stores nothing and calls no REST endpoint.
///
/// Framing is asymmetric and easy to get backwards: **we send a bare JSON object,
/// the server sends an array of them.**
actor BayeuxClient {
    /// `Configuration.getFayeHost()`.
    static let defaultURL = URL(string: "wss://push.groupme.com:443/faye")!

    /// The event feed. Single consumer, buffering the newest frames so a slow
    /// reader loses old typing notices rather than stalling the socket.
    nonisolated let events: AsyncStream<RealtimeEvent>

    private let url: URL
    private let tokenProvider: @Sendable () async -> String?
    private let continuation: AsyncStream<RealtimeEvent>.Continuation
    private let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "faye")
    private let coder = JSONValue.Coder.groupMe()
    private let urlSession: URLSession

    /// Backoff shaped like `RetryPolicy.background` but unbounded in attempts: a
    /// realtime socket should keep trying for as long as the app is alive.
    private let backoff = RetryPolicy(maxAttempts: .max, base: 1, cap: 60)

    private var socket: URLSessionWebSocketTask?
    private var supervisor: Task<Void, Never>?
    private var keepalive: Task<Void, Never>?
    private var backoffSleep: Task<Void, Error>?

    private var running = false
    private var userID: String?
    private var clientID: String?
    /// Bumped per socket so late frames and timers from a dead session are ignored.
    private var generation = 0
    private var didHandshakeThisSession = false

    /// Every channel we want to be on. The set is the truth; the socket is a cache
    /// of it, re-applied after each handshake.
    private var desiredChannels: Set<String> = []
    /// The channels `focus(on:)` manages, so they can be swapped as the reader
    /// moves between conversations.
    private var focusChannels: Set<String> = []
    /// Channels followed for as long as they exist, rather than only while
    /// their conversation is on screen. See ``follow(topics:)``.
    private var standingChannels: Set<String> = []

    private var adviceTimeout: TimeInterval = 600
    private var lastDisconnectAt: Date?
    private var hasEverConnected = false
    private var lastTypingSentAt: [String: Date] = [:]

    private(set) var state: RealtimeConnectionState = .idle {
        didSet {
            guard state != oldValue else { return }
            continuation.yield(.connectionStateDidChange(state))
        }
    }

    /// `tokenProvider` is the same access token the REST client uses; there is no
    /// separate push credential. It is read per authorised frame rather than held,
    /// so a re-login takes effect on the next subscribe.
    init(url: URL = BayeuxClient.defaultURL,
         tokenProvider: @escaping @Sendable () async -> String?) {
        self.url = url
        self.tokenProvider = tokenProvider
        let (stream, continuation) = AsyncStream<RealtimeEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        self.events = stream
        self.continuation = continuation

        let config = URLSessionConfiguration.default
        // The socket is long lived by design; the resource timeout must not kill it.
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = .greatestFiniteMagnitude
        config.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Lifecycle

    /// Connect and stay connected, as `userID`. Idempotent for the same user;
    /// calling it with a different user restarts the socket.
    func start(as userID: String) {
        if running, self.userID == userID { return }
        if running { stopNow() }

        self.userID = userID
        running = true
        desiredChannels.insert(Self.userChannel(userID))
        supervisor = Task { [weak self] in await self?.supervise() }
    }

    /// Disconnect and stop reconnecting. Sends `/meta/disconnect` first so the
    /// server drops our subscriptions instead of waiting them out.
    func stop() async {
        guard running else { return }
        running = false
        if let clientID {
            // Unauthenticated by protocol: `ext` is excluded from disconnect.
            try? await send(["channel": "/meta/disconnect", "clientId": clientID, "id": Self.newID()])
        }
        stopNow()
    }

    private func stopNow() {
        running = false
        generation &+= 1
        keepalive?.cancel(); keepalive = nil
        backoffSleep?.cancel(); backoffSleep = nil
        supervisor?.cancel(); supervisor = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        clientID = nil
        state = .idle
    }

    /// Called when reachability returns. Cuts the current backoff short instead of
    /// waiting out a sleep that was sized for a network that is now back.
    func networkDidBecomeAvailable() {
        guard running else { return }
        backoffSleep?.cancel()
    }

    // MARK: - Subscriptions

    /// Subscribe now if connected, and remember it for the next handshake.
    func subscribe(to channel: String) async {
        guard desiredChannels.insert(channel).inserted else { return }
        await sendSubscribe(channel)
    }

    func unsubscribe(from channel: String) async {
        guard desiredChannels.remove(channel) != nil else { return }
        guard let clientID else { return }
        var frame: [String: Any] = [
            "channel": "/meta/unsubscribe",
            "clientId": clientID,
            "subscription": channel,
            "id": Self.newID(),
        ]
        frame = await authorised(frame)
        try? await send(frame)
    }

    /// Follow the conversations currently on screen, dropping the previous ones.
    ///
    /// `/user/{me}` already carries everything addressed to us; these extra
    /// subscriptions are the app's own policy, and they are what makes typing
    /// indicators and other people's likes show up promptly in an open thread.
    /// Pass an empty list when leaving the conversation.
    ///
    /// A list rather than one channel, because a topic has two plausible
    /// addresses. Its own `/group/{topicID}` accepts a subscription, and so does
    /// its parent's, and nothing short of watching a real message arrive says
    /// which one GroupMe publishes on. Subscribing to both costs one frame and
    /// settles it; guessing costs a conversation that never updates.
    func focus(on conversations: [ConversationID]) async {
        guard let userID else { return }
        let wanted = Set(conversations.map { $0.pushChannel(myUserID: userID) })
        guard wanted != focusChannels else { return }
        for old in focusChannels.subtracting(wanted) where !standingChannels.contains(old) {
            await unsubscribe(from: old)
        }
        for new in wanted.subtracting(focusChannels) { await subscribe(to: new) }
        focusChannels = wanted
    }

    /// Keep a standing subscription to conversations `/user/{me}` does not
    /// carry.
    ///
    /// Topics are the reason this exists. The personal channel delivers every
    /// group and direct message addressed to the account, which is why an
    /// ordinary conversation lights up without being open — and it does not
    /// deliver topics. A topic that nobody is looking at therefore stayed silent
    /// until the next sync, which is minutes of a conversation simply not
    /// arriving.
    ///
    /// Capped, because this is one subscription each and an account could in
    /// principle belong to a great many. Past the cap the sync loop is still the
    /// backstop it always was.
    func follow(topics: [ConversationID]) async {
        guard let userID else { return }
        let wanted = Set(topics.prefix(Self.standingLimit).map { $0.pushChannel(myUserID: userID) })
        guard wanted != standingChannels else { return }
        for old in standingChannels.subtracting(wanted) where !focusChannels.contains(old) {
            await unsubscribe(from: old)
        }
        for new in wanted.subtracting(standingChannels) { await subscribe(to: new) }
        standingChannels = wanted
    }

    private static let standingLimit = 64

    // MARK: - Publishing

    /// Tell a conversation we are typing. Throttled to one frame per second per
    /// channel, matching the official client; receivers expire the indicator 1.5s
    /// after the last event, and there is no "stopped typing" message to send.
    ///
    /// Dropped silently when the socket is down: a typing notice is worthless late.
    func sendTyping(in conversation: ConversationID) async {
        guard let userID, let clientID else { return }
        let channel = conversation.pushChannel(myUserID: userID)
        let now = Date()
        if let last = lastTypingSentAt[channel],
           now.timeIntervalSince(last) < PushEvent.Typing.publishThrottle { return }
        lastTypingSentAt[channel] = now

        var frame: [String: Any] = [
            "channel": channel,
            "clientId": clientID,
            "id": Self.newID(),
            "data": [
                "type": PushEvent.WireType.typing,
                "user_id": userID,
                // Epoch milliseconds here, unlike every REST timestamp.
                "started": Int(now.timeIntervalSince1970 * 1000),
            ] as [String: Any],
        ]
        frame = await authorised(frame)
        try? await send(frame)
    }

    // MARK: - The supervision loop

    private func supervise() async {
        var attempt = 0
        while running, !Task.isCancelled {
            generation &+= 1
            let generation = generation
            didHandshakeThisSession = false

            do {
                try await runSession(generation: generation)
                continuation.yield(.connectionDidDrop(nil))
            } catch let error as RealtimeError {
                continuation.yield(.connectionDidDrop(error))
            } catch {
                continuation.yield(.connectionDidDrop(.transport(String(describing: error))))
            }

            keepalive?.cancel(); keepalive = nil
            socket?.cancel(with: .goingAway, reason: nil); socket = nil
            clientID = nil
            if didHandshakeThisSession { lastDisconnectAt = Date() }
            guard running, !Task.isCancelled else { break }

            // A session that got as far as a handshake earned a clean slate; one
            // that never did is probably hitting something that needs waiting out.
            if didHandshakeThisSession { attempt = 0 }
            let wait = backoff.delay(forAttempt: attempt)
            attempt += 1
            log.debug("faye reconnect in \(wait, format: .fixed(precision: 2))s")
            await sleepBeforeReconnect(wait)
        }
        state = .idle
    }

    /// One socket, from open to close. Returns when the server closes cleanly and
    /// throws on transport failure; either way the caller reconnects.
    private func runSession(generation: Int) async throws {
        state = .connecting
        let socket = urlSession.webSocketTask(with: url)
        self.socket = socket
        socket.resume()

        state = .handshaking
        // No `ext` on the handshake: it is unauthenticated, and the token would be
        // ignored anyway. We offer only `websocket` because it is the only
        // transport this client can actually speak; the server also serves
        // long-polling and SSE, which is the fallback to build if captive portals
        // and corporate wifi turn out to matter.
        try await send([
            "channel": "/meta/handshake",
            "version": "1.0",
            "supportedConnectionTypes": ["websocket"],
            "id": Self.newID(),
        ])

        while self.generation == generation, running {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                if self.generation != generation { return }
                throw RealtimeError.transport(String(describing: error))
            }
            guard self.generation == generation else { return }
            for frame in decodeFrames(message) {
                try await handle(frame, generation: generation)
            }
        }
    }

    private func sleepBeforeReconnect(_ seconds: TimeInterval) async {
        state = .waitingToReconnect(seconds: seconds)
        let sleeper = Task { try await Task.sleep(for: .seconds(seconds)) }
        backoffSleep = sleeper
        // Cancellation here means "reconnect now", not "give up".
        _ = try? await sleeper.value
        backoffSleep = nil
    }

    // MARK: - Frame handling

    private func handle(_ frame: BayeuxFrame, generation: Int) async throws {
        switch frame.channel {
        case "/meta/handshake":
            guard frame.successful == true, let id = frame.clientId else {
                throw RealtimeError.handshakeRejected(frame.error ?? "no clientId")
            }
            clientID = id
            didHandshakeThisSession = true
            apply(frame.advice)
            try await sendConnect()
            for channel in desiredChannels { await sendSubscribe(channel) }
            state = .connected

            let gap = hasEverConnected ? Date().timeIntervalSince(lastDisconnectAt ?? Date()) : nil
            hasEverConnected = true
            continuation.yield(.connectionDidResume(afterGap: gap))
            startKeepalive(generation: generation)

        case "/meta/connect":
            apply(frame.advice)
            if frame.successful == false || frame.advice?.reconnect == "handshake" {
                // Our clientId is gone. Tear the socket down and let supervise()
                // start over rather than sending into a session the server forgot.
                throw RealtimeError.clientExpired
            }

        case "/meta/subscribe":
            if frame.successful == false {
                let channel = frame.subscription ?? "?"
                continuation.yield(.subscriptionDidFail(channel: channel, reason: frame.error ?? "unknown"))
                log.error("faye subscribe failed for \(channel, privacy: .public): \(frame.error ?? "unknown", privacy: .public)")
            }

        case "/meta/unsubscribe", "/meta/disconnect":
            break

        default:
            if let event = PushEvent(frame: frame, coder: coder) {
                continuation.yield(.push(event))
            }
        }
    }

    private func decodeFrames(_ message: URLSessionWebSocketTask.Message) -> [BayeuxFrame] {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let payload): data = payload
        @unknown default: return []
        }
        // Inbound is an array. A bare object is not supposed to happen, but
        // accepting one costs a line and saves a silent blackout if it does.
        if let frames = try? coder.decoder.decode([BayeuxFrame].self, from: data) { return frames }
        if let frame = try? coder.decoder.decode(BayeuxFrame.self, from: data) { return [frame] }
        log.error("faye frame did not decode: \(String(decoding: data.prefix(512), as: UTF8.self), privacy: .private)")
        return []
    }

    private func apply(_ advice: BayeuxAdvice?) {
        if let timeout = advice?.timeout, timeout > 0 {
            adviceTimeout = timeout / 1000
        }
    }

    // MARK: - Sending

    private func sendConnect() async throws {
        guard let clientID else { return }
        // No `ext`: connect is excluded from auth, same as handshake and disconnect.
        try await send([
            "channel": "/meta/connect",
            "clientId": clientID,
            "connectionType": "websocket",
            "id": Self.newID(),
        ])
    }

    private func sendSubscribe(_ channel: String) async {
        guard let clientID else { return }
        var frame: [String: Any] = [
            "channel": "/meta/subscribe",
            "clientId": clientID,
            "subscription": channel,
            "id": Self.newID(),
        ]
        frame = await authorised(frame)
        do {
            try await send(frame)
        } catch {
            log.error("faye subscribe send failed for \(channel, privacy: .public)")
        }
    }

    /// Keepalive is a `/meta/connect` every `advice.timeout - 30s`. At the observed
    /// 600000ms that is one frame roughly every nine and a half minutes.
    private func startKeepalive(generation: Int) {
        keepalive?.cancel()
        let interval = max(30, adviceTimeout - 30)
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                await self?.pingIfCurrent(generation: generation)
            }
        }
    }

    private func pingIfCurrent(generation: Int) async {
        guard self.generation == generation, running else { return }
        try? await sendConnect()
    }

    /// Attach the access token. `ext` goes on subscribe, unsubscribe and publish
    /// only; handshake, connect and disconnect must not carry it.
    private func authorised(_ frame: [String: Any]) async -> [String: Any] {
        guard let token = await tokenProvider() else { return frame }
        var frame = frame
        frame["ext"] = ["access_token": token]
        return frame
    }

    /// Outgoing frames are bare objects, never arrays.
    private func send(_ frame: [String: Any]) async throws {
        guard let socket else { throw RealtimeError.notRunning }
        let data = try JSONSerialization.data(withJSONObject: frame, options: [])
        do {
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        } catch {
            throw RealtimeError.transport(String(describing: error))
        }
    }

    /// Bayeux `id` is a fresh UUID per message, not a counter.
    private static func newID() -> String { UUID().uuidString }

    static func userChannel(_ userID: String) -> String { "/user/\(userID)" }
}
