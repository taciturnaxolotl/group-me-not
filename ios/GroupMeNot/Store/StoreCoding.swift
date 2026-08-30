import Foundation

/// JSON in and out of the `payload` and `attachments` blobs.
///
/// The key strategies match `APIClient`'s exactly. That is the whole point: a
/// `Message` decoded from the network and re-encoded here produces the same
/// snake_case shape it arrived in, so a stored payload is indistinguishable
/// from a fresh one and no field silently drops on the round trip.
nonisolated enum StoreCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    /// Optional encode, for columns that are NULL when there is nothing to say.
    static func encodeIfPresent<T: Encodable>(_ value: T?) -> Data? {
        guard let value else { return nil }
        return try? encoder.encode(value)
    }

    /// Lenient decode. A payload written by an older build that no longer
    /// parses should drop one row, not fail a whole page of history.
    static func decodeIfPossible<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? decoder.decode(type, from: data)
    }
}

nonisolated enum StoreError: Error, CustomStringConvertible {
    /// A row exists but its payload could not be decoded.
    case corruptRow(table: String, key: String)
    /// A conversation kind we do not recognise, which means a newer build wrote it.
    case unknownConversationKind(Int64)

    var description: String {
        switch self {
        case .corruptRow(let table, let key): "unreadable row \(key) in \(table)"
        case .unknownConversationKind(let kind): "unknown conversation kind \(kind)"
        }
    }
}
