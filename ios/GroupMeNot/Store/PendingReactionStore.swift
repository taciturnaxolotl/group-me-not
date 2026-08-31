import Foundation
import OSLog

/// A reaction the user has made that GroupMe has not taken yet.
///
/// The message id is the identity, because that is how many reactions one
/// person can have on one message: one. See `pending_reactions` in ``Schema``.
nonisolated struct PendingReaction: Identifiable, Hashable, Sendable {
    /// The message this reaction is on, and the row's primary key.
    var id: String
    var conversation: ConversationID
    /// The glyph to end up with, or nil to end up with none.
    var glyph: String?
    /// What the server still holds, which the swap has to unlike first.
    var previous: String?
    var createdAt: Date
    var attempts: Int
    /// The earliest a drain should try again. On disk rather than in a timer,
    /// so the wait survives the app being killed.
    var nextAttemptAt: Date

    var messageID: String { id }
}

/// The queue of reactions accepted from the user but not yet handed to GroupMe.
///
/// The sibling of ``OutboxStore``, and deliberately much smaller. A send is an
/// event that must be delivered exactly once, so it needs states, an
/// idempotency key and a claim. A reaction is a state the server should end up
/// in, so a row can simply be replaced: the newest intent is the only one worth
/// sending, and replaying it is harmless whatever the server currently holds.
actor PendingReactionStore {
    private let db: Database
    private let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "reactions")

    init(_ file: DatabaseFile) throws {
        self.db = try file.open()
    }

    // MARK: - Queueing

    /// Record the reaction the user meant, replacing anything queued for the
    /// same message.
    ///
    /// `previous` is only honoured on the first queueing. A second tap replaces
    /// the glyph but keeps the server's idea of what came before, because that
    /// is what the eventual unlike-then-like has to work against; adopting the
    /// second tap's `previous` would tell the drain to unlike a reaction the
    /// server never received.
    ///
    /// The backoff resets too. A new tap is a fresh intent and should not
    /// inherit the wait earned by the one it replaced.
    @discardableResult
    func upsert(
        _ glyph: String?,
        onMessage messageID: String,
        in conversation: ConversationID,
        replacing previous: String?,
        at now: Date = Date()
    ) throws -> PendingReaction {
        try db.run(
            """
            INSERT INTO pending_reactions
                (message_id, conversation_key, kind, glyph, previous,
                 created_at, attempts, next_attempt_at)
            VALUES (?, ?, ?, ?, ?, ?, 0, ?)
            ON CONFLICT(message_id) DO UPDATE SET
                conversation_key = excluded.conversation_key,
                kind             = excluded.kind,
                glyph            = excluded.glyph,
                attempts         = 0,
                next_attempt_at  = excluded.next_attempt_at
            """,
            [
                SQLValue(messageID),
                SQLValue(conversation.storageKey),
                SQLValue(conversation.storageKind),
                SQLValue(glyph),
                SQLValue(previous),
                SQLValue(now),
                SQLValue(now),
            ]
        )
        return try entry(messageID) ?? PendingReaction(
            id: messageID,
            conversation: conversation,
            glyph: glyph,
            previous: previous,
            createdAt: now,
            attempts: 0,
            nextAttemptAt: now
        )
    }

    // MARK: - Draining

    /// Everything a drain should attempt right now, oldest intent first.
    func ready(at now: Date = Date(), limit: Int = 200) throws -> [PendingReaction] {
        try db.query(
            """
            SELECT \(Self.columns) FROM pending_reactions
             WHERE next_attempt_at <= ?
             ORDER BY created_at ASC
             LIMIT ?
            """,
            [SQLValue(now), SQLValue(limit)],
            Self.decode
        )
    }

    /// The attempt failed and is worth making again. Counts it and pushes the
    /// row out to `retryAt`.
    func markFailed(_ messageID: String, retryAt: Date) throws {
        try db.run(
            """
            UPDATE pending_reactions
               SET attempts = attempts + 1, next_attempt_at = ?
             WHERE message_id = ?
            """,
            [SQLValue(retryAt), SQLValue(messageID)]
        )
    }

    // MARK: - Reading

    /// What is still queued in one conversation. The transcript overlays these
    /// on stored history, so a catch-up cannot flicker a chip back off.
    func entries(in conversation: ConversationID) throws -> [PendingReaction] {
        try db.query(
            """
            SELECT \(Self.columns) FROM pending_reactions
             WHERE conversation_key = ?
             ORDER BY created_at ASC
            """,
            [SQLValue(conversation.storageKey)],
            Self.decode
        )
    }

    func entry(_ messageID: String) throws -> PendingReaction? {
        try db.queryOne(
            "SELECT \(Self.columns) FROM pending_reactions WHERE message_id = ?",
            [SQLValue(messageID)],
            Self.decode
        )
    }

    // MARK: - Removing

    func remove(_ messageID: String) throws {
        try db.run("DELETE FROM pending_reactions WHERE message_id = ?", [SQLValue(messageID)])
    }

    func removeAll(in conversation: ConversationID) throws {
        try db.run(
            "DELETE FROM pending_reactions WHERE conversation_key = ?",
            [SQLValue(conversation.storageKey)]
        )
    }

    func removeAll() throws {
        try db.run("DELETE FROM pending_reactions")
    }

    // MARK: - Internals

    nonisolated private static let columns = """
    message_id, conversation_key, kind, glyph, previous, created_at, attempts, next_attempt_at
    """

    nonisolated private static func decode(_ row: Row) throws -> PendingReaction {
        let kind = row.int64(2)
        guard let conversation = ConversationID(storageKind: kind, storageKey: row.string(1)) else {
            throw StoreError.unknownConversationKind(kind)
        }
        return PendingReaction(
            id: row.string(0),
            conversation: conversation,
            glyph: row.stringOrNil(3),
            previous: row.stringOrNil(4),
            createdAt: row.dateOrNil(5) ?? Date(timeIntervalSince1970: 0),
            attempts: row.int(6),
            nextAttemptAt: row.dateOrNil(7) ?? Date(timeIntervalSince1970: 0)
        )
    }
}
