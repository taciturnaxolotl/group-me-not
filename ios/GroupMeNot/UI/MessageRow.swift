import SwiftUI

// MARK: - Display model

/// One message, already resolved into everything the row needs to draw itself.
///
/// The row does no lookups: whether the message is mine, what the sender is
/// called, whether it opens or closes a run, how far along delivery is, which
/// reactions it carries and how its text is styled are all decided once when
/// the transcript is built. A view that has to ask questions during layout is a
/// view that scrolls badly.
nonisolated struct MessageDisplay: Identifiable, Hashable, Sendable {

    /// How far a message has got towards the server.
    enum Delivery: Hashable, Sendable {
        /// GroupMe has it.
        case sent
        /// Queued locally, on its way or waiting for a network. The fraction is
        /// how much of its attachments have gone out, and is nil when there are
        /// none or nothing is in flight yet.
        case pending(Double?)
        /// The last attempt failed. The string is what to tell the user.
        case failed(String?)
    }

    /// Stable across reloads: the server id once there is one, the outbox guid
    /// before that.
    var id: String
    var message: Message
    var isOwn: Bool
    /// The sender's nickname in this conversation, already resolved.
    var senderName: String
    var senderAvatarURL: String?
    /// True on the first message of a run, which is the only one that shows a
    /// name and a face.
    var showsSender: Bool
    /// True on the last message of a run, which carries the timestamp and the
    /// squared-off corner.
    var isRunTail: Bool
    var delivery: Delivery
    /// Links, mentions and the emoji-only verdict, parsed once.
    var text: MessageText
    /// The same text with the palette applied. Handed straight to `Text`.
    var styledText: AttributedString
    /// Reaction buckets, plain likes already folded into the heart, with our
    /// own membership resolved.
    var reactions: [Message.ReactionSummary]

    var isPending: Bool {
        if case .pending = delivery { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = delivery { return true }
        return false
    }

    /// What went wrong, when the sync layer had something worth repeating.
    var failureReason: String? {
        if case .failed(let reason) = delivery { return reason }
        return nil
    }

    /// A reaction needs a server id to name the message and a message that
    /// still exists to put it on, so queued and deleted rows do not offer one.
    var canReact: Bool {
        delivery == .sent && !message.isDeleted && !message.isSystem
    }

    /// True once the author has rewritten this message.
    ///
    /// Straight off `updated_at`, which the store has been keeping all along and
    /// nothing was reading. Worth surfacing: an edit is invisible to REST
    /// catch-up, so a reader who sees changed text with no marker has no way to
    /// tell a rewrite from a misremembering.
    var isEdited: Bool { message.isEdited && !message.isDeleted }

    /// The link worth a card. Only the first: past that the message is a link
    /// dump and cards stop helping.
    var previewLink: URL? {
        message.isDeleted ? nil : text.previewLink
    }

    /// True for the one case that renders bigger and without a bubble tint.
    /// Attachments veto it: a photo with a thumbs-up under it is still a photo.
    var isEmojiOnly: Bool {
        text.isEmojiOnly && (message.attachments ?? []).allSatisfy { $0.type == "mentions" }
    }
}

// MARK: - Row

/// A single line of the transcript.
///
/// Three shapes live here rather than in three views, because which one you get
/// is a property of the message and callers should not have to switch on it:
/// system notices are centred grey text, deleted messages are a tombstone, and
/// everything else is a bubble.
struct MessageRow: View {
    let item: MessageDisplay
    /// The glyphs the long-press bar offers.
    var catalog: ReactionCatalog = .default
    /// Link previews, or nil where there is no model to ask.
    var previews: LinkPreviewService?
    /// Called with the tapped glyph. The model decides whether that adds,
    /// swaps or clears; the row only reports the tap.
    var onReact: (String) -> Void = { _ in }
    /// Called when the user asks to send a failed message again.
    var onRetry: () -> Void = {}
    /// Called when the user gives up on a failed message.
    var onDiscard: () -> Void = {}
    /// Whether this conversation's edit window is still open for this message.
    ///
    /// Decided outside the row, because the window is `Group.messageEditPeriod`
    /// and lives on the conversation, not the message. Passed rather than
    /// inferred so the action is simply absent once the window closes: offering
    /// an Edit the server is going to refuse is worse than offering none.
    var canEdit: Bool = false
    /// Called with the new text when the user finishes an edit.
    var onEdit: (String) -> Void = { _ in }

    var body: some View {
        if item.message.isSystem {
            SystemNotice(text: item.message.text ?? "")
        } else {
            BubbleRow(
                item: item,
                catalog: catalog,
                previews: previews,
                onReact: onReact,
                onRetry: onRetry,
                onDiscard: onDiscard,
                canEdit: canEdit,
                onEdit: onEdit)
        }
    }
}

/// Joins, leaves, renames, and the rest: centred, quiet, and not attributed to
/// anyone.
private struct SystemNotice: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.vertical, 6)
            .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Bubble

