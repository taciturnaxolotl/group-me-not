import SwiftUI

/// Starting something, whether it turns out to be a DM or a group.
///
/// One screen for both, because at the moment of starting a conversation
/// nobody has decided which it is yet: you have decided *who*. Pick one person
/// and it is a chat; pick three and it wants a name. Asking "group or direct?"
/// first, as the old sheet did, made you answer a question about database
/// shapes before you were allowed to think about people.
struct NewConversationView: View {
    /// Called with the conversation to open, already dismissed.
    let onOpen: (ConversationRow) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var path: [Step] = []
    @State private var contacts: [Relationship] = []
    @State private var chosen: [String] = []
    @State private var query = ""
    @State private var isLoading = true
    @State private var failure: String?

    /// The only place this can go, and only in one direction.
    private enum Step: Hashable { case name }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("New Conversation")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "Search contacts")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) { forwardButton }
                }
                .navigationDestination(for: Step.self) { _ in
                    NewGroupDetails(people: picked) { row in
                        dismiss()
                        onOpen(row)
                    }
                }
                .task { await load() }
        }
    }

    /// One button whose meaning follows the selection, rather than two that
    /// take turns being disabled. With one person picked there is nothing left
    /// to ask, so it opens the chat; with several, the group still needs a
    /// name.
    @ViewBuilder private var forwardButton: some View {
        switch chosen.count {
        case 0:
            Button("Chat") {}.disabled(true)
        case 1:
            Button("Chat") { openDirect() }
        default:
            Button("Next") { path.append(.name) }
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
            } actions: {
                Button("New Group") { path.append(.name) }
            }
        } else {
            List {
                if !chosen.isEmpty { chosenSection }
                Section {
                    if visible.isEmpty {
                        Text("Nobody by that name.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visible) { person in row(person) }
                    }
                } header: {
                    Text(chosen.isEmpty ? "Contacts" : "All Contacts")
                }
                // Last, and quiet. A group with nobody in it is a real thing to
                // want and a rare thing to want, so it waits at the bottom
                // rather than sitting on top of the people.
                Section {
                    Button("New Group With No One Yet") { path.append(.name) }
                        .font(.subheadline)
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    /// Who is coming, in the order they were picked, and removable from here.
    /// A selection you can only undo by finding the person again in a list of
    /// four hundred is not really a selection.
    private var chosenSection: some View {
        Section("Chatting With") {
            ForEach(picked) { person in
                Button {
                    chosen.removeAll { $0 == person.id }
                } label: {
                    HStack(spacing: 12) {
                        Avatar(url: person.avatarUrl, name: person.name ?? "?", size: 32)
                        Text(person.name ?? "Someone").lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(person.name ?? "Someone")")
            }
        }
    }

    private func row(_ person: Relationship) -> some View {
        let isChosen = chosen.contains(person.id)
        return Button {
            if isChosen {
                chosen.removeAll { $0 == person.id }
            } else {
                chosen.append(person.id)
            }
        } label: {
            HStack(spacing: 12) {
                Avatar(url: person.avatarUrl, name: person.name ?? "?", size: 36)
                Text(person.name ?? "Someone").lineLimit(1)
                Spacer(minLength: 8)
                if isChosen {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Content

    private var picked: [Relationship] {
        chosen.compactMap { id in contacts.first { $0.id == id } }
    }

    /// Alphabetical, and the whole list stays visible while people are picked:
    /// removing somebody from the list the moment they are chosen makes it jump
    /// under the finger that chose them.
    private var visible: [Relationship] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = term.isEmpty
            ? contacts
            : contacts.filter { ($0.name ?? "").localizedStandardContains(term) }
        return matching.sorted {
            ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending
        }
    }

    // MARK: Actions

    private func load() async {
        contacts = await model.contacts()
        if contacts.isEmpty { failure = "Could not load your contacts." }
        isLoading = false
    }

    /// A DM needs nothing created. GroupMe addresses one by the other person's
    /// id, so the conversation exists the moment you decide to have it, and the
    /// row is built here rather than waited for.
    private func openDirect() {
        guard let person = picked.first, let userID = person.userId else { return }
        let id = ConversationID.direct(otherUserID: userID)
        let row = model.conversations.first { $0.id == id }
            ?? ConversationRow(
                id: id,
                name: person.name ?? "Someone",
                avatarURL: person.avatarUrl,
                unreadCount: 0,
                memberCount: 2,
                isPlaceholder: false)
        dismiss()
        onOpen(row)
    }
}

// MARK: - Naming a group

/// The second half of making a group: what to call it, given who is in it.
///
/// Separate from the picking because it only applies to one of the two
/// outcomes, and putting a name field in front of somebody who wants to send
/// one person a message is how the old sheet went wrong.
private struct NewGroupDetails: View {
    let people: [Relationship]
    let onCreated: (ConversationRow) -> Void

    @Environment(AppModel.self) private var model

    @State private var name = ""
    @State private var summary = ""
    @State private var isSending = false
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                TextField("Group name", text: $name)
                    .textInputAutocapitalization(.words)
                TextField("Description", text: $summary, axis: .vertical)
                    .lineLimit(2...4)
            } footer: {
                Text(people.isEmpty
                     ? "You can add people once it exists."
                     : "\(people.count) \(people.count == 1 ? "person" : "people") will be added.")
            }

            if !people.isEmpty {
                Section("Members") {
                    ForEach(people) { person in
                        HStack(spacing: 12) {
                            Avatar(url: person.avatarUrl, name: person.name ?? "?", size: 30)
                            Text(person.name ?? "Someone").lineLimit(1)
                        }
                    }
                }
            }

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle("New Group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(action: create) {
                    if isSending { ProgressView() } else { Text("Create") }
                }
                .disabled(trimmedName.isEmpty || isSending)
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Create, then invite, then open. The invite is allowed to fail on its
    /// own: the group exists either way, and dropping the reader back into an
    /// empty screen because an add did not take would lose them the group they
    /// just made.
    private func create() {
        isSending = true
        failure = nil
        Task {
            guard let created = await model.createGroup(
                name: trimmedName,
                description: summary.isEmpty ? nil : summary)
            else {
                isSending = false
                failure = "Could not create that group."
                return
            }

            if case .group(let groupID) = created, !people.isEmpty {
                let members = people.compactMap { person -> GroupMeAPI.AddMemberRequest.Person? in
                    guard let userID = person.userId else { return nil }
                    return .init(userId: userID, nickname: person.name ?? "Someone")
                }
                await model.invite(members, to: groupID)
            }

            isSending = false
            guard let row = model.conversations.first(where: { $0.id == created }) else {
                failure = "Made it, but could not open it. It is in your list."
                return
            }
            onCreated(row)
        }
    }
}
