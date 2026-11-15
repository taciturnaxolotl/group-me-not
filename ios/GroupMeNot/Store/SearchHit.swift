import Foundation

/// One stored message matching a search, with the matched words marked in `snippet`.
nonisolated struct SearchHit: Identifiable, Hashable, Sendable {
    var conversation: ConversationID
    var message: Message
    /// The matching stretch of text, each match wrapped in ``matchStart`` and ``matchEnd``.
    var snippet: String

    var id: String { "\(conversation.storageKey)/\(message.id)" }

    static let matchStart: Character = "\u{2}"
    static let matchEnd: Character = "\u{3}"

    /// Every word as a quoted prefix term, so punctuation in the query cannot become FTS syntax.
    static func ftsQuery(_ text: String) -> String? {
        let terms = text.split(whereSeparator: \.isWhitespace)
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
        return terms.isEmpty ? nil : terms.joined(separator: " ")
    }
}

/// One conversation's stored history, for the info sheet.
nonisolated struct ConversationStorage: Hashable, Sendable {
    var messages: Int
    /// Message rows plus their search index text; images live in the shared cache and are not counted.
    var bytes: Int
    var isComplete: Bool
}
