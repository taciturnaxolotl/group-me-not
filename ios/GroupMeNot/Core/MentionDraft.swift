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

    /// One mention as the draft currently stands: who, and where their name sits.
    struct Located: Hashable, Sendable {
        var userID: String
        /// Offset and length in UTF-16 units, covering the `@` and the name.
        var range: NSRange
    }

    /// A finished completion: the draft it produced, and where the caret goes.
    struct Completion: Hashable, Sendable {
        var text: String
        /// A UTF-16 offset, ready to hand back to UIKit.
        var caret: Int
    }

    /// Where each remembered name still sits in the draft, in text order.
    ///
    /// Each person claims the earliest `@name` nobody has claimed yet, so a
    /// mention typed in front of an older one still finds its own words and
    /// naming the same person twice finds both. A name the user has since
    /// edited away claims nothing and is dropped, rather than sending a locus
    /// pointing at whatever now sits there.
    ///
    /// The composer paints the result as it types, so what is highlighted and
    /// what is sent are resolved the same way.
    static func located(in text: String, naming people: [Named]) -> [Located] {
        guard !people.isEmpty, !text.isEmpty else { return [] }
        let utf16 = Array(text.utf16)

        var found: [Located] = []
        for person in people {
            let needle = Array("@\(person.name)".utf16)
            guard !needle.isEmpty else { continue }
            var from = 0
            while let start = index(of: needle, in: utf16, from: from) {
                let range = NSRange(location: start, length: needle.count)
                guard found.allSatisfy({ NSIntersectionRange($0.range, range).length == 0 }) else {
                    from = start + 1
                    continue
                }
                found.append(Located(userID: person.userID, range: range))
                break
            }
        }

        return found.sorted { $0.range.location < $1.range.location }
    }

    /// The attachment for a finished draft, or nil when nobody survives.
    static func attachment(for text: String, naming people: [Named]) -> Message.Attachment? {
        let found = located(in: text, naming: people)
        guard !found.isEmpty else { return nil }
        return Message.Attachment(
            type: "mentions",
            userIds: found.map(\.userID),
            loci: found.map { [$0.range.location, $0.range.length] })
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
    /// Keyed off the caret rather than the last `@` in the draft, so a mention
    /// can be added in front of words that are already written. Returns nil the
    /// moment the run contains whitespace, so "@Kieran " stops offering
    /// completions once the name is finished, and a lone "@" in the middle of
    /// an email address never starts one.
    static func query(in text: String, caret: Int) -> String? {
        guard let end = position(in: text, at: caret) else { return nil }
        let head = text[..<end]
        guard let at = head.lastIndex(of: "@") else { return nil }
        // An `@` immediately after a word character is an address, not a
        // mention: `me@example.com` should suggest nothing.
        if at > head.startIndex {
            let before = head[head.index(before: at)]
            guard before.isWhitespace || before.isNewline else { return nil }
        }
        let run = head[head.index(after: at)...]
        guard !run.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return String(run)
    }

    /// The draft with the partial name at the caret replaced by a full one.
    static func completing(_ text: String, at caret: Int, with name: String) -> Completion {
        guard let end = position(in: text, at: caret),
            let at = text[..<end].lastIndex(of: "@")
        else { return Completion(text: text, caret: caret) }
        let inserted = "@\(name) "
        var out = text
        out.replaceSubrange(at..<end, with: inserted)
        return Completion(text: out, caret: at.utf16Offset(in: text) + inserted.utf16.count)
    }

    /// The index at a UTF-16 offset, which is what UIKit reports a caret as.
    /// Nil when the offset is out of bounds or lands inside a character.
    private static func position(in text: String, at caret: Int) -> String.Index? {
        guard caret >= 0 else { return nil }
        let units = text.utf16
        guard let unit = units.index(units.startIndex, offsetBy: caret, limitedBy: units.endIndex)
        else { return nil }
        return String.Index(unit, within: text)
    }
}
