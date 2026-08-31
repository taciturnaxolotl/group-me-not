import Foundation

/// One row of the conversation list, already in the shape the UI renders.
///
/// This is a local type, not a wire type: it flattens `Group` and `Chat` into
/// the handful of fields a list cell needs, so the list never has to know which
/// of the two it is looking at.
nonisolated struct ConversationRow: Identifiable, Hashable, Sendable {
    var id: ConversationID
    var name: String
    var avatarURL: String?
    var lastMessageID: String?
    var lastMessageAt: Date?
    var lastMessagePreview: String?
    var lastMessageSender: String?
    var unreadCount: Int
    var lastReadMessageID: String?
    var mutedUntil: Date?
    var memberCount: Int?
    /// How long after posting a message may still be edited, in seconds, as the
    /// server reports it for this conversation. Nil or zero means editing is off.
    ///
    /// Carried on the list row rather than looked up per message so the
    /// transcript can decide whether to offer an Edit action without a request,
    /// which is the only way the affordance is honest offline.
    var messageEditPeriod: Int?
    /// The matching window for deletion, same rules. Stored now because it comes
    /// down the same fetch; nothing reads it yet.
    var messageDeletionPeriod: Int?
    /// True while all we know is that the conversation exists, because a
    /// message arrived for it before any list fetch did.
    var isPlaceholder: Bool

    var isGroup: Bool { id.isGroup }
    var hasUnread: Bool { unreadCount > 0 }

    func isMuted(at date: Date = Date()) -> Bool {
        guard let mutedUntil else { return false }
        return mutedUntil > date
    }

    var isMuted: Bool { isMuted() }

    /// Whether `message` is still inside this conversation's edit window.
    ///
    /// The same rule as ``Group/canEdit(_:now:)``, asked of the row the UI
    /// already holds. False when we have no window, which is every DM: `/v3/chats`
    /// reports no edit period, and an action the server is going to refuse is
    /// worse than no action at all.
    func canEdit(_ message: Message, now: Date = Date()) -> Bool {
        guard let period = messageEditPeriod, period > 0 else { return false }
        return now.timeIntervalSince(message.date) < TimeInterval(period)
    }
}

