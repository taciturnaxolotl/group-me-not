import SwiftUI

/// Which chain is being read, and where on screen it was opened from.
nonisolated struct ThreadFocus: Identifiable, Hashable, Sendable {
    let rootID: String
    /// The top of the message that was tapped, in screen coordinates. The chain
    /// opens from here so the message the reader was looking at does not move
    /// out from under them.
    let anchorY: CGFloat

    var id: String { rootID }
}

/// One reply chain, alone, over a blurred transcript.
///
/// The shape Messages uses, and the reason it works: a chain read in place is
/// read through everything that happened around it, and the quotes are there to
/// paper over exactly that. Lift the chain out and the quotes stop being
/// necessary, so this drops them — a thread is already the answer to "what is
/// this replying to".
///
/// Presented rather than overlaid. As an overlay it sat inside the chat's own
/// safe-area bar and navigation bar, ignoring the safe area across both, and
/// left the layout under it wrong in a way that outlived the dismissal. A
/// presentation with a clear background looks identical and cannot reach the
/// view it covers.
struct ThreadView: View {
    /// The chain, oldest first, root included.
    let items: [MessageDisplay]
    /// Where the tapped message was sitting when this opened.
    var anchorY: CGFloat = 0
    /// The conversation the chain came out of, for the bar at the top. The
    /// chat's own toolbar is behind the scrim and dimmed with everything else,
    /// so a chain that named nothing left the reader in a room with no sign on
    /// the door.
    var conversation: ConversationRow?
    var catalog: ReactionCatalog = .default
    /// Whether this conversation takes messages at all.
    var canPost: Bool = true
    var onReact: (MessageDisplay, String) -> Void = { _, _ in }
    /// The quick row the press menu offers.
    var quickGlyphs: [String] = []
    /// For the roster sheet, which a held chip raises here rather than
    /// downstairs: a sheet from the chat cannot appear over a chain.
    var members: [Member] = []
    var meID: String?
    var canEdit: (MessageDisplay) -> Bool = { _ in false }
    var canDelete: (MessageDisplay) -> Bool = { _ in false }
    /// The menu for a pressed message, built by the chat, which is the only
    /// place that knows what this account may do to it.
    var actions: (MessagePress) -> [MessageAction] = { _ in [] }
    var onRetry: (MessageDisplay) -> Void = { _ in }
    var onDiscard: (MessageDisplay) -> Void = { _ in }
    var onOpenConversation: (ConversationRow) -> Void = { _ in }
    /// A tap on a face in the chain. The chain cannot present over itself, so
    /// the chat is the one that opens the profile.
    var onOpenPerson: (PersonRef) -> Void = { _ in }
    /// Called with the text and any attachments of a reply into this chain.
    var onSend: (String, [PickedMedia]) -> Void = { _, _ in }
    var onDismiss: () -> Void = {}

    @State private var draft = ""
    @State private var gathered = false
    /// Drives the only thing that animates on the way in: the scrim and the
    /// chain. See ``body``.
    @State private var shown = false
    /// How tall the chain actually is, so the scroll view can be exactly that
    /// and no taller. See ``chain(in:)``.
    @State private var chainHeight: CGFloat = 0
    @State private var pressed: MessagePress?
    @State private var emojiTarget: MessagePress?
    @State private var rosterTarget: MessageDisplay?
    @State private var staged: [PickedMedia] = []
    @State private var isAttachmentPickerPresented = false
    @State private var isInfoPresented = false
    @State private var isWriting = false

    /// How far each reply starts above where it belongs, per step of distance
    /// from the root. Small: this is a gathering, not a fountain.
    private static let gather: CGFloat = 14

