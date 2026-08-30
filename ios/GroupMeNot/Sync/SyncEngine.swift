import Foundation
import OSLog

/// Where a sync is in its life, and everything the UI needs to say about the
/// network in one line of chrome.
///
/// A failure here is a banner, never a modal: local storage still has everything
/// on screen, so the honest message is "this may be a few minutes stale", not
/// "something went wrong".
nonisolated struct SyncState: Sendable, Hashable {
    nonisolated enum Phase: Sendable, Hashable {
        case idle
        case syncing
        case failed
    }

    var phase: Phase = .idle
    /// Reachability, folded in by ``AppModel`` so a view needs one property
    /// rather than two. Starts true: before the first path update we do not know,
    /// and guessing "offline" is how apps flash a false error on launch.
    var isOnline = true
    /// Why the last sync failed, if it did. Cleared by the next success.
    var lastError: String?
    var lastSyncedAt: Date?

    var isRefreshing: Bool { phase == .syncing }
    var isIdle: Bool { phase == .idle }
}

/// Why a sync ran. Only used for logging, but a sync you cannot attribute is a
/// sync you cannot tune.
nonisolated enum SyncReason: String, Sendable {
    case launch
    case foreground
    case manual
    case reconnect
    case signIn
    case push
}

/// What changed in local storage. The UI layer reloads from the stores when one
/// of these arrives; nothing here carries data, because the stores are the
/// source of truth and a change notification that carries a payload is just a
/// second source of truth waiting to disagree.
nonisolated enum SyncChange: Sendable {
    case state(SyncState)
    case conversations
    case messages(ConversationID)
}

