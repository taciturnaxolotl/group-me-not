import Foundation

// Wire models. Field names are GroupMe's, mapped from snake_case by the decoder.
// Timestamps are epoch *seconds*, not milliseconds.

nonisolated struct Message: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var sourceGuid: String?
    var createdAt: Int
    var userId: String?
    var senderId: String?
    var name: String?
    var avatarUrl: String?
    var senderType: String?
    var text: String?
    var system: Bool?
    var favoritedBy: [String]?
    var reactions: [Reaction]?
    var attachments: [Attachment]?
    var groupId: String?
    var chatId: String?
    var recipientId: String?
    var parentId: String?
    var pinnedAt: Int?
    var pinnedBy: String?
    var deletedAt: Int?
    var deletionActor: String?
    var updatedAt: Int?
    var event: SystemEvent?

    var date: Date { Date(timeIntervalSince1970: TimeInterval(createdAt)) }
    var isSystem: Bool { system == true }
    var isDeleted: Bool { (deletedAt ?? 0) > 0 }
    var likeCount: Int { favoritedBy?.count ?? 0 }

    /// The one list a bubble draws.
    ///
    /// A plain like and a `❤️` reaction are the same thing to a reader, so they
    /// share a bucket: `favorited_by` is folded into the heart and the two user
    /// lists are merged, the plain likers first. Everything else keeps the
    /// order the server sent, which is the order the reactions were first used.
    ///
    /// Reactions we cannot draw (legacy powerup packs, whose art lives behind a
    /// CDN we do not talk to) are dropped rather than rendered as a blank.
    func reactionSummaries(currentUserID: String?) -> [ReactionSummary] {
        let likers = favoritedBy ?? []
        var order: [String] = likers.isEmpty ? [] : [ReactionSummary.heart]
        var buckets: [String: [String]] = likers.isEmpty ? [:] : [ReactionSummary.heart: likers]

        for reaction in reactions ?? [] {
            guard let glyph = reaction.glyph, let users = reaction.userIds, !users.isEmpty
            else { continue }
            if buckets[glyph] == nil { order.append(glyph) }
            var merged = buckets[glyph] ?? []
            let known = Set(merged)
            merged.append(contentsOf: users.filter { !known.contains($0) })
            buckets[glyph] = merged
        }

        return order.compactMap { glyph in
            guard let users = buckets[glyph], !users.isEmpty else { return nil }
            return ReactionSummary(
                glyph: glyph,
                userIDs: users,
                reactedByMe: currentUserID.map(users.contains) ?? false)
        }
    }

    /// The glyph this user currently holds on this message, if any.
    ///
    /// GroupMe stores one reaction per person per message, so this is a single
    /// value and not a set. Used to decide whether a tap adds, swaps, or clears.
    func reaction(by userID: String) -> String? {
        reactionSummaries(currentUserID: userID).first { $0.reactedByMe }?.glyph
    }

    /// This message with `userID`'s reaction set to `glyph`, or cleared when
    /// `glyph` is nil. Whatever they held before goes first, because GroupMe
    /// allows one reaction per person per message.
    ///
    /// The single definition of that rule. ``AppModel`` applies it to the
    /// published array before it suspends, so a tapback draws on the next
    /// frame, and ``MessageStore/setReaction(_:by:onMessage:in:)`` applies the
    /// same function to the stored copy inside its transaction. One rule, two
    /// callers, no chance of them drifting apart.
    func settingReaction(_ glyph: String?, by userID: String) -> Message {
        var copy = self

        copy.favoritedBy = copy.favoritedBy?.filter { $0 != userID }
        copy.reactions = copy.reactions?.compactMap { reaction in
            guard let users = reaction.userIds, users.contains(userID) else { return reaction }
            var updated = reaction
            updated.userIds = users.filter { $0 != userID }
            return (updated.userIds?.isEmpty ?? true) ? nil : updated
        }

        switch glyph {
        case .none:
            break
        // The heart is a plain like on the wire, so it goes where a like goes.
        case .some(ReactionSummary.heart):
            copy.favoritedBy = (copy.favoritedBy ?? []) + [userID]
        case .some(let glyph):
            var reactions = copy.reactions ?? []
            if let index = reactions.firstIndex(where: { $0.glyph == glyph }) {
                reactions[index].userIds = (reactions[index].userIds ?? []) + [userID]
            } else {
                reactions.append(Reaction(type: "unicode", code: glyph, userIds: [userID]))
            }
            copy.reactions = reactions
        }
        return copy
    }

    /// True once the author has changed the text after posting.
    ///
    /// GroupMe stamps `updated_at` equal to `created_at` on a message nobody has
    /// touched, so the marker turns on strictly after, never on equality.
    var isEdited: Bool { (updatedAt ?? 0) > createdAt }

    /// This message with a later revision folded in, field by field.
    ///
    /// The reason to merge rather than replace: a `message.update` push carries
    /// the revised message, but nothing promises it carries *all* of it. A blind
    /// upsert of a thin edit payload would drop the likes, the reactions and the
    /// attachments we already hold, and REST catch-up could never put them back
    /// (`after_id` never revisits an id it has already passed). So anything the
    /// update leaves out is kept, and only what it states wins.
    ///
    /// `text` is the exception worth naming: an edit that clears the text sends
    /// an empty string, not a missing field, so an absent `text` really does mean
    /// "unchanged" here.
    func merging(_ update: Message) -> Message {
        var copy = self
        copy.text = update.text ?? copy.text
        copy.updatedAt = update.updatedAt ?? copy.updatedAt
        copy.attachments = update.attachments ?? copy.attachments
        copy.favoritedBy = update.favoritedBy ?? copy.favoritedBy
        copy.reactions = update.reactions ?? copy.reactions
        copy.name = update.name ?? copy.name
        copy.avatarUrl = update.avatarUrl ?? copy.avatarUrl
        copy.senderId = update.senderId ?? copy.senderId
        copy.userId = update.userId ?? copy.userId
        copy.deletedAt = update.deletedAt ?? copy.deletedAt
        copy.deletionActor = update.deletionActor ?? copy.deletionActor
        copy.pinnedAt = update.pinnedAt ?? copy.pinnedAt
        copy.pinnedBy = update.pinnedBy ?? copy.pinnedBy
        copy.parentId = update.parentId ?? copy.parentId
        copy.event = update.event ?? copy.event
        return copy
    }

    /// This message with new text and a fresh revision stamp. Used for the
    /// optimistic local edit, before the server has said anything.
    func editing(text: String?, updatedAt: Int = Int(Date().timeIntervalSince1970)) -> Message {
        var copy = self
        copy.text = text
        copy.updatedAt = updatedAt
        return copy
    }

    /// The family of system event this message announces, for the transcript's
    /// run collapsing. Nil for anything that is not a system notice.
    var systemFamily: SystemMessageFamily? {
        guard isSystem else { return nil }
        return SystemMessageFamily(eventType: event?.type)
    }

    /// Message ids sort chronologically as big integers, never lexically.
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        if let a = UInt64(lhs), let b = UInt64(rhs) { return a > b }
        return lhs.count == rhs.count ? lhs > rhs : lhs.count > rhs.count
    }

    /// One reaction bucket as the server stores it.
    ///
    /// `type` is `unicode` for the modern set and `emoji` for the legacy
    /// powerup packs, which is why `code` and the pack coordinates are all
    /// optional: exactly one pair is ever filled in.
    nonisolated struct Reaction: Codable, Hashable, Sendable {
        var type: String?
        var code: String?
        var packId: Int?
        var packIndex: Int?
        var userIds: [String]?

        /// What to draw, or nil when the reaction is a pack sticker we have no
        /// art for.
        var glyph: String? {
            guard type == nil || type == "unicode" else { return nil }
            guard let code, !code.isEmpty else { return nil }
            return code
        }
    }

    /// A reaction bucket after plain likes have been folded in. This is the
    /// shape a bubble renders.
    nonisolated struct ReactionSummary: Identifiable, Hashable, Sendable {
        /// The bucket plain likes land in.
        static let heart = "\u{2764}\u{FE0F}"

        var glyph: String
        var userIDs: [String]
        var reactedByMe: Bool

        var id: String { glyph }
        var count: Int { userIDs.count }
    }

    nonisolated struct SystemEvent: Codable, Hashable, Sendable {
        var type: String?
    }

    nonisolated struct Attachment: Codable, Hashable, Sendable {
        var type: String?
        var url: String?
        var sourceUrl: String?
        var previewUrl: String?
        var blurHash: String?
        var fileId: String?
        var name: String?
        var lat: String?
        var lng: String?
        var replyId: String?
        var baseReplyId: String?
        var userIds: [String]?
        var loci: [[Int]]?
        var placeholder: String?
        var charmap: [[Int]]?
        var duration: Int?
        var pollId: String?
        var eventId: String?
    }
}

