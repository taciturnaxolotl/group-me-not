import SwiftUI

/// What is behind the chevron under the chat title.
///
/// A group gets its roster; a DM gets the one person it is with. Everything
/// here comes from what the model already holds, so the sheet is drawn on the
/// frame it is presented and never waits for a request.
struct ConversationInfoView: View {
    let conversation: ConversationRow
    let members: [Member]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section { header.listRowSeparator(.hidden) }
                if !people.isEmpty { roster }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: 10) {
            Avatar(
                url: conversation.avatarURL,
                name: conversation.name,
                size: 88,
                isGroup: conversation.isGroup
            )
            Text(conversation.name)
                .lineLimit(2)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var roster: some View {
        Section(conversation.isGroup ? "Members" : "Conversation") {
            ForEach(people, id: \.identity) { member in
                HStack(spacing: 12) {
                    Avatar(url: member.imageUrl, name: displayName(member), size: 34)
                    Text(displayName(member))
                        .lineLimit(1)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Content

    /// A DM has no roster worth listing, so the other person stands in for one.
    private var people: [Member] {
        guard members.isEmpty else { return members }
        guard !conversation.isGroup else { return [] }
        return [Member(id: nil, userId: conversation.id.storageKey, nickname: conversation.name, name: nil, imageUrl: conversation.avatarURL, roles: nil)]
    }

    private var subtitle: String? {
        guard conversation.isGroup else { return "Direct message" }
        guard let count = memberCount else { return "Group" }
        return count == 1 ? "1 member" : "\(count) members"
    }

    private var memberCount: Int? {
        members.isEmpty ? conversation.memberCount : members.count
    }

    private func displayName(_ member: Member) -> String {
        member.nickname ?? member.name ?? "Someone"
    }
}
