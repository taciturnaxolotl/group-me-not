import Foundation
import UserNotifications
import os

/// Badge and local notifications.
///
/// ## What this can and cannot do
///
/// It cannot do remote push, and that is not a gap to be filled later. Remote
/// push would mean GroupMe's servers sending to *this* app's APNs topic, which
/// is signed by a certificate only its owner holds. Their `/push_registrations`
/// endpoint takes a `service` of `google_cloud_messaging` and a token from
/// their own Firebase project. There is no field in which a third-party client
/// can supply its own APNs topic, so no amount of work here reaches it.
///
/// So this covers the two things that are genuinely reachable:
///
/// - **The badge**, which is accurate whenever the app has run recently, and
///   simply goes stale rather than wrong while it has not.
/// - **Local notifications** for messages that arrive over the Faye socket while
///   the app is alive but not on screen, which is the tail end of a backgrounded
///   session rather than an always-on service.
actor Notifier {
    static let shared = Notifier()

    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "notify")
    private var authorised: Bool?

    /// Ask once, the first time there is something worth showing.
    ///
    /// Deliberately not called at launch: a permission sheet before the user has
    /// seen a single message is the prompt everyone declines.
    @discardableResult
    func requestAuthorisation() async -> Bool {
        if let authorised { return authorised }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            authorised = granted
            return granted
        } catch {
            log.notice("notification authorisation failed: \(error.localizedDescription, privacy: .public)")
            authorised = false
            return false
        }
    }

    /// Reflect the unread total on the icon.
    ///
    /// Setting the badge does not need the alert permission, and asking for one
    /// in order to draw the other would be a prompt the user did not earn. So
    /// this never prompts: if the badge is not permitted it quietly does nothing.
    func setBadge(_ count: Int) async {
        do {
            try await center.setBadgeCount(max(0, count))
        } catch {
            log.debug("could not set badge: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Show a message that arrived while the app was off screen.
    ///
    /// Threaded by conversation so several messages from one chat group together
    /// rather than stacking, which is what Messages does and what stops a busy
    /// group burying everything else.
    func post(title: String, body: String, conversationKey: String, unreadTotal: Int) async {
        guard await requestAuthorisation() else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = conversationKey
        content.badge = NSNumber(value: max(0, unreadTotal))
        content.userInfo = ["conversation": conversationKey]

        // nil trigger means deliver now.
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            log.notice("could not post notification: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Clear everything for one conversation when the user opens it, so reading
    /// on the phone does not leave a notification behind for the same messages.
    func clear(conversationKey: String) async {
        let delivered = await center.deliveredNotifications()
        let ids = delivered
            .filter { $0.request.content.threadIdentifier == conversationKey }
            .map(\.request.identifier)
        guard !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}
