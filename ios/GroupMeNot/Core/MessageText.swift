import Foundation

// GroupMe's wire format carries no markup. There is no markdown, no bold, no
// italic, nothing to escape. A message is a plain string plus two side channels:
// a `mentions` attachment holding UTF-16 offsets into that string, and whatever
// links a detector can find. So "formatting" here means exactly three things:
// links, mentions, and the fact that a message of nothing but emoji wants to be
// drawn large. Anything richer would be invented, and inventing wire formats is
// how clients start disagreeing with the server.

// MARK: - Custom attributes

/// The user id behind a mention run, so a view can style mentions (and make
/// them tappable) without re-deriving where they are.
///
/// A custom attribute rather than a colour: `MessageText` is pure Foundation
/// and has no opinion about the palette. The view walks
/// `runs[\.mentionUserID]` and paints.
nonisolated enum MentionUserIDAttribute: AttributedStringKey {
    typealias Value = String
    static let name = "sh.dunkirk.GroupMeNot.mentionUserID"
}

nonisolated extension AttributeScopes {
    nonisolated struct GroupMeNotAttributes: AttributeScope {
        let mentionUserID: MentionUserIDAttribute
    }

    var groupMeNot: GroupMeNotAttributes.Type { GroupMeNotAttributes.self }
}

nonisolated extension AttributeDynamicLookup {
    subscript<T: AttributedStringKey>(
        dynamicMember keyPath: KeyPath<AttributeScopes.GroupMeNotAttributes, T>
    ) -> T { self[T.self] }
}

// MARK: - Result

/// A message's text, ready to draw.
///
/// Built once when the transcript row is built, never in a `body`. Everything
/// the view needs to decide layout (is this one giant emoji? is there a link
/// worth a preview card?) is answered here, so the view only renders.
nonisolated struct MessageText: Hashable, Sendable {
    /// The text with `.link` on URLs and `\.mentionUserID` on mentions.
    var attributed: AttributedString
    /// The original string, unchanged. Handy for copy and for VoiceOver.
    var plain: String
    /// Every URL found, in reading order, deduplicated.
    ///
    /// A preview card is worth showing for the first one. Beyond that the
    /// message is a link dump and cards stop helping.
    var links: [URL]
    /// True when the message is a handful of emoji and nothing else, which is
    /// the one case that renders bigger and without a bubble tint.
    var isEmojiOnly: Bool
    /// How many, when it is. Counted in grapheme clusters, so a face with a
    /// skin tone and a gender is one emoji rather than four scalars.
    var emojiCount: Int = 0

    var isEmpty: Bool { plain.isEmpty }

    /// The link a preview card should describe, if any.
    var previewLink: URL? { links.first }

    static let empty = MessageText(
        attributed: AttributedString(), plain: "", links: [], isEmojiOnly: false)
}

// MARK: - Parsing

