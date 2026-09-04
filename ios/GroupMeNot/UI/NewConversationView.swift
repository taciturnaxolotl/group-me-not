import SwiftUI

/// Starting something, whether it turns out to be a DM or a group.
///
/// One screen for both, and the common one costs a single tap: touch a name
/// and their chat opens. Making a group is the deliberate act, so it says so
/// first — a row above the list leads to the group itself.
///
/// The other way round, which this was, made a DM the awkward case: you tapped
/// a person, got a checkmark, and then had to find a word in the corner of the
/// bar to say what the tap had already meant.
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

    /// A group is made in two steps, and only ever in this order: what it is,
    /// then who is in it.
    private enum Step: Hashable { case group, people }

    var body: some View {
        NavigationStack(path: $path) {
            contactList(gathering: false)
                .navigationTitle("New Conversation")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "Search contacts")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .group:
                        NewGroupDetails(
                            people: picked,
                            onAddPeople: { path.append(.people) },
                            onCreated: { row in
                                dismiss()
                                onOpen(row)
                            })
                    case .people:
                        contactList(gathering: true)
                            .navigationTitle("Add People")
                            .navigationBarTitleDisplayMode(.inline)
                            .searchable(text: $query, prompt: "Search contacts")
                    }
                }
                .task { await load() }
        }
    }

    // MARK: The list

    /// The same list twice: a tap opens somebody's chat, or adds them to the
    /// group being made. Which of the two it is, is the whole difference
    /// between the screens, so it is the only thing passed in.
    @ViewBuilder private func contactList(gathering: Bool) -> some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if contacts.isEmpty {
            ContentUnavailableView {
                Label("No Contacts", systemImage: "person.2")
            } description: {
                Text(failure ?? "GroupMe has nobody listed for this account.")
            } actions: {
                if !gathering {
                    Button("New Group") { path.append(.group) }
                }
            }
        } else {
            List {
                // Its own section. A group is not one of the people underneath
                // it, and a hairline between two rows says they are the same
                // kind of thing.
                if !gathering {
                    Section { newGroupRow }
                }
                Section {
                    if visible.isEmpty {
                        Text("Nobody by that name.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visible) { person in row(person, gathering: gathering) }
                    }
                } header: {
                    Text("Contacts")
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    /// The one row that is not a person, above the people because it leads
    /// somewhere else entirely.
    private var newGroupRow: some View {
        Button { path.append(.group) } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor, in: .circle)
                Text("New Group")
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func row(_ person: Relationship, gathering: Bool) -> some View {
        let isChosen = chosen.contains(person.id)
        return Button {
            guard gathering else {
                openDirect(person)
                return
            }
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
                if gathering {
                    Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isChosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
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
    private func openDirect(_ person: Relationship) {
        guard let userID = person.userId else { return }
        let id = ConversationID.direct(otherUserID: userID)
        let row = model.conversations.first { $0.id == id }
            ?? .direct(with: userID, name: person.name ?? "Someone", avatarURL: person.avatarUrl)
        dismiss()
        onOpen(row)
    }
}

// MARK: - The group itself

/// What the group is, before who is in it.
///
/// That order is deliberate. A group is a thing with a name and a face, and
/// people are added to it; asking for the members first makes the name read as
/// paperwork standing between you and the group you have already assembled.
/// Adding people is then a step you can simply not take, which is honest: an
/// empty group is a real thing to want, and it is one invitation from being
/// full.
private struct NewGroupDetails: View {
    let people: [Relationship]
    var onAddPeople: () -> Void
    let onCreated: (ConversationRow) -> Void

    @Environment(AppModel.self) private var model

    @State private var name = ""
    @State private var summary = ""
    @State private var photo: PickedMedia?
    @State private var isPickingPhoto = false
    @State private var isSending = false
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                photoRow.listRowBackground(Color.clear)
            }
            Section {
                TextField("Group name", text: $name)
                    .textInputAutocapitalization(.words)
                TextField("Description", text: $summary, axis: .vertical)
                    .lineLimit(2...4)
            }
            Section {
                addPeopleRow
                ForEach(people) { person in
                    HStack(spacing: 12) {
                        Avatar(url: person.avatarUrl, name: person.name ?? "?", size: 30)
                        Text(person.name ?? "Someone").lineLimit(1)
                    }
                }
            } footer: {
                Text("You can add people later too.")
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
        .attachmentPicker(isPresented: $isPickingPhoto) { picked in
            photo = picked.first
        }
    }

    /// The face, centred and on its own, the way a group's photo is shown
    /// everywhere else it appears.
    private var photoRow: some View {
        Button { isPickingPhoto = true } label: {
            VStack(spacing: 8) {
                if let photo {
                    RemoteImage(url: photo.previewURL ?? photo.fileURL, maxPixelSize: 252) {
                        Circle().fill(.quaternary)
                    }
                    .frame(width: 84, height: 84)
                    .clipShape(.circle)
                } else {
                    Circle()
                        .fill(.quaternary)
                        .frame(width: 84, height: 84)
                        .overlay {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 23))
                                .foregroundStyle(.secondary)
                        }
                }
                Text(photo == nil ? "Add Photo" : "Change Photo")
                    .font(.footnote)
                    .foregroundStyle(.tint)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Group photo")
    }

    private var addPeopleRow: some View {
        Button(action: onAddPeople) {
            HStack {
                Label("Add People", systemImage: "person.badge.plus")
                Spacer(minLength: 8)
                if !people.isEmpty {
                    Text("\(people.count)").foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Create, then dress it, then fill it, then open.
    ///
    /// The photo and the invitations are each allowed to fail on their own. The
    /// group exists either way, and dropping somebody back onto a form because
    /// an upload failed would lose them the group they just made; a face and a
    /// member list are both one tap away from inside it.
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

            if let photo {
                await model.updateGroupPhoto(photo, in: created)
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
