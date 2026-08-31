import Foundation
import Observation
import OSLog

/// The one object the UI talks to.
///
/// It owns the stores, the API client, the sync engine, the outbox and the push
/// socket, and it publishes plain arrays. Every property here is read out of
/// local storage; nothing on screen ever waits for a request to come back. A
/// sync, a push, or a queued send changes the database, the database change
/// comes back through a stream, and the arrays are reloaded. With the radio off
/// the whole app still works, minus the arriving of new things.
///
/// The rule this enforces, everywhere: **local storage is the truth, the network
/// updates local storage, the UI observes local storage.** Any code that reaches
/// past this class to the network for something the screen needs is a bug.
@Observable
@MainActor
final class AppModel {
    // MARK: - What the UI renders

    /// The conversation list, newest activity first.
    private(set) var conversations: [ConversationRow] = []
    /// The open conversation's transcript, oldest first.
    private(set) var messages: [Message] = []
    /// Queued sends for the open conversation, to append below `messages`.
    private(set) var outbox: [OutboxEntry] = []
    /// How far along each queued message's attachments are, by source guid.
    ///
    /// In memory only, and deliberately: a fraction is true for a few seconds
    /// and meaningless afterwards. Entries are dropped as soon as the send
    /// leaves the queue, so this never grows.
    private(set) var uploadProgress: [String: Double] = [:]
    /// Messages fetched only to be quoted above a reply.
    ///
    /// In memory rather than in the messages table, and that is deliberate. A
    /// message pulled out of the middle of a conversation's history says nothing
    /// about what surrounds it, and writing it to the table would put a row in a
    /// range `history_synced_id` has not verified. The store's account of what
    /// is contiguous depends on nothing arriving there by the side door.
    private(set) var quotedParents: [String: Message] = [:]
    /// Ids already asked for, successfully or not, so a quote whose original was
    /// deleted is not re-requested on every rebuild.
    @ObservationIgnored private var attemptedQuotes: Set<String> = []
    /// Ids we asked for and did not get. Distinct from "not asked yet", and the
    /// distinction is the whole point: without it a quote that can never be
    /// resolved says "Loading…" for as long as the conversation is open.
    private(set) var unresolvedQuotes: Set<String> = []
    private(set) var openConversationID: ConversationID?
    private(set) var members: [Member] = []

    private(set) var currentUser: CurrentUser?
    /// What is known about the session, which is not the same question as
    /// whether there is one.
    ///
    /// The third case is the whole point. A plain `Bool` has to start somewhere,
    /// and starting at false means the first frames of every launch draw the
    /// sign-in screen before the keychain has been asked. That is not a slow
    /// answer, it is a wrong one: the app flashes a screen the user has already
    /// dealt with and then throws it away.
    nonisolated enum Session: Sendable {
        /// The keychain has not answered yet. Lasts a frame or two.
        case unknown
        case signedOut
        case signedIn
    }

    /// Seeded from the stored identity, which is a synchronous `UserDefaults`
    /// read and therefore true on the very first frame.
    ///
    /// A guess, but not a loose one: signing out clears the identity in the same
    /// breath as the token, so the two are only ever out of step if the keychain
    /// item is removed from underneath the app. The authoritative read runs a
    /// moment later in `bootstrap` and corrects it either way.
    private(set) var session: Session = UserDefaults.standard
        .data(forKey: AppModel.currentUserKey) == nil ? .unknown : .signedIn

    var isSignedIn: Bool { session == .signedIn }
    private(set) var syncState = SyncState()
    private(set) var totalUnread = 0
    /// Who is typing in the open conversation, and when we last heard from them.
    /// Expired entries are swept on each new event; see `PushEvent.Typing.expiry`.
    private(set) var typingUserIDs: [String: Date] = [:]

    /// Network and socket state, for the offline banner.
    let realtime = RealtimeMonitor()

    /// The glyphs the reaction picker offers first, for the open conversation.
    ///
    /// The standard eighteen, except that a group which chose its own like icon
    /// gets that one at the front: it is the reaction that group actually means,
    /// so it should be the one under the thumb. Everything else is still
    /// reachable, from the picker's More button.
    ///
    /// A local constant plus a stored column, never a request. The official
    /// client refreshes the eighteen from a CDN document, but a picker must
    /// never be empty because a request has not come back, so the local list is
    /// the source and a refresh would only ever be an improvement on it.
    var reactionCatalog: ReactionCatalog {
        guard let openConversationID,
              let row = conversations.first(where: { $0.id == openConversationID })
        else { return .default }
        return ReactionCatalog.default.withLikeIcon(row.likeIcon)
    }

    /// Link previews for the open transcript.
    ///
    /// Owned here so the whole app shares one cache and one in-flight table: a
    /// link quoted in three conversations is fetched once. Memory-only and
    /// entirely cosmetic, which is why it is the one thing in this class that
    /// the UI may talk to directly.
    let previews: LinkPreviewService

    // MARK: - The machinery

