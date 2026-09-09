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
/// Parsed and styled message text, remembered between transcript rebuilds.
///
/// Keyed by a message's id and the stamp of its last revision, so an edit or a
/// reaction lands a new entry and everything else is answered from memory. Held
/// by the view, so it lives and dies with one open conversation.
///
/// A class with a lock rather than an actor: `Transcript.rows` is synchronous
/// and runs off the main actor, and hopping onto an actor for every message
/// would cost more than the parse it is saving.
nonisolated final class StyledTextCache: @unchecked Sendable {
    struct Entry {
        var text: MessageText
        var styled: AttributedString
    }

    private struct Key: Hashable {
        var id: String
        var stamp: Int
        var isOwn: Bool
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    /// Past this the conversation has been scrolled a very long way back, and
    /// the oldest entries are cheaper to rebuild than to keep.
    private static let capacity = 3_000

    func entry(for message: Message, isOwn: Bool) -> Entry {
        // `updated_at` is the revision marker for the only two things this
        // draws: an edit moves it, and so does the optimistic copy the composer
        // writes before the server has agreed — and a failed edit puts the old
        // stamp back, which correctly finds the old entry again. A tombstone
        // joins it because deleting is the other way text stops being text.
        let key = Key(
            id: message.id,
            stamp: (message.updatedAt ?? 0) &+ (message.deletedAt ?? 0),
            isOwn: isOwn)

        lock.lock()
        if let hit = entries[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let derived = Self.derive(message, isOwn: isOwn)

        lock.lock()
        if entries.count >= Self.capacity { entries.removeAll(keepingCapacity: true) }
        entries[key] = derived
        lock.unlock()
        return derived
    }

    static func derive(_ message: Message, isOwn: Bool) -> Entry {
        let text = message.announcesItsAttachment ? .empty : MessageTextParser.parse(message)
        return Entry(text: text, styled: MessageStyling.style(text, isOwn: isOwn))
    }
}

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
        styling: StyledTextCache? = nil,
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
            messages.filter { !$0.isMessageNotice }.map { ($0, .sent) } + echoes

        // One pass, so resolving a quote is a dictionary lookup rather than a
        // search of the whole transcript per bubble.
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Originals fetched purely to be quoted sit alongside the loaded window,
        // never inside it: they are here to be read, not to be scrolled to.
        byID.merge(quoted) { loaded, _ in loaded }
        let names = Dictionary(
            members.map { ($0.identity, $0.nickname ?? $0.name ?? "Someone") },
            uniquingKeysWith: { first, _ in first })

        // One count per chain root, so a message can be told how many answers
        // it has without every bubble searching the transcript for them.
        var answers: [String: Int] = [:]
        for message in messages {
            guard let root = message.replyRootID else { continue }
            answers[root, default: 0] += 1
        }

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
            // Parsed once per revision of a message rather than once per pass.
            // A catch-up rewrites the transcript several times a second, and
            // running a data detector over two hundred messages each time to
            // arrive at the same answer is most of what this function costs.
            let styled = styling?.entry(for: message, isOwn: own)
                ?? StyledTextCache.derive(message, isOwn: own)

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
                text: styled.text,
                styledText: styled.styled,
                reactions: message.reactionSummaries(currentUserID: myID),
                reply: replyPreview(
                    for: message, in: byID, unresolved: unresolved, names: names),
                // On the root only. A reply already says it is one by carrying
                // a quote, and stamping a count on every link of the chain
                // would say the same thing five times.
                replyCount: message.replyRootID == nil ? (answers[message.id] ?? 0) : 0,
                uploadGuid: message.sourceGuid
            )))
        }
        // Last, over finished rows: the fold only has to look at neighbours
        // once every other decision has been made.
        return SystemMessageRun.collapsing(rows)
    }

    /// Every message in one reply chain, oldest first, root included.
    ///
    /// A chain is flat by GroupMe's design, so this is a filter and not a walk:
    /// each reply already records the root it belongs to.
    static func chain(rootedAt rootID: String, in messages: [Message]) -> [Message] {
        messages
            .filter { $0.id == rootID || $0.replyRootID == rootID }
            .sorted { $0.date < $1.date }
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
            return ReplyPreview(
                messageID: nil, senderID: message.replyTargetUserID,
                senderName: who ?? "Message", text: detail)
        }
        return ReplyPreview(
            messageID: parent.id,
            senderID: parent.senderId ?? parent.userId,
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
    /// Pushed by the caller that owns the navigation path. Raised from a share
    /// link in the transcript, which is the one thing in here that can lead to
    /// a different conversation.
    var onOpenConversation: (ConversationRow) -> Void = { _ in }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [TranscriptRow] = []
    @State private var rebuildTask: Task<Void, Never>?
    @State private var draft = ""
    @State private var isLoadingOlder = false
    @State private var isInfoPresented = false
    @State private var isPinnedPresented = false
    /// The message whose reactions are being looked at.
    ///
    /// A box rather than a plain `@State`, and read by nobody in this body.
    /// Setting a state this view reads re-evaluates it, transcript and all,
    /// and that recompute runs *before* UIKit begins the presentation: it is
    /// the gap between holding a chip and seeing the sheet move. Holding the
    /// target off to one side means the only thing invalidated is the host
    /// that presents it.
    @State private var reactionDetail = RosterTarget()
    @State private var composerFocused = false
    /// Whose profile is open, if anybody's.
    @State private var viewingPerson: PersonRef?
    /// Parsed text, kept across rebuilds. Lives as long as this view does,
    /// which is as long as the conversation is open.
    @State private var styling = StyledTextCache()
    /// The open conversation's row, resolved when the list changes rather than
    /// once per bubble per pass; see ``current``.
    @State private var currentRow: ConversationRow?

    // MARK: Scroll state

    /// The clear strip that closes the transcript. Its visibility is what
    /// answers "is the reader at the foot", so it needs enough height to be a
    /// tolerance rather than a hairline — but no more than that, because it is
    /// also the whole of the gap between the last bubble and the composer.
    private static let footHeight: CGFloat = 12

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

    /// False until the navigation transition has had the screen to itself.
    /// See ``shownRows``.
    @State private var isSettled = false

    /// How tall the hovering reply bubble is; see ``replyHover(_:)``.
    @State private var replyHoverHeight: CGFloat = 0

    /// Past this a hovering reply scrolls instead of climbing the screen. The
    /// point is recognising what was tapped, and a paragraph and a half does
    /// that.
    private static let replyHoverLimit: CGFloat = 190

    /// How much of the window the first frames draw.
    ///
    /// Opening anchors the scroll view at the bottom, and a `LazyVStack` cannot
    /// place a bottom anchor without sizing every row above it, so the whole
    /// loaded window — fifty bubbles, each with styled text, glass and a
    /// geometry reader — is built in one main-thread pass. That pass lands in
    /// the middle of the navigation transition and stops it dead, with the
    /// header halfway across the screen.
    ///
    /// A screenful is what the reader can see, and it is what the push carries.
    /// The rest is spliced in behind them a moment later, above the viewport,
    /// held in place by the same anchor a page of older history uses — so the
    /// transcript arrives complete without anything having moved.
    private static let firstPaintRows = 14

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

    /// Whether growth in the content should keep the newest message on screen.
    ///
    /// The reader standing at the foot is the ordinary case, and it is the one
    /// the timed hold above could not cover. A transcript that opens cold keeps
    /// growing for seconds after its rows arrive: images decode, quoted
    /// originals come back from the network, link cards resolve. Every point of
    /// that growth used to push the newest message further under the composer,
    /// which is what "it did not scroll the whole way down" is. Following the
    /// foot for as long as the reader is standing at it needs no timer and no
    /// guess about how long settling takes.
    ///
    /// Cleared when the transcript is deliberately parked somewhere else — an
    /// unread divider, or a jump to a pinned message — and restored the moment
    /// the foot comes back into view.
    @State private var pinsFoot = true

    /// Which end of the content holds still, given both reasons to hold the
    /// end: a page spliced in above, and a reader standing at the foot.
    private var contentAnchor: UnitPoint? {
        sizeChangeAnchor ?? (pinsFoot ? .bottom : nil)
    }

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
    /// The message a Delete is being confirmed for.
    @State private var deleteTarget: MessagePress?
    @State private var editDraft = ""
    /// The message being answered, if the composer is in reply mode.
    @State private var replyingTo: Message?

    @State private var isAttachmentPickerPresented = false
    @State private var isNewPollPresented = false
    /// True while an answer to a message request is in flight; see
    /// ``messageRequestBar(_:)``.
    @State private var answeringRequest = false
    @State private var isNewEventPresented = false
    /// Media the user picked but has not sent yet, shown above the field.
    @State private var staged: [PickedMedia] = []
    /// People named in the draft so far, in the order they were chosen.
    ///
    /// Kept rather than re-derived, because a name in the text is not enough to
    /// find a person: two members can share one, and the draft only carries what
    /// was typed. Locating them in the text happens once, at send.
    @State private var named: [MentionDraft.Named] = []

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
    /// The chain being read on its own. Nil the rest of the time, which is
    /// most of it.
    @State private var thread: ThreadFocus?
    /// A jump whose row has not been built yet. See `focus(on:)`.
    @State private var pendingTarget: String?

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
            // A share link is tappable twice over: as the card under the
            // bubble and as the URL inside it. Both should do the same thing,
            // or the text is a trapdoor out of the app to a web page whose one
            // purpose is to sell the official client.
            .environment(\.openURL, OpenURLAction { url in
                guard let link = GroupMeLink(url: url) else { return .systemAction }
                Task {
                    if let row = model.conversations.first(where: { $0.id == link.conversation }) {
                        onOpenConversation(row)
                    } else if let joined = await model.join(link),
                              let row = model.conversations.first(where: { $0.id == joined }) {
                        onOpenConversation(row)
                    }
                }
                return .handled
            })
            // Under the bar, and under the toolbar, which are both drawn
            // above the content and so stay crisp. Only the conversation
            // recedes, which is the whole idea: the message being answered is
            // lifted out of it and everything else steps back.
            .overlay { replyScrim }
            // `safeAreaBar`, not `safeAreaInset`. It insets the transcript in
            // the same way, but it also tells the scroll view that what sits
            // there is a *bar*, which is what lets the edge effect dissolve
            // content under it instead of stopping it dead against a slab.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if let request = model.messageRequest(in: current.id) {
                    messageRequestBar(request)
                } else if model.canPostInOpenConversation {
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
            // A presentation rather than an overlay. Overlaid, the chain sat
            // inside this view's navigation bar and safe-area bar while
            // ignoring the safe area across both, and what it did to the layout
            // outlived its own dismissal.
            .fullScreenCover(item: $thread) { focus in
                ThreadView(
                    items: threadItems(rootedAt: focus.rootID),
                    anchorY: focus.anchorY,
                    conversation: current,
                    catalog: model.reactionCatalog,
                    canPost: model.canPostInOpenConversation,
                    onReact: { item, glyph in react(glyph, on: item) },
                    quickGlyphs: model.reactionCatalog.quick,
                    members: model.members,
                    meID: model.currentUser?.id,
                    canEdit: { model.canEdit($0.message) },
                    canDelete: { model.canDelete($0.message) },
                    actions: { actions(for: $0) },
                    onRetry: { retry($0) },
                    onDiscard: { discard($0) },
                    onOpenConversation: onOpenConversation,
                    onOpenPerson: { viewingPerson = $0 },
                    onSend: { text, media in reply(text, media: media, into: focus.rootID) },
                    onDismiss: {
                        var instant = Transaction()
                        instant.disablesAnimations = true
                        withTransaction(instant) { thread = nil }
                    })
                    // Without this the cover paints its own opaque ground and
                    // the conversation the chain came out of is gone.
                    .presentationBackground(.clear)
            }
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
            .confirmationDialog(
                "Delete this message?",
                isPresented: .init(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    guard let target = deleteTarget else { return }
                    deleteTarget = nil
                    Task { await model.delete(target.item.message) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It is removed for everyone in this conversation.")
            }
            .sheet(isPresented: $isNewPollPresented) { NewPollView() }
            .sheet(isPresented: $isNewEventPresented) { NewEventView() }
            .sheet(isPresented: $isPinnedPresented) {
                PinnedMessagesView(
                    messages: model.pinned,
                    members: model.members,
                    onOpen: { id in
                        guard await model.reveal(id) else { return false }
                        focus(on: id)
                        return true
                    },
                    onUnpin: { message in
                        Task { await model.setPinned(false, message: message) }
                    })
            }
            .sheet(isPresented: $isInfoPresented) {
                ConversationInfoView(
                    conversation: current, members: model.members,
                    onOpenDirect: onOpenConversation)
            }
            .sheet(item: $viewingPerson) { person in
                PersonView(
                    userID: person.id, name: person.name, avatarURL: person.avatarURL,
                    onOpenDirect: onOpenConversation, openedFrom: current.id)
            }
    }

    /// Scroll to a message, waiting for its row if the rebuild has not caught
    /// up. Paging back changes `model.messages`; the rows follow a beat later,
    /// and scrolling to an id that does not exist yet is a silent no-op.
    private func focus(on id: String) {
        if rows.contains(where: { $0.id == id }) {
            openingTarget = id
        } else {
            pendingTarget = id
        }
    }

    /// Split off `body` purely so the type checker can finish. Two chains of a
    /// dozen modifiers are two tractable problems; one chain of two dozen is a
    /// build that times out. Nothing here is grouped by meaning, and it would be
    /// dishonest to pretend otherwise.
    private var lifecycle: some View {
        chrome
            .task {
                // Before the open, so the first thing written for a brand new
                // DM is the row we know rather than the blank one a message
                // creates on its way past.
                await model.remember(conversation)
                await model.openConversation(conversation.id)
            }
            // Long enough for a push to finish, short enough that a
            // conversation whose history is already on disk still feels
            // immediate. The wait runs alongside the load above rather than
            // after it, so a slow read is not paid for twice.
            // The rest of the window arrives the moment the push is over,
            // above the viewport, held by the anchor that keeps a splice from
            // moving anything.
            .background(PushCompletion { settle() }.allowsHitTesting(false))
            // A backstop, and nothing more. The probe answers on the frame the
            // transition ends, or immediately when there was no transition to
            // wait for; this only covers the case where it never gets to run at
            // all, and a transcript stuck at fourteen rows is worse than one
            // that expands a moment late.
            .task {
                try? await Task.sleep(for: .milliseconds(700))
                settle()
            }
            .overlay {
                RosterHost(target: reactionDetail,
                           members: model.members,
                           meID: model.currentUser?.id)
            }
            .onDisappear(perform: teardown)
            .onChange(of: model.messagesRevision, initial: true) { messagesChanged() }
            // One scan when the list moves, rather than one per bubble per
            // pass. Only assigned when it differs, so a sync that changes some
            // other conversation does not redraw this one.
            .onChange(of: model.conversations, initial: true) {
                let resolved = model.conversations.first { $0.id == conversation.id }
                if resolved != currentRow { currentRow = resolved }
            }
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
                // Twice, and the second one is the one that works.
                //
                // The indicator changes the content height by about a bubble,
                // and this fires on the change rather than after the row it adds
                // has been laid out — so the first request scrolls to where the
                // foot was a frame ago and lands short, leaving the dots under
                // the composer. The second lands after layout. Both go to the
                // same anchor, so when the first was enough the second is free.
                bottomRequest += 1
                Task {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard isNearBottom, !isUserScrolling else { return }
                    bottomRequest += 1
                }
            }
            // The keyboard takes half the screen, and the scroll view answers a
            // growing bottom inset by keeping its offset: the content stays
            // where it was and the newest messages end up behind the keys. What
            // a reader wants is the opposite, that what they were looking at
            // stays looked at, so the foot is asked for again.
            //
            // Twice, because the inset is not final on the frame the field takes
            // focus; the second request lands once the keyboard has finished
            // arriving. Both scroll to the same anchor, so the second is free
            // when the first was enough.
            .onChange(of: composerFocused) { _, focused in
                guard focused, isNearBottom else { return }
                bottomRequest += 1
                Task {
                    try? await Task.sleep(for: .milliseconds(280))
                    guard composerFocused, isNearBottom else { return }
                    bottomRequest += 1
                }
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
                        // Same reason: while the stack holds a slice, the
                        // header would be announcing the top of something that
                        // is not the top.
                        if isSettled {
                            olderHeader
                                .padding(.top, Self.headroom)
                        }
                        messageRows
                        typingRow
                    }
                    bottomSpacer
                }
                .padding(.horizontal, 10)
                .background(TranscriptScrollTuning().allowsHitTesting(false))
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Deliberately optional, and `nil` nearly all the time. See
            // `sizeChangeAnchor`.
            .defaultScrollAnchor(contentAnchor, for: .sizeChanges)
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

    /// The foot of the window until the push is over, then all of it. Sliced
    /// rather than re-indexed: an `ArraySlice` keeps the indices of the array it
    /// came from, which is what the paging trigger below counts in.
    private var shownRows: ArraySlice<TranscriptRow> {
        // A conversation that opens on the unread divider, or on a message
        // somebody jumped to, lands somewhere that is not the foot: the row it
        // scrolls to has to be in the tree, and `scrollTo` on a row that is not
        // there is silently nothing. Those opens draw the window whole and pay
        // for it.
        guard !isSettled, unread == nil, openingTarget == nil, pendingTarget == nil
        else { return rows[...] }
        return rows.suffix(Self.firstPaintRows)
    }

    @ViewBuilder private var messageRows: some View {
        ForEach(Array(zip(shownRows.indices, shownRows)), id: \.1.id) { index, row in
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
            canEdit: model.canEdit(item.message, in: currentRow),
            onEdit: { text in edit(item, to: text) },
            onPress: { frame in
                // Derived off the main actor, and the first derivation is a
                // walk of fifteen thousand scalars asking ICU for names. Doing
                // it here means the More button opens a full grid rather than
                // an empty one that fills in: by the time anyone reaches for
                // it, the catalog has been sitting ready. Cached, so every
                // press after the first costs an actor hop and nothing else.
                Task.detached(priority: .utility) { _ = await EmojiCatalog.shared.all() }
                pressed = MessagePress(
                    item: item, frame: frame,
                    canEdit: model.canEdit(item.message, in: currentRow),
                    canDelete: model.canDelete(item.message, in: currentRow))
            },
            isHeld: pressed?.item.id == item.id,
            onOpenConversation: onOpenConversation,
            onReply: {
                replyingTo = item.message
                composerFocused = true
            },
            onOpenThread: { frame in
                let focus = ThreadFocus(
                    rootID: item.message.replyRootID ?? item.message.id,
                    anchorY: frame.minY)
                // Raised without the system's slide. The chain draws the chat's
                // own header and composer in the chat's own places, so a
                // presentation that flies up from the bottom is half a second
                // of those two sliding past themselves. ``ThreadView`` fades in
                // what it actually added and leaves the rest sitting still.
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { thread = focus }
            },
            onInspectReaction: { _ in reactionDetail.item = item },
            onOpenPerson: { viewingPerson = $0 }
        )
    }

    // MARK: Threads

    /// A reply typed inside a chain. Answers the last message in it, which is
    /// what keeps the chain's root the same one it already had.
    private func reply(_ text: String, media: [PickedMedia], into rootID: String) {
        let parent = Transcript.chain(rootedAt: rootID, in: model.messages).last
        bottomRequest += 1
        Task { await model.send(text, media: media, replyingTo: parent) }
    }

    /// The chain, drawn through the same builder as the transcript so a bubble
    /// in a thread is the same bubble it was in the conversation.
    ///
    /// Quotes and counts are stripped on the way out: inside a chain, every
    /// message answers the one above it, and saying so on each of them is
    /// furniture that the lifting-out was meant to remove.
    private func threadItems(rootedAt rootID: String) -> [MessageDisplay] {
        Transcript.rows(
            messages: Transcript.chain(rootedAt: rootID, in: model.messages),
            // Queued replies belong in the chain they were typed into, or
            // sending from a thread would look like it had done nothing until
            // the server came back.
            outbox: model.outbox.filter {
                $0.localEcho(sender: model.currentUser).replyRootID == rootID
            },
            currentUser: model.currentUser,
            quoted: model.quotedParents, members: model.members
        ).compactMap { row in
            guard case .message(var item) = row else { return nil }
            item.reply = nil
            item.replyCount = 0
            return item
        }
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
                thread = nil
                replyingTo = item.message
                composerFocused = true
            })
        }
        if !item.reactions.isEmpty {
            actions.append(.init("View Reactions", symbol: "heart.text.square") {
                pressed = nil
                thread = nil
                reactionDetail.item = item
            })
        }
        if model.canPin(item.message) {
            let pinned = model.isPinned(item.message)
            actions.append(.init(
                pinned ? "Unpin" : "Pin",
                symbol: pinned ? "pin.slash" : "pin"
            ) {
                pressed = nil
                Task { await model.setPinned(!pinned, message: item.message) }
            })
        }
        if press.canDelete {
            actions.append(.init("Delete", symbol: "trash", isDestructive: true) {
                pressed = nil
                thread = nil
                deleteTarget = press
            })
        }
        if press.canEdit {
            actions.append(.init("Edit", symbol: "pencil") {
                // The server's own text, not the parsed copy: an edit starts
                // from what was actually posted.
                editDraft = item.message.text ?? ""
                pressed = nil
                thread = nil
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
            TypingIndicator(people: model.typingPeople, names: model.typingNames)
                // Quick in, slow out. Somebody starting to type is news and
                // should arrive promptly; somebody stopping is a guess made by a
                // timer, and a leisurely fade is both honest about that and much
                // calmer to sit next to than a row that snaps away.
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.15)),
                    removal: .opacity.animation(.easeIn(duration: 0.45))))
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
        // Standing at the foot is the whole condition for following it.
        pinsFoot = visible
        // Reaching the foot is what reading a conversation means. Opening one
        // is not: a conversation with unread opens on the divider, well above
        // this, and stays unread until the reader comes down to it.
        guard visible else { return }
        Task { await model.markRead(current.id) }
    }

    // MARK: Paging

    /// How far from the top of the loaded history a row has to be before it
    /// asks for the page above it. Ten rows is roughly a screen, so the fetch
    /// is usually finished by the time the reader gets there.
    private static let prefetchDistance = 10

    /// Room above the head of the history for the part of the header that hangs
    /// below the bar.
    ///
    /// The title is a 62pt photograph with a pill tucked under it, so it stands
    /// a good deal taller than the bar the safe area is measured from. Messages
    /// dissolving under that overhang while scrolling is the intended effect;
    /// the top of the history coming to rest beneath it is not, because there is
    /// nothing above it left to scroll and "Beginning of conversation" simply
    /// never appears.
    private static let headroom: CGFloat = 46

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
        // The first frames draw a slice, so its first row is not the top of
        // anything and asking for older history off the back of it would page
        // the conversation on every open.
        guard isSettled, index < Self.prefetchDistance else { return }
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
        VStack(alignment: .leading, spacing: 0) {
            SwiftUI.Group {
                if let replyingTo { replyHover(replyingTo) }
            }
            // Scoped to the hover. An implicit animation here would reach the
            // `TextField` below and animate the words away after a send; see
            // `sendButton`.
            .animation(.snappy(duration: 0.24), value: replyingTo?.id)

            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    attachButton
                    field
                }
            }
        }
        .padding(.horizontal, 12)
        // Asymmetric, so the bar sits down against the home indicator rather
        // than floating in the middle of the space the safe area leaves. The
        // room above is what separates it from the transcript; the room below
        // is only there to keep it off the edge.
        .padding(.top, 7)
        // Negative, and only against the home indicator.
        //
        // `safeAreaBar` parks the bar clear of whatever is below it, and when
        // that is the home indicator it leaves more room than anything else on
        // screen gets — so part of it is taken back. When the keyboard is up it
        // is the keyboard down there instead, and there is nothing spare to
        // reclaim: the same negative padding drives the field into the keys.
        // Against the home indicator there is room to spare, so some is taken
        // back. Against the keyboard there is none, and the field wants a little
        // air between itself and the keys rather than sitting on them.
        .padding(.bottom, composerFocused ? 10 : -14)
        .animation(.easeOut(duration: 0.2), value: composerFocused)
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

    /// The decision a message request is waiting on, where the messages are.
    ///
    /// A request from somebody outside your contacts is readable before it is
    /// answered, and reading it is how anyone decides — so the answer belongs
    /// under the transcript rather than only on a separate screen that shows a
    /// single line of preview. It stands where the composer would, because
    /// until it is answered there is nothing to say back.
    private func messageRequestBar(_ request: PendingRequests.DirectRequest) -> some View {
        VStack(spacing: 10) {
            Text("\(current.name) is not in your contacts.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Accept") { answer(request, accept: true) }
                    .buttonStyle(.borderedProminent)
                Button("Delete", role: .destructive) { answer(request, accept: false) }
                    .buttonStyle(.bordered)
                if answeringRequest { ProgressView() }
            }
            .controlSize(.regular)
            .disabled(answeringRequest)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// Accepting leaves the conversation open, now with a composer. Declining
    /// deletes it, so this screen is showing something that no longer exists
    /// and steps back to the list.
    private func answer(_ request: PendingRequests.DirectRequest, accept: Bool) {
        guard let userID = request.otherUser?.id else { return }
        answeringRequest = true
        Task {
            let ok = await model.respondToRequest(accept, from: userID)
            answeringRequest = false
            if ok && !accept { dismiss() }
        }
    }

    /// A menu rather than a button, now that there is more than one thing to
    /// attach. Photos stay at the top because they are what the button was for
    /// and what it is still mostly used for.
    private var attachButton: some View {
        Menu {
            Button("Photo or Video", systemImage: "photo") {
                isAttachmentPickerPresented = true
            }
            if current.isGroup {
                Button("Poll", systemImage: "chart.bar") { isNewPollPresented = true }
            }
            Button("Event", systemImage: "calendar") { isNewEventPresented = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 21, weight: .medium))
                .frame(width: Self.composerHeight, height: Self.composerHeight)
                // The same shape and size as the field beside it, so the two
                // read as one control split in half rather than a button parked
                // next to a box.
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24, style: .continuous))
        }
        // On the `Menu`, not on the label. A menu tints its label with the
        // accent colour and overrides whatever the label asked for, which is
        // why this went blue the moment it stopped being a plain button.
        .foregroundStyle(.primary)
        .accessibilityLabel("Add attachment")
    }

    /// One line's worth of composer, which the attach button matches.
    private static let composerHeight: CGFloat = 44

    private var field: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !staged.isEmpty {
                SwiftUI.Group {
                    stagedStrip
                    // The whole reason the tray lives inside the field rather
                    // than above it. A photo waiting to be sent is part of the
                    // message being written, and a hairline is enough to say
                    // "these two things go together, and one of them is the
                    // words".
                    Divider().padding(.leading, 14)
                }
                .animation(.snappy(duration: 0.22), value: staged)
            }

            if !mentionMatches.isEmpty {
                mentionSuggestions
                Divider().padding(.leading, 14)
            }

            HStack(alignment: .bottom, spacing: 4) {
                ComposerField("Message", text: $draft, isFocused: $composerFocused)
                    .padding(.leading, 16)
                    .padding(.vertical, 11)
                    .frame(minHeight: Self.composerHeight)
                    .accessibilityLabel("Message")
                    .onChange(of: draft) { _, text in
                        // Throttled inside the socket client, so every keystroke
                        // calling this is the intended usage.
                        guard !text.isEmpty else { return }
                        Task { await model.userIsTyping() }
                    }

                sendButton
                    // On the button, not on the field.
                    //
                    // An implicit animation applies to everything beneath it,
                    // and beneath it was the `TextField`. Sending flips
                    // `canSend` in the same update that empties `draft`, so the
                    // field's own text change was being handed an animation it
                    // had no business having, and the words stayed on screen
                    // after the message had gone. Only the button appears and
                    // disappears here; only the button should animate.
                    .animation(.snappy(duration: 0.18), value: canSend)
            }
        }
        // A rounded rectangle rather than a capsule, because a capsule around a
        // field carrying a row of photos is a stadium: the radius follows the
        // height, and the taller it gets the more the ends bow out. At a single
        // line's height this radius is indistinguishable from one, which is the
        // point — round like the buttons beside it, and still sane when the
        // attachment tray makes it four times as tall.
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
    }

    /// Members matching the name being typed after an `@`.
    ///
    /// Capped, because this sits above the keyboard and a list that grows past a
    /// few rows pushes the message it belongs to off the screen.
    private var mentionMatches: [Member] {
        guard current.isGroup, let query = MentionDraft.query(in: draft) else { return [] }
        let me = model.currentUser?.id
        let people = model.members.filter { $0.identity != me }
        guard !query.isEmpty else { return Array(people.prefix(Self.mentionLimit)) }
        return Array(
            people
                .filter { (($0.nickname ?? $0.name) ?? "").localizedStandardContains(query) }
                .prefix(Self.mentionLimit))
    }

    private static let mentionLimit = 5

    private var mentionSuggestions: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(mentionMatches, id: \.identity) { member in
                    Button { complete(with: member) } label: {
                        HStack(spacing: 6) {
                            Avatar(url: member.imageUrl, name: name(of: member), size: 22)
                            Text(name(of: member))
                                .font(.subheadline)
                                .lineLimit(1)
                        }
                        .padding(.leading, 4)
                        .padding(.trailing, 10)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func name(of member: Member) -> String {
        member.nickname ?? member.name ?? "Someone"
    }

    /// Finish the name being typed, and remember who it was.
    private func complete(with member: Member) {
        let display = name(of: member)
        draft = MentionDraft.completing(draft, with: display)
        named.append(MentionDraft.Named(userID: member.identity, name: display))
    }

    /// What the transcript does while a reply is being written.
    ///
    /// Messages blurs the conversation and leaves the message being answered
    /// standing over it, and the reason is that the reply has a subject: with
    /// the rest of the transcript at full strength, the bubble above the
    /// composer is just one more bubble among forty. Tapping it puts the
    /// conversation back, which is the same way out the reply arrow offers.
    @ViewBuilder private var replyScrim: some View {
        ZStack {
            if replyingTo != nil {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.12))
                    .ignoresSafeArea()
                    .contentShape(.rect)
                    .onTapGesture { replyingTo = nil }
                    .accessibilityLabel("Cancel reply")
                    .accessibilityAddTraits(.isButton)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: replyingTo == nil)
    }

    /// The message being answered, hovering over the transcript just above the
    /// bar, drawn as the message it is.
    ///
    /// Messages does this and it is plainly right: a reply is aimed at
    /// something the reader can already see, so showing them a *smaller,
    /// greyer, differently-shaped* copy of it is asking them to match two
    /// pictures of the same thing. The bubble they tapped comes down to the
    /// composer unchanged instead.
    ///
    /// Outside the field rather than inside it. In the field it was another row
    /// of the same control, which is what made a quote need furniture to be
    /// told apart from the words answering it; up here it is a message sitting
    /// over the transcript, and nothing has to say so.
    @ViewBuilder private func replyHover(_ message: Message) -> some View {
        if let item = replyHoverItem(message) {
            SwiftUI.Group {
                ScrollView {
                    MessageRow(item: item, catalog: model.reactionCatalog,
                               previews: model.previews, showsFace: false)
                        // A picture of the message, not the message. Every
                        // gesture it carries belongs to the transcript.
                        .allowsHitTesting(false)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                            replyHoverHeight = $0
                        }
                }
                .scrollBounceBehavior(.basedOnSize)
                // Exactly as tall as the bubble, up to the cap. A scroll view
                // takes every point it is offered, so left to itself it stood
                // the message a screenful above the field it belongs to.
                .frame(height: min(max(replyHoverHeight, 1), Self.replyHoverLimit))
            }
            .padding(.horizontal, 2)
            // Close, but not touching. The bubble and the field it is about to
            // be answered in are one arrangement; a hair of air keeps them from
            // reading as one object.
            .padding(.bottom, 12)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .accessibilityElement(children: .contain)
        }
    }

    /// The message run through the same builder the transcript uses, so the
    /// bubble above the composer is the bubble from the conversation rather
    /// than a second drawing of one.
    private func replyHoverItem(_ message: Message) -> MessageDisplay? {
        Transcript.rows(
            messages: [message], outbox: [], currentUser: model.currentUser,
            quoted: model.quotedParents, members: model.members
        ).compactMap { row -> MessageDisplay? in
            guard case .message(var item) = row else { return nil }
            // Its own quote and its own reply count belong to the transcript;
            // here they are a message inside a message.
            item.reply = nil
            item.replyCount = 0
            // No timestamp either: the footer only draws on the tail of a run,
            // and a clock under a message being answered is answering a
            // question nobody asked while standing on the composer.
            item.isRunTail = false
            return item
        }.first
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
            .padding(.trailing, 5)
            .padding(.bottom, 6)
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
        // Located against the trimmed text, which is what actually goes out. A
        // locus measured against the untrimmed draft would be off by however
        // much leading whitespace was typed.
        let mentions = MentionDraft.attachment(for: text, naming: named)
        // Emptying the binding is the whole of it: `ComposerField` unmarks the
        // field before it assigns, so an unresolved prediction cannot write the
        // sent message back a frame later.
        draft = ""
        staged = []
        replyingTo = nil
        named = []
        bottomRequest += 1
        Task {
            await model.send(text, media: media, replyingTo: parent, mentioning: mentions)
        }
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

    /// The conversation on screen, resolved out of the model rather than held,
    /// so an unread count or a name that changes underneath is picked up. The
    /// row passed in is the fallback for the frame before the list has it.
    private var current: ConversationRow {
        currentRow ?? conversation
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // The way out of a reply, in the one place a screen's way out belongs.
        // It stands where the pin does and takes its turn: while a reply is
        // being written that is what the button is for, and the pinned
        // messages are still there afterwards.
        if replyingTo != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Button { replyingTo = nil } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Cancel reply")
            }
        } else if !model.pinned.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isPinnedPresented = true } label: {
                    Image(systemName: "pin.fill")
                }
                .accessibilityLabel(
                    model.pinned.count == 1
                        ? "1 pinned message" : "\(model.pinned.count) pinned messages")
            }
        }
        ToolbarItem(placement: .principal) {
            Button(action: openDetails) {
                ConversationTitle(conversation: current)
            }
                .buttonStyle(.plain)
                .accessibilityLabel(titleAccessibilityLabel)
                .accessibilityHint(
                    current.isGroup ? "Shows conversation details" : "Shows their profile")
        }
    }

    /// What the header opens.
    ///
    /// A group has a roster, a description and a way out, and that is a screen.
    /// A DM has one other person in it, so the sheet was a header and a list of
    /// one — a page about a conversation that is really a page about somebody.
    /// The profile is the thing being asked for, so it is the thing that opens.
    private func openDetails() {
        guard case .direct(let otherUserID) = current.id else {
            isInfoPresented = true
            return
        }
        viewingPerson = PersonRef(
            id: otherUserID, name: current.name, avatarURL: current.avatarURL)
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
        model.closeConversation(conversation.id)
    }

    private func messagesChanged() {
        rebuild()
        // Only for a reader standing at the foot. Something that lands while
        // they are up in the history has not been read by anybody, and saying it
        // has both clears a badge they still want and moves the read cursor past
        // messages they have not seen — which every other device then believes.
        guard isNearBottom else { return }
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
            let built = await Task.detached(priority: .userInitiated) { [styling] in
                Transcript.rows(
                    messages: messages, outbox: outbox, currentUser: currentUser,
                    quoted: quoted, unresolved: unresolved, members: members, unread: unread,
                    styling: styling)
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
        // The seventh: a jump that has been waiting for its row. This is the
        // one fill that grows above *and* wants the view to move, so it opts
        // out of holding the content's end for the same reason the divider does.
        let arriving = pendingTarget.map { target in built.contains { $0.id == target } } ?? false

        if grewAbove, !opensOnDivider, !arriving { holdContentEnd() }
        // Both of these send the transcript somewhere that is not the foot, so
        // the foot must stop pulling. Before the assignment, because the fill
        // itself is a size change and the anchor is read as it happens.
        if opensOnDivider || arriving { pinsFoot = false }
        rows = built

        if arriving {
            openingTarget = pendingTarget
            pendingTarget = nil
        }

        // After the assignment, so the row it scrolls to exists by the time the
        // effect runs.
        if opensOnDivider { openingTarget = TranscriptRow.unreadMarkerID }

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

        // A receipt we hold but cannot find means everything loaded is newer
        // than it, so everything loaded is unread and the divider belongs at the
        // top. Counting back by the badge here would be worse than useless: the
        // badge is a number from the server about a range we cannot see, and
        // using it would place the divider in the middle of messages we know
        // are unread.
        if current.lastReadMessageID != nil {
            unread = UnreadMark(firstUnreadID: messages[0].id, count: messages.count)
            return
        }

        // No receipt at all. Counting back from the newest message is the same
        // arithmetic the badge was drawn from, clamped to the window.
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
    /// Draw the rest of the window, holding the content's end so the splice
    /// above the viewport moves nothing.
    private func settle() {
        guard !isSettled else { return }
        holdContentEnd()
        isSettled = true
    }

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
    let people: [TypingPerson]
    let names: [String]

    /// Enough to say "several", past which the faces are a smudge.
    private static let visibleFaces = 3
    private static let faceSize: CGFloat = 22

    var body: some View {
        HStack(spacing: 7) {
            faces
            TypingDots()
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.quaternary, in: .rect(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
        // None of its own. The foot of the transcript sits directly under this
        // and carries the whole gap; anything here is a second one on top of it.
        .padding(.bottom, 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sentence)
    }

    /// Overlapped rather than spaced, so three people cost about the width of
    /// two. The first typist is drawn on top, which keeps the pile from
    /// reshuffling as people join and leave it.
    @ViewBuilder private var faces: some View {
        if !people.isEmpty {
            HStack(spacing: -Self.faceSize * 0.35) {
                ForEach(Array(people.prefix(Self.visibleFaces).enumerated()), id: \.element.id) { index, person in
                    Avatar(url: person.imageURL, name: person.name, size: Self.faceSize)
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5))
                        .zIndex(Double(Self.visibleFaces - index))
                }
            }
            // A count over the pile rather than a fourth face. Past three the
            // faces stop being recognisable anyway, and "and four more" is the
            // only part still worth saying.
            .overlay(alignment: .topTrailing) {
                if people.count > Self.visibleFaces {
                    Text("+\(people.count - Self.visibleFaces)")
                        .font(.system(size: 10, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(Color.accentColor, in: .capsule)
                        .overlay(Capsule().strokeBorder(Color(.systemBackground), lineWidth: 1.5))
                        .offset(x: 6, y: -5)
                }
            }
        }
    }

    private var sentence: String {
        switch names.count {
        case 0: "Typing…"
        case 1: "\(names[0]) is typing…"
        case 2: "\(names[0]) and \(names[1]) are typing…"
        case 3: "\(names[0]), \(names[1]) and \(names[2]) are typing…"
        default: "\(names[0]), \(names[1]) and \(names.count - 2) others are typing…"
        }
    }
}

/// The animation itself, kept apart so its `@State` is created and destroyed
/// with the bubble rather than living for the length of the conversation.
private struct TypingDots: View {
    private static let dotSize: CGFloat = 7
    private static let period = 1.2
    /// A third of the cycle between neighbours, which is what makes it read as
    /// a travelling wave rather than three lights blinking.
    private static let stagger = 0.2

    /// Driven by the clock rather than by an animation.
    ///
    /// This used to be a `repeatForever` started in `onAppear`, and it did not
    /// run: an ancestor's `.animation(_:value:)` replaces the animation context
    /// for everything beneath it, so the repeating linear curve was quietly
    /// swapped for the parent's quarter-second ease and the dots sat still. A
    /// `TimelineView` asks what time it is instead, which nothing above can
    /// override.
    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate / Self.period
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(.secondary)
                        .frame(width: Self.dotSize, height: Self.dotSize)
                        .scaleEffect(0.75 + 0.35 * wave(index, at: phase))
                        .opacity(0.4 + 0.6 * wave(index, at: phase))
                }
            }
        }
    }

    /// A raised cosine over the cycle, offset per dot. Smooth at the wrap,
    /// which a keyframe list of discrete states is not.
    private func wave(_ index: Int, at phase: Double) -> Double {
        let t = (phase - Double(index) * Self.stagger).truncatingRemainder(dividingBy: 1)
        let wrapped = t < 0 ? t + 1 : t
        return (1 - cos(wrapped * 2 * .pi)) / 2
    }
}

