import SwiftUI

/// Chooses between signing in and the app.
///
/// The switch is on stored credentials, not on a network result, so a relaunch
/// with a token in the keychain goes straight to the conversation list and
/// starts drawing from disk while the first sync is still being dialled.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SwiftUI.Group {
            if model.isSignedIn {
                ConversationListView()
            } else {
                SignInView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.isSignedIn)
    }
}
