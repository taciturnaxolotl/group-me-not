import SwiftUI

/// People waiting to be let into a group.
///
/// Only reachable by an admin or the owner, because only they can answer. Each
/// row carries the answer to the group's join question where there is one — the
/// whole reason a group asks one is to decide by it, and an approval screen that
/// hides it makes the question pointless.
struct JoinRequestsView: View {
    let conversation: ConversationRow

    @Environment(AppModel.self) private var model

    @State private var requests: [JoinRequest] = []
    @State private var isLoading = true
    @State private var answering: Set<String> = []
    @State private var failure: String?

    var body: some View {
        List {
            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            ForEach(requests) { request in
                row(request)
            }
        }
        .overlay {
            if isLoading {
                ProgressView()
            } else if requests.isEmpty {
                ContentUnavailableView {
                    Label("No Requests", systemImage: "person.badge.clock")
                } description: {
                    Text("Nobody is waiting to join right now.")
                }
            }
        }
        .navigationTitle("Join Requests")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func row(_ request: JoinRequest) -> some View {
        let id = request.approvalID ?? request.identityFallback
        let isBusy = answering.contains(id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Avatar(url: request.imageUrl, name: request.displayName, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.displayName)
                        .lineLimit(1)
                    if let asked = request.createdAt {
                        Text(Formatters.listTimestamp(Date(timeIntervalSince1970: TimeInterval(asked))))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if isBusy { ProgressView() }
            }

            if let response = request.response {
                Text(response)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("Approve") { answer(request, approve: true) }
                    .buttonStyle(.borderedProminent)
                Button("Decline", role: .destructive) { answer(request, approve: false) }
                    .buttonStyle(.bordered)
            }
            .disabled(isBusy)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    // MARK: Actions

    private func load() async {
        requests = await model.joinRequests(for: conversation.id)
        isLoading = false
    }

    private func answer(_ request: JoinRequest, approve: Bool) {
        let id = request.approvalID ?? request.identityFallback
        answering.insert(id)
        failure = nil
        Task {
            let ok = await model.respond(to: request, in: conversation.id, approve: approve)
            answering.remove(id)
            if ok {
                // Dropped locally rather than re-fetched: the list is short, the
                // answer is final, and a round trip to remove one row is a row
                // that sits there looking unanswered.
                requests.removeAll { ($0.approvalID ?? $0.identityFallback) == id }
            } else {
                failure = "Could not answer that. Try again in a moment."
            }
        }
    }
}

extension JoinRequest {
    /// A stable key for a request the server gave no id, so the row can still
    /// track its own in-flight state.
    var identityFallback: String { userId ?? displayName }
}
