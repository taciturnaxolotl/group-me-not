import SwiftUI

// MARK: - Transcript model

/// One entry in the scrolling transcript.
nonisolated enum TranscriptRow: Identifiable, Hashable, Sendable {
    /// The heading that opens a new day.
    case day(Date)
    case message(MessageDisplay)
    /// Several consecutive notices of one kind, drawn as one line until opened.
    case systemRun(SystemMessageRun)

    var id: String {
        switch self {
        case .day(let date): "day-\(Int(date.timeIntervalSince1970))"
        case .message(let item): item.id
        case .systemRun(let run): "system-run-\(run.id)"
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
        // Last, over finished rows: the fold only has to look at neighbours
        // once every other decision has been made.
        return SystemMessageRun.collapsing(rows)
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
///
/// The body here is deliberately thin. Every region is its own property or its
/// own small view, because a single expression holding the transcript, the
/// composer and the toolbar is more than the type checker will solve in the
/// time anyone is willing to wait for it.
struct ChatView: View {
    let conversation: ConversationRow

    @Environment(AppModel.self) private var model

    @State private var rows: [TranscriptRow] = []
    @State private var rebuildTask: Task<Void, Never>?
    @State private var draft = ""
    @State private var isLoadingOlder = false
    @State private var isInfoPresented = false
    @FocusState private var composerFocused: Bool

    /// The anchor we scroll to after sending, so a fresh bubble is always
    /// visible even if the user had drifted up the history.
    private let bottomAnchor = "transcript.bottom"

    var body: some View {
        transcript
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .navigationTitle(conversation.name)
            .navigationBarTitleDisplayMode(.inline)
            // The header belongs to the same sheet of paper as the transcript.
            // Hiding the bar's own material is what stops the seam appearing
            // when content scrolls under it.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { toolbar }
            .sheet(isPresented: $isInfoPresented) {
                ConversationInfoView(conversation: conversation, members: model.members)
            }
            .task { await model.openConversation(conversation.id) }
            .onDisappear(perform: teardown)
            .onChange(of: model.messages, initial: true) { messagesChanged() }
            .onChange(of: model.outbox, initial: true) { rebuild() }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    olderHeader
                    messageRows
                    typingRow
                    bottomSpacer
                }
                .padding(.horizontal, 10)
                // Real room under the last bubble. Flush against the composer's
                // safe-area boundary, the last row's long press competes with
                // the inset view for the same few points and loses about as
                // often as it wins.
                .padding(.bottom, 14)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: draftSubmissionCount) {
                withAnimation(.snappy) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private var messageRows: some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            switch row {
            case .day(let date):
                DaySeparator(date: date)
            case .message(let item):
                messageRow(item)
                    .onAppear { prefetchOlderIfNeeded(atRow: index) }
            case .systemRun(let run):
                SystemRunRow(run: run) { messageRow($0) }
                    .onAppear { prefetchOlderIfNeeded(atRow: index) }
            }
        }
    }

    private func messageRow(_ item: MessageDisplay) -> some View {
        MessageRow(
            item: item,
            catalog: model.reactionCatalog,
            previews: model.previews,
            onReact: { glyph in react(glyph, on: item) },
            onRetry: { retry(item) },
            onDiscard: { discard(item) },
            // Asked each time the row is built, so the action disappears on its
            // own once the server's edit window closes.
            canEdit: model.canEdit(item.message),
            onEdit: { text in edit(item, to: text) }
        )
    }

    @ViewBuilder private var typingRow: some View {
        if model.isAnyoneTyping {
            TypingIndicator(names: model.typingNames)
                .transition(.opacity)
                // Scoped to the indicator. An implicit animation on the whole
                // stack re-animates every row on every typing event, which is
                // both wasted work and a way to lose a long press mid-flight.
                .animation(.easeOut(duration: 0.2), value: model.isAnyoneTyping)
        }
    }

    private var bottomSpacer: some View {
        Color.clear
            .frame(height: 1)
            .id(bottomAnchor)
    }

    // MARK: Paging

    /// How far from the top of the loaded history a row has to be before it
    /// asks for the page above it. Ten rows is roughly a screen, so the fetch
    /// is usually finished by the time the reader gets there.
    private static let prefetchDistance = 10

    @ViewBuilder private var olderHeader: some View {
        if model.canLoadOlder {
            ProgressView()
                .controlSize(.small)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Loading earlier messages")
                // A second, belt-and-braces trigger. The prefetch below
                // normally fires first; this catches the case where the
                // whole of history fits on one screen.
                .onAppear { requestOlder() }
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

    private func prefetchOlderIfNeeded(atRow index: Int) {
        guard index < Self.prefetchDistance else { return }
        requestOlder()
    }

    /// Idempotent by construction: a request in flight is never joined by a
    /// second one, and the flag is cleared on every path out of the load, so a
    /// page that turns up nothing cannot wedge paging shut. The next row to
    /// appear near the top asks again.
    private func requestOlder() {
        guard !isLoadingOlder, model.canLoadOlder else { return }
        isLoadingOlder = true
        Task {
            await model.loadOlder()
            isLoadingOlder = false
        }
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
            attachButton
            field
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // The same paper as the transcript, not a bar laid on top of it. This
        // still stops scrolled content showing through, because `safeAreaInset`
        // draws in front; it just does not announce itself while doing so.
        //
        // `ignoresSafeArea` is not optional here. `safeAreaInset` seats the
        // composer *above* the home indicator, and a plain colour, unlike the
        // `.bar` material this replaced, does not reach down into that strip on
        // its own. Without it the transcript shows through under the composer.
        .background(Color(.systemBackground).ignoresSafeArea(edges: .bottom))
    }

    private var attachButton: some View {
        Button(action: {}) {
            Image(systemName: "plus")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(.quaternary, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add attachment")
    }

    private var field: some View {
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

            sendButton
        }
        .background {
            Capsule().fill(.quaternary.opacity(0.5))
            Capsule().strokeBorder(.quaternary, lineWidth: 0.75)
        }
        .animation(.snappy(duration: 0.18), value: canSend)
    }

    @ViewBuilder private var sendButton: some View {
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

    /// New text for one of our own messages. Optimistic, like a reaction: the
    /// bubble changes now and the model puts it back if the server refuses.
    private func edit(_ item: MessageDisplay, to text: String) {
        Task { await model.edit(item.message, to: text) }
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
            Button { isInfoPresented = true } label: { titleLabel }
                .buttonStyle(.plain)
                .accessibilityLabel(titleAccessibilityLabel)
                .accessibilityHint("Shows conversation details")
        }
    }

    private var titleLabel: some View {
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
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var titleAccessibilityLabel: String {
        guard conversation.isGroup, let count = memberCount else { return conversation.name }
        return "\(conversation.name), \(count) members"
    }

    /// The roster once it has been fetched, falling back to whatever the list
    /// row knew. The list row is a snapshot taken at navigation time, so it
    /// cannot learn a count; the model can.
    private var memberCount: Int? {
        model.members.isEmpty ? conversation.memberCount : model.members.count
    }

    // MARK: Row building

    private func teardown() {
        rebuildTask?.cancel()
        model.closeConversation()
    }

    private func messagesChanged() {
        rebuild()
        // Anything that lands while the conversation is on screen has, by any
        // reasonable definition, been read.
        Task { await model.markRead(conversation.id) }
    }

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
            // Only when something actually moved.
            //
            // A catch-up rewrites `model.messages` several times a second, and
            // most of those rebuilds produce an identical array. Assigning it
            // anyway changes the transcript's content size, and a content-size
            // change while the scroll view is pinned to the bottom makes it
            // re-anchor, which shifts the rows under a stationary finger. That
            // is what kills a long press on the newest messages while leaving
            // one in the middle of the history alone: re-anchoring only moves
            // content for a reader who is already at the bottom.
            guard built != rows else { return }
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

/// A folded run of system notices: one quiet line that opens into the server's
/// own sentences, verbatim. The lid keeps its own state, so a run the reader
/// opened stays open across rebuilds; `SystemMessageRun.id` is what makes that
/// identity hold.
private struct SystemRunRow<Row: View>: View {
    let run: SystemMessageRun
    @ViewBuilder let row: (MessageDisplay) -> Row

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.22)) { isExpanded.toggle() } } label: {
                HStack(spacing: 4) {
                    Text(run.summary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: .capsule)
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(run.summary)
            .accessibilityHint(isExpanded ? "Hides the notices" : "Shows the notices")

            if isExpanded {
                ForEach(run.items) { item in row(item) }
            }
        }
        .padding(.vertical, 6)
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

/// Three dots in an incoming bubble, at the foot of the transcript.
///
/// Nobody sends a "stopped typing" frame, so this appears on an event and
/// leaves on a timeout. The names are no longer drawn, because Messages does
/// not draw them either, but they are still what VoiceOver reads: a bubble of
/// dots is nothing to speak aloud.
private struct TypingIndicator: View {
    let names: [String]

    var body: some View {
        HStack {
            TypingDots()
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.quaternary, in: .rect(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
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

/// The animation itself, kept apart so its `@State` is created and destroyed
/// with the bubble rather than living for the length of the conversation.
private struct TypingDots: View {
    @State private var phase = 0.0

    private static let dotSize: CGFloat = 7
    private static let period = 1.2
    /// A third of the cycle between neighbours, which is what makes it read as
    /// a travelling wave rather than three lights blinking.
    private static let stagger = 0.2

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: Self.dotSize, height: Self.dotSize)
                    .scaleEffect(scale(index))
                    .opacity(opacity(index))
            }
        }
        .onAppear {
            withAnimation(.linear(duration: Self.period).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    /// A raised cosine over the cycle, offset per dot. Smooth at the wrap,
    /// which a keyframe list of discrete states is not.
    private func wave(_ index: Int) -> Double {
        let t = (phase - Double(index) * Self.stagger).truncatingRemainder(dividingBy: 1)
        let wrapped = t < 0 ? t + 1 : t
        return (1 - cos(wrapped * 2 * .pi)) / 2
    }

    private func scale(_ index: Int) -> Double { 0.75 + 0.35 * wave(index) }
    private func opacity(_ index: Int) -> Double { 0.4 + 0.6 * wave(index) }
}
