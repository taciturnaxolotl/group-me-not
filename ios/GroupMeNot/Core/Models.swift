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

    /// Message ids sort chronologically as big integers, never lexically.
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        if let a = UInt64(lhs), let b = UInt64(rhs) { return a > b }
        return lhs.count == rhs.count ? lhs > rhs : lhs.count > rhs.count
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
