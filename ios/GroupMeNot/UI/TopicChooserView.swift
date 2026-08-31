import SwiftUI

/// Which of a group's conversations to open.
///
/// Reached from a pinned tile, which is the one place a group with topics cannot
/// simply expand: the list's disclosure needs a row and a tile has none. So the
/// choice becomes a page rather than a gesture.
///
/// Main first, because it is the conversation that existed before anybody added
/// topics and is what "the group" usually means.
struct TopicChooserView: View {
    let group: ConversationRow
    let open: (ConversationRow) -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section { row(for: group, named: "Main") }
            if !topics.isEmpty {
                Section("Topics") {
                    ForEach(topics) { topic in row(for: topic, named: topic.name) }
                }
            }
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var topics: [ConversationRow] {
        guard case .group(let id) = group.id else { return [] }
        return model.conversations.filter { $0.parentID == id }
    }

    private func row(for conversation: ConversationRow, named name: String) -> some View {
        Button {
            open(conversation)
        } label: {
            HStack(spacing: 12) {
                Avatar(
                    url: conversation.avatarURL,
                    name: name,
                    size: 36,
                    isGroup: conversation.isGroup
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.isEmpty ? "Untitled" : name)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if let preview = conversation.lastMessagePreview, !preview.isEmpty {
                        Text(preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if conversation.postingPolicy == .adminsOnly {
                    Image(systemName: "megaphone.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Announcements only")
                }

                Spacer(minLength: 8)
                UnreadBadge(count: conversation.unreadCount, isMuted: conversation.isMuted)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
