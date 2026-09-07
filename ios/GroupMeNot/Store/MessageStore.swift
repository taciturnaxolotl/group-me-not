import Foundation

/// Message history on disk.
///
/// The UI reads from here and only from here. The network layer's job is to
/// call `upsert` and then get out of the way, so a conversation opens at local
/// speed whether or not there is a radio.
actor MessageStore {
    private let db: Database

    /// Messages already decoded, so a reload does not turn the same JSON into
    /// the same values again.
    ///
    /// The transcript is re-read whenever anything in it changes, and during a
    /// catch-up that is several times a second over a window of hundreds. Almost
    /// all of those rows are the ones that were there a moment ago. Every write
    /// goes through this actor, so a cache that is dropped on write is exact
    /// rather than hopeful: there is no staleness to reason about, because a row
    /// that changed is a row that is no longer in here.
    ///
    /// Three writers, and each must forget what it wrote: ``upsert(_:in:)``,
    /// ``writeMerged(_:in:)``, and ``writeReactions(of:id:in:)``. A fourth that
    /// did not would fail quietly rather than loudly — it would serve one
    /// message's previous copy for as long as nothing else rewrote it, which is
    /// exactly what happened the first time this cache shipped.
    private var decoded: [MessageKey: Message] = [:]

    private struct MessageKey: Hashable {
        var conversation: String
        var id: String
    }

    /// Roughly a long conversation's worth. Past it the whole thing goes rather
    /// than the oldest: an exact eviction order costs more bookkeeping than the
    /// decode it would save.
    private static let decodeCacheCapacity = 5_000

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
            forget(messages.map(\.id), in: key)
            return written
        }
    }

    /// Convenience for the single message a push event delivers.
    @discardableResult
    func upsert(_ message: Message, in conversation: ConversationID) throws -> Int {
        try upsert([message], in: conversation)
    }

    /// Folds a revision of a message we already hold into the stored copy.
    ///
    /// This is what a `message.update` push turns into. It is not an
    /// ``upsert(_:in:)``: an edit payload is a revision, not a whole message,
    /// and replacing the row with it would drop the likes, reactions and
    /// attachments the update did not bother to repeat. Worse, it would be
    /// unrecoverable, because `after_id` never revisits an id it has passed, so
    /// nothing short of refetching history you already have would put them back.
    /// ``Message/merging(_:)`` is the rule; this is where it meets the disk.
    ///
    /// A message we have never seen is inserted whole instead, which is the
    /// right fallback: an edit is also the first time an offline client may be
    /// hearing about a message at all.
    ///
    /// - Returns: the stored message afterwards.
    @discardableResult
    func applyUpdate(_ update: Message, in conversation: ConversationID) throws -> Message {
        try db.transaction {
            guard let stored = try loadMessage(id: update.id, in: conversation) else {
                try writeMerged(update, in: conversation)
                return update
            }
            let merged = stored.merging(update)
            try writeMerged(merged, in: conversation)
            return merged
        }
    }

    /// Rewrites one message's text locally, ahead of the server agreeing.
    ///
    /// The optimistic half of an edit: the bubble changes on the next frame and
    /// the PUT follows. Pass the stamp back through ``applyUpdate(_:in:)`` when
    /// the server's own revision arrives, and pass the original text back here
    /// if the PUT fails.
    ///
    /// - Returns: the stored message, or nil if we do not have it.
    @discardableResult
    /// Mark a message deleted, the way the server does.
    ///
    /// A tombstone rather than a removal, because that is what comes back: the
    /// row keeps its id and gains `deleted_at`, so a later catch-up agrees with
    /// what was drawn instead of resurrecting the text.
    func markDeleted(
        _ messageID: String,
        at stamp: Int = Int(Date().timeIntervalSince1970),
        by actor: String?,
        in conversation: ConversationID
    ) throws -> Message? {
        try db.transaction {
            guard var stored = try loadMessage(id: messageID, in: conversation) else { return nil }
            stored.deletedAt = stamp
            stored.deletionActor = actor
            stored.text = nil
            stored.attachments = nil
            try writeMerged(stored, in: conversation)
            return stored
        }
    }

    func applyEdit(
        text: String?,
        updatedAt: Int = Int(Date().timeIntervalSince1970),
        toMessage messageID: String,
        in conversation: ConversationID
    ) throws -> Message? {
        try db.transaction {
            guard let stored = try loadMessage(id: messageID, in: conversation) else { return nil }
            let edited = stored.editing(text: text, updatedAt: updatedAt)
            try writeMerged(edited, in: conversation)
            return edited
        }
    }

    /// Applies one person's reaction to the stored copy, so a scroll, a reload
    /// or a relaunch agrees with the chip the tap already drew.
    ///
    /// The edit itself is ``Message/settingReaction(_:by:)``, which is the same
    /// function ``AppModel`` applies to the published array. Sharing it is the
    /// point: two hand-written copies of "one reaction per person, and the
    /// heart lives in `favorited_by`" would drift the first time either changed.
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
            guard let stored = try loadMessage(id: messageID, in: conversation) else { return nil }
            let message = stored.settingReaction(glyph, by: userID)

            try writeReactions(of: message, id: messageID, in: conversation)
            return message
        }
    }

    /// Replaces a message's whole reaction set with the one a `favorite` or
    /// `like.delete` push delivered.
    ///
    /// The push carries the complete list, not a delta: the official client
    /// hands it straight to `updateReactionsForMessage(…, replace: true)` and
    /// treats an absent array as "no reactions at all". So this replaces rather
    /// than merges, which is the only reading under which removing the last
    /// reaction can ever reach us.
    ///
    /// `favorited_by` is cleared for the same reason. It is not a second,
    /// independent set of likers; it is the legacy *view* of this same data,
    /// which is why the modern client hides the heart row entirely whenever it
    /// draws reaction pills. Leaving a stale copy behind would strand a phantom
    /// heart on the message forever, because `after_id` paging never revisits a
    /// message to correct it.
    ///
    /// Bypasses ``upsertSQL``'s freshness guard on purpose: a reaction does not
    /// move `updated_at`, so a guarded write would refuse its own edit.
    ///
    /// - Returns: the stored message afterwards, or nil if we do not hold it.
    @discardableResult
    func replaceReactions(
        _ reactions: [Message.Reaction],
        onMessage messageID: String,
        in conversation: ConversationID
    ) throws -> Message? {
        try db.transaction {
            guard var message = try loadMessage(id: messageID, in: conversation) else { return nil }
            message.reactions = reactions
            message.favoritedBy = nil

            try writeReactions(of: message, id: messageID, in: conversation)
            return message
        }
    }

    /// The write both reaction paths make, in one place.
    ///
    /// One place because of what has to happen alongside it. A reaction does not
    /// move `updated_at`, so these two are the only writes in this actor that
    /// change a message without going through ``upsert(_:in:)`` or
    /// ``writeMerged(_:in:)`` — and each of those forgets the row it wrote,
    /// while these used not to. The decode cache then kept handing back the
    /// copy from before the tap: the chip appeared, the next reload took it
    /// away again, and a reaction arriving from somebody else never showed up
    /// at all until a catch-up happened to rewrite the message for other
    /// reasons. A cache is only exact if every writer says so; this is the
    /// third writer, saying so.
    private func writeReactions(
        of message: Message, id: String, in conversation: ConversationID
    ) throws {
        try db.run(
            """
            UPDATE messages SET payload = ?, reactions = ?
             WHERE conversation_key = ? AND id = ?
            """,
            [
                SQLValue(try StoreCoding.encode(message)),
                SQLValue(StoreCoding.encodeIfPresent(message.reactions)),
                SQLValue(conversation.storageKey),
                SQLValue(id),
            ])
        forget([id], in: conversation.storageKey)
    }

    // MARK: - Reading

    /// The newest `limit` messages, oldest first so the caller can render them
    /// straight into a transcript.
    ///
    /// Paging back is done by asking for a larger `limit`, not by passing an
    /// anchor: the transcript holds one array of everything it draws, so a page
    /// of history is a longer read rather than a second one to splice on.
    func recent(_ conversation: ConversationID, limit: Int = 50) throws -> [Message] {
        let key = conversation.storageKey
        // The id comes back beside the payload so a hit can be answered without
        // decoding the blob it arrived with.
        let rows = try db.query(
            """
            SELECT id, payload FROM messages
             WHERE conversation_key = ?
             ORDER BY sort_key DESC, id DESC
             LIMIT ?
            """,
            [SQLValue(key), SQLValue(limit)]
        ) { row in (id: row.string(0), payload: row.dataOrNil(1)) }

        var messages: [Message] = []
        messages.reserveCapacity(rows.count)
        for row in rows {
            let cacheKey = MessageKey(conversation: key, id: row.id)
            if let hit = decoded[cacheKey] {
                messages.append(hit)
                continue
            }
            guard let payload = row.payload,
                  let message = try? StoreCoding.decode(Message.self, from: payload)
            else { continue }
            remember(message, at: cacheKey)
            messages.append(message)
        }
        return messages.reversed()
    }

    private func remember(_ message: Message, at key: MessageKey) {
        if decoded.count >= Self.decodeCacheCapacity { decoded.removeAll(keepingCapacity: true) }
        decoded[key] = message
    }

    /// Forget rows that have just been written. Called from the two places that
    /// write one: the batch upsert and the merge behind every edit, reaction and
    /// tombstone.
    private func forget(_ ids: [String], in conversation: String) {
        for id in ids { decoded.removeValue(forKey: MessageKey(conversation: conversation, id: id)) }
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

    /// Writes an already-merged message straight over the stored row.
    ///
    /// Deliberately without ``upsertSQL``'s freshness guard. That guard exists to
    /// stop a stale *replay* from undoing an edit; here the caller has already
    /// merged the two revisions by hand, so the row in front of it is the answer
    /// and refusing it on a timestamp comparison would only lose the edit. The
    /// list row is repointed too, because editing the newest message changes what
    /// the conversation list should be previewing.
    ///
    /// Must be called inside a transaction.
    private func writeMerged(_ message: Message, in conversation: ConversationID) throws {
        try ConversationWrites.ensureExists(conversation, in: db)
        try db.run(
            """
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
            """,
            [
                SQLValue(conversation.storageKey),
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
                SQLValue(try StoreCoding.encode(message)),
                SQLValue(StoreCoding.encodeIfPresent(message.reactions)),
            ])
        try ConversationWrites.applyLatest(message, conversation, in: db)
        forget([message.id], in: conversation.storageKey)
    }

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
