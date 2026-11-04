import AuthenticationServices
import Foundation
import UIKit
import os

/// Sign in through GroupMe's own web client.
///
/// Not OAuth proper, whatever the name says. GroupMe's code flow needs a client
/// secret a shipped app cannot keep, and their implicit flow needs an app
/// registration an Apple-registered account cannot obtain. What works is the
/// hand-off their desktop app uses: the web client runs the normal sign-in and
/// then redirects to `groupme://oauth/callback#access_token=…`, and an
/// `ASWebAuthenticationSession` on that scheme catches it. No client id, no
/// secret, no password seen by this app.
nonisolated enum OAuth {
    nonisolated enum Failure: LocalizedError {
        case cancelled
        case noToken
        /// The session ended on a `groupme://` link that was not the sign-in
        /// callback. See `signIn(with:)`.
        case divertedToApp
        case noWindow
        case session(String)
        case stateMismatch

        var errorDescription: String? {
            switch self {
            case .cancelled:
                nil  // The user closed the sheet; not worth a message.
            case .noToken:
                "GroupMe finished sign-in without returning a token."
            case .divertedToApp:
                "That was GroupMe's own \"Open app\" link, which cannot finish signing in here. Use Continue instead."
            case .noWindow:
                "There is no window to present sign-in in."
            case .stateMismatch:
                "That sign-in response did not match this request."
            case .session(let detail):
                detail
            }
        }
    }

    // MARK: - Desktop handoff

    /// The providers GroupMe's own web client will hand off to.
    nonisolated enum Provider: String, CaseIterable, Sendable {
        case apple, google, microsoft, facebook

        var title: String {
            switch self {
            case .apple: "Continue with Apple"
            case .google: "Continue with Google"
            case .microsoft: "Continue with Microsoft"
            case .facebook: "Continue with Facebook"
            }
        }

        var symbol: String {
            switch self {
            case .apple: "apple.logo"
            case .google, .facebook, .microsoft: "globe"
            }
        }
    }

    /// Sign in through a provider, using the handoff GroupMe's web client already
    /// implements for their desktop app.
    ///
    /// `web.groupme.com/signin?desktop_auth=1&provider=…&state=…` runs the normal
    /// web sign-in and then redirects to
    /// `groupme://oauth/callback#access_token=…&state=…`.
    ///
    /// This matters because it is the only route an Apple-registered account has.
    /// The Android app offers Google and Microsoft only, and dev.groupme.com
    /// takes an email and password, so neither can authenticate one. This can.
    @MainActor
    static func signIn(with provider: Provider) async throws -> String {
        // Echoed back untouched, so it is worth checking. A response carrying
        // somebody else's state is a response to somebody else's request.
        let state = UUID().uuidString

        var components = URLComponents(string: "https://web.groupme.com/signin")!
        components.queryItems = [
            URLQueryItem(name: "desktop_auth", value: "1"),
            URLQueryItem(name: "provider", value: provider.rawValue),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "intent", value: "signin"),
        ]

        guard let anchor = PresentationAnchor.resolve() else { throw Failure.noWindow }
        let callback = try await present(components.url!, from: anchor)

        // A callback with the wrong state is somebody else's; one with no
        // state is one the page never armed, and the armed page is the only
        // one that ends in a token worth having. Either way, refused.
        guard value(named: "state", in: callback) == state else {
            Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "auth")
                .notice("sign-in callback state mismatch; parameters were \(parameterNames(of: callback).joined(separator: ", "), privacy: .public)")
            throw Failure.stateMismatch
        }
        // Every `groupme://` link on that page ends the session, not just the
        // one we are waiting for, because the callback scheme is what
        // `ASWebAuthenticationSession` matches on and GroupMe's scheme is the
        // only scheme their handoff has. Their mobile web pages carry an "Open
        // app" button that goes to `groupme://` to launch the real client, so
        // pressing it hands us a callback with no token in it and the sign-in
        // dies for no visible reason. Their "Continue" button runs the sign-in
        // proper, which ends at `groupme://oauth/callback#access_token=…`.
        //
        // Nothing here can stop the diversion, so the least it can do is say
        // which button to press.
        guard let token = token(from: callback) else {
            throw isOAuthCallback(callback) ? Failure.noToken : Failure.divertedToApp
        }
        return token
    }

    /// The sheet on screen, if any, so a second tap can take it down.
    @MainActor private static var current: ASWebAuthenticationSession?

    /// Give up on the sign-in in progress. The session's completion handler
    /// reports the cancel, which is what resumes whoever was waiting.
    @MainActor
    static func cancel() {
        current?.cancel()
    }

    /// Run the page in a system sheet and return the `groupme://` URL it ended
    /// on.
    ///
    /// Always a private session. The shared one would let a second sign-in be
    /// one tap, by reusing Safari's cookies, but those cookies belong to
    /// whoever signed in last and nothing in this app can clear them; after a
    /// sign-out every shared sheet walked straight back into the account that
    /// had just left. A sheet that remembers nothing asks who you are, every
    /// time, which is the only answer that is always right.
    @MainActor
    private static func present(_ url: URL, from anchor: PresentationAnchor) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            // The framework reports a session that cannot start through its
            // completion handler as well as through `start()`, so either
            // arrival may be the second one. One of them resumes; the other
            // is dropped.
            let once = ResumeOnce(continuation)
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: handoffScheme) { callback, error in
                current = nil
                if let error {
                    once.resume(throwing: failure(from: error))
                } else if let callback {
                    once.resume(returning: callback)
                } else {
                    once.resume(throwing: Failure.noToken)
                }
            }
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = true
            current = session
            if !session.start() {
                current = nil
                once.resume(throwing: Failure.session("Could not open the GroupMe sign-in page."))
            }
        }
    }

    private static func failure(from error: Error) -> Failure {
        switch (error as? ASWebAuthenticationSessionError)?.code {
        case .canceledLogin: .cancelled
        case .presentationContextNotProvided, .presentationContextInvalid: .noWindow
        default: .session(error.localizedDescription)
        }
    }

    /// A continuation that resumes at most once. The checked kind traps on a
    /// second resume, and the two places that might do it cannot see each
    /// other.
    private final class ResumeOnce: @unchecked Sendable {
        private var continuation: CheckedContinuation<URL, Error>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<URL, Error>) {
            self.continuation = continuation
        }

        func resume(returning value: URL) {
            take()?.resume(returning: value)
        }

        func resume(throwing error: Error) {
            take()?.resume(throwing: error)
        }

        private func take() -> CheckedContinuation<URL, Error>? {
            lock.lock()
            defer { lock.unlock() }
            let taken = continuation
            continuation = nil
            return taken
        }
    }

    /// The parameter names a callback carried, for diagnosing a flow that came
    /// back in an unexpected shape. Names only: one of the values is the token.
    static func parameterNames(of url: URL) -> [String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
        var parsed = URLComponents()
        parsed.percentEncodedQuery = components.percentEncodedFragment
        let names = (components.queryItems ?? []) + (parsed.queryItems ?? [])
        return names.map(\.name).sorted()
    }

    /// GroupMe's desktop scheme. We only ever intercept it inside an
    /// `ASWebAuthenticationSession`, which resolves the redirect itself rather
    /// than handing it to the system, so this does not need registering and does
    /// not fight the official app for the scheme.
    private static let handoffScheme = "groupme"

    /// Reads a parameter from either the query or the fragment.
    static func value(named name: String, in url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if let found = components.queryItems?.first(where: { $0.name == name })?.value, !found.isEmpty {
            return found
        }
        // The fragment is query syntax, so it has to be handed over still
        // encoded. Reading `.fragment` decodes it, and feeding a decoded string
        // back in as a query re-parses any `%26` or `%3D` inside a value as
        // structure, which quietly corrupts tokens.
        guard let fragment = components.percentEncodedFragment else { return nil }
        var parsed = URLComponents()
        parsed.percentEncodedQuery = fragment
        return parsed.queryItems?.first(where: { $0.name == name })?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The handoff puts the token in the fragment. The query is checked too,
    /// since reading both costs nothing and the page is not ours.
    static func token(from url: URL) -> String? { value(named: "access_token", in: url) }

    /// Whether a callback is the one the handoff promises, rather than some
    /// other `groupme://` link the page happened to offer.
    private static func isOAuthCallback(_ url: URL) -> Bool {
        (url.host ?? "").lowercased() == "oauth"
    }
}

/// `ASWebAuthenticationSession` needs a window to hang the sheet on. SwiftUI has
/// no direct handle, so find the active foreground scene's key window.
@MainActor
private final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let window: ASPresentationAnchor

    /// Resolves the window up front, so "there is nowhere to present this" is a
    /// thrown error rather than a crash.
    ///
    /// `presentationAnchor(for:)` has to return a non-optional window, and as of
    /// iOS 26 there is no scene-less `UIWindow` initialiser left to invent one
    /// with. Rather than trap in the callback, find the window while we can
    /// still fail gracefully and refuse to start the session without one.
    static func resolve() -> PresentationAnchor? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let window = scene?.keyWindow ?? scene?.windows.first else { return nil }
        return PresentationAnchor(window: window)
    }

    private init(window: ASPresentationAnchor) {
        self.window = window
        super.init()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window
    }
}
