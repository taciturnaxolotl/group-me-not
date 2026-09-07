import SwiftUI

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

    init(
        _ placeholder: String, text: Binding<String>, isFocused: Binding<Bool>, lineLimit: Int = 6
    ) {
        self.placeholder = placeholder
        self._text = text
        self._isFocused = isFocused
        self.lineLimit = lineLimit
    }

    var body: some View {
        Field(text: $text, isFocused: $isFocused, lineLimit: lineLimit)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
    }

    private struct Field: UIViewRepresentable {
        @Binding var text: String
        @Binding var isFocused: Bool
        let lineLimit: Int

        func makeUIView(context: Context) -> UITextView {
            let view = UITextView()
            view.delegate = context.coordinator
            view.font = .preferredFont(forTextStyle: .body)
            view.adjustsFontForContentSizeCategory = true
            view.autocapitalizationType = .sentences
            view.backgroundColor = .clear
            // The padding belongs to the caller, the way it did when this was a
            // `TextField`, so the view measures as pure text.
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            view.isScrollEnabled = false
            view.text = text
            return view
        }

        func updateUIView(_ view: UITextView, context: Context) {
            context.coordinator.parent = self

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
            _ proposal: ProposedViewSize, uiView view: UITextView, context: Context
        ) -> CGSize? {
            let width = proposal.width ?? view.bounds.width
            guard width > 0 else { return nil }
            let line = view.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
            let wanted = view.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height
            let ceiling = line * CGFloat(lineLimit)
            let height = min(max(wanted, line), ceiling)
            // Past the limit the box stops growing, so the words have to move
            // instead. A point of slack, because a fitting height and a ceiling
            // computed the same way still disagree in the last decimal.
            let scrolls = wanted > ceiling + 1
            if view.isScrollEnabled != scrolls { view.isScrollEnabled = scrolls }
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
                // Only once it has stopped growing does the caret need chasing.
                if view.isScrollEnabled { view.scrollRangeToVisible(view.selectedRange) }
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