/// Two corrections to the `UIScrollView` behind the transcript, neither of
/// which SwiftUI exposes a way to make.
///
/// A probe rather than a modifier because there is no other handle on that
/// scroll view. It walks up from its own place in the view tree to the enclosing
/// one, which is a hop or two, and is otherwise inert.
/// Calls back when the navigation transition that brought this view on screen
/// has finished, or at once when it arrived without one.
///
/// A timer was the alternative and it is a guess in both directions: too short
/// and the work it is deferring lands in the middle of the animation anyway,
/// too long and the screen sits half-drawn after everything has stopped moving.
/// UIKit knows exactly when a push ends and will say so; SwiftUI simply has no
/// modifier that asks, so this asks on its behalf.
private struct PushCompletion: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> UIView {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.onCompletion = action
        return probe
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? Probe)?.onCompletion = action
    }

    final class Probe: UIView {
        var onCompletion: (() -> Void)?
        private var hasReported = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, !hasReported else { return }
            // Next turn of the run loop: the transition coordinator is put in
            // place as the push begins, and on the frame a view joins the
            // window it is not necessarily there yet.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report() {
            guard !hasReported else { return }
            guard let coordinator = owningController?.transitionCoordinator else {
                finish()
                return
            }
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.finish() }
        }

        private func finish() {
            hasReported = true
            onCompletion?()
        }

        /// The view controller this view is drawn by, which for a SwiftUI view
        /// is whichever hosting controller sits above it in the responder
        /// chain.
        private var owningController: UIViewController? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController { return controller }
                responder = current.next
            }
            return nil
        }
    }
}

