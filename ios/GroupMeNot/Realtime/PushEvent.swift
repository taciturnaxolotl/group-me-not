import Foundation

// The realtime wire format, and what we turn it into.
//
// Bayeux frames arrive from the server as a JSON *array* of message objects; we
// send bare objects. Everything below models the inbound direction.
//
// Three type vocabularies overlap in GroupMe and only the first one appears in a
// Faye envelope's `data.type`:
//
//   1. Faye envelope types      favorite, like.delete, typing        <- modelled here
//   2. FCM data-message types   line.create, direct_message.create,  <- a different transport
//                               reaction, direct.call.missed, ...
//   3. System-message events    message.deleted, group.name_change,  <- ride *inside* a message
//                               membership.announce.joined, ...         as `event.type`
//
// So a group rename does not arrive as a push type. It arrives as an ordinary
// message with `system: true` and `event.type == "group.name_change"`, which is
// `PushEvent.Kind.message` here; read `message.event?.type` for the third
// vocabulary. Keeping them apart is the whole point of this file.

// MARK: - Events out of the realtime layer

/// Everything `BayeuxClient` tells the rest of the app, in one stream.
nonisolated enum RealtimeEvent: Sendable {
    /// Handshake finished and every desired channel was subscribed again.
    ///
    /// `gap` is how long we spent not listening, or `nil` on the first connect of
    /// this client's life. Faye has no replay extension (the server does not offer
    /// it), so **anything published during the gap is gone**: on every one of these
    /// the sync layer must reconcile over REST. The gap only says how much to
    /// expect, and whether a cheap `after_id` catch-up will do.
    case connectionDidResume(afterGap: TimeInterval?)

    /// The socket went away. A reconnect is already scheduled unless `stop()` ran.
    case connectionDidDrop(RealtimeError?)

    /// The connection state changed. Purely informational; drive UI from this.
    case connectionStateDidChange(RealtimeConnectionState)

    /// A channel refused us. Usually a stale token, since `ext` auth is only
    /// checked on subscribe.
    case subscriptionDidFail(channel: String, reason: String)

    /// Something arrived on a subscribed channel.
    case push(PushEvent)
}

nonisolated enum RealtimeConnectionState: Sendable, Hashable {
    case idle
    case connecting
    case handshaking
    case connected
    /// Backing off. `seconds` is the delay chosen for this attempt.
    case waitingToReconnect(seconds: TimeInterval)

    var isConnected: Bool { self == .connected }
}

nonisolated enum RealtimeError: Error, Sendable, Hashable {
    /// The server answered `/meta/handshake` with `successful: false`.
    case handshakeRejected(String)
    /// The socket failed or closed underneath us.
    case transport(String)
    /// The server told us to re-handshake, typically an expired `clientId`.
    case clientExpired
    /// A send was attempted with no live socket.
    case notRunning
}

// MARK: - The parsed push envelope

/// One thing that happened, as delivered over Faye.
nonisolated struct PushEvent: Sendable, Hashable {
    /// The Bayeux channel it arrived on, e.g. `/user/12345` or `/group/98765`.
    var channel: String
    /// `data.type` verbatim, kept even when we recognise it, because the
    /// vocabulary is not fully documented and logs are how we learn the rest.
    var type: String?
    /// `data.user_id`: whoever caused this, not necessarily the message author.
    var senderUserID: String?
    var kind: Kind

    nonisolated enum Kind: Sendable, Hashable {
        /// `subject` was message-shaped: a new line, an edit, or a system event.
        case message(Message)
        /// `favorite`: somebody liked a message.
        case liked(Like)
        /// `like.delete`: somebody took a like back.
        case unliked(Like)
        /// `typing`. There is no "stopped typing"; indicators die by timeout.
        case typing(Typing)
        /// A type we do not model. The subject is kept verbatim so a consumer can
        /// inspect it, and so nothing is silently dropped.
        case unrecognised(subject: JSONValue?)
    }

    nonisolated struct Like: Sendable, Hashable {
        /// The full message when the server sent it, which it usually does.
        var message: Message?
        /// The message the like applies to. Present even when `message` is not.
        var messageID: String?
        /// Who liked it, from `data.user_id`.
        var userID: String?
    }

    nonisolated struct Typing: Sendable, Hashable {
        var userID: String
        var startedAt: Date

        /// Publish at most one typing frame per second (the Android client's
        /// `InputBarFragment` throttle). Not negotiated, so matching it is how we
        /// look normal to everyone else.
        static let publishThrottle: TimeInterval = 1.0
        /// Drop a received indicator this long after its last event. Any new event
        /// for the same user restarts the clock.
        static let expiry: TimeInterval = 1.5
    }

    /// Literals seen in `FayeService`. Anything else falls through to a message
    /// shape test, which is how `line.create`-style deliveries land as `.message`.
    nonisolated enum WireType {
        static let favorite = "favorite"
        static let likeDelete = "like.delete"
        static let typing = "typing"
    }
}

