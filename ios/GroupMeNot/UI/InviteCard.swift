import SwiftUI

/// A GroupMe share link, drawn as the invitation it is.
///
/// Left alone it is a link to a web page whose entire purpose is to talk the
/// reader into installing the official client, and the group it points at is
/// one they can already join from here. So the transcript answers the link
/// itself: join, or open the group if this is one they are already in.
///
/// Deliberately not a link preview. The preview endpoint would describe the
/// landing page rather than the group, and "GroupMe — Group Messaging" over a
/// stock photograph tells the reader nothing they did not know.
struct InviteCard: View {
    let link: GroupMeLink
    /// Matched to the bubble it sits in, like the link card next to it.
    let isOwn: Bool
    /// Called with the conversation to open, once there is one.
    var onOpen: (ConversationRow) -> Void = { _ in }

    @Environment(AppModel.self) private var model

    @State private var isJoining = false
    @State private var failed = false

    /// Same width as a link preview, so a bubble carrying either has one edge.
    private static let width: CGFloat = 232
    private static let corner: CGFloat = 18

    /// Set when this is a group we are already in, which turns the whole card
    /// from an invitation into a door.
    private var joined: ConversationRow? {
        model.conversations.first { $0.id == link.conversation }
    }

    var body: some View {
        Button(action: act) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(joined?.name ?? "Group Invite")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(isOwn ? AnyShapeStyle(.white.opacity(0.75))
                                               : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 0)
                if isJoining {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isOwn ? AnyShapeStyle(.white.opacity(0.6))
                                               : AnyShapeStyle(.tertiary))
                }
            }
            .multilineTextAlignment(.leading)
            .foregroundStyle(isOwn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: Self.width)
            .background(tint)
            .clipShape(.rect(cornerRadius: Self.corner, style: .continuous))
            .contentShape(.rect(cornerRadius: Self.corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isJoining)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(joined.map { "Open \($0.name)" } ?? "Join this group")
        .accessibilityAddTraits(.isButton)
    }

    private var icon: some View {
        Image(systemName: joined == nil ? "person.badge.plus" : "bubble.left.and.bubble.right.fill")
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 34, height: 34)
            .background(
                isOwn ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(.quaternary),
                in: .circle)
    }

    private var subtitle: String {
        if failed { return "That link did not work. It may have expired." }
        if joined != nil { return "You are already in this group" }
        return isJoining ? "Joining…" : "Tap to join"
    }

    /// The bubble's own fill, a shade quieter, so the card belongs to the
    /// message rather than sitting on the transcript.
    private var tint: AnyShapeStyle {
        isOwn ? AnyShapeStyle(Color.accentColor.opacity(0.85))
              : AnyShapeStyle(Color(.tertiarySystemFill))
    }

    private func act() {
        if let joined {
            onOpen(joined)
            return
        }
        isJoining = true
        failed = false
        Task {
            let conversation = await model.join(link)
            isJoining = false
            guard let conversation,
                  let row = model.conversations.first(where: { $0.id == conversation })
            else {
                failed = true
                return
            }
            onOpen(row)
        }
    }
}
