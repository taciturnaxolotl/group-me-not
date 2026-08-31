import Foundation

/// Turns a composed message into the `mentions` attachment GroupMe expects.
///
/// The wire shape is two parallel arrays: `user_ids`, and `loci` of
/// `[offset, length]`. **The offsets are UTF-16 code units**, because they come
/// out of Java strings — the same fact `MessageTextParser` has to undo when
/// reading them. Counting Swift `Character`s here would put every mention in a
/// message containing an emoji on the wrong word.
nonisolated enum MentionDraft {

    /// One person named in a draft.
    struct Named: Hashable, Sendable {
        var userID: String
        var name: String
    }

    /// The attachment for a finished draft, or nil when nobody survives.
    ///
    /// Each name is located by searching the text for `@name`, in order, never
    /// looking at the same stretch twice. That handles the same person named
    /// twice, and it drops a mention whose text the user has since edited away
    /// rather than sending a locus pointing at whatever now sits there.
    static func attachment(for text: String, naming people: [Named]) -> Message.Attachment? {
        guard !people.isEmpty, !text.isEmpty else { return nil }
        let utf16 = Array(text.utf16)

        var ids: [String] = []
        var loci: [[Int]] = []
        var searched = 0

        for person in people {
            let needle = Array("@\(person.name)".utf16)
            guard !needle.isEmpty, let start = index(of: needle, in: utf16, from: searched)
            else { continue }
            ids.append(person.userID)
            loci.append([start, needle.count])
            searched = start + needle.count
        }

        guard !ids.isEmpty else { return nil }
        return Message.Attachment(type: "mentions", userIds: ids, loci: loci)
    }

    /// Plain substring search over UTF-16 units, which is what the offsets are
    /// counted in. Using `String.range(of:)` and converting afterwards would
    /// work and would also invite somebody to convert it wrongly later.
    private static func index(of needle: [UInt16], in haystack: [UInt16], from: Int) -> Int? {
        guard needle.count <= haystack.count, from <= haystack.count - needle.count else { return nil }
        for start in from...(haystack.count - needle.count) {
            var matched = true
            for offset in needle.indices where haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return start }
        }
        return nil
    }

    /// The partial name being typed at the caret, if the caret sits in one.
    ///
    /// Returns nil the moment the run contains whitespace, so "@Kieran " stops
    /// offering completions once the name is finished, and a lone "@" in the
    /// middle of an email address never starts one.
    static func query(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        // An `@` immediately after a word character is an address, not a
        // mention: `me@example.com` should suggest nothing.
        if at > text.startIndex {
            let before = text[text.index(before: at)]
            guard before.isWhitespace || before.isNewline else { return nil }
        }
        let run = text[text.index(after: at)...]
        guard !run.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return String(run)
    }

    /// The draft with the partial name at the caret replaced by a full one.
    static func completing(_ text: String, with name: String) -> String {
        guard let at = text.lastIndex(of: "@") else { return text }
        return String(text[..<at]) + "@\(name) "
    }
}
