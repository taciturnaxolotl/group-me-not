import Foundation

// Wire models. Field names are GroupMe's, mapped from snake_case by the decoder.
// Timestamps are epoch *seconds*, not milliseconds.

nonisolated struct Message: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var sourceGuid: String?
    var createdAt: Int
    var userId: String?
    var senderId: String?
    var name: String?
    var avatarUrl: String?
    var senderType: String?
    var text: String?
    var system: Bool?
    var favoritedBy: [String]?
    var reactions: [Reaction]?
    var attachments: [Attachment]?
    var groupId: String?
    var chatId: String?
    var recipientId: String?
    var parentId: String?
    var pinnedAt: Int?
    var pinnedBy: String?
    var deletedAt: Int?
    var deletionActor: String?
    var updatedAt: Int?
    var event: SystemEvent?

    var date: Date { Date(timeIntervalSince1970: TimeInterval(createdAt)) }

    /// The text worth drawing.
    ///
    /// Nil for a message whose entire text is one of its own attachment URLs.
    /// GroupMe's clients set a video message's text to the video's URL, so an
    /// old client that cannot render the attachment still shows a link. Every
    /// client that *can* render it hides the text, and a client that does not is
    /// a client that prints a raw URL under every video.
    ///
    /// The URL is appended, so only a *trailing* one is removed. That is a
    /// deliberate limit rather than a half-measure: `loci` on a mention are
    /// offsets into this exact string, and cutting anything out of the middle
    /// or off the front would slide every mention after it onto the wrong word.
    /// Trimming the tail cannot move an offset that precedes it.
    ///
    /// Only the message's own attachment URLs, matched in full. A caption that
    /// happens to end in some other link keeps it, because that link is
    /// something a person typed.
    var visibleText: String? {
        guard let text, !text.isEmpty else { return text }
        let urls = (attachments ?? [])
            .flatMap { [$0.url, $0.previewUrl, $0.sourceUrl] }
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        guard !urls.isEmpty else { return text }

        var stripped = Substring(text)
        // A loop, because a message carrying a video and a photo appends both.
        var removedSomething = true
        while removedSomething {
            removedSomething = false
            let tail = stripped.reversed().prefix { $0.isWhitespace }.count
            let body = stripped.dropLast(tail)
            for url in urls where body.hasSuffix(url) {
                stripped = body.dropLast(url.count)
                removedSomething = true
                break
            }
        }

        guard stripped.count != text.count else { return text }
        let remaining = String(stripped).replacingOccurrences(
            of: "\\s+$", with: "", options: .regularExpression)
        return remaining.isEmpty ? nil : remaining
    }

    /// The message this one is a reply to, if it is one.
    ///
    /// Read off the attachment rather than off `parent_id`, because the
    /// attachment is what the sender actually said and `parent_id` is only
    /// sometimes filled in. GroupMe threads are flat: `reply_id` is the message
    /// being answered and `base_reply_id` is the root of the chain, and a client
    /// that draws one quote wants the former.
    var replyTargetID: String? {
        attachments?.first { $0.type == "reply" }?.replyId ?? parentId
    }

    /// The pair a reply has to send back. Both, because GroupMe keeps the chain
    /// root as well as the immediate parent, and a reply to a reply that omits
    /// the root loses the thread.
    static func replyAttachment(to message: Message) -> Attachment {
        Attachment(
            type: "reply",
            replyId: message.id,
            // Answering a reply keeps the original root; answering anything else
            // makes that message the root. Confirmed against live traffic: a
            // reply to a reply carries the first message's id here, not the
            // second's.
            baseReplyId: message.attachments?
                .first { $0.type == "reply" }?.baseReplyId ?? message.id,
            userId: message.senderId ?? message.userId)
    }

    /// Who wrote the message this one answers, as the sender recorded it.
    var replyTargetUserID: String? {
        attachments?.first { $0.type == "reply" }?.userId
    }
    var isSystem: Bool { system == true }
    var isDeleted: Bool { (deletedAt ?? 0) > 0 }
    var likeCount: Int { favoritedBy?.count ?? 0 }

    /// The reaction buckets the server actually described, in the one shape the
    /// rest of the app reasons about.
    ///
    /// `reactions` and `favorited_by` are not two sets of people to add up. They
    /// are two *views of the same set*, and which one you get depends on how old
    /// the reading client is. The same `favorite` frame on the wire is parsed by
    /// the official client either as `{line, reactions: [...]}` or, with
    /// multi-reactions off, as `{line, user_id}` appended to `favorited_by`; and
    /// its bubble shows reaction pills or the heart row but never both
    /// (`LikeableViewHolder.configureLikeUI`). So `favorited_by` is everyone who
    /// reacted with anything, and treating it as a heart bucket *alongside*
    /// `reactions` counts every reactor twice and puts a ❤️ on every message
    /// that has any reaction at all.
    ///
    /// Hence: when the server sent a reaction array, that array is the whole
    /// truth. `favorited_by` is the fallback for messages it described no other
    /// way, where a heart is the only thing we could honestly draw, and even
    /// then the glyph is a legacy convention rather than something we were told.
    ///
    /// The emptiness test is on the raw array, not on what survives drawing: a
    /// message whose only reaction is one we cannot draw has still been
    /// described, and inventing a heart for it would be attributing a glyph
    /// nobody sent.
    var wireReactions: [Reaction] {
        if let reactions, !reactions.isEmpty { return reactions }
        guard let likers = favoritedBy, !likers.isEmpty else { return [] }
        return [Reaction(type: "unicode", code: ReactionSummary.heart, userIds: likers)]
    }

    /// The one list a bubble draws.
    ///
    /// Buckets keep the order the server sent, which is the order the reactions
    /// were first used.
    ///
    /// Legacy powerup reactions survive as pack tokens (see
    /// ``Reaction/glyph``); anything with no glyph at all is dropped rather
    /// than rendered as a blank.
    func reactionSummaries(currentUserID: String?) -> [ReactionSummary] {
        var order: [String] = []
        var buckets: [String: [String]] = [:]

        for reaction in wireReactions {
            guard let glyph = reaction.glyph, let users = reaction.userIds, !users.isEmpty
            else { continue }
            if buckets[glyph] == nil { order.append(glyph) }
            var merged = buckets[glyph] ?? []
            let known = Set(merged)
            merged.append(contentsOf: users.filter { !known.contains($0) })
            buckets[glyph] = merged
        }

        return order.compactMap { glyph in
            guard let users = buckets[glyph], !users.isEmpty else { return nil }
            return ReactionSummary(
                glyph: glyph,
                userIDs: users,
                reactedByMe: currentUserID.map(users.contains) ?? false)
        }
    }

    /// The glyph this user currently holds on this message, if any.
    ///
    /// GroupMe stores one reaction per person per message, so this is a single
    /// value and not a set. Used to decide whether a tap adds, swaps, or clears.
    func reaction(by userID: String) -> String? {
        reactionSummaries(currentUserID: userID).first { $0.reactedByMe }?.glyph
    }

    /// This message with `userID`'s reaction set to `glyph`, or cleared when
    /// `glyph` is nil. Whatever they held before goes first, because GroupMe
    /// allows one reaction per person per message.
    ///
    /// The single definition of that rule. ``AppModel`` applies it to the
    /// published array before it suspends, so a tapback draws on the next
    /// frame, and ``MessageStore/setReaction(_:by:onMessage:in:)`` applies the
    /// same function to the stored copy inside its transaction. One rule, two
    /// callers, no chance of them drifting apart.
    ///
    /// The result is always in the modern shape: buckets in `reactions`, and
    /// `favorited_by` cleared. It has to be, because ``wireReactions`` reads
    /// `favorited_by` only when `reactions` is empty, so a heart left behind in
    /// the legacy field would simply not be drawn on a message that has any
    /// other reaction on it. Starting from ``wireReactions`` rather than from
    /// `reactions` is what carries the existing likers across that conversion
    /// instead of dropping them the moment somebody adds a second glyph.
    func settingReaction(_ glyph: String?, by userID: String) -> Message {
        var copy = self

        var buckets = wireReactions.compactMap { reaction -> Reaction? in
            guard let users = reaction.userIds, users.contains(userID) else { return reaction }
            var updated = reaction
            updated.userIds = users.filter { $0 != userID }
            return (updated.userIds?.isEmpty ?? true) ? nil : updated
        }

        if let glyph {
            if let index = buckets.firstIndex(where: { $0.glyph == glyph }) {
                buckets[index].userIds = (buckets[index].userIds ?? []) + [userID]
            } else {
                buckets.append(Reaction(glyph: glyph, userIds: [userID]))
            }
        }

        copy.reactions = buckets
        copy.favoritedBy = nil
        return copy
    }

    /// True once the author has changed the text after posting.
    ///
    /// GroupMe stamps `updated_at` equal to `created_at` on a message nobody has
    /// touched, so the marker turns on strictly after, never on equality.
    var isEdited: Bool { (updatedAt ?? 0) > createdAt }

    /// This message with a later revision folded in, field by field.
    ///
    /// The reason to merge rather than replace: a `message.update` push carries
    /// the revised message, but nothing promises it carries *all* of it. A blind
    /// upsert of a thin edit payload would drop the likes, the reactions and the
    /// attachments we already hold, and REST catch-up could never put them back
    /// (`after_id` never revisits an id it has already passed). So anything the
    /// update leaves out is kept, and only what it states wins.
    ///
    /// `text` is the exception worth naming: an edit that clears the text sends
    /// an empty string, not a missing field, so an absent `text` really does mean
    /// "unchanged" here.
    func merging(_ update: Message) -> Message {
        var copy = self
        copy.text = update.text ?? copy.text
        copy.updatedAt = update.updatedAt ?? copy.updatedAt
        copy.attachments = update.attachments ?? copy.attachments
        copy.favoritedBy = update.favoritedBy ?? copy.favoritedBy
        copy.reactions = update.reactions ?? copy.reactions
        copy.name = update.name ?? copy.name
        copy.avatarUrl = update.avatarUrl ?? copy.avatarUrl
        copy.senderId = update.senderId ?? copy.senderId
        copy.userId = update.userId ?? copy.userId
        copy.deletedAt = update.deletedAt ?? copy.deletedAt
        copy.deletionActor = update.deletionActor ?? copy.deletionActor
        copy.pinnedAt = update.pinnedAt ?? copy.pinnedAt
        copy.pinnedBy = update.pinnedBy ?? copy.pinnedBy
        copy.parentId = update.parentId ?? copy.parentId
        copy.event = update.event ?? copy.event
        return copy
    }

    /// This message with new text and a fresh revision stamp. Used for the
    /// optimistic local edit, before the server has said anything.
    func editing(text: String?, updatedAt: Int = Int(Date().timeIntervalSince1970)) -> Message {
        var copy = self
        copy.text = text
        copy.updatedAt = updatedAt
        return copy
    }

    /// The family of system event this message announces, for the transcript's
    /// run collapsing. Nil for anything that is not a system notice.
    var systemFamily: SystemMessageFamily? {
        guard isSystem else { return nil }
        return SystemMessageFamily(eventType: event?.type)
    }

    /// Message ids sort chronologically as big integers, never lexically.
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        if let a = UInt64(lhs), let b = UInt64(rhs) { return a > b }
        return lhs.count == rhs.count ? lhs > rhs : lhs.count > rhs.count
    }

    /// One reaction bucket as the server stores it.
    ///
    /// `type` is `unicode` for the modern set and `emoji` for the legacy
    /// powerup packs, which is why `code` and the pack coordinates are all
    /// optional: exactly one pair is ever filled in.
    nonisolated struct Reaction: Codable, Hashable, Sendable {
        var type: String?
        var code: String?
        var packId: Int?
        var packIndex: Int?
        var userIds: [String]?

        /// The opaque key the rest of the app identifies a reaction by.
        ///
        /// A unicode reaction is its own key, which is what lets a glyph travel
        /// through the picker, the outbox and the chips as a plain `String`.
        /// Pack reactions need a key too, because the alternative is what we
        /// used to do: return nil and silently drop every powerup reaction on
        /// the floor. So they get a token, `gm:{pack}:{index}`, which
        /// ``PackGlyph`` reads back and ``ReactionCatalog/icon(for:)`` turns
        /// into the right request body. The colon form cannot collide with a
        /// real emoji, because a unicode reaction is a single grapheme cluster
        /// and this is not.
        var glyph: String? {
            if let packGlyph = PackGlyph(self) { return packGlyph.token }
            guard type == nil || type == "unicode" else { return nil }
            guard let code, !code.isEmpty else { return nil }
            return code
        }

        /// GroupMe is not consistent about the type of these two.
        ///
        /// `pack_id` arrives as a JSON number on most messages and as a quoted
        /// string on some, in the same array, in the same response. The strict
        /// decoder threw on the string, and because it threw while decoding a
        /// *page*, one such reaction anywhere in two hundred messages lost the
        /// entire page: a fresh install would sync seven conversations, fail
        /// seven times, and show no history at all.
        ///
        /// So both are read loosely. A pack id we cannot make a number of
        /// leaves the reaction without a glyph, which drops that one sticker
        /// and keeps everything else, and that is the right trade every time.
        /// Spelled out rather than synthesised, because the custom decoder below
        /// has to name them and the compiler's version is not visible to it.
        enum Key: String, CodingKey {
            case type, code, packId, packIndex, userIds
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            code = try container.decodeIfPresent(String.self, forKey: .code)
            packId = Self.looseInt(container, .packId)
            packIndex = Self.looseInt(container, .packIndex)
            userIds = try container.decodeIfPresent([String].self, forKey: .userIds)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            try container.encodeIfPresent(type, forKey: .type)
            try container.encodeIfPresent(code, forKey: .code)
            try container.encodeIfPresent(packId, forKey: .packId)
            try container.encodeIfPresent(packIndex, forKey: .packIndex)
            try container.encodeIfPresent(userIds, forKey: .userIds)
        }

        private static func looseInt(
            _ container: KeyedDecodingContainer<Key>, _ key: Key
        ) -> Int? {
            // `try?` flattens the double optional, so a missing key and a
            // wrong type both arrive here as nil. Neither needs telling apart:
            // the string attempt answers nil for a missing key too.
            if let number = try? container.decodeIfPresent(Int.self, forKey: key) { return number }
            guard let text = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
            return Int(text)
        }

        /// Spelled out because the glyph initialiser below suppresses the one
        /// the compiler would have written.
        init(
            type: String? = nil, code: String? = nil,
            packId: Int? = nil, packIndex: Int? = nil, userIds: [String]? = nil
        ) {
            self.type = type
            self.code = code
            self.packId = packId
            self.packIndex = packIndex
            self.userIds = userIds
        }

        /// The wire bucket a glyph belongs in. The inverse of ``glyph``.
        init(glyph: String, userIds: [String]? = nil) {
            if let pack = PackGlyph(token: glyph) {
                self.init(
                    type: "emoji", code: nil,
                    packId: pack.packID, packIndex: pack.index, userIds: userIds)
            } else {
                self.init(type: "unicode", code: glyph, userIds: userIds)
            }
        }
    }

    /// A legacy powerup reaction: a cell in a pack's sprite sheet rather than a
    /// character.
    ///
    /// These are not a historical curiosity. A group's own like icon is still
    /// written this way by the official Android client (`GroupLikeIconRequest`
    /// hardcodes `type: "emoji"`), so a client that understands only unicode
    /// cannot draw the one reaction a group chose for itself.
    nonisolated struct PackGlyph: Hashable, Sendable {
        var packID: Int
        var index: Int

        /// Distinguishes the token from a real emoji. See ``Reaction/glyph``.
        static let prefix = "gm:"

        var token: String { "\(Self.prefix)\(packID):\(index)" }

        init(packID: Int, index: Int) {
            self.packID = packID
            self.index = index
        }

        init?(token: String) {
            guard token.hasPrefix(Self.prefix) else { return nil }
            let parts = token.dropFirst(Self.prefix.count).split(separator: ":")
            guard parts.count == 2, let pack = Int(parts[0]), let index = Int(parts[1])
            else { return nil }
            self.init(packID: pack, index: index)
        }

        /// Reads a wire reaction, or a group's `like_icon`, as a pack cell.
        ///
        /// `type` is trusted when it is there and inferred from the coordinates
        /// when it is not, because the system event that announces a like icon
        /// change carries only `pack_id` and `pack_index`
        /// (`Message.ReactionIcon` in the Android model).
        init?(_ reaction: Reaction) {
            guard let packID = reaction.packId, let index = reaction.packIndex else { return nil }
            guard reaction.type == nil || reaction.type == "emoji" else { return nil }
            self.init(packID: packID, index: index)
        }
    }

    /// A reaction bucket after plain likes have been folded in. This is the
    /// shape a bubble renders.
    nonisolated struct ReactionSummary: Identifiable, Hashable, Sendable {
        /// The bucket plain likes land in.
        static let heart = "\u{2764}\u{FE0F}"

        var glyph: String
        var userIDs: [String]
        var reactedByMe: Bool

        var id: String { glyph }
        var count: Int { userIDs.count }

        /// What VoiceOver should say for the glyph. A pack cell has no name we
        /// hold, so it is announced by what it is.
        var spokenGlyph: String {
            PackGlyph(token: glyph) == nil ? glyph : "sticker"
        }
    }

    nonisolated struct SystemEvent: Codable, Hashable, Sendable {
        var type: String?
        /// The structured half of a system notice.
        ///
        /// `LocalizedData` on the wire, and it is enormous: one union of every
        /// field every event family needs. Only what we act on is modelled, so
        /// adding an event means adding a field here and nothing else.
        var data: EventData?

        nonisolated struct EventData: Codable, Hashable, Sendable {
            /// The group's new like icon, on `group.like_icon_set` and
            /// `group.subgroup_like_icon_change`. Absent on `…_removed`, which
            /// is how the removal is expressed.
            var likeIcon: Reaction?
        }

        /// Event types this app acts on beyond the transcript. The rest of the
        /// vocabulary is in `SystemMessageFamily`, which only needs the prefix.
        static let likeIconSet = "group.like_icon_set"
        static let likeIconRemoved = "group.like_icon_removed"
        static let subgroupLikeIconChanged = "group.subgroup_like_icon_change"
    }

    nonisolated struct Attachment: Codable, Hashable, Sendable {
        var type: String?
        var url: String?
        var sourceUrl: String?
        var previewUrl: String?
        var blurHash: String?
        var fileId: String?
        var name: String?
        var lat: String?
        var lng: String?
        var replyId: String?
        var baseReplyId: String?
        /// On a `reply`, who wrote the message being answered.
        ///
        /// Distinct from `userIds`, which is the mention list. Every reply the
        /// official clients send carries this, and it is the one thing that lets
        /// a quote name a person before the message being quoted has been
        /// fetched, so it is worth sending and worth reading.
        var userId: String?
        var userIds: [String]?
        var loci: [[Int]]?
        var placeholder: String?
        var charmap: [[Int]]?
        var duration: Int?
        var pollId: String?
        var eventId: String?
    }
}

