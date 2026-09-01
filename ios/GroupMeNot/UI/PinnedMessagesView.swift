import SwiftUI

/// What a conversation has pinned.
///
/// A sheet rather than a banner. A banner sits between the header and the
/// transcript, which is where the header's own photo and name already are, and
/// it needs a background to be legible over whatever is scrolling behind it —
/// so it puts a slab across the top of the screen to say something most people
/// are not looking for. Behind a button it costs nothing until it is wanted.
struct PinnedMessagesView: View {
    let messages: [Message]
    let members: [Member]
    /// Jump to it in the transcript. Returns whether it could be found: a pin
    /// can sit further back than we are willing to page.
    let onOpen: (String) async -> Bool
    let onUnpin: (Message) -> Void

    @Environment(\.dismiss) private var dismiss
    /// The pin currently being dug out of the history.
    @State private var opening: String?
    @State private var tooFarBack = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(messages, id: \.id) { message in
                    Button {
                        open(message)
                    } label: {
                        row(message)
                    }
                    .buttonStyle(.plain)
                    .disabled(opening != nil)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            onUnpin(message)
                        } label: {
                            Label("Unpin", systemImage: "pin.slash.fill")
                        }
                    }
                }
            }
            .listStyle(.plain)
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

    /// Digging can take a moment and can come up empty, so the row says which
    /// pin it is working on rather than leaving the tap looking unheard.
    private func open(_ message: Message) {
        opening = message.id
        Task {
            let found = await onOpen(message.id)
            opening = nil
            if found { dismiss() } else { tooFarBack = true }
        }
    }

    private var title: String {
        messages.count == 1 ? "1 Pinned" : "\(messages.count) Pinned"
    }

    private func row(_ message: Message) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(url: message.avatarUrl, name: name(of: message), size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name(of: message))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Formatters.listTimestamp(message.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(Transcript.summarise(message))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if opening == message.id {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    /// The name the message carried, falling back to the roster for one that
    /// arrived without it.
    private func name(of message: Message) -> String {
        if let name = message.name, !name.isEmpty { return name }
        guard let sender = message.senderId ?? message.userId,
              let member = members.first(where: { $0.identity == sender })
        else { return "Someone" }
        return member.nickname ?? member.name ?? "Someone"
    }
}
