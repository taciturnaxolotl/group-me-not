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

            // Parsing and reaction folding happen here, once, and never in a
            // `body`. This whole function runs off the main actor; see
            // `ChatView.rebuild()`.
            let own = isOwn(message, myID: myID)
            let text = MessageTextParser.parse(message)

            rows.append(.message(MessageDisplay(
                // Already unique: history carries a server id, and an echo
                // carries its guid until the server assigns one.
                id: message.id,
                message: message,
                isOwn: own,
                senderName: message.name ?? "Someone",
                senderAvatarURL: message.avatarUrl,
                showsSender: opensRun,
                isRunTail: closesRun,
                delivery: delivery,
                text: text,
                styledText: MessageStyling.style(text, isOwn: own),
                reactions: message.reactionSummaries(currentUserID: myID)
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
    @State private var rebuildTask: Task<Void, Never>?
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
                                catalog: model.reactionCatalog,
                                previews: model.previews,
                                onReact: { glyph in react(glyph, on: item) },
                                onRetry: { retry(item) },
                                onDiscard: { discard(item) }
                            )
                        }
                    }

                    if model.isAnyoneTyping {
                        TypingIndicator(names: model.typingNames)
                            .transition(.opacity)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                .animation(.easeOut(duration: 0.2), value: model.isAnyoneTyping)
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
        .onDisappear {
            rebuildTask?.cancel()
            model.closeConversation()
        }
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

    /// Messages-shaped: a round attach button, then a capsule that grows with
    /// the text and carries its own send button once there is something to send.
    ///
    /// The send control lives *inside* the capsule rather than beside it so the
    /// field keeps its full width while empty, which is the detail that makes
    /// the whole bar read as native rather than approximately native.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: {}) {
                Image(systemName: "plus")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(.quaternary, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add attachment")

            HStack(alignment: .bottom, spacing: 4) {
                TextField("Message", text: $draft, axis: .vertical)
                    .textInputAutocapitalization(.sentences)
                    .lineLimit(1...6)
                    .padding(.leading, 14)
                    .padding(.vertical, 7)
                    .focused($composerFocused)
                    .accessibilityLabel("Message")
                    .onChange(of: draft) { _, text in
                        // Throttled inside the socket client, so every keystroke
                        // calling this is the intended usage.
                        guard !text.isEmpty else { return }
                        Task { await model.userIsTyping() }
                    }

                if canSend {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 27))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color(.systemBackground), Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 3)
                    .padding(.bottom, 2)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Send")
                } else {
                    Color.clear.frame(width: 10, height: 1)
                }
            }
            .background {
                Capsule().fill(.quaternary.opacity(0.5))
                Capsule().strokeBorder(.quaternary, lineWidth: 0.75)
            }
            .animation(.snappy(duration: 0.18), value: canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
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

    /// A tapped chip or glyph. The model works out whether that adds, swaps or
    /// clears, and it does so optimistically, so the chip is redrawn from the
    /// next `model.messages` change rather than from anything this view keeps.
    private func react(_ glyph: String, on item: MessageDisplay) {
        guard item.canReact else { return }
        Task { await model.toggleReaction(glyph, on: item.message) }
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
            VStack(spacing: 2) {
                Avatar(
                    url: conversation.avatarURL,
                    name: conversation.name,
                    size: 30,
                    isGroup: conversation.isGroup
                )
                HStack(spacing: 3) {
                    Text(conversation.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                conversation.isGroup && memberCount != nil
                    ? "\(conversation.name), \(memberCount!) members"
                    : conversation.name
            )
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
    ///
    /// And rebuilt *off* the main actor, because the pass now parses every
    /// message's links and mentions. Two hundred rows of `NSDataDetector` is
    /// not something to run between two frames. The inputs are all value types
    /// and the output is one array, so the hop costs a copy and nothing else.
    ///
    /// Cancelling the previous build matters more than it looks: a catch-up
    /// writes several times a second, and only the last answer is wanted.
    private func rebuild() {
        let messages = model.messages
        let outbox = model.outbox
        let currentUser = model.currentUser

        rebuildTask?.cancel()
        rebuildTask = Task {
            let built = await Task.detached(priority: .userInitiated) {
                Transcript.rows(messages: messages, outbox: outbox, currentUser: currentUser)
            }.value
            guard !Task.isCancelled else { return }
            rows = built
        }
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

/// "Alice is typing…", at the foot of the transcript.
///
/// Nobody sends a "stopped typing" frame, so this appears on an event and
/// leaves on a timeout. Names come from the group roster when we hold one; a DM
/// gets the anonymous form, which reads fine when there is only one other
/// person it could be.
private struct TypingIndicator: View {
    let names: [String]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "ellipsis.bubble")
                .imageScale(.small)
            Text(sentence)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sentence)
    }

    private var sentence: String {
        switch names.count {
        case 0: "Typing…"
        case 1: "\(names[0]) is typing…"
        case 2: "\(names[0]) and \(names[1]) are typing…"
        default: "Several people are typing…"
        }
    }
}
