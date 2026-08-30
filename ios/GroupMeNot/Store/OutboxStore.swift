import Foundation
import OSLog

/// Where a queued send is in its life.
nonisolated enum OutboxState: Int64, Sendable, CaseIterable {
    /// Waiting for a drain.
    case pending = 0
    /// A drain has claimed it and a request is in flight.
    case sending = 1
    /// The server took it. Kept briefly so the UI can reconcile the bubble.
    case sent = 2
    /// The last attempt failed. Retried once `nextAttemptAt` passes.
    case failed = 3
}

/// One outgoing message, keyed by the guid the server dedupes on.
nonisolated struct OutboxEntry: Identifiable, Hashable, Sendable {
    /// `source_guid`: our idempotency key, and the row's primary key.
    var id: String
    var conversation: ConversationID
    var text: String?
    var attachments: [Message.Attachment]
    var state: OutboxState
    var attempts: Int
    var createdAt: Date
    var updatedAt: Date
    /// The earliest a drain should try again. Backoff lives here rather than in
    /// a timer, so it survives the app being killed.
    var nextAttemptAt: Date
    var lastError: String?
    /// Filled in once we learn the server id, which for a `409` replay needs a
    /// reconciling read.
    var sentMessageID: String?

    var sourceGuid: String { id }

    /// A stand-in `Message` so the transcript can render the bubble before the
    /// server has ever seen it. The id is the guid, so it never collides with a
    /// real message id; the transcript appends echoes after stored history
    /// rather than sorting them into it.
    func localEcho(sender: CurrentUser?) -> Message {
        Message(
            id: sentMessageID ?? id,
            sourceGuid: id,
            createdAt: Int(createdAt.timeIntervalSince1970),
            userId: sender?.id,
            senderId: sender?.id,
            name: sender?.name,
            avatarUrl: sender?.imageUrl,
            senderType: "user",
            text: text,
            system: false,
            favoritedBy: [],
            attachments: attachments.isEmpty ? nil : attachments,
            groupId: conversation.isGroup ? conversation.remoteID : nil,
            chatId: nil,
            recipientId: conversation.isGroup ? nil : conversation.remoteID,
            parentId: nil,
            pinnedAt: nil,
            pinnedBy: nil,
            deletedAt: nil,
            deletionActor: nil,
            updatedAt: nil,
            event: nil
        )
    }
}

