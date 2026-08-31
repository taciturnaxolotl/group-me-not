import Foundation
import OSLog

/// The local schema, and the migration path onto it.
///
/// Four tables, not the official client's twenty. The shape follows one rule:
/// a column exists if a query filters, sorts, or renders a list with it.
/// Everything else about a message lives in its `payload` blob, which is the
/// original JSON, so the wire model round-trips exactly and adding a field to
/// `Message` never needs a migration.
nonisolated enum Schema {
    /// Bump this and add a `case` to `apply(step:)` for every change.
    static let version: Int32 = 5

    private static let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "schema")

    /// Brings a connection up to `version`. Idempotent, and safe to run from
    /// several connections at once: the check happens again under the write
    /// lock, so the loser of the race does nothing.
    static func migrate(_ db: Database) throws {
        if try userVersion(db) == version { return }
        try db.transaction {
            var current = try userVersion(db)
            guard current != version else { return }
            if current > version {
                // A newer build wrote this file. Refusing is better than
                // dropping columns we do not understand.
                throw SQLError(
                    code: 1,
                    message: "database is at schema \(current), this build understands \(version)",
                    sql: nil
                )
            }
            while current < version {
                log.notice("migrating schema \(current) -> \(current + 1)")
                try apply(step: current + 1, to: db)
                current += 1
            }
            try db.execute("PRAGMA user_version = \(version)")
        }
    }

    static func userVersion(_ db: Database) throws -> Int32 {
        let value = try db.queryOne("PRAGMA user_version") { Int32($0.int(0)) }
        return value ?? 0
    }

    private static func apply(step: Int32, to db: Database) throws {
        switch step {
        case 1: try db.execute(initial)
        case 2: try db.execute(addReactions)
        case 3: try db.execute(addEditPeriods)
        case 4: try db.execute(addPendingReactions)
        case 5: try db.execute(addOutboxMedia)
        default:
            throw SQLError(code: 1, message: "no migration defined for schema \(step)", sql: nil)
        }
    }

    // MARK: - Version 1

    private static let initial = """
    -- One row per conversation, group or DM, keyed by ConversationID.storageKey.
    CREATE TABLE conversations (
        key                   TEXT    NOT NULL PRIMARY KEY,
        kind                  INTEGER NOT NULL,            -- 0 group, 1 direct
        remote_id             TEXT    NOT NULL,            -- group id, or the other user's id
        name                  TEXT,
        avatar_url            TEXT,
        last_message_id       TEXT,
        last_message_sort     INTEGER NOT NULL DEFAULT 0,  -- see MessageSortKey
        last_message_at       INTEGER NOT NULL DEFAULT 0,  -- epoch seconds
        last_message_preview  TEXT,
        last_message_sender   TEXT,
        unread_count          INTEGER NOT NULL DEFAULT 0,
        last_read_message_id  TEXT,
        muted_until           INTEGER NOT NULL DEFAULT 0,  -- epoch seconds, 0 = not muted
        member_count          INTEGER,
        -- Set when we have only inferred this conversation from a message, so a
        -- real list fetch knows it is allowed to overwrite the placeholder name.
        placeholder           INTEGER NOT NULL DEFAULT 0,
        synced_at             INTEGER NOT NULL DEFAULT 0
    );

    -- The conversation list's only ordering. `key` breaks ties so paging is stable.
    CREATE INDEX conversations_recent
        ON conversations(last_message_at DESC, key DESC);

    -- Messages. `sort_key` is the id parsed as a big integer, because ids sort
    -- chronologically as numbers and lexically as nonsense: "9" > "10" as text.
    -- Every history query rides the (conversation_key, sort_key) index.
    CREATE TABLE messages (
        conversation_key  TEXT    NOT NULL REFERENCES conversations(key) ON DELETE CASCADE,
        id                TEXT    NOT NULL,
        sort_key          INTEGER NOT NULL,
        source_guid       TEXT,
        created_at        INTEGER NOT NULL,
        updated_at        INTEGER,
        sender_id         TEXT,
        text              TEXT,
        system            INTEGER NOT NULL DEFAULT 0,
        deleted_at        INTEGER,
        pinned_at         INTEGER,
        parent_id         TEXT,
        -- The full Message as JSON. Reads decode this and nothing else.
        payload           BLOB    NOT NULL,
        PRIMARY KEY (conversation_key, id)
    );  -- a rowid table on purpose: payload blobs are too big for WITHOUT ROWID

    -- Serves both "latest N in a conversation" (DESC, LIMIT N) and
    -- "everything after id X" (sort_key > ?, ASC).
    CREATE INDEX messages_history
        ON messages(conversation_key, sort_key DESC, id DESC);

    -- Reconciling an outbox entry with the message the server actually stored.
    CREATE INDEX messages_source_guid
        ON messages(source_guid) WHERE source_guid IS NOT NULL;

    CREATE INDEX messages_parent
        ON messages(conversation_key, parent_id) WHERE parent_id IS NOT NULL;

    -- Group membership, and the display identity we fall back to when a message
    -- carries no name of its own.
    CREATE TABLE members (
        conversation_key  TEXT NOT NULL REFERENCES conversations(key) ON DELETE CASCADE,
        user_id           TEXT NOT NULL,
        membership_id     TEXT,
        nickname          TEXT,
        name              TEXT,
        image_url         TEXT,
        roles             TEXT,   -- JSON array
        PRIMARY KEY (conversation_key, user_id)
    ) WITHOUT ROWID;

    CREATE INDEX members_user ON members(user_id);

    -- Outgoing messages, keyed by the source_guid the server dedupes on.
    -- No foreign key: a send queued into a conversation we have not listed yet
    -- must still survive.
    CREATE TABLE outbox (
        source_guid       TEXT    NOT NULL PRIMARY KEY,
        conversation_key  TEXT    NOT NULL,
        kind              INTEGER NOT NULL,   -- 0 group, 1 direct
        remote_id         TEXT    NOT NULL,
        text              TEXT,
        attachments       BLOB,               -- JSON array of Message.Attachment
        state             INTEGER NOT NULL,   -- OutboxState
        attempts          INTEGER NOT NULL DEFAULT 0,
        created_at        INTEGER NOT NULL,
        updated_at        INTEGER NOT NULL,
        next_attempt_at   INTEGER NOT NULL DEFAULT 0,
        last_error        TEXT,
        sent_message_id   TEXT
    );

    -- The drain's query: everything runnable, oldest first.
    CREATE INDEX outbox_ready ON outbox(state, next_attempt_at, created_at);

    -- The composer's query: what is still in flight in this conversation.
    CREATE INDEX outbox_conversation ON outbox(conversation_key, created_at);
    """

    // MARK: - Version 2

    /// Reactions, as the JSON array the wire sends.
    ///
    /// A column rather than a table: a message's reactions are only ever read
    /// with the message, never joined or aggregated across one, so a side table
    /// would buy a join and nothing else. `payload` already carries the same
    /// array; this column exists so a reaction can be rewritten in place when a
    /// push event or a local toggle changes one, without decoding and
    /// re-encoding the whole message.
    private static let addReactions = """
    ALTER TABLE messages ADD COLUMN reactions BLOB;
    """

    // MARK: - Version 3

    /// How long a message stays editable, per conversation.
    ///
    /// Server-owned, per group, and it has to be on disk rather than in memory:
    /// the transcript decides whether to offer an Edit action while it draws, and
    /// it draws from local storage on a cold start with the radio off. A window
    /// we only learn from a live `GET /v3/groups` would mean the affordance is
    /// missing exactly when the app is being useful offline.
    ///
    /// `/v3/chats` reports no equivalent for DMs, so the column stays NULL there
    /// and the action is not offered. Guessing a window would be worse than not
    /// offering one: the wrong guess is an action the server refuses.
    private static let addEditPeriods = """
    ALTER TABLE conversations ADD COLUMN message_edit_period INTEGER;
    ALTER TABLE conversations ADD COLUMN message_deletion_period INTEGER;
    """

    // MARK: - Version 4

    /// Reactions the user has made that the server has not taken yet.
    ///
    /// The outbox exists because a message written offline must not be lost. A
    /// reaction tapped offline deserves the same promise and used to get the
    /// opposite one: any failed request rolled it back, so with the radio off
    /// the chip un-tapped itself a moment after the tap.
    ///
    /// `message_id` is the whole key on purpose. A reaction is not an event, it
    /// is a state: one per person per message, last write wins. Five taps while
    /// offline are one intent, so an upsert replaces whatever was queued and the
    /// queue replays a single call. There is no sequence and no history here
    /// because nobody would ever want either replayed.
    ///
    /// `previous` is what the server still believes, which is not what the
    /// screen shows. ``GroupMeAPI/setReaction(_:onMessage:in:replacing:retry:)``
    /// unlikes before it likes and needs the server's idea of "before" to get
    /// that order right, so an upsert keeps the original row's value.
    ///
    /// No foreign key onto `messages`: a queued reaction that outlives its
    /// message is one stale row the drain deletes, which is cheaper than
    /// carrying the cascade.
    private static let addPendingReactions = """
    CREATE TABLE pending_reactions (
        message_id       TEXT    NOT NULL PRIMARY KEY,
        conversation_key TEXT    NOT NULL,
        kind             INTEGER NOT NULL,   -- 0 group, 1 direct
        glyph            TEXT,               -- NULL means "remove my reaction"
        previous         TEXT,               -- what the server still holds
        created_at       INTEGER NOT NULL,
        attempts         INTEGER NOT NULL DEFAULT 0,
        next_attempt_at  INTEGER NOT NULL DEFAULT 0
    ) WITHOUT ROWID;

    -- The drain's query: everything runnable, oldest first.
    CREATE INDEX pending_reactions_ready
        ON pending_reactions(next_attempt_at, created_at);

    -- The transcript's query: what to overlay on one conversation.
    CREATE INDEX pending_reactions_conversation
        ON pending_reactions(conversation_key);
    """

    // MARK: - Version 5

    /// Attachments the user has picked that no service has taken yet.
    ///
    /// A column on `outbox` rather than a table of its own, for the same reason
    /// `reactions` is a column on `messages`: this list is only ever read with
    /// its queue row and never joined or aggregated across one, so a side table
    /// would buy a join and nothing else.
    ///
    /// Separate from `attachments` because the two are different things.
    /// `attachments` is wire shape, encoded straight into the send body;
    /// `media` is local bookkeeping, a `PendingMedia` array naming files in the
    /// vault, and it is what makes a photo attached with the radio off survive a
    /// force quit. The drain uploads each entry, writes the returned URL back
    /// into this column, and only then builds the wire attachments. Writing the
    /// URL back is what stops a send that fails after a successful upload from
    /// pushing the same bytes twice.
    private static let addOutboxMedia = """
    ALTER TABLE outbox ADD COLUMN media BLOB;  -- JSON array of PendingMedia
    """
}