nonisolated struct Group: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var type: String?
    var description: String?
    var imageUrl: String?
    var creatorUserId: String?
    var createdAt: Int?
    var updatedAt: Int?
    var mutedUntil: Int?
    var unreadCount: Int?
    var lastReadMessageId: String?
    var lastReadAt: Int?
    var messages: MessagesSummary?
    var members: [Member]?
    var membersCount: Int?
    var parentId: String?
    var childrenCount: Int?

    /// The reaction this group chose for itself, if it has one.
    ///
    /// Same `{type, code, pack_id, pack_index}` shape as a message reaction, so
    /// it is the same type: a group like icon and a reaction are the same thing
    /// pointed at different objects, and `POST /v3/groups/{id}/like_icon` takes
    /// the body `POST …/like` does. In practice it usually arrives as a pack
    /// icon rather than a character; see ``Message/PackGlyph``.
    var likeIcon: Message.Reaction?

    /// How long after posting a message may still be edited, in seconds.
    ///
    /// Server-owned and per-group. The edit affordance honours it rather than
    /// offering an action that is going to be refused: `0` or absent means
    /// editing is off for this group.
    var messageEditPeriod: Int?
    /// The matching window for deletion, same rules.
    var messageDeletionPeriod: Int?

    /// Whether `message` is still inside this group's edit window.
    func canEdit(_ message: Message, now: Date = Date()) -> Bool {
        guard let period = messageEditPeriod, period > 0 else { return false }
        return now.timeIntervalSince(message.date) < TimeInterval(period)
    }

    nonisolated struct MessagesSummary: Codable, Hashable, Sendable {
        var count: Int?
        var lastMessageId: String?
        var lastMessageCreatedAt: Int?
        var lastMessageUpdatedAt: Int?
        var preview: Preview?

        nonisolated struct Preview: Codable, Hashable, Sendable {
            var nickname: String?
            var text: String?
            var imageUrl: String?
            var attachments: [Message.Attachment]?
        }
    }
}

