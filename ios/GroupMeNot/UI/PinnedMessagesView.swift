import SwiftUI

/// What a conversation has pinned.
///
/// A sheet rather than a banner. A banner sits between the header and the
/// transcript, which is where the header's own photo and name already are, and
/// it needs a background to be legible over whatever is scrolling behind it, so
/// it puts a slab across the top of the screen to say something most people are
/// not looking for. Behind a button it costs nothing until it is wanted.
///
/// The pins are drawn by ``MessageRow``, the same view the transcript uses, off
/// rows from the same ``Transcript`` builder. A pin is worth pinning because of
/// what it says, and a one-line summary is exactly the part of a message that
/// throws away the links, the mentions, the photo and the reply it was
/// answering. Reusing the row means the formatting cannot drift out of step
/// with the transcript either, since there is only one of it.
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
                LazyVStack(spacing: 10) {
                    ForEach(rows, id: \.id) { row in
                        switch row {
                        case .day(let date):
                            DaySeparator(date: date)
                        case .message(let item):
                            pin(item)
                        case .systemRun(let run):
                            SystemRunRow(run: run) { item in
                                MessageRow(item: item, catalog: model.reactionCatalog)
                            }
                        case .unreadMarker:
                            EmptyView()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
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

    /// The pins as transcript rows. Oldest first, like the transcript, so the
    /// day headings read forwards.
    ///
    /// No outbox and no unread mark: nothing here is in flight, and where the
    /// reader left off is a fact about the transcript rather than about a pin.
    private var rows: [TranscriptRow] {
        Transcript.rows(
            messages: messages.sorted { $0.date < $1.date },
            outbox: [],
            currentUser: model.currentUser,
            members: members)
    }

    private func pin(_ item: MessageDisplay) -> some View {
        MessageRow(
            item: item,
            catalog: model.reactionCatalog,
            previews: model.previews,
            onOpenReply: { _ in open(item.message) })
            .opacity(opening == nil || opening == item.id ? 1 : 0.5)
            .overlay(alignment: .topTrailing) {
                if opening == item.id {
                    ProgressView().controlSize(.small)
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
