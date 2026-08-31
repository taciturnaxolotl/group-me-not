import SwiftUI

// MARK: - Conversation list

/// Every group and direct message, most recent first.
///
/// Reads entirely from local storage, so it draws on the first frame after
/// launch whether or not there is a network. Refreshing is something the user
/// may ask for and something the app does quietly in the background; it is
/// never something the list waits on.
struct ConversationListView: View {
    @Environment(AppModel.self) private var model

    @State private var path: [ConversationRow] = []
    @State private var query = ""
    @State private var isSettingsPresented = false

    var body: some View {
        NavigationStack(path: $path) {
            content
                // The title lives in the content, not the bar. A large
                // navigation title always renders on its own row *below* the
                // toolbar, so an avatar in the toolbar can never sit beside it.
                // Drawing both in one header row is what the App Store does for
                // exactly this reason.
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: ConversationRow.self) { row in
                    ChatView(conversation: row)
                }
                .refreshable { await model.refresh() }
                .safeAreaInset(edge: .top, spacing: 0) {
                    NetworkStatusBanner(state: model.syncState)
                }
                .sheet(isPresented: $isSettingsPresented) {
                    SettingsView()
                }
        }
    }

    @ViewBuilder private var content: some View {
        if model.conversations.isEmpty {
            emptyState
        } else if visibleRows.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            list
        }
    }

    private var list: some View {
        List {
            titleHeader
            searchField
            ForEach(visibleRows) { row in
                NavigationLink(value: row) {
                    ConversationCell(row: row)
                }
                .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if row.hasUnread {
                        Button {
                            Task { await model.markRead(row.id) }
                        } label: {
                            Label("Read", systemImage: "envelope.open.fill")
                        }
                        .tint(.blue)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        Task { await model.setMuted(!row.isMuted, for: row.id) }
                    } label: {
                        Label(
                            row.isMuted ? "Unmute" : "Mute",
                            systemImage: row.isMuted ? "bell.fill" : "bell.slash.fill"
                        )
                    }
                    .tint(.indigo)
                }
            }
        }
        .listStyle(.plain)
        // The list is small and entirely local, so the animation is honest:
        // rows really do reorder the instant a message lands.
        .animation(.default, value: visibleRows)
    }

    /// A local, case- and diacritic-insensitive filter.
    ///
    /// Deliberately not a database query. The list tops out in the low
    /// hundreds, so filtering it in memory is a fraction of a millisecond and
    /// spares us a round trip to an actor on every keystroke.
    private var visibleRows: [ConversationRow] {
        // Topics are reached from inside their group, not from here. Six rows
        // named "RULES" and "GRAVEYARD" scattered through a list sorted by
        // recency is a list that has stopped being a list of conversations.
        matching.filter { !$0.isTopic }
    }

    private var matching: [ConversationRow] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return model.conversations }
        return model.conversations.filter { row in
            row.name.localizedStandardContains(term)
                || (row.lastMessagePreview?.localizedStandardContains(term) ?? false)
                || (row.lastMessageSender?.localizedStandardContains(term) ?? false)
        }
    }

    /// Shown before the first sync finishes, and for the rare account with
    /// nothing in it. Either way there is nothing useful to do here, so it says
    /// so plainly instead of spinning.
    @ViewBuilder private var emptyState: some View {
        if model.syncState.isRefreshing {
            ProgressView("Loading conversations")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Groups and direct messages will appear here once they sync.")
            } actions: {
                Button("Refresh") { Task { await model.refresh() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Large title and account avatar on one line, scrolling with the list.
    var titleHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Chats")
                .font(.largeTitle.bold())
            Spacer(minLength: 12)
            accountButton
                // Pulled back to the cap line so the avatar centres against the
                // title rather than hanging off its baseline.
                .alignmentGuide(.firstTextBaseline) { $0.height * 0.78 }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// Search lives in the content rather than the navigation bar's drawer.
    ///
    /// `.searchable` renders its drawer directly under the bar, which would put
    /// it *above* the title row, inverting the order. Since the title already
    /// had to move into the content to sit beside the avatar, the field follows
    /// it, and the two stay in the order a reader expects.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        // The list rows carry 8 of their own, so this is what actually separates
        // the field from the first conversation rather than the whole gap.
        .padding(.bottom, 14)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// Straight to Settings. A menu holding a single item is a tap that buys
    /// nothing: it asks the user to choose between one option, and it hides the
    /// destination behind an animation. Everything account-level already lives
    /// on that screen, including Sign Out, so there is nowhere else this could
    /// reasonably go.
    private var accountButton: some View {
        Button {
            isSettingsPresented = true
        } label: {
            Avatar(
                url: model.currentUser?.imageUrl,
                name: model.currentUser?.name ?? "?",
                size: 28
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
        .accessibilityHint("Your account and preferences")
    }
}

// MARK: - Row

/// One conversation in the list.
///
/// Laid out the way Mail and Messages lay theirs out, because that is the
/// layout people already know how to read: face, then two lines of text, then
/// the time and whatever is still unread.
struct ConversationCell: View {
    let row: ConversationRow

    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 50

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(
                url: row.avatarURL,
                name: row.name,
                size: avatarSize,
                isGroup: row.isGroup
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name.isEmpty ? "Conversation" : row.name)
                        .font(.headline)
                        .lineLimit(1)

                    if row.postingPolicy == .adminsOnly {
                        Image(systemName: "megaphone.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Announcements only")
                    }

                    if row.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }

                    Spacer(minLength: 4)

                    if let date = row.lastMessageAt {
                        Text(Formatters.listTimestamp(date))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }

                HStack(alignment: .top, spacing: 6) {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if row.hasUnread {
                        UnreadBadge(count: row.unreadCount, isMuted: row.isMuted)
                    }
                }
            }
        }
        // One element, one sentence. VoiceOver users should not have to swipe
        // through four fragments to learn who wrote and when.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The sender's name is worth a prefix in a group, where "who said it"
    /// carries as much as "what they said". In a DM it is always the same two
    /// people, so it would be noise.
    private var preview: String {
        guard let text = row.lastMessagePreview, !text.isEmpty else {
            return row.isPlaceholder ? "Syncing…" : "No messages yet"
        }
        // Just the message. Prefixing the sender in groups pushed the useful
        // half off the end of a two-line cell, which is the opposite of what a
        // preview is for. The sender is still searchable.
        return text
    }

    private var accessibilityLabel: String {
        var parts: [String] = [row.name]
        if row.hasUnread {
            parts.append("\(row.unreadCount) unread message\(row.unreadCount == 1 ? "" : "s")")
        }
        if row.isMuted { parts.append("muted") }
        parts.append(preview)
        if let date = row.lastMessageAt { parts.append(Formatters.spokenTimestamp(date)) }
        return parts.joined(separator: ", ")
    }
}

/// The unread count. Muted conversations get a grey badge rather than no badge:
/// muting says "do not interrupt me", not "hide this from me".
/// Shared with the topic picker, which needs the same badge for the same
/// reason: a count is how a list says which rows are worth opening.
struct UnreadBadge: View {
    let count: Int
    let isMuted: Bool

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minWidth: 20)
            .background(isMuted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor), in: .capsule)
            .accessibilityHidden(true)
    }
}

// MARK: - Network status

/// A thin strip that appears when the network is gone.
///
/// It is a strip and not a sheet, an alert, or a full-screen error, because
/// none of those are true: the app works offline. The only thing worth saying
/// is that what you are reading may be a few minutes stale, and that fits in
/// one line.
struct NetworkStatusBanner: View {
    let state: SyncState

    var body: some View {
        if !state.isOnline {
            banner(symbol: "wifi.slash", text: "Offline", tint: .secondary)
        } else if let error = state.lastError {
            banner(symbol: "exclamationmark.triangle.fill", text: error, tint: .orange)
        }
    }

    private func banner(symbol: String, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .imageScale(.small)
            Text(text)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}
