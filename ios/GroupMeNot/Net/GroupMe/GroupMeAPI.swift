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

    /// Our user id, if we already know it. Never asks the network: the media
    /// upload path wants it in a body and would rather fall back to the older
    /// endpoint than spend a round trip on it.
    func currentUser() -> String? { currentUserID }

    /// The `{a}+{b}` id the media and file services want in a header.
    ///
    /// The same value ``restID(for:)`` builds for the like and read-receipt
    /// routes, exposed because the upload service is outside this actor and the
    /// rule for joining two user ids should not be written twice.
    func conversationRestID(_ conversation: ConversationID) async throws -> String {
        try await restID(for: conversation)
    }

    // MARK: - Conversation lists

    /// What the two list routes ask to have included.
    ///
    /// Not optional. Both index endpoints leave `unread_count` out unless it is
    /// asked for, so without this every badge in the conversation list reads
    /// zero. The single-group read includes it either way, which is what makes
    /// the omission easy to miss.
    ///
    /// It goes through `repeating:` rather than the plain query dictionary
    /// because `include` is a key this API repeats: the group index sends
    /// `&include=visibility&include=locations`. Only one value is needed today,
    /// and spelling it in the shape that can hold several means adding the
    /// second one later is not a refactor.
    private static let listInclude = ["include": ["unread_count"]]

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
        ], repeating: Self.listInclude)
    }

    /// `GET /v3/chats`. Offset-paged, same as ``groups(page:perPage:)``.
    func chats(page: Int = 1, perPage: Int = 100) async throws -> [Chat] {
        try await client.get(.v3, "/chats", query: [
            "page": String(page),
            "per_page": String(perPage),
        ], repeating: Self.listInclude)
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
        do {
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
        } catch APIError.noContent {
            // "There are no messages in that range", which is the answer every
            // caller here is already prepared for. Paging forward stops; paging
            // back has reached the beginning. Neither is a failure, and treating
            // it as one is what left a freshly-emptied app with no history at
            // all: every conversation's first page threw before it stored a row.
            return []
        }
        return page.sorted { Message.isNewer($1.id, than: $0.id) }
    }

    // MARK: - Polls

    /// One poll, with what this account voted for.
    ///
    /// Polls live on their own routes rather than inside the message, so a
    /// message carrying `poll_id` is an invitation to fetch rather than the
    /// thing itself.
    func poll(_ pollID: String, in groupID: String) async -> PollBox? {
        let response: SinglePollResponse? = try? await client.get(
            .v3, "/poll/\(groupID)/\(pollID)", retry: .background)
        return response?.poll
    }

    /// Vote, change a vote, or withdraw one.
    ///
    /// Two routes, and which one depends on the poll rather than on how many
    /// options are being sent. A `single` poll takes the option in the path; a
    /// `multi` poll takes a `votes` array in the body and answers `500` to the
    /// per-option route. Both measured, including the body key, which the server
    /// named itself by refusing `option_ids` with `{"votes": "is required"}`.
    ///
    /// An empty array withdraws.
    @discardableResult
    func vote(
        _ optionIDs: [String], in pollID: String, groupID: String, multiple: Bool
    ) async -> PollBox? {
        if !multiple, let only = optionIDs.first, optionIDs.count == 1 {
            let response: SinglePollResponse? = try? await client.post(
                .v3, "/poll/\(groupID)/\(pollID)/\(only)",
                body: Optional<Discard>.none, retry: .interactive)
            return response?.poll
        }
        let response: SinglePollResponse? = try? await client.post(
            .v3, "/poll/\(groupID)/\(pollID)",
            body: MultiVote(votes: optionIDs), retry: .interactive)
        return response?.poll
    }

    private nonisolated struct MultiVote: Encodable, Sendable {
        var votes: [String]
    }

    // MARK: - Events

    /// One event.
    ///
    /// The conversation id here is the REST one — a group id, or two user ids
    /// joined with `+` for a DM — which is why it goes through `restID`.
    func event(_ eventID: String, in conversation: ConversationID) async -> GroupEvent? {
        guard let convID = try? await restID(for: conversation) else { return nil }
        let response: EventResponse? = try? await client.get(
            .v3, "/conversations/\(convID)/events/show",
            query: ["event_id": eventID], retry: .background)
        return response?.event
    }

    /// Say whether you are going.
    ///
    /// `going` is a query parameter rather than a body, and there are only two
    /// values: `true` and `false`. "Maybe" exists in the response as a third
    /// list but there is no way found to put yourself in it, and withdrawing
    /// entirely is a separate `DELETE` rather than a third value here.
    @discardableResult
    func rsvp(
        _ going: Bool, to eventID: String, in conversation: ConversationID
    ) async -> GroupEvent? {
        guard let convID = try? await restID(for: conversation) else { return nil }
        let response: EventResponse? = try? await client.post(
            .v3, "/conversations/\(convID)/events/rsvp",
            query: ["event_id": eventID, "going": going ? "true" : "false"],
            body: Optional<Discard>.none, retry: .interactive)
        return response?.event
    }

    // MARK: - Creating

    /// Start a poll.
    ///
    /// `expiration` is epoch seconds and there is a minimum: ten minutes was
    /// refused with `400` and an hour accepted, so callers should not offer
    /// anything shorter than an hour without checking.
    @discardableResult
    func createPoll(
        in groupID: String, subject: String, options: [String],
        expiresAt: Date, allowsMultiple: Bool, anonymous: Bool
    ) async throws -> Poll? {
        let response: SinglePollResponse? = try await client.post(
            .v3, "/poll/\(groupID)",
            body: NewPoll(
                subject: subject,
                options: options.map { NewPoll.Option(title: $0) },
                expiration: Int(expiresAt.timeIntervalSince1970),
                type: allowsMultiple ? "multi" : "single",
                visibility: anonymous ? "anonymous" : "public"),
            retry: .interactive)
        return response?.poll?.data
    }

    private nonisolated struct NewPoll: Encodable, Sendable {
        var subject: String
        var options: [Option]
        var expiration: Int
        var type: String
        var visibility: String

        nonisolated struct Option: Encodable, Sendable {
            var title: String
        }
    }

    /// Create an event.
    ///
    /// `start_at`, `end_at`, `timezone` and `is_all_day` must be sent together
    /// — omitting the timezone earns a `400` saying exactly that — and the
    /// timestamps are ISO 8601 strings rather than the epoch seconds used
    /// everywhere else in this API.
    @discardableResult
    func createEvent(
        in conversation: ConversationID, name: String, description: String?,
        location: String?, startAt: Date, endAt: Date, isAllDay: Bool
    ) async throws -> GroupEvent? {
        let convID = try await restID(for: conversation)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let response: EventResponse? = try await client.post(
            .v3, "/conversations/\(convID)/events/create",
            body: NewEvent(
                name: name,
                description: description,
                location: location.map { NewEvent.Place(name: $0) },
                startAt: formatter.string(from: startAt),
                endAt: formatter.string(from: endAt),
                timezone: TimeZone.current.identifier,
                isAllDay: isAllDay),
            retry: .interactive)
        return response?.event
    }

    private nonisolated struct NewEvent: Encodable, Sendable {
        var name: String
        var description: String?
        var location: Place?
        var startAt: String
        var endAt: String
        var timezone: String
        var isAllDay: Bool

        nonisolated struct Place: Encodable, Sendable {
            var name: String
        }
    }

    /// Start a group.
    ///
    /// `POST /v3/groups` is GroupMe's long-standing public route for this. It is
    /// **not** in the extracted client reference, which only carries the
    /// subgroup and destroy routes, so this one is documentation rather than
    /// measurement — the only untested call in this file.
    @discardableResult
    func createGroup(name: String, description: String?, imageURL: String?) async throws -> Group? {
        let response: Group = try await client.post(
            .v3, "/groups",
            body: NewGroup(name: name, description: description, imageUrl: imageURL, share: true),
            retry: .interactive)
        return response
    }

    private nonisolated struct NewGroup: Encodable, Sendable {
        var name: String
        var description: String?
        var imageUrl: String?
        /// Asks the server for a join link, which the share sheet then has.
        var share: Bool
    }

    /// Join a group with a share token, which is what a `join_group` link is.
    ///
    /// `POST /v3/groups/{id}/join/{token}` answers with the group wrapped in one
    /// more layer than every other route here: `{"response": {"group": {…}}}`.
    /// Joining something already joined is not an error, it just answers with
    /// the group again, which is what makes the button safe to press twice.
    func joinGroup(_ groupID: String, shareToken: String) async throws -> Group? {
        let joined: Joined = try await client.post(
            .v3, "/groups/\(groupID)/join/\(shareToken)",
            body: Optional<Discard>.none, retry: .interactive)
        return joined.group
    }

    private nonisolated struct Joined: Decodable, Sendable {
        var group: Group?
    }

    /// Accept or decline a message request from somebody not in your contacts.
    func respondToChatRequest(_ accept: Bool, from otherUserID: String) async throws {
        if accept {
            try await client.postIgnoringResponse(
                .v3, "/chats/\(otherUserID)/approve",
                body: Optional<Discard>.none, retry: .interactive)
        } else {
            // Declining is deleting the conversation, which is what the route
            // for it does: there is no "reject" verb.
            try await client.deleteIgnoringResponse(
                .v3, "/chats/\(otherUserID)", retry: .interactive)
        }
    }

    // MARK: - Requests

    /// Everything waiting on a decision: message requests and group invitations.
    func pendingRequests() async throws -> PendingRequests {
        do {
            return try await client.get(.v4, "/requests", retry: .background)
        } catch APIError.noContent {
            return PendingRequests()
        }
    }

    /// People asking to join one group. Admins and the owner only.
    func pendingMemberships(in groupID: String) async throws -> [JoinRequest] {
        do {
            return try await client.get(
                .v3, "/groups/\(groupID)/pending_memberships", retry: .background)
        } catch APIError.noContent {
            return []
        }
    }

    /// Let somebody in, or turn them away.
    ///
    /// Addressed by *membership* id rather than user id; see
    /// ``JoinRequest/approvalID``.
    func respond(
        toMembership membershipID: String, in groupID: String, approve: Bool
    ) async throws {
        try await client.postIgnoringResponse(
            .v3, "/groups/\(groupID)/members/\(membershipID)/approval",
            body: Approval(approval: approve), retry: .interactive)
    }

    private nonisolated struct Approval: Encodable, Sendable {
        var approval: Bool
    }

    // MARK: - Muting

    /// Mute or unmute, on the server rather than only on this phone.
    ///
    /// Three things about these routes are worth stating, because none of them
    /// match the surrounding API:
    ///
    /// - A group is muted on the **legacy host**, `v2.groupme.com`, not on
    ///   `api.groupme.com`. A topic is muted on v3. Same body, different hosts.
    /// - The verb is in the path rather than the body: `…/mute` and
    ///   `…/unmute` are two routes, not one route with a flag.
    /// - `duration` is minutes, and its absence means forever.
    func setMuted(
        _ muted: Bool, conversation: ConversationID, parentGroupID: String?,
        minutes: Int? = nil
    ) async throws {
        guard case .group(let id) = conversation else {
            // DMs have no mute route in this API. The caller keeps its local
            // preference, which is all there has ever been for them.
            throw APIError.http(status: 404, meta: nil, retryAfter: nil)
        }
        let verb = muted ? "mute" : "unmute"
        let body = MuteRequest(duration: minutes, recapEnabled: nil)

        if let parentGroupID {
            try await client.postIgnoringResponse(
                .v3, "/groups/\(parentGroupID)/subgroups/\(id)/\(verb)",
                body: body, retry: .interactive)
        } else {
            try await client.postIgnoringResponse(
                .legacy, "/groups/\(id)/memberships/\(verb)",
                body: body, retry: .interactive)
        }
    }

    private nonisolated struct MuteRequest: Encodable, Sendable {
        var duration: Int?
        var recapEnabled: Bool?
    }

    // MARK: - Pinned messages

    /// The messages pinned in a conversation.
    func pinnedMessages(in conversation: ConversationID) async -> [Message] {
        do {
            switch conversation {
            case .group(let groupID):
                let page: GroupMessagesPage = try await client.get(
                    .v3, "/pinned/groups/\(groupID)/messages", retry: .background)
                return page.messages ?? []
            case .direct(let otherUserID):
                let page: DirectMessagesPage = try await client.get(
                    .v3, "/pinned/direct_messages",
                    query: ["other_user_id": otherUserID], retry: .background)
                return page.directMessages ?? []
            }
        } catch {
            return []
        }
    }

    func setPinned(
        _ pinned: Bool, message messageID: String, in conversation: ConversationID
    ) async throws {
        let convID = try await restID(for: conversation)
        try await client.postIgnoringResponse(
            .v3, "/conversations/\(convID)/messages/\(messageID)/\(pinned ? "pin" : "unpin")",
            body: Optional<Discard>.none, retry: .interactive)
    }

    // MARK: - Membership

    /// Leave a group by removing your own membership.
    ///
    /// Addressed by *membership* id, which is not the user id. `destroy` is the
    /// other thing that could be meant by "leave" and is not this: it deletes
    /// the group for everybody and only the owner may do it.
    func leaveGroup(_ groupID: String, membershipID: String) async throws {
        try await client.postIgnoringResponse(
            .v3, "/groups/\(groupID)/members/\(membershipID)/remove",
            body: Optional<Discard>.none, retry: .interactive)
    }

    /// Delete a group outright. Owner only, and there is no undoing it.
    func destroyGroup(_ groupID: String) async throws {
        try await client.postIgnoringResponse(
            .v3, "/groups/\(groupID)/destroy",
            body: Optional<Discard>.none, retry: .interactive)
    }

    func removeMember(_ membershipID: String, from groupID: String) async throws {
        try await client.postIgnoringResponse(
            .v3, "/groups/\(groupID)/members/\(membershipID)/remove",
            body: Optional<Discard>.none, retry: .interactive)
    }

    /// Promote to admin, or demote back to a plain member.
    func setRole(_ role: String, for membershipID: String, in groupID: String) async throws {
        try await client.postIgnoringResponse(
            .v3, "/groups/\(groupID)/members/\(membershipID)/update",
            body: RoleUpdate(role: role), retry: .interactive)
    }

    private nonisolated struct RoleUpdate: Encodable, Sendable {
        var role: String
    }

    // MARK: - Group settings

    /// Change how you appear in one group.
    ///
    /// Per-group, which is the point: GroupMe lets the same person be "Kieran"
    /// in one place and "K" in another, and this is the route that does it.
    /// Nothing about the account changes.
    func updateMembership(
        in groupID: String, nickname: String? = nil, avatarURL: String? = nil
    ) async throws {
        var fields: [String: String] = [:]
        if let nickname { fields["nickname"] = nickname }
        if let avatarURL { fields["avatar_url"] = avatarURL }
        guard !fields.isEmpty else { return }
        try await client.postIgnoringResponse(
            .v3, "/groups/\(groupID)/memberships/update",
            body: MembershipUpdate(membership: fields), retry: .interactive)
    }

    private nonisolated struct MembershipUpdate: Encodable, Sendable {
        var membership: [String: String]
    }

    /// Change the group itself. Admins and the owner only, which the server
    /// enforces and the UI should not offer past.
    ///
    /// Only the fields passed are sent. GroupMe's update route replaces what it
    /// is given, so sending a whole group back is how a description somebody
    /// else wrote a minute ago gets overwritten with the copy this device
    /// happened to be holding.
    @discardableResult
    func updateGroup(
        _ groupID: String,
        name: String? = nil,
        description: String? = nil,
        imageURL: String? = nil,
        requiresApproval: Bool? = nil
    ) async throws -> Group? {
        var body: [String: AnyEncodable] = [:]
        if let name { body["name"] = AnyEncodable(name) }
        if let description { body["description"] = AnyEncodable(description) }
        if let imageURL { body["image_url"] = AnyEncodable(imageURL) }
        if let requiresApproval { body["requires_approval"] = AnyEncodable(requiresApproval) }
        guard !body.isEmpty else { return nil }

        try await client.postIgnoringResponse(
            .v3, "/groups/\(groupID)/update", body: body, retry: .interactive)
        return try? await group(id: groupID)
    }

    // MARK: - Profile

    /// Change the parts of your own profile GroupMe lets you change.
    ///
    /// On the legacy host, and shaped `{ "user": { … } }`, which is the only
    /// update route the official client uses: there is no `/v3/users/update`.
    /// Only the fields passed are sent, so a caller changing a bio cannot
    /// accidentally blank a name it did not look at.
    func updateProfile(
        name: String? = nil, bio: String? = nil, avatarURL: String? = nil,
        zipCode: String? = nil
    ) async throws -> CurrentUser? {
        let id: String
        if let known = currentUserID {
            id = known
        } else {
            id = try await me().id
        }
        var fields: [String: String] = [:]
        if let name { fields["name"] = name }
        if let bio { fields["bio"] = bio }
        if let avatarURL { fields["avatar_url"] = avatarURL }
        if let zipCode { fields["zip_code"] = zipCode }
        guard !fields.isEmpty else { return nil }

        try await client.postIgnoringResponse(
            .legacy, "/users/\(id)", body: ProfileUpdate(user: fields), retry: .interactive)
        // The response shape is not documented, so the truth comes from asking
        // again rather than from parsing a guess.
        return try? await me()
    }

    private nonisolated struct ProfileUpdate: Encodable, Sendable {
        var user: [String: String]
    }

    /// The one account-level preference the client exposes.
    func setFriendSuggestable(_ suggestable: Bool) async throws {
        try await client.postIgnoringResponse(
            .v3, "/users/me/settings",
            body: FriendSuggestable(friendSuggestable: suggestable), retry: .interactive)
    }

    private nonisolated struct FriendSuggestable: Encodable, Sendable {
        var friendSuggestable: Bool
    }

    /// This account's contacts.
    ///
    /// Blocked people are asked for and then dropped rather than left to the
    /// server's default, because the default has changed between clients and an
    /// invite list is the last place a blocked contact should turn up.
    func relationships() async throws -> [Relationship] {
        do {
            let people: [Relationship] = try await client.get(
                .v4, "/relationships",
                query: ["include_blocked": "true"], retry: .background)
            return people.filter { $0.blocked != true && $0.userId != nil }
        } catch APIError.noContent {
            return []
        }
    }

    /// Invite people to a group.
    ///
    /// Answers with a result id rather than a result: the server queues the
    /// additions and the caller is expected to poll
    /// `/v4/groups/{id}/members/results/{resultId}`. Nothing here polls, and
    /// that is deliberate — the membership shows up in the next roster fetch,
    /// which happens on the next open, and inventing a progress screen for it
    /// would be inventing a wait the user does not have.
    func addMembers(_ people: [AddMemberRequest.Person], to groupID: String) async throws {
        guard !people.isEmpty else { return }
        try await client.postIgnoringResponse(
            .v3, "/groups/\(groupID)/members/add",
            body: AddMemberRequest(members: people), retry: .interactive)
    }

    nonisolated struct AddMemberRequest: Encodable, Sendable {
        var members: [Person]

        nonisolated struct Person: Encodable, Sendable {
            var userId: String
            /// Required by the endpoint. The person's own name is the only
            /// honest default; a group can rename them afterwards.
            var nickname: String
        }
    }

    /// Change a topic.
    ///
    /// A separate route from `groups/{id}/update`, and it has to be: a topic is
    /// not a group, and addressing the group route with a topic id is a 404.
    /// `topic` is the name field — there is no `name` on a subgroup.
    func updateSubgroup(
        _ topicID: String, in parentGroupID: String,
        topic: String? = nil, description: String? = nil,
        type: String? = nil, avatarURL: String? = nil
    ) async throws {
        var body: [String: AnyEncodable] = [:]
        if let topic { body["topic"] = AnyEncodable(topic) }
        if let description { body["description"] = AnyEncodable(description) }
        if let type { body["group_type"] = AnyEncodable(type) }
        if let avatarURL { body["avatar_url"] = AnyEncodable(avatarURL) }
        guard !body.isEmpty else { return }
        try await client.putIgnoringResponse(
            .v3, "/groups/\(parentGroupID)/subgroups/\(topicID)",
            body: body, retry: .interactive)
    }

    /// Delete a topic.
    ///
    /// `DELETE` on the same path that reads and updates one. Not to be confused
    /// with `groups/{id}/destroy`, which ends the whole group; this removes one
    /// room and leaves the rest standing.
    func deleteSubgroup(_ topicID: String, in parentGroupID: String) async throws {
        try await client.deleteIgnoringResponse(
            .v3, "/groups/\(parentGroupID)/subgroups/\(topicID)", retry: .interactive)
    }

    /// Start a topic inside a group.
    ///
    /// `group_type` is the posting rule: `announcement` for admins only,
    /// `private` for everybody in the parent.
    @discardableResult
    func createSubgroup(
        in parentGroupID: String, topic: String, description: String?, announcementOnly: Bool
    ) async throws -> Subgroup? {
        let response: Subgroup? = try? await client.post(
            .v3, "/groups/\(parentGroupID)/subgroups",
            body: NewSubgroup(
                topic: topic,
                description: description,
                groupType: announcementOnly ? "announcement" : "private"),
            retry: .interactive)
        return response
    }

    private nonisolated struct NewSubgroup: Encodable, Sendable {
        var topic: String
        var description: String?
        var groupType: String
    }

    /// The topics inside a group.
    ///
    /// The only way to see them. Subgroups never appear in `GET /v3/groups`, and
    /// `GET /v3/groups/{subgroupID}` answers 404, so a client that does not make
    /// this call is a client for which six of this group's conversations simply
    /// do not exist. Their messages, once you have the ids, are read and written
    /// at the ordinary group routes.
    func subgroups(of groupID: String) async throws -> [Subgroup] {
        do {
            let response: [Subgroup] = try await client.get(
                .v3, "/groups/\(groupID)/subgroups",
                query: ["include": "unread_count"], retry: .background)
            return response
        } catch APIError.noContent {
            return []
        }
    }

    // MARK: - Presence

    /// What somebody's status is right now.
    ///
    /// `retry: .background` on purpose. Nobody is waiting on this and a status
    /// that arrives late is a status that has changed anyway, so a failure is
    /// worth one quiet attempt and no more.
    func presence(of userID: String) async throws -> Presence {
        try await client.get(
            .v1, "/presence/users/\(userID)", enveloped: false, retry: .background)
    }

    /// Say where *we* are.
    ///
    /// The heartbeat sends `online` every few minutes while somebody is looking
    /// at the app, and `away` when they stop. A status the user picked is sent
    /// with `manual`, which is what stops the next heartbeat overwriting it.
    ///
    /// A 200 with an empty body is a yes, not a failure: this route answers with
    /// whatever it likes and the caller has nothing to read.
    func publishPresence(_ status: Presence.Status, manual: Bool = false) async throws {
        do {
            try await client.putIgnoringResponse(
                .v1, "/presence/status",
                body: PresenceUpdate(status: status.apiValue, manual: manual ? true : nil),
                retry: .background)
        } catch APIError.noContent {
            return
        }
    }

    /// One message by id, for a quote whose original is out of the loaded
    /// window.
    ///
    /// The group form is v4; the DM form is v3 and wants the other user as a
    /// query parameter. Returns nil rather than throwing when the server has
    /// nothing, because the only caller is decorating a quote and a missing
    /// original is a normal thing, not a failure.
    /// Works for a topic addressed by its own id, which is worth stating because
    /// the neighbouring routes do not: `GET /v3/groups/{topicID}` is a 404, and
    /// so is this route addressed to the topic's *parent*. Measured both ways.
    func message(id: String, in conversation: ConversationID) async throws -> Message? {
        do {
            switch conversation {
            case .group(let groupID):
                let response: SingleMessage = try await client.get(
                    .v4, "/groups/\(groupID)/messages/\(id)",
                    query: ["acceptFiles": "true"], retry: .background)
                return response.message
            case .direct(let otherUserID):
                let response: SingleMessage = try await client.get(
                    .v3, "/direct_messages/\(id)",
                    query: ["other_user_id": otherUserID, "acceptFiles": "true"],
                    retry: .background)
                return response.message ?? response.directMessage
            }
        } catch APIError.noContent {
            return nil
        } catch let error as APIError where error.status == 404 {
            // Deleted, or old enough to have been swept. Either way it is not
            // coming, and the caller draws "Original unavailable".
            return nil
        }
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

    // MARK: - Editing

    /// Rewrite a message that is already on the server.
    ///
    /// ```
    /// PUT /v4/groups/{groupId}/messages/{messageId}
    /// PUT /v4/direct_messages/{otherUserId}/messages/{messageId}
    /// ```
    ///
    /// Note the shape of the DM route: unlike sending, which takes no id in the
    /// path and names the recipient in the body, editing puts the *other user's*
    /// id in the path. And both are v4 while both send routes are v3. There is
    /// no rule to lean on; the branch lives here so no call site has to know.
    ///
    /// Two things a caller has to respect, because the server will not explain
    /// itself if they are ignored:
    ///
    /// - There is an edit window, `Group.messageEditPeriod`, and it is per group.
    ///   Past it the call is refused. Check ``ConversationRow/canEdit(_:now:)``
    ///   before offering the action rather than after.
    /// - An edit does not change the message's id, so no `after_id` catch-up will
    ///   ever show it to another client. Whoever is listening on Faye hears the
    ///   `message.update`; whoever is offline simply never learns. That is the
    ///   API's gap, not ours, but it is why the local copy is updated here and
    ///   now rather than waiting for a resync to confirm it.
    ///
    /// Retries default to none. A send is safe to repeat because `source_guid`
    /// dedupes it; an edit has no such key, and a second PUT of the same text is
    /// harmless but a second PUT racing a *later* edit is not.
    /// Remove one of our own messages.
    ///
    /// The server replaces it with a tombstone rather than erasing it: the id
    /// stays, `deleted_at` is set, and the next catch-up brings it back in that
    /// form. Which is why the local write is the same shape.
    func delete(message messageID: String, in conversation: ConversationID) async throws {
        let convID = try await restID(for: conversation)
        try await client.deleteIgnoringResponse(
            .v3, "/conversations/\(convID)/messages/\(messageID)", retry: .none)
    }

    func edit(
        message messageID: String,
        in conversation: ConversationID,
        text: String?,
        attachments: [Message.Attachment] = [],
        retry: RetryPolicy = .none
    ) async throws {
        let path: String
        switch conversation {
        case .group(let groupID):
            path = "/groups/\(groupID)/messages/\(messageID)"
        case .direct(let otherUserID):
            path = "/direct_messages/\(otherUserID)/messages/\(messageID)"
        }
        try await client.putIgnoringResponse(
            .v4, path,
            body: EditMessageBody(message: .init(text: text, attachments: attachments)),
            retry: retry)
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
        icon: LikeIcon? = nil,
        retry: RetryPolicy = .interactive
    ) async throws {
        let convID = try await restID(for: conversation)
        let path = "/messages/\(convID)/\(messageID)/like"
        if let icon {
            try await client.postIgnoringResponse(
                .v3, path, body: LikeBody(likeIcon: icon), retry: retry)
        } else {
            try await client.postIgnoringResponse(
                .v3, path, body: Optional<Empty>.none, retry: retry)
        }
    }

    /// `POST /v3/messages/{conversationId}/{messageId}/unlike`. Never carries a body.
    func unlike(
        message messageID: String,
        in conversation: ConversationID,
        retry: RetryPolicy = .interactive
    ) async throws {
        let convID = try await restID(for: conversation)
        try await client.postIgnoringResponse(
            .v3, "/messages/\(convID)/\(messageID)/unlike",
            body: Optional<Empty>.none, retry: retry)
    }

    /// Put this user's reaction on a message into an exact state.
    ///
    /// A person holds at most one reaction per message, so changing glyph is
    /// two calls: drop the old one, then add the new. Pass `nil` for `glyph` to
    /// clear. Deciding that tapping your own glyph means "clear" is the UI's
    /// call, not this one's; this method sets what it is told.
    ///
    /// The unlike runs first and its result is honoured, because a like that
    /// lands on top of an existing reaction is silently ignored by the server
    /// and the two sides would disagree from then on.
    func setReaction(
        _ glyph: String?,
        onMessage messageID: String,
        in conversation: ConversationID,
        replacing current: String? = nil,
        retry: RetryPolicy = .interactive
    ) async throws {
        if glyph == current { return }
        if current != nil {
            try await unlike(message: messageID, in: conversation, retry: retry)
        }
        if let glyph {
            try await like(
                message: messageID,
                in: conversation,
                icon: ReactionCatalog.icon(for: glyph),
                retry: retry)
        }
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
