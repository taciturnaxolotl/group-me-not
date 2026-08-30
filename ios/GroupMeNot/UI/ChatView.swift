import SwiftUI

// MARK: - Transcript model

/// One entry in the scrolling transcript.
nonisolated enum TranscriptRow: Identifiable, Hashable, Sendable {
    /// The heading that opens a new day.
    case day(Date)
    case message(MessageDisplay)

    var id: String {
        switch self {
        case .day(let date): "day-\(Int(date.timeIntervalSince1970))"
        case .message(let item): item.id
        }
    }
}

/// Turns stored history plus the outbox into rows.
///
/// Kept apart from the view and free of isolation so it can run wherever it is
/// convenient and be reasoned about on its own. It decides three things: where
/// days break, where runs of one person's messages begin and end, and which
/// queued sends still need a bubble of their own.
nonisolated enum Transcript {

    /// Messages closer together than this, from the same person, on the same
    /// day, belong to one run and share a face.
    static let runInterval: TimeInterval = 300

    /// - Parameters:
    ///   - messages: stored history, oldest first.
    ///   - outbox: queued sends for this conversation, oldest first.
    ///   - currentUser: used to attribute the outbox echoes, which have no
    ///     server-assigned sender yet.
    static func rows(
        messages: [Message],
        outbox: [OutboxEntry],
        currentUser: CurrentUser?,
        calendar: Calendar = .current
    ) -> [TranscriptRow] {
        let myID = currentUser?.id

        // A queued send whose real message has already arrived would otherwise
        // draw twice: once as history, once as an echo. The guid is what ties
        // the two together.
        let landedGuids = Set(messages.compactMap(\.sourceGuid))
        let echoes = outbox
            .filter { !landedGuids.contains($0.sourceGuid) }
            .map { entry -> (Message, MessageDisplay.Delivery) in
                let delivery: MessageDisplay.Delivery = entry.state == .failed
                    ? .failed(friendlyFailure(entry))
                    : .pending
                return (entry.localEcho(sender: currentUser), delivery)
            }

        let timeline: [(Message, MessageDisplay.Delivery)] =
            messages.map { ($0, .sent) } + echoes

        var rows: [TranscriptRow] = []
        rows.reserveCapacity(timeline.count + 8)

        for (index, entry) in timeline.enumerated() {
            let (message, delivery) = entry
            let previous = index > 0 ? timeline[index - 1].0 : nil
            let next = index + 1 < timeline.count ? timeline[index + 1].0 : nil

            if previous == nil || !calendar.isDate(previous!.date, inSameDayAs: message.date) {
                rows.append(.day(calendar.startOfDay(for: message.date)))
            }

            let opensRun = previous.map { !continuesRun(from: $0, to: message, calendar: calendar) } ?? true
            let closesRun = next.map { !continuesRun(from: message, to: $0, calendar: calendar) } ?? true

            rows.append(.message(MessageDisplay(
                // Already unique: history carries a server id, and an echo
                // carries its guid until the server assigns one.
                id: message.id,
                message: message,
                isOwn: isOwn(message, myID: myID),
                senderName: message.name ?? "Someone",
                senderAvatarURL: message.avatarUrl,
                showsSender: opensRun,
                isRunTail: closesRun,
                delivery: delivery
            )))
        }
        return rows
    }

    /// System notices never join a run, and neither do messages from different
    /// people, on different days, or minutes apart.
    private static func continuesRun(from previous: Message, to next: Message, calendar: Calendar) -> Bool {
        guard !previous.isSystem, !next.isSystem else { return false }
        guard let a = previous.senderId ?? previous.userId,
              let b = next.senderId ?? next.userId,
              a == b
        else { return false }
        guard calendar.isDate(previous.date, inSameDayAs: next.date) else { return false }
        return abs(next.date.timeIntervalSince(previous.date)) < runInterval
    }

    private static func isOwn(_ message: Message, myID: String?) -> Bool {
        guard let myID else { return false }
        return (message.senderId ?? message.userId) == myID
    }

    /// Outbox errors are transport strings. The bubble gets a sentence a person
    /// can act on; the detail stays in the log.
    private static func friendlyFailure(_ entry: OutboxEntry) -> String? {
        entry.attempts > 1 ? "Not delivered" : "Not delivered yet"
    }
}

// MARK: - View

/// One conversation.
///
/// The transcript reads from local storage and nothing else, so opening a chat
/// is instant whether or not there is a radio. Sending writes to the outbox and
/// returns; the bubble is on screen before any request exists.
struct ChatView: View {
    let conversation: ConversationRow

    @Environment(AppModel.self) private var model

    @State private var rows: [TranscriptRow] = []
    @State private var draft = ""
    @State private var isLoadingOlder = false
    @FocusState private var composerFocused: Bool

