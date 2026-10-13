import SwiftUI
import UniformTypeIdentifiers

/// The growing text field a message is written in.
///
/// SwiftUI's `TextField(axis: .vertical)` was here first, and it kept losing
/// two arguments with the keyboard. The first is what the text is: while an
/// inline prediction or a two-stage composition is unresolved the field holds
/// marked text of its own, and emptying the binding underneath it does not take
/// that away, so the sent message comes back a frame later. The second is how
/// tall it should be: the height is the field's own business and it settles a
/// beat behind the words, which is fine for a line arriving and very much not
/// fine for six lines leaving at once.
///
/// A `UITextView` answers both, because both are questions UIKit will let you
/// ask directly. Clearing unmarks first and then assigns, so the text really is
/// gone; the height is measured in `sizeThatFits`, which SwiftUI calls in the
/// same layout pass that carries the new text, so the box is never a size the
/// words no longer justify.
struct ComposerField: View {
    let placeholder: String
    @Binding var text: String
    /// Two-way, and a plain `Bool` rather than `@FocusState`, which has no way
    /// through to a represented view.
    @Binding var isFocused: Bool
    /// How tall it grows before the words start scrolling inside it.
    var lineLimit: Int = 6
    /// The stretches of the draft that are live mentions, in UTF-16 units.
    /// Drawn tinted and semibold, the way the transcript draws a mention, so a
    /// name still attached to a person looks like one.
    var mentions: [NSRange] = []
    /// The field's selection, two-way, because completing a mention means
    /// knowing where the caret is and then putting it after the inserted name.
    @Binding var selection: NSRange
    /// Called with any images lifted off the pasteboard when the user pastes.
    /// A `UITextView` drops images on the floor otherwise; routing them here
    /// lets a pasted screenshot become an attachment instead of nothing.
    var onPasteImages: ([PastedImage]) -> Void = { _ in }

    init(
        _ placeholder: String, text: Binding<String>, isFocused: Binding<Bool>, lineLimit: Int = 6,
        mentions: [NSRange] = [],
        selection: Binding<NSRange> = .constant(NSRange(location: 0, length: 0)),
        onPasteImages: @escaping ([PastedImage]) -> Void = { _ in }
    ) {
        self.placeholder = placeholder
        self._text = text
        self._isFocused = isFocused
        self.lineLimit = lineLimit
        self.mentions = mentions
        self._selection = selection
        self.onPasteImages = onPasteImages
    }

    var body: some View {
        Field(
            text: $text, isFocused: $isFocused, lineLimit: lineLimit, mentions: mentions,
            selection: $selection, onPasteImages: onPasteImages)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
    }

    /// A text view that keeps the caret in sight once its box has stopped
    /// growing.
    ///
    /// The chase cannot happen where the words change, because at that moment
    /// the field is still the height the line before justified: SwiftUI
    /// measures and resizes afterwards. Scrolling then is scrolling inside
    /// bounds that are about to change, and it leaves the last line sitting
    /// under the edge — which is what "it stops moving" looks like from the
    /// outside. Waiting for the layout that carries the new height is what
    /// makes the line being typed the line on screen.
    private final class GrowingTextView: UITextView {
        /// Set when the text changed, cleared by the layout that answers it.
        var caretNeedsChasing = false
        /// Handed the images off the pasteboard when the user pastes one.
        var onPasteImages: ([PastedImage]) -> Void = { _ in }
        /// What the last restyle painted, so a pass that changes nothing is
        /// not a pass that rewrites the storage.
        private var painted: Painted?

        private struct Painted: Equatable {
            var text: String
            var mentions: [NSRange]
        }

        private var hasPaintedMentions: Bool { painted?.mentions.isEmpty == false }

        /// Tint and weight the mention runs, and leave everything else plain.
        ///
        /// Attributes only: the characters are never touched, because the caret,
        /// the undo stack and autocorrect all key off the text. Composition is
        /// skipped outright, since the underline under marked text is the
        /// keyboard's and the next keystroke brings us back here anyway.
        func restyleMentions(_ ranges: [NSRange]) {
            guard markedTextRange == nil else { return }
            let text = textStorage.string
            let length = (text as NSString).length
            let wanted = Painted(
                text: text, mentions: ranges.filter { $0.length > 0 && $0.upperBound <= length })
            // A field nobody has mentioned anybody in is never written to at
            // all, so a composer without mentions keeps whatever UIKit puts in
            // its own storage rather than having it set back to plain.
            guard !wanted.mentions.isEmpty || hasPaintedMentions else { return }
            guard wanted != painted else { return }
            painted = wanted

            let plain = baseAttributes
            // Typing attributes come from the character left of the caret, so
            // without this the letter after a mention inherits its colour.
            typingAttributes = plain
            guard length > 0 else { return }

            let caret = selectedRange
            textStorage.beginEditing()
            textStorage.setAttributes(plain, range: NSRange(location: 0, length: length))
            let emphasis = mentionAttributes
            for range in wanted.mentions { textStorage.addAttributes(emphasis, range: range) }
            textStorage.endEditing()
            if selectedRange != caret { selectedRange = caret }
        }

