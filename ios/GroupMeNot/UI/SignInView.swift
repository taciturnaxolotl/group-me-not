import SwiftUI

/// Token entry.
///
/// GroupMe's password flow needs a registered OAuth client and a web redirect,
/// which is a lot of moving parts for a client one person runs. A personal
/// access token does the same job: it is the same credential the official app
/// carries, and dev.groupme.com hands one to any signed-in account.
///
/// So the design problem here is not authentication, it is instruction. Most of
/// this screen is telling the user where to go and what to copy.
struct SignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    @State private var token = ""
    @State private var isRevealed = false
    @State private var isSigningIn = false
    @State private var isAuthorising = false
    @State private var isShowingTokenEntry = false
    @State private var oauthError: String?
    @FocusState private var tokenFieldFocused: Bool

    private static let developerURL = URL(string: "https://dev.groupme.com/applications")!

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    header
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                if OAuth.isConfigured {
                    Section {
                        Button(action: signInWithGroupMe) {
                            HStack {
                                Spacer()
                                if isAuthorising {
                                    ProgressView()
                                } else {
                                    Label("Continue with GroupMe", systemImage: "person.crop.circle")
                                        .fontWeight(.semibold)
                                }
                                Spacer()
                            }
                        }
                        .disabled(isBusy)
                    } footer: {
                        Text("Opens GroupMe's own sign-in page. Your password is never seen by this app.")
                    }
                }

                Section {
                    if OAuth.isConfigured {
                        DisclosureGroup("Use a token instead", isExpanded: $isShowingTokenEntry) {
                            tokenField
                        }
                    } else {
                        tokenField
                    }
                } header: {
                    Text(OAuth.isConfigured ? "Advanced" : "Access Token")
                } footer: {
                    Text("Stored in the keychain on this device. It is never sent anywhere except GroupMe.")
                }

                if isTokenEntryVisible {
                    Section {
                        Button(action: signIn) {
                            HStack {
                                Spacer()
                                if isSigningIn {
                                    ProgressView()
                                } else {
                                    Text("Sign In").fontWeight(.semibold)
                                }
                                Spacer()
                            }
                        }
                        .disabled(!canSubmit)
                    }
                }

                if let error = oauthError ?? model.syncState.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }

                Section(OAuth.isConfigured ? "Where to find a token" : "Where to find it") {
                    instructions
                    Button("Open dev.groupme.com", systemImage: "safari") {
                        openURL(Self.developerURL)
                    }
                }
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 46))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("GroupMeNot")
                .font(.title2.weight(.semibold))
            Text("A faster GroupMe that works without a signal.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 20)
        .accessibilityElement(children: .combine)
    }

    /// A `SecureField` by default, with a reveal toggle.
    ///
    /// A token is forty characters of hex that nobody types, so every affordance
    /// here is aimed at pasting: no autocorrect, no capitalisation, no smart
    /// quotes, and a reveal button so a bad paste is visible rather than
    /// mysterious.
    @ViewBuilder private var tokenField: some View {
        HStack {
            SwiftUI.Group {
                if isRevealed {
                    TextField("Paste your token", text: $token)
                } else {
                    SecureField("Paste your token", text: $token)
                }
            }
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .submitLabel(.go)
            .focused($tokenFieldFocused)
            .onSubmit(signIn)
            .accessibilityLabel("Access token")

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(isRevealed ? "Hide token" : "Show token")
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            step(1, "Open dev.groupme.com and sign in with your usual GroupMe account.")
            step(2, "Choose Access Token at the top right. A dialog shows a long string of letters and numbers.")
            step(3, "Copy it, come back here, and paste it above.")
        }
        .padding(.vertical, 4)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: .circle)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(text)")
    }

    // MARK: Actions

    /// Tokens arrive with stray whitespace surprisingly often, because they are
    /// copied out of a dialog by hand. Trimming is not being clever; it is
    /// removing a failure the user cannot see.
    private var trimmedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool { !trimmedToken.isEmpty && !isBusy }
    private var isBusy: Bool { isSigningIn || isAuthorising }

    /// The token field is always reachable, but it is only the primary path when
    /// this build has no client id to run OAuth with.
    private var isTokenEntryVisible: Bool { !OAuth.isConfigured || isShowingTokenEntry }

    /// Hand off to GroupMe's own page. The token comes back through the custom
    /// scheme; we never see a password.
    private func signInWithGroupMe() {
        guard !isBusy else { return }
        tokenFieldFocused = false
        isAuthorising = true
        oauthError = nil
        Task {
            do {
                let token = try await OAuth.signIn()
                await model.signIn(token: token)
            } catch OAuth.Failure.cancelled {
                // They closed the sheet. Say nothing.
            } catch {
                oauthError = error.localizedDescription
            }
            isAuthorising = false
        }
    }

    private func signIn() {
        guard canSubmit else { return }
        tokenFieldFocused = false
        isSigningIn = true
        Task {
            await model.signIn(token: trimmedToken)
            isSigningIn = false
        }
    }
}
