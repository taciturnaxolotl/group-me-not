import SwiftUI

/// The way in.
///
/// One decision on the screen, not five. GroupMe's own web client will hand a
/// token back to a native app for any of four identity providers, so signing in
/// is a single tap for nearly everybody; the token route exists for the account
/// that has no provider at all, and the instructions for it run to three
/// numbered steps and a paragraph about Web Inspector. Those used to sit on the
/// first screen, under the buttons, where they were the largest thing on it and
/// answered a question almost nobody had. They live behind a sheet now, and the
/// screen asks what it actually wants to ask.
struct SignInView: View {
    @Environment(AppModel.self) private var model

    @State private var authorising: OAuth.Provider?
    @State private var isChoosingProvider = false
    @State private var isTokenSheetPresented = false
    @State private var oauthError: String?

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 24)
                banner
                Spacer(minLength: 24)
                actions
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .confirmationDialog("Sign In", isPresented: $isChoosingProvider, titleVisibility: .hidden) {
            ForEach(OAuth.Provider.allCases.filter { $0 != .apple }, id: \.self) { provider in
                Button(provider.title) { signIn(with: provider) }
            }
            Button("Use an access token") { isTokenSheetPresented = true }
        }
        .sheet(isPresented: $isTokenSheetPresented) { TokenSignInView() }
    }

    // MARK: Pieces

    private var banner: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("GroupMeNot")
                .font(.largeTitle.bold())
            Text("A faster GroupMe that works without a signal.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// One button that most people will press, one that opens the rest.
    ///
    /// Four equally weighted buttons is not a choice, it is a form: each one
    /// has to be read before any can be pressed. Apple is the one this app is
    /// most likely to be reached through, so it goes first and looks like the
    /// answer; everything else is one tap further away and costs the first
    /// screen nothing.
    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                signIn(with: .apple)
            } label: {
                HStack(spacing: 8) {
                    if authorising == .apple {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "apple.logo")
                        Text("Continue with Apple").fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isBusy)

            Button {
                isChoosingProvider = true
            } label: {
                Text("Other ways to sign in")
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isBusy)

            if let provider = authorising, provider != .apple {
                Label("Waiting for \(provider.rawValue.capitalized)…", systemImage: "hourglass")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let error = oauthError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            Text("Opens GroupMe's own sign-in page. Your password is never seen by this app.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    // MARK: Actions

    private var isBusy: Bool { authorising != nil }

    /// Hand off to GroupMe's own page. The token comes back through their
    /// desktop callback scheme; we never see a password.
    private func signIn(with provider: OAuth.Provider) {
        guard !isBusy else { return }
        authorising = provider
        oauthError = nil
        Task {
            do {
                let token = try await OAuth.signIn(with: provider)
                await model.signIn(token: token)
            } catch OAuth.Failure.cancelled {
                // They closed the sheet. Say nothing.
            } catch {
                oauthError = error.localizedDescription
            }
            authorising = nil
        }
    }
}

/// The token route, for an account no provider will vouch for.
///
/// Mostly instruction rather than authentication: a personal access token is
/// the same credential the official app carries, and dev.groupme.com hands one
/// to any signed-in account. The work is telling somebody where to go.
private struct TokenSignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var token = ""
    @State private var isRevealed = false
    @State private var isSigningIn = false
    @FocusState private var tokenFieldFocused: Bool

    private static let developerURL = URL(string: "https://dev.groupme.com/applications")!

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    tokenField
                } footer: {
                    Text("Stored in the keychain on this device. It is never sent anywhere except GroupMe.")
                }

                if let error = model.syncState.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }

                Section("Where to find it") {
                    instructions
                    Button("Open dev.groupme.com", systemImage: "safari") {
                        openURL(Self.developerURL)
                    }
                }
            }
            .navigationTitle("Access Token")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSigningIn {
                        ProgressView()
                    } else {
                        Button("Sign In", action: signIn).disabled(!canSubmit)
                    }
                }
            }
            .onAppear { tokenFieldFocused = true }
        }
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
            step(1, "Open dev.groupme.com and sign in with an email and password.")
            step(2, "Choose Access Token at the top right. A dialog shows a long string of letters and numbers.")
            step(3, "Copy it, come back here, and paste it above.")

            Divider().padding(.vertical, 2)

            // dev.groupme.com only accepts email or phone plus a password. An
            // account created through Sign in with Apple has no password, so
            // that route is closed to it and this one is the only way in.
            Label {
                Text("Signed up with Apple?")
                    .font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: "apple.logo")
            }

            Text("dev.groupme.com only takes an email and password, so it will not let you in. "
                 + "Open web.groupme.com in Safari instead, sign in with Apple, and read "
                 + "`localStorage.access_token` from the Web Inspector. It is the same token.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
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

    /// Tokens arrive with stray whitespace surprisingly often, because they are
    /// copied out of a dialog by hand. Trimming is not being clever; it is
    /// removing a failure the user cannot see.
    private var trimmedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool { !trimmedToken.isEmpty && !isSigningIn }

    private func signIn() {
        guard canSubmit else { return }
        tokenFieldFocused = false
        isSigningIn = true
        Task {
            await model.signIn(token: trimmedToken)
            isSigningIn = false
            // The sheet goes when the session does. Staying put on failure is
            // the point: the error is in the form the token was typed into.
            if model.isSignedIn { dismiss() }
        }
    }
}