private struct BubbleRow: View {
    let item: MessageDisplay
    let catalog: ReactionCatalog
    let previews: LinkPreviewService?
    let onReact: (String) -> Void
    let onRetry: () -> Void
    let onDiscard: () -> Void
    let canEdit: Bool
    let onEdit: (String) -> Void

    @Environment(AppSettings.self) private var settings

    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var gutter: CGFloat = 56
    @ScaledMetric(relativeTo: .caption) private var chipHeight: CGFloat = 26

    /// How far a chip sits inside the bubble it hangs off. The rest of its
    /// height is reserved below, so the next row never has to move over.
    private let chipOverlap: CGFloat = 9

    /// The bubble's frame in global space, captured on every layout pass so a
    /// long press can hand it to the overlay. Cheap, and the alternative is
    /// measuring at press time, which is a frame too late.
    @State private var bubbleFrame: CGRect = .zero
    @State private var isPickerPresented = false
    @State private var isEditorPresented = false
    /// Same sequencing as `editWanted`: a sheet raised while the popover is
    /// still dismissing is a sheet that never appears.
    @State private var emojiWanted = false
    @State private var isEmojiBrowserPresented = false
    /// Set by the Edit action and consumed once the popover has actually gone.
    /// Raising a sheet while a popover is still dismissing loses the sheet, so
    /// the two are sequenced rather than fired together.
    @State private var editWanted = false
    @State private var editDraft = ""

    /// Which edge this bubble hangs off.
    ///
    /// Everyone else is always leading; my own messages follow the setting.
    /// Layout reads this, and only this. Colour still reads `item.isOwn`,
    /// because who said a thing does not change when you move it.
    private var isTrailing: Bool {
        item.isOwn && settings.ownMessageAlignment == .sided
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isTrailing {
                // Keeps my bubbles from running the full width, which is what
                // makes the two sides readable at a glance.
                Spacer(minLength: gutter)
            } else {
                // In one-column mode my own messages get a face and a name too.
                // Without them the column would start at a different x for me
                // than for everyone else, which reads as a mistake.
                avatarSlot
            }

            VStack(alignment: isTrailing ? .trailing : .leading, spacing: 2) {
                if item.showsSender && !isTrailing {
                    Text(item.senderName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                }

                messageBody

                footer
            }

            if !isTrailing { Spacer(minLength: gutter) }
        }
        .padding(.vertical, item.isRunTail ? 3 : 1)
        // `.contain` rather than `.combine`: the chips, the links and the
        // preview card are all things to act on, and flattening the row would
        // read them out and then hide them.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityContext)
    }

    /// Reserved even when empty, so a run of messages stays in one column.
    @ViewBuilder private var avatarSlot: some View {
        if item.showsSender {
            Avatar(url: item.senderAvatarURL, name: item.senderName, size: avatarSize)
        } else {
            Color.clear.frame(width: avatarSize, height: 1)
        }
    }

    // MARK: The bubble and everything hanging off it

