import SwiftUI

// MARK: - In a conversation

/// Searches one conversation's stored messages. Pushed inside the info sheet, which closes on a pick.
struct MessageSearchView: View {
    let conversation: ConversationID
    let onOpen: (String) -> Void

    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searchedBackTo: Date?

    var body: some View {
        List {
            ForEach(hits) { hit in
                Button { onOpen(hit.message.id) } label: { SearchHitRow(hit: hit) }
                    .buttonStyle(.plain)
            }
            if let searchedBackTo, !query.isEmpty {
                Text("Searched messages back to \(searchedBackTo.formatted(date: .abbreviated, time: .omitted)). "
                     + "Older history is still downloading.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay {
            if !query.isEmpty, hits.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search this conversation")
        .task(id: query) {
            hits = await debouncedSearch(query, in: conversation, model: model)
            searchedBackTo = await model.searchedBackTo(conversation)
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Across conversations

/// Message matches shown under the conversation list's own search results.
struct MessageSearchSection: View {
    let query: String
    let onOpen: (SearchHit) -> Void

    @Environment(AppModel.self) private var model
    @State private var hits: [SearchHit] = []

    var body: some View {
        Section {
            ForEach(hits) { hit in
                Button { onOpen(hit) } label: {
                    SearchHitRow(hit: hit, conversationName: name(of: hit.conversation))
                }
                .buttonStyle(.plain)
            }
        } header: {
            if !hits.isEmpty { Text("Messages") }
        }
        .task(id: query) {
            hits = await debouncedSearch(query, in: nil, model: model)
        }
    }

    private func name(of conversation: ConversationID) -> String? {
        model.conversations.first { $0.id == conversation }?.name
    }
}

// MARK: - Shared

/// Waits out fast typing so each keystroke does not run its own query.
@MainActor
private func debouncedSearch(_ query: String, in conversation: ConversationID?, model: AppModel) async -> [SearchHit] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return [] }
    try? await Task.sleep(for: .milliseconds(200))
    guard !Task.isCancelled else { return [] }
    return await model.search(trimmed, in: conversation)
}

/// One matching message: who, when, and the matching text with its matches in bold.
struct SearchHitRow: View {
    let hit: SearchHit
    var conversationName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(heading)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(Formatters.listTimestamp(hit.message.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(Self.highlighted(hit.snippet))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }

    private var heading: String {
        let sender = hit.message.name ?? "Someone"
        guard let conversationName else { return sender }
        return "\(sender) in \(conversationName)"
    }

    /// Turns the store's match markers into bold, primary-coloured runs.
    static func highlighted(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var isMatch = false
        var run = ""
        func flush() {
            var piece = AttributedString(run)
            if isMatch {
                piece.font = .subheadline.weight(.semibold)
                piece.foregroundColor = .primary
            }
            result += piece
            run = ""
        }
        for character in snippet {
            if character == SearchHit.matchStart || character == SearchHit.matchEnd {
                flush()
                isMatch = character == SearchHit.matchStart
            } else {
                run.append(character)
            }
        }
        flush()
        return result
    }
}
