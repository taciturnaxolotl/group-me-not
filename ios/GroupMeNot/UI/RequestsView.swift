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

    var body: some View {
        NavigationStack {
            List {
                if let dms = requests.dmRequests, !dms.isEmpty {
                    Section("Message Requests") {
                        ForEach(dms, id: \.identity) { request in
                            HStack(spacing: 12) {
                                Avatar(
                                    url: request.otherUser?.avatarUrl,
                                    name: request.otherUser?.name ?? "?",
                                    size: 40
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(request.otherUser?.name ?? "Someone")
                                        .lineLimit(1)
                                    if let preview = request.lastMessage?.visibleText, !preview.isEmpty {
                                        Text(preview)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                            .accessibilityElement(children: .combine)
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