    var body: some View {
        // A real navigation stack, for a real toolbar.
        //
        // The bar was hand-drawn here for a while and it was never quite right:
        // the title sat a few points low, the close button was the wrong size
        // and the wrong kind of glass, and every fix was another guess at
        // metrics UIKit already knows. Giving this view a bar of its own hands
        // the placement and the styling back to the system, so the title lands
        // exactly where the chat's does and the close button is the same
        // control as the pin beside it — because it is the same control.
        NavigationStack {
            GeometryReader { geo in
                ZStack(alignment: .top) {
                    scrim().opacity(shown ? 1 : 0)
                    chain(in: geo).opacity(shown ? 1 : 0)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if canPost { composer }
                }
                .overlay { actionsOverlay }
                .sheet(item: $emojiTarget) { target in
                    EmojiBrowser(selected: target.selectedGlyph) { glyph in
                        emojiTarget = nil
                        onReact(target.item, glyph)
                    }
                }
                .sheet(isPresented: $isInfoPresented) {
                    if let conversation {
                        ConversationInfoView(conversation: conversation, members: members)
                    }
                }
                .sheet(item: $rosterTarget) { item in
                    ReactionRoster(summaries: item.reactions, members: members, meID: meID)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            // The same hidden bar background the chat uses, so the scrim runs
            // under the toolbar rather than stopping against a slab.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { toolbar }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.18)) { shown = true }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { gathered = true }
        }
    }

    /// Dim first, blur second, both at full strength. The conversation behind
    /// is context, not competition: it should be legible as a shape and
    /// illegible as words, which is exactly what a heavy blur under a dim does.
    ///
    /// Edge to edge and under everything, with no gap and no ramp. Anything
    /// less leaves a band across the screen with an edge on it, which reads as
    /// a panel laid over the chat rather than the chat receding behind a
    /// chain.
    private func scrim() -> some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Color.black.opacity(0.28))
            .ignoresSafeArea()
            .contentShape(.rect)
            .onTapGesture(perform: close)
            .accessibilityLabel("Close thread")
            .accessibilityAddTraits(.isButton)
    }

