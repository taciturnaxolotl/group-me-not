import Foundation

/// Somebody else, as a profile sheet draws them.
///
/// Assembled rather than fetched: GroupMe keeps a person's profile, the groups
/// you share with them, the meaning of their interests and whether they are
/// about in four different places, and this is the one shape that has all of it
/// at once. Everything past the id is optional, because every part of it can be
/// absent and a sheet with a face and a name on it is still worth showing.
nonisolated struct Person: Hashable, Sendable {
    var id: String
    var name: String?
    var avatarURL: String?
    var bio: String?
    /// The Spotify link they chose as their anthem.
    var anthem: URL?
    /// When they joined GroupMe, drawn as "Since May 2025".
    var since: Date?
    /// Their school and year, when they are in a campus directory: the profile
    /// carries the two separately and they only mean anything together.
    var school: String?
    var charms: [InterestCharm]
    var sharedGroups: [SharedGroup]
    var presence: Presence?

    init(id: String) {
        self.id = id
        self.charms = []
        self.sharedGroups = []
    }
}

/// One of the interests a person can pin to their profile.
///
/// The profile carries ids and nothing else; the words and the emoji live in a
/// catalog on GroupMe's CDN. See ``InterestCatalog``.
nonisolated struct InterestCharm: Hashable, Sendable, Identifiable {
    var id: Int
    var glyph: String
    var name: String
}

/// A group two people are both in.
nonisolated struct SharedGroup: Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var avatarURL: String?
}

// MARK: - Wire

/// `GET https://v2.groupme.com/users/{id}`, and the same route again with
/// `include_shared_groups=true`.
///
/// The two answers overlap without agreeing: the plain read carries the profile
/// proper — interests, the anthem, the campus fields — and the one asking for
/// shared groups carries those. The official client makes both calls and so does
/// this, because guessing that one is a superset of the other is the kind of
/// guess that quietly shows an empty sheet.
///
/// Decoded by hand and leniently. Every field here is one somebody may not have
/// set, arriving from a legacy host that has been through several ideas about
/// what a profile is: `graduation_year` is a string in one place and a number in
/// another. A profile that fails to decode is a sheet that fails to open, and
/// none of this is worth that.
nonisolated struct UserProfileBody: Decodable, Sendable {
    var user: WireUser?
    var interests: [Int]?
    var graduationYear: String?
    var directories: [WireDirectory]?
    var sharedGroups: [WireSharedGroup]?

    nonisolated struct WireUser: Decodable, Sendable {
        var id: String?
        var userId: String?
        var name: String?
        var avatarUrl: String?
        var imageUrl: String?
        var bio: String?
        var songUrl: String?
        var createdAt: Double?

        var identity: String? { userId ?? id }
        var picture: String? { avatarUrl ?? imageUrl }
        /// Seconds here, unlike presence's milliseconds. The legacy host has
        /// always used seconds and the mini profile draws a month and a year
        /// from it, so a factor of a thousand would be visible.
        var joined: Date? {
            guard let createdAt, createdAt > 0 else { return nil }
            return Date(timeIntervalSince1970: createdAt)
        }
    }

    nonisolated struct WireDirectory: Decodable, Sendable {
        var name: String?
        var shortName: String?
    }

    nonisolated struct WireSharedGroup: Decodable, Sendable {
        var id: String?
        var groupName: String?
        var groupAvatar: String?
    }

    private enum CodingKeys: String, CodingKey {
        case user, interests, graduationYear, directories, sharedGroups
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        user = try? container.decodeIfPresent(WireUser.self, forKey: .user)
        interests = (try? container.decodeIfPresent([Int].self, forKey: .interests)) ?? nil
        directories = (try? container.decodeIfPresent([WireDirectory].self, forKey: .directories)) ?? nil
        sharedGroups = (try? container.decodeIfPresent([WireSharedGroup].self, forKey: .sharedGroups)) ?? nil
        if let year = try? container.decodeIfPresent(String.self, forKey: .graduationYear) {
            graduationYear = year
        } else if let year = try? container.decodeIfPresent(Int.self, forKey: .graduationYear) {
            graduationYear = String(year)
        } else {
            graduationYear = nil
        }
    }

    /// The school chip: "Cedarville 2030". Either half alone is not worth a chip
    /// — a year with no school says nothing, and a school with no year is
    /// already in the directory list nobody is looking at.
    var school: String? {
        let name = directories?.compactMap { $0.shortName ?? $0.name }.first
        switch (name, graduationYear) {
        case (let name?, let year?): return "\(name) \(year)"
        case (let name?, nil): return name
        default: return nil
        }
    }
}
