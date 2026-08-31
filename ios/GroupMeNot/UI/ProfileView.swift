import CoreImage.CIFilterBuiltins
import SwiftUI

/// Your own account: what other people see, and what GroupMe knows.
///
/// Split along that line deliberately. The top is editable because it is yours
/// to change; the bottom is read-only because changing an email or a phone
/// number is a verification flow, and a field that looks editable and is not is
/// worse than a field that plainly is not.
struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var bio = ""
    @State private var isSaving = false
    @State private var isPickingPhoto = false
    @State private var isUploadingPhoto = false
    @State private var failure: String?

    private var user: CurrentUser? { model.currentUser }

    var body: some View {
        Form {
            photoAndName
            if let user { about(user) }
            if let url = user?.shareUrl.flatMap(URL.init(string:)) { share(url) }
            preferences
            if let user { account(user) }
            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Profile")
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
            upload(first)
        }
        .task {
            await model.refreshProfile()
            reset()
        }
    }

    // MARK: Sections

    private var photoAndName: some View {
        Section {
            HStack {
                Spacer()
                Button { isPickingPhoto = true } label: {
                    ZStack(alignment: .bottomTrailing) {
                        Avatar(url: user?.imageUrl, name: name.isEmpty ? "?" : name, size: 96)
                        if isUploadingPhoto {
                            ProgressView()
                                .frame(width: 96, height: 96)
                                .background(.black.opacity(0.35), in: .circle)
                        } else {
                            Image(systemName: "camera.fill")
                                .font(.caption)
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.accentColor, in: .circle)
                                .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isUploadingPhoto)
                .accessibilityLabel("Change profile photo")
                Spacer()
            }
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)

            LabeledContent("Name") {
                TextField("Your name", text: $name)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
            }
        }
    }

    private func about(_ user: CurrentUser) -> some View {
        Section {
            TextField("Say something about yourself", text: $bio, axis: .vertical)
                .lineLimit(2...5)
        } header: {
            Text("Bio")
        }
    }

    private func share(_ url: URL) -> some View {
        Section("Your Profile Link") {
            if let code = Self.qrCode(for: url) {
                Image(uiImage: code)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 160, height: 160)
                    .padding(12)
                    .background(.white, in: .rect(cornerRadius: 14, style: .continuous))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .listRowSeparator(.hidden)
                    .accessibilityLabel("Profile code")
            }
            ShareLink(item: url) {
                Label("Share Link", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var preferences: some View {
        Section {
            Toggle("Suggest Me to Others", isOn: Binding(
                get: { user?.friendSuggestable ?? false },
                set: { wanted in
                    Task {
                        let changed = await model.setFriendSuggestable(wanted)
                        if !changed { failure = "Could not change that." }
                    }
                }
            ))
        } footer: {
            Text("Lets GroupMe offer your account to people who may know you.")
        }
    }

    /// Facts rather than fields. Everything here is changed through a flow this
    /// app does not implement — a verification code, a password, a second
    /// factor — so it is shown and not offered.
    private func account(_ user: CurrentUser) -> some View {
        Section("Account") {
            if let email = user.email, !email.isEmpty {
                LabeledContent("Email") {
                    HStack(spacing: 4) {
                        Text(email)
                        if user.emailVerified == true {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.tint)
                                .accessibilityLabel("Verified")
                        }
                    }
                }
            }
            if let phone = user.phoneNumber, !phone.isEmpty {
                LabeledContent("Phone", value: phone)
            }
            if let joined = user.joined {
                LabeledContent("Joined", value: joined.formatted(date: .abbreviated, time: .omitted))
            }
            if let mfa = user.mfa, mfa.enabled == true {
                LabeledContent("Two-Factor") {
                    Text(mfa.activeChannels.isEmpty ? "On" : mfa.activeChannels.joined(separator: ", "))
                }
            }
            if !connected(user).isEmpty {
                LabeledContent("Connected", value: connected(user).joined(separator: ", "))
            }
        }
    }

    private func connected(_ user: CurrentUser) -> [String] {
        var out: [String] = []
        if user.microsoftConnected == true { out.append("Microsoft") }
        if user.facebookConnected == true { out.append("Facebook") }
        if user.twitterConnected == true { out.append("X") }
        return out
    }

    // MARK: Actions

    private var hasChanges: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines) != (user?.name ?? "")
            || bio.trimmingCharacters(in: .whitespacesAndNewlines) != (user?.bio ?? "")
    }

    private func reset() {
        name = user?.name ?? ""
        bio = user?.bio ?? ""
    }

    private func save() {
        let newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else {
            failure = "A name cannot be empty."
            return
        }
        isSaving = true
        failure = nil
        Task {
            // Only what changed. Sending a field back unchanged is a chance for
            // the server to normalise it into something the user did not ask for.
            let sent = await model.updateProfile(
                name: newName == (user?.name ?? "") ? nil : newName,
                bio: bio.trimmingCharacters(in: .whitespacesAndNewlines) == (user?.bio ?? "")
                    ? nil
                    : bio.trimmingCharacters(in: .whitespacesAndNewlines))
            isSaving = false
            if sent { reset() } else { failure = "Could not save. Try again in a moment." }
        }
    }

    private func upload(_ picked: PickedMedia) {
        isUploadingPhoto = true
        failure = nil
        Task {
            let ok = await model.updateAvatar(picked)
            isUploadingPhoto = false
            if !ok { failure = "Could not set that photo." }
        }
    }

    /// Generated rather than fetched, for the same reason a group's code is:
    /// the moment you show somebody a code is the moment you are next to them,
    /// and the two of you may have no signal.
    private static func qrCode(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
