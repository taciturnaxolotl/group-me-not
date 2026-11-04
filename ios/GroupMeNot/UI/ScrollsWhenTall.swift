import SwiftUI

/// A vertical scroll view that is only a scroll view when it has to be.
///
/// Laid out as its content when the content fits the height it is offered,
/// and as a scroll view of exactly that height when it does not. Nothing is
/// measured and nothing is remembered: the size is right on the first pass,
/// a different content is the right size on *its* first pass, and a change
/// in height lands in the same transaction as whatever caused it, so it
/// animates with it instead of a frame behind.
///
/// This replaces the pattern of a `ScrollView` with its content measured
/// back into a `frame(height:)`. That pattern is one frame late on every
/// change, and the state it keeps outlives the content it measured, which is
/// how a short message came to be drawn in a tall message's frame.
struct ScrollsWhenTall<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content()
            ScrollView {
                content()
            }
            .scrollBounceBehavior(.basedOnSize)
            // Both roles, said here on the scroll view itself. The anchors are
            // inherited: a chain presented from a chat sits inside that chat's
            // bottom anchors, and so opened on its last message and held the
            // bottom still as its rows settled, with the tapped message cut
            // off above.
            .defaultScrollAnchor(.top, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .sizeChanges)
        }
    }
}
