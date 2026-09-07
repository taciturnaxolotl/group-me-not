import Foundation
import os

/// What GroupMe's interest ids mean.
///
/// A profile carries interests as bare numbers — `[1001, 6000, 2001]` — and the
/// emoji and the words for them live in one JSON file on GroupMe's CDN:
///
///     https://cdn.groupme.com/assets/interestCharms/interestCharms.en-US.json
///
/// Twelve categories, some five hundred entries, and the same entry appears in
/// more than one category, so the useful shape is the flat map this builds
/// rather than the nested one that arrives. No token: it is a public asset, and
/// deliberately fetched with a plain request rather than through ``APIClient``,
/// which exists to speak an authenticated API this file is not part of.
///
/// Fetched once per launch and then held. It is 80KB and changes about as often
/// as GroupMe adds a fashion, so `URLCache` carries it between launches and this
/// actor carries it between sheets.
actor InterestCatalog {
    static let shared = InterestCatalog()

    private var entries: [Int: InterestCharm]?
    private var inFlight: Task<[Int: InterestCharm], Never>?
    private let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "interests")

    /// The charms for a profile's ids, in the order the profile gave them.
    ///
    /// Unknown ids are dropped rather than drawn as a number. A catalog that
    /// will not load means no chips at all, which is the right failure: the
    /// sheet is a face and a name before it is anything else.
    func charms(for ids: [Int]) async -> [InterestCharm] {
        guard !ids.isEmpty else { return [] }
        let table = await load()
        return ids.compactMap { table[$0] }
    }

    private func load() async -> [Int: InterestCharm] {
        if let entries { return entries }
        // One fetch however many sheets open at once: the second caller waits on
        // the first rather than asking again.
        if let inFlight { return await inFlight.value }
        let task = Task<[Int: InterestCharm], Never> { await Self.fetch(log: log) }
        inFlight = task
        let table = await task.value
        inFlight = nil
        // Only a real answer is kept. An empty table from a failed fetch would
        // otherwise be remembered as "this account has no interests" for the
        // rest of the session.
        if !table.isEmpty { entries = table }
        return table
    }

    private static func fetch(log: Logger) async -> [Int: InterestCharm] {
        guard let url = URL(string: Self.source) else { return [:] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let categories = try JSONDecoder().decode([Category].self, from: data)
            var table: [Int: InterestCharm] = [:]
            for category in categories {
                for entry in category.entries ?? [] {
                    guard let id = entry.id, let glyph = entry.glyph, let name = entry.name
                    else { continue }
                    table[id] = InterestCharm(id: id, glyph: glyph, name: name)
                }
            }
            return table
        } catch {
            log.notice("interest catalog unavailable: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    /// The language tag is part of the path rather than a header, and `en-US` is
    /// the one the Android client sends when it has nothing better. The
    /// `version` parameter it also sends comes from a config service we do not
    /// speak; leaving it off serves the current file.
    private static let source =
        "https://cdn.groupme.com/assets/interestCharms/interestCharms.en-US.json"

    private nonisolated struct Category: Decodable, Sendable {
        var entries: [Entry]?

        nonisolated struct Entry: Decodable, Sendable {
            var id: Int?
            var name: String?
            var glyph: String?
        }
    }
}