    /// The anchor we scroll to after sending, so a fresh bubble is always
    /// visible even if the user had drifted up the history.
    private let bottomAnchor = "transcript.bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    olderHeader

                    ForEach(rows) { row in
                        switch row {
                        case .day(let date):
                            DaySeparator(date: date)
                        case .message(let item):
                            MessageRow(
                                item: item,
                                onRetry: { retry(item) },
                                onDiscard: { discard(item) }
                            )
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
            // Open at the newest message, and stay pinned to it as content
            // changes size. Prepending a page of history therefore leaves the
            // reader exactly where they were, which is the whole trick.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: draftSubmissionCount) {
                withAnimation(.snappy) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
        }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle(conversation.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        // `openConversation` already clears the badge; opening a conversation is
        // reading it.
        .task { await model.openConversation(conversation.id) }
        .onDisappear { model.closeConversation() }
        .onChange(of: model.messages, initial: true) {
            rebuild()
            // Anything that lands while the conversation is on screen has, by
            // any reasonable definition, been read.
            Task { await model.markRead(conversation.id) }
        }
        .onChange(of: model.outbox, initial: true) { rebuild() }
    }

    // MARK: Paging

    @ViewBuilder private var olderHeader: some View {
        if model.canLoadOlder {
            ProgressView()
                .controlSize(.small)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Loading earlier messages")
                .task(id: rows.first?.id) { await loadOlder() }
        } else if !rows.isEmpty {
            Text("Beginning of conversation")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
        } else {
            EmptyState(conversation: conversation)
        }
    }

    private func loadOlder() async {
        guard !isLoadingOlder else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        await model.loadOlder()
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .textInputAutocapitalization(.sentences)
                .lineLimit(1...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.quaternary, in: .capsule)
                .focused($composerFocused)
                .accessibilityLabel("Message")

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.35)
            .animation(.easeOut(duration: 0.15), value: canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // `.bar` keeps the composer legible over whatever scrolls beneath it,
        // and `safeAreaInset` puts it above the keyboard for free.
        .background(.bar)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Bumped on every send purely so the scroll-to-bottom effect has something
    /// to observe. Cheaper and more reliable than watching the row count.
    @State private var draftSubmissionCount = 0

    /// Clears the field and hands the text off without awaiting anything. The
    /// bubble appears on the next frame; the network hears about it afterwards.
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        draftSubmissionCount += 1
        Task { await model.send(text) }
    }

    private func retry(_ item: MessageDisplay) {
        guard let entry = outboxEntry(for: item) else { return }
        Task { await model.retry(entry) }
    }

    private func discard(_ item: MessageDisplay) {
        guard let entry = outboxEntry(for: item) else { return }
        Task { await model.discard(entry) }
    }

    private func outboxEntry(for item: MessageDisplay) -> OutboxEntry? {
        let guid = item.message.sourceGuid ?? item.id
        return model.outbox.first { $0.sourceGuid == guid }
    }

    // MARK: Chrome

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                Avatar(
                    url: conversation.avatarURL,
                    name: conversation.name,
                    size: 28,
                    isGroup: conversation.isGroup
                )
                VStack(spacing: 0) {
                    Text(conversation.name)
                        .font(.headline)
                        .lineLimit(1)
                    if conversation.isGroup, let count = memberCount {
                        Text("\(count) members")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(conversation.name)
        }
    }

    /// The roster once it has been fetched, falling back to whatever the list
    /// row knew. The list row is a snapshot taken at navigation time, so it
    /// cannot learn a count; the model can.
    private var memberCount: Int? {
        model.members.isEmpty ? conversation.memberCount : model.members.count
    }

    // MARK: Row building

    /// Rebuilt on change rather than computed in `body`, so scrolling never
    /// pays for the grouping pass.
    private func rebuild() {
        rows = Transcript.rows(
            messages: model.messages,
            outbox: model.outbox,
            currentUser: model.currentUser
        )
    }
}

// MARK: - Pieces

/// The date heading between days.
private struct DaySeparator: View {
    let date: Date

    var body: some View {
        Text(Formatters.dayHeader(date))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.quaternary, in: .capsule)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .accessibilityLabel(Formatters.spokenDayHeader(date))
    }
}

/// Shown while a conversation we know about has no messages stored yet, which
/// on a cold start lasts about as long as one fetch.
private struct EmptyState: View {
    let conversation: ConversationRow

    var body: some View {
        VStack(spacing: 12) {
            Avatar(
                url: conversation.avatarURL,
                name: conversation.name,
                size: 72,
                isGroup: conversation.isGroup
            )
            Text(conversation.name)
                .font(.title3.weight(.semibold))
            Text("No messages yet. Say something.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .accessibilityElement(children: .combine)
    }
}