    /// The chain, opened where it was tapped.
    ///
    /// The first message keeps the reader's place: it is drawn at the y the
    /// tapped bubble was already at, so the screen does not lurch. Everything
    /// after it arrives from just above where it belongs, so the replies read
    /// as collecting around the message they answer rather than as a list that
    /// was always there.
    /// The scroll view is sized to its content and the gap above it is a
    /// non-hit-testing spacer, which is what keeps the background tappable. A
    /// scroll view takes every touch inside its frame, empty or not, so one
    /// stretched over the screen is a lid on the scrim: the way out stops
    /// working everywhere except the few points the chain does not cover.
    private func chain(in geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: topInset(in: geo))
                .allowsHitTesting(false)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(item)
                            .offset(y: gathered ? 0 : -Self.gather * CGFloat(index))
                            .opacity(gathered || index == 0 ? 1 : 0)
                    }
                }
                // The transcript's own inset. Without it a bubble lifted into a
                // chain sits ten points further out than the one it was lifted
                // from, which is exactly the kind of drift that makes a chain
                // read as a different screen rather than the same messages.
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { chainHeight = $0 }
            }
            .frame(maxHeight: chainHeight > 0 ? chainHeight : nil, alignment: .top)
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.top)
            Spacer(minLength: 0)
        }
    }

    /// The chat's title, and a way out where the chat keeps its bar buttons.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: close) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close thread")
        }
        ToolbarItem(placement: .principal) {
            if let conversation {
                Button { isInfoPresented = true } label: {
                    ConversationTitle(conversation: conversation)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows conversation details")
            }
        }
    }

    /// The same row the transcript draws, with the same things you can do to
    /// it. A message behaves differently depending on which screen it is being
    /// read on is a message you cannot trust.
    private func row(_ item: MessageDisplay) -> some View {
        MessageRow(
            item: item,
            catalog: catalog,
            onReact: { onReact(item, $0) },
            onRetry: { onRetry(item) },
            onDiscard: { onDiscard(item) },
            canEdit: canEdit(item),
            onPress: { frame in
                pressed = MessagePress(
                    item: item, frame: frame,
                    canEdit: canEdit(item), canDelete: canDelete(item))
            },
            isHeld: pressed?.item.id == item.id,
            // Already in the chain, so the drag has nowhere to take you: it
            // puts the cursor in the field instead, which is what the reply was
            // for.
            onReply: { isWriting = true },
            onOpenThread: { _ in },
            onInspectReaction: { _ in rosterTarget = item },
            onOpenPerson: onOpenPerson)
    }

    /// The press menu, raised here rather than by the chat. A chain is
    /// presented over that view, and a menu it put on screen would come up
    /// underneath this one.
    @ViewBuilder private var actionsOverlay: some View {
        ZStack {
            if let pressed {
                MessageActionsOverlay(
                    anchor: pressed.frame,
                    glyphs: quickGlyphs,
                    selected: pressed.selectedGlyph,
                    actions: actions(pressed).map { action in
                        MessageAction(
                            action.title, symbol: action.symbol,
                            isDestructive: action.isDestructive
                        ) {
                            self.pressed = nil
                            action.perform()
                        }
                    },
                    onPick: { glyph in
                        self.pressed = nil
                        onReact(pressed.item, glyph)
                    },
                    onMore: {
                        self.pressed = nil
                        emojiTarget = pressed
                    },
                    onDismiss: { self.pressed = nil })
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: pressed == nil)
    }

    /// Where the first message goes: where it already was, kept off the
    /// toolbar and out of the bottom half of the screen, since a chain that
    /// opens below the fold has nowhere to put its replies.
    private func topInset(in geo: GeometryProxy) -> CGFloat {
        // `anchorY` was measured in the window; this stack begins wherever it
        // begins, and asking is safer than assuming a status bar's worth.
        let wanted = anchorY - geo.frame(in: .global).minY
        // The bar is the navigation stack's now, and this space already starts
        // underneath it.
        let floor: CGFloat = 8
        let ceiling = max(floor, geo.size.height * 0.42)
        return min(max(wanted, floor), ceiling)
    }

    /// Its own, rather than borrowing the chat's. Pointing the composer
    /// downstairs at a chain it could not see meant typing in one place and
    /// watching another, and a thread that cannot be answered from inside it is
    /// a reading view pretending to be a conversation.
    ///
    /// Built to the same measurements as ``ChatView``'s, down to the negative
    /// bottom padding that parks it against the home indicator, because it
    /// stands exactly where that one stands: anything off by a point reads as
    /// the bar jumping when a chain opens.
    private var composer: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                attachButton
                field
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, isWriting ? 10 : -14)
        .animation(.easeOut(duration: 0.2), value: isWriting)
        .attachmentPicker(isPresented: $isAttachmentPickerPresented) { picked in
            staged.append(contentsOf: picked)
            isWriting = true
        }
    }

    /// A button rather than the chat's menu: a poll or an event is a thing a
    /// conversation holds, not a thing a reply to one message is, so photos are
    /// the whole list and a list of one is a button.
    private var attachButton: some View {
        Button { isAttachmentPickerPresented = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 21, weight: .medium))
                .frame(width: Self.composerHeight, height: Self.composerHeight)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel("Add attachment")
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !staged.isEmpty {
                stagedStrip
                Divider().padding(.leading, 14)
            }
            HStack(alignment: .bottom, spacing: 4) {
                ComposerField("Reply", text: $draft, isFocused: $isWriting)
                    .padding(.leading, 16)
                    .padding(.vertical, 11)
                    .frame(minHeight: Self.composerHeight)
                    .accessibilityLabel("Reply")

                sendButton
                    .animation(.snappy(duration: 0.18), value: canSend)
            }
        }
        .animation(.snappy(duration: 0.22), value: staged)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
    }

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
        }
        .accessibilityLabel(item.kind == .video ? "Video attachment" : "Photo attachment")
    }

    @ViewBuilder private var sendButton: some View {
        if canSend {
            Button(action: send) {
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

    /// One line's worth of composer, which the attach button matches.
    private static let composerHeight: CGFloat = 44
    private static let chipSide: CGFloat = 56

    private var canSend: Bool { !trimmed.isEmpty || !staged.isEmpty }

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fades what this view added and then hands back. The presentation itself
    /// is raised and dropped without animation, so this is the whole of the
    /// transition in both directions and the header never moves.
    private func close() {
        withAnimation(.easeIn(duration: 0.16)) {
            shown = false
            gathered = false
        }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            onDismiss()
        }
    }

    private func send() {
        guard canSend else { return }
        onSend(trimmed, staged)
        draft = ""
        staged = []
    }

}