    /// Bubble, preview card, and the reaction chips that straddle the bottom of
    /// whichever of those two ends up last.
    private var messageBody: some View {
        VStack(alignment: isTrailing ? .trailing : .leading, spacing: 4) {
            // Outside the bubble, deliberately. A photo is not text with a
            // picture in it; it is the message. Wrapping it in tinted padding
            // puts a coloured frame around somebody's holiday snap and makes
            // every image on screen sit inside a box it does not need. Messages
            // draws them bare, and a caption underneath becomes its own bubble.
            if !pictureAttachments.isEmpty, !item.message.isDeleted {
                PhotoCascade(pictures: pictureAttachments, isTrailing: isTrailing)
                    .opacity(item.isPending ? 0.55 : 1)
                    .animation(.easeOut(duration: 0.2), value: item.isPending)
                    // Over the pile rather than over each photo. One ring for
                    // one message: the fraction covers all of its attachments,
                    // and three rings counting the same thing would be three
                    // ways to be confused.
                    .overlay { uploadRing }
            }
            bubble
            if let link = item.previewLink {
                LinkPreviewCard(url: link, isOwn: item.isOwn, service: previews)
            }
        }
        .overlay(alignment: isTrailing ? .bottomTrailing : .bottomLeading) { chips }
        // The overlay draws outside the layout, so the overhang is paid for
        // here. Without this the row below would be sat on.
        .padding(.bottom, item.reactions.isEmpty ? 0 : chipHeight - chipOverlap)
        // A chip appearing is the entire feedback for a tap, so it is the one
        // thing in this row worth animating. Driven from out here rather than
        // from the chips themselves, because a transition only animates when
        // the animation is attached above the view being inserted.
        .animation(.snappy(duration: 0.2), value: item.reactions)
        .contentShape(.rect)
        // `maximumDistance` is not about the finger. It measures movement
        // relative to *this view*, and the view moves on its own:
        // `.defaultScrollAnchor(.bottom, for: .sizeChanges)` re-pins the
        // transcript to the content bottom whenever it resizes, so a typing
        // bubble appearing (~45pt) or a catch-up rewriting history yanks the row
        // out from under a stationary touch and cancels the press. At the 10pt
        // default that makes the newest few messages unpressable while the ones
        // above them work perfectly, which is a maddening thing to debug.
        //
        // 44pt absorbs those shifts and still sits well inside the distance a
        // real drag covers before the pan recogniser claims the touch, so
        // scrolling does not start opening pickers.
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { bubbleFrame = $0 }
        .onLongPressGesture(minimumDuration: 0.32, maximumDistance: 44) { showPicker(true) }
        // On the way up only. A haptic for the dismissal would be a second
        // tap the user did not make.
        .sensoryFeedback(trigger: isPickerPresented) { _, shown in
            shown ? .impact(weight: .light) : nil
        }
        // A cover rather than a popover, so the two floating pieces can sit
        // above and below the bubble instead of inside one box with an arrow.
        // Its background is cleared and its own slide-up animation suppressed;
        // the overlay animates itself, out of the message that was pressed.
        .fullScreenCover(isPresented: $isPickerPresented) {
            MessageActionsOverlay(
                anchor: bubbleFrame,
                glyphs: catalog.quick,
                selected: mine,
                actions: pickerActions,
                onPick: { glyph in
                    showPicker(false)
                    onReact(glyph)
                },
                onMore: {
                    emojiWanted = true
                    showPicker(false)
                },
                onDismiss: { showPicker(false) })
                .presentationBackground(.clear)
        }
        .onChange(of: isPickerPresented) { _, shown in
            guard !shown else { return }
            if editWanted {
                editWanted = false
                isEditorPresented = true
            } else if emojiWanted {
                emojiWanted = false
                isEmojiBrowserPresented = true
            }
        }
        .sheet(isPresented: $isEmojiBrowserPresented) {
            EmojiBrowser(selected: mine) { glyph in
                isEmojiBrowserPresented = false
                onReact(glyph)
            }
        }
        .alert("Edit Message", isPresented: $isEditorPresented) {
            TextField("Message", text: $editDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let text = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text != item.message.text else { return }
                onEdit(text)
            }
        }
    }

