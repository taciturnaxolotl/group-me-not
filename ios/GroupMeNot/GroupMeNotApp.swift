import SwiftUI
import UIKit

/// The one thing SwiftUI has no modifier for.
///
/// A background upload that finishes while the app is not running gets the app
/// relaunched, and the system hands over a completion handler that must be
/// called once the answers have been dealt with. There is no `App` hook for
/// this — it is a `UIApplicationDelegate` method or nothing — so this is the
/// whole of why an adaptor exists.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // UIKit hands this over as a plain closure with no `Sendable` promise,
        // and it has to travel to an actor and back to be called. The promise it
        // does make is the one that matters: call it once, on the main thread,
        // when the answers have been dealt with. `nonisolated(unsafe)` is that
        // statement in the language's own words rather than a cast that hides
        // it — and the hop back to `@MainActor` is what makes it true.
        nonisolated(unsafe) let handler = completionHandler
        Task {
            await BackgroundUploads.shared.adoptLaunchEvents {
                Task { @MainActor in handler() }
            }
        }
    }
}

@main
struct GroupMeNotApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    /// One model for the process. It owns the store, the API, sync and realtime,
    /// and it opens the database on init so the first frame can render from disk
    /// without waiting for anything.
    @State private var model = AppModel()
    /// Preferences. Separate from the model on purpose: it owns no I/O, and a
    /// view that only wants to know how to draw should not have to reach
    /// through the object that owns the database to find out.
    @State private var settings = AppSettings()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(settings)
                .task { await model.bootstrap() }
                // The badge follows the unread total wherever it changes: a
                // sync, a push, or opening a conversation. Driven from here
                // rather than the model so the model keeps knowing nothing about
                // UIKit.
                .onChange(of: model.totalUnread, initial: true) { _, count in
                    Task { await Notifier.shared.setBadge(count) }
                }
                // The preference lives with the other preferences; acting on
                // it is the model's business. This is the one wire between them.
                .onChange(of: settings.sharesPresence, initial: true) { _, shares in
                    model.sharesPresence = shares
                }
                .onChange(of: scenePhase) { _, phase in
                    // Faye replays nothing it missed, so coming back from the
                    // background means running the whole catch-up loop again.
                    guard phase == .active else {
                        model.backgrounded()
                        return
                    }
                    Task { await model.foregrounded() }
                }
        }
    }
}
