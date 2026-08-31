import Foundation

/// What `GET /v1/urls/preview` had to say about a link.
///
/// GroupMe proxies Iframely here and does not document the response, so this
/// model refuses to be precise about it. Every field is optional, nothing is
/// required to decode, and the keys are looked up by name anywhere in the
/// returned JSON rather than by a fixed path. A shape change upstream should
/// cost us a field, never a crash and never an error banner.
nonisolated struct LinkPreview: Hashable, Sendable, Decodable {
    var title: String?
    var summary: String?
    var imageURL: URL?
    var siteName: String?
    /// The URL the server considers canonical, which is often the redirect
    /// target rather than what was typed.
    var canonicalURL: URL?

    /// True when there is enough here to be worth a card. A preview with
    /// nothing but a site name is just a second copy of the link.
    var isRenderable: Bool {
        title?.isEmpty == false || summary?.isEmpty == false || imageURL != nil
    }
}

nonisolated extension LinkPreview {

    /// Key spellings seen across Iframely, Open Graph and oEmbed, in preference
    /// order. First hit wins, shallowest first.
    private static let titleKeys = ["title", "meta_title", "og_title", "name", "headline"]
    private static let summaryKeys = ["description", "meta_description", "og_description", "summary"]
    private static let imageKeys = ["thumbnail_url", "image_url", "image", "thumbnail", "og_image", "picture"]
    private static let siteKeys = ["site_name", "site", "provider_name", "sitename", "publisher"]
    private static let canonicalKeys = ["canonical", "canonical_url", "og_url", "url", "href"]

    init(from decoder: Decoder) throws {
        let json = try JSON(from: decoder)
        // The v1 surface is inconsistent about the `{ response: … }` envelope,
        // so unwrap it when it is there and carry on when it is not.
        let root = json["response"] ?? json

        title = root.firstString(named: Self.titleKeys)
        summary = root.firstString(named: Self.summaryKeys)
        siteName = root.firstString(named: Self.siteKeys)
        imageURL = root.firstURL(named: Self.imageKeys)
        canonicalURL = root.firstURL(named: Self.canonicalKeys)

        // Guard against the common near-miss where the only "url" in the
        // document is the thumbnail's.
        if canonicalURL == imageURL { canonicalURL = nil }
    }
}

// MARK: - Untyped JSON

/// Just enough JSON to go looking for a key without knowing where it lives.
///
/// Small on purpose. It exists for one undocumented endpoint; if a second one
/// ever needs it, that is the moment to promote it out of this file.
nonisolated enum JSON: Decodable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSON])
    case array([JSON])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([String: JSON].self) { self = .object(value) }
        else if let value = try? container.decode([JSON].self) { self = .array(value) }
        else { self = .null }
    }

    subscript(key: String) -> JSON? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    var stringValue: String? {
        switch self {
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        // Objects that stand in for a string: `{ "href": … }`, `{ "url": … }`.
        case .object:
            return self["href"]?.stringValue ?? self["url"]?.stringValue ?? self["src"]?.stringValue
        case .array(let items):
            return items.lazy.compactMap(\.stringValue).first
        case .number, .bool, .null:
            return nil
        }
    }

    /// Breadth-first search for the first of `names` that carries a string.
    ///
    /// Breadth-first matters: Iframely nests a thumbnail object that also has a
    /// `url`, and the shallow one is the one that means what we want.
    func firstString(named names: [String]) -> String? {
        var level: [JSON] = [self]
        var depth = 0
        while !level.isEmpty && depth < 4 {
            for name in names {
                for node in level {
                    if let value = node[name]?.stringValue { return value }
                }
            }
            level = level.flatMap { node -> [JSON] in
                switch node {
                case .object(let fields): return Array(fields.values)
                case .array(let items): return items
                default: return []
                }
            }
            depth += 1
        }
        return nil
    }

    func firstURL(named names: [String]) -> URL? {
        guard let raw = firstString(named: names) else { return nil }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }
}