private struct TranscriptScrollTuning: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let probe = Probe()
        // It is a background spanning the whole transcript. Left interactive it
        // would quietly swallow every tap that lands between two bubbles.
        probe.isUserInteractionEnabled = false
        return probe
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? Probe)?.attach()
    }

    final class Probe: UIView {
        private weak var scrollView: UIScrollView?
        private var insetObservation: NSKeyValueObservation?
        private var boundsObservation: NSKeyValueObservation?
        /// The height actually available to draw content in, which is what the
        /// keyboard takes away — by whichever means it happens to use.
        private var lastVisibleHeight: CGFloat?
        /// Whether we are the ones moving the scroll view right now.
        ///
        /// `setContentOffset` moves `bounds.origin`, which is the very property
        /// the compensation is observing, and the observer fires *inside* the
        /// call. Without this the compensation answers its own movement, and
        /// since the answer is identical every time it recurses until the stack
        /// runs out.
        private var isCompensating = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attach()
        }

        func attach() {
            guard scrollView == nil else { return }
            var ancestor: UIView? = superview
            while let current = ancestor {
                if let scroll = current as? UIScrollView {
                    bind(scroll)
                    return
                }
                ancestor = current.superview
            }
        }

        private func bind(_ scroll: UIScrollView) {
            scrollView = scroll

            // 1. No scroll-to-top.
            //
            // The status bar gesture means "go to the beginning of the content",
            // which in almost every app is helpful and in a transcript is the
            // least useful place there is: the beginning of a chat is the oldest
            // message anybody ever sent in it. Worse, its target is the whole
            // status bar, so it fires on a tap near the header that was meant
            // for the header, and a year of history goes past in one frame.
            scroll.scrollsToTop = false

            // 2. Keep the view still when the keyboard arrives.
            //
            // Watched two ways, because there are two. A keyboard can take room
            // from a scroll view by growing its bottom inset or by shrinking its
            // frame, and which one happens is SwiftUI's business rather than
            // ours: `safeAreaBar` and the keyboard between them have used both.
            // Watching only the inset means the compensation silently does
            // nothing whenever the other one is used, which is exactly what a
            // reader sees as the transcript sliding under the keyboard.
            //
            // So the thing tracked is neither: it is the height left over,
            // which is what actually determines what can be seen.
            lastVisibleHeight = visibleHeight(of: scroll)
            insetObservation = scroll.observe(\.adjustedContentInset, options: [.new]) { scroll, _ in
                MainActor.assumeIsolated { [weak self] in self?.visibleHeightChanged(on: scroll) }
            }
            boundsObservation = scroll.observe(\.bounds, options: [.new]) { scroll, _ in
                MainActor.assumeIsolated { [weak self] in self?.visibleHeightChanged(on: scroll) }
            }
        }

        /// The keyboard does not move a scroll view; it inflates the bottom of
        /// its safe area, and a scroll view answers that by keeping its offset.
        /// The content therefore stays exactly where it was and the keyboard is
        /// drawn on top of the part the reader was reading.
        ///
        /// Adding the same amount to the offset is what "the view did not move"
        /// actually requires. It is applied without an animation of its own so
        /// it inherits the keyboard's, which is what makes the two look like one
        /// movement rather than a scroll chasing a keyboard.
        private func visibleHeight(of scroll: UIScrollView) -> CGFloat {
            scroll.bounds.height
                - scroll.adjustedContentInset.top
                - scroll.adjustedContentInset.bottom
        }

        private func visibleHeightChanged(on scroll: UIScrollView) {
            guard !isCompensating else { return }
            let visible = visibleHeight(of: scroll)
            let previous = lastVisibleHeight
            // Recorded before anything is applied, not after. A `defer` runs
            // once the frame unwinds, which is far too late for an observer
            // that fires part way through.
            lastVisibleHeight = visible
            guard let previous else { return }
            // Room lost, which is what the offset has to make up.
            //
            // `bounds` also fires on every scroll, but its *origin* moving is
            // not this: only a change in height counts, and a scroll does not
            // change one. Both directions, so it holds on close as well as on
            // open — room gained is taken back off the offset. The rule is
            // purely relative; it never refers to "the bottom" and so holds
            // from anywhere in the history.
            let delta = previous - visible
            guard abs(delta) > 1 else { return }
            // A finger on the glass owns the scroll view. Nothing here outranks
            // that.
            guard !scroll.isDragging, !scroll.isDecelerating else { return }

            let lowest = -scroll.adjustedContentInset.top
            let highest = max(
                lowest,
                scroll.contentSize.height
                    + scroll.adjustedContentInset.bottom
                    - scroll.bounds.height)
            let target = min(max(scroll.contentOffset.y + delta, lowest), highest)
            guard abs(target - scroll.contentOffset.y) > 0.5 else { return }
            // No animation of its own, so it inherits the keyboard's. Giving it
            // a curve here would be giving it a *different* curve, and the
            // content would visibly slide against a keyboard moving at another
            // rate.
            isCompensating = true
            scroll.setContentOffset(
                CGPoint(x: scroll.contentOffset.x, y: target), animated: false)
            isCompensating = false
        }
    }
}

