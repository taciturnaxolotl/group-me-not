import Foundation

/// The reactions a picker offers *first*.
///
/// Not the reactions it is limited to. `like_icon` is `{type: "unicode", code}`
/// on the wire and the official client fills `code` from a full emoji keyboard
/// (`EmojiPickerFragment` maps `Glyph.Unicode` straight to `type: "unicode"`),
/// so any emoji is a valid reaction. This is the quick row: the eighteen
/// `https://cdn.groupme.com/assets/reactions.json` lists, in its order, because
/// they are the ones people reach for. Everything else lives behind the
/// picker's More button and comes from ``EmojiCatalog``.
///
/// We ship the eighteen as a static default rather than fetching them, because
/// a picker that is empty until the network answers is a picker that fails on
/// the subway. Refreshing from the CDN would be a strict improvement and never
/// a prerequisite, which is why nothing here reaches for it yet.
nonisolated struct ReactionCatalog: Sendable, Hashable {
    /// Glyphs, in the order the picker draws them. Unicode, except for a
    /// group's own like icon, which may be a pack token (``Message/PackGlyph``).
    var glyphs: [String]

    /// The 18 reactions the live CDN document lists, in its order.
    static let `default` = ReactionCatalog(glyphs: [
        "\u{2764}\u{FE0F}",  // ❤️
        "\u{1F44D}",         // 👍
        "\u{1F44E}",         // 👎
        "\u{1F923}",         // 🤣
        "\u{1F389}",         // 🎉
        "\u{1F525}",         // 🔥
        "\u{1F62E}",         // 😮
        "\u{1F440}",         // 👀
        "\u{1F62D}",         // 😭
        "\u{1F97A}",         // 🥺
        "\u{2753}",          // ❓
        "\u{1F64F}",         // 🙏
        "\u{1F480}",         // 💀
        "\u{1FAF6}",         // 🫶
        "\u{1F92C}",         // 🤬
        "\u{1F485}",         // 💅
        "\u{1FAE0}",         // 🫠
        "\u{1FAE6}",         // 🫦
    ])

    /// This catalog with a group's own like icon at the front.
    ///
    /// First, because it is the one reaction the group picked on purpose, and
    /// deduplicated, because a group whose icon is 🔥 should get one 🔥 in the
    /// row rather than two. Moving it rather than merely inserting it keeps the
    /// promise the report asked for: the group's glyph is offered first,
    /// whatever else the row contains.
    func withLikeIcon(_ icon: Message.Reaction?) -> ReactionCatalog {
        guard let glyph = icon?.glyph, !glyph.isEmpty else { return self }
        return ReactionCatalog(glyphs: [glyph] + glyphs.filter { $0 != glyph })
    }

    /// The short row a long press offers: the group's own like icon, if it has
    /// one, and four more.
    ///
    /// Five, not eighteen. A row that has to scroll is a row nobody scrolls, and
    /// the tail of the catalog was reachable only by dragging inside a popover
    /// that a stray millimetre would dismiss. Everything past the fifth glyph
    /// lives behind the More button, where the whole emoji set is searchable and
    /// nothing is hiding off the edge.
    ///
    /// ``withLikeIcon(_:)`` has already moved the group's glyph to the front, so
    /// taking the first five is what puts it under the thumb.
    var quick: [String] { Array(glyphs.prefix(5)) }

    /// The glyph a plain, bodyless like means.
    ///
    /// Legacy likes have no icon of their own, and every client draws them as a
    /// heart, so this is the bucket they merge into. See
    /// `Message.reactionSummaries(currentUserID:)`.
    static let plainLike = Message.ReactionSummary.heart

    /// What to send for a glyph.
    ///
    /// The heart is deliberately a plain like rather than a `unicode` reaction:
    /// that is what the official composer does, and it keeps the message's
    /// `favorited_by` list, which older clients and the likes endpoints still
    /// read, in agreement with what we drew.
    ///
    /// A pack token goes back out as the `emoji` shape it came in as, which is
    /// what makes reacting with a group's own like icon work at all.
    static func icon(for glyph: String) -> GroupMeAPI.LikeIcon? {
        if let pack = Message.PackGlyph(token: glyph) {
            return .emoji(packId: pack.packID, packIndex: pack.index)
        }
        return glyph == plainLike ? nil : .unicode(glyph)
    }
}
