import Foundation

/// The GroupMe REST surface, typed.
///
/// One method per thing the app actually does, decoding straight into the Core
/// models. Every quirk that would otherwise leak into call sites lives here:
/// the `omit=memberships` default, `acceptFiles`, the 200-message cap, the
/// `after_id`/`since_id` trap, the 409-means-success rule on sends, and the
/// fact that groups and DMs are two endpoints wearing one costume.
///
/// Callers pass a `ConversationID` and never branch on its kind.
actor GroupMeAPI {
    private let client: APIClient

    /// Needed only to build DM conversation ids for the `/messages/{convId}/…`
    /// and `/read_receipts/{convId}` routes. Resolved lazily and cached, so a
    /// client that only ever touches groups never spends a request on it.
    private var currentUserID: String?

    init(client: APIClient, currentUserID: String? = nil) {
        self.client = client
        self.currentUserID = currentUserID
    }

    /// Seed the cached user id from local storage at launch, so the first DM
    /// action after a cold start does not wait on `/users/me`.
    func adopt(currentUserID id: String) {
        self.currentUserID = id
    }

    // MARK: - Identity

    /// `GET /v3/users/me`. Also refreshes the cached user id.
    @discardableResult
    func me() async throws -> CurrentUser {
        let user: CurrentUser = try await client.get(.v3, "/users/me")
        currentUserID = user.id
        return user
    }

    // MARK: - Conversation lists

    /// `GET /v3/groups`, always with `omit=memberships`.
    ///
    /// A group's member list runs to hundreds of entries and is useless in a
    /// list view, so it is never worth the bytes here. Fetch members with
    /// ``group(id:)`` when someone opens a conversation.
    ///
    /// Offset-paged: keep asking until a short page comes back.
    func groups(page: Int = 1, perPage: Int = 100) async throws -> [Group] {
        try await client.get(.v3, "/groups", query: [
            "page": String(page),
            "per_page": String(perPage),
            "omit": "memberships",
        ])
    }

    /// `GET /v3/chats`. Offset-paged, same as ``groups(page:perPage:)``.
    func chats(page: Int = 1, perPage: Int = 100) async throws -> [Chat] {
        try await client.get(.v3, "/chats", query: [
            "page": String(page),
            "per_page": String(perPage),
        ])
    }

    /// `GET /v3/groups/{id}`.
    ///
    /// A plain read already includes members, `unread_count`,
    /// `last_read_message_id` and `last_read_at`; `include=` adds nothing on
    /// this route, so it is not sent.
    func group(id: String) async throws -> Group {
        try await client.get(.v3, "/groups/\(id)")
    }

    // MARK: - Message history

    /// The real server cap on `limit`. Asking for 500 earns a 400 that says so.
    static let maxMessagesPerPage = 200

    /// Read history for either kind of conversation.
    ///
    /// - Parameters:
    ///   - conversation: group or DM. The route asymmetry is handled here.
    ///   - before: page backwards from this message id, newest first.
    ///   - after: page **forwards** from this message id, gap-free.
    ///   - limit: capped at 200, which is the server's real limit.
    ///
    /// Returns messages in ascending id order regardless of which direction was
    /// requested, because the server's ordering depends on the anchor and no
    /// caller benefits from knowing that.
    ///
    /// `since_id` is deliberately unreachable from here. It looks like a
    /// catch-up parameter and is not: it returns the *newest* messages and
    /// silently skips everything between them and your anchor. `after_id` is
    /// the one that pages forward without losing the gap.
    func messages(
        in conversation: ConversationID,
        before: String? = nil,
        after: String? = nil,
        limit: Int = GroupMeAPI.maxMessagesPerPage,
        retry: RetryPolicy = .interactive
    ) async throws -> [Message] {
        var query: [String: String?] = [
            "limit": String(min(max(limit, 1), Self.maxMessagesPerPage)),
            // Not optional in practice: omit it and document attachments are
            // silently stripped from the response.
            "acceptFiles": "true",
            "before_id": before,
            "after_id": after,
        ]

        let page: [Message]
        switch conversation {
        case .group(let groupID):
            let response: GroupMessagesPage = try await client.get(
                .v3, "/groups/\(groupID)/messages", query: query, retry: retry)
            page = response.messages ?? []
        case .direct(let otherUserID):
            query["other_user_id"] = .some(otherUserID)
            let response: DirectMessagesPage = try await client.get(
                .v3, "/direct_messages", query: query, retry: retry)
            page = response.directMessages ?? []
        }
        return page.sorted { Message.isNewer($1.id, than: $0.id) }
    }

    // MARK: - Sending

    /// What a send call learned.
    nonisolated enum SendOutcome: Sendable {
        /// The server accepted this `source_guid` for the first time and
        /// returned the stored message, server id and all.
        case sent(Message)
        /// HTTP 409: this `source_guid` was accepted by an earlier attempt.
        ///
        /// This is a success. It is the guarantee the whole outbox rests on:
        /// persist the guid before the request goes out and a retry can never
        /// duplicate the message. The body carries no message, so the server
        /// id has to come from a resync of the conversation.
        case alreadyAccepted
    }

    /// Send to either kind of conversation.
    ///
    /// - Parameter sourceGuid: the idempotency key. Persist it *before*
    ///   calling, and reuse the same one on every retry of the same message.
    ///
    /// Defaults to the patient retry policy, because the 409 rule makes
    /// retrying a send strictly safe.
    func send(
        text: String?,
        attachments: [Message.Attachment] = [],
        to conversation: ConversationID,
        sourceGuid: String,
        retry: RetryPolicy = .background
    ) async throws -> SendOutcome {
        let host = APIClient.Host.v3
        let path: String
        let recipientID: String?
        switch conversation {
        case .group(let groupID):
            path = "/groups/\(groupID)/messages"
            recipientID = nil
        case .direct(let otherUserID):
            // The DM route takes no id in the path.
            path = "/direct_messages"
            recipientID = otherUserID
        }

        let body = SendMessageBody(message: .init(
            sourceGuid: sourceGuid,
            text: text,
            recipientId: recipientID,
            attachments: attachments))

        do {
            switch conversation {
            case .group:
                let sent: SentGroupMessage = try await client.post(
                    host, path, body: body, retry: retry)
                return .sent(sent.message)
            case .direct:
                let sent: SentDirectMessage = try await client.post(
                    host, path, body: body, retry: retry)
                return .sent(sent.directMessage)
            }
        } catch let error as APIError where error.status == 409 {
            return .alreadyAccepted
        }
    }

    // MARK: - Likes

    /// A reaction. Plain likes send no body at all; `unicode` and legacy
    /// `emoji` packs both ride the same `like` route.
    nonisolated struct LikeIcon: Encodable, Sendable {
        var type: String
        var code: String?
        var packId: Int?
        var packIndex: Int?

        static func unicode(_ code: String) -> LikeIcon { LikeIcon(type: "unicode", code: code) }
        static func emoji(packId: Int, packIndex: Int) -> LikeIcon {
            LikeIcon(type: "emoji", packId: packId, packIndex: packIndex)
        }
    }

    private nonisolated struct LikeBody: Encodable, Sendable {
        var likeIcon: LikeIcon
    }

    /// `POST /v3/messages/{conversationId}/{messageId}/like`.
    ///
    /// Pass a `LikeIcon` for a reaction; omit it for a plain like.
    func like(
        message messageID: String,
        in conversation: ConversationID,
        icon: LikeIcon? = nil
    ) async throws {
        let convID = try await restID(for: conversation)
        let path = "/messages/\(convID)/\(messageID)/like"
        if let icon {
            try await client.postIgnoringResponse(.v3, path, body: LikeBody(likeIcon: icon))
        } else {
            try await client.postIgnoringResponse(.v3, path, body: Optional<Empty>.none)
        }
    }

    /// `POST /v3/messages/{conversationId}/{messageId}/unlike`. Never carries a body.
    func unlike(message messageID: String, in conversation: ConversationID) async throws {
        let convID = try await restID(for: conversation)
        try await client.postIgnoringResponse(
            .v3, "/messages/\(convID)/\(messageID)/unlike", body: Optional<Empty>.none)
    }

    // MARK: - Read receipts

    /// One conversation's read cursor. Serves as both the response row from
    /// `GET /v4/read_receipts` and the request row for the batch POST, because
    /// the server uses the same two fields for both.
    nonisolated struct ReadReceipt: Codable, Hashable, Sendable {
        var conversationId: String
        var lastReadMessageId: String?
    }

    /// `POST /v4/read_receipts/{conversationId}`.
    ///
    /// The server rate-limits these hard enough that the official app drains
    /// them from a dirty-flag queue. Prefer ``markRead(_:)`` when more than one
    /// conversation is dirty, and use the one-shot policy here: a stale read
    /// cursor is not worth a retry storm.
    func markRead(
        conversation: ConversationID,
        messageId: String,
        retry: RetryPolicy = .none
    ) async throws {
        let convID = try await restID(for: conversation)
        try await client.postIgnoringResponse(
            .v4, "/read_receipts/\(convID)",
            body: ReadCursorBody(lastReadMessageId: messageId),
            retry: retry)
    }

    /// `POST /v4/read_receipts`, the batch form. One request for every
    /// conversation whose cursor moved while the app was busy.
    func markRead(_ receipts: [ReadReceipt], retry: RetryPolicy = .none) async throws {
        guard !receipts.isEmpty else { return }
        try await client.postIgnoringResponse(
            .v4, "/read_receipts", body: BatchReadCursorBody(receipts: receipts), retry: retry)
    }

    /// `GET /v4/read_receipts`. Every conversation's read cursor in one call,
    /// which is how a cold start learns what is unread without touching each
    /// conversation.
    func readReceipts() async throws -> [ReadReceipt] {
        let page: ReadReceiptsPage = try await client.get(.v4, "/read_receipts")
        return page.receipts ?? []
    }

    // MARK: - Helpers

    /// The id GroupMe wants in `/messages/{id}/…` and `/read_receipts/{id}`.
    ///
    /// Groups are just their own id, so this never hits the network for one.
    /// DMs need both user ids joined with `+`, so the first DM action on a cold
    /// start may resolve `/users/me` once and cache it.
    private func restID(for conversation: ConversationID) async throws -> String {
        if case .group(let id) = conversation { return id }
        if let currentUserID { return conversation.restID(myUserID: currentUserID) }
        let user = try await me()
        return conversation.restID(myUserID: user.id)
    }
}
