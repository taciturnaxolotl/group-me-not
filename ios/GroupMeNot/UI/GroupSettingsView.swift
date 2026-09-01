import SwiftUI

/// What can be changed about a group, and by whom.
///
/// Split by permission rather than by topic. Everybody may change how they
/// appear here; only admins and the owner may change the group. The two are
/// separate sections so nobody has to work out which is which, and the second
/// simply does not exist for a member — a greyed-out field invites a tap and
/// then explains nothing, and the server would refuse it anyway.
struct GroupSettingsView: View {
    let conversation: ConversationRow
    let myNickname: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var nickname = ""
    @State private var name = ""
    @State private var summary = ""
    @State private var requiresApproval = false
    @State private var isSaving = false
    @State private var isPickingPhoto = false
    @State private var isUploadingPhoto = false
    @State private var failure: String?

    private var canEditGroup: Bool { model.role(in: conversation.id).canEditGroup }

    var body: some View {
        Form {
            nicknameSection
            if canEditGroup {
                photoSection
                detailsSection
                joiningSection
            }
            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(canEditGroup ? "Group Settings" : "Your Nickname")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) {
                    if isSaving { ProgressView() } else { Text("Save") }
                }
                .disabled(!hasChanges || isSaving)
            }
        }
        .attachmentPicker(isPresented: $isPickingPhoto) { picked in
            guard let first = picked.first else { return }
            uploadPhoto(first)
        }
        .onAppear(perform: reset)
    }

    // MARK: Sections

    private var nicknameSection: some View {
        Section {
            TextField("Your name in this group", text: $nickname)
                .textInputAutocapitalization(.words)
        } header: {
            Text("Your Nickname")
        }
    }

    private var photoSection: some View {
        Section {
            HStack {
                Spacer()
                Button { isPickingPhoto = true } label: {
                    ZStack {
                        Avatar(
                            url: conversation.avatarURL,
                            name: name.isEmpty ? conversation.name : name,
                            size: 88,
                            isGroup: true
                        )
                        if isUploadingPhoto {
                            ProgressView()
                                .frame(width: 88, height: 88)
                                .background(.black.opacity(0.35), in: .circle)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isUploadingPhoto)
                .accessibilityLabel("Change group photo")
                Spacer()
            }
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)
        }
    }

    private var detailsSection: some View {
        Section("Group") {
            LabeledContent("Name") {
                TextField("Group name", text: $name)
                    .multilineTextAlignment(.trailing)
            }
            TextField("Description", text: $summary, axis: .vertical)
                .lineLimit(2...5)
        }
    }

    private var joiningSection: some View {
        Section {
            Toggle("Require approval for new members", isOn: $requiresApproval)
        }
    }

    // MARK: Actions

    private var hasChanges: Bool {
        if trimmed(nickname) != myNickname { return true }
        guard canEditGroup else { return false }
        return trimmed(name) != conversation.name
            || trimmed(summary) != (conversation.summary ?? "")
            || requiresApproval != (conversation.requiresApproval ?? false)
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func reset() {
        nickname = myNickname
        name = conversation.name
        summary = conversation.summary ?? ""
        requiresApproval = conversation.requiresApproval ?? false
    }

    private func save() {
        isSaving = true
        failure = nil
        Task {
            var ok = true
            // Only what changed, and each on its own route. A nickname is a
            // membership and the rest is the group, so one Save is two calls
            // rather than one; batching them would mean sending fields to a
            // route that does not own them.
            if trimmed(nickname) != myNickname, !trimmed(nickname).isEmpty {
                ok = await model.setNickname(trimmed(nickname), in: conversation.id) && ok
            }
            if canEditGroup {
                let newName = trimmed(name) == conversation.name ? nil : trimmed(name)
                let newSummary = trimmed(summary) == (conversation.summary ?? "")
                    ? nil : trimmed(summary)
                let newApproval = requiresApproval == (conversation.requiresApproval ?? false)
                    ? nil : requiresApproval
                if newName != nil || newSummary != nil || newApproval != nil {
                    ok = await model.updateGroup(
                        conversation.id, name: newName, description: newSummary,
                        requiresApproval: newApproval) && ok
                }
            }
            isSaving = false
            if ok { dismiss() } else { failure = "Some of that did not save." }
        }
    }

    private func uploadPhoto(_ picked: PickedMedia) {
        isUploadingPhoto = true
        failure = nil
        Task {
            let ok = await model.updateGroupPhoto(picked, in: conversation.id)
            isUploadingPhoto = false
            if !ok { failure = "Could not set that photo." }
        }
    }
}
