import SwiftUI

/// Chooses between signing in and the app.
///
/// The switch is on stored credentials, not on a network result, so a relaunch
/// with a token in the keychain goes straight to the conversation list and
/// starts drawing from disk while the first sync is still being dialled.
///
/// Three states, not two. Reading the keychain is quick but it is not
/// instantaneous, and a two-state switch has to guess for those few frames; the
/// only available guess is "signed out", which flashes the sign-in screen at
/// somebody who signed in weeks ago. Drawing nothing until the answer arrives
/// costs a frame or two of plain background and is never wrong.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SwiftUI.Group {
            switch model.session {
            case .signedIn:
                ConversationListView()
            case .signedOut:
                SignInView()
            case .unknown:
                // Deliberately empty, and deliberately the same colour as the
                // launch screen: nothing should be visible happening here.
                Color(.systemBackground).ignoresSafeArea()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.isSignedIn)
    }
}
