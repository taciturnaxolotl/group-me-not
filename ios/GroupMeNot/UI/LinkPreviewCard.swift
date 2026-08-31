import SwiftUI

/// What a link in a message looks like, once the server has described it.
///
/// Three rules, all of them about not moving the transcript underneath the
/// reader:
///
/// 1. The card is a fixed size from the first layout pass. The image lands
///    inside a frame that was already the right shape.
/// 2. While the answer is unknown the space is reserved, so the arrival of a
///    preview is a fade rather than a shove.
/// 3. A link that declines to describe itself renders nothing at all. There is
///    no error state, because a missing preview is not a failure the reader
///    needs to hear about.
///
/// With no network this view is simply never anything, which is the correct
/// offline behaviour: the link itself is already in the bubble above.
struct LinkPreviewCard: View {
    let url: URL
    let isOwn: Bool
    /// Nil in previews and tests, where the card stays a placeholder and then
    /// disappears.
    let service: LinkPreviewService?
    /// Matched to the bubble's, so the card reads as part of the same object.
    var cornerRadius: CGFloat = 18

    /// The same width the attachment thumbnails use, so a bubble carrying both
    /// has one edge rather than two.
    private static let width: CGFloat = 232
    private static let imageHeight: CGFloat = 122
    private static let captionHeight: CGFloat = 58

    private enum Phase: Equatable {
        case loading
        case ready(LinkPreview)
        case absent
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @State private var phase: Phase = .loading

    var body: some View {
        content
            // Keyed on the appearance too: GroupMe renders some previews itself
            // and returns different art for dark mode.
            .task(id: TaskKey(url: url, dark: colorScheme == .dark)) { await load() }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .absent:
            EmptyView()
        case .loading:
            placeholder
        case .ready(let preview):
            card(preview)
                .transition(.opacity)
        }
    }

    /// The reserved space. Same size as the real card, so nothing jumps when
    /// the answer arrives.
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(tint)
            .frame(width: Self.width, height: Self.imageHeight + Self.captionHeight)
            .overlay {
                Image(systemName: "link")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
            .accessibilityHidden(true)
    }

    private func card(_ preview: LinkPreview) -> some View {
        Button {
            openURL(preview.canonicalURL ?? url)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                image(preview)
                caption(preview)
            }
            .frame(width: Self.width)
            .background(tint)
            .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken(preview))
        .accessibilityAddTraits(.isLink)
    }

    /// Always drawn, even when the preview has no art, so every card in a
    /// transcript is the same height and the column stays calm.
    private func image(_ preview: LinkPreview) -> some View {
        RemoteImage(url: preview.imageURL, maxPixelSize: Self.width * 3) {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "safari")
                    .font(.title)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: Self.width, height: Self.imageHeight)
        .clipped()
    }

    private func caption(_ preview: LinkPreview) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(preview.title ?? preview.summary ?? host)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(preview.siteName ?? host)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(isOwn ? AnyShapeStyle(.white.opacity(0.75))
                                       : AnyShapeStyle(.secondary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.captionHeight, alignment: .top)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .foregroundStyle(isOwn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    }

    /// The bubble's own fill, a shade quieter, so the card belongs to the
    /// message rather than sitting on the transcript.
    private var tint: AnyShapeStyle {
        isOwn ? AnyShapeStyle(Color.accentColor.opacity(0.85))
              : AnyShapeStyle(Color(.tertiarySystemFill))
    }

    private var host: String {
        url.host()?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
    }

    private func spoken(_ preview: LinkPreview) -> String {
        [preview.title, preview.siteName ?? host, "link"]
            .compactMap(\.self).joined(separator: ", ")
    }

    private nonisolated struct TaskKey: Hashable {
        var url: URL
        var dark: Bool
    }

    /// Cache first, so a row scrolled back into view draws its card in the same
    /// frame it appears. Only a genuine miss reaches the network, and only the
    /// network can move this off `.loading`.
    private func load() async {
        // No model to ask, which happens in previews and tests. Reserving space
        // for an answer that will never come would be a permanent grey box.
        guard let service else {
            phase = .absent
            return
        }
        let dark = colorScheme == .dark

        // Also the reset for a recycled row: a hit redraws in this frame, a
        // miss puts the placeholder back rather than leaving the previous
        // message's card on screen.
        let hit = await service.cached(for: url, dark: dark)
        phase = hit.map(Phase.ready) ?? .loading
        if hit != nil { return }

        let fetched = await service.preview(for: url, dark: dark)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            phase = fetched.map(Phase.ready) ?? .absent
        }
    }
}
