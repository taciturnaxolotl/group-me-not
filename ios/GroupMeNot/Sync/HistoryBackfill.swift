import Foundation
import os

/// Downloads a conversation's history, oldest page at a time, until it reaches the first message.
///
/// It only writes the store; the transcript reads those pages back when the reader scrolls to them,
/// and search finds them as soon as they land.
actor HistoryBackfill {
    private let api: GroupMeAPI
    private let store: Store
    private let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "backfill")
    private var running: (conversation: ConversationID, task: Task<Void, Never>)?

    /// A pause between pages, so a long history never competes with real requests or trips rate limits.
    private static let pause: Duration = .seconds(1)
    private static let retryAfterFailure: Duration = .seconds(30)

    init(api: GroupMeAPI, store: Store) {
        self.api = api
        self.store = store
    }

    func start(_ conversation: ConversationID) {
        if running?.conversation == conversation { return }
        running?.task.cancel()
        running = (conversation, Task { await self.run(conversation) })
    }

    func stop() {
        running?.task.cancel()
        running = nil
    }

    private func run(_ conversation: ConversationID) async {
        defer { if running?.conversation == conversation { running = nil } }
        while !Task.isCancelled {
            guard (try? await store.conversations.historyComplete(conversation)) == false,
                  let oldest = try? await store.messages.oldestID(in: conversation)
            else { return }

            let asOf = Date()
            do {
                let page = try await api.messages(in: conversation, before: oldest, retry: .background)
                guard !page.isEmpty else {
                    try await store.conversations.markHistoryComplete(conversation)
                    log.notice("history complete for \(conversation.storageKey, privacy: .public)")
                    return
                }
                try await store.messages.upsert(page, in: conversation, asOf: asOf)
                try await Task.sleep(for: Self.pause)
            } catch is CancellationError {
                return
            } catch {
                log.notice("backfill paused in \(conversation.storageKey, privacy: .public): \(error)")
                try? await Task.sleep(for: Self.retryAfterFailure)
            }
        }
    }
}
