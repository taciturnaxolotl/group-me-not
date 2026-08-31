import Foundation

/// Message history on disk.
///
/// The UI reads from here and only from here. The network layer's job is to
/// call `upsert` and then get out of the way, so a conversation opens at local
/// speed whether or not there is a radio.
actor MessageStore {
    private let db: Database

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
                    SQLValue(StoreCoding.encodeIfPresent(message.reactions)),
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

    /// Applies one person's reaction locally, so a tap redraws now and the
    /// network call becomes a background detail.
    ///
    /// Sets `userID`'s reaction on the message to `glyph`, or clears it when
    /// `glyph` is nil. Whatever they held before is removed first, because
    /// GroupMe allows one reaction per person per message. The heart is written
    /// into `favorited_by` rather than the reactions array, matching what the
    /// server does with the bodyless like this glyph sends.
    ///
    /// Deliberately bypasses the freshness guard on ``upsert(_:in:)``: the
    /// message's `updated_at` does not move when a reaction lands, so a guarded
    /// write would refuse its own edit. A later server copy overwrites this,
    /// which is the right outcome.
    ///
    /// - Returns: the stored message, or nil if we do not have it.
    @discardableResult
    func setReaction(
        _ glyph: String?,
        by userID: String,
        onMessage messageID: String,
        in conversation: ConversationID
    ) throws -> Message? {
        try db.transaction {
            guard var message = try loadMessage(id: messageID, in: conversation) else { return nil }

            // Clear whatever this person held, in both places it can live.
            message.favoritedBy = message.favoritedBy?.filter { $0 != userID }
            message.reactions = message.reactions?.compactMap { reaction in
                guard let users = reaction.userIds, users.contains(userID) else { return reaction }
                var updated = reaction
                updated.userIds = users.filter { $0 != userID }
                return (updated.userIds?.isEmpty ?? true) ? nil : updated
            }

            switch glyph {
            case .none:
                break
            case .some(Message.ReactionSummary.heart):
                message.favoritedBy = (message.favoritedBy ?? []) + [userID]
            case .some(let glyph):
                var reactions = message.reactions ?? []
                if let index = reactions.firstIndex(where: { $0.glyph == glyph }) {
                    reactions[index].userIds = (reactions[index].userIds ?? []) + [userID]
                } else {
                    reactions.append(Message.Reaction(
                        type: "unicode", code: glyph, userIds: [userID]))
                }
                message.reactions = reactions
            }

            try db.run(
                """
                UPDATE messages SET payload = ?, reactions = ?
                 WHERE conversation_key = ? AND id = ?
                """,
                [
                    SQLValue(try StoreCoding.encode(message)),
                    SQLValue(StoreCoding.encodeIfPresent(message.reactions)),
                    SQLValue(conversation.storageKey),
                    SQLValue(messageID),
                ])
            return message
        }
    }

    // MARK: - Reading

    /// The newest `limit` messages, oldest first so the caller can render them
    /// straight into a transcript.
    ///
    /// Paging back is done by asking for a larger `limit`, not by passing an
    /// anchor: the transcript holds one array of everything it draws, so a page
    /// of history is a longer read rather than a second one to splice on.
    func recent(_ conversation: ConversationID, limit: Int = 50) throws -> [Message] {
        let rows = try db.query(
            """
            SELECT payload FROM messages
             WHERE conversation_key = ?
             ORDER BY sort_key DESC, id DESC
             LIMIT ?
            """,
            [SQLValue(conversation.storageKey), SQLValue(limit)],
            decodeMessage
        )
        return rows.reversed()
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

    // MARK: - Internals

    private func loadMessage(id: String, in conversation: ConversationID) throws -> Message? {
        try db.queryOne(
            "SELECT payload FROM messages WHERE conversation_key = ? AND id = ?",
            [SQLValue(conversation.storageKey), SQLValue(id)],
            decodeMessage
        )
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
         sender_id, text, system, deleted_at, pinned_at, parent_id, payload, reactions)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(conversation_key, id) DO UPDATE SET
        source_guid = COALESCE(excluded.source_guid, messages.source_guid),
        updated_at  = excluded.updated_at,
        sender_id   = excluded.sender_id,
        text        = excluded.text,
        system      = excluded.system,
        deleted_at  = excluded.deleted_at,
        pinned_at   = excluded.pinned_at,
        parent_id   = excluded.parent_id,
        payload     = excluded.payload,
        reactions   = excluded.reactions
     WHERE COALESCE(excluded.updated_at, 0) >= COALESCE(messages.updated_at, 0)
    """
}
