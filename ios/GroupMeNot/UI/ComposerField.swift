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
    /// Called with any images lifted off the pasteboard when the user pastes.
    /// A `UITextView` drops images on the floor otherwise; routing them here
    /// lets a pasted screenshot become an attachment instead of nothing.
    var onPasteImages: ([PastedImage]) -> Void = { _ in }

    init(
        _ placeholder: String, text: Binding<String>, isFocused: Binding<Bool>, lineLimit: Int = 6,
        onPasteImages: @escaping ([PastedImage]) -> Void = { _ in }
    ) {
        self.placeholder = placeholder
        self._text = text
        self._isFocused = isFocused
        self.lineLimit = lineLimit
        self.onPasteImages = onPasteImages
    }

    var body: some View {
        Field(text: $text, isFocused: $isFocused, lineLimit: lineLimit, onPasteImages: onPasteImages)
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

            init(parent: Field) { self.parent = parent }

            func textViewDidChange(_ view: UITextView) {
                guard !isApplyingExternalText else { return }
                parent.text = view.text
                // Asked for here, done in `layoutSubviews`, once the box is the
                // height these words justify.
                (view as? GrowingTextView)?.caretNeedsChasing = true
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
