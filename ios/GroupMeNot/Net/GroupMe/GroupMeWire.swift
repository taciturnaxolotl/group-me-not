import Foundation

// Wire wrappers: the shapes GroupMe puts *inside* the `response` envelope.
//
// They exist only so `GroupMeAPI` can hand callers a plain `[Message]` or a
// `Message`. Nothing outside this directory should ever name one, hence
// `internal` rather than public API, and hence the deliberate duplication
// between the group and DM variants: the two routes really do disagree about
// the key, and pretending otherwise here would just move the branch somewhere
// worse.

/// `GET /v3/groups/{id}/messages`
nonisolated struct GroupMessagesPage: Decodable, Sendable {
    var count: Int?
    var messages: [Message]?
}

/// `GET /v3/direct_messages`
nonisolated struct DirectMessagesPage: Decodable, Sendable {
    var count: Int?
    var directMessages: [Message]?
}

/// `POST /v3/groups/{id}/messages`
nonisolated struct SentGroupMessage: Decodable, Sendable {
    var message: Message
}

/// `POST /v3/direct_messages`
nonisolated struct SentDirectMessage: Decodable, Sendable {
    var directMessage: Message
}

/// `GET /v4/read_receipts`
nonisolated struct ReadReceiptsPage: Decodable, Sendable {
    var receipts: [GroupMeAPI.ReadReceipt]?
}

// MARK: - Request bodies

/// Both send routes wrap their payload in a `message` key. The DM route carries
/// `recipient_id` inside that wrapper instead of taking an id in the path.
///
/// `ShareCardRequest` in the official app wraps DM bodies in `direct_message`
/// instead. That path is for Copilot cards; the normal composer sends `message`,
/// and so do we.
nonisolated struct SendMessageBody: Encodable, Sendable {
    var message: Payload

    nonisolated struct Payload: Encodable, Sendable {
        var sourceGuid: String
        var text: String?
        var recipientId: String?
        var attachments: [Message.Attachment]
    }
}

/// `POST /v4/read_receipts/{conversationId}`
nonisolated struct ReadCursorBody: Encodable, Sendable {
    var lastReadMessageId: String
}

/// `POST /v4/read_receipts`
nonisolated struct BatchReadCursorBody: Encodable, Sendable {
    var receipts: [GroupMeAPI.ReadReceipt]
}