    let store: Store
    private let tokens: TokenStore
    private let client: APIClient
    private let api: GroupMeAPI
    private let sends: Outbox
    /// Shared with the outbox. A profile picture goes up the same way a message
    /// photo does, and for the same reasons.
    private let uploads: MediaUploadService
    private let sync: SyncEngine
    private let bayeux: BayeuxClient
    private let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "app")

    /// How many messages the transcript holds. Grows as the user scrolls back.
    @ObservationIgnored private var window = AppModel.transcriptPage
    private static let transcriptPage = 200

    @ObservationIgnored private var didBootstrap = false
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var needsConversationReload = false
    @ObservationIgnored private var needsMessageReload = false
    /// True once paging back has run out of history, so the transcript stops
    /// asking for more.
    ///
    /// Observed, deliberately. `canLoadOlder` is read from a `body` to decide
    /// whether to draw the "loading earlier messages" spinner, so a change here
    /// that nothing is watching leaves that spinner turning over a conversation
    /// that has already reached its beginning.
    private var reachedBeginning = false

    /// The last attempt to page back failed on the network. Distinct from
    /// `reachedBeginning`, which means there is genuinely nothing more: this
    /// one is temporary, and the transcript offers to try again rather than
    /// pretending it is still loading.
    private(set) var olderPageFailed = false

    /// Placeholder ids we have already asked the server to resolve, so a row the
    /// server never replaces cannot spin the catch-up forever.
    @ObservationIgnored private var attemptedHeals: Set<String> = []
    @ObservationIgnored private var typingSweep: Task<Void, Never>?

    /// Where the signed-in user is remembered between launches. Small enough for
    /// defaults, and needed before the first request: DM routes are addressed
    /// with our own id, so a cold offline start that did not know it could not
    /// even name a conversation.
    private static let currentUserKey = "sh.dunkirk.GroupMeNot.currentUser"

    init(store: Store? = nil, tokens: TokenStore = .shared) {
        let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "app")
        let resolved: Store
        if let store {
            resolved = store
        } else if let disk = try? Store.onDisk() {
            resolved = disk
        } else if let memory = try? Store.ephemeral() {
            log.fault("could not open the on-disk store; running from memory this launch")
            resolved = memory
        } else {
            fatalError("SQLite is unavailable; there is no local store to run against")
        }

        let provider: @Sendable () async -> String? = { await tokens.token() }
        let client = APIClient(tokenProvider: provider)
        let api = GroupMeAPI(client: client)
        let uploads = MediaUploadService(tokenProvider: provider)
        self.uploads = uploads
        let outbox = Outbox(api: api, store: resolved, uploads: uploads)

        self.store = resolved
        self.tokens = tokens
        self.previews = LinkPreviewService(tokenProvider: provider)
        self.client = client
        self.api = api
        self.sends = outbox
        self.sync = SyncEngine(api: api, store: resolved, outbox: outbox)
        self.bayeux = BayeuxClient(tokenProvider: provider)
    }

    // MARK: - Lifecycle

    /// Bring the app up. Local state lands first and unconditionally; the network
    /// work is started afterwards and never blocks it.
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        // First, before anything that can wait.
        //
        // Which screen to draw depends on one keychain read and nothing else,
        // and it used to be decided after two hops onto the outbox actor and a
        // database open that runs migrations. All of that is quick and none of
        // it is instant, and for as long as it ran the root view had no answer
        // to give — which is the flash of the wrong screen at launch.
        restoreIdentity()
        session = await tokens.isSignedIn ? .signedIn : .signedOut

        realtime.start()
        realtime.attach(to: bayeux)
        startObserving()

        await sends.onNeedsReconcile { [sync] conversation in
            await sync.catchUp(conversation)
        }

        // Hops to the main actor because it redraws, and coalesces there rather
        // than here: `didSendBodyData` fires per packet, and a photo on a slow
        // connection would otherwise ask for a hundred frames a second.
        await sends.onUploadProgress { [weak self] guid, fraction in
            // Bound to a `let` before the `Task` reads it. A capture list makes
            // `self` a mutable variable in the enclosing closure, and reading a
            // captured `var` from concurrently-executing code is exactly what
            // Swift 6 refuses; a constant has nothing to race with.
            let model = self
            Task { @MainActor in model?.noteUploadProgress(guid, fraction) }
        }

        // 1. The screen, from disk. This is the part that must never wait.
        await reloadConversations()

        guard isSignedIn else { return }

        // 2. Everything else, in the background.
        if let user = currentUser {
            await adopt(user)
        }
        Task { await self.sends.drain() }
        Task { await self.drainReactions() }
        Task { await self.sync.sync(reason: .launch) }
        Task { await self.refreshIdentity() }
        Task { await self.refreshRequests() }
    }

    /// Call when the app comes back to the foreground. Faye does not replay what
    /// it missed, so the whole loop runs again.
    func foregrounded() async {
        guard isSignedIn else { return }
        if let user = currentUser { await bayeux.start(as: user.id) }
        await sync.sync(reason: .foreground)
    }

    /// Pull to refresh.
    func refresh() async {
        guard isSignedIn else { return }
        await sync.sync(reason: .manual)
        await refreshRequests()
    }

    // MARK: - Conversations

    /// Open a conversation. The transcript is on screen before this returns; the
    /// catch-up that follows is decoration.
    func openConversation(_ conversation: ConversationID) async {
        openConversationID = conversation
        window = Self.transcriptPage
        typingSweep?.cancel()
        typingUserIDs = [:]

        messages = await transcript(conversation) ?? []
        outbox = await sends.pending(in: conversation)
        members = (try? await store.conversations.members(of: conversation)) ?? []

        reachedBeginning = false
        olderPageFailed = false
        await markRead(conversation)

        // Both started rather than awaited. The transcript is already on screen
        // by this point and neither of these changes it: one puts subscribe
        // frames on a socket that may still be handshaking, the other is a
        // network round trip. Awaiting them only delays the caller, and the
        // caller is a view's `.task`.
        let channels = focusChannels(for: conversation)
        Task { [bayeux] in await bayeux.focus(on: channels) }
        Task { await self.sync.catchUp(conversation) }
    }

    /// Leave the open conversation. Synchronous, because it runs from
    /// `onDisappear` and a view teardown should not have to await anything.
    func closeConversation() {
        typingSweep?.cancel()
        typingSweep = nil
        openConversationID = nil
        messages = []
        outbox = []
        members = []
        typingUserIDs = [:]
        reachedBeginning = false
        olderPageFailed = false
        attemptedHeals = []
        attemptedQuotes = []
        quotedParents = [:]
        unresolvedQuotes = []
        Task { [bayeux] in await bayeux.focus(on: []) }
    }

    /// Whether scrolling up can turn up anything more. Goes false once a request
    /// for older messages comes back with nothing from either disk or the server,
    /// which is the only honest way to know: no endpoint reports a total.
    var canLoadOlder: Bool { !reachedBeginning && !messages.isEmpty }

    /// Page backwards. Local history first; the network only when we run out.
    func loadOlder() async {
        guard let conversation = openConversationID, !reachedBeginning else { return }
        let oldest = messages.first?.id
        olderPageFailed = false
        window += Self.transcriptPage

        if let stored = await transcript(conversation), stored.count > messages.count {
            messages = stored
            return
        }

        guard let oldest else {
            reachedBeginning = true
            return
        }

        let page: [Message]
        do {
            // No `limit:`. The client's default is the verified server cap,
            // and asking for less than the cap is asking for more round trips.
            page = try await api.messages(in: conversation, before: oldest)
        } catch {
            // A request that failed says nothing about whether history exists.
            // Treating a dead radio as "you have reached the beginning" would
            // permanently disable paging for the rest of the session, so the
            // window is put back and the next scroll tries again.
            window -= Self.transcriptPage
            olderPageFailed = true
            log.notice("could not page back in \(conversation.storageKey, privacy: .public): \(diagnosticText(error), privacy: .public)")
            return
        }

        guard !page.isEmpty else {
            reachedBeginning = true
            return
        }
        _ = try? await store.messages.upsert(page, in: conversation)
        messages = await transcript(conversation) ?? messages
    }

    /// Clear the badge locally, then tell the server whenever it is willing to
    /// listen. The order matters: the badge is the user's, not GroupMe's.
    func markRead(_ conversation: ConversationID) async {
        let head = conversation == openConversationID
            ? messages.last?.id
            : conversations.first { $0.id == conversation }?.lastMessageID
        try? await store.conversations.markRead(conversation, upTo: head)
        await reloadConversations()
        guard let head else { return }
        Task { [api] in
            // One shot: a read cursor that misses is worth nothing next to the
            // rate limit a retry storm would earn.
            try? await api.markRead(conversation: conversation, messageId: head)
        }
    }

    /// Mute or unmute, locally. GroupMe's mute route is not one we speak yet, so
    /// this is a device preference until it is.
    func setMuted(_ muted: Bool, for conversation: ConversationID) async {
        try? await store.conversations.setMuted(conversation, until: muted ? .distantFuture : nil)
        await reloadConversations()
    }

    // MARK: - Sending

    /// Queue a message for the open conversation.
    func send(
        _ text: String, media: [PickedMedia] = [], replyingTo parent: Message? = nil,
        mentioning mentions: Message.Attachment? = nil
    ) async {
        guard let conversation = openConversationID else { return }
        await send(
            text: text, media: media, to: conversation,
            replyingTo: parent, mentioning: mentions)
    }

    /// Queue a message. Returns as soon as it is durable, which is immediately.
    ///
    /// Attachments change nothing about that promise. The picked files are moved
    /// somewhere durable and the queue row is written before any upload starts,
    /// so a photo attached with the radio off is already in the transcript and
    /// already safe; the bytes go up whenever the network next allows.
    func send(
        text: String, media: [PickedMedia] = [], to conversation: ConversationID,
        replyingTo parent: Message? = nil, mentioning mentions: Message.Attachment? = nil
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !media.isEmpty else { return }
        // A reply is an ordinary message with one more attachment on it. Nothing
        // else in the queue, the retry or the idempotency guarantee has to know
        // that this one answers another.
        var attachments = parent.map { [Message.replyAttachment(to: $0)] } ?? []
        if let mentions { attachments.append(mentions) }
        do {
            try await sends.send(
                text: trimmed.isEmpty ? nil : trimmed, attachments: attachments,
                media: media, to: conversation)
        } catch {
            log.error("could not queue a send: \(error)")
        }
        if conversation == openConversationID {
            outbox = await sends.pending(in: conversation)
        }
        await reloadConversations()
    }

    /// Retry a send the server refused outright. Transient failures need no such
    /// thing: the outbox clears them on its own.
    func retry(_ entry: OutboxEntry) async {
        await sends.retry(entry.id)
    }

    func discard(_ entry: OutboxEntry) async {
        await sends.discard(entry.id)
    }

    /// Whether this account may post in the open conversation.
    ///
    /// Only ever false for an announcement topic, which GroupMe uses for a rules
    /// or announcements channel: everyone reads it, admins and the owner write
    /// it. The roster the roles come from is the *parent* group's, because a
    /// topic has no membership of its own.
    ///
    /// Optimistic while the roster is still loading. A composer that appears
    /// once the members arrive is a composer that flickered; one that is there
    /// and whose send is refused is a mistake the user can see and understand.
    var canPostInOpenConversation: Bool {
        guard let openConversationID,
              let row = conversations.first(where: { $0.id == openConversationID }),
              row.postingPolicy == .adminsOnly
        else { return true }
        guard let me = currentUser?.id, !members.isEmpty else { return true }
        return members.first { $0.identity == me }?.canPostInAnnouncements ?? true
    }

    /// Subscribe to every topic we know about.
    ///
    /// Started rather than awaited, and that is the whole point of the shape.
    /// This is called from the list reload, which the transcript reload runs
    /// *after*; awaiting it put a handful of subscribe frames on the socket
    /// between a conversation being opened and its messages appearing. On a cold
    /// start the socket is still handshaking, so those frames wait, and the
    /// transcript waited with them — a few seconds of an open conversation with
    /// nothing in it.
    ///
    /// Nothing depends on the result. It is idempotent, so a call that overlaps
    /// another simply finds the set already correct and sends nothing.
    private func followTopics() {
        let topics = conversations.filter(\.isTopic).map(\.id)
        guard !topics.isEmpty else { return }
        Task { [bayeux] in await bayeux.follow(topics: topics) }
    }

    /// The conversations to follow while this one is open.
    ///
    /// A topic and the group it belongs to, because a topic's messages could
    /// plausibly be published on either channel and both accept a subscription.
    /// One extra frame per conversation opened is a cheap way to stop caring
    /// which.
    private func focusChannels(for conversation: ConversationID) -> [ConversationID] {
        guard let parent = conversations.first(where: { $0.id == conversation })?.parentID
        else { return [conversation] }
        return [conversation, .group(parent)]
    }

    /// Publish a typing notice. Throttled inside the socket client, so calling
    /// this on every keystroke is fine.
    func userIsTyping() async {
        guard let conversation = openConversationID else { return }
        await bayeux.sendTyping(in: conversation)
    }

    // MARK: - Editing

    /// Whether the Edit action should be offered for this message at all.
    ///
    /// Three conditions, and the third is the one worth stating: GroupMe closes
    /// editing after `Group.messageEditPeriod` seconds and refuses the PUT after
    /// that. So the window is checked before the action appears rather than
    /// after it is used. A menu item that fails on tap is a worse bug than a menu
    /// item that is not there.
    ///
    /// DMs report no window, so this is false for them; see
    /// ``ConversationRow/canEdit(_:now:)``.
    func canEdit(_ message: Message) -> Bool {
        guard let me = currentUser?.id, (message.senderId ?? message.userId) == me else { return false }
        guard !message.isDeleted, !message.isSystem, !message.isListPreview else { return false }
        guard let conversation = openConversationID,
              let row = conversations.first(where: { $0.id == conversation })
        else { return false }
        return row.canEdit(message)
    }

    /// Rewrite one of our own messages, optimistically.
    ///
    /// Same order as a reaction: the published array first so the bubble changes
    /// on the next frame, then the database so a reload agrees, then the server.
    /// A refusal puts both local copies back to the text that was there before.
    ///
    /// There is no outbox entry for this. An edit has no `source_guid` and so no
    /// idempotency key, which means a blind retry could race a later edit and
    /// resurrect older text. A failed edit is therefore just a failed edit: the
    /// bubble reverts, and the user can try again knowing what they are looking
    /// at.
    func edit(_ message: Message, to text: String) async {
        guard let conversation = openConversationID, canEdit(message) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != message.text else { return }

        let originalText = message.text
        let originalStamp = message.updatedAt ?? message.createdAt

        await applyEdit(text: trimmed, stamp: Int(Date().timeIntervalSince1970),
                        to: message.id, in: conversation)

        do {
            try await api.edit(message: message.id, in: conversation, text: trimmed)
        } catch {
            log.notice("""
                edit of \(message.id, privacy: .public) did not stick: \
                \(diagnosticText(error), privacy: .public)
                """)
            await applyEdit(text: originalText, stamp: originalStamp,
                            to: message.id, in: conversation)
        }
    }

    /// The published copy and the stored copy, in that order. Adopting what the
    /// store hands back settles the same race ``commit(_:by:to:in:)`` does: a
    /// coalesced reload can land between the two writes.
    private func applyEdit(
        text: String?, stamp: Int, to messageID: String, in conversation: ConversationID
    ) async {
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index] = messages[index].editing(text: text, updatedAt: stamp)
        }
        guard let stored = try? await store.messages.applyEdit(
            text: text, updatedAt: stamp, toMessage: messageID, in: conversation)
        else { return }
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index] = stored
        }
        await reloadConversations()
    }


    /// Whether the Delete action should be offered.
    ///
    /// Same three conditions as ``canEdit(_:)``, against the group's own
    /// deletion window. Groups usually set that window to forever, so unlike
    /// editing this is normally available — but a group that has switched
    /// deletion off gets no action rather than one the server refuses.
    func canDelete(_ message: Message) -> Bool {
        guard let me = currentUser?.id, (message.senderId ?? message.userId) == me else { return false }
        guard !message.isDeleted, !message.isSystem, !message.isListPreview else { return false }
        guard let conversation = openConversationID,
              let row = conversations.first(where: { $0.id == conversation })
        else { return false }
        return row.canDelete(message)
    }

    /// Take one of our own messages back.
    ///
    /// Optimistic in the same order as an edit: the published array, then the
    /// database, then the server. A refusal puts the message back, because the
    /// alternative is a tombstone over a message that is still there for
    /// everybody else.
    func delete(_ message: Message) async {
        guard let conversation = openConversationID, canDelete(message) else { return }
        let original = message

        await applyDeletion(to: message.id, in: conversation)
        do {
            try await api.delete(message: message.id, in: conversation)
        } catch {
            let detail = diagnosticText(error)
            log.notice("delete of \(message.id, privacy: .public) did not stick: \(detail, privacy: .public)")
            // Straight back to what it was. There is no half-deleted state to
            // reason about, so restoring the whole message is both simplest and
            // exactly right.
            if let index = messages.firstIndex(where: { $0.id == original.id }) {
                messages[index] = original
            }
            _ = try? await store.messages.upsert(original, in: conversation)
            await reloadConversations()
        }
    }

    private func applyDeletion(to messageID: String, in conversation: ConversationID) async {
        let me = currentUser?.id
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            var copy = messages[index]
            copy.deletedAt = Int(Date().timeIntervalSince1970)
            copy.deletionActor = me
            copy.text = nil
            copy.attachments = nil
            messages[index] = copy
        }
        guard let stored = try? await store.messages.markDeleted(
            messageID, by: me, in: conversation)
        else { return }
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index] = stored
        }
        await reloadConversations()
    }

    // MARK: - Requests

    /// How many decisions are waiting, account-wide.
    ///
    /// Polled with the sync rather than watched, because there is no push for
    /// it and a request is not urgent: somebody who asked to join a group is
    /// content to wait a minute.
    private(set) var pendingRequests = PendingRequests()

    var waitingRequests: Int { pendingRequests.waiting }

    func refreshRequests() async {
        guard isSignedIn else { return }
        guard let latest = try? await api.pendingRequests() else { return }
        pendingRequests = latest
    }

    /// People asking to join one group.
    func joinRequests(for conversation: ConversationID) async -> [JoinRequest] {
        guard case .group(let groupID) = conversation,
              role(in: conversation).canEditGroup
        else { return [] }
        return (try? await api.pendingMemberships(in: groupID)) ?? []
    }

    /// Approve or decline one, and refresh what is left.
    @discardableResult
    func respond(to request: JoinRequest, in conversation: ConversationID, approve: Bool) async -> Bool {
        guard case .group(let groupID) = conversation, let id = request.approvalID
        else { return false }
        do {
            try await api.respond(toMembership: id, in: groupID, approve: approve)
            // An approval adds a member, so the roster is now wrong.
            if approve { await sync.catchUp(conversation) }
            await refreshRequests()
            return true
        } catch {
            log.notice("could not answer a join request: \(diagnosticText(error), privacy: .public)")
            return false
        }
    }

    // MARK: - Group settings

    /// What this account may change about a group.
    ///
    /// Read from the roster rather than assumed. The server enforces it anyway,
    /// so this is about not offering an action that is going to be refused,
    /// which is the same rule the edit window follows.
    func role(in conversation: ConversationID) -> GroupRole {
        guard case .group = conversation, let me = currentUser?.id else { return .member }
        guard let mine = members.first(where: { $0.identity == me }) else { return .member }
        let roles = mine.roles ?? []
        if roles.contains("owner") { return .owner }
        if roles.contains("admin") { return .admin }
        return .member
    }

    nonisolated enum GroupRole: Sendable {
        case owner, admin, member

        /// Renaming a group, changing its picture or its description, and who
        /// may join. The server allows both admins and the owner.
        var canEditGroup: Bool { self != .member }
    }

    /// Your nickname in one group.
    @discardableResult
    func setNickname(_ nickname: String, in conversation: ConversationID) async -> Bool {
        guard case .group(let groupID) = conversation else { return false }
        do {
            try await api.updateMembership(in: groupID, nickname: nickname)
            // The roster is what the transcript draws names from, so it is what
            // has to catch up before the change is visible anywhere.
            await sync.catchUp(conversation)
            return true
        } catch {
            log.notice("could not set nickname: \(diagnosticText(error), privacy: .public)")
            return false
        }
    }

    /// Change the group itself. Refused for a member, before it is sent.
    @discardableResult
    func updateGroup(
        _ conversation: ConversationID,
        name: String? = nil,
        description: String? = nil,
        requiresApproval: Bool? = nil
    ) async -> Bool {
        guard case .group(let groupID) = conversation, role(in: conversation).canEditGroup
        else { return false }
        do {
            guard let updated = try await api.updateGroup(
                groupID, name: name, description: description,
                requiresApproval: requiresApproval)
            else { return true }
            try? await store.conversations.upsert(groups: [updated])
            await reloadConversations()
            return true
        } catch {
            log.notice("could not update group: \(diagnosticText(error), privacy: .public)")
            return false
        }
    }

    /// Replace a group's picture, uploading it first.
    @discardableResult
    func updateGroupPhoto(_ picked: PickedMedia, in conversation: ConversationID) async -> Bool {
        guard case .group(let groupID) = conversation, role(in: conversation).canEditGroup
        else { return false }
        do {
            let media = try await MediaVault.shared.adopt(picked)
            let uploaded = try await uploads.upload(
                media, senderID: currentUser?.id, groupID: groupID, conversationID: nil)
            await MediaVault.shared.remove(media)
            guard let updated = try await api.updateGroup(groupID, imageURL: uploaded.url)
            else { return true }
            try? await store.conversations.upsert(groups: [updated])
            await reloadConversations()
            return true
        } catch {
            log.notice("could not set group photo: \(diagnosticText(error), privacy: .public)")
            return false
        }
    }

    // MARK: - Profile

    /// Change your own name, bio, photo, or postcode.
    ///
    /// The stored identity is replaced with whatever the server says afterwards
    /// rather than with what was asked for: the two differ when a field is
    /// rejected or normalised, and the copy every screen reads should be the
    /// server's.
    @discardableResult
    func updateProfile(
        name: String? = nil, bio: String? = nil, avatarURL: String? = nil,
        zipCode: String? = nil
    ) async -> Bool {
        do {
            guard let updated = try await api.updateProfile(
                name: name, bio: bio, avatarURL: avatarURL, zipCode: zipCode)
            else { return true }
            remember(updated)
            return true
        } catch {
            log.notice("profile update failed: \(diagnosticText(error), privacy: .public)")
            return false
        }
    }

    /// Put a picked photo up and make it the profile picture.
    ///
    /// Two steps because that is what it is: the picture service takes bytes and
    /// hands back a URL, and the profile takes a URL. Reusing the upload path
    /// the composer uses means a profile photo is resized on the way out for the
    /// same reasons a message photo is.
    func updateAvatar(_ picked: PickedMedia) async -> Bool {
        do {
            let media = try await MediaVault.shared.adopt(picked)
            let uploaded = try await uploads.upload(
                media, senderID: currentUser?.id, groupID: nil, conversationID: nil)
            await MediaVault.shared.remove(media)
            return await updateProfile(avatarURL: uploaded.url)
        } catch {
            log.notice("avatar upload failed: \(diagnosticText(error), privacy: .public)")
            return false
        }
    }

    /// Refresh the profile from the server. Used when its screen opens, because
    /// the fields it shows are ones nothing else in the app reads.
    func refreshProfile() async {
        guard let user = try? await api.me() else { return }
        remember(user)
    }

    func setFriendSuggestable(_ suggestable: Bool) async -> Bool {
        do {
            try await api.setFriendSuggestable(suggestable)
            await refreshProfile()
            return true
        } catch {
            log.notice("could not change suggestability: \(diagnosticText(error), privacy: .public)")
            return false
        }
    }

    // MARK: - People

    /// This account's contacts, for the invite screen.
    ///
    /// Not cached. It is read once when a sheet opens, which is rare enough that
    /// a column to keep it in would be a column that is wrong more often than it
    /// is read.
    func contacts() async -> [Relationship] {
        (try? await api.relationships()) ?? []
    }

    /// Add people to a group. True when the server took them.
    ///
    /// The roster is not written here. GroupMe queues the additions behind a
    /// result id, so the membership becomes true a moment later on their side,
    /// and the next roster fetch is what learns it. Writing an optimistic member
    /// row would be claiming something we have not been told.
    func invite(_ people: [GroupMeAPI.AddMemberRequest.Person], to groupID: String) async -> Bool {
        do {
            try await api.addMembers(people, to: groupID)
            // Ask for the roster now rather than at the next open, so the sheet
            // that raised this closes onto a list that is about to be right.
            await sync.catchUp(.group(groupID))
            return true
        } catch {
            log.notice("could not add members: \(diagnosticText(error), privacy: .public)")
            return false
        }
    }

    // MARK: - Reactions

    /// What a tap on a chip or a glyph means.
    ///
    /// GroupMe stores one reaction per person per message, so tapping the glyph
    /// you already hold clears it and tapping a different one swaps it. That
    /// rule is the UI's to make, which is why it lives here rather than in
    /// ``GroupMeAPI/setReaction(_:onMessage:in:replacing:)``.
    func toggleReaction(_ glyph: String, on message: Message) async {
        guard let me = currentUser?.id, let live = live(message) else { return }
        await setReaction(live.reaction(by: me) == glyph ? nil : glyph, on: live)
    }

    /// Put `glyph` on a message, replacing whatever was there.
    func react(to message: Message, with glyph: String) async {
        guard let live = live(message) else { return }
        await setReaction(glyph, on: live)
    }

    /// Take `glyph` off a message, if that is the one we are holding. Passing a
    /// glyph somebody else used is a no-op rather than a surprise.
    func removeReaction(from message: Message, with glyph: String) async {
        guard let me = currentUser?.id, let live = live(message),
              live.reaction(by: me) == glyph
        else { return }
        await setReaction(nil, on: live)
    }

    /// Set this user's reaction on a message to exactly `glyph`.
    ///
    /// Optimistic, in the order that matters:
    ///
    /// 1. The published array, synchronously, before this function ever
    ///    suspends. The chip is drawn on the next frame, which is the whole
    ///    point: a tapback that waits for a round trip is a tapback that feels
    ///    broken.
    /// 2. The database, so a scroll, a reload or a relaunch agrees with what
    ///    was just drawn.
    /// 3. The server, last, and only then.
    ///
    /// What happens at step three depends on which kind of failure it was, and
    /// the two are not close:
    ///
    /// - A failure worth retrying, which is every transport failure and so every
    ///   tap made with the radio off, keeps what was drawn and queues the intent.
    ///   A message written offline is held and delivered on reconnect; a
    ///   reaction tapped in the same tunnel gets the same promise, rather than
    ///   quietly un-tapping itself a second later.
    /// - A failure the server means, which is anything else, rolls both copies
    ///   back. It will not succeed on the tenth attempt either, and leaving the
    ///   chip on screen would be telling the user something untrue.
    ///
    /// The rollback is deliberately to what the user saw before rather than to
    /// what the server now holds: `setReaction` unlikes before it likes, so a
    /// half-failed swap can leave the server empty, and guessing at that would
    /// be inventing state. The next catch-up settles it with the server's own
    /// copy, which is the only authority worth trusting.
    private func setReaction(_ glyph: String?, on message: Message) async {
        guard let conversation = openConversationID, let me = currentUser?.id else { return }
        guard !message.isDeleted, !message.isSystem else { return }

        let previous = message.reaction(by: me)
        guard glyph != previous else { return }

        // What the server holds, which is what an eventual replay has to unlike.
        // A row already queued knows this better than the screen does: the
        // screen has been showing intents the server has never seen.
        let queued = try? await store.pendingReactions.entry(message.id)
        let serverHolds = queued?.previous ?? previous

        apply(glyph, by: me, to: message.id)
        await commit(glyph, by: me, to: message.id, in: conversation)

        do {
            try await api.setReaction(
                glyph, onMessage: message.id, in: conversation, replacing: serverHolds)
            // The server agrees now, so any earlier intent is spent.
            try? await store.pendingReactions.remove(message.id)
        } catch let error as APIError where error.isRetryable {
            log.notice("""
                reaction on \(message.id, privacy: .public) queued: \
                \(diagnosticText(error), privacy: .public)
                """)
            _ = try? await store.pendingReactions.upsert(
                glyph, onMessage: message.id, in: conversation, replacing: serverHolds)
        } catch {
            log.notice("""
                reaction on \(message.id, privacy: .public) refused: \
                \(diagnosticText(error), privacy: .public)
                """)
            try? await store.pendingReactions.remove(message.id)
            apply(serverHolds, by: me, to: message.id)
            await commit(serverHolds, by: me, to: message.id, in: conversation)
        }
    }

    /// Send the reactions that are waiting, in the order they were meant.
    ///
    /// Runs on the same two triggers the outbox drains on, because it is the
    /// same promise: a tap the network refused is held, not lost. Each row is
    /// one call however many times the user tapped, since the queue keeps
    /// intents rather than events.
    private func drainReactions() async {
        guard isSignedIn, let me = currentUser?.id else { return }
        let due = (try? await store.pendingReactions.ready()) ?? []
        guard !due.isEmpty else { return }

        for row in due {
            do {
                try await api.setReaction(
                    row.glyph,
                    onMessage: row.messageID,
                    in: row.conversation,
                    replacing: row.previous,
                    retry: .background)
                try? await store.pendingReactions.remove(row.messageID)
                // The server took it, but a catch-up in between may have
                // written its older copy over ours, so say it once more on
                // disk. Nothing is overlaying this row any longer.
                apply(row.glyph, by: me, to: row.messageID)
                await commit(row.glyph, by: me, to: row.messageID, in: row.conversation)

            } catch let error as APIError where error.isRetryable {
                // Full jitter, clamped, so a reaction queued overnight retries
                // every few minutes rather than drifting out to hours.
                let advised = error.retryAfter ?? 0
                let wait = max(advised, Self.reactionBackoff.delay(forAttempt: min(row.attempts + 1, 8)))
                try? await store.pendingReactions.markFailed(
                    row.messageID, retryAt: Date().addingTimeInterval(max(wait, 1)))
                log.notice("""
                    queued reaction on \(row.messageID, privacy: .public) still waiting: \
                    \(diagnosticText(error), privacy: .public)
                    """)

            } catch {
                // Refused rather than missed. Drop the intent and put the
                // screen back to what the server will actually show.
                try? await store.pendingReactions.remove(row.messageID)
                apply(row.previous, by: me, to: row.messageID)
                await commit(row.previous, by: me, to: row.messageID, in: row.conversation)
                log.error("""
                    queued reaction on \(row.messageID, privacy: .public) rejected: \
                    \(diagnosticText(error), privacy: .public)
                    """)
            }
        }
    }

    /// Outer backoff for a queued reaction, on top of whatever
    /// `RetryPolicy.background` already spent inside the request. Unbounded in
    /// attempts, like the outbox: the intent has nowhere else to be.
    private static let reactionBackoff = RetryPolicy(maxAttempts: .max, base: 2, cap: 300)

    /// Put queued reactions back on top of messages read from disk.
    ///
    /// A catch-up hands back the server's copy of a message, which does not yet
    /// know about a reaction still sitting in the queue. Without this the chip
    /// would blink off on every sync and back on when the queue finally drained.
    /// The queued intent is the newer truth until it is spent, so it wins.
    /// The transcript as it should be drawn: what is on disk, with anything
    /// still queued laid over it. Every read of the open conversation goes
    /// through here, so there is one answer to "what does this look like".
    private func transcript(_ conversation: ConversationID) async -> [Message]? {
        guard let stored = try? await store.messages.recent(conversation, limit: window) else {
            return nil
        }
        return await overlayingPendingReactions(stored, in: conversation)
    }

    private func overlayingPendingReactions(
        _ stored: [Message], in conversation: ConversationID
    ) async -> [Message] {
        guard let me = currentUser?.id,
              let queued = try? await store.pendingReactions.entries(in: conversation),
              !queued.isEmpty
        else { return stored }

        var byID: [String: String?] = [:]
        for row in queued { byID[row.messageID] = row.glyph }
        return stored.map { message in
            guard let glyph = byID[message.id] else { return message }
            return message.settingReaction(glyph, by: me)
        }
    }

    /// Write the reaction to disk, then adopt the row the store hands back.
    ///
    /// Adopting it matters: a coalesced reload can read the transcript in the
    /// window between the optimistic edit and this write landing, which would
    /// put the chip back the way it was. The store's answer is the same message
    /// with the edit already in it, so replaying it here settles that race
    /// instead of leaving the screen a revision behind.
    private func commit(
        _ glyph: String?, by userID: String, to messageID: String, in conversation: ConversationID
    ) async {
        guard let stored = try? await store.messages.setReaction(
            glyph, by: userID, onMessage: messageID, in: conversation) else { return }
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index] = stored
    }

    /// The transcript's copy of a message, which is the one worth acting on.
    ///
    /// The view hands back whatever it drew, and a push may have landed since.
    /// A miss means the row is a queued send with no server id yet, or the
    /// conversation moved on, and either way there is nothing to react to.
    private func live(_ message: Message) -> Message? {
        messages.first { $0.id == message.id }
    }

    /// Rewrite one message in the published array. A miss is normal: the
    /// conversation may have been closed, or the message scrolled out of the
    /// window, while the request was in the air.
    private func apply(_ glyph: String?, by userID: String, to messageID: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index] = messages[index].settingReaction(glyph, by: userID)
    }

    // MARK: - Session

    /// Adopt a token and prove it works.
    ///
    /// A rejected token is discarded and reported through `syncState.lastError`,
    /// which is where every other network failure already shows up. A token that
    /// simply could not be checked, because the phone is offline, is kept: the
    /// user typed something plausible and the next successful request settles it.
    func signIn(token: String) async {
        await tokens.save(token)
        session = .signedIn
        syncState.lastError = nil

        do {
            let user = try await api.me()
            remember(user)
            await adopt(user)
            await sends.credentialsDidChange()
            await sync.sync(reason: .signIn)
        } catch let error as APIError where error.status == 401 || error.status == 403 {
            await tokens.clear()
            session = .signedOut
            syncState.phase = .failed
            syncState.lastError = "That token was refused."
            log.error("sign-in refused")
        } catch {
            syncState.phase = .failed
            syncState.lastError = "Could not reach GroupMe. Trying again shortly."
            log.error("sign-in could not be verified: \(error)")
        }
    }

    /// Sign out and leave nothing behind. Deleting a conversation cascades to its
    /// messages and members, and the queue goes with it: an unsent message
    /// belongs to the session that wrote it.
    func signOut() async {
        await bayeux.stop()
        await tokens.clear()
        typingSweep?.cancel()
        typingSweep = nil

        try? await store.pendingReactions.removeAll()
        let rows = (try? await store.conversations.list(limit: 5000)) ?? []
        for row in rows {
            try? await store.outbox.removeAll(in: row.id)
            try? await store.conversations.delete(row.id)
        }
        UserDefaults.standard.removeObject(forKey: Self.currentUserKey)
        await previews.clear()
        // The queue went with the conversations, so its files go too. An unsent
        // photo belongs to the session that picked it.
        await MediaVault.shared.removeAll()

        session = .signedOut
        currentUser = nil
        conversations = []
        messages = []
        outbox = []
        uploadProgress = [:]
        members = []
        typingUserIDs = [:]
        openConversationID = nil
        totalUnread = 0
        syncState = SyncState(isOnline: realtime.reachability != .offline)
        attemptedHeals = []
        await sync.forgetTips()
    }

    // MARK: - Cache

    /// Throw away everything that can be fetched again, and fetch it again.
    ///
    /// Deliberately not a sign-out. The token, the identity and above all the
    /// outbox stay: a queued message is something the user wrote, and no server
    /// can give it back. The outbox table carries no foreign key to
    /// `conversations` precisely so that it survives this.
    ///
    /// What goes is history, rosters, sync cursors and link previews, which is
    /// to say every row whose only author is the server. The list comes back on
    /// the sync that follows; the open transcript comes back on its catch-up.
    func clearCache() async {
        let rows = (try? await store.conversations.list(limit: 5000)) ?? []
        for row in rows { try? await store.conversations.delete(row.id) }
        await previews.clear()
        // The pictures, which are the bulk of it. Everything above is rows in a
        // database and measures in kilobytes; a month of photographs measures in
        // hundreds of megabytes and lives in `URLCache`.
        await ImageLoader.shared.clear()
        // The tips are a memory of what the list said a moment ago, and every
        // head they name has just been deleted. Left in place they would make
        // the next list read as "advanced by one" and write a placeholder over
        // the hole instead of paging it back in.
        await sync.forgetTips()

        conversations = []
        messages = []
        members = []
        totalUnread = 0
        window = Self.transcriptPage
        reachedBeginning = false
        olderPageFailed = false
        attemptedHeals = []

        guard isSignedIn else { return }
        await sync.sync(reason: .manual)
        if let open = openConversationID { await sync.catchUp(open) }
        await reloadConversations()
        await reloadMessages()
    }

    // MARK: - Identity

    private func restoreIdentity() {
        guard let data = UserDefaults.standard.data(forKey: Self.currentUserKey),
              let user = try? JSONDecoder().decode(CurrentUser.self, from: data)
        else { return }
        currentUser = user
    }

    private func remember(_ user: CurrentUser) {
        currentUser = user
        if let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: Self.currentUserKey)
        }
    }

    /// Hand our user id to everything that addresses DMs with it, and open the
    /// socket.
    private func adopt(_ user: CurrentUser) async {
        await api.adopt(currentUserID: user.id)
        await sync.adopt(currentUserID: user.id)
        await bayeux.start(as: user.id)
    }

    private func refreshIdentity() async {
        guard let user = try? await api.me() else { return }
        let changed = user.id != currentUser?.id
        remember(user)
        if changed { await adopt(user) }
    }

    // MARK: - Observation

    private func startObserving() {
        let sync = sync, sends = sends, bayeux = bayeux, realtime = realtime

        observers.append(Task { [weak self] in
            for await change in sync.changes {
                guard let self else { return }
                await self.apply(change)
            }
        })

        observers.append(Task { [weak self] in
            for await conversation in sends.changes {
                guard let self else { return }
                await self.outboxDidChange(conversation)
            }
        })

        // The one consumer of the realtime stream. The monitor gets what it
        // needs for the UI, the sync engine gets everything that is a store
        // write, and typing stays here because it is the one thing that never
        // touches the database.
        observers.append(Task { [weak self] in
            for await event in bayeux.events {
                realtime.observe(event)
                await sync.apply(event)
                self?.handleLocally(event)
            }
        })

        observers.append(Task { [weak self] in
            for await reachability in realtime.reachabilityChanges {
                guard let self else { return }
                self.syncState.isOnline = reachability != .offline
                guard reachability == .online, self.isSignedIn else { continue }
                // The queue first: a message the user wrote while offline should
                // beat a refresh of things other people wrote.
                await sends.connectivityDidReturn()
                await self.drainReactions()
                await sync.sync(reason: .reconnect)
            }
        })
    }

    private func apply(_ change: SyncChange) async {
        switch change {
        case .state(let state):
            var state = state
            state.isOnline = realtime.reachability != .offline
            syncState = state
        case .conversations:
            scheduleReload(conversations: true, messages: false)
        case .messages(let conversation):
            scheduleReload(conversations: true, messages: conversation == openConversationID)
        }
    }

    /// A fortieth of the way, which for anything big enough to have a visible
    /// upload is a report every few hundred milliseconds.
    ///
    /// This used to be a tenth, back when a report rebuilt the whole transcript
    /// and the coalescing was protecting against that. It is not any more: the
    /// ring reads this dictionary itself, so a report redraws one circle. The
    /// only thing left to balance is smoothness against arithmetic, and ten
    /// steps across a minute-long video upload is not motion, it is a slideshow.
    private func noteUploadProgress(_ guid: String, _ fraction: Double) {
        let previous = uploadProgress[guid] ?? 0
        guard fraction >= 1 || fraction - previous >= 0.025 else { return }
        uploadProgress[guid] = fraction
    }

    private func outboxDidChange(_ conversation: ConversationID) async {
        scheduleReload(conversations: true, messages: conversation == openConversationID)
    }

    /// The parts of a realtime event the UI owns rather than the database.
    private func handleLocally(_ event: RealtimeEvent) {
        guard case .push(let push) = event, case .typing(let typing) = push.kind else { return }
        guard push.channel == openConversationChannel, typing.userID != currentUser?.id else { return }
        // Stamped with our clock rather than the sender's. `started` comes off
        // somebody else's phone, and a device a couple of seconds out would
        // otherwise show an indicator that either never appears or never leaves.
        typingUserIDs[typing.userID] = Date()
        scheduleTypingSweep()
    }

    /// Indicators die by timeout: there is no "stopped typing" frame on the
    /// wire. Nothing else will wake us once the last event lands, so each event
    /// schedules its own expiry.
    private func scheduleTypingSweep() {
        typingSweep?.cancel()
        typingSweep = Task { [weak self] in
            try? await Task.sleep(for: .seconds(PushEvent.Typing.expiry))
            guard !Task.isCancelled else { return }
            self?.sweepTyping()
        }
    }

    private func sweepTyping() {
        let now = Date()
        typingUserIDs = typingUserIDs.filter { now.timeIntervalSince($0.value) < PushEvent.Typing.expiry }
        if !typingUserIDs.isEmpty { scheduleTypingSweep() }
    }

    /// Who is typing, by the name this conversation knows them by.
    ///
    /// Empty when nobody is, and also when we hold no roster for them, which is
    /// the normal case in a DM. The view says "Typing…" rather than guessing.
    var typingNames: [String] { typingPeople.map(\.name) }

    /// Who is typing, with the face to draw for each.
    ///
    /// Only people the roster knows. A DM carries no membership, and an id with
    /// no name is a face nobody would recognise anyway, so those are dropped
    /// rather than drawn as a grey circle: the dots alone already say somebody
    /// is typing.
    var typingPeople: [TypingPerson] {
        guard !typingUserIDs.isEmpty else { return [] }
        let byID = Dictionary(
            members.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        return typingUserIDs.keys.compactMap { id -> TypingPerson? in
            guard let member = byID[id], let name = member.nickname ?? member.name
            else { return nil }
            return TypingPerson(id: id, name: name, imageURL: member.imageUrl)
        }
        .sorted { $0.name < $1.name }
    }

    var isAnyoneTyping: Bool { !typingUserIDs.isEmpty }

    private var openConversationChannel: String? {
        guard let openConversationID, let me = currentUser?.id else { return nil }
        return openConversationID.pushChannel(myUserID: me)
    }

    // MARK: - Reloading

    /// Coalesced reload. A 200-message catch-up writes many times in a second and
    /// the list only needs to be right once, so writes are collected and applied
    /// on one pass instead of redrawing per page.
    private func scheduleReload(conversations: Bool, messages: Bool) {
        needsConversationReload = needsConversationReload || conversations
        needsMessageReload = needsMessageReload || messages
        guard reloadTask == nil else { return }
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            self.reloadTask = nil
            await self.performReload()
        }
    }

    private func performReload() async {
        if needsConversationReload {
            needsConversationReload = false
            await reloadConversations()
        }
        if needsMessageReload {
            needsMessageReload = false
            await reloadMessages()
        }
    }

    private func reloadConversations() async {
        if let rows = try? await store.conversations.list() { conversations = rows }
        followTopics()
        if let unread = try? await store.conversations.totalUnread() { totalUnread = unread }
        // The roster arrives on the same notification the list does, because a
        // group fetch writes both. Re-reading it here is what lets an open
        // conversation pick up its members without a second signal.
        if let open = openConversationID,
           let roster = try? await store.conversations.members(of: open) {
            members = roster
        }
    }

    private func reloadMessages() async {
        guard let conversation = openConversationID else { return }
        if let stored = await transcript(conversation) { messages = stored }
        outbox = await sends.pending(in: conversation)
        // A send that has left the queue has no progress worth remembering, and
        // this is the one place that reliably learns it went.
        let queued = Set(outbox.map(\.sourceGuid))
        uploadProgress = uploadProgress.filter { queued.contains($0.key) }
        healPlaceholders()
        resolveQuotes()
    }

    /// Fetch the originals behind any quote we cannot already draw.
    ///
    /// Replies are common enough to matter: a sample of a hundred recent
    /// messages across a dozen groups held twenty-nine of them. Most answer
    /// something near at hand, which costs nothing here because it is already
    /// loaded; the rest answer something older, and one small request turns
    /// "Loading…" into the message the sender was pointing at.
    ///
    /// Bounded, because a page of history could in principle be replies to a
    /// page of *different* old messages, and eighty requests to decorate one
    /// screen is not a trade worth making.
    private func resolveQuotes() {
        guard let conversation = openConversationID else { return }
        let have = Set(messages.map(\.id))
        let wanted = Set(messages.compactMap(\.replyTargetID))
            .subtracting(have)
            .subtracting(attemptedQuotes)
        guard !wanted.isEmpty else { return }

        let batch = Array(wanted.prefix(Self.maxQuoteFetches))
        attemptedQuotes.formUnion(batch)
        Task { [api] in
            for id in batch {
                let parent = try? await api.message(id: id, in: conversation)
                guard conversation == self.openConversationID else { return }
                if let parent {
                    self.quotedParents[id] = parent
                } else {
                    // Say so rather than leaving the quote spinning.
                    self.unresolvedQuotes.insert(id)
                }
            }
        }
    }

    private static let maxQuoteFetches = 12

    /// Replace any list-preview placeholder on screen with the server's copy.
    ///
    /// A group's list preview carries the text and the nickname but no sender
    /// id, and ``SyncEngine`` writes one as a stand-in when the list proves a
    /// conversation moved by exactly one message. That saves a request, and it
    /// costs the one field the transcript needs to know whose bubble this is: a
    /// message you sent from another device arrives unattributed and draws as
    /// somebody else's.
    ///
    /// Opening a conversation already heals it, because ``SyncEngine/catchUp(_:)``
    /// anchors behind a placeholder head. The gap is the conversation that was
    /// *already* open when the stand-in landed, which is exactly the case where
    /// the wrong bubble is being looked at. So the fetch is paid here, only when
    /// a placeholder is actually on screen.
    private func healPlaceholders() {
        guard let conversation = openConversationID else { return }
        let unresolved = messages.filter { $0.isListPreview && !attemptedHeals.contains($0.id) }
        guard !unresolved.isEmpty else { return }
        attemptedHeals.formUnion(unresolved.map(\.id))
        Task { await self.sync.catchUp(conversation) }
    }
}


/// One person mid-sentence, for the indicator at the foot of a transcript.
nonisolated struct TypingPerson: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let imageURL: String?
}
