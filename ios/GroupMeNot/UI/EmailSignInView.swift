import SwiftUI

/// Email or phone, and a password.
///
/// Two fields and a button, until the account asks for a code, at which point
/// there is a third. The code step replaces the button rather than appearing
/// beside it: a form with two ways to submit is a form that has to be read.
struct EmailSignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var userName = ""
    @State private var password = ""
    @State private var code = ""
    @State private var challenge: PasswordLogin.Challenge?
    @State private var isWorking = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case userName, password, code }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email or phone", text: $userName)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .userName)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit(submit)
                }
                .disabled(challenge != nil)

                if let challenge {
                    Section {
                        TextField("Verification code", text: $code)
                            .textContentType(.oneTimeCode)
                            .keyboardType(.numberPad)
                            .focused($focus, equals: .code)
                    } footer: {
                        Text(challenge.advice)
                    }
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(challenge == nil ? "Sign In" : "Verify")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button(challenge == nil ? "Sign In" : "Verify", action: submit)
                            .disabled(!canSubmit)
                    }
                }
            }
            .onAppear { focus = .userName }
        }
    }

    private var canSubmit: Bool {
        guard !isWorking else { return false }
        if challenge != nil { return code.count >= 4 }
        return !userName.trimmed.isEmpty && !password.isEmpty
    }

    /// One action for both steps, because the server treats them as one login:
    /// the second post repeats the credentials and adds the code.
    private func submit() {
        guard canSubmit else { return }
        focus = nil
        isWorking = true
        error = nil
        Task {
            do {
                let outcome = try await PasswordLogin.signIn(
                    userName: userName.trimmed,
                    password: password,
                    code: challenge == nil ? nil : code)
                switch outcome {
                case .token(let token):
                    await model.signIn(token: token)
                    if model.isSignedIn { dismiss() } else { error = model.syncState.lastError }
                case .challenge(let next):
                    challenge = next
                    focus = .code
                }
            } catch {
                self.error = error.localizedDescription
                // A wrong code is worth another try; the credentials behind it
                // were already accepted, so the form stays on the code step.
                if challenge != nil { code = "" }
            }
            isWorking = false
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
