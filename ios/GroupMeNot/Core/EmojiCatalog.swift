import Foundation

/// One emoji, and the name Unicode gives it.
nonisolated struct EmojiEntry: Identifiable, Hashable, Sendable {
    /// What to draw, and what goes in `like_icon.code`.
    var glyph: String
    /// Lowercased Unicode name, e.g. `face with tears of joy`. The only thing
    /// search matches on.
    var name: String

    var id: String { glyph }
}

/// Every emoji, derived rather than listed.
///
/// The reaction wire format is `{"like_icon": {"type": "unicode", "code": "…"}}`
/// and the official client fills `code` from a whole emoji keyboard, so the
/// eighteen in ``ReactionCatalog`` are a shortcut and not a limit. Offering the
/// rest means having the rest, and there are two ways to get them: paste in a
/// table of some three thousand glyphs and their names and then own it forever,
/// or ask the copy of Unicode that ships in the OS. This asks.
///
/// `Unicode.Scalar.Properties` knows which scalars are emoji, which ones need a
/// variation selector to render as one, and what each is called. That makes the
/// catalog a function of the device's Unicode version instead of a table that
/// goes stale: a phone that knows about newer emoji offers them, and nothing
/// here has to be edited when it does. It also costs nothing at rest and works
/// with the radio off, which a CDN-fetched list would not.
///
/// What it does not cover: sequences. Flags, skin tones, families and every
/// other ZWJ combination are built from several scalars, and there is no
/// property that enumerates the valid combinations, so a scalar walk cannot
/// find them. Those glyphs are still perfectly sendable, and the keyboard is
/// the way to reach them; what this offers is every *single-scalar* emoji,
/// which is around fifteen hundred of them.
actor EmojiCatalog {
    /// Shared because the derivation is worth doing once per launch and the
    /// result is a few hundred kilobytes at most.
    static let shared = EmojiCatalog()

    private var cache: [EmojiEntry]?

    /// Every emoji, in Unicode order, which puts the blocks people think of as
    /// categories next to each other without us having to name them.
    func all() -> [EmojiEntry] {
        if let cache { return cache }
        let derived = Self.derive()
        cache = derived
        return derived
    }

    /// Emoji whose name contains every word of `query`.
    ///
    /// Word-wise and prefix-matched, so `cat face` finds `cat face with wry
    /// smile` and `smi` finds every smiling thing. An empty query is everything,
    /// which is what the browser shows before anyone types.
    func search(_ query: String) -> [EmojiEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return all() }
        return all().filter { entry in
            let names = entry.name.split(separator: " ")
            return words.allSatisfy { word in
                names.contains { $0.hasPrefix(word) }
            }
        }
    }

    // MARK: - Derivation

    /// The blocks that contain emoji, so the walk is fifteen thousand scalars
    /// rather than the million-odd in Unicode. Every emoji ever assigned lives
    /// in one of these.
    private static let blocks: [ClosedRange<UInt32>] = [
        0x00A9...0x00AE,   // © ®
        0x203C...0x3299,   // arrows, dingbats, enclosed CJK
        0x1F000...0x1FAFF, // the pictographic planes
    ]

    /// Scalars that are emoji but are not emoji anybody reacts with.
    private static func isExcluded(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        // Regional indicators are flag *halves*: alone they draw as boxed
        // letters, and pairing them is a sequence this walk cannot enumerate.
        case 0x1F1E6...0x1F1FF: true
        // Skin tone modifiers, which are not glyphs on their own either.
        case 0x1F3FB...0x1F3FF: true
        default: false
        }
    }

    private static func derive() -> [EmojiEntry] {
        var entries: [EmojiEntry] = []
        entries.reserveCapacity(1600)

        for block in blocks {
            for value in block {
                guard let scalar = Unicode.Scalar(value) else { continue }
                let properties = scalar.properties
                guard properties.isEmoji, !isExcluded(scalar) else { continue }
                guard let name = properties.name else { continue }

                // A scalar with emoji presentation draws as an emoji on its
                // own. One without it defaults to text (❤ is a black heart
                // until you say otherwise), so it carries U+FE0F, exactly as
                // the reactions the CDN document lists do.
                let glyph = properties.isEmojiPresentation
                    ? String(scalar)
                    : String(scalar) + "\u{FE0F}"
                entries.append(EmojiEntry(glyph: glyph, name: name.lowercased()))
            }
        }
        return entries
    }
}
