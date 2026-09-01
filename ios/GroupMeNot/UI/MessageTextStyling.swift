import SwiftUI

/// Paints a parsed message.
///
/// `MessageTextParser` marks the runs and refuses to have an opinion about
/// colour, which is right: it is pure Foundation and the palette depends on
/// which side of the transcript the bubble sits on. This is the other half,
/// and it runs once when the transcript is built rather than in a `body`, so a
/// scroll never pays for it.
nonisolated enum MessageStyling {

    /// The size an emoji-only message is drawn at.
    ///
    /// Scaled by how many there are. One emoji is a gesture and should land like
    /// one; eight are closer to a sentence and have to fit a line. A single size
    /// for both makes the lone one look timid and the row of eight look like a
    /// mistake.
    static func emojiFontSize(count: Int) -> CGFloat {
        switch count {
        case ...1: 68
        case 2: 56
        case 3: 48
        default: 40
        }
    }

    /// Links tinted and underlined, mentions tinted and bold.
    ///
    /// Own bubbles are white text on the accent colour, so a tint would
    /// disappear into the background; there the emphasis carries the meaning
    /// and the underline carries the link.
    static func style(_ text: MessageText, isOwn: Bool) -> AttributedString {
        guard !text.isEmpty else { return text.attributed }
        var styled = text.attributed

        // Ranges are collected first because mutating an `AttributedString`
        // while walking its runs invalidates the walk.
        var links: [Range<AttributedString.Index>] = []
        var mentions: [Range<AttributedString.Index>] = []
        for run in styled.runs {
            if run.link != nil { links.append(run.range) }
            if run.mentionUserID != nil { mentions.append(run.range) }
        }
        guard !links.isEmpty || !mentions.isEmpty else { return styled }

        var linkStyle = AttributeContainer()
        linkStyle[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] =
            isOwn ? .white : .accentColor
        linkStyle[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = .single

        var mentionStyle = AttributeContainer()
        mentionStyle[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] =
            isOwn ? .white : .accentColor
        mentionStyle[AttributeScopes.SwiftUIAttributes.FontAttribute.self] =
            .body.weight(.semibold)

        for range in links { styled[range].mergeAttributes(linkStyle) }
        // Mentions last: a display name that happens to contain a URL should
        // read as a mention, not as a link.
        for range in mentions { styled[range].mergeAttributes(mentionStyle) }
        return styled
    }
}
