import SwiftUI

/// The way in.
///
/// One decision on the screen, not five. There are three ways in and they are
/// not equal in likelihood, so they are not equal on the page: a provider hand
/// off through GroupMe's own web client, an email and password straight to
/// their login endpoint, and the remaining providers one tap further down.
///
/// There used to be a pasted-token route beneath all this, with three numbered
/// steps and a paragraph about the Web Inspector. It was the largest thing on
/// the screen and it answered a question the other routes already answer.
struct SignInView: View {
    @Environment(AppModel.self) private var model

    @State private var authorising: OAuth.Provider?
    @State private var isChoosingProvider = false
    @State private var isEmailPresented = false
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
        .confirmationDialog("Sign In", isPresented: $isChoosingProvider, titleVisibility: .visible) {
            ForEach(OAuth.Provider.allCases, id: \.self) { provider in
                Button(provider.title) { signIn(with: provider) }
            }
            Button("Email & Password") { isEmailPresented = true }
        }
        .sheet(isPresented: $isEmailPresented) { EmailSignInView() }
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
            Text("The better, faster, nicer, all around best GroupMe client.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// One button, and the choice behind it.
    ///
    /// A page of equally weighted buttons is a form: each one has to be read
    /// before any can be pressed, and the biggest, Apple, gets pressed by
    /// people who wanted Google and then have to back out of Apple's sheet.
    /// So the page asks only whether you want in, and every way — the four
    /// providers and email and password — arrives in one list once you have
    /// said yes, none of them launching until it is chosen.
    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                isChoosingProvider = true
            } label: {
                HStack(spacing: 8) {
                    if isBusy {
                        ProgressView().tint(.white)
                    } else {
                        Text("Sign In").fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isBusy)

            if let provider = authorising {
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
