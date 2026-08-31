import SwiftUI

// MARK: - Transcript model

/// One entry in the scrolling transcript.
nonisolated enum TranscriptRow: Identifiable, Hashable, Sendable {
    /// The heading that opens a new day.
    case day(Date)
    case message(MessageDisplay)
    /// Several consecutive notices of one kind, drawn as one line until opened.
    case systemRun(SystemMessageRun)
    /// Where the reader left off.
    case unreadMarker(UnreadMark)

    /// The only row of its kind in a transcript, so a constant is enough and
    /// scrolling to it does not need to know which message it precedes.
    static let unreadMarkerID = "transcript.unread"

    var id: String {
        switch self {
        case .day(let date): "day-\(Int(date.timeIntervalSince1970))"
        case .message(let item): item.id
        case .systemRun(let run): "system-run-\(run.id)"
        case .unreadMarker: Self.unreadMarkerID
        }
    }

    /// Whether this row is something a person sent. Days, dividers and folded
    /// notices are furniture, and counting them as arrivals would put a badge
    /// on the jump button for the passing of midnight.
    var isMessage: Bool {
        if case .message = self { return true }
        return false
    }
}

/// Where the unread divider goes, and what it says.
///
/// Resolved once, when the conversation opens, and then held still. The read
/// receipt posts within a second of arriving, so a marker recomputed from live
/// data would vanish before anyone had used it; the whole value of the thing is
/// that it outlives the state that produced it.
nonisolated struct UnreadMark: Hashable, Sendable {
    /// The first message the reader has not seen. The divider is drawn directly
    /// above it, which keeps the two together when older pages load in and
    /// shift every index.
    let firstUnreadID: String
    let count: Int
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
    ///   - unread: where the reader left off, if anywhere. Already pinned by
    ///     the view; this only places it.
    static func rows(
        messages: [Message],
        outbox: [OutboxEntry],
        currentUser: CurrentUser?,
        unread: UnreadMark? = nil,
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

            // Below the day heading and above the bubble, which is where the
            // eye expects a landmark: the date tells you when, the divider
            // tells you where you stopped.
            if let unread, unread.firstUnreadID == message.id {
                rows.append(.unreadMarker(unread))
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

    // MARK: Scroll state

    /// The clear strip that closes the transcript. Its visibility is what
    /// answers "is the reader at the foot", so it needs enough height to be a
    /// tolerance rather than a hairline.
    private static let footHeight: CGFloat = 24

    /// Whether the foot of the transcript is on screen.
    ///
    /// Observed, not computed. The old test rebuilt the scroll view's maximum
    /// offset out of content size, container size and insets, which meant it
    /// had to know which insets the container already accounted for; it got
    /// that wrong, and every change to the chrome was another chance to get it
    /// wrong again. Asking the scroll view whether the last row is visible has
    /// no arithmetic to keep in step with the bars.
    ///
    /// Starts true because the transcript opens at the newest message.
    @State private var isAtFoot = true

    private var isNearBottom: Bool { isAtFoot }

    /// Whether to draw the way back down. Held apart from `isAtFoot` so it can
    /// settle: it goes true only after the foot has been gone for a moment, and
    /// false the instant it returns. A flick that overshoots and drops back
    /// never shows the button at all.
    @State private var showsJumpButton = false
    @State private var jumpRevealTask: Task<Void, Never>?

    /// How long the foot has to stay away before the button is offered.
    private static let jumpRevealDelay = Duration.milliseconds(400)

    /// How many messages have arrived below the fold since the reader left it.
    /// Drawn as a count on the button, the way Messages does, and cleared when
    /// they get back to the foot.
    @State private var newBelowCount = 0

    /// True while the reader's finger, or its momentum, owns the scroll view.
    /// Nothing may move the content out from under either one.
    @State private var isUserScrolling = false

    /// A follow that arrived while the finger was down. Held, not dropped: the
    /// message did land at the foot, and the reader is standing there. It runs
    /// the moment the scroll view goes quiet.
    @State private var followWhenStill = false

    /// Which end of the content stays put when the content size changes.
    ///
    /// Almost always `nil`, meaning the top: rows appended at the foot, and the
    /// typing bubble coming and going, must not shift what is on screen. It is
    /// flipped to `.bottom` for exactly as long as a page of older history is
    /// being spliced in above the viewport, which is the one case where holding
    /// the *end* of the content still is what keeps the reader in place.
    @State private var sizeChangeAnchor: UnitPoint?
    @State private var anchorResetTask: Task<Void, Never>?

    /// Bumped whenever something has happened that should put the newest
    /// message on screen. Cheaper and more reliable than watching row counts,
    /// and it gives the several callers one place to land.
    @State private var bottomRequest = 0

    /// The scroll view's position, held so this view can move it.
    @State private var scrollPosition = ScrollPosition()
    @State private var isAttachmentPickerPresented = false
    /// Media the user picked but has not sent yet, shown above the field.
    @State private var staged: [PickedMedia] = []

    // MARK: Unread

    /// Where the divider goes, fixed for as long as this view lives. Resolved
    /// on the first fill and never again; see ``UnreadMark``.
    @State private var unread: UnreadMark?
    @State private var hasResolvedUnread = false

    /// The row the transcript opens on, when that is not the newest message.
    /// Set once, consumed once, by the effect inside the `ScrollViewReader`.
    @State private var openingTarget: String?

    /// A quarter of the way down rather than hard against the top edge, so a
    /// little of what was already read stays visible above the divider. Landing
    /// with nothing above it reads as the top of the conversation.
    private static let openingAnchor = UnitPoint(x: 0.5, y: 0.25)

    var body: some View {
        transcript
            .background(Color(.systemBackground))
            // `safeAreaBar`, not `safeAreaInset`. It insets the transcript in
            // the same way, but it also tells the scroll view that what sits
            // there is a *bar*, which is what lets the edge effect dissolve
            // content under it instead of stopping it dead against a slab.
            .safeAreaBar(edge: .bottom, spacing: 0) { composer }
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
            // The indicator changes the content height by about a bubble. A
            // reader at the foot should follow it; a reader in the history
            // should not feel it at all, which is what the missing size-change
            // anchor already guarantees.
            .onChange(of: model.isAnyoneTyping) {
                guard isNearBottom, !isUserScrolling else { return }
                bottomRequest += 1
            }
    }

    // MARK: Transcript

    private var transcript: some View {
        // Two mechanisms, because they are good at different things. The reader
        // scrolls to a *view*, which is what the opening jump needs: it lands on
        // a specific message. The position scrolls to an *edge*, which is what
        // the way back down needs, and is the only one of the two that works
        // when the foot of a `LazyVStack` has not been realised.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    olderHeader
                    messageRows
                    typingRow
                    bottomSpacer
                }
                .padding(.horizontal, 10)
            }
            // The way back down. This used to be `proxy.scrollTo(bottomAnchor)`,
            // and the anchor was the foot of a `LazyVStack`, which does not exist
            // while the reader is up in the history. Which is exactly when the jump
            // button is on screen: the one control whose whole job is "take me back
            // down" was the one that could never do it. An edge asks the scroll view
            // about its content rather than about its children, so there is nothing
            // left to be unrealised.
            .scrollPosition($scrollPosition)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Deliberately optional, and `nil` nearly all the time. See
            // `sizeChangeAnchor`.
            .defaultScrollAnchor(sizeChangeAnchor, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            // Content fades out under the composer rather than sliding beneath
            // a hard edge. This is the other half of `safeAreaBar`; without it
            // the bar floats over a transcript that is plainly still there.
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .onScrollPhaseChange { _, phase in
                // `.animating` is us, not them, and must not lock out the
                // follow that started it.
                isUserScrolling = phase == .tracking
                    || phase == .interacting
                    || phase == .decelerating
                guard !isUserScrolling, followWhenStill else { return }
                followWhenStill = false
                if isNearBottom { bottomRequest += 1 }
            }
            .overlay(alignment: .bottomTrailing) {
                // The stack is the stable parent the transition needs; the `if`
                // lives one level down, inside `jumpButton`.
                // Animated where the state changes rather than here: the
                // reveal is deliberately delayed, and an implicit animation
                // bound to the flag would fire the moment the flag flips
                // regardless of what else the frame is doing.
                ZStack { jumpButton }
            }
            // Short and flat rather than springy. A bouncing settle at the
            // foot is what reads as the transcript overshooting, and several of
            // these can overlap during a catch-up.
            .onChange(of: bottomRequest) {
                withAnimation(.easeOut(duration: 0.22)) {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }
            // Not animated: this is where the conversation opens, not a
            // movement the reader should see happen.
            .onChange(of: openingTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: Self.openingAnchor)
                openingTarget = nil
            }
        }
    }

    /// The way back down, and the only notice a reader up in the history gets
    /// that something has arrived. Small, out of the way, and absent entirely
    /// while they are already at the foot.
    @ViewBuilder private var jumpButton: some View {
        if showsJumpButton {
            Button { bottomRequest += 1 } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                    .overlay(alignment: .topTrailing) { unreadBadge }
            }
            .buttonStyle(.plain)
            // Roomier than it was against the old opaque bar. Glass reads as
            // floating, and something floating needs air around it or the two
            // pieces look like one broken control.
            .padding(.trailing, 16)
            .padding(.bottom, 16)
            // Fades, and barely grows. A button that pops in at the edge of
            // vision reads as an alert; this one is a door left ajar.
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
            .accessibilityLabel(accessibleJumpLabel)
        }
    }

    /// What arrived while the reader was away. A number, not a tint: a colour
    /// change on a button nobody is looking at says nothing, and the one thing
    /// worth saying here is how much they have missed.
    @ViewBuilder private var unreadBadge: some View {
        if newBelowCount > 0 {
            Text(newBelowCount > 99 ? "99+" : "\(newBelowCount)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(Color.accentColor, in: .capsule)
                .offset(x: 7, y: -6)
                .transition(.scale.combined(with: .opacity))
        }
    }

    private var accessibleJumpLabel: String {
        switch newBelowCount {
        case 0: "Jump to latest"
        case 1: "1 new message, jump to latest"
        default: "\(newBelowCount) new messages, jump to latest"
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
            case .unreadMarker(let mark):
                UnreadDivider(count: mark.count)
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

    /// The foot of the transcript: real room under the last bubble, and the
    /// sentinel the whole scroll state is read from. Flush against the composer, the last row's long press competes
    /// with the bar for the same few points and loses about as often as it
    /// wins, so the room is not decoration.
    ///
    /// Deaf to touches, deliberately. It is only ever measured.
    private var bottomSpacer: some View {
        Color.clear
            .frame(height: Self.footHeight)
            .allowsHitTesting(false)
            .onScrollVisibilityChange(threshold: 0.01, footVisibilityChanged)
    }

    /// The one place scroll position turns into state.
    private func footVisibilityChanged(_ visible: Bool) {
        isAtFoot = visible
        jumpRevealTask?.cancel()

        guard !visible else {
            newBelowCount = 0
            withAnimation(.easeInOut(duration: 0.22)) { showsJumpButton = false }
            return
        }
        jumpRevealTask = Task {
            try? await Task.sleep(for: Self.jumpRevealDelay)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.22)) { showsJumpButton = true }
        }
    }

    // MARK: Paging

    /// How far from the top of the loaded history a row has to be before it
    /// asks for the page above it. Ten rows is roughly a screen, so the fetch
    /// is usually finished by the time the reader gets there.
    private static let prefetchDistance = 10

    @ViewBuilder private var olderHeader: some View {
        if model.olderPageFailed {
            // The one case that is neither "more is coming" nor "there is no
            // more": the radio answered nothing. A spinner here would turn a
            // failed request into a permanent one, so the reader gets a
            // sentence and a way to ask again instead.
            Button { requestOlder(retrying: true) } label: {
                Label("Couldn't load earlier messages", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
        } else if model.canLoadOlder {
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
    private func requestOlder(retrying: Bool = false) {
        guard !isLoadingOlder, model.canLoadOlder else { return }
        // A failed page stays failed until the reader asks again. Retrying it
        // on every `onAppear` would hammer a dead radio for as long as the
        // conversation is open.
        guard retrying || !model.olderPageFailed else { return }
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
    ///
    /// There is no background behind any of this, and that is the point. The
    /// two controls carry their own glass and nothing else is drawn, so the
    /// transcript runs underneath the bar and dissolves into it rather than
    /// ending at an opaque edge. The container is what makes the pair read as
    /// one piece of glass with a gap in it instead of two unrelated lozenges.
    private var composer: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                attachButton
                field
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .attachmentPicker(isPresented: $isAttachmentPickerPresented) { picked in
            // Staged rather than sent. Picking a photo and then typing a caption
            // is the common case, and sending on pick would make that
            // impossible.
            staged.append(contentsOf: picked)
            composerFocused = true
        }
    }

    private var attachButton: some View {
        Button { isAttachmentPickerPresented = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .glassEffect(.regular.interactive(), in: .circle)
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
        .glassEffect(.regular, in: .capsule)
        .animation(.snappy(duration: 0.18), value: canSend)
    }

    @ViewBuilder private var sendButton: some View {
        if canSend {
            Button(action: send) {
                // Drawn as a glyph on a filled circle rather than
                // `arrow.up.circle.fill`. The SF Symbol's arrow is small
                // relative to its enclosing ring and the ring cannot be
                // thickened, which reads thinner than the control it is
                // imitating. An explicit circle gets the weight right.
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 29, height: 29)
                    .background(Color.accentColor, in: .circle)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .padding(.bottom, 3)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("Send")
        } else {
            Color.clear.frame(width: 10, height: 1)
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !staged.isEmpty
    }

    /// Clears the field and hands the text off without awaiting anything. The
    /// bubble appears on the next frame; the network hears about it afterwards.
    ///
    /// Sending always goes to the foot, wherever the reader had drifted to. It
    /// is the one movement they asked for.
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let media = staged
        guard !text.isEmpty || !media.isEmpty else { return }
        // Cleared before the await, like the text: the queued row is what the
        // transcript draws from here on, and leaving the tray populated would
        // show the same photo twice.
        draft = ""
        staged = []
        bottomRequest += 1
        Task { await model.send(text, media: media) }
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
        anchorResetTask?.cancel()
        jumpRevealTask?.cancel()
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

        // Before the receipt posts. `messagesChanged` marks the conversation
        // read in a task it kicks off after calling this, so resolving here is
        // what gets the divider in ahead of its own erasure.
        resolveUnreadIfNeeded(in: messages)
        let unread = unread

        rebuildTask?.cancel()
        rebuildTask = Task {
            let built = await Task.detached(priority: .userInitiated) {
                Transcript.rows(messages: messages, outbox: outbox, currentUser: currentUser, unread: unread)
            }.value
            guard !Task.isCancelled else { return }
            // Only when something actually moved.
            //
            // A catch-up rewrites `model.messages` several times a second, and
            // most of those rebuilds produce an identical array. Assigning it
            // anyway changes the transcript's content size, and every
            // content-size change is a chance to shift the rows under a
            // stationary finger, which is what kills a long press.
            guard built != rows else { return }
            apply(built)
        }
    }

    /// Installs a freshly built transcript, having first decided what the
    /// change means for the scroll position.
    ///
    /// Three cases, and they want opposite things:
    ///
    /// - Rows arriving above the ones already on screen. That is a page of
    ///   older history, or the very first fill of an empty transcript. Hold the
    ///   *end* of the content still for the length of the splice so the reader
    ///   does not see it happen.
    /// - Rows arriving at the foot while the reader is there too. Follow them
    ///   down, animated, so a new bubble slides in rather than appearing
    ///   mid-jump.
    /// - Rows arriving at the foot while the reader is up in the history. Move
    ///   nothing. Mark the jump button and let them come down when they like.
    private func apply(_ built: [TranscriptRow]) {
        let grewAbove = rows.isEmpty
            ? !built.isEmpty
            : built.count > rows.count && built.first?.id != rows.first?.id
        let grewBelow = !built.isEmpty && built.last?.id != rows.last?.id
        // Counted before the assignment, and only over real messages: this is
        // what the badge on the jump button says.
        let arrived = built.count(where: \.isMessage) - rows.count(where: \.isMessage)

        // The sixth case: a conversation with unreads opens on the divider
        // rather than at the foot. The end anchor is skipped for that fill,
        // since holding the content's end for the next few frames is the one
        // thing that would drag the view back down off the divider.
        let opensOnDivider = rows.isEmpty && !built.isEmpty && unread != nil

        if grewAbove, !opensOnDivider { holdContentEnd() }
        rows = built

        // After the assignment, so the row it scrolls to exists by the time the
        // effect runs.
        if opensOnDivider { openingTarget = TranscriptRow.unreadMarkerID }

        if grewAbove { return }
        guard grewBelow else { return }
        guard isNearBottom else {
            withAnimation(.snappy(duration: 0.2)) {
                newBelowCount += max(1, arrived)
            }
            return
        }
        // Following is for a reader who is standing still at the foot. While
        // they are dragging, or coasting, the scroll view is theirs; the follow
        // waits for them to stop rather than yanking the content mid-gesture.
        if isUserScrolling {
            followWhenStill = true
        } else {
            bottomRequest += 1
        }
    }

    // MARK: Unread

    /// Works out where the reader left off, once, from the conversation row as
    /// it stood when this view was pushed.
    ///
    /// `conversation` is a snapshot taken at navigation time, so the counts in
    /// it cannot move underneath us; the only reason this has to be guarded is
    /// that the *messages* it resolves against arrive later, and a second pass
    /// over a longer history would find a different answer.
    private func resolveUnreadIfNeeded(in messages: [Message]) {
        guard !hasResolvedUnread, !messages.isEmpty else { return }
        hasResolvedUnread = true

        let count = conversation.unreadCount
        guard count > 0 else { return }

        // The receipt is the good answer: the first message after it is the
        // first thing the reader has not seen.
        if let lastRead = conversation.lastReadMessageID,
           let index = messages.lastIndex(where: { $0.id == lastRead }) {
            guard index + 1 < messages.count else { return }
            unread = UnreadMark(firstUnreadID: messages[index + 1].id, count: count)
            return
        }

        // No receipt, or one older than anything loaded. Counting back from the
        // newest message is the same arithmetic the badge was drawn from, and
        // clamping to the first loaded message is what covers a long absence:
        // everything on screen is unread, so the divider sits at the top of it
        // rather than somewhere off above the loaded window.
        let index = max(0, messages.count - count)
        guard index < messages.count else { return }
        unread = UnreadMark(firstUnreadID: messages[index].id, count: count)
    }

    /// Anchors the content's end for the frame or two it takes the scroll view
    /// to absorb a prepend, then puts it back.
    ///
    /// The window has to outlast the layout pass, not the fetch: the page has
    /// already arrived by the time this runs, and it is the resulting size
    /// change that needs the anchor. Leaving the anchor on any longer would
    /// bring back the every-size-change re-pin this replaced.
    private func holdContentEnd() {
        anchorResetTask?.cancel()
        sizeChangeAnchor = .bottom
        anchorResetTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            sizeChangeAnchor = nil
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

/// The line marking where the reader left off.
///
/// A landmark, not an alert: a hairline rule with a quiet label sitting in it.
/// It carries no colour of its own, because the one thing it must not do is
/// compete with the messages it is pointing at.
private struct UnreadDivider: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            rule
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.4)
            rule
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    private var rule: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(height: 0.5)
    }

    private var label: String {
        count > 1 ? "\(count) unread" : "Unread"
    }

    private var spokenLabel: String {
        count > 1 ? "\(count) unread messages below" : "Unread messages below"
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
