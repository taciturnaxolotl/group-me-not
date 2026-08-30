import Foundation
import OSLog

/// Message history on disk.
///
/// The UI reads from here and only from here. The network layer's job is to
/// call `upsert` and then get out of the way, so a conversation opens at local
/// speed whether or not there is a radio.
actor MessageStore {
    private let db: Database
    private let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "messages")

    init(_ file: DatabaseFile) throws {
        self.db = try file.open()
    }

    // MARK: - Writing

    /// Stores a batch of messages, replacing any we already had.
    ///
    /// Idempotent by construction: the primary key is
    /// `(conversation, id)` and the update only fires when the incoming copy is
    /// at least as fresh as the stored one, so replaying the same page of
    /// history is a no-op rather than a rewrite. The whole batch is one
    /// transaction, which for a 200-message catch-up page is the difference
    /// between one fsync and two hundred.
    ///
    /// - Returns: the number of rows inserted or updated.
    @discardableResult
    func upsert(_ messages: [Message], in conversation: ConversationID) throws -> Int {
        guard !messages.isEmpty else { return 0 }
        let key = conversation.storageKey

        return try db.transaction {
            try ConversationWrites.ensureExists(conversation, in: db)

            var written = 0
            for message in messages {
                let payload = try StoreCoding.encode(message)
                try db.run(Self.upsertSQL, [
                    SQLValue(key),
                    SQLValue(message.id),
                    SQLValue(MessageSortKey.value(for: message.id)),
                    SQLValue(message.sourceGuid),
                    SQLValue(message.createdAt),
                    SQLValue(message.updatedAt),
                    SQLValue(message.senderId ?? message.userId),
                    SQLValue(message.text),
                    SQLValue(message.isSystem),
                    SQLValue(message.deletedAt),
                    SQLValue(message.pinnedAt),
                    SQLValue(message.parentId),
                    SQLValue(payload),
                ])
                written += db.changes
            }

            // Keep the conversation list honest without a second round trip.
            if let newest = messages.max(by: { Message.isNewer($1.id, than: $0.id) }) {
                try ConversationWrites.applyLatest(newest, conversation, in: db)
            }
            return written
        }
    }

    /// Convenience for the single message a push event delivers.
    @discardableResult
    func upsert(_ message: Message, in conversation: ConversationID) throws -> Int {
        try upsert([message], in: conversation)
    }

    /// Marks a message deleted, keeping the row so the transcript still shows
    /// the gap. GroupMe's own delete does the same: the message keeps arriving,
    /// with its text cleared.
    func tombstone(
        id: String,
        in conversation: ConversationID,
        deletedAt: Date = Date(),
        actor deletionActor: String? = nil
    ) throws {
        try db.transaction {
            guard var message = try loadMessage(id: id, in: conversation) else { return }
            message.text = nil
            message.attachments = nil
            message.deletedAt = Int(deletedAt.timeIntervalSince1970)
            message.deletionActor = deletionActor ?? message.deletionActor
            // Force the update through even if updated_at did not move.
            message.updatedAt = max(message.updatedAt ?? 0, message.deletedAt ?? 0)
            try upsertRow(message, in: conversation)
        }
    }

    /// Removes a message outright. Use for a local send that failed permanently;
    /// prefer `tombstone` for anything the server deleted.
    func delete(id: String, in conversation: ConversationID) throws {
        try db.run(
            "DELETE FROM messages WHERE conversation_key = ? AND id = ?",
            [SQLValue(conversation.storageKey), SQLValue(id)]
        )
    }

    /// Drops a conversation's whole history. The conversation row survives.
    func deleteAll(in conversation: ConversationID) throws {
        try db.run(
            "DELETE FROM messages WHERE conversation_key = ?",
            [SQLValue(conversation.storageKey)]
        )
    }

    /// Trims a conversation to its newest `keeping` messages. History we can
    /// always refetch is not worth carrying forever.
    func trim(_ conversation: ConversationID, keeping limit: Int) throws {
        try db.run(
            """
            DELETE FROM messages
             WHERE conversation_key = ?1
               AND (sort_key, id) < (
                    SELECT sort_key, id FROM messages
                     WHERE conversation_key = ?1
                     ORDER BY sort_key DESC, id DESC
                     LIMIT 1 OFFSET ?2
               )
            """,
            [SQLValue(conversation.storageKey), SQLValue(max(0, limit - 1))]
        )
    }

    // MARK: - Reading

    /// The newest `limit` messages, oldest first so the caller can append them
    /// straight into a transcript.
    ///
    /// Pass `before` to page backwards: it is the id of the oldest message you
    /// already have.
    func recent(
        _ conversation: ConversationID,
        limit: Int = 50,
        before: String? = nil
    ) throws -> [Message] {
        let key = SQLValue(conversation.storageKey)
        let rows: [Message]
        if let before {
            rows = try db.query(
                """
                SELECT payload FROM messages
                 WHERE conversation_key = ? AND (sort_key, id) < (?, ?)
                 ORDER BY sort_key DESC, id DESC
                 LIMIT ?
                """,
                [key, SQLValue(MessageSortKey.value(for: before)), SQLValue(before), SQLValue(limit)],
                decodeMessage
            )
        } else {
            rows = try db.query(
                """
                SELECT payload FROM messages
                 WHERE conversation_key = ?
                 ORDER BY sort_key DESC, id DESC
                 LIMIT ?
                """,
                [key, SQLValue(limit)],
                decodeMessage
            )
        }
        return rows.reversed()
    }

    /// Everything stored after `id`, ascending. Mirrors the server's `after_id`
    /// paging so a catch-up and a local read agree on what "after" means.
    func messages(
        _ conversation: ConversationID,
        after id: String,
        limit: Int = 200
    ) throws -> [Message] {
        try db.query(
            """
            SELECT payload FROM messages
             WHERE conversation_key = ? AND (sort_key, id) > (?, ?)
             ORDER BY sort_key ASC, id ASC
             LIMIT ?
            """,
            [
                SQLValue(conversation.storageKey),
                SQLValue(MessageSortKey.value(for: id)),
                SQLValue(id),
                SQLValue(limit),
            ],
            decodeMessage
        )
    }

    /// The newest stored message id: the anchor a catch-up passes as `after_id`.
    func syncHead(_ conversation: ConversationID) throws -> String? {
        try db.queryOne(
            """
            SELECT id FROM messages
             WHERE conversation_key = ?
             ORDER BY sort_key DESC, id DESC
             LIMIT 1
            """,
            [SQLValue(conversation.storageKey)]
        ) { $0.string(0) }
    }

    /// Sync heads for every conversation at once, so the list-and-diff step is
    /// one query rather than one per conversation.
    func syncHeads() throws -> [ConversationID: String] {
        let rows = try db.query(
            """
            SELECT c.kind, c.remote_id, m.id
              FROM conversations c
              JOIN messages m ON m.conversation_key = c.key
             WHERE m.sort_key = (
                    SELECT MAX(sort_key) FROM messages WHERE conversation_key = c.key
             )
             GROUP BY c.key
            """
        ) { row in
            (kind: row.int64(0), remoteID: row.string(1), messageID: row.string(2))
        }
        return rows.reduce(into: [:]) { result, row in
            guard let id = ConversationID(storageKind: row.kind, remoteID: row.remoteID) else { return }
            result[id] = row.messageID
        }
    }

    func message(id: String, in conversation: ConversationID) throws -> Message? {
        try loadMessage(id: id, in: conversation)
    }

    /// Finds the server's copy of a message we sent, by the guid we sent it
    /// with. This is how an outbox entry learns its real id after a `409`.
    func message(sourceGuid: String) throws -> Message? {
        try db.queryOne(
            "SELECT payload FROM messages WHERE source_guid = ? ORDER BY sort_key DESC LIMIT 1",
            [SQLValue(sourceGuid)],
            decodeMessage
        )
    }

    func count(in conversation: ConversationID) throws -> Int {
        try db.queryOne(
            "SELECT COUNT(*) FROM messages WHERE conversation_key = ?",
            [SQLValue(conversation.storageKey)]
        ) { $0.int(0) } ?? 0
    }

    /// Messages replying into a thread, oldest first.
    func replies(to parentID: String, in conversation: ConversationID) throws -> [Message] {
        try db.query(
            """
            SELECT payload FROM messages
             WHERE conversation_key = ? AND parent_id = ?
             ORDER BY sort_key ASC, id ASC
            """,
            [SQLValue(conversation.storageKey), SQLValue(parentID)],
            decodeMessage
        )
    }

    // MARK: - Internals

    private func loadMessage(id: String, in conversation: ConversationID) throws -> Message? {
        try db.queryOne(
            "SELECT payload FROM messages WHERE conversation_key = ? AND id = ?",
            [SQLValue(conversation.storageKey), SQLValue(id)],
            decodeMessage
        )
    }

    private func upsertRow(_ message: Message, in conversation: ConversationID) throws {
        _ = try upsert([message], in: conversation)
    }

    private func decodeMessage(_ row: Row) throws -> Message {
        guard let data = row.dataOrNil(0),
              let message = try? StoreCoding.decode(Message.self, from: data)
        else {
            throw StoreError.corruptRow(table: "messages", key: "payload")
        }
        return message
    }

    /// Last write wins, but only forwards: the `WHERE` stops a stale replay of
    /// an older copy from undoing an edit we already have.
    nonisolated private static let upsertSQL = """
    INSERT INTO messages
        (conversation_key, id, sort_key, source_guid, created_at, updated_at,
         sender_id, text, system, deleted_at, pinned_at, parent_id, payload)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(conversation_key, id) DO UPDATE SET
        source_guid = COALESCE(excluded.source_guid, messages.source_guid),
        updated_at  = excluded.updated_at,
        sender_id   = excluded.sender_id,
        text        = excluded.text,
        system      = excluded.system,
        deleted_at  = excluded.deleted_at,
        pinned_at   = excluded.pinned_at,
        parent_id   = excluded.parent_id,
        payload     = excluded.payload
     WHERE COALESCE(excluded.updated_at, 0) >= COALESCE(messages.updated_at, 0)
    """
}
