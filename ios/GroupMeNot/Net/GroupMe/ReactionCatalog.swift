import Foundation

/// The reactions a picker offers.
///
/// GroupMe does not hardcode this set; the official client pulls it from
/// `https://cdn.groupme.com/assets/reactions.json?version=<ecs version>` and
/// caches it. We ship the current list as a static default instead, because a
/// picker that is empty until the network answers is a picker that fails on the
/// subway. Refreshing from the CDN would be a strict improvement and never a
/// prerequisite, which is why nothing here reaches for it yet.
nonisolated struct ReactionCatalog: Sendable, Hashable {
    /// Unicode glyphs, in the order the picker draws them.
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
    static func icon(for glyph: String) -> GroupMeAPI.LikeIcon? {
        glyph == plainLike ? nil : .unicode(glyph)
    }
}
