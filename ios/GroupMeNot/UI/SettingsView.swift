import SwiftUI

/// Everything the user gets to decide.
///
/// One screen, three sections, and room for more. Appearance holds the choices
/// that change how the transcript draws, Account holds who you are and how to
/// stop being them, and About holds the build. Nothing here does work of its
/// own: it reads `AppSettings` and calls `AppModel`.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var isSignOutPresented = false
    @State private var isClearCachePresented = false
    @State private var isClearing = false

    var body: some View {
        NavigationStack {
            Form {
                appearance
                account
                storage
                about
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Sign out of GroupMe?",
                isPresented: $isSignOutPresented,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    Task {
                        await model.signOut()
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Messages already on this phone are removed with your account.")
            }
            .confirmationDialog(
                "Clear cached messages?",
                isPresented: $isClearCachePresented,
                titleVisibility: .visible
            ) {
                Button("Clear Cache", role: .destructive) {
                    isClearing = true
                    Task {
                        await model.clearCache()
                        isClearing = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("History is downloaded again the next time you are online. "
                     + "Anything you have written but not yet sent is kept.")
            }
        }
    }

    // MARK: Sections

    private var appearance: some View {
        Section {
            // `@Bindable` on the environment object rather than a local copy,
            // so the picker writes through to the one every view is reading.
            @Bindable var settings = settings
            Picker("Message Alignment", selection: $settings.ownMessageAlignment) {
                ForEach(OwnMessageAlignment.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("Appearance")
        } footer: {
            Text(settings.ownMessageAlignment.detail)
        }
    }

    private var account: some View {
        Section("Account") {
            if let user = model.currentUser {
                HStack(spacing: 12) {
                    Avatar(url: user.imageUrl, name: user.name ?? "?", size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.name ?? "Signed in")
                            .font(.body)
                        if let detail = user.email ?? user.phoneNumber {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            } else {
                Text("Not signed in")
                    .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                isSignOutPresented = true
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    /// The escape hatch for a local copy that has gone wrong.
    ///
    /// Named for what it does rather than for what it fixes, because the honest
    /// answer to "when should I press this" is "when something looks stale and
    /// you would otherwise reinstall". The footer says what survives, which is
    /// the only part a person needs to be sure of before tapping a red button.
    private var storage: some View {
        Section {
            Button(role: .destructive) {
                isClearCachePresented = true
            } label: {
                HStack {
                    Label("Clear Cache", systemImage: "trash")
                    if isClearing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isClearing)
        } header: {
            Text("Storage")
        } footer: {
            Text("Removes downloaded messages and previews from this phone. "
                 + "Your account, and any message still waiting to send, are untouched.")
        }
    }

    private var about: some View {
        Section("About") {
            LabeledContent("Version", value: Self.version)
        }
    }

    /// Marketing version and build, straight off the bundle, so a bug report
    /// can name exactly what it was running.
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        guard let build, build != short else { return short }
        return "\(short) (\(build))"
    }
}
