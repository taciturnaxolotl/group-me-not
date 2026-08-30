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

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "This build has no GroupMe client ID, so it cannot use OAuth. Paste a token instead."
            case .cancelled:
                nil  // The user closed the sheet; not worth a message.
            case .noToken:
                "GroupMe finished sign-in without returning a token."
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

    /// GroupMe returns `groupmenot://oauth?access_token=…`. Some OAuth servers
    /// use the fragment instead, so check both rather than assume.
    static func token(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if let value = components.queryItems?.first(where: { $0.name == "access_token" })?.value,
           !value.isEmpty {
            return value
        }
        guard let fragment = components.fragment else { return nil }
        var fragmentComponents = URLComponents()
        fragmentComponents.query = fragment
        return fragmentComponents.queryItems?
            .first(where: { $0.name == "access_token" })?.value
            .flatMap { $0.isEmpty ? nil : $0 }
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