    @ViewBuilder private var chips: some View {
        if !item.reactions.isEmpty {
            ReactionChips(
                summaries: item.reactions,
                isOwn: isTrailing,
                height: chipHeight,
                onTap: onReact
            )
            .offset(x: isTrailing ? -10 : 10, y: chipHeight - chipOverlap)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
    }

    /// The ring over a photo still on its way out.
    ///
    /// Absent until there is something to say. A send that has not started, or
    /// one with nothing to upload, gets the dimmed bubble and no ring: a ring
    /// stuck at zero reads as a failure rather than as a queue.
    @ViewBuilder private var uploadRing: some View {
        if case .pending(let fraction) = item.delivery, let fraction, fraction < 1 {
            UploadRing(fraction: fraction)
                .transition(.opacity)
        }
    }

    /// Whether there is anything left for a bubble to hold.
    ///
    /// A message that is only photographs gets no bubble at all: an empty tinted
    /// rectangle under a picture is a frame around nothing.
    private var hasBubbleContent: Bool {
        item.message.isDeleted
            || !item.text.isEmpty
            || item.isEdited
            || !otherAttachments.isEmpty
    }

    @ViewBuilder private var bubble: some View {
        SwiftUI.Group {
            if !hasBubbleContent {
                EmptyView()
            } else if item.message.isDeleted {
                Tombstone()
            } else if item.isEmojiOnly {
                // No tint, no padding worth speaking of: a lone emoji is its
                // own bubble.
                Text(item.text.plain)
                    .font(.system(size: MessageStyling.emojiFontSize))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            } else {
                VStack(alignment: isTrailing ? .trailing : .leading, spacing: 6) {
                    ForEach(Array(otherAttachments.enumerated()), id: \.offset) { _, attachment in
                        AttachmentChipFor(attachment: attachment, isOwn: item.isOwn)
                    }
                    if !item.text.isEmpty {
                        Text(item.styledText)
                            .font(.body)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            // Links come out of the parser as `.link` runs, so
                            // `Text` makes them tappable for free. The tint is
                            // already baked in per side.
                            .tint(item.isOwn ? .white : .accentColor)
                    }
                    if item.isEdited { editedMarker }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(item.isOwn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(bubbleTint, in: bubbleShape)
            }
        }
        // The whole point of the optimistic send: the bubble is there instantly
        // and merely looks provisional until the server agrees.
        .opacity(item.isPending ? 0.55 : 1)
        .animation(.easeOut(duration: 0.2), value: item.isPending)
    }

    /// "Edited", under the text and out of the way.
    ///
    /// Inside the bubble rather than in the footer on purpose: the footer only
    /// draws on the tail of a run, and an edited message in the middle of one
    /// would otherwise carry no marker at all.
    private var editedMarker: some View {
        Text("Edited")
            .font(.caption2)
            .foregroundStyle(item.isOwn ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.secondary))
            .accessibilityLabel("Edited")
    }

    private var bubbleTint: AnyShapeStyle {
        item.isOwn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.secondarySystemFill))
    }

    /// Rounded on three corners, and squared off on the one nearest the sender
    /// when the run ends. Same idea as Messages: the tail points at whoever
    /// said it, which means it follows the alignment rather than the author.
    private var bubbleShape: UnevenRoundedRectangle {
        let big: CGFloat = 18
        let tail: CGFloat = item.isRunTail ? 5 : 18
        return UnevenRoundedRectangle(
            topLeadingRadius: big,
            bottomLeadingRadius: isTrailing ? big : tail,
            bottomTrailingRadius: isTrailing ? tail : big,
            topTrailingRadius: big,
            style: .continuous
        )
    }

