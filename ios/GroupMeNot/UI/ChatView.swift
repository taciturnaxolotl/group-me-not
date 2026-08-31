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
        quoted: [String: Message] = [:],
        unresolved: Set<String> = [],
        members: [Member] = [],
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

        // One pass, so resolving a quote is a dictionary lookup rather than a
        // search of the whole transcript per bubble.
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Originals fetched purely to be quoted sit alongside the loaded window,
        // never inside it: they are here to be read, not to be scrolled to.
        byID.merge(quoted) { loaded, _ in loaded }
        let names = Dictionary(
            members.map { ($0.identity, $0.nickname ?? $0.name ?? "Someone") },
            uniquingKeysWith: { first, _ in first })

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
                reactions: message.reactionSummaries(currentUserID: myID),
                reply: replyPreview(
                    for: message, in: byID, unresolved: unresolved, names: names),
                uploadGuid: message.sourceGuid
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

    /// The quote to draw above a reply, or nil if this is not one.
    ///
    /// A reply whose parent has scrolled out of the loaded window still gets a
    /// quote, with the little that is known. The alternative is drawing the
    /// message as though it answered nothing, which is a different message.
    private static func replyPreview(
        for message: Message, in byID: [String: Message],
        unresolved: Set<String>, names: [String: String]
    ) -> ReplyPreview? {
        guard let targetID = message.replyTargetID else { return nil }
        guard let parent = byID[targetID] else {
            // The reply itself records who was answered, so even with the
            // original still in flight the quote can name the right person.
            // Naming them is most of what a quote is for.
            let who = message.replyTargetUserID.flatMap { names[$0] }
            // "Loading…" is a promise, and it has to be one this can keep. Once
            // the fetch has come back empty the original is not coming, and
            // saying otherwise leaves a quote spinning for as long as the
            // conversation is open.
            let detail = unresolved.contains(targetID) ? "Original unavailable" : "Loading…"
            return ReplyPreview(messageID: nil, senderName: who ?? "Message", text: detail)
        }
        return ReplyPreview(
            messageID: parent.id,
            senderName: parent.name ?? "Someone",
            text: summarise(parent))
    }

    /// One line describing a message, for a quote. Text if it has any, and
    /// otherwise a word for whatever it is instead, because "" in a quote reads
    /// as a bug.
    static func summarise(_ message: Message) -> String {
        if message.isDeleted { return "Deleted message" }
        if let text = message.visibleText, !text.isEmpty { return text }
        guard let type = message.attachments?.first(where: { $0.type != "mentions" })?.type
        else { return "Message" }
        switch type {
        case "image", "linked_image": return "Photo"
        case "video": return "Video"
        case "audio": return "Voice message"
        case "file": return "File"
        case "location": return "Location"
        default: return "Attachment"
        }
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
    @Environment(AppSettings.self) private var settings

    @State private var rows: [TranscriptRow] = []
    @State private var rebuildTask: Task<Void, Never>?
    @State private var draft = ""
    @State private var isLoadingOlder = false
    @State private var isInfoPresented = false
    /// Which of the group's conversations is on screen: the group itself, or one
    /// of its topics. Nil until `.task` resolves the remembered one.
    @State private var activeID: ConversationID?
    @State private var isTopicPickerPresented = false
    /// Set when the transcript is about to be filled for a conversation the
    /// scroll view has already laid out once, which is what switching topics
    /// does. See ``apply(_:)``.
    @State private var needsOpeningScroll = false
    /// The reaction whose people are being looked at.
    @State private var reactionDetail: Message.ReactionSummary?
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

    /// The view every "take me back down" scrolls to. Deliberately not part of
    /// the lazy stack; see ``transcript``.
    private let bottomAnchor = "transcript.bottom"

    /// The message under a long press, if any.
    ///
    /// Held here, and drawn here, rather than presented from the row.
    ///
    /// A `fullScreenCover` or a sheet takes over the window: it resigns first
    /// responder, the keyboard leaves, the safe area shrinks by its height, and
    /// the transcript moves. None of that is anything the reader asked for by
    /// holding a finger on a bubble. An overlay changes no container and no safe
    /// area, so the page cannot scroll, because nothing about the page has
    /// changed. The keyboard is free to stay exactly where it was.
    @State private var pressed: MessagePress?
    /// The message an emoji browser is open for. That one really is a sheet, so
    /// the keyboard does go; `keyboardWasOpen` is how it comes back.
    @State private var emojiTarget: MessagePress?
    @State private var keyboardWasOpen = false
    @State private var editTarget: MessagePress?
    @State private var editDraft = ""
    /// The message being answered, if the composer is in reply mode.
    @State private var replyingTo: Message?

    @State private var isAttachmentPickerPresented = false
    /// Media the user picked but has not sent yet, shown above the field.
    @State private var staged: [PickedMedia] = []

    // MARK: Unread

    /// Where the divider goes, fixed for as long as this view lives. Resolved
    /// on the first fill and never again; see ``UnreadMark``.
    @State private var unread: UnreadMark?
    @State private var hasResolvedUnread = false
    /// Whether the divider has been on screen, so it is only retired by being
    /// scrolled past rather than by never having appeared.
    @State private var hasSeenDivider = false

    /// The row the transcript opens on, when that is not the newest message.
    /// Set once, consumed once, by the effect inside the `ScrollViewReader`.
    @State private var openingTarget: String?

    /// A quarter of the way down rather than hard against the top edge, so a
    /// little of what was already read stays visible above the divider. Landing
    /// with nothing above it reads as the top of the conversation.
    private static let openingAnchor = UnitPoint(x: 0.5, y: 0.25)

    var body: some View {
        lifecycle
    }

    private var chrome: some View {
        transcript
            .background(Color(.systemBackground))
            // `safeAreaBar`, not `safeAreaInset`. It insets the transcript in
            // the same way, but it also tells the scroll view that what sits
            // there is a *bar*, which is what lets the edge effect dissolve
            // content under it instead of stopping it dead against a slab.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if model.canPostInOpenConversation {
                    composer
                } else {
                    readOnlyNotice
                }
            }
            .navigationTitle(current.name)
            .navigationBarTitleDisplayMode(.inline)
            // The header belongs to the same sheet of paper as the transcript.
            // Hiding the bar's own material is what stops the seam appearing
            // when content scrolls under it.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { toolbar }
            .overlay { actionsOverlay }
            .sheet(item: $emojiTarget) { target in
                EmojiBrowser(selected: target.selectedGlyph) { glyph in
                    emojiTarget = nil
                    react(glyph, on: target.item)
                }
            }
            .onChange(of: emojiTarget == nil) { _, closed in
                // The sheet took the keyboard whether we wanted it to or not.
                // Putting it back is the difference between a picker and an
                // interruption.
                guard closed, keyboardWasOpen else { return }
                keyboardWasOpen = false
                composerFocused = true
            }
            .alert("Edit Message", isPresented: .init(
                get: { editTarget != nil },
                set: { if !$0 { editTarget = nil } }
            )) {
                TextField("Message", text: $editDraft)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    guard let target = editTarget else { return }
                    let text = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, text != target.item.message.text else { return }
                    edit(target.item, to: text)
                }
            }
            .sheet(isPresented: $isInfoPresented) {
                ConversationInfoView(conversation: current, members: model.members)
            }
    }

    /// Split off `body` purely so the type checker can finish. Two chains of a
    /// dozen modifiers are two tractable problems; one chain of two dozen is a
    /// build that times out. Nothing here is grouped by meaning, and it would be
    /// dishonest to pretend otherwise.
    private var lifecycle: some View {
        chrome
            .task {
                let start = rememberedRow
                activeID = start.id
                await model.openConversation(start.id)
            }
            .sheet(item: $reactionDetail) { summary in
                ReactionRoster(
                    summary: summary, members: model.members, meID: model.currentUser?.id)
            }
            .sheet(isPresented: $isTopicPickerPresented) {
                TopicPicker(
                    group: conversation,
                    topics: topics,
                    current: current.id,
                    onPick: switchTo)
            }
            .onDisappear(perform: teardown)
            .onChange(of: model.messages, initial: true) { messagesChanged() }
            .onChange(of: model.outbox, initial: true) { rebuild() }
            // A fetched original turns "Loading…" into the message itself, and
            // a failed one turns it into an answer rather than a promise.
            .onChange(of: model.quotedParents) { rebuild() }
            .onChange(of: model.unresolvedQuotes) { rebuild() }
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
        ScrollViewReader { proxy in
            ScrollView {
                // The foot lives outside the lazy stack, and that placement is
                // the whole reason the way back down works. A `LazyVStack` only
                // builds what is near the viewport, so its last child does not
                // exist while the reader is up in the history, and
                // `proxy.scrollTo` on a view that is not in the tree does
                // nothing at all. Which is exactly when the jump button is on
                // screen. A plain `VStack` builds both its children immediately,
                // so the anchor is always there to be scrolled to, and the rows
                // above it stay as lazy as they ever were.
                VStack(spacing: 0) {
                    LazyVStack(spacing: 0) {
                        olderHeader
                        messageRows
                        typingRow
                    }
                    bottomSpacer
                }
                .padding(.horizontal, 10)
                .background(NoScrollToTop().allowsHitTesting(false))
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Deliberately optional, and `nil` nearly all the time. See
            // `sizeChangeAnchor`.
            .defaultScrollAnchor(sizeChangeAnchor, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            // Content fades out under the composer rather than sliding beneath
            // a hard edge. This is the other half of `safeAreaBar`; without it
            // the bar floats over a transcript that is plainly still there.
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            // The same treatment at the head. Content dissolving into the bar
            // rather than sliding under a hard edge is what makes the bar read
            // as part of the same sheet of paper; it is the effect Safari and
            // Messages use, and it is why the toolbar's own material is hidden.
            .scrollEdgeEffectStyle(.soft, for: .top)
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
            // Short and flat rather than springy. A bouncing settle at the
            // foot is what reads as the transcript overshooting, and several of
            // these can overlap during a catch-up.
            .onChange(of: bottomRequest) {
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
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
                    .onScrollVisibilityChange(threshold: 0.2, dividerVisibilityChanged)
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
            onEdit: { text in edit(item, to: text) },
            onPress: { frame in
                pressed = MessagePress(
                    item: item, frame: frame, canEdit: model.canEdit(item.message))
            },
            onOpenReply: { id in openingTarget = id },
            onInspectReaction: { summary in reactionDetail = summary }
        )
    }

    // MARK: Long press

    private var actionsOverlay: some View {
        // The `ZStack` is the stable parent the transition needs, and the
        // animation is bound to presence rather than to identity: pressing a
        // second message while the first is up should swap the contents, not
        // fade one out and another in.
        ZStack {
            if let pressed {
                MessageActionsOverlay(
                    anchor: pressed.frame,
                    glyphs: model.reactionCatalog.quick,
                    selected: pressed.selectedGlyph,
                    actions: actions(for: pressed),
                    onPick: { glyph in
                        self.pressed = nil
                        react(glyph, on: pressed.item)
                    },
                    onMore: {
                        // Remembered before the sheet takes it away.
                        keyboardWasOpen = composerFocused
                        self.pressed = nil
                        emojiTarget = pressed
                    },
                    onDismiss: { self.pressed = nil })
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: pressed == nil)
    }

    /// The rows under the reaction pill. The pill is unconditional; these are
    /// not, and an action that would fail is simply absent.
    private func actions(for press: MessagePress) -> [MessageAction] {
        let item = press.item
        var actions: [MessageAction] = []
        if !item.text.isEmpty, !item.message.isDeleted {
            actions.append(.init("Copy", symbol: "doc.on.doc") {
                UIPasteboard.general.string = item.text.plain
                pressed = nil
            })
        }
        if !item.message.isSystem, !item.message.isDeleted, !item.isPending {
            actions.append(.init("Reply", symbol: "arrowshape.turn.up.left") {
                pressed = nil
                replyingTo = item.message
                composerFocused = true
            })
        }
        if press.canEdit {
            actions.append(.init("Edit", symbol: "pencil") {
                // The server's own text, not the parsed copy: an edit starts
                // from what was actually posted.
                editDraft = item.message.text ?? ""
                pressed = nil
                editTarget = press
            })
        }
        if item.isFailed {
            actions.append(.init("Try Again", symbol: "arrow.clockwise") {
                pressed = nil
                retry(item)
            })
            actions.append(.init("Delete", symbol: "trash", isDestructive: true) {
                pressed = nil
                discard(item)
            })
        }
        return actions
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
            .id(bottomAnchor)
            .onScrollVisibilityChange(threshold: 0.01, footVisibilityChanged)
    }

    /// Retire the divider once the reader has gone past it.
    ///
    /// It marks where reading stopped last time, which is worth knowing on
    /// arrival and worth nothing afterwards; left in place it becomes a line
    /// across a conversation the reader has finished with, and it survives every
    /// rebuild, so it would sit there until the view is torn down.
    ///
    /// Retired on the way *out* of view rather than the way in. A run short
    /// enough to fit on one screen would otherwise vanish the moment it drew,
    /// which is the one case where the divider had no chance to do its job.
    private func dividerVisibilityChanged(_ visible: Bool) {
        if visible {
            hasSeenDivider = true
            return
        }
        guard hasSeenDivider, unread != nil else { return }
        withAnimation(.easeOut(duration: 0.25)) { unread = nil }
    }

    /// The one place scroll position turns into state.
    ///
    /// Only one question is asked of it now: is the reader standing at the foot?
    /// That is what decides whether a new message follows them down or is left
    /// alone. There is no longer a button to reveal, so there is nothing here to
    /// settle or delay.
    private func footVisibilityChanged(_ visible: Bool) {
        isAtFoot = visible
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
            EmptyState(conversation: current)
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

    /// What sits where the composer would, in a topic only admins may post in.
    ///
    /// A bar rather than nothing at all. Removing the composer leaves a screen
    /// that looks like it is still loading one; saying why is the difference
    /// between a restriction and a bug.
    private var readOnlyNotice: some View {
        Label("Only admins can post here", systemImage: "megaphone.fill")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .accessibilityElement(children: .combine)
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
        VStack(alignment: .leading, spacing: 0) {
            if let replyingTo {
                replyBanner(replyingTo)
                Divider().padding(.leading, 14)
            }
            if !staged.isEmpty {
                stagedStrip
                // The whole reason the tray lives inside the field rather than
                // above it. A photo waiting to be sent is part of the message
                // being written, and a hairline is enough to say "these two
                // things go together, and one of them is the words".
                Divider().padding(.leading, 14)
            }

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
        }
        // A rounded rectangle rather than a capsule, because a capsule around a
        // field carrying a row of photos is a stadium: the radius follows the
        // height, and the taller it gets the more the ends bow out. At a single
        // line's height this is within a point of the capsule it replaces.
        .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
        .animation(.snappy(duration: 0.18), value: canSend)
        .animation(.snappy(duration: 0.22), value: staged)
    }

    /// What this message will be answering, with a way out.
    ///
    /// In the field rather than above it, for the same reason the attachments
    /// are: the thing being replied to is part of the message being written.
    private func replyBanner(_ message: Message) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.caption)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(message.name ?? "Someone")
                    .font(.caption.weight(.semibold))
                Text(Transcript.summarise(message))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                replyingTo = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(.quaternary, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel reply")
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }

    /// The photos and videos waiting to go with this message.
    ///
    /// Horizontal and scrolling, so picking eight makes the row longer rather
    /// than making the composer taller. Each carries its own way out: a staged
    /// photo is a decision that has not been committed to yet, and a decision
    /// you cannot reverse is a decision you have to send.
    private var stagedStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(staged) { item in
                    stagedChip(item)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 9)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func stagedChip(_ item: PickedMedia) -> some View {
        // The poster frame first: a video's own URL is a movie, and no image
        // loader makes a thumbnail out of one.
        RemoteImage(url: item.previewURL ?? item.fileURL, maxPixelSize: Self.chipSide * 3) {
            Rectangle().fill(.quaternary)
        }
        .frame(width: Self.chipSide, height: Self.chipSide)
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if item.kind == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.45), in: .circle)
                    .padding(4)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                staged.removeAll { $0.id == item.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(.black.opacity(0.55), in: .circle)
            }
            .buttonStyle(.plain)
            .padding(3)
            .accessibilityLabel("Remove attachment")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.kind == .video ? "Video attachment" : "Photo attachment")
    }

    private static let chipSide: CGFloat = 56

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
        let parent = replyingTo
        draft = ""
        staged = []
        replyingTo = nil
        bottomRequest += 1
        Task { await model.send(text, media: media, replyingTo: parent) }
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

    /// The conversation on screen: the group, or one of its topics.
    ///
    /// Resolved out of the model rather than held, so an unread count or a name
    /// that changes underneath is picked up. The row passed in is only ever the
    /// starting point and a fallback for the frame before the list has it.
    private var current: ConversationRow {
        let id = activeID ?? conversation.id
        return model.conversations.first { $0.id == id } ?? conversation
    }

    /// This group's topics, newest activity first.
    private var topics: [ConversationRow] {
        guard case .group(let id) = conversation.id else { return [] }
        return model.conversations.filter { $0.parentID == id }
    }

    /// Where to start: the topic last read in this group, if it still exists.
    private var rememberedRow: ConversationRow {
        guard case .group(let id) = conversation.id,
              let remembered = settings.lastTopic(inGroup: id),
              let row = topics.first(where: { $0.id.remoteID == remembered })
        else { return conversation }
        return row
    }

    /// Move to another of this group's conversations without leaving the screen.
    ///
    /// The transcript's own state has to go with it. `rows`, the unread divider
    /// and the scroll flags all describe the conversation being left, and
    /// carrying them across would draw one conversation's divider over another's
    /// messages.
    private func switchTo(_ row: ConversationRow) {
        isTopicPickerPresented = false
        guard row.id != current.id else { return }
        if case .group(let id) = conversation.id {
            settings.rememberTopic(row.id.remoteID, inGroup: id)
        }

        activeID = row.id
        needsOpeningScroll = true
        rebuildTask?.cancel()
        rows = []
        unread = nil
        hasResolvedUnread = false
        hasSeenDivider = false
        isAtFoot = true
        Task { await model.openConversation(row.id) }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if !topics.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isTopicPickerPresented = true } label: {
                    Image(systemName: "square.stack.3d.up")
                }
                .accessibilityLabel("Topics")
                .accessibilityHint("Switch between this group's topics")
            }
        }
        ToolbarItem(placement: .principal) {
            Button { isInfoPresented = true } label: { titleLabel }
                .buttonStyle(.plain)
                .accessibilityLabel(titleAccessibilityLabel)
                .accessibilityHint("Shows conversation details")
        }
    }

    /// The face, then the name in a capsule of its own.
    ///
    /// The capsule is not decoration. Without it the name is loose text on a
    /// transparent bar, sitting over whatever happens to be scrolling behind it,
    /// and there is no telling where the tappable part ends. A bordered pill
    /// says "this is a control, and it is exactly this big", which is what a
    /// transparent bar takes away and has to give back some other way.
    private var titleLabel: some View {
        // Negative spacing, so the pill tucks up behind the foot of the picture
        // and the two read as one control rather than as a photo with a caption
        // under it. Safe in a way `.offset` would not be: spacing is layout, so
        // the stack reports the shorter height it actually occupies, and the bar
        // sizes itself to what is drawn.
        VStack(spacing: -6) {
            Avatar(
                url: current.avatarURL,
                name: current.name,
                size: 62,
                isGroup: current.isGroup
            )
            // A stack draws in order, so the pill would otherwise cover the
            // photo. Lifting the photo instead puts the overlap the right way
            // round: the face stays whole and the pill runs behind it.
            .zIndex(1)
            HStack(spacing: 3) {
                Text(current.name)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 6)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        // Clear of the status bar. A picture that starts where the safe area
        // does is a picture touching the clock, and this item is tall enough
        // that the bar grows to fit it rather than the other way round.
        .padding(.top, 14)
        // On the pieces, not on the whole stack. The gap between the face and
        // the name is not part of either, and a hit area that covers it is a hit
        // area covering the bar itself.
        .accessibilityElement(children: .combine)
    }

    private var titleAccessibilityLabel: String {
        guard current.isGroup, let count = memberCount else { return current.name }
        return "\(current.name), \(count) members"
    }

    /// The roster once it has been fetched, falling back to whatever the list
    /// row knew. The list row is a snapshot taken at navigation time, so it
    /// cannot learn a count; the model can.
    private var memberCount: Int? {
        model.members.isEmpty ? current.memberCount : model.members.count
    }

    // MARK: Row building

    private func teardown() {
        rebuildTask?.cancel()
        anchorResetTask?.cancel()
        model.closeConversation()
    }

    private func messagesChanged() {
        rebuild()
        // Anything that lands while the conversation is on screen has, by any
        // reasonable definition, been read.
        Task { await model.markRead(current.id) }
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
        let quoted = model.quotedParents
        let unresolved = model.unresolvedQuotes
        let members = model.members

        // Before the receipt posts. `messagesChanged` marks the conversation
        // read in a task it kicks off after calling this, so resolving here is
        // what gets the divider in ahead of its own erasure.
        resolveUnreadIfNeeded(in: messages)
        let unread = unread

        rebuildTask?.cancel()
        rebuildTask = Task {
            let built = await Task.detached(priority: .userInitiated) {
                Transcript.rows(
                    messages: messages, outbox: outbox, currentUser: currentUser,
                    quoted: quoted, unresolved: unresolved, members: members, unread: unread)
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

        // The first fill after switching topics.
        //
        // On the first fill of the *view*, the newest message is on screen
        // because `defaultScrollAnchor(.bottom, for: .initialOffset)` put it
        // there. Switching topics does not get that: the scroll view has been
        // laid out already and keeps the offset it had, so a new transcript
        // arrives showing its oldest message. Asking for the foot here is the
        // equivalent of that initial anchor, and it defers to the unread divider
        // when there is one, because that is a better place to land than either.
        if needsOpeningScroll, !built.isEmpty {
            needsOpeningScroll = false
            if !opensOnDivider { bottomRequest += 1 }
            return
        }

        if grewAbove { return }
        guard grewBelow else { return }
        // A reader up in the history is left exactly where they are. Nothing
        // announces the new message: they will scroll down when they mean to,
        // and moving the transcript under them would be the rudest thing this
        // view could do.
        guard isNearBottom else { return }
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

        let count = current.unreadCount
        guard count > 0 else { return }

        // The receipt is the good answer: the first message after it is the
        // first thing the reader has not seen.
        if let lastRead = current.lastReadMessageID,
           let index = messages.lastIndex(where: { $0.id == lastRead }) {
            guard index + 1 < messages.count else { return }
            // Counted from where the divider lands, not taken from the badge.
            //
            // The two are different numbers arrived at different ways: the badge
            // is the server's tally and the divider is placed from the read
            // receipt, and they drift apart whenever one is fresher than the
            // other. A divider reading "3 unread" with one message under it is
            // not a small inaccuracy, it is a label contradicting the thing it
            // labels. Deriving the count from the position makes them agree by
            // construction.
            unread = UnreadMark(
                firstUnreadID: messages[index + 1].id,
                count: messages.count - (index + 1))
            return
        }

        // No receipt, or one older than anything loaded. Counting back from the
        // newest message is the same arithmetic the badge was drawn from, and
        // clamping to the first loaded message is what covers a long absence:
        // everything on screen is unread, so the divider sits at the top of it
        // rather than somewhere off above the loaded window.
        let index = max(0, messages.count - count)
        guard index < messages.count else { return }
        unread = UnreadMark(firstUnreadID: messages[index].id, count: messages.count - index)
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

/// Switches off the status bar's scroll-to-top gesture for the scroll view it
/// is placed inside.
///
/// The gesture means "go to the beginning of the content", which in almost every
/// app is helpful and in a transcript is the least useful place there is: the
/// beginning of a chat is the oldest message anybody has ever sent in it. Worse,
/// the target is the whole status bar, so it fires on a tap near the header that
/// was meant for the header, and a year of history goes past in one frame.
///
/// A probe rather than a modifier because SwiftUI exposes no way to say this. It
/// walks up from its own position in the view tree to the enclosing
/// `UIScrollView`, which is one hop in practice.
private struct NoScrollToTop: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let probe = Probe()
        // It is a background spanning the whole transcript. Left interactive it
        // would quietly swallow every tap that lands between two bubbles.
        probe.isUserInteractionEnabled = false
        return probe
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? Probe)?.disable()
    }

    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            disable()
        }

        func disable() {
            var ancestor: UIView? = superview
            while let current = ancestor {
                if let scrollView = current as? UIScrollView {
                    scrollView.scrollsToTop = false
                    return
                }
                ancestor = current.superview
            }
        }
    }
}

