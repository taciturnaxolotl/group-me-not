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
    private let uploads: MediaUploadService
    private let vault: MediaVault
    private let continuation: AsyncStream<ConversationID>.Continuation
    private let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "outbox")
    private var progressHook: (@Sendable (String, Double) -> Void)?

    private var draining: Task<Void, Never>?
    private var wakeup: Task<Void, Never>?
    /// Called when a `409` leaves us knowing the message landed but not its id.
    /// The sync engine fills this in; the call is fire and forget so a drain
    /// never waits on a fetch.
    private var reconcileHook: (@Sendable (ConversationID) async -> Void)?
    /// Guids the server accepted through a `409`, waiting to learn their real
    /// message id from a catch-up. See ``reconcile()``.
    private var awaitingServerID: [String: ConversationID] = [:]

    init(
        api: GroupMeAPI,
        store: Store,
        uploads: MediaUploadService,
        vault: MediaVault = .shared
    ) {
        self.api = api
        self.store = store
        self.uploads = uploads
        self.vault = vault
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

    /// Watch how far along an entry's attachments are, as a fraction.
    ///
    /// Deliberately a hook and not a stored column. Upload progress is true for
    /// a few seconds and meaningless afterwards; writing it to SQLite would mean
    /// a database write per network packet to persist a number that is wrong the
    /// moment the app is killed.
    func onUploadProgress(_ hook: @escaping @Sendable (String, Double) -> Void) {
        progressHook = hook
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
        media: [PickedMedia] = [],
        to conversation: ConversationID,
        sourceGuid: String = UUID().uuidString
    ) async throws -> OutboxEntry {
        // The bytes go somewhere durable before the row that names them, so a
        // crash in between leaves an unclaimed file rather than a queue entry
        // pointing at nothing. `sweep` cleans up after that; nothing cleans up
        // after the other order.
        var pending: [PendingMedia] = []
        for item in media {
            do {
                pending.append(try await vault.adopt(item))
            } catch {
                log.error("could not keep a picked file: \(error)")
            }
        }

        // A send can name a conversation we have never listed, so give the
        // message a list row to hang off before anything else.
        try await store.conversations.ensureExists(conversation)
        // Everything above this line is local. The row is on disk before a
        // single byte goes anywhere, which is the promise the whole queue rests
        // on: an attachment picked in a tunnel is already the user's message.
        let entry = try await store.outbox.enqueue(
            in: conversation, text: text, attachments: attachments, media: pending,
            sourceGuid: sourceGuid)
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
        await vault.remove(entry.media)
        continuation.yield(entry.conversation)
    }

    /// Delete vault files no queue row claims any more.
    ///
    /// Runs after a drain, where the rows that just left the queue are.
    private func sweepMedia() async {
        guard let claimed = try? await store.outbox.claimedMediaFilenames() else { return }
        await vault.sweep(keeping: claimed)
    }

    // MARK: - Draining

    /// Send everything that is due. Two drains never overlap; a caller arriving
    /// mid-drain waits for the one already running.
    func drain() async {
        if let draining {
            await draining.value
            return
        }
        // Claimed around the whole drain, not around each request. A queue of
        // three photos that is interrupted between two of them is interrupted
        // just the same; the point is to keep going until the queue is empty or
        // the system says stop.
        await BackgroundTime.begin(Self.backgroundTimeName)
        let task = Task { await performDrain() }
        draining = task
        await task.value
        draining = nil
        await BackgroundTime.end(Self.backgroundTimeName)
    }

    private static let backgroundTimeName = "sh.dunkirk.GroupMeNot.send" 

    /// A background transfer finished with nobody waiting for it.
    ///
    /// This is the whole reason uploads survive the app being put away. The
    /// await inside ``MediaUploadService`` belongs to a process that may have
    /// been suspended hours ago; what the system hands back on relaunch is a
    /// task, a body, and the job that was written on it. Turning that into "this
    /// attachment is uploaded" is a database write, and the send that follows is
    /// an ordinary drain.
    ///
    /// Idempotent by construction: an attachment that already has a URL is left
    /// alone, so a duplicate delivery costs a lookup.
    func apply(_ outcome: UploadOutcome) async {
        let job = outcome.job
        guard outcome.error == nil, let status = outcome.status, (200...299).contains(status) else {
            // Left in the queue exactly as it was. The next drain re-posts it,
            // which for a failed transfer is the right answer and for a video
            // means asking the transcoder rather than sending the file again.
                log.notice("background upload for \(job.guid, privacy: .public) did not land: HTTP \(outcome.status ?? -1, privacy: .public)")
            await drain()
            return
        }

        guard var entry = try? await store.outbox.entry(job.guid),
              entry.media.indices.contains(job.index),
              !entry.media[job.index].isUploaded
        else { return }

        switch job.step {
        case .presignedPut:
            entry.media[job.index].uploadedUrl = job.renderURL
            entry.media[job.index].uploadedPreviewUrl =
                job.thumbnailURL ?? entry.media[job.index].uploadedPreviewUrl
        case .pictureService:
            guard let url = Self.pictureURL(in: outcome.body) else { return }
            entry.media[job.index].uploadedUrl = url
        case .transcode:
            // Not finished, only accepted. The video is on the transcoder's side
            // now, and where to ask about it is the thing worth writing down:
            // the next drain waits rather than uploading it again.
            guard let statusURL = Self.transcodeStatusURL(in: outcome.body) else { return }
            entry.media[job.index].transcodeStatusUrl = statusURL
        }

        try? await store.outbox.setMedia(entry.media, for: entry.id)
        continuation.yield(entry.conversation)
        await drain()
    }

    private static func pictureURL(in body: Data) -> String? {
        struct Payload: Decodable {
            struct Inner: Decodable { var url: String? }
            var payload: Inner?
        }
        let url = (try? JSONDecoder().decode(Payload.self, from: body))?.payload?.url
        return url?.isEmpty == false ? url : nil
    }

    private static func transcodeStatusURL(in body: Data) -> String? {
        struct Started: Decodable { var status_url: String? }
        let url = (try? JSONDecoder().decode(Started.self, from: body))?.status_url
        return url?.isEmpty == false ? url : nil
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
        await sweepMedia()
    }

    private func attempt(_ entry: OutboxEntry) async {
        do {
            // Attachments first. A message referencing a `file://` URL is a
            // message GroupMe would store and nobody could ever open, so the
            // send does not happen until every picked file has a real one.
            let entry = try await uploadingMedia(entry)

            let outcome = try await api.send(
                text: entry.text,
                attachments: entry.allAttachments,
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
                await vault.remove(entry.media)

            case .alreadyAccepted:
                try? await store.outbox.markSent(entry.id, messageID: nil)
                if let stored = (try? await store.messages.message(sourceGuid: entry.id)) ?? nil {
                    try? await store.outbox.markSent(entry.id, messageID: stored.id)
                    try? await store.outbox.remove(entry.id)
                    await vault.remove(entry.media)
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

    /// How many attachments of one message go up at once. Two is the whole of
    /// the reasoning: it halves the wait for a photo set without turning a
    /// message into a burst that a media service is entitled to throttle.
    private static let uploadConcurrency = 2

    /// Push every attachment that has not been pushed, and hand back the entry
    /// with its URLs filled in.
    ///
    /// Each success is written to disk as it happens rather than at the end. A
    /// message with three photos that loses the network after the second one
    /// resumes at the third, and a `409` on a resend never costs a second copy
    /// of the same video.
    private func uploadingMedia(_ entry: OutboxEntry) async throws -> OutboxEntry {
        guard entry.needsUpload else { return entry }

        let senderID = await api.currentUser()
        let groupID = entry.conversation.isGroup ? entry.conversation.remoteID : nil
        let conversationID = try? await api.conversationRestID(entry.conversation)

        var entry = entry
        // Progress is reported for the message, not for the file: the bubble is
        // one thing and a reader does not care that it happens to be three
        // photographs. Attachments already uploaded count as whole, which is
        // what makes a resumed send pick up where the ring left off.
        let total = Double(entry.media.count)
        let guid = entry.id
        let report = progressHook
        let progress = UploadProgress(
            finished: entry.media.count(where: \.isUploaded), total: entry.media.count)

        let waiting = entry.media.indices.filter { !entry.media[$0].isUploaded }

        // A few at a time rather than one after another.
        //
        // Three photos used to go up strictly in turn, so the message took as
        // long as the sum of them and a slow first file held two finished ones
        // behind it. They are independent uploads to a service that is happy to
        // take them at once; what they are not is unlimited, hence the window.
        //
        // Each result is still written to disk the moment it lands, in whatever
        // order they land in, so a send interrupted halfway resumes with exactly
        // the ones that finished.
        try await withThrowingTaskGroup(of: (Int, UploadedMedia).self) { group in
            var next = 0
            func start(_ index: Int) {
                let media = entry.media[index]
                group.addTask { [uploads] in
                    let uploaded = try await uploads.upload(
                        media,
                        guid: guid,
                        index: index,
                        senderID: senderID,
                        groupID: groupID,
                        conversationID: conversationID,
                        onProgress: { fraction in
                            guard total > 0 else { return }
                            report?(guid, progress.report(index, at: fraction))
                        })
                    return (index, uploaded)
                }
            }

            while next < min(Self.uploadConcurrency, waiting.count) {
                start(waiting[next])
                next += 1
            }
            while let (index, uploaded) = try await group.next() {
                entry.media[index].uploadedUrl = uploaded.url
                entry.media[index].uploadedPreviewUrl =
                    uploaded.previewURL ?? entry.media[index].uploadedPreviewUrl
                try? await store.outbox.setMedia(entry.media, for: entry.id)
                progressHook?(entry.id, progress.finish(index))
                // The bubble picks up the real URL as soon as the row does,
                // which is what makes a slow send show its photo arriving
                // rather than sitting there looking stuck.
                continuation.yield(entry.conversation)
                if next < waiting.count {
                    start(waiting[next])
                    next += 1
                }
            }
        }
        return entry
    }

    private func fail(_ entry: OutboxEntry, _ error: Error) async {
        let attempts = entry.attempts + 1  // `claim` already bumped the stored count
        let description = (error as? MediaUploadError).map(Self.uploadFailureText) ?? failureText(error)

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

    /// A short phrase for a failed upload, fit for the line under a bubble.
    private static func uploadFailureText(_ error: MediaUploadError) -> String {
        switch error {
        case .transport: "offline"
        case .unavailable(let status, _): "HTTP \(status)"
        case .unauthenticated: "signed out"
        case .rejected: "attachment refused"
        case .malformed: "unreadable response"
        case .transcodeTimedOut: "still processing"
        case .missingFile: "attachment missing"
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
        // An upload failure and a send failure are the same three questions:
        // wait for the radio, wait for a token, or stop. The upload service
        // answers them itself rather than making this read status codes twice.
        if let upload = error as? MediaUploadError {
            if upload.needsCredentials { return .waitForCredentials }
            return upload.isRetryable ? .retry : .permanent
        }
        guard let api = error as? APIError else { return .retry }
        switch api {
        case .transport:
            return .retry
        case .unauthenticated:
            return .waitForCredentials
        case .decoding:
            // The message may well have landed; a resend is a 409, which is free.
            return .retry
        case .noContent:
            // The server took it and said nothing back. Same reasoning as a
            // decoding failure: the safe move is to resend, because the guid
            // makes a duplicate impossible.
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

/// How far a message's attachments have got, across uploads running at once.
///
/// A tally rather than arithmetic at the call site, because with two files in
/// the air the fraction is a sum: what has finished, plus how far each of the
/// ones still going has got. A lock because the callbacks arrive off whatever
/// thread the transfer is on, often.
nonisolated private final class UploadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var finished: Int
    private let total: Int
    private var inFlight: [Int: Double] = [:]

    init(finished: Int, total: Int) {
        self.finished = finished
        self.total = total
    }

    func report(_ index: Int, at fraction: Double) -> Double {
        lock.lock()
        inFlight[index] = fraction
        let value = combined()
        lock.unlock()
        return value
    }

    func finish(_ index: Int) -> Double {
        lock.lock()
        inFlight[index] = nil
        finished += 1
        let value = combined()
        lock.unlock()
        return value
    }

    /// Called under the lock.
    private func combined() -> Double {
        guard total > 0 else { return 1 }
        let partial = inFlight.values.reduce(0, +)
        return min((Double(finished) + partial) / Double(total), 1)
    }
}

