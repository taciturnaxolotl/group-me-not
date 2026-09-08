import Foundation

/// Somebody else, as a profile sheet draws them.
///
/// Assembled rather than fetched: GroupMe keeps a person's profile, the groups
/// you share with them and the meaning of their interests in three different
/// places, and this is the one shape that has all of it at once. Everything past the id is optional, because every part of it can be
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
    /// Pictures they have put on their profile, which most people have none of.
    var photos: [String]

    init(id: String) {
        self.id = id
        self.charms = []
        self.sharedGroups = []
        self.photos = []
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
    /// Inside `user`, not beside it — measured against two accounts that have
    /// them, both with six. The Android model lists `photo_urls` on the
    /// response, which is the same shape of mistake `group_id` was; reading both
    /// levels costs nothing and settles it either way.
    var photoUrls: [String]?

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

    /// `group_id`, not `id`, and it is a **number**.
    ///
    /// Both halves of that were a bug in turn. The field list here is
    /// `group_id`, `group_name`, `group_avatar` and nothing else — measured
    /// against the live route — so reading `id` found nil every time and dropped
    /// every group. Reading `group_id` as a string then threw, which is worse:
    /// one bad element fails the whole array, so the count went from wrong to
    /// still nothing. Group ids are strings everywhere else in this API; here,
    /// like a subgroup's, they arrive as integers.
    nonisolated struct WireSharedGroup: Decodable, Sendable {
        var groupId: String?
        var groupName: String?
        var groupAvatar: String?

        private enum CodingKeys: String, CodingKey {
            case groupId, groupName, groupAvatar
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let number = (try? container.decodeIfPresent(Int.self, forKey: .groupId)) ?? nil {
                groupId = String(number)
            } else {
                groupId = (try? container.decodeIfPresent(String.self, forKey: .groupId)) ?? nil
            }
            groupName = (try? container.decodeIfPresent(String.self, forKey: .groupName)) ?? nil
            groupAvatar = (try? container.decodeIfPresent(String.self, forKey: .groupAvatar)) ?? nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case user, interests, graduationYear, directories, sharedGroups, photoUrls
    }

    /// Read from wherever it is.
    ///
    /// The legacy host has been through several ideas about the shape of a
    /// profile, and which level a field sits at is one of them: `interests` and
    /// `shared_groups` turn up beside `user` on some reads and inside it on
    /// others, and interests arrive as bare ids in one place and as little
    /// objects carrying one in another. None of that is worth a guess, so every
    /// field is looked for at both levels and in every spelling seen. What is
    /// not there is simply absent, and a sheet missing a row is a sheet.
    init(from decoder: any Decoder) throws {
        let outer = try decoder.container(keyedBy: CodingKeys.self)
        let inner = try? outer.nestedContainer(keyedBy: CodingKeys.self, forKey: .user)

        user = try? outer.decodeIfPresent(WireUser.self, forKey: .user)
        interests = Self.interests(in: outer) ?? inner.flatMap(Self.interests(in:))
        directories = Self.value([WireDirectory].self, .directories, outer, inner)
        sharedGroups = Self.value([WireSharedGroup].self, .sharedGroups, outer, inner)
        graduationYear = Self.text(.graduationYear, outer, inner)
        photoUrls = Self.value([String].self, .photoUrls, outer, inner)
    }

    /// A container's value for a key, from the outer object or the inner one.
    private static func value<T: Decodable>(
        _ type: T.Type, _ key: CodingKeys,
        _ outer: KeyedDecodingContainer<CodingKeys>,
        _ inner: KeyedDecodingContainer<CodingKeys>?
    ) -> T? {
        if let found = try? outer.decodeIfPresent(type, forKey: key) { return found }
        return (try? inner?.decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// A string that may have been sent as a number. `graduation_year` is both.
    private static func text(
        _ key: CodingKeys,
        _ outer: KeyedDecodingContainer<CodingKeys>,
        _ inner: KeyedDecodingContainer<CodingKeys>?
    ) -> String? {
        if let found = value(String.self, key, outer, inner) { return found }
        return value(Int.self, key, outer, inner).map(String.init)
    }

    /// Interest ids, however they were spelled.
    private static func interests(in container: KeyedDecodingContainer<CodingKeys>) -> [Int]? {
        if let ids = try? container.decodeIfPresent([Int].self, forKey: .interests), !ids.isEmpty {
            return ids
        }
        if let ids = try? container.decodeIfPresent([String].self, forKey: .interests) {
            let numbers = ids.compactMap(Int.init)
            if !numbers.isEmpty { return numbers }
        }
        if let objects = try? container.decodeIfPresent([WireInterest].self, forKey: .interests) {
            let numbers = objects.compactMap(\.id)
            if !numbers.isEmpty { return numbers }
        }
        return nil
    }

    nonisolated struct WireInterest: Decodable, Sendable {
        var id: Int?
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