nonisolated struct Member: Codable, Identifiable, Hashable, Sendable {
    var id: String?
    var userId: String?
    var nickname: String?
    var name: String?
    var imageUrl: String?
    var roles: [String]?

    var identity: String { userId ?? id ?? UUID().uuidString }

    /// Whether this member may post in an announcement topic.
    ///
    /// GroupMe uses three role words: `owner`, `admin`, `user`. Only the first
    /// two carry any authority, and the third is everybody else.
    var canPostInAnnouncements: Bool {
        guard let roles else { return false }
        return roles.contains("admin") || roles.contains("owner")
    }
}

/// A topic inside a group.
///
/// Reached only through `GET /v3/groups/{parentID}/subgroups`. Note `topic`
/// rather than `name`, and that the ids arrive as numbers rather than strings,
/// which is the one place this API breaks its own habit.
nonisolated struct Subgroup: Codable, Hashable, Sendable {
    var id: Int
    var parentId: Int
    var topic: String?
    var description: String?
    var avatarUrl: String?
    /// `announcement` or `private`. See ``PostingPolicy``.
    var type: String?
    var mutedUntil: Int?
    var likeIcon: Message.Reaction?
    var unreadCount: Int?
    var lastReadMessageId: String?
    var messageEditPeriod: Int?
    var messages: Group.MessagesSummary?

    var groupID: String { String(id) }
    var parentGroupID: String { String(parentId) }
}

/// Who may post in a conversation.
nonisolated enum PostingPolicy: Int, Codable, Sendable, Hashable {
    /// Anybody in it. Every ordinary group and DM.
    case everyone = 0
    /// Admins and the owner only. GroupMe's `announcement` topics, which is how
    /// a rules or announcements channel is expressed.
    case adminsOnly = 1

    init(wireType: String?) {
        self = wireType == "announcement" ? .adminsOnly : .everyone
    }
}

nonisolated struct Chat: Codable, Hashable, Sendable {
    var createdAt: Int?
    var updatedAt: Int?
    var lastMessage: Message?
    var messagesCount: Int?
    var unreadCount: Int?
    var lastReadMessageId: String?
    var lastReadAt: Int?
    var otherUser: OtherUser

    nonisolated struct OtherUser: Codable, Hashable, Sendable {
        var id: String
        var name: String?
        var avatarUrl: String?
    }
}

nonisolated struct CurrentUser: Codable, Hashable, Sendable {
    var id: String
    var name: String?
    var imageUrl: String?
    var email: String?
    var phoneNumber: String?
}