extension PushEvent {
    /// Build an event from a delivered frame. Returns `nil` for `/meta/` frames and
    /// for deliveries with no `data`, which are the client's own publishes echoing.
    nonisolated init?(frame: BayeuxFrame, coder: JSONValue.Coder) {
        guard !frame.channel.hasPrefix("/meta/"), let data = frame.data else { return nil }
        self.channel = frame.channel
        self.type = data.type
        self.senderUserID = data.userId

        switch data.type {
        case PushEvent.WireType.typing:
            guard let user = data.userId ?? data.subject?["user_id"]?.stringValue else {
                self.kind = .unrecognised(subject: data.subject)
                return
            }
            // `started` is epoch *milliseconds* here, unlike every REST timestamp.
            let millis = data.started ?? data.subject?["started"]?.doubleValue
            let started = millis.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            self.kind = .typing(Typing(userID: user, startedAt: started))

        case PushEvent.WireType.favorite:
            self.kind = .liked(Self.like(from: data, coder: coder))

        case PushEvent.WireType.likeDelete:
            self.kind = .unliked(Self.like(from: data, coder: coder))

        default:
            if let message: Message = data.subject?.decoded(as: Message.self, using: coder) {
                self.kind = .message(message)
            } else {
                self.kind = .unrecognised(subject: data.subject)
            }
        }
    }

    /// Like payloads have been seen two ways: the subject *is* the message, or the
    /// subject wraps it under `line`. Try both rather than guess.
    nonisolated private static func like(from data: PushEnvelope, coder: JSONValue.Coder) -> Like {
        let subject = data.subject
        let message = subject?.decoded(as: Message.self, using: coder)
            ?? subject?["line"]?.decoded(as: Message.self, using: coder)
        let id = message?.id
            ?? subject?["message_id"]?.stringValue
            ?? subject?["line"]?["id"]?.stringValue
        return Like(message: message, messageID: id, userID: data.userId)
    }
}

// MARK: - Wire decoding

/// One Bayeux message. Meta responses and channel deliveries share this shape.
nonisolated struct BayeuxFrame: Decodable, Sendable {
    var channel: String
    var id: String?
    var clientId: String?
    var successful: Bool?
    var error: String?
    var subscription: String?
    var version: String?
    var supportedConnectionTypes: [String]?
    var advice: BayeuxAdvice?
    var data: PushEnvelope?
}

/// The server's reconnect instructions. `timeout` drives our keepalive period.
nonisolated struct BayeuxAdvice: Decodable, Sendable {
    /// `retry`, `handshake`, or `none`.
    var reconnect: String?
    /// Milliseconds the server will hold a connect open. Observed: 600000.
    var timeout: Double?
    /// Milliseconds to wait before reconnecting. Observed: 0.
    var interval: Double?
}

/// `data` on a delivery: `{ type, user_id, subject }`, plus `started` on typing.
nonisolated struct PushEnvelope: Decodable, Sendable, Hashable {
    var type: String?
    var userId: String?
    var started: Double?
    /// The affected object, in the same shape the REST API returns it.
    var subject: JSONValue?
}

// MARK: - JSONValue

/// A parsed JSON tree, used to hold `data.subject` until we know what it is.
///
/// Integers stay integers so a re-encode round trip does not turn `created_at`
/// into `1730000000.0` and break decoding into `Int`.
nonisolated enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// The encoder/decoder pair used to reinterpret a subtree as a model. Held by
    /// the caller because `JSONDecoder` is not free to build and this happens once
    /// per delivered frame.
    /// Not `Sendable`: keep one per actor rather than sharing it.
    nonisolated struct Coder {
        let decoder: JSONDecoder
        let encoder: JSONEncoder

        /// Snake case in, snake case out, matching `APIClient`.
        static func groupMe() -> Coder {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            return Coder(decoder: decoder, encoder: encoder)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not JSON")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Member lookup by the *wire* key, so callers write `subject["user_id"]`.
    subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    var stringValue: String? {
        switch self {
        case .string(let value): value
        case .int(let value): String(value)
        default: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value): value
        case .int(let value): Double(value)
        case .string(let value): Double(value)
        default: nil
        }
    }

    /// Reinterpret this subtree as a model. Returns `nil` when the shape does not
    /// fit, which is how an unrecognised subject is told apart from a message:
    /// `Message` needs `id` and `created_at`, and nothing else on the wire has both.
    func decoded<T: Decodable>(as type: T.Type, using coder: Coder) -> T? {
        guard case .object = self, let data = try? coder.encoder.encode(self) else { return nil }
        return try? coder.decoder.decode(T.self, from: data)
    }
}
