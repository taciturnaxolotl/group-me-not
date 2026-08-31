import Foundation

/// The stores over one database file.
///
/// A convenience, not a requirement: each store opens its own connection and
/// works perfectly well alone. Bundling them just saves passing them around
/// separately, and guarantees they agree on which file they are talking to.
///
/// Every store here is an actor, so this is a `Sendable` value you can hand to
/// anything.
nonisolated struct Store: Sendable {
    let file: DatabaseFile
    let conversations: ConversationStore
    let messages: MessageStore
    let outbox: OutboxStore
    let pendingReactions: PendingReactionStore

    init(_ file: DatabaseFile) throws {
        self.file = file
        // The first `open` runs the migration; the others find it already done.
        self.conversations = try ConversationStore(file)
        self.messages = try MessageStore(file)
        self.outbox = try OutboxStore(file)
        self.pendingReactions = try PendingReactionStore(file)
    }

    /// The on-device store, in Application Support and excluded from backup.
    static func onDisk() throws -> Store {
        try Store(.applicationSupport())
    }

    /// An isolated store for tests and previews.
    static func ephemeral() throws -> Store {
        try Store(.inMemory(named: "store-\(UUID().uuidString)"))
    }
}
