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
        /// Queued locally, on its way or waiting for a network.
        case pending
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

    var isPending: Bool { delivery == .pending }

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
        .onLongPressGesture(minimumDuration: 0.32, maximumDistance: 44) { isPickerPresented = true }
        // On the way up only. A haptic for the dismissal would be a second
        // tap the user did not make.
        .sensoryFeedback(trigger: isPickerPresented) { _, shown in
            shown ? .impact(weight: .light) : nil
        }
        .popover(isPresented: $isPickerPresented) {
            ReactionPicker(
                glyphs: catalog.glyphs,
                selected: mine,
                onPick: { glyph in
                    isPickerPresented = false
                    onReact(glyph)
                },
                onMore: {
                    emojiWanted = true
                    isPickerPresented = false
                },
                actions: pickerActions)
                .presentationCompactAdaptation(.popover)
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

    @ViewBuilder private var bubble: some View {
        SwiftUI.Group {
            if item.message.isDeleted {
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
                    AttachmentStack(
                        attachments: displayableAttachments,
                        isOwn: item.isOwn,
                        isTrailing: isTrailing)
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

    /// The glyph shown as selected, which is also the one a second tap clears.
    private var mine: String? {
        item.reactions.first { $0.reactedByMe }?.glyph
    }

    /// Everything the context menu used to carry. The reaction bar above it is
    /// unconditional; these are not.
    private var pickerActions: [ReactionPicker.Action] {
        var actions: [ReactionPicker.Action] = []
        if !item.text.isEmpty, !item.message.isDeleted {
            actions.append(.init("Copy", symbol: "doc.on.doc") {
                UIPasteboard.general.string = item.text.plain
                isPickerPresented = false
            })
        }
        if canEdit {
            actions.append(.init("Edit", symbol: "pencil") {
                // The server's own text, not the parsed copy: an edit starts
                // from what was actually posted.
                editDraft = item.message.text ?? ""
                editWanted = true
                isPickerPresented = false
            })
        }
        if item.isFailed {
            actions.append(.init("Try Again", symbol: "arrow.clockwise") {
                isPickerPresented = false
                onRetry()
            })
            actions.append(.init("Delete", symbol: "trash", isDestructive: true) {
                isPickerPresented = false
                onDiscard()
            })
        }
        return actions
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

/// Everything hanging off a message.
///
/// Photos draw at their real shape and still never resize on arrival, because
/// the shape comes out of the URL rather than out of the pixels. See
/// `MediaDimensions`. The frame is settled on the first layout pass, so the
/// transcript's scroll position is safe.
private struct AttachmentStack: View {
    let attachments: [Message.Attachment]
    /// Who wrote it, which decides the tint.
    let isOwn: Bool
    /// Which edge the bubble hangs off, which decides the layout. The two come
    /// apart once own messages can be drawn on the leading edge.
    let isTrailing: Bool

    /// The one the user tapped, if any. Wrapped rather than used directly
    /// because `Message.Attachment` has no identity of its own and a message can
    /// carry two identical ones.
    @State private var viewing: ViewableMedia?

    var body: some View {
        if !attachments.isEmpty {
            VStack(alignment: isTrailing ? .trailing : .leading, spacing: 6) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                    view(for: attachment, at: index)
                }
            }
            .fullScreenCover(item: $viewing) { item in
                MediaViewer(attachment: item.attachment)
            }
        }
    }

    @ViewBuilder private func view(for attachment: Message.Attachment, at index: Int) -> some View {
        switch attachment.type {
        case "image", "video", "linked_image":
            MediaThumbnail(attachment: attachment, heightCap: heightCap)
                .onTapGesture { viewing = ViewableMedia(id: index, attachment: attachment) }
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

    /// How tall any one photo here may draw.
    ///
    /// A lone portrait shot is allowed real height; a message carrying three of
    /// them is not, or the reader has to scroll past one message to reach the
    /// next. Fixed off the count rather than measured, so it is known before
    /// anything loads.
    private var heightCap: CGFloat {
        let pictures = attachments.filter { $0.type == "image" || $0.type == "video" || $0.type == "linked_image" }
        return pictures.count > 1 ? 200 : 320
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
        case "emoji": "Sticker"
        case "poll": "Poll"
        case "event": "Event"
        default: "Attachment"
        }
    }
}

/// One tapped attachment, given the identity `fullScreenCover(item:)` needs.
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

    /// The widest a photo draws. A little under half the narrowest phone in
    /// portrait, which leaves the gutter, the avatar and the padding room on
    /// every device rather than only on big ones.
    private static let maxWidth: CGFloat = 240
    /// Small pictures draw at life size rather than blown up, but not so small
    /// that they stop being a tap target.
    private static let minWidth: CGFloat = 96

    /// The box used when the URL declares no dimensions: older messages, other
    /// hosts, and the local `file://` URL a queued upload points at. Roughly
    /// the 4:3 a phone camera produces. Guessing a shape would be worse than
    /// admitting we do not know one, so this stays the fallback and only the
    /// fallback.
    private static let fallback = CGSize(width: 232, height: 174)

    var body: some View {
        RemoteImage(url: url, maxPixelSize: box.width * 3) {
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
    /// Width first, then height from the true ratio. Doing it in that order is
    /// what keeps a very tall picture usable: a full-page screenshot fitted on
    /// both axes would come out a forty-point sliver, so the width is held and
    /// the height is capped instead. A picture clamped that way is cropped
    /// rather than squashed, because `RemoteImage` fills its frame and the
    /// thumbnail clips.
    private var box: CGSize {
        guard let declared = MediaDimensions.declared(in: url),
              declared.width > 0, declared.height > 0
        else { return Self.fallback }
        let width = min(max(declared.width, Self.minWidth), Self.maxWidth)
        let height = width * declared.height / declared.width
        return CGSize(width: width.rounded(), height: min(height, heightCap).rounded())
    }

    /// The still to draw.
    ///
    /// `previewUrl` first, because a video's own `url` is an MP4 and no image
    /// loader is going to make a picture out of it. For a queued attachment both
    /// of these are `file://` URLs into the vault, which the loader reads
    /// exactly as happily as an HTTPS one; that is what lets one renderer draw a
    /// photo that is still on the phone and one that came back from GroupMe.
    private var url: URL? {
        let candidate = attachment.previewUrl ?? attachment.url ?? attachment.sourceUrl
        return candidate.flatMap(URL.init(string:))
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
