import UIKit

/// Room to finish something after the screen goes off.
///
/// An app that is backgrounded — the home button, a lock, a phone call — has
/// seconds before the system suspends it, and a suspended app's URL session
/// stops mid-transfer. A photo halfway up stays halfway up until the app is
/// opened again, which is exactly when somebody puts their phone in a pocket
/// having just sent one.
///
/// The assertion asks for that time explicitly. It is not unlimited and it is
/// not promised: the system grants what it feels like, usually around half a
/// minute, and the expiry handler is where it takes it back. What it reliably
/// buys is the tail of a send that had nearly finished, which is most of them.
///
/// Not a substitute for a background `URLSession`. That is the thing that
/// survives suspension outright, and it would want the whole upload path
/// rebuilt around delegates and file handles — worth doing for a long video,
/// and worth not pretending this is.
@MainActor
enum BackgroundTime {
    private static var tokens: [String: UIBackgroundTaskIdentifier] = [:]

    /// Claim time under a name. Claiming again under a name already held is a
    /// no-op, so callers do not have to track whether they are the first.
    static func begin(_ name: String) {
        guard tokens[name] == nil else { return }
        let token = UIApplication.shared.beginBackgroundTask(withName: name) {
            // The system wants it back. Ending it here is what stops the app
            // being killed outright rather than merely suspended.
            end(name)
        }
        guard token != .invalid else { return }
        tokens[name] = token
    }

    static func end(_ name: String) {
        guard let token = tokens.removeValue(forKey: name) else { return }
        UIApplication.shared.endBackgroundTask(token)
    }
}