/// Somewhere to choose between a group's conversations.
///
/// A sheet rather than a menu. Topics carry unread counts and posting rules, and
/// a menu row is a line of text: it can show which one you are in, but not that
/// two of them have something waiting or that one of them is read-only.
private struct TopicPicker: View {
    /// The group itself, which is a conversation like any other and is listed
    /// first because it is the one that existed before anybody added topics.
    let group: ConversationRow
    let topics: [ConversationRow]
    let current: ConversationID
    let onPick: (ConversationRow) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section { row(for: group, name: "Main") }
                if !topics.isEmpty {
                    Section("Topics") {
                        ForEach(topics) { topic in row(for: topic, name: topic.name) }
                    }
                }
            }
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(for conversation: ConversationRow, name: String) -> some View {
        Button {
            onPick(conversation)
        } label: {
            HStack(spacing: 12) {
                Avatar(
                    url: conversation.avatarURL,
                    name: name,
                    size: 32,
                    isGroup: conversation.isGroup
                )
                Text(name.isEmpty ? "Untitled" : name)
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                if conversation.postingPolicy == .adminsOnly {
                    Image(systemName: "megaphone.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Announcements only")
                }

                Spacer(minLength: 8)

                UnreadBadge(count: conversation.unreadCount, isMuted: conversation.isMuted)

                if conversation.id == current {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Currently open")
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// Who reacted with one glyph.
///
/// A sheet raised by holding a chip. The chip can only ever show a number, and a
/// number is the least interesting thing about a reaction in a group of forty
/// people: the question is always *who*.
private struct ReactionRoster: View {
    let summary: Message.ReactionSummary
    let members: [Member]
    /// So the reader can find themselves in a long list without reading it.
    let meID: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                    HStack(spacing: 12) {
                        Avatar(url: person.imageURL, name: person.name, size: 34)
                        Text(person.name)
                        if person.isYou {
                            Text("You")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            // Empty, because the principal item below carries the title along
            // with the glyph it is about. Setting both draws one over the other.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        ReactionGlyph(glyph: summary.glyph, size: 18)
                        Text(title).font(.headline)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        summary.count == 1 ? "1 reaction" : "\(summary.count) reactions"
    }

    /// The roster is the group's, so anybody who has since left it is an id with
    /// no name. They are still listed: dropping them would make the sheet
    /// disagree with the count on the chip it came from.
    private var people: [Person] {
        let byID = Dictionary(
            members.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        return summary.userIDs.map { id in
            let member = byID[id]
            return Person(
                name: member?.nickname ?? member?.name ?? "Someone",
                imageURL: member?.imageUrl,
                isYou: id == meID)
        }
    }

    private struct Person {
        let name: String
        let imageURL: String?
        let isYou: Bool
    }
}
