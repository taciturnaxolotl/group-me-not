import SwiftUI

/// Pick people out of your contacts and add them to a group.
///
/// Searchable, multi-select, and honest about who is already in: people already
/// in the group are listed and disabled rather than hidden. Hiding them makes a
/// list that appears to be missing somebody, and "why is Sam not here" is a
/// worse question than "Sam is already in this".
struct InvitePeopleView: View {
    let conversation: ConversationRow
    /// The current roster, used only to grey out the people in it.
    let alreadyIn: [Member]

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var contacts: [Relationship] = []
    @State private var chosen: Set<String> = []
    @State private var query = ""
    @State private var isLoading = true
    @State private var isSending = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Invite People")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "Search contacts")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: invite) {
                            if isSending { ProgressView() } else { Text("Add") }
                        }
                        .disabled(chosen.isEmpty || isSending)
                    }
                }
                .task { await load() }
        }
    }

    @ViewBuilder private var content: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if contacts.isEmpty {
            ContentUnavailableView {
                Label("No Contacts", systemImage: "person.2")
            } description: {
                Text(failure ?? "GroupMe has nobody listed for this account.")
            }
        } else if visible.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List {
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                ForEach(visible) { person in
                    row(person)
                }
            }
            .listStyle(.plain)
        }
    }

    private func row(_ person: Relationship) -> some View {
        let id = person.id
        let isMember = memberIDs.contains(id)
        let isChosen = chosen.contains(id)
        return Button {
            if isChosen { chosen.remove(id) } else { chosen.insert(id) }
        } label: {
            HStack(spacing: 12) {
                Avatar(url: person.avatarUrl, name: person.name ?? "?", size: 36)
                Text(person.name ?? "Someone")
                    .lineLimit(1)
                    .foregroundStyle(isMember ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Spacer(minLength: 8)
                if isMember {
                    Text("In group")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if isChosen {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isMember)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Content

    private var memberIDs: Set<String> { Set(alreadyIn.map(\.identity)) }

    /// Alphabetical, with anybody already in the group at the end. The point of
    /// the screen is the people who are not in it yet.
    private var visible: [Relationship] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = term.isEmpty
            ? contacts
            : contacts.filter { ($0.name ?? "").localizedStandardContains(term) }
        return matching.sorted { a, b in
            let inA = memberIDs.contains(a.id), inB = memberIDs.contains(b.id)
            guard inA == inB else { return !inA }
            return (a.name ?? "").localizedCaseInsensitiveCompare(b.name ?? "") == .orderedAscending
        }
    }

    // MARK: Actions

    private func load() async {
        contacts = await model.contacts()
        if contacts.isEmpty { failure = "Could not load your contacts." }
        isLoading = false
    }

    private func invite() {
        guard case .group(let groupID) = conversation.id else { return }
        let people = contacts
            .filter { chosen.contains($0.id) }
            .compactMap { person -> GroupMeAPI.AddMemberRequest.Person? in
                guard let userID = person.userId else { return nil }
                return .init(userId: userID, nickname: person.name ?? "Someone")
            }
        guard !people.isEmpty else { return }

        isSending = true
        Task {
            let sent = await model.invite(people, to: groupID)
            isSending = false
            if sent {
                dismiss()
            } else {
                failure = "Could not add them. Try again in a moment."
            }
        }
    }
}
