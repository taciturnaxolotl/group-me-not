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
    static let version: Int32 = 1

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

    init?(storageKind: Int64, remoteID: String) {
        switch storageKind {
        case 0: self = .group(remoteID)
        case 1: self = .direct(otherUserID: remoteID)
        default: return nil
        }
    }
}
