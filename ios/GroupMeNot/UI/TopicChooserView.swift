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

    @State private var roster: [Member] = []
    @State private var isInfoPresented = false

    private var canEdit: Bool { model.role(in: group.id).canEditGroup }

    /// The group as the store holds it *now*, not as it was when this page was
    /// pushed.
    ///
    /// `group` is a value copied out of the list at navigation time, and its
    /// unread count is a number that was true then. The topics below it are
    /// read live from the model and update themselves; Main was the one row on
    /// this page still quoting a snapshot, so reading Main and swiping back
    /// left its badge sitting there until something else reloaded the list.
    private var main: ConversationRow {
        model.conversations.first { $0.id == group.id } ?? group
    }

    var body: some View {
        List {
            Section { row(for: main, named: "Main") }
            if !topics.isEmpty {
                Section("Topics") {
                    ForEach(topics) { topic in row(for: topic, named: topic.name) }
                }
            }
        }
        .navigationTitle(main.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Group Info", systemImage: "info.circle") {
                        isInfoPresented = true
                    }
                    if canEdit {
                        NavigationLink {
                            NewTopicView(conversation: main)
                        } label: {
                            Label("Add Topic", systemImage: "plus")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Group options")
            }
        }
        .sheet(isPresented: $isInfoPresented) {
            ConversationInfoView(conversation: main, members: roster)
        }
        // The roster is read here because nothing is open: `model.members`
        // belongs to whatever transcript is on screen, and on this page there
        // is not one.
        .task { roster = await model.roster(of: group.id) }
    }

    private var topics: [ConversationRow] {
        guard case .group(let id) = group.id else { return [] }
        return model.conversations.filter { $0.parentID == id }
    }

    /// What can be done to one of these without opening it.
    ///
    /// Muting is the common one and belongs on the row rather than three screens
    /// in. The rest is admin work, and a topic is the only thing here that can
    /// be deleted — Main is the group.
    @ViewBuilder private func actions(for conversation: ConversationRow) -> some View {
        Button {
            Task { await model.setMuted(!conversation.isMuted, for: conversation.id) }
        } label: {
            Label(
                conversation.isMuted ? "Unmute" : "Mute",
                systemImage: conversation.isMuted ? "bell.fill" : "bell.slash.fill")
        }
        if canEdit {
            NavigationLink {
                GroupSettingsView(
                    conversation: conversation,
                    myNickname: nickname(in: conversation))
            } label: {
                Label(
                    conversation.isTopic ? "Topic Settings" : "Group Settings",
                    systemImage: "slider.horizontal.3")
            }
        }
    }

    private func nickname(in conversation: ConversationRow) -> String {
        guard let me = model.currentUser?.id,
              let mine = roster.first(where: { $0.identity == me })
        else { return "" }
        return mine.nickname ?? mine.name ?? ""
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
        .contextMenu { actions(for: conversation) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
