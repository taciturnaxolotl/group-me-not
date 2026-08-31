import AuthenticationServices
import Foundation
import UIKit
import os

/// Sign in through GroupMe's own OAuth page.
///
/// GroupMe offers two flows. The code flow needs a client secret, which a
/// shipped app cannot keep, so this uses the implicit flow: the authorize page
/// redirects straight back to our custom scheme with the token in the query.
///
/// The Android app does none of this. It posts a username and password to
/// `/access_tokens` with a hardcoded salt, which means it handles the password
/// itself. Handing that to GroupMe's own web page is both less code and less
/// responsibility.
nonisolated enum OAuth {
    /// Fill this in after registering the app. See `isConfigured` below.
    ///
    /// 1. Sign in at https://dev.groupme.com/applications and choose "Create Application".
    /// 2. Set the Callback URL to exactly `groupmenot://oauth`.
    /// 3. Copy the Client ID it gives you into `clientID`.
    ///
    /// No secret is needed, and none should ever be embedded here.
    static let clientID = ""

    static let callbackScheme = "groupmenot"
    private static let authorizeURL = "https://oauth.groupme.com/oauth/authorize"

    /// False until a client id is filled in. The sign-in screen uses this to
    /// hide the button rather than offer one that cannot work.
    static var isConfigured: Bool { !clientID.isEmpty }

    nonisolated enum Failure: LocalizedError {
        case notConfigured
        case cancelled
        case noToken
        case session(String)
        case stateMismatch

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "This build has no GroupMe client ID, so it cannot use OAuth. Paste a token instead."
            case .cancelled:
                nil  // The user closed the sheet; not worth a message.
            case .noToken:
                "GroupMe finished sign-in without returning a token."
            case .stateMismatch:
                "That sign-in response did not match this request."
            case .session(let detail):
                detail
            }
        }
    }

    /// Presents the GroupMe sign-in page and resolves to an access token.
    ///
    /// Not ephemeral on purpose: if the user is already signed in to GroupMe in
    /// Safari, this is a single tap rather than another password prompt.
    @MainActor
    static func signIn() async throws -> String {
        guard isConfigured else { throw Failure.notConfigured }

        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [URLQueryItem(name: "client_id", value: clientID)]
        let url = components.url!

        guard let anchor = PresentationAnchor.resolve() else {
            throw Failure.session("There is no window to present sign-in in.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callback, error in
                if let error {
                    let isCancel = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    continuation.resume(throwing: isCancel ? Failure.cancelled
                                                           : Failure.session(error.localizedDescription))
                    return
                }
                guard let callback, let token = token(from: callback) else {
                    continuation.resume(throwing: Failure.noToken)
                    return
                }
                continuation.resume(returning: token)
            }
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(throwing: Failure.session("Could not open the GroupMe sign-in page."))
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
    ///
    /// No client id and no app registration: the mechanism is GroupMe's, and we
    /// are asking their page to do what it already does.
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

        guard let anchor = PresentationAnchor.resolve() else {
            throw Failure.session("There is no window to present sign-in in.")
        }

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: components.url!,
                callbackURLScheme: handoffScheme
            ) { callback, error in
                if let error {
                    let isCancel = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    continuation.resume(throwing: isCancel ? Failure.cancelled
                                                           : Failure.session(error.localizedDescription))
                    return
                }
                guard let callback else {
                    continuation.resume(throwing: Failure.noToken)
                    return
                }
                continuation.resume(returning: callback)
            }
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(throwing: Failure.session("Could not open the GroupMe sign-in page."))
            }
        }

        // Reject a state that came back *different*, but tolerate one that did
        // not come back at all. The web client only echoes it when it captured
        // it on the way in, and a missing echo is not evidence of anything:
        // ASWebAuthenticationSession already guarantees this callback belongs to
        // the session we started. A wrong one is worth refusing; a silent one is
        // worth noting.
        if let returned = value(named: "state", in: callback) {
            guard returned == state else { throw Failure.stateMismatch }
        } else {
            Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "auth")
                .notice("sign-in callback carried no state; parameters were \(parameterNames(of: callback).joined(separator: ", "), privacy: .public)")
        }
        guard let token = token(from: callback) else { throw Failure.noToken }
        return token
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

    /// GroupMe returns `groupmenot://oauth?access_token=…`. Some OAuth servers
    /// use the fragment instead, so check both rather than assume.
    static func token(from url: URL) -> String? { value(named: "access_token", in: url) }
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