/// Who reacted to a message, and with what.
///
/// One panel for the whole message rather than one per glyph. A message with
/// four reactions used to mean four sheets to open in turn, each answering a
/// question nobody asks glyph by glyph: what people want is the room, not one
/// corner of it.
///
/// Glyphs run along the top with their counts, and picking one narrows the list.
/// "All" is the default and is what a message with a single reaction shows
/// without any of this getting in the way.
/// Where the roster's subject lives, so that setting it touches one small view
/// instead of the whole chat.
@MainActor @Observable final class RosterTarget {
    var item: MessageDisplay?
}

/// Nothing to look at. It exists to own the sheet, and it is the only view that
/// reads ``RosterTarget``.
private struct RosterHost: View {
    @Bindable var target: RosterTarget
    let members: [Member]
    let meID: String?

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .sheet(item: $target.item) { item in
                ReactionRoster(summaries: item.reactions, members: members, meID: meID)
            }
    }
}

/// Who reacted, and with what. Raised from a held chip, in the transcript or
/// in a chain, which is why it is not private to either.
struct ReactionRoster: View {
    let summaries: [Message.ReactionSummary]
    let members: [Member]
    /// So the reader can find themselves in a long list without reading it.
    let meID: String?

    @Environment(\.dismiss) private var dismiss
    @State private var filter: String?

