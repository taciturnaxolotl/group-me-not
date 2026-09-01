import SwiftUI

@main
struct GroupMeNotApp: App {
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
