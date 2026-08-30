import Foundation
import OSLog

/// The send path.
///
/// A send is a local write. The composer returns the instant the row is on disk,
/// and getting it to GroupMe is this actor's problem from then on, including
/// across a cold start, a dead radio, and a server having a bad afternoon.
///
/// The whole thing rests on `source_guid`. It is generated before the first
/// request goes out and reused on every retry, so a replay the server has
/// already seen comes back `409`, which is success spelled differently. That
/// makes blind retrying safe, and safe blind retrying is what lets this queue
/// drain itself.
///
/// The official client stops at the first failure, writes "failed" next to the
/// bubble, and waits for a tap. This one never needs a tap: a transient failure
/// is a timestamp on a row, the backoff lives on disk rather than in a timer, and
/// connectivity returning collapses the wait to nothing.
actor Outbox {
    /// Outer backoff, on top of whatever `RetryPolicy.background` already spent
    /// inside the request. Unbounded in attempts, because a queued message has
    /// nowhere else to be and giving up on it would lose it.
    static let backoff = RetryPolicy(maxAttempts: .max, base: 2, cap: 300)

    /// How many entries one pass claims at a time.
    static let batchSize = 20

    /// A retry date this far out means "not on a timer": the entry is waiting for
    /// something to change, either credentials or the user.
    static let held = Date.distantFuture

    /// Fires with the conversation whose queue changed, so the UI can reload it.
    nonisolated let changes: AsyncStream<ConversationID>

    private let api: GroupMeAPI
    private let store: Store
    private let continuation: AsyncStream<ConversationID>.Continuation
    private let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "outbox")

    private var draining: Task<Void, Never>?
    private var wakeup: Task<Void, Never>?
    /// Called when a `409` leaves us knowing the message landed but not its id.
    /// The sync engine fills this in; the call is fire and forget so a drain
    /// never waits on a fetch.
    private var reconcileHook: (@Sendable (ConversationID) async -> Void)?
    /// Guids the server accepted through a `409`, waiting to learn their real
    /// message id from a catch-up. See ``reconcile()``.
    private var awaitingServerID: [String: ConversationID] = [:]

    init(api: GroupMeAPI, store: Store) {
        self.api = api
        self.store = store
        let (stream, continuation) = AsyncStream<ConversationID>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        self.changes = stream
        self.continuation = continuation
    }

    /// Point the outbox at something that can fetch a conversation's history, so
    /// a `409` can learn the server id it was not given.
    func onNeedsReconcile(_ hook: @escaping @Sendable (ConversationID) async -> Void) {
        reconcileHook = hook
    }

    // MARK: - Enqueueing

    /// Accept a message for delivery.
    ///
    /// Returns as soon as the row is durable, which is the whole point: the guid
    /// exists before any request does, so every later attempt is idempotent and
    /// the message cannot be lost by a crash between "user tapped send" and "the
    /// wire agreed".
    @discardableResult
    func send(
        text: String?,
        attachments: [Message.Attachment] = [],
        to conversation: ConversationID,
        sourceGuid: String = UUID().uuidString
    ) async throws -> OutboxEntry {
        // A send can name a conversation we have never listed, so give the
        // message a list row to hang off before anything else.
        try await store.conversations.ensureExists(conversation)
        let entry = try await store.outbox.enqueue(
            in: conversation, text: text, attachments: attachments, sourceGuid: sourceGuid)
        continuation.yield(conversation)
        kick()
        return entry
    }

    /// What is still in flight in one conversation, oldest first. The transcript
    /// appends these below stored history.
    func pending(in conversation: ConversationID) async -> [OutboxEntry] {
        (try? await store.outbox.entries(in: conversation)) ?? []
    }

    /// Put a permanently failed entry back in line. Only ever needed for the
    /// failures we deliberately refuse to auto-retry, like a message the server
    /// rejected outright.
    func retry(_ sourceGuid: String) async {
        guard let entry = try? await store.outbox.entry(sourceGuid) else { return }
        try? await store.outbox.requeue(sourceGuid)
        continuation.yield(entry.conversation)
        kick()
    }

    /// Throw a queued message away at the user's request.
    func discard(_ sourceGuid: String) async {
        guard let entry = try? await store.outbox.entry(sourceGuid) else { return }
        try? await store.outbox.remove(sourceGuid)
        continuation.yield(entry.conversation)
    }

    // MARK: - Draining

    /// Send everything that is due. Two drains never overlap; a caller arriving
    /// mid-drain waits for the one already running.
    func drain() async {
        if let draining {
            await draining.value
            return
        }
        let task = Task { await performDrain() }
        draining = task
        await task.value
        draining = nil
    }

    /// The network came back. Anything sitting out a backoff sized for a network
    /// that no longer exists gets its wait cancelled, and then we send.
    func connectivityDidReturn() async {
        await requeue(matching: { $0.state == .failed && $0.nextAttemptAt < Self.heldThreshold })
        await drain()
    }

    /// A new token is in the keychain. Releases everything that was parked
    /// waiting for exactly that.
    func credentialsDidChange() async {
        await requeue(matching: { $0.state == .failed })
        await drain()
    }

    /// Resolve entries the server accepted through a `409`.
    ///
    /// The 409 body is empty, so the entry knows it landed but not under which
    /// id. Once a catch-up has stored the conversation's history, the guid we
    /// sent it with finds the server's copy and the queue row can go.
    ///
    /// The waiting set is in memory on purpose. It is bookkeeping, not data: the
    /// message is already on the server and the next sync stores it regardless,
    /// so a crash before reconciling costs nothing but a `sent` row that
    /// `pruneSent` sweeps up. Nothing renders those rows.
    func reconcile() async {
        for (guid, conversation) in awaitingServerID {
            guard let stored = (try? await store.messages.message(sourceGuid: guid)) ?? nil else { continue }
            try? await store.outbox.markSent(guid, messageID: stored.id)
            try? await store.outbox.remove(guid)
            awaitingServerID.removeValue(forKey: guid)
            continuation.yield(conversation)
        }
        _ = try? await store.outbox.pruneSent()
    }

    private func performDrain() async {
        // Anything the app died in the middle of is safe to send again.
        _ = try? await store.outbox.releaseStalledSends()

        var attempted: Set<String> = []
        while !Task.isCancelled {
            let batch = (try? await store.outbox.ready(limit: Self.batchSize)) ?? []
            let due = batch.filter { !attempted.contains($0.id) }
            if due.isEmpty { break }

            for entry in due {
                attempted.insert(entry.id)
                // `claim` bumps the attempt count and hands the entry to exactly
                // one drain, so a second drain cannot send it twice.
                guard (try? await store.outbox.claim(entry.id)) == true else { continue }
                await attempt(entry)
            }
        }

        await scheduleNextWake()
    }

    private func attempt(_ entry: OutboxEntry) async {
        do {
            let outcome = try await api.send(
                text: entry.text,
                attachments: entry.attachments,
                to: entry.conversation,
                sourceGuid: entry.sourceGuid,
                retry: .background)

            switch outcome {
            case .sent(let message):
                // Store the server's copy first: if we die here, the next drain
                // replays the guid, gets a 409, and finds the message waiting.
                _ = try? await store.messages.upsert(message, in: entry.conversation)
                try? await store.outbox.markSent(entry.id, messageID: message.id)
                try? await store.outbox.remove(entry.id)

            case .alreadyAccepted:
                try? await store.outbox.markSent(entry.id, messageID: nil)
                if let stored = (try? await store.messages.message(sourceGuid: entry.id)) ?? nil {
                    try? await store.outbox.markSent(entry.id, messageID: stored.id)
                    try? await store.outbox.remove(entry.id)
                } else {
                    awaitingServerID[entry.id] = entry.conversation
                    if let reconcileHook {
                        // Fire and forget: the drain must not wait on a fetch,
                        // and the entry is recorded as sent either way.
                        let conversation = entry.conversation
                        Task { await reconcileHook(conversation) }
                    }
                }
                log.notice("409 for \(entry.id, privacy: .public): an earlier attempt landed")
            }
            continuation.yield(entry.conversation)

        } catch {
            await fail(entry, error)
        }
    }

    private func fail(_ entry: OutboxEntry, _ error: Error) async {
        let attempts = entry.attempts + 1  // `claim` already bumped the stored count
        let description = error.shortFailureText

        switch Self.disposition(for: error) {
        case .retry:
            // Full jitter on top of the request's own retries. The attempt index
            // is clamped so a message queued overnight retries every few minutes
            // rather than drifting out to hours.
            let advised = (error as? APIError)?.retryAfter ?? 0
            let wait = max(advised, Self.backoff.delay(forAttempt: min(attempts, 8)))
            let retryAt = Date().addingTimeInterval(max(wait, 1))
            try? await store.outbox.markFailed(entry.id, error: description, retryAt: retryAt)
            log.notice("send \(entry.id, privacy: .public) failed (\(description, privacy: .public)); retrying in \(wait, format: .fixed(precision: 1))s")

        case .waitForCredentials:
            try? await store.outbox.markFailed(entry.id, error: description, retryAt: Self.held)
            log.error("send \(entry.id, privacy: .public) needs a valid token")

        case .permanent:
            // The server will never take this message. Retrying forever would
            // burn battery to no end, so it stops here and the UI can offer to
            // discard it.
            try? await store.outbox.markFailed(entry.id, error: description, retryAt: Self.held)
            log.error("send \(entry.id, privacy: .public) rejected: \(description, privacy: .public)")
        }

        continuation.yield(entry.conversation)
    }

    // MARK: - Waking up

    /// Anything further out than this is parked, not scheduled.
    private static let heldThreshold = Date.distantFuture.addingTimeInterval(-86_400)

    /// Sleep until the earliest due entry, then drain. This is the piece that
    /// makes the queue self-clearing without a user tap; the durable half of it
    /// is `next_attempt_at` on the row, which survives the timer being killed.
    private func scheduleNextWake() async {
        wakeup?.cancel()
        wakeup = nil

        let queued = (try? await store.outbox.ready(at: Self.held, limit: 500)) ?? []
        let due = queued.map(\.nextAttemptAt).filter { $0 < Self.heldThreshold }.min()
        guard let due else { return }

        let delay = max(1, due.timeIntervalSinceNow)
        wakeup = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.drain()
        }
    }

    /// Start a drain without waiting for it, so `send` returns at local speed.
    private func kick() {
        Task { await self.drain() }
    }

    private func requeue(matching predicate: (OutboxEntry) -> Bool) async {
        // `ready(at: .distantFuture)` is every pending and failed entry, whatever
        // its backoff says, which is exactly the set we want to reconsider.
        let queued = (try? await store.outbox.ready(at: Self.held, limit: 500)) ?? []
        for entry in queued where predicate(entry) {
            try? await store.outbox.requeue(entry.id)
            continuation.yield(entry.conversation)
        }
    }

    // MARK: - Classifying failures

    private enum Disposition {
        /// Transient. Back off and try again, forever if need be.
        case retry
        /// The token is bad. Park until a new one arrives.
        case waitForCredentials
        /// The server refused the message itself. No amount of retrying helps.
        case permanent
    }

    private static func disposition(for error: Error) -> Disposition {
        guard let api = error as? APIError else { return .retry }
        switch api {
        case .transport:
            return .retry
        case .unauthenticated:
            return .waitForCredentials
        case .decoding:
            // The message may well have landed; a resend is a 409, which is free.
            return .retry
        case .http(let status, _, _):
            switch status {
            case 401, 403: return .waitForCredentials
            case 408, 429: return .retry
            case 500...599: return .retry
            case 400...499: return .permanent
            default: return .retry
            }
        }
    }
}