/// The queue of messages we have accepted from the user but not yet handed to
/// GroupMe.
///
/// This is what makes the composer feel instant: a send is a local write, and
/// the network drains the queue whenever it can. `source_guid` makes the replay
/// safe, since resending one the server already has comes back `409`, which is
/// success spelled differently.
actor OutboxStore {
    private let db: Database
    private let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "outbox")

    init(_ file: DatabaseFile) throws {
        self.db = try file.open()
    }

    // MARK: - Queueing

    /// Accepts a message for delivery and returns the row the UI should render.
    ///
    /// The guid is generated here unless the caller supplies one, and it is the
    /// only identity the message has until the server assigns a real id.
    @discardableResult
    func enqueue(
        in conversation: ConversationID,
        text: String?,
        attachments: [Message.Attachment] = [],
        sourceGuid: String = UUID().uuidString,
        at now: Date = Date()
    ) throws -> OutboxEntry {
        let entry = OutboxEntry(
            id: sourceGuid,
            conversation: conversation,
            text: text,
            attachments: attachments,
            state: .pending,
            attempts: 0,
            createdAt: now,
            updatedAt: now,
            nextAttemptAt: now,
            lastError: nil,
            sentMessageID: nil
        )
        try insert(entry)
        return entry
    }

    /// Writes an entry as given. Re-enqueueing the same guid is a no-op, which
    /// is what makes a retried "send" button harmless.
    func insert(_ entry: OutboxEntry) throws {
        try db.run(
            """
            INSERT INTO outbox
                (source_guid, conversation_key, kind, remote_id, text, attachments,
                 state, attempts, created_at, updated_at, next_attempt_at, last_error, sent_message_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_guid) DO NOTHING
            """,
            [
                SQLValue(entry.id),
                SQLValue(entry.conversation.storageKey),
                SQLValue(entry.conversation.storageKind),
                SQLValue(entry.conversation.remoteID),
                SQLValue(entry.text),
                SQLValue(entry.attachments.isEmpty ? nil : StoreCoding.encodeIfPresent(entry.attachments)),
                SQLValue(entry.state.rawValue),
                SQLValue(entry.attempts),
                SQLValue(entry.createdAt),
                SQLValue(entry.updatedAt),
                SQLValue(entry.nextAttemptAt),
                SQLValue(entry.lastError),
                SQLValue(entry.sentMessageID),
            ]
        )
    }

    // MARK: - Draining

    /// Everything still waiting to go out, oldest first.
    func pending(limit: Int = 200) throws -> [OutboxEntry] {
        try db.query(
            """
            SELECT \(Self.columns) FROM outbox
             WHERE state = ?
             ORDER BY created_at ASC
             LIMIT ?
            """,
            [SQLValue(OutboxState.pending.rawValue), SQLValue(limit)],
            Self.decode
        )
    }

    /// Everything a drain should attempt right now: fresh sends plus failures
    /// whose backoff has elapsed.
    func ready(at now: Date = Date(), limit: Int = 200) throws -> [OutboxEntry] {
        try db.query(
            """
            SELECT \(Self.columns) FROM outbox
             WHERE state IN (?, ?) AND next_attempt_at <= ?
             ORDER BY created_at ASC
             LIMIT ?
            """,
            [
                SQLValue(OutboxState.pending.rawValue),
                SQLValue(OutboxState.failed.rawValue),
                SQLValue(now),
                SQLValue(limit),
            ],
            Self.decode
        )
    }

    /// Takes ownership of an entry before sending it, bumping the attempt
    /// count. Returns false if someone else got there first, which is how two
    /// concurrent drains avoid sending the same thing twice.
    func claim(_ sourceGuid: String, at now: Date = Date()) throws -> Bool {
        try db.run(
            """
            UPDATE outbox
               SET state = ?, attempts = attempts + 1, updated_at = ?
             WHERE source_guid = ? AND state IN (?, ?)
            """,
            [
                SQLValue(OutboxState.sending.rawValue),
                SQLValue(now),
                SQLValue(sourceGuid),
                SQLValue(OutboxState.pending.rawValue),
                SQLValue(OutboxState.failed.rawValue),
            ]
        )
        return db.changes > 0
    }

    /// The server has it. `messageID` is nil when we learned this from a `409`,
    /// which carries no body; a reconciling read fills it in later.
    func markSent(_ sourceGuid: String, messageID: String?, at now: Date = Date()) throws {
        try db.run(
            """
            UPDATE outbox
               SET state = ?, updated_at = ?, last_error = NULL,
                   sent_message_id = COALESCE(?, sent_message_id)
             WHERE source_guid = ?
            """,
            [
                SQLValue(OutboxState.sent.rawValue),
                SQLValue(now),
                SQLValue(messageID),
                SQLValue(sourceGuid),
            ]
        )
    }

    /// The attempt failed. `retryAt` is when a drain may try again; pass a far
    /// future date for a failure the user has to resolve.
    func markFailed(
        _ sourceGuid: String,
        error: String?,
        retryAt: Date,
        at now: Date = Date()
    ) throws {
        try db.run(
            """
            UPDATE outbox
               SET state = ?, updated_at = ?, next_attempt_at = ?, last_error = ?
             WHERE source_guid = ?
            """,
            [
                SQLValue(OutboxState.failed.rawValue),
                SQLValue(now),
                SQLValue(retryAt),
                SQLValue(error),
                SQLValue(sourceGuid),
            ]
        )
    }

    /// Puts an entry back in line, typically because the user tapped retry.
    func requeue(_ sourceGuid: String, at now: Date = Date()) throws {
        try db.run(
            """
            UPDATE outbox
               SET state = ?, updated_at = ?, next_attempt_at = ?, last_error = NULL
             WHERE source_guid = ?
            """,
            [
                SQLValue(OutboxState.pending.rawValue),
                SQLValue(now),
                SQLValue(now),
                SQLValue(sourceGuid),
            ]
        )
    }

    /// Rescues entries stuck in `sending` because the app died mid-request.
    /// Resending is safe: the guid makes it idempotent.
    ///
    /// - Returns: how many entries were released.
    @discardableResult
    func releaseStalledSends(olderThan interval: TimeInterval = 60, now: Date = Date()) throws -> Int {
        try db.run(
            """
            UPDATE outbox
               SET state = ?, updated_at = ?, next_attempt_at = ?
             WHERE state = ? AND updated_at <= ?
            """,
            [
                SQLValue(OutboxState.pending.rawValue),
                SQLValue(now),
                SQLValue(now),
                SQLValue(OutboxState.sending.rawValue),
                SQLValue(now.addingTimeInterval(-interval)),
            ]
        )
        let released = db.changes
        if released > 0 { log.notice("released \(released) stalled outbox entries") }
        return released
    }

    // MARK: - Reading

    /// What is still in flight in one conversation, oldest first. The transcript
    /// appends these below the stored history.
    func entries(in conversation: ConversationID, includingSent: Bool = false) throws -> [OutboxEntry] {
        let states = includingSent
            ? OutboxState.allCases
            : [.pending, .sending, .failed]
        let placeholders = states.map { _ in "?" }.joined(separator: ", ")
        var bindings: [SQLValue] = [SQLValue(conversation.storageKey)]
        bindings.append(contentsOf: states.map { SQLValue($0.rawValue) })
        return try db.query(
            """
            SELECT \(Self.columns) FROM outbox
             WHERE conversation_key = ? AND state IN (\(placeholders))
             ORDER BY created_at ASC
            """,
            bindings,
            Self.decode
        )
    }

    func entry(_ sourceGuid: String) throws -> OutboxEntry? {
        try db.queryOne(
            "SELECT \(Self.columns) FROM outbox WHERE source_guid = ?",
            [SQLValue(sourceGuid)],
            Self.decode
        )
    }

    func count(state: OutboxState) throws -> Int {
        try db.queryOne(
            "SELECT COUNT(*) FROM outbox WHERE state = ?",
            [SQLValue(state.rawValue)]
        ) { $0.int(0) } ?? 0
    }

    // MARK: - Removing

    func remove(_ sourceGuid: String) throws {
        try db.run("DELETE FROM outbox WHERE source_guid = ?", [SQLValue(sourceGuid)])
    }

    /// Clears out entries the server has accepted and the transcript has caught
    /// up with. Run after a sync; there is nothing to be gained by keeping them.
    @discardableResult
    func pruneSent(olderThan interval: TimeInterval = 300, now: Date = Date()) throws -> Int {
        try db.run(
            "DELETE FROM outbox WHERE state = ? AND updated_at <= ?",
            [SQLValue(OutboxState.sent.rawValue), SQLValue(now.addingTimeInterval(-interval))]
        )
        return db.changes
    }

    func removeAll(in conversation: ConversationID) throws {
        try db.run(
            "DELETE FROM outbox WHERE conversation_key = ?",
            [SQLValue(conversation.storageKey)]
        )
    }

    // MARK: - Internals

    nonisolated private static let columns = """
    source_guid, kind, remote_id, text, attachments, state, attempts,
    created_at, updated_at, next_attempt_at, last_error, sent_message_id
    """

    nonisolated private static func decode(_ row: Row) throws -> OutboxEntry {
        let kind = row.int64(1)
        guard let conversation = ConversationID(storageKind: kind, remoteID: row.string(2)) else {
            throw StoreError.unknownConversationKind(kind)
        }
        let attachments = StoreCoding
            .decodeIfPossible([Message.Attachment].self, from: row.dataOrNil(4)) ?? []
        return OutboxEntry(
            id: row.string(0),
            conversation: conversation,
            text: row.stringOrNil(3),
            attachments: attachments,
            state: OutboxState(rawValue: row.int64(5)) ?? .pending,
            attempts: row.int(6),
            createdAt: row.dateOrNil(7) ?? Date(timeIntervalSince1970: 0),
            updatedAt: row.dateOrNil(8) ?? Date(timeIntervalSince1970: 0),
            nextAttemptAt: row.dateOrNil(9) ?? Date(timeIntervalSince1970: 0),
            lastError: row.stringOrNil(10),
            sentMessageID: row.stringOrNil(11)
        )
    }
}