/// The conversation list, plus membership.
///
/// Everything the list view needs is denormalised into one row, so rendering
/// it is a single indexed scan and never a join against messages.
actor ConversationStore {
    private let db: Database

    init(_ file: DatabaseFile) throws {
        self.db = try file.open()
    }

    // MARK: - Writing

    /// Folds a page of `/v3/groups` into the list.
    func upsert(groups: [Group]) throws {
        guard !groups.isEmpty else { return }
        try db.transaction {
            for group in groups {
                try upsert(row: Self.row(from: group))
                if let members = group.members {
                    try replaceMembers(members, in: .group(group.id))
                }
            }
        }
    }

    /// Folds a page of `/v3/chats` into the list.
    func upsert(chats: [Chat]) throws {
        guard !chats.isEmpty else { return }
        try db.transaction {
            for chat in chats {
                try upsert(row: Self.row(from: chat))
                if let message = chat.lastMessage {
                    try ConversationWrites.applyLatest(
                        message, .direct(otherUserID: chat.otherUser.id), in: db
                    )
                }
            }
        }
    }

    /// Writes one row. Fields the caller left empty do not erase what we already
    /// know, and the last-message columns only move forwards, so a list fetch
    /// that raced a push event cannot rewind the list.
    func upsert(row: ConversationRow) throws {
        try db.run(Self.upsertSQL, [
            SQLValue(row.id.storageKey),
            SQLValue(row.id.storageKind),
            SQLValue(row.id.remoteID),
            SQLValue(row.name.isEmpty ? nil : row.name),
            SQLValue(row.avatarURL),
            SQLValue(row.lastMessageID),
            SQLValue(row.lastMessageID.map(MessageSortKey.value(for:)) ?? 0),
            SQLValue(Int64(row.lastMessageAt?.timeIntervalSince1970 ?? 0)),
            SQLValue(row.lastMessagePreview),
            SQLValue(row.lastMessageSender),
            SQLValue(row.unreadCount),
            SQLValue(row.lastReadMessageID),
            SQLValue(Int64(row.mutedUntil?.timeIntervalSince1970 ?? 0)),
            SQLValue(row.memberCount),
            SQLValue(row.isPlaceholder),
            SQLValue(Date()),
            SQLValue(row.messageEditPeriod),
            SQLValue(row.messageDeletionPeriod),
        ])
    }

    /// Creates a bare row if the conversation is new to us. Used when a message
    /// or an outgoing send names a conversation we have never listed.
    func ensureExists(_ conversation: ConversationID) throws {
        try ConversationWrites.ensureExists(conversation, in: db)
    }

    /// Marks read locally. Clears the badge immediately; the read receipt POST
    /// can follow whenever the network is willing.
    func markRead(_ conversation: ConversationID, upTo messageID: String? = nil) throws {
        let target = try messageID ?? currentLastMessageID(conversation)
        try db.run(
            """
            UPDATE conversations
               SET unread_count = 0,
                   last_read_message_id = COALESCE(?, last_read_message_id)
             WHERE key = ?
            """,
            [SQLValue(target), SQLValue(conversation.storageKey)]
        )
    }

    /// Bumps the badge by one. The push path uses this: an arriving message
    /// should light up the list without waiting for a conversation refetch.
    func incrementUnread(_ conversation: ConversationID, by amount: Int = 1) throws {
        try db.run(
            "UPDATE conversations SET unread_count = MAX(0, unread_count + ?) WHERE key = ?",
            [SQLValue(amount), SQLValue(conversation.storageKey)]
        )
    }

    func setMuted(_ conversation: ConversationID, until date: Date?) throws {
        try db.run(
            "UPDATE conversations SET muted_until = ? WHERE key = ?",
            [SQLValue(date ?? Date(timeIntervalSince1970: 0)), SQLValue(conversation.storageKey)]
        )
    }

    /// Removes the conversation and, by cascade, its messages and members.
    func delete(_ conversation: ConversationID) throws {
        try db.run("DELETE FROM conversations WHERE key = ?", [SQLValue(conversation.storageKey)])
    }

    // MARK: - Reading

    /// The conversation list, newest activity first.
    func list(limit: Int = 200, offset: Int = 0) throws -> [ConversationRow] {
        try db.query(
            """
            SELECT \(Self.columns) FROM conversations
             ORDER BY last_message_at DESC, key DESC
             LIMIT ? OFFSET ?
            """,
            [SQLValue(limit), SQLValue(offset)],
            Self.decode
        )
    }

    func conversation(_ conversation: ConversationID) throws -> ConversationRow? {
        try db.queryOne(
            "SELECT \(Self.columns) FROM conversations WHERE key = ?",
            [SQLValue(conversation.storageKey)],
            Self.decode
        )
    }

    /// Total unread across every conversation, for the app badge.
    func totalUnread() throws -> Int {
        try db.queryOne("SELECT COALESCE(SUM(unread_count), 0) FROM conversations") { $0.int(0) } ?? 0
    }

    // MARK: - Members

    /// Replaces a conversation's membership wholesale, which is what a
    /// `?omit=memberships`-free fetch actually gives you: the current truth,
    /// with departures expressed as absence.
    func replaceMembers(_ members: [Member], in conversation: ConversationID) throws {
        try db.transaction {
            try ConversationWrites.ensureExists(conversation, in: db)
            let key = conversation.storageKey
            try db.run("DELETE FROM members WHERE conversation_key = ?", [SQLValue(key)])
            for member in members {
                guard let userID = member.userId ?? member.id else { continue }
                try db.run(
                    """
                    INSERT INTO members
                        (conversation_key, user_id, membership_id, nickname, name, image_url, roles)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(conversation_key, user_id) DO UPDATE SET
                        membership_id = excluded.membership_id,
                        nickname      = excluded.nickname,
                        name          = excluded.name,
                        image_url     = excluded.image_url,
                        roles         = excluded.roles
                    """,
                    [
                        SQLValue(key),
                        SQLValue(userID),
                        SQLValue(member.id),
                        SQLValue(member.nickname),
                        SQLValue(member.name),
                        SQLValue(member.imageUrl),
                        SQLValue(StoreCoding.encodeIfPresent(member.roles).flatMap { String(data: $0, encoding: .utf8) }),
                    ]
                )
            }
            try db.run(
                """
                UPDATE conversations SET member_count =
                    (SELECT COUNT(*) FROM members WHERE conversation_key = ?1)
                 WHERE key = ?1
                """,
                [SQLValue(key)]
            )
        }
    }

    func members(of conversation: ConversationID) throws -> [Member] {
        try db.query(
            """
            SELECT membership_id, user_id, nickname, name, image_url, roles
              FROM members WHERE conversation_key = ?
             ORDER BY COALESCE(nickname, name, user_id) COLLATE NOCASE
            """,
            [SQLValue(conversation.storageKey)]
        ) { row in
            Member(
                id: row.stringOrNil(0),
                userId: row.stringOrNil(1),
                nickname: row.stringOrNil(2),
                name: row.stringOrNil(3),
                imageUrl: row.stringOrNil(4),
                roles: row.stringOrNil(5)
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { StoreCoding.decodeIfPossible([String].self, from: $0) }
            )
        }
    }

    // MARK: - Internals

    private func currentLastMessageID(_ conversation: ConversationID) throws -> String? {
        try db.queryOne(
            "SELECT last_message_id FROM conversations WHERE key = ?",
            [SQLValue(conversation.storageKey)]
        ) { $0.stringOrNil(0) } ?? nil
    }

    nonisolated private static let columns = """
    kind, remote_id, name, avatar_url, last_message_id, last_message_at,
    last_message_preview, last_message_sender, unread_count, last_read_message_id,
    muted_until, member_count, placeholder, message_edit_period, message_deletion_period
    """

    nonisolated private static func decode(_ row: Row) throws -> ConversationRow {
        let kind = row.int64(0)
        guard let id = ConversationID(storageKind: kind, remoteID: row.string(1)) else {
            throw StoreError.unknownConversationKind(kind)
        }
        return ConversationRow(
            id: id,
            name: row.stringOrNil(2) ?? "",
            avatarURL: row.stringOrNil(3),
            lastMessageID: row.stringOrNil(4),
            lastMessageAt: row.dateOrNil(5),
            lastMessagePreview: row.stringOrNil(6),
            lastMessageSender: row.stringOrNil(7),
            unreadCount: row.int(8),
            lastReadMessageID: row.stringOrNil(9),
            mutedUntil: row.dateOrNil(10),
            memberCount: row.intOrNil(11),
            messageEditPeriod: row.intOrNil(13),
            messageDeletionPeriod: row.intOrNil(14),
            isPlaceholder: row.bool(12)
        )
    }

    /// `COALESCE(excluded.x, conversations.x)` throughout, so a partial update
    /// adds knowledge and never removes it. The last-message columns carry the
    /// extra guard that they only move forwards.
    nonisolated private static let upsertSQL = """
    INSERT INTO conversations
        (key, kind, remote_id, name, avatar_url, last_message_id, last_message_sort,
         last_message_at, last_message_preview, last_message_sender, unread_count,
         last_read_message_id, muted_until, member_count, placeholder, synced_at,
         message_edit_period, message_deletion_period)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(key) DO UPDATE SET
        name       = COALESCE(excluded.name, conversations.name),
        avatar_url = COALESCE(excluded.avatar_url, conversations.avatar_url),
        last_message_id = CASE WHEN excluded.last_message_sort >= conversations.last_message_sort
                               THEN COALESCE(excluded.last_message_id, conversations.last_message_id)
                               ELSE conversations.last_message_id END,
        last_message_sort = MAX(excluded.last_message_sort, conversations.last_message_sort),
        last_message_at = MAX(excluded.last_message_at, conversations.last_message_at),
        last_message_preview = CASE WHEN excluded.last_message_sort >= conversations.last_message_sort
                                    THEN COALESCE(excluded.last_message_preview, conversations.last_message_preview)
                                    ELSE conversations.last_message_preview END,
        last_message_sender = CASE WHEN excluded.last_message_sort >= conversations.last_message_sort
                                   THEN COALESCE(excluded.last_message_sender, conversations.last_message_sender)
                                   ELSE conversations.last_message_sender END,
        unread_count = excluded.unread_count,
        last_read_message_id = COALESCE(excluded.last_read_message_id, conversations.last_read_message_id),
        muted_until = CASE WHEN excluded.kind = 0
                           THEN excluded.muted_until
                           ELSE COALESCE(NULLIF(excluded.muted_until, 0), conversations.muted_until) END,
        member_count = COALESCE(excluded.member_count, conversations.member_count),
        placeholder = 0,
        synced_at = excluded.synced_at,
        message_edit_period = COALESCE(excluded.message_edit_period, conversations.message_edit_period),
        message_deletion_period = COALESCE(excluded.message_deletion_period, conversations.message_deletion_period)
    """

    // MARK: - Wire model to row

    nonisolated static func row(from group: Group) -> ConversationRow {
        let summary = group.messages
        let preview = summary?.preview
        return ConversationRow(
            id: .group(group.id),
            name: group.name,
            avatarURL: group.imageUrl,
            lastMessageID: summary?.lastMessageId,
            lastMessageAt: summary?.lastMessageCreatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            lastMessagePreview: preview.flatMap {
                ConversationWrites.previewText(text: $0.text, attachments: $0.attachments)
            },
            lastMessageSender: preview?.nickname,
            unreadCount: group.unreadCount ?? 0,
            lastReadMessageID: group.lastReadMessageId,
            mutedUntil: group.mutedUntil.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            memberCount: group.membersCount ?? group.members?.count,
            messageEditPeriod: group.messageEditPeriod,
            messageDeletionPeriod: group.messageDeletionPeriod,
            isPlaceholder: false
        )
    }

    nonisolated static func row(from chat: Chat) -> ConversationRow {
        let last = chat.lastMessage
        return ConversationRow(
            id: .direct(otherUserID: chat.otherUser.id),
            name: chat.otherUser.name ?? "",
            avatarURL: chat.otherUser.avatarUrl,
            lastMessageID: last?.id,
            lastMessageAt: last.map { Date(timeIntervalSince1970: TimeInterval($0.createdAt)) },
            lastMessagePreview: last.flatMap {
                ConversationWrites.previewText(text: $0.text, attachments: $0.attachments)
            },
            lastMessageSender: last?.name,
            unreadCount: chat.unreadCount ?? 0,
            lastReadMessageID: chat.lastReadMessageId,
            mutedUntil: nil,
            memberCount: 2,
            // `/v3/chats` reports no edit or deletion window for a DM.
            messageEditPeriod: nil,
            messageDeletionPeriod: nil,
            isPlaceholder: false
        )
    }
}