    /// Timestamp and the failure affordance. Only on the tail of a run, so a
    /// burst of five messages does not carry five clocks. Likes used to live
    /// here and now live in the chips, where they belong.
    @ViewBuilder private var footer: some View {
        if item.isFailed {
            let reason = item.failureReason ?? "Not delivered"
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                Text(reason)
                    .lineLimit(1)
                Button("Try Again", action: onRetry)
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
            }
            .font(.caption)
            .foregroundStyle(.red)
            .padding(.horizontal, 4)
            .padding(.top, 1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(reason)
            .accessibilityHint("Double tap Try Again to send it again")
        } else if item.isRunTail {
            Text(Formatters.messageTime(item.message.date))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.top, 1)
                .accessibilityHidden(true)
        }
    }

    // MARK: The long-press bar

    /// Raise or drop the actions overlay without the cover's own slide-up.
    ///
    /// A `fullScreenCover` animates in from the bottom edge, which is the wrong
    /// gesture entirely for something that should appear on the message under
    /// the finger. Suppressing it here rather than with a `.transaction` on the
    /// row keeps the suppression to this one state change: the same modifier
    /// applied to the view would silence the reaction chips and every other
    /// animation in the subtree.
    private func showPicker(_ shown: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { isPickerPresented = shown }
    }

    /// The glyph shown as selected, which is also the one a second tap clears.
    private var mine: String? {
        item.reactions.first { $0.reactedByMe }?.glyph
    }

    /// Everything the context menu used to carry. The reaction bar above it is
    /// unconditional; these are not.
    private var pickerActions: [MessageAction] {
        var actions: [MessageAction] = []
        if !item.text.isEmpty, !item.message.isDeleted {
            actions.append(.init("Copy", symbol: "doc.on.doc") {
                UIPasteboard.general.string = item.text.plain
                showPicker(false)
            })
        }
        if canEdit {
            actions.append(.init("Edit", symbol: "pencil") {
                // The server's own text, not the parsed copy: an edit starts
                // from what was actually posted.
                editDraft = item.message.text ?? ""
                editWanted = true
                showPicker(false)
            })
        }
        if item.isFailed {
            actions.append(.init("Try Again", symbol: "arrow.clockwise") {
                showPicker(false)
                onRetry()
            })
            actions.append(.init("Delete", symbol: "trash", isDestructive: true) {
                showPicker(false)
                onDiscard()
            })
        }
        return actions
    }

    /// The photographs, in order, which is also the order the viewer pages
    /// through.
    private var pictureAttachments: [Message.Attachment] {
        displayableAttachments.filter { PhotoCascade.isPicture($0.type) }
    }

    /// Everything else: places, files, polls. These stay in the bubble, because
    /// each is drawn as a chip that reads as part of the message rather than as
    /// the message.
    private var otherAttachments: [Message.Attachment] {
        displayableAttachments.filter { !PhotoCascade.isPicture($0.type) }
    }

    /// Replies and mentions are structure, not content: they have nothing to
    /// draw on their own, so they never reach the attachment stack.
    private var displayableAttachments: [Message.Attachment] {
        (item.message.attachments ?? []).filter { $0.type != "mentions" && $0.type != "reply" }
    }

    /// Who and when, and nothing else: the text, the attachments and the chips
    /// are all children now and speak for themselves. Repeating them here would
    /// make VoiceOver read every message twice.
    private var accessibilityContext: String {
        var parts: [String] = []
        parts.append(item.isOwn ? "You said" : "\(item.senderName) said")
        if item.message.isDeleted { parts.append("this message was deleted") }
        if item.isEdited { parts.append("edited") }
        switch item.delivery {
        case .sent: parts.append(Formatters.spokenTimestamp(item.message.date))
        case .pending: parts.append("sending")
        case .failed(let reason): parts.append(reason ?? "not delivered")
        }
        return parts.joined(separator: ", ")
    }
}

/// A deleted message. GroupMe keeps delivering the row with its text stripped,
/// so the gap is real and worth showing rather than hiding.
private struct Tombstone: View {
    var body: some View {
        Text("Message deleted")
            .font(.body.italic())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color(.separator), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
    }
}

// MARK: - Attachments