nonisolated enum MessageTextParser {

    /// More emoji than this and it is a wall, not an exclamation, so it stays
    /// at body size.
    static let emojiOnlyLimit = 8

    /// Turn a message into styled runs. Pure, cheap, and safe to call off the
    /// main actor.
    static func parse(_ message: Message) -> MessageText {
        parse(text: message.visibleText ?? "", attachments: message.attachments ?? [])
    }

    /// The same, for text that is not attached to a stored `Message` yet: an
    /// outbox draft, a conversation-list preview.
    static func parse(text: String, attachments: [Message.Attachment] = []) -> MessageText {
        guard !text.isEmpty else { return .empty }

        var attributed = AttributedString(text)
        var links: [URL] = []
        let count = emojiCount(text)

        // Links first. A mention never contains a URL, so ordering only matters
        // for the pathological case of a link inside a display name, where the
        // mention should win and does, being applied second.
        for match in detectLinks(in: text) {
            guard let range = attributedRange(utf16Offset: match.range.location,
                                              length: match.range.length,
                                              text: text, attributed: attributed)
            else { continue }
            attributed[range].link = match.url
            if !links.contains(match.url) { links.append(match.url) }
        }

        for mention in mentions(in: attachments) {
            guard let range = attributedRange(utf16Offset: mention.offset,
                                              length: mention.length,
                                              text: text, attributed: attributed)
            else { continue }
            attributed[range].mentionUserID = mention.userID
        }

        return MessageText(
            attributed: attributed,
            plain: text,
            links: links,
            isEmojiOnly: count > 0,
            emojiCount: count)
    }

    // MARK: Links

    /// Shared because building one costs more than running it, and it is
    /// immutable and thread safe once built.
    private static let detector: NSDataDetector? =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private nonisolated struct LinkMatch {
        var range: NSRange
        var url: URL
    }

    private static func detectLinks(in text: String) -> [LinkMatch] {
        guard let detector else { return [] }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: full).compactMap { match in
            guard let url = match.url, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return nil }
            return LinkMatch(range: match.range, url: url)
        }
    }

    // MARK: Mentions

    private nonisolated struct MentionRun {
        var userID: String
        var offset: Int
        var length: Int
    }

    /// `user_ids` and `loci` are parallel arrays. The server has been known to
    /// send them at different lengths; zipping rather than indexing means a
    /// short one costs a mention, not a crash.
    private static func mentions(in attachments: [Message.Attachment]) -> [MentionRun] {
        var runs: [MentionRun] = []
        for attachment in attachments where attachment.type == "mentions" {
            let ids = attachment.userIds ?? []
            let loci = attachment.loci ?? []
            for (userID, locus) in zip(ids, loci) {
                guard locus.count >= 2, locus[0] >= 0, locus[1] > 0 else { continue }
                runs.append(MentionRun(userID: userID, offset: locus[0], length: locus[1]))
            }
        }
        return runs.sorted { $0.offset < $1.offset }
    }

    // MARK: Offsets

    /// Convert a UTF-16 `[offset, length]` locus into a range of the
    /// `AttributedString`.
    ///
    /// This is the part everyone gets wrong. GroupMe's offsets come out of Java
    /// strings, so they count UTF-16 code units: an emoji outside the BMP is
    /// two, a flag is four, a family with skin tones can be a dozen. Swift's
    /// `String` counts grapheme clusters and `AttributedString` counts
    /// characters, so slicing with the raw integers moves every mention after
    /// the first emoji.
    ///
    /// So: walk the UTF-16 view to find the endpoints, round outward to
    /// character boundaries if the server hands us an index inside a cluster
    /// (highlighting one character too much beats dropping the mention), then
    /// convert to character distances, which is the only currency
    /// `AttributedString` accepts.
    static func attributedRange(
        utf16Offset: Int, length: Int, text: String, attributed: AttributedString
    ) -> Range<AttributedString.Index>? {
        guard let stringRange = characterRange(utf16Offset: utf16Offset, length: length, in: text)
        else { return nil }

        let lower = text.distance(from: text.startIndex, to: stringRange.lowerBound)
        let count = text.distance(from: stringRange.lowerBound, to: stringRange.upperBound)
        guard count > 0 else { return nil }

        let start = attributed.index(attributed.startIndex, offsetByCharacters: lower)
        let end = attributed.index(start, offsetByCharacters: count)
        return start..<end
    }

    /// The same conversion, stopping at `String.Index`. Exposed because it is
    /// the piece worth testing on its own.
    static func characterRange(utf16Offset: Int, length: Int, in text: String) -> Range<String.Index>? {
        let utf16 = text.utf16
        guard utf16Offset >= 0, length > 0 else { return nil }
        guard let rawStart = utf16.index(utf16.startIndex, offsetBy: utf16Offset, limitedBy: utf16.endIndex)
        else { return nil }
        let rawEnd = utf16.index(rawStart, offsetBy: length, limitedBy: utf16.endIndex) ?? utf16.endIndex

        let start = alignedDown(rawStart, in: text)
        let end = alignedUp(rawEnd, in: text)
        guard start < end else { return nil }
        return start..<end
    }

    /// Nearest character boundary at or before `index`.
    private static func alignedDown(_ index: String.UTF16View.Index, in text: String) -> String.Index {
        if let exact = String.Index(index, within: text) { return exact }
        var probe = index
        while probe > text.utf16.startIndex {
            probe = text.utf16.index(before: probe)
            if let exact = String.Index(probe, within: text) { return exact }
        }
        return text.startIndex
    }

    /// Nearest character boundary at or after `index`.
    private static func alignedUp(_ index: String.UTF16View.Index, in text: String) -> String.Index {
        if let exact = String.Index(index, within: text) { return exact }
        var probe = index
        while probe < text.utf16.endIndex {
            probe = text.utf16.index(after: probe)
            if let exact = String.Index(probe, within: text) { return exact }
        }
        return text.endIndex
    }

    // MARK: Emoji

    /// True when every visible character is an emoji and there are few enough
    /// of them to be a gesture rather than a paragraph.
    ///
    /// U+FFFD counts, because that is the placeholder a legacy powerup sticker
    /// leaves behind in `text`; a message that is one sticker should read as
    /// one sticker.
    static func isEmojiOnly(_ text: String) -> Bool { emojiCount(text) > 0 }

    /// How many emoji a message is made of, or zero if it is made of anything
    /// else. Grapheme clusters, so a ZWJ sequence counts once.
    static func emojiCount(_ text: String) -> Int {
        var count = 0
        for character in text {
            if character.isWhitespace { continue }
            guard character.isEmojiLike else { return 0 }
            count += 1
            if count > emojiOnlyLimit { return 0 }
        }
        return count
    }
}

nonisolated extension Character {
    /// Emoji detection, the pragmatic version.
    ///
    /// `isEmoji` on a scalar is true for digits and `#`, which is useless on
    /// its own, so a single-scalar character has to actually ask for emoji
    /// presentation. Multi-scalar clusters (skin tones, ZWJ families, flags,
    /// keycaps) are emoji if any scalar is, which is where the variation
    /// selector and the regional indicators get picked up.
    var isEmojiLike: Bool {
        if self == "\u{FFFD}" { return true }
        guard let first = unicodeScalars.first else { return false }
        if unicodeScalars.count == 1 {
            return first.properties.isEmojiPresentation
        }
        return unicodeScalars.contains {
            $0.properties.isEmojiPresentation || $0 == "\u{FE0F}"
                || (0x1F1E6...0x1F1FF).contains($0.value)
        }
    }
}
