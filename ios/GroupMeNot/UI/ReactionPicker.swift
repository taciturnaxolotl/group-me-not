import SwiftUI

/// The floating bar a long press puts over a message: the reaction catalog on
/// top, the actions that used to live in the context menu underneath.
///
/// One presentation rather than two, because a long press can only mean one
/// thing and the tapback row is what a chat app should do with it. Everything
/// here works with the radio off: the catalog is a local constant and a tap
/// applies optimistically.
struct ReactionPicker: View {
    let glyphs: [String]
    /// The glyph this user already holds, drawn as selected. Tapping it again
    /// clears the reaction.
    let selected: String?
    var onPick: (String) -> Void
    /// Called when the user wants a glyph the row does not carry. Nil hides the
    /// More button, which is what a caller with nowhere to put a sheet wants.
    var onMore: (() -> Void)?
    /// The actions below the divider, in the order they should read.
    var actions: [Action] = []

    /// One row under the reaction bar. Nothing fancy: a symbol, a word, and a
    /// closure.
    struct Action: Identifiable {
        var id: String { title }
        var title: String
        var symbol: String
        var isDestructive: Bool = false
        var perform: () -> Void

        init(_ title: String, symbol: String, isDestructive: Bool = false,
             perform: @escaping () -> Void) {
            self.title = title
            self.symbol = symbol
            self.isDestructive = isDestructive
            self.perform = perform
        }
    }

    @ScaledMetric(relativeTo: .title2) private var glyphSlot: CGFloat = 34

    var body: some View {
        VStack(spacing: 0) {
            reactionBar
            if !actions.isEmpty {
                Divider()
                actionList
            }
        }
        .frame(width: 296)
    }

    /// Eighteen glyphs never fit a phone's width, so the bar scrolls. The first
    /// half dozen are the ones people actually use, and they are visible
    /// without moving anything.
    ///
    /// The row is the quick list, not the whole set: `like_icon` takes any
    /// unicode emoji, and the More button on the end is how you reach the rest.
    /// It sits at the end rather than the start because the glyph most worth
    /// having under a thumb is the group's own, and that one is first.
    private var reactionBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(glyphs, id: \.self) { glyph in
                    Button { onPick(glyph) } label: {
                        ReactionGlyph(glyph: glyph, size: glyphSlot * 0.62)
                            .frame(width: glyphSlot, height: glyphSlot)
                            .background {
                                if glyph == selected {
                                    Circle().fill(Color.accentColor.opacity(0.22))
                                }
                            }
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(glyph)
                    .accessibilityAddTraits(glyph == selected ? [.isSelected] : [])
                }
                if let onMore { moreButton(onMore) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func moreButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: glyphSlot * 0.42, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: glyphSlot, height: glyphSlot)
                .background(Circle().fill(Color(.secondarySystemFill)))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More reactions")
    }

    private var actionList: some View {
        VStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                if index > 0 { Divider().padding(.leading, 44) }
                Button(action: action.perform) {
                    HStack {
                        Text(action.title)
                        Spacer(minLength: 8)
                        Image(systemName: action.symbol)
                    }
                    .font(.body)
                    .foregroundStyle(action.isDestructive ? AnyShapeStyle(Color.red)
                                                          : AnyShapeStyle(.primary))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
