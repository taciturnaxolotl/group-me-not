import SwiftUI

/// The reactions on a message, as chips that straddle the bubble's bottom edge.
///
/// Drawn from `MessageDisplay.reactions`, which was folded once when the
/// transcript was built. This view counts nothing and looks nothing up; it is
/// a pure function of what it was handed, which is what keeps a scroll cheap.
struct ReactionChips: View {
    let summaries: [Message.ReactionSummary]
    /// Chips sit on the trailing corner of my own bubbles and the leading
    /// corner of everyone else's, the way a tapback follows its speaker.
    let isOwn: Bool
    /// Set by the row, which also uses it to reserve the overhang.
    var height: CGFloat = 26
    var onTap: (String) -> Void = { _ in }
    /// A long press, asking who is behind this glyph.
    var onInspect: (Message.ReactionSummary) -> Void = { _ in }

    /// More distinct glyphs than this and the row is wider than the bubble it
    /// hangs off, so the tail collapses into a count.
    static let visibleLimit = 4

    private var shown: [Message.ReactionSummary] { Array(summaries.prefix(Self.visibleLimit)) }
    private var overflow: Int { max(0, summaries.count - Self.visibleLimit) }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(shown) { summary in
                // Gestures rather than a `Button`, because this needs two of
                // them and a button's tap does not share well with a long press
                // on the same view. The button traits are put back below so
                // VoiceOver is unaffected by the change.
                chip(summary)
                    .onTapGesture { onTap(summary.glyph) }
                    .onLongPressGesture(minimumDuration: 0.32) { onInspect(summary) }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(Self.label(for: summary))
                    .accessibilityHint(summary.reactedByMe
                        ? "Removes your reaction" : "Reacts with this")
                    .accessibilityAction(named: "Who reacted") { onInspect(summary) }
            }
            if overflow > 0 { overflowChip }
        }
        // Ideal width, not the bubble's.
        //
        // These are drawn in an overlay, so the bubble's width is what gets
        // proposed to them — and a narrow bubble with a short message proposed
        // less than the chips needed, which `Text` answers by truncating itself
        // to nothing. The counts vanished while the glyphs stayed, because a
        // glyph has no truncation to do. Asking for the ideal size lets the row
        // run past the bubble's edge, which is where a tapback belongs anyway.
        .fixedSize()
        // A ring in the background colour, so the chips read as sitting on top
        // of the bubble rather than being part of it.
        .padding(2)
        .background(Capsule().fill(Color(.systemBackground)))
    }

    private func chip(_ summary: Message.ReactionSummary) -> some View {
        HStack(spacing: 2) {
            ReactionGlyph(glyph: summary.glyph, size: height * 0.5)
            if summary.count > 1 {
                Text("\(summary.count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(summary.reactedByMe
                        ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.horizontal, 7)
        .frame(height: height - 4)
        .background(Capsule().fill(fill(summary)))
        .overlay(Capsule().strokeBorder(border(summary), lineWidth: 1))
        .contentShape(.capsule)
    }

    private var overflowChip: some View {
        Text("+\(overflow)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(height: height - 4)
            .background(Capsule().fill(Color(.secondarySystemFill)))
            .accessibilityLabel("\(overflow) more reaction\(overflow == 1 ? "" : "s")")
    }

    private func fill(_ summary: Message.ReactionSummary) -> AnyShapeStyle {
        summary.reactedByMe
            ? AnyShapeStyle(Color.accentColor.opacity(0.20))
            : AnyShapeStyle(Color(.secondarySystemFill))
    }

    private func border(_ summary: Message.ReactionSummary) -> Color {
        summary.reactedByMe ? Color.accentColor.opacity(0.55) : .clear
    }

    /// Spoken form. VoiceOver reads the count, not the glyph, because the name
    /// of an emoji is rarely what it means here.
    static func label(for summary: Message.ReactionSummary) -> String {
        let people = summary.count == 1 ? "1 person" : "\(summary.count) people"
        return summary.reactedByMe
            ? "\(summary.spokenGlyph), \(people) including you"
            : "\(summary.spokenGlyph), \(people)"
    }
}
