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
    /// The periodic sync that runs while the app is in front. See
    /// `AppModel.startHeartbeat()`.
    case heartbeat
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
    /// When the read-cursor drain may speak to the server again, after a 429.
    private var readCursorPauseUntil: Date?

    /// How long to stand down when the server refuses a batch and says nothing
    /// about when to come back. An hour, which is what the official client uses.
    private static let readCursorPause: TimeInterval = 3_600

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
        // Join a sync already in flight rather than starting a second one. The
        // handle is cleared inside the task rather than after awaiting it,
        // because a caller that goes away mid-await would otherwise leave a
        // finished task sitting here forever — and every later sync would then
        // "join" it, return at once, and do nothing. An app backgrounded during
        // its first sync is exactly how that happens, and it wedges the whole
        // thing until relaunch.
        if let running, !running.isCancelled {
            await running.value
            // A sync that failed is not a sync this caller can inherit. The
            // ordinary way that bites: the app comes forward before the radio
            // is up, the foreground sync starts and is doomed, and the
            // reconnect that arrives a second later joins it, returns, and
            // reports success. Both callers walk away with nothing and the app
            // sits a week behind until a heartbeat notices, which is a minute
            // and a half of a transcript that will not fill in.
            guard state.phase == .failed else { return }
        }
        let task = Task { [self] in
            await perform(reason: reason)
            clearRunning()
        }
        running = task
        await task.value
    }

    private func clearRunning() {
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

            let topics = await subgroups(of: groups)
            if !topics.isEmpty {
                try await store.conversations.upsert(subgroups: topics)
                continuation.yield(.conversations)
            }

            // 3. Diff against local heads and close the gaps.
            // Two different questions, and the difference between them is the
            // whole point. `historyHeads` is how far we have *paged*;
            // `syncHeads` is the newest message we happen to hold, which a push
            // can raise without proving anything about what sits behind it.
            // The diff runs off the first; the second only tells the log when a
            // push has run out ahead of verified history.
            let heads = try await store.conversations.historyHeads()
            let held = try await store.messages.syncHeads()
            let plans = plan(groups: groups, chats: chats, topics: topics, heads: heads, held: held)
            await execute(plans)

            // A 409 tells us a queued send landed but not what id it landed
            // under. Now that history is current, the guid should resolve.
            await outbox.reconcile()

            // 4. Read state, in both directions. Best effort: a stale badge is
            //    not worth failing a sync that already delivered every message.
            await flushReadCursors()
            await syncReadReceipts()

            // 5. And now that both the messages and the cursors are current,
            //    the badges follow from them.
            await recountUnread()

            await housekeeping()

            state.phase = .idle
            state.lastError = nil
            state.lastSyncedAt = Date()
            log.info("sync finished in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s, \(plans.count) conversations moved")
        } catch {
            let message = failureText(error)
            state.phase = .failed
            state.lastError = message
            log.error("sync failed: \(message, privacy: .public)")
        }
    }

    /// Forget what the last list fetch said.
    ///
    /// The shortcut in ``plans(groups:chats:heads:)`` compares this fetch's tip
    /// against the previous one, so a caller that has just emptied the database
    /// underneath it has to say so. Otherwise the next list looks like "advanced
    /// by exactly one" against a head that no longer exists, and writes a
    /// placeholder instead of paging the history back in.
    func forgetTips() {
        lastSeenTips = [:]
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
            log.error("catch-up for \(conversation.storageKey, privacy: .public) failed: \(diagnosticText(error), privacy: .public)")
        }
        await roster
    }

    /// The topics inside every group that has any.
    ///
    /// `children_count` is the gate, and it is what makes this cheap: almost no
    /// group has topics, so almost no group costs a request. Without the gate
    /// this would be one call per conversation on every sync to discover that
    /// nineteen out of twenty have nothing.
    ///
    /// A group whose topics fail to load is a group without topics for this
    /// cycle. They are conversations, not corrections, and nothing in the
    /// history diff depends on them.
    private func subgroups(of groups: [Group]) async -> [Subgroup] {
        let parents = groups.filter { ($0.childrenCount ?? 0) > 0 }
        guard !parents.isEmpty else { return [] }

        var found: [Subgroup] = []
        await withTaskGroup(of: [Subgroup].self) { tasks in
            for parent in parents {
                tasks.addTask { (try? await self.api.subgroups(of: parent.id)) ?? [] }
            }
            for await batch in tasks { found.append(contentsOf: batch) }
        }
        return found
    }

    /// Fetch a group's membership, which the list step deliberately does without.
    ///
    /// `GET /v3/groups` is asked for `omit=memberships` because a member list
    /// runs to hundreds of rows the conversation list will never draw. A plain
    /// `GET /v3/groups/{id}` does include them, so opening a conversation is
    /// where the roster gets filled in and the member count becomes true.
    private func refreshRoster(of conversation: ConversationID) async {
        // A topic has no roster of its own. `GET /v3/groups/{topicID}` is a 404,
        // and its membership is simply its parent's, so the parent is what gets
        // asked and the members are written against the topic.
        let source = (try? await store.conversations.conversation(conversation))?
            .rosterSource ?? conversation
        guard case .group(let groupID) = source else { return }
        do {
            let group = try await api.group(id: groupID)
            // Only the roster. Writing the whole row here would also write the
            // server's `unread_count`, which is stale by definition at this
            // point: we cleared the badge locally a moment ago and the read
            // receipt has not landed yet, so the badge would come straight back.
            // The rest of the group's own description comes down this same
            // fetch, and the list endpoint does not necessarily carry it. Kept
            // because the info sheet has to draw from storage: it is opened
            // deliberately and should be complete on the frame it appears.
            try? await store.conversations.setProfile(from: group, for: conversation)
            guard let roster = group.members else { return }
            try await store.conversations.replaceMembers(roster, in: conversation)
            continuation.yield(.conversations)
        } catch {
            log.notice("roster for \(groupID, privacy: .public) unavailable: \(diagnosticText(error), privacy: .public)")
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
        topics: [Subgroup],
        heads: [ConversationID: String],
        held: [ConversationID: String]
    ) -> [Plan] {
        var plans: [Plan] = []

        /// Say so when a conversation's newest local message is ahead of the
        /// history we have actually paged.
        ///
        /// That is a hole, and it is the exact shape of the bug this logging
        /// exists for: a push lands after a spell offline, the transcript's
        /// newest row jumps to it, and everything between the old head and the
        /// pushed message is missing. It stays quiet for a healthy conversation
        /// because a healthy conversation is paged up to its own head.
        func noteGap(_ id: ConversationID) {
            guard let newest = held[id], let verified = heads[id],
                  newest != verified, Message.isNewer(newest, than: verified)
            else { return }
            log.notice("""
                gap in \(id.storageKey, privacy: .public): hold through \(newest, privacy: .public) \
                but history verified only through \(verified, privacy: .public); paging forward from there
                """)
        }

        for group in groups {
            let id = ConversationID.group(group.id)
            guard let summary = group.messages, let remoteHead = summary.lastMessageId else { continue }
            let localHead = heads[id]
            let tip = RemoteTip(messageID: remoteHead, count: summary.count)
            let previous = lastSeenTips[id]
            lastSeenTips[id] = tip

            guard moved(remote: remoteHead, local: localHead) else { continue }
            noteGap(id)
            // A group with topics does not own its own summary. `last_message_id`
            // there names the newest message anywhere under the group, topics
            // included, so the shortcut would write the group's list preview in
            // as a stand-in for a message that was never posted to the group:
            // a phantom bubble in the parent transcript, under a topic
            // message's id, with the verified head advanced to match. The topic
            // loop below refuses the shortcut for exactly this reason; a parent
            // is the other half of the same case.
            let hasTopics = (group.childrenCount ?? 0) > 0
            plans.append(Plan(
                conversation: id,
                localHead: localHead,
                embedded: !hasTopics
                    && advancedByOne(previous: previous, tip: tip, localHead: localHead)
                    ? Self.previewMessage(for: group, id: remoteHead)
                    : nil
            ))
        }

        // Topics get the same diff as anything else, and they only get it here.
        // They are absent from both list endpoints, so without this a topic's
        // history is whatever a focused catch-up happened to fetch and nothing
        // ever notices it falling behind.
        for topic in topics {
            let id = ConversationID.group(topic.groupID)
            guard let summary = topic.messages, let remoteHead = summary.lastMessageId
            else { continue }
            let localHead = heads[id]

            guard moved(remote: remoteHead, local: localHead) else { continue }
            noteGap(id)
            // No embedded shortcut, so no tip to remember either: `lastSeenTips`
            // exists only to answer `advancedByOne`, and topics do not ask.
            //
            // They do not ask because a topic's list entry carries a preview
            // with no sender, exactly like a group's, and writing that in as a
            // stand-in message is a bug this file has already had once: it made
            // messages you had sent yourself appear as somebody else's. One
            // request per moved topic is the right price for not repeating it.
            plans.append(Plan(conversation: id, localHead: localHead, embedded: nil))
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
            noteGap(id)
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
    ///
    /// Nil unless the preview actually describes a message. **A system notice
    /// previews as all nulls** — measured 31 August 2026 against a group whose
    /// newest message was `membership.announce.joined`: `nickname`, `text` and
    /// `image_url` were every one of them null, while the message itself was an
    /// ordinary `system: true` notice from "GroupMe". Building from that gives a
    /// message with no sender and nothing to say, which the transcript can only
    /// draw as an empty bubble attributed to "Someone". Returning nil instead
    /// leaves the conversation looking behind, which is exactly what it is, and
    /// the next pass pages the real notice in.
    private static func previewMessage(for group: Group, id: String) -> Message? {
        guard let summary = group.messages, let preview = summary.preview else { return nil }
        // A name is the part that cannot be recovered later. Text can be empty
        // on a message that is only a photograph, but a preview that will not
        // say who wrote it can only ever be drawn as a stranger.
        guard let nickname = preview.nickname, !nickname.isEmpty else { return nil }
        let hasText = !(preview.text ?? "").isEmpty
        guard hasText || !(preview.attachments ?? []).isEmpty else { return nil }
        return Message(
            id: id,
            sourceGuid: nil,
            createdAt: summary.lastMessageCreatedAt ?? Int(Date().timeIntervalSince1970),
            userId: nil,
            senderId: nil,
            name: nickname,
            avatarUrl: preview.imageUrl,
            senderType: previewSenderType,
            text: preview.text,
            system: false,
            favoritedBy: nil,
            attachments: preview.attachments,
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
                // `advancedByOne` proved this message is the only one we were
                // missing, so history really is contiguous through it. Saying so
                // is what stops the next sync from planning this conversation
                // again forever.
                try await store.conversations.advanceHistorySynced(
                    plan.conversation, to: embedded.id)
                continuation.yield(.messages(plan.conversation))
                return
            }
            try await fetchHistory(plan.conversation, after: plan.localHead, retry: .background)
        } catch {
            // One conversation failing is not the sync failing. The others still
            // land, and this one is picked up by the next loop.
            log.error("catch-up for \(plan.conversation.storageKey, privacy: .public) failed: \(diagnosticText(error), privacy: .public)")
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
        var exhaustedPages = true

        for _ in 0..<Self.maxHistoryPages {
            let page = try await api.messages(
                in: conversation, after: anchor,
                limit: Self.historyPageSize, retry: retry)
            guard !page.isEmpty else { exhaustedPages = false; break }

            try await store.messages.upsert(page, in: conversation)
            stored += page.count
            // The page is ascending and was fetched from `anchor`, so history is
            // now contiguous through its last message. Recording that after every
            // page rather than at the end is what lets a catch-up that gives up
            // early, or fails halfway, resume from where it got to instead of
            // starting over or, worse, pretending it finished.
            if let last = page.last?.id {
                try await store.conversations.advanceHistorySynced(conversation, to: last)
            }
            continuation.yield(.messages(conversation))

            // With no anchor the server hands back the newest page, so there is
            // nothing after it to ask for.
            guard anchor != nil, page.count >= Self.historyPageSize, let last = page.last?.id else {
                exhaustedPages = false
                break
            }
            anchor = last
        }

        if exhaustedPages {
            // We stopped because we ran out of budget, not because we ran out of
            // history, so there is still a hole. It is not lost: the verified
            // head moved as far as we got, so the next sync sees the conversation
            // as still behind and carries on from here. Worth a line all the
            // same, because "the catch-up was truncated" is otherwise invisible.
            log.notice("""
                history for \(conversation.storageKey, privacy: .public) still incomplete after \
                \(Self.maxHistoryPages) pages (\(stored) messages); resuming on the next sync
                """)
        }

        if stored > 0 {
            // Whatever the list said this conversation had waiting, we can now
            // see for ourselves.
            await recountUnread(in: conversation)
            continuation.yield(.conversations)
            log.debug("stored \(stored) messages for \(conversation.storageKey, privacy: .public)")
        }
        return stored
    }

    /// The newest message id that is safe to page forward from.
    ///
    /// Safe means two things. It must be somewhere history is actually
    /// contiguous, which is what `history_synced_id` records and what the
    /// newest row in the table emphatically is not: anchoring on a pushed
    /// message skips everything between it and the last thing we paged. And it
    /// must not be a list-preview placeholder, which carries no sender and has
    /// to be overwritten by the server's real copy.
    ///
    /// Falling back to the recent scan when nothing has been paged yet keeps the
    /// cold-start behaviour: no anchor means "fetch the newest page", which is
    /// the right thing to show somebody opening a conversation for the first
    /// time.
    private func healableAnchor(_ conversation: ConversationID) async throws -> String? {
        let recent = try await store.messages.recent(conversation, limit: 32)
        guard let verified = try await store.conversations.historySyncedID(conversation) else {
            // `recent` is oldest first, so the last non-placeholder is the newest one.
            return recent.last(where: { !$0.isListPreview })?.id
        }
        guard recent.contains(where: { $0.id == verified && $0.isListPreview }) else {
            return verified
        }
        // The verified head is a preview row. Anchor behind it so the server's
        // real message comes back and replaces it.
        return recent.last { !$0.isListPreview && Message.isNewer(verified, than: $0.id) }?.id
    }

    // MARK: - Step 4: read state

    /// Recount one conversation's badge from the messages on disk.
    ///
    /// Silent when we do not yet know who we are: without that, every message
    /// looks like somebody else's and a conversation full of our own writing
    /// would light up. The next sync after sign-in has the id and puts the
    /// numbers right.
    private func recountUnread(in conversation: ConversationID, lowering: Bool = false) async {
        guard let currentUserID else { return }
        try? await store.conversations.recountUnread(
            in: conversation, mine: currentUserID, lowering: lowering)
    }

    private func recountUnread() async {
        guard let currentUserID else { return }
        try? await store.conversations.recountUnread(mine: currentUserID)
        continuation.yield(.conversations)
    }

    /// Post every read cursor the server has not acknowledged, in one call.
    ///
    /// The dirty flag is the queue and this is the drain; see
    /// `read_cursor_synced` in ``Schema``. A failure leaves the flags alone, so
    /// the next sync tries again, which is the whole point of writing them down.
    ///
    /// A 429 is the one failure worth remembering. GroupMe rate-limits this
    /// route hard, and a client that answers a refusal by asking again every
    /// ninety seconds is the reason routes get rate-limited. So the drain stands
    /// down for as long as the server asks, or an hour, which is what the
    /// official client waits.
    private func flushReadCursors() async {
        if let until = readCursorPauseUntil {
            guard Date() >= until else { return }
            readCursorPauseUntil = nil
        }
        guard let currentUserID else { return }
        let pending = (try? await store.conversations.pendingReadCursors()) ?? []
        guard !pending.isEmpty else { return }

        do {
            try await api.markRead(pending.map {
                GroupMeAPI.ReadReceipt(
                    conversationId: $0.conversation.restID(myUserID: currentUserID),
                    lastReadMessageId: $0.messageID)
            })
            for item in pending {
                try? await store.conversations
                    .markReadCursorSynced(item.conversation, at: item.messageID)
            }
            log.debug("posted \(pending.count) read cursor(s)")
        } catch {
            if (error as? APIError)?.status == 429 {
                let pause = (error as? APIError)?.retryAfter ?? Self.readCursorPause
                readCursorPauseUntil = Date().addingTimeInterval(pause)
                log.notice("read cursors rate limited; standing down for \(Int(pause), privacy: .public)s")
            } else {
                log.notice("read cursors unposted: \(diagnosticText(error), privacy: .public)")
            }
        }
    }

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
                    try await store.conversations.markRead(
                        conversation, upTo: readID, reportedByServer: true)
                } else if row.lastReadMessageID != readID {
                    // We are ahead: something was read on this device and the
                    // receipt did not reach the server. Flagged rather than
                    // posted from here, so it goes out batched with everything
                    // else owed on the next pass. Without this, every other
                    // device keeps showing a badge for a conversation that was
                    // read here days ago.
                    if let local = row.lastReadMessageID, Message.isNewer(local, than: readID) {
                        try await store.conversations.markReadCursorPending(conversation)
                    } else {
                        row.lastReadMessageID = readID
                        try await store.conversations.upsert(row: row)
                        // The cursor moved, so the badge may legitimately come
                        // down: these are messages somebody read elsewhere.
                        await recountUnread(in: conversation, lowering: true)
                    }
                }
            }
            continuation.yield(.conversations)
        } catch {
            log.notice("read receipts unavailable: \(diagnosticText(error), privacy: .public)")
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
            await applyLikeIconChange(from: message, in: conversation)
            do {
                let isMine = currentUserID != nil && (message.senderId ?? message.userId) == currentUserID
                let stored = try await store.messages.message(id: message.id, in: conversation)
                let known = stored != nil

                // An edit arrives under the same id as the message it revises, so
                // it must merge rather than insert. `after_id` can never show us
                // this, which makes the live event the only chance we get; see
                // `PushEvent.SystemEventType.messageUpdate`. The `isEdited` test
                // is a belt to the envelope's braces: the delivery is not always
                // labelled, and a revision stamp on a message we already hold says
                // the same thing.
                if known, push.isMessageUpdate || message.isEdited {
                    try await store.messages.applyUpdate(message, in: conversation)
                    continuation.yield(.messages(conversation))
                    continuation.yield(.conversations)
                    return
                }

                try await store.messages.upsert(message, in: conversation)
                // Deliberately *not* an advance of `history_synced_id`. A push
                // proves this message exists; it proves nothing about the
                // messages between it and the last page we fetched, and after a
                // spell offline there can be thousands. Leaving the verified
                // head where it is keeps the conversation looking behind to the
                // next diff, which is what makes the hole get filled instead of
                // hidden. See `history_synced_id` in ``Schema``.
                if !known, let verified = try await store.conversations
                    .historySyncedID(conversation),
                    Message.isNewer(message.id, than: verified) {
                    log.debug("""
                        push \(message.id, privacy: .public) into \(conversation.storageKey, privacy: .public) \
                        sits ahead of verified history \(verified, privacy: .public)
                        """)
                }
                // Only a genuinely new message from somebody else moves a
                // badge. What it moves it to is a count rather than a bump: the
                // message is on disk by now, so asking how many sit past the
                // read cursor already includes it, and asking twice cannot
                // count it twice.
                if !isMine, !known, !message.isSystem {
                    await recountUnread(in: conversation)
                }
                continuation.yield(.messages(conversation))
                continuation.yield(.conversations)
            } catch {
                log.error("could not store pushed message: \(diagnosticText(error), privacy: .public)")
            }

        case .liked(let like), .unliked(let like):
            // The frame is not a message: it names one and carries the whole
            // reaction set afterwards. See ``PushEvent/Like``. This used to try
            // to decode the subject as a `Message` and could never succeed,
            // because the stub it names has no `created_at`, so every reaction
            // anybody made went in the bin and the only reactions we ever drew
            // were the ones a REST fetch happened to carry. `after_id` never
            // revisits a message, so that is not a delay; it is forever.
            guard let messageID = like.messageID,
                  let conversation = conversation(for: like, channel: push.channel)
            else {
                log.notice("reaction push with no addressable message on \(push.channel, privacy: .public)")
                return
            }
            guard let reactions = like.reactions else {
                log.notice("""
                    reaction push for \(messageID, privacy: .public) carried no reaction set; \
                    leaving the stored copy alone
                    """)
                return
            }
            do {
                guard try await store.messages.replaceReactions(
                    reactions, onMessage: messageID, in: conversation) != nil
                else { return }
                continuation.yield(.messages(conversation))
            } catch {
                log.error("could not store reaction: \(diagnosticText(error), privacy: .public)")
            }

        case .typing, .unrecognised:
            break
        }
    }

    /// Fold a like-icon change into the conversation row.
    ///
    /// A group changing its like icon is not a push type of its own. It arrives
    /// the way every group setting change does: an ordinary message with
    /// `system: true` and an `event.type`, carrying the new icon in
    /// `event.data.like_icon`. That makes this the cheap path. The expensive
    /// one, a full `GET /v3/groups/{id}`, is never needed for a change we were
    /// handed outright.
    ///
    /// Absence is the removal. `group.like_icon_removed` carries no icon by
    /// definition, and `group.subgroup_like_icon_change` uses a missing
    /// `like_icon` to mean the same thing (`MessageUtils` reads a null there as
    /// the "icon removed" sentence), so both land on a nil write.
    private func applyLikeIconChange(from message: Message, in conversation: ConversationID) async {
        let icon: Message.Reaction?
        switch message.event?.type {
        case Message.SystemEvent.likeIconSet, Message.SystemEvent.subgroupLikeIconChanged:
            icon = message.event?.data?.likeIcon
        case Message.SystemEvent.likeIconRemoved:
            icon = nil
        default:
            return
        }
        do {
            try await store.conversations.setLikeIcon(icon, for: conversation)
            continuation.yield(.conversations)
        } catch {
            log.error("could not store like icon: \(diagnosticText(error), privacy: .public)")
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

    /// Which conversation a reaction push belongs to.
    ///
    /// The group case names its group outright. The DM case carries a `chat_id`,
    /// which is the two user ids joined with `+`, so the conversation is
    /// whichever end is not us.
    private func conversation(for like: PushEvent.Like, channel: String?) -> ConversationID? {
        if let groupID = like.groupID { return .group(groupID) }
        if let chatID = like.chatID, let id = direct(fromJoined: chatID, separator: "+") { return id }
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
