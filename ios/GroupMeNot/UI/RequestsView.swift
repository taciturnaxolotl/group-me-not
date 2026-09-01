import SwiftUI

/// Messages and invitations held back until you decide.
///
/// Two lists behind one count: people who messaged you without being a contact,
/// and groups that invited you. Both were empty when this was written, so the
/// rows are drawn from what the models say and nothing more elaborate is
/// attempted — a screen that renders a name and a decision is right whatever the
/// items turn out to carry.
struct RequestsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var requests: PendingRequests { model.pendingRequests }

    @State private var busy: Set<String> = []
    @State private var failure: String?

    /// Accepting lets the conversation through; declining deletes it, because
    /// that is what the route does and there is no third state to leave it in.
    private func answer(_ accept: Bool, _ request: PendingRequests.DirectRequest) {
        guard let userID = request.otherUser?.id else { return }
        busy.insert(request.identity)
        failure = nil
        Task {
            let ok = await model.respondToRequest(accept, from: userID)
            busy.remove(request.identity)
            if !ok { failure = "Could not answer that. Try again in a moment." }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                if let dms = requests.dmRequests, !dms.isEmpty {
                    Section("Message Requests") {
                        ForEach(dms, id: \.identity) { request in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 12) {
                                    Avatar(
                                        url: request.otherUser?.avatarUrl,
                                        name: request.otherUser?.name ?? "?",
                                        size: 40
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(request.otherUser?.name ?? "Someone")
                                            .lineLimit(1)
                                        if let preview = request.lastMessage?.visibleText,
                                           !preview.isEmpty {
                                            Text(preview)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    if busy.contains(request.identity) { ProgressView() }
                                }

                                HStack(spacing: 10) {
                                    Button("Accept") { answer(true, request) }
                                        .buttonStyle(.borderedProminent)
                                    Button("Delete", role: .destructive) { answer(false, request) }
                                        .buttonStyle(.bordered)
                                }
                                .controlSize(.small)
                                .disabled(busy.contains(request.identity))
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if let invites = requests.groupRequestsReceived, !invites.isEmpty {
                    Section("Group Invitations") {
                        ForEach(invites) { invite in
                            HStack(spacing: 12) {
                                Avatar(url: invite.imageUrl, name: invite.displayName, size: 40)
                                Text(invite.displayName).lineLimit(1)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .overlay {
                if requests.waiting == 0 {
                    ContentUnavailableView {
                        Label("Nothing Waiting", systemImage: "tray")
                    } description: {
                        Text("Message requests and group invitations appear here.")
                    }
                }
            }
            .navigationTitle("Requests")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.refreshRequests() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.refreshRequests() }
        }
    }
}
