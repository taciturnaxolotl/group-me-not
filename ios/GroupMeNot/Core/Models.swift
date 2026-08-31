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

    /// Everyone who reacted at all, plain likers included, deduplicated.
    var reactionUserIDs: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for id in (favoritedBy ?? []) + (reactions ?? []).flatMap({ $0.userIds ?? [] })
        where seen.insert(id).inserted {
            ordered.append(id)
        }
        return ordered
    }

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

        var count: Int { userIds?.count ?? 0 }
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