        /// The plain look of the field, asked of the type system rather than
        /// read back off the view: `UITextView.font` is nil the moment the
        /// storage holds two fonts, and reading it after a mention has been
        /// painted would hand back the semibold one and make the whole draft
        /// bold a pass later.
        private var baseAttributes: [NSAttributedString.Key: Any] {
            [.font: Self.baseFont, .foregroundColor: UIColor.label]
        }

        private var mentionAttributes: [NSAttributedString.Key: Any] {
            let body = Self.baseFont
            let bolder = body.fontDescriptor.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]
            ])
            return [
                .font: UIFont(descriptor: bolder, size: body.pointSize),
                .foregroundColor: tintColor ?? .tintColor,
            ]
        }

        /// Read fresh every time so the field follows Dynamic Type the way a
        /// plain one does.
        private static var baseFont: UIFont { .preferredFont(forTextStyle: .body) }

        /// A backspace that would damage a mention selects it instead: the
        /// first press lights the name up whole, the second takes it away.
        /// Deleting a mention letter by letter breaks it several keystrokes
        /// before the word looks any different.
        override func deleteBackward() {
            if let mention = mentionUnderCaret() {
                selectedRange = mention
                return
            }
            super.deleteBackward()
        }

        /// The painted mention a resting caret sits inside or at the end of. A
        /// caret at the very start of a name is left alone: that backspace
        /// belongs to whatever is in front of the mention, not to it.
        private func mentionUnderCaret() -> NSRange? {
            let caret = selectedRange
            guard caret.length == 0 else { return nil }
            let length = (textStorage.string as NSString).length
            return painted?.mentions.first { range in
                range.upperBound <= length
                    && caret.location > range.location
                    && caret.location <= range.upperBound
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard caretNeedsChasing else { return }
            caretNeedsChasing = false
            scrollRangeToVisible(selectedRange)
        }

        /// A field of plain text will not offer Paste when the pasteboard holds
        /// only an image, so it has to be enabled by hand — otherwise there is
        /// no way to invoke the paste we are about to intercept.
        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(paste(_:)), UIPasteboard.general.hasImages {
                return true
            }
            return super.canPerformAction(action, withSender: sender)
        }

        /// Intercept a paste that carries images and route them to attachments
        /// rather than letting UIKit turn them into text attachments the wire
        /// format has no place for. Anything else pastes as it always did.
        override func paste(_ sender: Any?) {
            let images = Self.pasteboardImages()
            guard !images.isEmpty else {
                super.paste(sender)
                return
            }
            onPasteImages(images)
        }

        /// Every image on the general pasteboard, kept as raw bytes with the
        /// type it was copied as. Reads `items` directly so a multi-image paste
        /// and the original encoding both survive.
        private static func pasteboardImages() -> [PastedImage] {
            let board = UIPasteboard.general
            guard board.hasImages else { return [] }
            var out: [PastedImage] = []
            for item in board.items {
                for (identifier, value) in item {
                    guard let type = UTType(identifier), type.conforms(to: .image) else { continue }
                    if let data = value as? Data {
                        out.append(PastedImage(data: data, type: type))
                        break
                    }
                    if let image = value as? UIImage, let data = image.pngData() {
                        out.append(PastedImage(data: data, type: .png))
                        break
                    }
                }
            }
            return out
        }
    }

    private struct Field: UIViewRepresentable {
        @Binding var text: String
        @Binding var isFocused: Bool
        let lineLimit: Int
        let mentions: [NSRange]
        @Binding var selection: NSRange
        let onPasteImages: ([PastedImage]) -> Void

        func makeUIView(context: Context) -> GrowingTextView {
            let view = GrowingTextView()
            view.delegate = context.coordinator
            view.font = .preferredFont(forTextStyle: .body)
            view.adjustsFontForContentSizeCategory = true
            view.autocapitalizationType = .sentences
            view.backgroundColor = .clear
            // The padding belongs to the caller, the way it did when this was a
            // `TextField`, so the view measures as pure text.
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            // Always scrollable, and the height comes from `sizeThatFits`
            // instead. Turning scrolling on only once the words outgrew the box
            // meant flipping a mode inside a measuring pass, and the view that
            // came out the other side had a six-line frame it would not scroll:
            // the text past the sixth line was laid out and unreachable.
            view.isScrollEnabled = true
            view.alwaysBounceVertical = false
            view.onPasteImages = onPasteImages
            view.text = text
            view.restyleMentions(mentions)
            // Seeded so the first update is not mistaken for the caller asking
            // for the caret to move.
            context.coordinator.reportedSelection = selection
            return view
        }

        func updateUIView(_ view: GrowingTextView, context: Context) {
            context.coordinator.parent = self
            // Refreshed every pass: the closure captures the caller's current
            // state, and a stale one would append to a view that has moved on.
            view.onPasteImages = onPasteImages

            if view.text != text {
                // Before the assignment, and the whole point of this file. An
                // unresolved composition is text the field is still holding on
                // its own account, and it writes it back over anything set
                // underneath it. Unmarking commits it, which fires the delegate,
                // so the coordinator is told to ignore itself for the moment.
                context.coordinator.isApplyingExternalText = true
                if view.markedTextRange != nil { view.unmarkText() }
                view.text = text
                context.coordinator.isApplyingExternalText = false
                // Text set from outside moves the caret too, and after a send
                // it moves it to the top of an empty field. A view that keeps
                // the offset it had while six lines were being written shows a
                // blank space where the placeholder should be.
                view.caretNeedsChasing = true
            }

            // After the assignment, which resets the storage to the plain font
            // and colour, and on every other pass too: the ranges move with
            // each keystroke even when the text has not changed under us.
            view.restyleMentions(mentions)

            // A selection the field never reported is the caller asking for the
            // caret to move, which is how completing a mention lands it after
            // the name just inserted. Anything the field reported itself is the
            // user's own doing and is left where it is.
            if selection != context.coordinator.reportedSelection,
                selection.upperBound <= (view.text as NSString).length
            {
                context.coordinator.reportedSelection = selection
                if view.selectedRange != selection { view.selectedRange = selection }
            }

            if isFocused, !view.isFirstResponder {
                view.becomeFirstResponder()
            } else if !isFocused, view.isFirstResponder {
                view.resignFirstResponder()
            }
        }

        /// The height the words actually need, clamped to the line limit.
        ///
        /// SwiftUI asks this on the layout pass that follows the text change,
        /// which is why deleting a paragraph collapses the box on the same
        /// frame the words disappear rather than a beat afterwards.
        func sizeThatFits(
            _ proposal: ProposedViewSize, uiView view: GrowingTextView, context: Context
        ) -> CGSize? {
            let width = proposal.width ?? view.bounds.width
            guard width > 0 else { return nil }
            let line = view.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
            let wanted = view.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height
            let ceiling = line * CGFloat(lineLimit)
            // Past the limit the box stops growing and the words move inside
            // it instead, which is the whole of what this clamp does: the view
            // scrolls either way, and below the ceiling there is simply never
            // anything out of sight to scroll to.
            let height = min(max(wanted, line), ceiling)
            return CGSize(width: width, height: ceil(height))
        }

        func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

        final class Coordinator: NSObject, UITextViewDelegate {
            var parent: Field
            /// Set while the binding is being written into the field, so the
            /// delegate does not turn round and write it back out again.
            var isApplyingExternalText = false
            /// The last selection the field reported upward, so the caller
            /// echoing it back is not read as a request to move the caret.
            var reportedSelection: NSRange?

            init(parent: Field) { self.parent = parent }

            func textViewDidChange(_ view: UITextView) {
                guard !isApplyingExternalText else { return }
                parent.text = view.text
                // Asked for here, done in `layoutSubviews`, once the box is the
                // height these words justify.
                (view as? GrowingTextView)?.caretNeedsChasing = true
            }

            func textViewDidChangeSelection(_ view: UITextView) {
                guard !isApplyingExternalText, parent.selection != view.selectedRange else { return }
                reportedSelection = view.selectedRange
                parent.selection = view.selectedRange
            }

            func textViewDidBeginEditing(_ view: UITextView) {
                if !parent.isFocused { parent.isFocused = true }
            }

            func textViewDidEndEditing(_ view: UITextView) {
                if parent.isFocused { parent.isFocused = false }
            }
        }
    }
}