nonisolated struct Group: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var type: String?
    var description: String?
    var imageUrl: String?
    var creatorUserId: String?
    var createdAt: Int?
    var updatedAt: Int?
    var mutedUntil: Int?
    var unreadCount: Int?
    var lastReadMessageId: String?
    var lastReadAt: Int?
    var messages: MessagesSummary?
    var members: [Member]?
    var membersCount: Int?
    var parentId: String?
    var childrenCount: Int?

    /// How long after posting a message may still be edited, in seconds.
    ///
    /// Server-owned and per-group. The edit affordance honours it rather than
    /// offering an action that is going to be refused: `0` or absent means
    /// editing is off for this group.
    var messageEditPeriod: Int?
    /// The matching window for deletion, same rules.
    var messageDeletionPeriod: Int?

    /// Whether `message` is still inside this group's edit window.
    func canEdit(_ message: Message, now: Date = Date()) -> Bool {
        guard let period = messageEditPeriod, period > 0 else { return false }
        return now.timeIntervalSince(message.date) < TimeInterval(period)
    }

    nonisolated struct MessagesSummary: Codable, Hashable, Sendable {
        var count: Int?
        var lastMessageId: String?
        var lastMessageCreatedAt: Int?
        var lastMessageUpdatedAt: Int?
        var preview: Preview?

        nonisolated struct Preview: Codable, Hashable, Sendable {
            var nickname: String?
            var text: String?
            var imageUrl: String?
            var attachments: [Message.Attachment]?
        }
    }
}

nonisolated struct Member: Codable, Identifiable, Hashable, Sendable {
    var id: String?
    var userId: String?
    var nickname: String?
    var name: String?
    var imageUrl: String?
    var roles: [String]?

    var identity: String { userId ?? id ?? UUID().uuidString }
}

nonisolated struct Chat: Codable, Hashable, Sendable {
    var createdAt: Int?
    var updatedAt: Int?
    var lastMessage: Message?
    var messagesCount: Int?
    var unreadCount: Int?
    var lastReadMessageId: String?
    var lastReadAt: Int?
    var otherUser: OtherUser

    nonisolated struct OtherUser: Codable, Hashable, Sendable {
        var id: String
        var name: String?
        var avatarUrl: String?
    }
}

nonisolated struct CurrentUser: Codable, Hashable, Sendable {
    var id: String
    var name: String?
    var imageUrl: String?
    var email: String?
    var phoneNumber: String?
}