/// The photographs a message carried, drawn bare.
///
/// No tint, no padding, no bubble. Photos draw at their real shape and still
/// never resize on arrival, because the shape comes out of the URL rather than
/// out of the pixels. See `MediaDimensions`.
private struct PhotoCascade: View {
    let pictures: [Message.Attachment]
    /// Which edge the message hangs off, which decides which way the pile leans.
    let isTrailing: Bool

    /// The one the user tapped, if any. Wrapped rather than used directly
    /// because `Message.Attachment` has no identity of its own and a message can
    /// carry two identical ones.
    @State private var viewing: ViewableMedia?

    static func isPicture(_ type: String?) -> Bool {
        type == "image" || type == "video" || type == "linked_image"
    }

    var body: some View {
        content
            .fullScreenCover(item: $viewing) { item in
                // The whole run, not the one that was tapped, so a swipe inside
                // the viewer reaches the others.
                MediaViewer(attachments: pictures, initialIndex: item.id)
            }
    }

    /// Several photos are stacked and staggered rather than listed.
    ///
    /// This is what Messages does with a burst of pictures, and the reason is
    /// not decoration: four photos in a plain column is most of a screen of
    /// scrolling for one message, and it reads as four separate things rather
    /// than as one thing somebody sent. Overlapping them says "these arrived
    /// together" in a way vertical spacing cannot, and the alternating offset is
    /// what keeps the one underneath legible instead of merely hidden.
    @ViewBuilder private var content: some View {
        if pictures.count == 1 {
            MediaThumbnail(attachment: pictures[0], heightCap: heightCap)
                .onTapGesture { viewing = ViewableMedia(id: 0, attachment: pictures[0]) }
        } else if !pictures.isEmpty {
            // Placed by hand, and sized by hand, because both halves of that
            // matter. A `VStack` with negative spacing and `.offset` children
            // leaves the container describing a different rectangle from the one
            // its contents actually occupy, and whatever lays it out believes
            // the description. Here the frame is the arithmetic.
            ZStack(alignment: .topLeading) {
                ForEach(Array(pictures.enumerated()), id: \.offset) { index, attachment in
                    MediaThumbnail(
                        attachment: attachment,
                        heightCap: heightCap,
                        reserved: boxes[index])
                        .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
                        .offset(x: lean(at: index), y: top(of: index))
                        // Later photos sit on top, so the cascade reads front to
                        // back in the order they were sent.
                        .zIndex(Double(index))
                        .onTapGesture { viewing = ViewableMedia(id: index, attachment: attachment) }
                }
            }
            .frame(width: stackSize.width, height: stackSize.height, alignment: .topLeading)
        }
    }

    /// How tall any one photo here may draw.
    ///
    /// A lone portrait shot is allowed real height; a message carrying three of
    /// them is not, or the reader has to scroll past one message to reach the
    /// next. Fixed off the count rather than measured, so it is known before
    /// anything loads.
    private var heightCap: CGFloat { pictures.count > 1 ? 240 : 360 }

    /// Every picture's box, worked out once so the cascade can place them.
    private var boxes: [CGSize] {
        pictures.map { MediaThumbnail.reservedBox(for: $0, heightCap: heightCap) }
    }

    /// Where each photo's top edge sits: the one before it, less the overlap.
    private func top(of index: Int) -> CGFloat {
        boxes.prefix(index).reduce(0) { $0 + $1.height - Self.overlap }
    }

    /// Alternating so the pile does not drift, and shifted into positive space
    /// so the leftmost photo starts at the container's own edge.
    private func lean(at index: Int) -> CGFloat {
        let side = index.isMultiple(of: 2) ? -Self.stagger : Self.stagger
        return Self.stagger + (isTrailing ? -side : side)
    }

    /// Exactly the rectangle the photos occupy: the widest of them plus the
    /// room the stagger needs on both sides, and the foot of the last one.
    private var stackSize: CGSize {
        guard let last = boxes.indices.last else { return .zero }
        return CGSize(
            width: (boxes.map(\.width).max() ?? 0) + Self.stagger * 2,
            height: top(of: last) + boxes[last].height)
    }

