import SwiftUI

/// The message being answered, hovering over the transcript just above the
/// composer, drawn as the message it is.
///
/// Messages does this and it is plainly right: a reply is aimed at something
/// the reader can already see, so showing them a *smaller, greyer,
/// differently-shaped* copy of it is asking them to match two pictures of the
/// same thing. The bubble they tapped comes down to the composer instead.
///
/// Outside the field rather than inside it. In the field it was another row of
/// the same control, which is what made a quote need furniture to be told
/// apart from the words answering it; up here it is a message sitting over the
/// transcript, and nothing has to say so.
struct ReplyHover: View {
    /// The row as the transcript built it. Lifted out and stripped of its
    /// clock here, so the caller hands over the thing it already has.
    let item: MessageDisplay
    /// The height of the whole chat, which the hover is sized against.
    ///
    /// The whole view rather than the room above the composer, because the
    /// hover is *part* of that room: sized against what is left it would
    /// shrink the very thing it was measured from, and settle somewhere
    /// smaller than either answer. Zero before the chat has been measured.
    let viewHeight: CGFloat
    var previews: LinkPreviewService?

    var body: some View {
        ScrollsWhenTall {
            MessageRow(item: row, previews: previews, showsFace: false)
                // A picture of the message, not the message. Every gesture it
                // carries belongs to the transcript.
                .allowsHitTesting(false)
                // Small enough that the whole message fits the slot. At
                // transcript height a photo is twice what the hover can show,
                // so the reader answers the top half of a picture with the
                // rest of it cut off.
                .environment(\.quotedPictureHeight, pictureHeight)
        }
        // Past this the message scrolls instead of climbing the screen. The
        // point is recognising what was tapped, and a third of the view is
        // about what the keyboard leaves free for it.
        .frame(maxHeight: limit, alignment: .top)
        .padding(.horizontal, 2)
        // Close, but not touching. The bubble and the field it is about to be
        // answered in are one arrangement; a hair of air keeps them from
        // reading as one object.
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
    }

    /// No quote, no count, and a run of one: the name draws whether or not
    /// the message opened a run downstairs, because up here there is nothing
    /// above it to say who is speaking. No timestamp, for the opposite
    /// reason: a clock under a message being answered is answering a question
    /// nobody asked while standing on the composer.
    private var row: MessageDisplay {
        var row = item.liftedOutOfTranscript()
        row.showsSender = true
        row.isRunTail = false
        return row
    }

    private var limit: CGFloat {
        viewHeight > 0 ? viewHeight * 0.34 : Self.limitBeforeMeasuring
    }

    /// What the slot is worth for the frame before the chat has been measured.
    /// Not a floor: a landscape phone has a third of very little, and holding
    /// the portrait number there would stand the hover over the conversation
    /// it came from.
    private static let limitBeforeMeasuring: CGFloat = 190

    /// How tall a photograph may draw, leaving room for a name above and a
    /// caption below. Floored, because a slot too short to hold a picture and
    /// its chrome is better scrolled than filled with a stamp.
    private var pictureHeight: CGFloat { max(80, limit - 90) }
}