// MARK: - Shared writes

/// The two writes every store needs to make against `conversations`.
///
/// They live here rather than on `ConversationStore` because `MessageStore`
/// needs them too, and an actor cannot call into another actor without
/// suspending. Passing the caller's own connection keeps both inside one
/// transaction.
nonisolated enum ConversationWrites {
    /// Inserts a placeholder row so a message has something to hang off. Does
    /// nothing when the conversation is already known.
    static func ensureExists(_ conversation: ConversationID, in db: Database) throws {
        try db.run(
            """
            INSERT INTO conversations (key, kind, remote_id, placeholder)
            VALUES (?, ?, ?, 1)
            ON CONFLICT(key) DO NOTHING
            """,
            [
                SQLValue(conversation.storageKey),
                SQLValue(conversation.storageKind),
                SQLValue(conversation.remoteID),
            ]
        )
    }

    /// Points the list row at `message`, unless it already points at something
    /// newer. Ordering is by sort key, so an out-of-order push cannot rewind it.
    static func applyLatest(_ message: Message, _ conversation: ConversationID, in db: Database) throws {
        try db.run(
            """
            UPDATE conversations
               SET last_message_id = ?2,
                   last_message_sort = ?3,
                   last_message_at = ?4,
                   last_message_preview = ?5,
                   last_message_sender = ?6
             WHERE key = ?1 AND ?3 >= last_message_sort
            """,
            [
                SQLValue(conversation.storageKey),
                SQLValue(message.id),
                SQLValue(MessageSortKey.value(for: message.id)),
                SQLValue(message.createdAt),
                SQLValue(previewText(text: message.text, attachments: message.attachments)),
                SQLValue(message.name),
            ]
        )
    }

    /// One line of list-cell text. An image-only message still has to say
    /// something, so attachments get a noun.
    static func previewText(text: String?, attachments: [Message.Attachment]?) -> String? {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        guard let type = attachments?.first(where: { $0.type != nil && $0.type != "mentions" && $0.type != "reply" })?.type
        else { return text }
        switch type {
        case "image": return "Photo"
        case "video": return "Video"
        case "audio": return "Voice message"
        case "file": return "File"
        case "location": return "Location"
        case "emoji": return "Sticker"
        case "poll": return "Poll"
        case "event": return "Event"
        default: return text
        }
    }
}
