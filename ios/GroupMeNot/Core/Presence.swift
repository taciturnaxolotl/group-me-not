import Foundation

/// Saying whether we are here.
///
/// Only that direction. Presence has two halves in GroupMe and a third-party
/// client can only have one of them:
///
/// - **Publishing works.** `PUT /v1/presence/status` with `{"status":"online"}`
///   answers 200 and echoes the status back. The official client sends it every
///   three minutes for as long as somebody is looking at the app, and `away`
///   when they stop.
/// - **Reading is refused.** `GET /v1/presence/users/{id}`, the batch form with
///   `?ids=`, and `GET /v1/presence/groups/{id}/members` all answer
///   `401 {"code": 40102, "errors": ["device_verification_failed"]}` — with and
///   without the `group_id` the official client sends, and whatever the User-Agent
///   claims to be. Measured 7 September 2026 against a live account, from both a
///   developer token and the app's own.
///
/// The gate is Google Play Integrity on Android and App Attest on iOS: the app
/// fetches a nonce from `/v1/nonce`, has the platform sign an attestation over
/// it, and sends the result as `x-verify-token` / `x-verify-token-standard` for
/// the client id `com.groupme.android` (`ProtectedRequestQueue`, `OkHttp3Stack`).
/// An attestation is a statement by Google or Apple that this is *their* app,
/// signed by *their* certificate. There is no version of this a different app
/// can produce, which is the entire point of it — so there is no cleverness to
/// find here, and no reading code to keep warm against the day it works.
///
/// What is left is worth keeping: with the preference on, other people's
/// official clients show you as here, which is the half of the feature that
/// costs them nothing to grant.
nonisolated enum PresenceStatus: Sendable, Hashable {
    case online
    case away
    case offline

    /// What to send. `clear` and `active` also arrive as "here" when reading,
    /// which is recorded for the next person to look at this and nothing else.
    var apiValue: String {
        switch self {
        case .online: "online"
        case .away: "away"
        case .offline: "offline"
        }
    }
}

/// `PUT /v1/presence/status`.
///
/// `manual` is sent only when the status was chosen rather than inferred: it is
/// what separates "I have set myself to offline" from "this client has stopped
/// saying anything". Omitted for the heartbeat, which is not a choice.
nonisolated struct PresenceUpdate: Encodable, Sendable {
    var status: String
    var manual: Bool?
}
