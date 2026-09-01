import SwiftUI

/// What a conversation has pinned.
///
/// A sheet rather than a banner. A banner sits between the header and the
/// transcript, which is where the header's own photo and name already are, and
/// it needs a background to be legible over whatever is scrolling behind it, so
/// it puts a slab across the top of the screen to say something most people are
/// not looking for. Behind a button it costs nothing until it is wanted.
struct PinnedMessagesView: View {
    let messages: [Message]
    let members: [Member]
    /// Jump to it in the transcript. Returns whether it could be found: a pin
    /// can sit further back than we are willing to page.
    let onOpen: (String) async -> Bool
    let onUnpin: (Message) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The pin currently being dug out of the history.
    @State private var opening: String?
    @State private var tooFarBack = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(pins.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        pin(item)
                    }
                }
            }
            .overlay {
                if messages.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing Pinned", systemImage: "pin")
                    } description: {
                        Text("Hold a message and choose Pin to keep it here.")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .alert("Too Far Back", isPresented: $tooFarBack) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This message sits deeper in the history than we can reach right now.")
        }
    }

    /// The pins, parsed exactly as the transcript parses them.
    ///
    /// Built by ``Transcript`` rather than by hand so the links, the mentions
    /// and the emoji verdict cannot drift out of step with the chat: there is
    /// one parser and this uses it. Day headings and system runs are dropped on
    /// the way out, since a pin carries its own date and nobody pins a notice.
    /// Newest first, which is the order a pin list is read in.
    private var pins: [MessageDisplay] {
        Transcript.rows(
            messages: messages.sorted { $0.date > $1.date },
            outbox: [],
            currentUser: model.currentUser,
            members: members
        ).compactMap { row in
            guard case .message(let item) = row else { return nil }
            return item
        }
    }

    private func pin(_ item: MessageDisplay) -> some View {
        PinnedMessageCard(item: item, previews: model.previews)
            .opacity(opening == nil || opening == item.id ? 1 : 0.45)
            .overlay(alignment: .topTrailing) {
                if opening == item.id {
                    ProgressView().controlSize(.small).padding(.trailing, 16)
                }
            }
            .contentShape(.rect)
            .onTapGesture { open(item.message) }
            .contextMenu {
                Button(role: .destructive) {
                    onUnpin(item.message)
                } label: {
                    Label("Unpin", systemImage: "pin.slash")
                }
            }
    }

    private var title: String {
        messages.count == 1 ? "1 Pinned" : "\(messages.count) Pinned"
    }

    /// Digging can take a moment and can come up empty, so the pin says it is
    /// being worked on rather than leaving the tap looking unheard.
    private func open(_ message: Message) {
        guard opening == nil else { return }
        opening = message.id
        Task {
            let found = await onOpen(message.id)
            opening = nil
            if found { dismiss() } else { tooFarBack = true }
        }
    }
}

/// One pin, drawn to be read rather than to be chatted with.
///
/// It shares the transcript's content, not the transcript's furniture. The
/// formatting matters, since a pin is worth keeping because of what it says and
/// a one-line summary throws away precisely the links, mentions and pictures
/// that made it worth keeping. The rest of a bubble does not: alignment answers
/// "who said this", which the name already answers; the tint separates two
/// columns that are not here; the gutter keeps a paragraph off the far edge so
/// two columns stay readable, and holding a pin to two thirds of the width when
/// it is the only thing on the page just makes it harder to read.
private struct PinnedMessageCard: View {
    let item: MessageDisplay
    let previews: LinkPreviewService?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !pictures.isEmpty, !item.message.isDeleted {
                PhotoCascade(pictures: pictures, isTrailing: false)
            }
            ForEach(Array(chips.enumerated()), id: \.offset) { _, attachment in
                AttachmentChipFor(attachment: attachment, isOwn: false)
            }
            text
            if let link = item.previewLink {
                LinkPreviewCard(url: link, isOwn: false, service: previews)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Avatar(url: item.senderAvatarURL, name: item.senderName, size: 26)
            Text(item.senderName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(Formatters.listTimestamp(item.message.date))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var text: some View {
        if item.message.isDeleted {
            Text("Deleted message")
                .font(.body.italic())
                .foregroundStyle(.secondary)
        } else if item.isEmojiOnly {
            // Same treatment as the transcript: a lone emoji paints outside the
            // line box its font reports, so it needs the room and the fixed size.
            Text(item.text.plain)
                .font(.system(size: MessageStyling.emojiFontSize(count: item.text.emojiCount)))
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
        } else if !item.text.isEmpty {
            // Restyled rather than reused: `item.styledText` is coloured for a
            // tinted bubble, and here there is none to read against.
            Text(MessageStyling.style(item.text, isOwn: false))
                .font(.body)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Replies and mentions are structure rather than content, so they never
    /// reach the stack; the rest splits the way the transcript splits it.
    private var displayable: [Message.Attachment] {
        (item.message.attachments ?? []).filter { $0.type != "mentions" && $0.type != "reply" }
    }

    private var pictures: [Message.Attachment] {
        displayable.filter { PhotoCascade.isPicture($0.type) }
    }

    private var chips: [Message.Attachment] {
        displayable.filter { !PhotoCascade.isPicture($0.type) }
    }
}