    // No `NavigationStack`, no `List`. A sheet does not animate in until its
    // content has been built and laid out once, and those two are the most
    // expensive things that could be in here: a navigation container and a
    // collection view, both stood up from nothing on every present, for a
    // header and a column of names. A `ScrollView` over a `LazyVStack` draws
    // the same list and starts the animation sooner, which is the whole
    // complaint about how long a roster takes to arrive.
    var body: some View {
        VStack(spacing: 0) {
            header
            if summaries.count > 1 { glyphs }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                        HStack(spacing: 12) {
                            Avatar(url: person.imageURL, name: person.name, size: 34)
                            Text(person.name)
                                .lineLimit(1)
                            if person.isYou {
                                Text("You")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            // Which glyph this person used, when the list is not
                            // already filtered to one.
                            if filter == nil {
                                ReactionGlyph(glyph: person.glyph, size: 18)
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(person.name), reacted with \(person.spokenGlyph)")
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .presentationDetents([.medium, .large])
    }

    /// The title row a navigation bar used to draw, at a fraction of what one
    /// costs to stand up.
    private var header: some View {
        ZStack {
            Text(title)
                .font(.headline)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var glyphs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip(nil, label: "All", count: total)
                ForEach(summaries) { summary in
                    chip(summary.glyph, label: nil, count: summary.count)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func chip(_ glyph: String?, label: String?, count: Int) -> some View {
        let isOn = filter == glyph
        return Button {
            filter = glyph
        } label: {
            HStack(spacing: 5) {
                if let glyph {
                    ReactionGlyph(glyph: glyph, size: 17)
                } else if let label {
                    Text(label).font(.subheadline.weight(.medium))
                }
                Text("\(count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                isOn ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(.quaternary),
                in: .capsule)
            .overlay(
                Capsule().strokeBorder(
                    isOn ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private var total: Int { summaries.reduce(0) { $0 + $1.count } }

    private var title: String {
        total == 1 ? "1 reaction" : "\(total) reactions"
    }

    /// Everybody who reacted, in glyph order, each paired with what they used.
    ///
    /// The roster is the group's, so anybody who has since left it is an id with
    /// no name. They are still listed: dropping them would make the panel
    /// disagree with the count on the chip it came from.
    private var people: [Person] {
        let byID = Dictionary(
            members.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        return summaries
            .filter { filter == nil || $0.glyph == filter }
            .flatMap { summary in
                summary.userIDs.map { id in
                    let member = byID[id]
                    return Person(
                        name: member?.nickname ?? member?.name ?? "Someone",
                        imageURL: member?.imageUrl,
                        isYou: id == meID,
                        glyph: summary.glyph,
                        spokenGlyph: summary.spokenGlyph)
                }
            }
    }

    private struct Person {
        let name: String
        let imageURL: String?
        let isYou: Bool
        let glyph: String
        let spokenGlyph: String
    }
}

/// The face, then the name in a capsule of its own.
///
/// The capsule is not decoration. Without it the name is loose text on a
/// transparent bar, sitting over whatever happens to be scrolling behind it,
/// and there is no telling where the tappable part ends. A bordered pill says
/// "this is a control, and it is exactly this big", which is what a transparent
/// bar takes away and has to give back some other way.
///
/// Shared with ``ThreadView``, which draws its own copy in the same place: a
/// chain is presented over the chat, so the real toolbar is behind the scrim
/// and dimmed with everything else, and the reader should not have to close
/// the chain to find out which conversation they are in.
struct ConversationTitle: View {
    let conversation: ConversationRow

    var body: some View {
        VStack(spacing: -6) {
            Avatar(
                url: conversation.avatarURL,
                name: conversation.name,
                size: 62,
                isGroup: conversation.isGroup
            )
            // A stack draws in order, so the pill would otherwise cover the
            // photo. Lifting the photo instead puts the overlap the right way
            // round: the face stays whole and the pill runs behind it.
            .zIndex(1)
            HStack(spacing: 3) {
                Text(conversation.name)
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
}
