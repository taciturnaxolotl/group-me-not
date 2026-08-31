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
    private(set) var openConversationID: ConversationID?
    private(set) var members: [Member] = []

    private(set) var currentUser: CurrentUser?
    private(set) var isSignedIn = false
    private(set) var syncState = SyncState()
    private(set) var totalUnread = 0
    /// Who is typing in the open conversation, and when we last heard from them.
    /// Expired entries are swept on each new event; see `PushEvent.Typing.expiry`.
    private(set) var typingUserIDs: [String: Date] = [:]

    /// Network and socket state, for the offline banner.
    let realtime = RealtimeMonitor()

    /// The glyphs the reaction picker offers.
    ///
    /// A constant today. The official client refreshes this from a CDN
    /// document, but a picker must never be empty because a request has not
    /// come back, so the local list is the source and a refresh would only ever
    /// be an improvement on it.
    let reactionCatalog = ReactionCatalog.default

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
    @ObservationIgnored private var reachedBeginning = false
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
        let outbox = Outbox(api: api, store: resolved)

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

        realtime.start()
        realtime.attach(to: bayeux)
        startObserving()

        await sends.onNeedsReconcile { [sync] conversation in
            await sync.catchUp(conversation)
        }

        // 1. The screen, from disk. This is the part that must never wait.
        restoreIdentity()
        await reloadConversations()
        isSignedIn = await tokens.isSignedIn

        guard isSignedIn else { return }

        // 2. Everything else, in the background.
        if let user = currentUser {
            await adopt(user)
        }
        Task { await self.sends.drain() }
        Task { await self.sync.sync(reason: .launch) }
        Task { await self.refreshIdentity() }
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
    }

    // MARK: - Conversations

    /// Open a conversation. The transcript is on screen before this returns; the
    /// catch-up that follows is decoration.
    func openConversation(_ conversation: ConversationID) async {
        openConversationID = conversation
        window = Self.transcriptPage
        typingSweep?.cancel()
        typingUserIDs = [:]

        messages = (try? await store.messages.recent(conversation, limit: window)) ?? []
        outbox = await sends.pending(in: conversation)
        members = (try? await store.conversations.members(of: conversation)) ?? []

        reachedBeginning = false
        await markRead(conversation)
        await bayeux.focus(on: conversation)
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
        Task { [bayeux] in await bayeux.focus(on: nil) }
    }

    /// Whether scrolling up can turn up anything more. Goes false once a request
    /// for older messages comes back with nothing from either disk or the server,
    /// which is the only honest way to know: no endpoint reports a total.
    var canLoadOlder: Bool { !reachedBeginning && !messages.isEmpty }

    /// Page backwards. Local history first; the network only when we run out.
    func loadOlder() async {
        guard let conversation = openConversationID, !reachedBeginning else { return }
        let oldest = messages.first?.id
        window += Self.transcriptPage

        if let stored = try? await store.messages.recent(conversation, limit: window),
           stored.count > messages.count {
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
            log.notice("could not page back in \(conversation.storageKey, privacy: .public): \(failureText(error), privacy: .public)")
            return
        }

        guard !page.isEmpty else {
            reachedBeginning = true
            return
        }
        _ = try? await store.messages.upsert(page, in: conversation)
        messages = (try? await store.messages.recent(conversation, limit: window)) ?? messages
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
    func send(_ text: String) async {
        guard let conversation = openConversationID else { return }
        await send(text: text, to: conversation)
    }

    /// Queue a message. Returns as soon as it is durable, which is immediately.
    func send(text: String, to conversation: ConversationID) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await sends.send(text: trimmed, to: conversation)
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

    /// Publish a typing notice. Throttled inside the socket client, so calling
    /// this on every keystroke is fine.
    func userIsTyping() async {
        guard let conversation = openConversationID else { return }
        await bayeux.sendTyping(in: conversation)
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
    /// A failure at step three puts both local copies back. The rollback is
    /// deliberately to what the user saw before rather than to what the server
    /// now holds: `setReaction` unlikes before it likes, so a half-failed swap
    /// can leave the server empty, and guessing at that would be inventing
    /// state. The next catch-up settles it with the server's own copy, which is
    /// the only authority worth trusting.
    private func setReaction(_ glyph: String?, on message: Message) async {
        guard let conversation = openConversationID, let me = currentUser?.id else { return }
        guard !message.isDeleted, !message.isSystem else { return }

        let previous = message.reaction(by: me)
        guard glyph != previous else { return }

        apply(glyph, by: me, to: message.id)
        await commit(glyph, by: me, to: message.id, in: conversation)

        do {
            try await api.setReaction(
                glyph, onMessage: message.id, in: conversation, replacing: previous)
        } catch {
            log.notice("""
                reaction on \(message.id, privacy: .public) did not stick: \
                \(failureText(error), privacy: .public)
                """)
            apply(previous, by: me, to: message.id)
            await commit(previous, by: me, to: message.id, in: conversation)
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
        isSignedIn = true
        syncState.lastError = nil

        do {
            let user = try await api.me()
            remember(user)
            await adopt(user)
            await sends.credentialsDidChange()
            await sync.sync(reason: .signIn)
        } catch let error as APIError where error.status == 401 || error.status == 403 {
            await tokens.clear()
            isSignedIn = false
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

        let rows = (try? await store.conversations.list(limit: 5000)) ?? []
        for row in rows {
            try? await store.outbox.removeAll(in: row.id)
            try? await store.conversations.delete(row.id)
        }
        UserDefaults.standard.removeObject(forKey: Self.currentUserKey)
        await previews.clear()

        isSignedIn = false
        currentUser = nil
        conversations = []
        messages = []
        outbox = []
        members = []
        typingUserIDs = [:]
        openConversationID = nil
        totalUnread = 0
        syncState = SyncState(isOnline: realtime.reachability != .offline)
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
    var typingNames: [String] {
        guard !typingUserIDs.isEmpty else { return [] }
        var names: [String: String] = [:]
        for member in members {
            if let name = member.nickname ?? member.name { names[member.identity] = name }
        }
        return typingUserIDs.keys.compactMap { names[$0] }.sorted()
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
        if let stored = try? await store.messages.recent(conversation, limit: window) {
            messages = stored
        }
        outbox = await sends.pending(in: conversation)
    }
}