    /// How far each photo leans, alternating so the pile does not drift.
    private static let stagger: CGFloat = 14
    /// How much of the photo above stays covered.
    private static let overlap: CGFloat = 22
}

/// One tapped attachment, given the identity `fullScreenCover(item:)` needs.
///
/// The index is the identity: `Message.Attachment` carries none of its own, and
/// a message can perfectly well hold the same photo twice.
private struct ViewableMedia: Identifiable {
    let id: Int
    let attachment: Message.Attachment
}

/// A photo or video still in a box of known size.
///
/// "Known" is the important word. The box is computed from the dimensions
/// GroupMe puts in the URL, so it is both the picture's true shape and settled
/// before the first byte arrives. Scaled to fit, never cropped.
private struct MediaThumbnail: View {
    let attachment: Message.Attachment
    /// The tallest this photo may draw, decided by how many are in the message.
    var heightCap: CGFloat = 320
    /// The exact box to draw in, when the caller has already worked it out.
    ///
    /// A cascade has to know every photo's height to place the next one, so the
    /// stack computes them all and hands each thumbnail its own. That also
    /// settles the sizes for good: `measured` is skipped, because a photo that
    /// resized itself after loading would slide out from under the one drawn on
    /// top of it.
    var reserved: CGSize?

    /// The widest a photo draws. A little under half the narrowest phone in
    /// portrait, which leaves the gutter, the avatar and the padding room on
    /// every device rather than only on big ones.
    static let maxWidth: CGFloat = 240
    /// Small pictures draw at life size rather than blown up, but not so small
    /// that they stop being a tap target.
    static let minWidth: CGFloat = 96

    /// The box used when the URL declares no dimensions: older messages, other
    /// hosts, and the local `file://` URL a queued upload points at. Roughly
    /// the 4:3 a phone camera produces. Guessing a shape would be worse than
    /// admitting we do not know one, so this stays the fallback and only the
    /// fallback.
    static let fallback = CGSize(width: 232, height: 174)

    /// What the pixels turned out to be, for the URLs that declare nothing.
    /// Nil for the ones that do, because then there is nothing to correct.
    @State private var measured: CGSize?

    var body: some View {
        RemoteImage(url: url, maxPixelSize: box.width * 3, onLoad: adopt) {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: attachment.type == "video" ? "play.rectangle.fill" : "photo")
                    .font(.title)
                    .foregroundStyle(.tertiary)
            }
        }
        // The frame is set before anything loads, so the row's height is known
        // from the first layout pass and never changes.
        .frame(width: box.width, height: box.height)
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .overlay {
            if attachment.type == "video" {
                Image(systemName: "play.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white, .black.opacity(0.35))
            }
        }
        .accessibilityLabel(attachment.type == "video" ? "Video" : "Photo")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Double tap to open")
    }

    /// The space this photo occupies, in points.
    ///
    /// The largest box of the picture's own shape that fits the limits, so
    /// nothing is cropped. Shrinking only: a small picture is drawn at life size
    /// rather than blown up to fill the width.
    ///
    /// The one exception is the picture too narrow to tap once it has been made
    /// to fit, which means an aspect ratio no camera produces and in practice
    /// means a full-page screenshot. That one is widened to `minWidth` and
    /// allowed to run past the height cap, where it is cropped: a 50-point
    /// ribbon of a screenshot is not a picture anybody can see.
    static func box(for size: CGSize, heightCap: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return fallback }
        let shrink = min(maxWidth / size.width, heightCap / size.height, 1)
        let width = max(size.width * shrink, minWidth)
        let height = min(size.height * width / size.width, heightCap)
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    /// The URL's own account of its shape, or the pixels' if the URL kept quiet,
    /// or the fallback until either turns up.
    private var box: CGSize {
        if let reserved { return reserved }
        guard let size = MediaDimensions.declared(in: url) ?? measured else { return Self.fallback }
        return Self.box(for: size, heightCap: heightCap)
    }

    /// The box a photo will occupy, without drawing it. The cascade asks this
    /// for every picture before laying any of them out.
    static func reservedBox(for attachment: Message.Attachment, heightCap: CGFloat) -> CGSize {
        guard let size = MediaDimensions.declared(in: url(of: attachment)) else { return fallback }
        return box(for: size, heightCap: heightCap)
    }

    /// Correct the reservation, but only where there was nothing to reserve it
    /// from. A URL that declared its size was right the first time, and letting
    /// the pixels re-decide would move a row that had settled.
    private func adopt(_ size: CGSize) {
        guard reserved == nil, MediaDimensions.declared(in: url) == nil, measured != size else { return }
        measured = size
    }

    /// The still to draw.
    ///
    /// `previewUrl` first, because a video's own `url` is an MP4 and no image
    /// loader is going to make a picture out of it. For a queued attachment both
    /// of these are `file://` URLs into the vault, which the loader reads
    /// exactly as happily as an HTTPS one; that is what lets one renderer draw a
    /// photo that is still on the phone and one that came back from GroupMe.
    private var url: URL? { Self.url(of: attachment) }

    static func url(of attachment: Message.Attachment) -> URL? {
        let candidate = attachment.previewUrl ?? attachment.url ?? attachment.sourceUrl
        return candidate.flatMap(URL.init(string:))
    }
}