// MARK: - Sort keys

/// Turns a GroupMe message id into an integer that sorts the same way the id
/// does.
///
/// GroupMe ids are decimal strings of a 64-bit-ish counter, so the parse
/// normally succeeds and the ordering is exact. The fallbacks exist so a
/// surprise id shape degrades to "roughly right" instead of scrambling a
/// transcript; every query orders by `(sort_key, id)` so equal keys still come
/// out deterministically.
nonisolated enum MessageSortKey {
    static func value(for id: String) -> Int64 {
        if let exact = UInt64(id) { return Int64(clamping: exact) }
        // Leading digits, if any: ids with a suffix still land near their peers.
        let digits = id.prefix { $0.isNumber }
        if !digits.isEmpty, let partial = UInt64(digits) { return Int64(clamping: partial) }
        return 0
    }
}

// MARK: - Conversation identity in storage

nonisolated extension ConversationID {
    /// Discriminator stored in `conversations.kind` and `outbox.kind`.
    var storageKind: Int64 {
        switch self {
        case .group: 0
        case .direct: 1
        }
    }

    /// The half of the identity that is not the kind: a group id, or the other
    /// user's id. Paired with `storageKind` this rebuilds the enum.
    var remoteID: String {
        switch self {
        case .group(let id): id
        case .direct(let other): other
        }
    }

    /// Rebuilds the identity from the pair a row stores when it carries the
    /// storage key rather than the remote id. The exact inverse of
    /// ``storageKey``.
    init?(storageKind: Int64, storageKey: String) {
        switch storageKind {
        case 0: self = .group(storageKey)
        case 1:
            let prefix = "dm:"
            self = .direct(
                otherUserID: storageKey.hasPrefix(prefix)
                    ? String(storageKey.dropFirst(prefix.count))
                    : storageKey)
        default: return nil
        }
    }

    init?(storageKind: Int64, remoteID: String) {
        switch storageKind {
        case 0: self = .group(remoteID)
        case 1: self = .direct(otherUserID: remoteID)
        default: return nil
        }
    }
}
