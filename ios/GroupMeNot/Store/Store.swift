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

    /// Everything this app is keeping on disk, in bytes.
    ///
    /// Three places, because there are three: the database and its write-ahead
    /// log, the vault holding attachments waiting to be sent, and `URLCache`,
    /// which is where every photo actually lives once it has been fetched. The
    /// last is much the largest and is the one a person means when they ask how
    /// much room this app is using.
    ///
    /// Measured rather than tracked. A running total is a number that drifts;
    /// this is asked for once, when a screen that shows it appears.
    static func diskUsage(of file: DatabaseFile) -> Int64 {
        var total: Int64 = 0
        // SQLite in WAL mode is three files, and the log is routinely the
        // biggest of them right after a sync.
        for suffix in ["", "-wal", "-shm"] {
            total += size(ofFileAt: URL(fileURLWithPath: file.path + suffix))
        }
        total += size(ofDirectoryAt: MediaVault.directory)
        total += Int64(URLCache.shared.currentDiskUsage)
        return total
    }

    private static func size(ofFileAt url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func size(ofDirectoryAt url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        else { return 0 }
        var total: Int64 = 0
        for case let item as URL in walker { total += size(ofFileAt: item) }
        return total
    }

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
