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
    @Environment(AppSettings.self) private var settings

    @State private var path: [Route] = []
    @State private var query = ""
    @State private var isSettingsPresented = false
    /// Groups whose topics are showing, by group id. Not persisted: which
    /// branches of a list are open is the shape of one visit to it.
    @State private var expanded: Set<String> = []
    @State private var isRequestsPresented = false
    /// The tile a long press landed on, named in the sheet that follows so
    /// there is no doubt which one is about to change.
    @State private var pinTarget: ConversationRow?

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
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .chat(let row):
                        ChatView(conversation: row)
                    case .topics(let group):
                        TopicChooserView(group: group) { path.append(.chat($0)) }
                    }
                }
                .refreshable { await model.refresh() }
                .safeAreaInset(edge: .top, spacing: 0) {
                    NetworkStatusBanner(state: model.syncState)
                }
                .sheet(isPresented: $isSettingsPresented) {
                    SettingsView()
                }
                .sheet(isPresented: $isRequestsPresented) {
                    RequestsView()
                }
                .confirmationDialog(
                    pinTarget?.name ?? "",
                    isPresented: .init(
                        get: { pinTarget != nil },
                        set: { if !$0 { pinTarget = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    if let target = pinTarget {
                        let key = target.id.storageKey
                        let isPinned = settings.isPinned(key)
                        Button(isPinned ? "Unpin" : "Pin") {
                            withAnimation(.snappy(duration: 0.25)) { settings.togglePin(key) }
                            pinTarget = nil
                        }
                        .disabled(!isPinned && !settings.canPinMore)
                        Button("Cancel", role: .cancel) { pinTarget = nil }
                    }
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
            if model.waitingRequests > 0 && query.isEmpty { requestsRow }
            if !pinnedRows.isEmpty && query.isEmpty { pinnedStrip }
            ForEach(entries) { entry in
                SwiftUI.Group {
                    if entry.isGrid {
                        topicGrid(entry)
                    } else if entry.isExpandable {
                        // A header, not a destination. Its children include the
                        // main conversation, so sending the tap there as well
                        // would give one row two meanings.
                        Button {
                            toggle(entry.row)
                        } label: {
                            ConversationCell(entry: entry)
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink(value: Route.chat(entry.row)) {
                            ConversationCell(entry: entry)
                        }
                    }
                }
                .listRowInsets(entry.isGrid
                    ? EdgeInsets()
                    : .init(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(entry.isGrid ? .hidden : .visible)
                // Long press to pin, on every row that is a conversation. The
                // swipe is still there; this is the gesture people reach for.
                .contextMenu {
                    if !entry.isGrid {
                        pinButton(for: entry.row)
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if entry.row.hasUnread {
                        Button {
                            Task { await model.markRead(entry.row.id) }
                        } label: {
                            Label("Read", systemImage: "envelope.open.fill")
                        }
                        .tint(.blue)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        Task { await model.setMuted(!entry.row.isMuted, for: entry.row.id) }
                    } label: {
                        Label(
                            entry.row.isMuted ? "Unmute" : "Mute",
                            systemImage: entry.row.isMuted ? "bell.fill" : "bell.slash.fill"
                        )
                    }
                    .tint(.indigo)

                    if !entry.isGrid { pinButton(for: entry.row).tint(.orange) }
                }
            }
        }
        .listStyle(.plain)
        // The list is small and entirely local, so the animation is honest:
        // rows really do reorder the instant a message lands.
        .animation(.default, value: entries)
        .animation(.snappy(duration: 0.25), value: settings.pinned)
    }

    /// A local, case- and diacritic-insensitive filter.
    ///
    /// Deliberately not a database query. The list tops out in the low
    /// hundreds, so filtering it in memory is a fraction of a millisecond and
    /// spares us a round trip to an actor on every keystroke.
    private var visibleRows: [ConversationRow] { matching }

    /// Only when there is something in it.
    ///
    /// A permanent row saying "no requests" is a row that teaches people to
    /// ignore that part of the screen, which is the opposite of what it is for.
    private var requestsRow: some View {
        Button {
            isRequestsPresented = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "tray.fill")
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor, in: .circle)
                Text("Requests")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                UnreadBadge(count: model.waitingRequests, isMuted: false)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// Pin or unpin, wherever the gesture came from.
    @ViewBuilder private func pinButton(for row: ConversationRow) -> some View {
        let key = row.id.storageKey
        let isPinned = settings.isPinned(key)
        Button {
            withAnimation(.snappy(duration: 0.25)) { settings.togglePin(key) }
        } label: {
            Label(
                isPinned ? "Unpin" : "Pin",
                systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
        }
        // Silently doing nothing at the limit would read as broken, so at the
        // limit the action is simply not offered.
        .disabled(!isPinned && !settings.canPinMore)
    }

    /// A group's conversations as tiles, in the same shape the pinned strip
    /// uses.
    ///
    /// Rows with a rule down their left edge were decoration pretending to be
    /// structure: eight of them read as a list that had gone wrong. Tiles say
    /// "these belong together" by being a block, which is what an expanded group
    /// actually is.
    private func topicGrid(_ entry: Entry) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
            spacing: 14
        ) {
            ForEach(entry.members) { member in
                ConversationTile(
                    row: member,
                    name: member.id == entry.row.id ? "Main" : member.name,
                    unread: member.unreadCount,
                    size: 52,
                    onLongPress: { pinTarget = member }
                ) {
                    path.append(.chat(member))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .listRowBackground(Color.clear)
    }

    /// The pinned conversations, in the order they were pinned.
    ///
    /// Resolved against the live list rather than stored whole, so a pinned
    /// conversation that is renamed or gains an unread is right without the
    /// preference knowing anything about conversations.
    private var pinnedRows: [ConversationRow] {
        let byKey = Dictionary(
            model.conversations.map { ($0.id.storageKey, $0) },
            uniquingKeysWith: { first, _ in first })
        return settings.pinned.compactMap { byKey[$0] }
    }

    /// Faces along the top, the way iMessage does it.
    ///
    /// A picture and a name, and no preview: the point of pinning is to get
    /// somewhere in one tap, and a preview would make each one as tall as the
    /// row it replaced. Hidden while searching, because a search should look
    /// through everything rather than have part of it pinned above the results.
    private var pinnedStrip: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Pinned")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)

            // Three fixed columns rather than an adaptive fit, so the grid is
            // the same shape on every phone and a pin does not move when the
            // one before it is removed.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 14) {
                ForEach(pinnedRows) { row in
                    pinnedTile(row)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// A plain `Button`, not a `NavigationLink`.
    ///
    /// A link inside a grid inside a `List` row is drawn as a list row: it takes
    /// the disclosure chevron, and it resolves its destination against the row
    /// it is nested in rather than the value it was given, which is why tapping
    /// a pinned chat opened somebody else's messages. Pushing the route by hand
    /// has neither problem.
    private func pinnedTile(_ row: ConversationRow) -> some View {
        ConversationTile(
            row: row,
            name: row.name,
            unread: unreadTotal(for: row),
            size: 60,
            leadsToChooser: hasTopics(row),
            onLongPress: { pinTarget = row }
        ) {
            path.append(destination(for: row))
        }
    }

    /// A pinned group answers for its topics, the same way a collapsed one does
    /// in the list. A tile has nothing to expand, so if it did not carry their
    /// unread the only sign of a message in a topic would be a conversation the
    /// pin was meant to save you from opening.
    private func unreadTotal(for row: ConversationRow) -> Int {
        guard case .group(let id) = row.id else { return row.unreadCount }
        return model.conversations
            .filter { $0.parentID == id }
            .reduce(row.unreadCount) { $0 + $1.unreadCount }
    }

    private func hasTopics(_ row: ConversationRow) -> Bool {
        guard case .group(let id) = row.id else { return false }
        return model.conversations.contains { $0.parentID == id }
    }

    private func destination(for row: ConversationRow) -> Route {
        hasTopics(row) ? .topics(row) : .chat(row)
    }

    private func toggle(_ row: ConversationRow) {
        let id = row.id.remoteID
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// The list as drawn: groups, and beneath an expanded one its main
    /// conversation and each of its topics.
    ///
    /// Collapsed by default, because a group's topics are its business and six
    /// extra rows in everybody's list is the tail wagging the dog. Sorting them
    /// in by recency, which is what the list did briefly, scattered rows named
    /// "RULES" and "GRAVEYARD" through it with nothing to say what they belonged
    /// to.
    private var entries: [Entry] {
        let rows = matching
        let byParent = Dictionary(grouping: rows.filter(\.isTopic)) { $0.parentID ?? "" }
        guard !byParent.isEmpty else { return rows.map { Entry(row: $0) } }

        var out: [Entry] = []
        for row in rows where !row.isTopic && !isPinnedAndShown(row) {
            guard case .group(let id) = row.id, let topics = byParent[id], !topics.isEmpty else {
                out.append(Entry(row: row))
                continue
            }
            let isOpen = expanded.contains(id)
            out.append(Entry(
                row: row,
                isExpandable: true,
                isExpanded: isOpen,
                // Collapsed, the group has to answer for its topics: hiding a
                // row must not hide the fact that something is waiting in it.
                badge: row.unreadCount + topics.reduce(0) { $0 + $1.unreadCount }))
            guard isOpen else { continue }
            // One entry holding the whole set, drawn as a grid. Main first,
            // because it is the conversation that existed before anybody added
            // topics.
            out.append(Entry(row: row, members: [row] + topics))
        }
        // A topic whose group is filtered out by the search term keeps its own
        // place rather than disappearing with it.
        let shown = Set(out.map(\.row.id))
        out.append(contentsOf: rows.filter(\.isTopic)
            .filter { !shown.contains($0.id) }
            .map { Entry(row: $0) })
        return out
    }

    /// A pinned conversation is drawn in the strip instead of in the list, but
    /// only while the strip is on screen: a search hides the strip, and hiding
    /// the row as well would be a search that cannot find a pinned chat.
    private func isPinnedAndShown(_ row: ConversationRow) -> Bool {
        query.isEmpty && settings.isPinned(row.id.storageKey)
    }

    /// One drawn row. A conversation can appear twice — once as the header for
    /// its topics and once as "Main" beneath them — so identity is the pairing
    /// of the conversation with its role, not the conversation alone.
    struct Entry: Identifiable, Hashable {
        let row: ConversationRow
        var isExpandable = false
        var isExpanded = false
        var label: String?
        var badge: Int?
        /// When this is non-empty the entry is not a conversation but the set of
        /// them belonging to the group above it, drawn as tiles. The group's own
        /// row is the first member.
        var members: [ConversationRow] = []

        var isGrid: Bool { !members.isEmpty }
        var id: String { "\(row.id.storageKey)#\(isGrid ? "grid" : "row")" }
        var name: String { label ?? row.name }
        var unread: Int { badge ?? row.unreadCount }
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

/// Where a tap in the list goes.
///
/// Two cases because a pinned group with topics has nothing to open: the list's
/// own disclosure is not available to a tile, so it pushes a page that offers
/// the choice instead.
enum Route: Hashable {
    case chat(ConversationRow)
    case topics(ConversationRow)
}

// MARK: - Row

/// One conversation in the list.
///
/// Laid out the way Mail and Messages lay theirs out, because that is the
/// layout people already know how to read: face, then two lines of text, then
/// the time and whatever is still unread.
struct ConversationCell: View {
    let entry: ConversationListView.Entry

    private var row: ConversationRow { entry.row }

    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 50

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(
                url: row.avatarURL,
                name: entry.name,
                size: avatarSize,
                isGroup: row.isGroup
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name.isEmpty ? "Conversation" : entry.name)
                        .font(.headline)
                        .lineLimit(1)

                    if entry.isExpandable {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(entry.isExpanded ? 90 : 0))
                            .animation(.snappy(duration: 0.2), value: entry.isExpanded)
                            .accessibilityHidden(true)
                    }

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

                    UnreadBadge(count: entry.unread, isMuted: row.isMuted)
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
        var parts: [String] = [entry.name]
        if entry.unread > 0 {
            parts.append("\(entry.unread) unread message\(entry.unread == 1 ? "" : "s")")
        }
        if entry.isExpandable {
            parts.append(entry.isExpanded ? "topics showing" : "has topics")
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

    /// Nothing at zero. A badge exists to say "there is something here", so one
    /// reading "0" is a badge arguing with itself; the callers should not each
    /// have to remember that.
    @ViewBuilder var body: some View {
        if count > 0 { badge }
    }

    private var badge: some View {
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

/// A conversation as a face and a name.
///
/// Shared by the pinned strip and by an expanded group's topics, which is the
/// point: both are "a handful of conversations that belong together", and
/// drawing them the same way is what makes the second one legible. Rows with a
/// rule down the side were decoration pretending to be structure.
struct ConversationTile: View {
    let row: ConversationRow
    /// Usually the conversation's name, but "Main" for a group standing in for
    /// itself among its own topics.
    let name: String
    let unread: Int
    var size: CGFloat = 56
    /// Marks a tile that opens a choice rather than a conversation.
    var leadsToChooser = false
    /// Held rather than long-pressed into a `contextMenu`.
    ///
    /// A `contextMenu` declared inside a `List` row is installed on the *row*,
    /// and the row here is the whole grid: holding one tile offered a menu for
    /// all of them at once. An explicit gesture on the tile is attached to the
    /// tile, which is the only thing that reliably is.
    var onLongPress: (() -> Void)?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Avatar(url: row.avatarURL, name: name, size: size, isGroup: row.isGroup)
                    .overlay(alignment: .topTrailing) {
                        UnreadBadge(count: unread, isMuted: row.isMuted)
                            .offset(x: 6, y: -2)
                    }
                    .overlay(alignment: .bottomTrailing) { hints }
                Text(name)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0.35) { onLongPress?() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(unread > 0 ? "\(name), \(unread) unread" : name)
    }

    /// Two things worth knowing before tapping: that this leads to a choice
    /// rather than a conversation, and that it is one nobody can post in.
    @ViewBuilder private var hints: some View {
        if leadsToChooser {
            badge("square.stack.3d.up.fill", tint: Color.accentColor)
        } else if row.postingPolicy == .adminsOnly {
            badge("megaphone.fill", tint: .secondary)
        }
    }

    private func badge(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(4)
            .background(tint, in: .circle)
            .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5))
    }
}