/// The catch-up loop.
///
/// Faye has no replay: anything published while the socket was down is gone, and
/// there is no "events since" endpoint to ask instead. So every foreground and
/// every reconnect runs the whole loop, which is:
///
/// 1. drain the outbox, so our own writes land before we read
/// 2. `GET /v3/groups?omit=memberships` and `GET /v3/chats`, concurrently
/// 3. for each conversation whose `last_message_id` moved, page `after_id` from
///    the local head at `limit=200` until a short page
/// 4. `GET /v4/read_receipts`, to reconcile read state
///
/// Step 3 has a shortcut worth most of the loop's cost: both list endpoints
/// embed the newest message (whole, for chats; as a preview, for groups). When a
/// conversation advanced by exactly one message we already have it, and the
/// follow-up call is skipped. On the common wake-up case, "three chats have one
/// new message each", that is three conversations changed and zero message
/// calls.
///
/// The engine writes only through the store actors and reads only through the
/// API actor. It owns no cache of its own beyond the small bookkeeping needed to
/// recognise the one-message case.
actor SyncEngine {
    /// The server's real cap. Asking for more earns a 400 that says so.
    static let historyPageSize = GroupMeAPI.maxMessagesPerPage
    /// Conversation lists are offset-paged; 100 is what the official client asks for.
    static let listPageSize = 100
    /// Enough for 100k messages in one conversation. A catch-up that needs more
    /// than this is a fresh install, and a fresh install does not need all of it.
    static let maxHistoryPages = 10
    /// Enough for 5000 conversations. Nobody has 5000 conversations.
    static let maxListPages = 50
    /// How many conversations to catch up at once. Four keeps a slow cell busy
    /// without giving GroupMe's rate limiter a reason to notice us.
    static let fetchConcurrency = 4

    /// `sender_type` on the stand-in row written from a group list preview.
    ///
    /// A preview has the text and the nickname but no sender id, so the row is
    /// good enough for a list cell and not good enough for a transcript bubble.
    /// Marking it means ``catchUp(_:)`` can heal it the moment somebody opens the
    /// conversation, by anchoring its `after_id` behind the placeholder.
    static let previewSenderType = "preview"

    /// State changes and store writes, in one stream. Single consumer.
    nonisolated let changes: AsyncStream<SyncChange>

    private(set) var state = SyncState() {
        didSet {
            guard state != oldValue else { return }
            continuation.yield(.state(state))
        }
    }

    private let api: GroupMeAPI
    private let store: Store
    private let outbox: Outbox
    private let continuation: AsyncStream<SyncChange>.Continuation
    private let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "sync")

    private var currentUserID: String?
    /// The full sync currently running, if any. A second caller joins it rather
    /// than starting a competing one.
    private var running: Task<Void, Never>?
    /// Conversations with a targeted catch-up in flight, so opening a
    /// conversation twice in a second does not fetch it twice.
    private var catchingUp: Set<ConversationID> = []
    /// What the last list fetch said about each conversation's newest message.
    /// In memory only: after a cold start the shortcut simply does not fire, and
    /// the loop falls back to a normal `after_id` page.
    private var lastSeenTips: [ConversationID: RemoteTip] = [:]

    /// The newest message a list fetch reported, with the conversation's total
    /// message count beside it. The pair is what makes "advanced by exactly one"
    /// a fact rather than a guess.
    private struct RemoteTip {
        var messageID: String
        var count: Int?
    }

    init(api: GroupMeAPI, store: Store, outbox: Outbox, currentUserID: String? = nil) {
        self.api = api
        self.store = store
        self.outbox = outbox
        self.currentUserID = currentUserID
        let (stream, continuation) = AsyncStream<SyncChange>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        self.changes = stream
        self.continuation = continuation
    }

    /// Tell the engine who we are. Needed to address DMs and to decide whether an
    /// arriving message should light up an unread badge.
    func adopt(currentUserID id: String) {
        currentUserID = id
    }

    // MARK: - The loop

    /// Run the whole catch-up. Two syncs never overlap: a caller arriving while
    /// one is in flight waits for that one and returns.
    func sync(reason: SyncReason = .manual) async {
        if let running {
            await running.value
            return
        }
        let task = Task { await perform(reason: reason) }
        running = task
        await task.value
        running = nil
    }

    private func perform(reason: SyncReason) async {
        let started = Date()
        state.phase = .syncing
        log.info("sync started (\(reason.rawValue, privacy: .public))")

        do {
            // 1. Our own writes first, so the reads that follow see them.
            await outbox.drain()

            // 2. Both lists at once. Neither depends on the other and together
            //    they are the whole conversation list.
            async let groupsTask = allGroups()
            async let chatsTask = allChats()
            let (groups, chats) = try await (groupsTask, chatsTask)

            try await store.conversations.upsert(groups: groups)
            try await store.conversations.upsert(chats: chats)
            continuation.yield(.conversations)

            // 3. Diff against local heads and close the gaps.
            let heads = try await store.messages.syncHeads()
            let plans = plan(groups: groups, chats: chats, heads: heads)
            await execute(plans)

            // A 409 tells us a queued send landed but not what id it landed
            // under. Now that history is current, the guid should resolve.
            await outbox.reconcile()

            // 4. Read state. Best effort: a stale badge is not worth failing a
            //    sync that already delivered every message.
            await syncReadReceipts()

            await housekeeping()

            state.phase = .idle
            state.lastError = nil
            state.lastSyncedAt = Date()
            log.info("sync finished in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s, \(plans.count) conversations moved")
        } catch {
            let message = error.shortFailureText
            state.phase = .failed
            state.lastError = message
            log.error("sync failed: \(message, privacy: .public)")
        }
    }

    /// Catch one conversation up now. Used when a conversation opens, and when
    /// the outbox needs a server id resolved.
    ///
    /// Anchors behind any list-preview placeholder at the head, so opening a
    /// conversation replaces the lossy row with the server's real message.
    func catchUp(_ conversation: ConversationID) async {
        guard catchingUp.insert(conversation).inserted else { return }
        defer { catchingUp.remove(conversation) }
        // History and roster are independent reads; neither should wait on the
        // other, and the transcript is the one worth having first.
        async let roster: Void = refreshRoster(of: conversation)
        do {
            let anchor = try await healableAnchor(conversation)
            try await fetchHistory(conversation, after: anchor, retry: .interactive)
        } catch {
            log.error("catch-up for \(conversation.storageKey, privacy: .public) failed: \(error.shortFailureText, privacy: .public)")
        }
        await roster
    }

    /// Fetch a group's membership, which the list step deliberately does without.
    ///
    /// `GET /v3/groups` is asked for `omit=memberships` because a member list
    /// runs to hundreds of rows the conversation list will never draw. A plain
    /// `GET /v3/groups/{id}` does include them, so opening a conversation is
    /// where the roster gets filled in and the member count becomes true.
    private func refreshRoster(of conversation: ConversationID) async {
        guard case .group(let groupID) = conversation else { return }
        do {
            let group = try await api.group(id: groupID)
            try await store.conversations.upsert(groups: [group])
            continuation.yield(.conversations)
        } catch {
            log.notice("roster for \(groupID, privacy: .public) unavailable: \(error.shortFailureText, privacy: .public)")
        }
    }

    // MARK: - Step 2: the lists

    private func allGroups() async throws -> [Group] {
        var all: [Group] = []
        for page in 1...Self.maxListPages {
            let batch = try await api.groups(page: page, perPage: Self.listPageSize)
            all.append(contentsOf: batch)
            if batch.count < Self.listPageSize { break }
        }
        return all
    }

    private func allChats() async throws -> [Chat] {
        var all: [Chat] = []
        for page in 1...Self.maxListPages {
            let batch = try await api.chats(page: page, perPage: Self.listPageSize)
            all.append(contentsOf: batch)
            if batch.count < Self.listPageSize { break }
        }
        return all
    }

    // MARK: - Step 3: the diff

    /// One conversation that moved, and how to close the gap.
    private struct Plan: Sendable {
        var conversation: ConversationID
        var localHead: String?
        /// The whole new message, when the list already handed it to us and it is
        /// provably the only one we are missing.
        var embedded: Message?
    }

    private func plan(
        groups: [Group],
        chats: [Chat],
        heads: [ConversationID: String]
    ) -> [Plan] {
        var plans: [Plan] = []

        for group in groups {
            let id = ConversationID.group(group.id)
            guard let summary = group.messages, let remoteHead = summary.lastMessageId else { continue }
            let localHead = heads[id]
            let tip = RemoteTip(messageID: remoteHead, count: summary.count)
            let previous = lastSeenTips[id]
            lastSeenTips[id] = tip

            guard moved(remote: remoteHead, local: localHead) else { continue }
            plans.append(Plan(
                conversation: id,
                localHead: localHead,
                embedded: advancedByOne(previous: previous, tip: tip, localHead: localHead)
                    ? Self.previewMessage(for: group, id: remoteHead)
                    : nil
            ))
        }

        for chat in chats {
            let id = ConversationID.direct(otherUserID: chat.otherUser.id)
            guard let last = chat.lastMessage else { continue }
            let localHead = heads[id]
            let tip = RemoteTip(messageID: last.id, count: chat.messagesCount)
            let previous = lastSeenTips[id]
            lastSeenTips[id] = tip

            // `upsert(chats:)` already pointed the list row at this message; the
            // question here is only whether the transcript is missing anything.
            guard moved(remote: last.id, local: localHead) else { continue }
            plans.append(Plan(
                conversation: id,
                localHead: localHead,
                embedded: advancedByOne(previous: previous, tip: tip, localHead: localHead) ? last : nil
            ))
        }

        return plans
    }

    /// True when the server's newest message is not one we already have.
    private func moved(remote: String, local: String?) -> Bool {
        guard let local else { return true }
        return remote != local && Message.isNewer(remote, than: local)
    }

    /// The shortcut's precondition, stated strictly.
    ///
    /// We saw head `H` with total count `N`; the server now says head `H'` with
    /// count `N + 1`, and our local head is still `H`. Under those three facts
    /// `H'` is the only message we are missing, so the list already gave us
    /// everything and the follow-up call is pure waste.
    ///
    /// Any weaker test risks silently skipping messages, which is the one bug an
    /// offline client cannot afford, so all three have to hold.
    private func advancedByOne(previous: RemoteTip?, tip: RemoteTip, localHead: String?) -> Bool {
        guard let previous, let localHead,
              previous.messageID == localHead,
              let before = previous.count, let now = tip.count,
              now == before + 1
        else { return false }
        return true
    }

    /// A stand-in message built from a group's list preview.
    ///
    /// The preview carries text, nickname, image and attachments but no sender
    /// id, so this is marked with ``previewSenderType`` and replaced by the real
    /// message the first time anybody opens the conversation.
    private static func previewMessage(for group: Group, id: String) -> Message? {
        guard let summary = group.messages else { return nil }
        let preview = summary.preview
        return Message(
            id: id,
            sourceGuid: nil,
            createdAt: summary.lastMessageCreatedAt ?? Int(Date().timeIntervalSince1970),
            userId: nil,
            senderId: nil,
            name: preview?.nickname,
            avatarUrl: preview?.imageUrl,
            senderType: previewSenderType,
            text: preview?.text,
            system: false,
            favoritedBy: nil,
            attachments: preview?.attachments,
            groupId: group.id,
            chatId: nil,
            recipientId: nil,
            parentId: nil,
            pinnedAt: nil,
            pinnedBy: nil,
            deletedAt: nil,
            deletionActor: nil,
            updatedAt: nil,
            event: nil
        )
    }

    private func execute(_ plans: [Plan]) async {
        guard !plans.isEmpty else { return }
        // A sliding window rather than a task per conversation: after a week
        // offline "conversations that changed" is most of them, and firing
        // eighty message fetches at once is how a client discovers GroupMe's
        // rate limiter.
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            while next < min(Self.fetchConcurrency, plans.count) {
                let plan = plans[next]
                group.addTask { await self.execute(plan) }
                next += 1
            }
            while await group.next() != nil {
                guard next < plans.count else { continue }
                let plan = plans[next]
                next += 1
                group.addTask { await self.execute(plan) }
            }
        }
    }

    private func execute(_ plan: Plan) async {
        do {
            if let embedded = plan.embedded {
                try await store.messages.upsert(embedded, in: plan.conversation)
                continuation.yield(.messages(plan.conversation))
                return
            }
            try await fetchHistory(plan.conversation, after: plan.localHead, retry: .background)
        } catch {
            // One conversation failing is not the sync failing. The others still
            // land, and this one is picked up by the next loop.
            log.error("catch-up for \(plan.conversation.storageKey, privacy: .public) failed: \(error.shortFailureText, privacy: .public)")
        }
    }

    /// Page forward from `anchor` until a short page comes back.
    ///
    /// `after_id` is the only gap-free direction. `since_id` looks like it would
    /// do this job and does not: it returns the *newest* messages and silently
    /// drops everything between them and the anchor.
    @discardableResult
    private func fetchHistory(
        _ conversation: ConversationID,
        after anchor: String?,
        retry: RetryPolicy
    ) async throws -> Int {
        var anchor = anchor
        var stored = 0

        for _ in 0..<Self.maxHistoryPages {
            let page = try await api.messages(
                in: conversation, after: anchor,
                limit: Self.historyPageSize, retry: retry)
            guard !page.isEmpty else { break }

            try await store.messages.upsert(page, in: conversation)
            stored += page.count
            continuation.yield(.messages(conversation))

            // With no anchor the server hands back the newest page, so there is
            // nothing after it to ask for.
            guard anchor != nil, page.count >= Self.historyPageSize, let last = page.last?.id else { break }
            anchor = last
        }

        if stored > 0 {
            continuation.yield(.conversations)
            log.debug("stored \(stored) messages for \(conversation.storageKey, privacy: .public)")
        }
        return stored
    }

    /// The newest local message id that is safe to page forward from: the head,
    /// unless the head is a list-preview placeholder, in which case we anchor
    /// behind it so the real message comes back and overwrites it.
    private func healableAnchor(_ conversation: ConversationID) async throws -> String? {
        let recent = try await store.messages.recent(conversation, limit: 32)
        // `recent` is oldest first, so the last non-placeholder is the newest one.
        return recent.last(where: { !$0.isListPreview })?.id
    }

    // MARK: - Step 4: read state

    private func syncReadReceipts() async {
        do {
            let receipts = try await api.readReceipts()
            for receipt in receipts {
                guard let conversation = conversation(forRESTID: receipt.conversationId),
                      let readID = receipt.lastReadMessageId
                else { continue }
                guard var row = try await store.conversations.conversation(conversation) else { continue }

                // A cursor at or past our newest message means the conversation
                // is read, whatever the list said. Otherwise keep the list's
                // unread count and just record where the cursor is.
                if let head = row.lastMessageID, !Message.isNewer(head, than: readID) {
                    try await store.conversations.markRead(conversation, upTo: readID)
                } else if row.lastReadMessageID != readID {
                    row.lastReadMessageID = readID
                    try await store.conversations.upsert(row: row)
                }
            }
            continuation.yield(.conversations)
        } catch {
            log.notice("read receipts unavailable: \(error.shortFailureText, privacy: .public)")
        }
    }

    private func housekeeping() async {
        _ = try? await store.outbox.pruneSent()
        _ = try? await store.outbox.releaseStalledSends()
    }

    // MARK: - Realtime

    /// Fold a realtime event into local storage.
    ///
    /// Everything the socket delivers is a store write and a notification; the
    /// UI never sees a `PushEvent`. A resume runs the whole loop again, because
    /// Faye replays nothing and the REST diff is the only way to close the hole.
    func apply(_ event: RealtimeEvent) async {
        switch event {
        case .push(let push):
            await apply(push)
        case .connectionDidResume:
            await sync(reason: .reconnect)
        case .connectionDidDrop, .connectionStateDidChange, .subscriptionDidFail:
            break
        }
    }

    private func apply(_ push: PushEvent) async {
        switch push.kind {
        case .message(let message):
            guard let conversation = conversation(for: message, channel: push.channel) else {
                log.notice("push message with no addressable conversation on \(push.channel, privacy: .public)")
                return
            }
            do {
                let isMine = currentUserID != nil && (message.senderId ?? message.userId) == currentUserID
                let known = try await store.messages.message(id: message.id, in: conversation) != nil
                try await store.messages.upsert(message, in: conversation)
                // Only a genuinely new message from somebody else moves a badge.
                if !isMine, !known, !message.isSystem {
                    try await store.conversations.incrementUnread(conversation)
                }
                continuation.yield(.messages(conversation))
                continuation.yield(.conversations)
            } catch {
                log.error("could not store pushed message: \(error.shortFailureText, privacy: .public)")
            }

        case .liked(let like), .unliked(let like):
            // The like payload usually carries the whole message, favourites and
            // all, so storing it is the entire update.
            guard let message = like.message,
                  let conversation = conversation(for: message, channel: push.channel)
            else { return }
            _ = try? await store.messages.upsert(message, in: conversation)
            continuation.yield(.messages(conversation))

        case .typing, .unrecognised:
            break
        }
    }

    // MARK: - Addressing

    /// Which conversation a pushed message belongs to.
    ///
    /// A group message says so outright. A DM arrives on `/user/{me}` and names
    /// two people, so the conversation is whichever of them is not us; the
    /// channel name is the fallback when the payload is thin.
    private func conversation(for message: Message, channel: String?) -> ConversationID? {
        if let groupID = message.groupId { return .group(groupID) }
        if let me = currentUserID {
            if let recipient = message.recipientId, recipient != me { return .direct(otherUserID: recipient) }
            if let sender = message.senderId ?? message.userId, sender != me { return .direct(otherUserID: sender) }
            // A note to self: both ends are us.
            if message.recipientId == me { return .direct(otherUserID: me) }
        }
        return channel.flatMap(conversation(forChannel:))
    }

    /// `/group/{id}` or `/direct_message/{a}_{b}`.
    private func conversation(forChannel channel: String) -> ConversationID? {
        let parts = channel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "group": return .group(parts[1])
        case "direct_message": return direct(fromJoined: parts[1], separator: "_")
        default: return nil
        }
    }

    /// `/conversations/{id}` ids: a group id, or two user ids joined with `+`.
    private func conversation(forRESTID id: String) -> ConversationID? {
        id.contains("+") ? direct(fromJoined: id, separator: "+") : .group(id)
    }

    private func direct(fromJoined joined: String, separator: Character) -> ConversationID? {
        let ends = joined.split(separator: separator).map(String.init)
        guard !ends.isEmpty else { return nil }
        guard let me = currentUserID else { return nil }
        // The other end, or ourselves for a note to self.
        let other = ends.first { $0 != me } ?? ends[0]
        return .direct(otherUserID: other)
    }
}

nonisolated extension Message {
    /// True for the stand-in row written from a group's list preview, which has
    /// the text but not the sender. The transcript should treat it as provisional
    /// and ``SyncEngine/catchUp(_:)`` replaces it with the server's copy.
    var isListPreview: Bool { senderType == SyncEngine.previewSenderType }
}
