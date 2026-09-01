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
        case banned
        case server(String)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .rejected: "That email or password was not accepted."
            case .banned: "This account has been suspended."
            case .server(let detail): detail
            case .unreadable: "GroupMe answered in a shape this app does not understand."
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
            "user_name": userName,
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
        return try outcome(from: data, response: response)
    }

    // MARK: - Reading the answer

    private static func outcome(from data: Data, response: URLResponse) throws -> Outcome {
        guard let envelope = try? JSONDecoder().decode(LoginEnvelope.self, from: data) else {
            log.error("login response did not decode: \(data.count) bytes")
            throw Failure.unreadable
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
        case 40121:
            throw Failure.banned
        default:
            break
        }
        if let message = envelope.meta?.errors?.first, !message.isEmpty {
            throw Failure.server(message)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        throw status == 401 || status == 404 ? Failure.rejected : Failure.unreadable
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

    private static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
                return "\(key)=\(escaped)"
            }
            .joined(separator: "&")
    }
}
