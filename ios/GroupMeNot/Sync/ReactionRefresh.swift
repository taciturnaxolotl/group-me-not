import Foundation
import OSLog

/// Keeps the reactions on the open transcript current.
///
/// `after_id` never revisits a message and Faye replays nothing, so a reaction
/// made while the socket was down never reaches a message we already hold.
/// While the socket is up, though, every change arrives live. So the only copies
/// worth asking about again are the ones fetched before it last came back.
///
/// One mark per conversation records how far down that is already done: every
/// message from its floor to the newest was fetched since the socket came back.
/// A refresh extends the mark downward one `before_id` page at a time.
actor ReactionRefresh {
    /// How far down a conversation's reactions are known to be current.
    enum Floor: Equatable {
        /// Every message, back to the first.
        case beginning
        /// This message and everything newer.
        case message(String)

        func covers(_ id: String) -> Bool {
            switch self {
            case .beginning: true
            case .message(let floor): !Message.isNewer(floor, than: id)
            }
        }
    }

    /// Pages one refresh may spend. A transcript window is two pages at most.
    static let maxPages = 5

    private let api: GroupMeAPI
    private let store: Store
    private let changes: AsyncStream<SyncChange>.Continuation
    private let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "reactions")

    /// When the socket last came back. A cold start counts, so it starts at now.
    private var liveSince = Date()
    private var floors: [ConversationID: Floor] = [:]
    /// The one refresh allowed to run, and how far down it has been asked to go.
    private var run: (id: Int, conversation: ConversationID, target: String)?
    private var nextRunID = 0

    init(api: GroupMeAPI, store: Store, changes: AsyncStream<SyncChange>.Continuation) {
        self.api = api
        self.store = store
        self.changes = changes
    }

    /// The socket is back after a gap, so every mark is void.
    func wentLive() {
        liveSince = Date()
        floors = [:]
        changes.yield(.reactionsStale)
    }

    /// Make reactions current from the newest message down to `oldest`.
    ///
    /// One run at a time, for the conversation on screen. A call for the same
    /// conversation while one runs only deepens its target; a call for another
    /// conversation takes over.
    func refresh(downTo oldest: String, in conversation: ConversationID) async {
        if let current = run, current.conversation == conversation {
            if Message.isNewer(current.target, than: oldest) { run?.target = oldest }
            return
        }
        nextRunID += 1
        let id = nextRunID
        run = (id, conversation, oldest)
        defer { if run?.id == id { run = nil } }

        for _ in 0..<Self.maxPages {
            guard let current = run, current.id == id else { return }
            let floor = floors[conversation]
            if floor?.covers(current.target) == true { return }
            guard await fetchPage(below: floor, in: conversation) else { return }
        }
    }

    /// Stop the refresh for a conversation that has closed.
    func stop(_ conversation: ConversationID) {
        if run?.conversation == conversation { run = nil }
    }

    /// Replace one stored message with the server's copy, for a reaction frame
    /// that named a message but not what happened to it.
    func refetch(_ messageID: String, in conversation: ConversationID) async {
        do {
            guard try await store.messages.message(id: messageID, in: conversation) != nil else { return }
            let asOf = Date()
            guard let message = try await api.message(id: messageID, in: conversation) else { return }
            try await store.messages.upsert(message, in: conversation, asOf: asOf)
            changes.yield(.messages(conversation))
        } catch {
            log.notice("could not refetch \(messageID, privacy: .public): \(diagnosticText(error), privacy: .public)")
        }
    }

    /// One page below `floor`, or the newest page when there is no floor yet.
    /// Returns whether another page is worth asking for.
    private func fetchPage(below floor: Floor?, in conversation: ConversationID) async -> Bool {
        let anchor: String?
        switch floor {
        case nil: anchor = nil
        case .beginning: return false
        case .message(let id): anchor = id
        }
        let asOf = Date()
        let page: [Message]
        do {
            page = try await api.messages(in: conversation, before: anchor, retry: .background)
            try await store.messages.upsert(page, in: conversation, asOf: asOf)
        } catch {
            log.notice("reaction refresh for \(conversation.storageKey, privacy: .public) stopped: \(diagnosticText(error), privacy: .public)")
            return false
        }
        if !page.isEmpty { changes.yield(.messages(conversation)) }
        // A page asked for before the socket last came back may already be out
        // of date, so it cannot extend the mark.
        guard asOf >= liveSince else { return false }

        let oldest = page.min { Message.isNewer($1.id, than: $0.id) }?.id
        if page.count < GroupMeAPI.maxMessagesPerPage || oldest == nil {
            floors[conversation] = .beginning
        } else if let oldest {
            floors[conversation] = .message(oldest)
        }
        return true
    }
}