/// An attachment the transcript cannot draw inline, named rather than rendered.
/// These stay inside the bubble: a chip is part of a message, not the message.
private struct AttachmentChipFor: View {
    let attachment: Message.Attachment
    let isOwn: Bool

    var body: some View {
        switch attachment.type {
        case "location":
            AttachmentChip(
                symbol: "mappin.and.ellipse",
                title: attachment.name ?? "Location",
                isOwn: isOwn
            )
        case "file":
            AttachmentChip(symbol: "doc.fill", title: attachment.name ?? "File", isOwn: isOwn)
        case "audio":
            AttachmentChip(symbol: "waveform", title: "Voice message", isOwn: isOwn)
        case "poll":
            AttachmentChip(symbol: "chart.bar.fill", title: "Poll", isOwn: isOwn)
        case "event":
            AttachmentChip(symbol: "calendar", title: "Event", isOwn: isOwn)
        case "emoji":
            EmptyView()
        default:
            AttachmentChip(symbol: "paperclip", title: Self.noun(for: attachment.type), isOwn: isOwn)
        }
    }

    /// A word for an attachment the transcript cannot render, used in previews
    /// and read aloud by VoiceOver.
    static func noun(for type: String?) -> String {
        switch type {
        case "image", "linked_image": "Photo"
        case "video": "Video"
        case "audio": "Voice message"
        case "file": "File"
        case "location": "Location"
        case "poll": "Poll"
        case "event": "Event"
        default: "Attachment"
        }
    }
}

/// A one-line stand-in for an attachment we do not render inline.
private struct AttachmentChip: View {
    let symbol: String
    let title: String
    let isOwn: Bool

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.subheadline)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isOwn ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(.quaternary),
                        in: .rect(cornerRadius: 10, style: .continuous))
    }
}


/// How much of an attachment has gone out.
///
/// A ring rather than a bar, because it sits on top of a picture and a bar wants
/// an edge to live along. Determinate throughout: `URLSession` reports bytes
/// sent against bytes expected, so there is never a moment where this has to
/// pretend by spinning.
private struct UploadRing: View {
    let fraction: Double

    private static let side: CGFloat = 44
    private static let lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.28), lineWidth: Self.lineWidth)
            Circle()
                .trim(from: 0, to: max(fraction, 0.02))
                .stroke(.white, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                // Twelve o'clock, not three. A ring that starts at the right
                // edge reads as already part-finished.
                .rotationEffect(.degrees(-90))
        }
        .frame(width: Self.side, height: Self.side)
        .padding(10)
        // Its own ground, because the photo underneath is arbitrary and white on
        // white is nothing at all.
        .background(.black.opacity(0.35), in: .circle)
        .animation(.easeOut(duration: 0.25), value: fraction)
        .accessibilityLabel("Uploading")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}
