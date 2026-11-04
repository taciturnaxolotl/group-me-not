import CryptoKit
import Foundation
import os

/// Signing in with an email or phone number and a password.
///
/// The one route that needs no provider and no web page. It is the Android
/// client's own login: a form post to the legacy host, authenticated not by a
/// token but by a hash the client computes about itself.
///
/// ```
/// POST https://v2.groupme.com/access_tokens
/// X-Access-Token: sha256(salt + platformId + deviceId + userName)
/// ```
///
/// The salt is a constant compiled into `AccountUtils.getHashedLoginToken`, so
/// it is a client-identity check rather than a secret: anything that can compute
/// the hash may present it. See `docs/auth.md`.
nonisolated enum PasswordLogin {
    /// From `AccountUtils.getHashedLoginToken`.
    private static let salt = "48ea3317-4a12-4a30-9b87-efdf2dc1b9ec"
    /// The version code the hash and the form fields are keyed to. Changing it
    /// changes the identity the server is shown, so it is one constant used in
    /// three places rather than three constants.
    private static let versionCode = "262370304"
    private static let platformID = "Android-\(versionCode)"
    private static let deviceKey = "auth.deviceID"

    private static let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "auth")

    /// What a login attempt came back as.
    enum Outcome: Sendable {
        case token(String)
        /// The account wants a code before it will hand one over.
        case challenge(Challenge)
    }

    /// A verification step, which GroupMe answers a first attempt with rather
    /// than failing it.
    struct Challenge: Sendable, Hashable {
        /// `sms`, `email`, or whatever else they add.
        var methods: [String]
        /// Where the code went, when they say.
        var destination: String?

        /// One sentence for the field's footer.
        var advice: String {
            guard let destination, !destination.isEmpty else {
                return "GroupMe sent a code. Enter it to finish signing in."
            }
            return "GroupMe sent a code to \(destination). Enter it to finish signing in."
        }
    }

    enum Failure: LocalizedError {
        case rejected
        case badCode
        case banned
        case throttled
        case server(String)
        case unreadable(status: Int)

        var errorDescription: String? {
            switch self {
            case .rejected: "That email or password was not accepted."
            case .badCode: "That code was not accepted."
            case .banned: "This account has been suspended."
            case .throttled: "Too many attempts. Wait a little and try again."
            case .server(let detail): detail
            case .unreadable(let status):
                status >= 500
                    ? "GroupMe is having trouble right now. Try again in a moment."
                    : "GroupMe answered in a shape this app does not understand (\(status))."
            }
        }
    }

    /// Sign in, optionally answering a challenge from a previous attempt.
    ///
    /// The two shapes are one function because the server treats them as one
    /// login: the second post repeats every field of the first and adds the
    /// code. Sending the code alone would be starting a different login.
    static func signIn(userName: String, password: String, code: String? = nil) async throws -> Outcome {
        let device = deviceID()
        var request = URLRequest(url: URL(string: "https://v2.groupme.com/access_tokens")!)
        request.httpMethod = "POST"
        request.setValue(hash(userName: userName, deviceID: device), forHTTPHeaderField: "X-Access-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let fields: [String: String] = [
            credentialField(for: userName): userName,
            "password": password,
            "grant_type": "password",
            "app_id": platformID,
            "app_version": versionCode,
            "device_id": device,
        ]

        if let code, !code.isEmpty {
            // The challenge answer is a different request class on the server:
            // same URL, same fields, JSON rather than a form, with the code
            // nested under `verification`.
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body = fields.mapValues { JSONValue.string($0) }
            body["verification"] = .object(["code": .string(code)])
            request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        } else {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(formEncode(fields).utf8)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        return try outcome(from: data, response: response, answeringChallenge: code != nil)
    }

    // MARK: - Reading the answer

    /// A refusal on the code step is about the code: the credentials behind
    /// it were accepted a moment ago, and telling the user their password is
    /// wrong while they look at a code field sends them back to retype the
    /// one thing that was right.
    private static func outcome(
        from data: Data, response: URLResponse, answeringChallenge: Bool
    ) throws -> Outcome {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let envelope = try? JSONDecoder().decode(LoginEnvelope.self, from: data) else {
            log.error("login response \(status) did not decode: \(data.count) bytes")
            throw status == 429 ? Failure.throttled : Failure.unreadable(status: status)
        }
        if let token = envelope.response?.accessToken, !token.isEmpty {
            return .token(token)
        }
        switch envelope.meta?.code {
        case 20200:
            let verification = envelope.response?.verification
            return .challenge(Challenge(
                methods: verification?.methods?.available ?? [],
                destination: verification?.systemNumber))
        case 40101:
            throw Failure.badCode
        case 40121:
            throw Failure.banned
        case 42901:
            throw Failure.throttled
        default:
            break
        }
        if let message = envelope.meta?.errors?.first, !message.isEmpty {
            throw Failure.server(message)
        }
        switch status {
        case 401, 404: throw answeringChallenge ? Failure.badCode : Failure.rejected
        case 429: throw Failure.throttled
        default: throw Failure.unreadable(status: status)
        }
    }

    private struct LoginEnvelope: Decodable {
        var response: Payload?
        var meta: Meta?

        struct Payload: Decodable {
            var accessToken: String?
            var userId: String?
            var verification: Verification?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case userId = "user_id"
                case verification
            }
        }

        struct Verification: Decodable {
            var type: String?
            var systemNumber: String?
            var methods: Methods?

            enum CodingKeys: String, CodingKey {
                case type
                case systemNumber = "system_number"
                case methods
            }
        }

        /// `{ sms: true, email: false }`, read as the list of what is on offer.
        struct Methods: Decodable {
            var sms: Bool?
            var email: Bool?
            var available: [String] {
                var names: [String] = []
                if sms == true { names.append("sms") }
                if email == true { names.append("email") }
                return names
            }
        }

        struct Meta: Decodable {
            var code: Int?
            var errors: [String]?
        }
    }

    // MARK: - Identity

    /// Which key the credential goes under.
    ///
    /// The APK, and every version of this file before it, sent `user_name`. The
    /// live server no longer reads it: a post keyed `user_name` comes back
    /// `400 {"errors": ["No phone number or email given"]}`, no matter how right
    /// everything else is, which is why email-and-password login had simply
    /// stopped working. The field it wants now is `email` or `phone_number`, and
    /// it takes either key for either kind of value — a phone number under
    /// `email` is accepted — so the split here is for honesty rather than
    /// because the server insists on it. Measured against the live endpoint on
    /// 19 September 2026; see `docs/verified.md`.
    private static func credentialField(for userName: String) -> String {
        userName.contains("@") ? "email" : "phone_number"
    }

    /// The pre-login token, which is not a token.
    private static func hash(userName: String, deviceID: String) -> String {
        let material = salt + platformID + deviceID + userName
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Stable per install. The server ties a session to it, and a device that
    /// renames itself every launch looks like a new one every time, which is how
    /// an account collects a login notification a week.
    private static func deviceID() -> String {
        if let stored = UserDefaults.standard.string(forKey: deviceKey), !stored.isEmpty {
            return stored
        }
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: deviceKey)
        return fresh
    }

    /// The hash names an Android client, so the request may as well agree with
    /// it. Shaped after `com.groupme.net.UserAgentInterceptor`.
    private static let userAgent =
        "GM-Android/16.10.4 (\(versionCode); M:Apple iPhone; O:34; D:ios) GroupMeNot/1.0"

    /// The unreserved set and nothing else. `CharacterSet.alphanumerics` is
    /// every letter in Unicode, which would put a password's accented letters
    /// on the wire as raw bytes in a body that promises percent-encoding.
    private static let formUnreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func formEncode(_ fields: [String: String]) -> String {
        let allowed = formUnreserved
        return fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
                return "\(key)=\(escaped)"
            }
            .joined(separator: "&")
    }
}
