# Messaging

Groups and DMs are almost the same API. The differences are not guessable, so this file
spells them out.

## Reading history

```
GET https://api.groupme.com/v3/groups/{groupId}/messages
GET https://api.groupme.com/v3/direct_messages?other_user_id={userId}
```

Query parameters. The client appends `limit`, `acceptFiles`, `before_id`, `include`, and
`profile`, in that order; the two forward-paging parameters are server capabilities the app
never uses.

| Param | Notes |
| --- | --- |
| `limit` | app sends 100 on a full sync and 50 on a poll; the real cap is **200** ([verified](verified.md)) |
| `acceptFiles` | app sends `true`, web sends `1`; without it, file attachments come back stripped |
| `before_id` | page backwards from this message id |
| `after_id` | page **forwards**, gap-free, ascending. The app never sends it |
| `since_id` | jumps to the newest messages, descending. Not a catch-up parameter |
| `include=read_receipts` | DMs only, first page only, and only when the `unreadSync` flag is on |
| `profile=current` | added when the `avatarNameSync` flag is on; returns current display names rather than the name captured at send time |

`acceptFiles` and `profile` are not in the published developer docs. `acceptFiles` is the
interesting one: omit it and document attachments silently disappear from the response.

For catching up after time offline, use `after_id`. `since_id` looks equivalent and is not:
it returns the most recent messages and skips anything in between. See
[verified.md](verified.md) for the measurement.

A single message:

```
GET https://api.groupme.com/v4/groups/{groupId}/messages/{messageId}
GET https://api.groupme.com/v3/direct_messages/{messageId}?other_user_id={userId}
```

Note the version split. Group single-message reads went to v4; the DM equivalent stayed on v3.

## Sending

```
POST https://api.groupme.com/v3/groups/{groupId}/messages
POST https://api.groupme.com/v3/direct_messages
```

The DM route takes no id in the path. The recipient goes in the body.

```json
{
  "message": {
    "source_guid": "<client-generated UUID>",
    "text": "hello",
    "recipient_id": "<user id, DMs only>",
    "attachments": []
  }
}
```

`source_guid` is the idempotency key. Reusing one returns **`409`**, which the client treats
as success without parsing a body, so a retry learns that the message landed but not its
server-assigned id. Resync the conversation to pick that up.

`locale` (BCP-47 tag) and `time_zone` (tz database id) appear only when the recipient is the
Copilot assistant chat. `supported_cards`, an array of card type strings the client can
render, needs that plus the study-tools flag.

The request wrapper key is `message` on this path. `ShareCardRequest` wraps DM bodies in
`direct_message` instead, so the two send paths genuinely disagree; `message` is what the
normal composer sends.

The response is `{"response": {"message": {...}}}` for groups and
`{"response": {"direct_message": {...}}}` for DMs.

## Editing and deleting

```
PUT    https://api.groupme.com/v4/groups/{groupId}/messages/{messageId}
PUT    https://api.groupme.com/v4/direct_messages/{userId}/messages/{messageId}
DELETE https://api.groupme.com/v3/conversations/{conversationId}/messages/{messageId}
```

Edit is v4 and takes the *other user's* id in the DM path. Delete is v3 and takes the
combined `{a}+{b}` conversation id. There is no consistency to lean on here.

## Attachments

Attachments are a JSON array on the message, discriminated by `type`. All but the last are
built by `PostMessageRequest.MessagePayloadBuilder`; `copilot_card` comes from
`ShareCardRequest` instead.

| `type` | Fields |
| --- | --- |
| `image` | `url`, `source_url`, `blur_hash` |
| `video` | `url`, `preview_url`, `blur_hash` |
| `audio` | `url`, `duration`, `peaks`, `transcript_url` |
| `file` | `file_id` |
| `location` | `name`, `lat`, `lng` |
| `reply` | `reply_id`, `base_reply_id` |
| `emoji` | `placeholder`, `charmap` |
| `mentions` | `user_ids`, `loci` |
| `copilot_card` | `card_type`, `card_id`, `state`, `title`, `payload`, `source_user_id`, `source_user_name`, `source_score` |

`url` for images and video must be a GroupMe media-service URL, not an arbitrary one. See
[uploads](uploads.md).

`reply` carries two ids because GroupMe threads are flat: `reply_id` is the message being
replied to and `base_reply_id` is the root of the chain.

`emoji` is the legacy powerup sticker mechanism. `placeholder` is always U+FFFD (the
replacement character), and `charmap` is a list of `[pack_id, pack_index]` pairs substituted
for each occurrence, the same pair the reaction `like_icon` uses.

`mentions` uses `loci`: a list of `[offset, length]` pairs into `text`, parallel to
`user_ids`. Offsets are UTF-16 code unit indices, because they are produced from Java
strings. Emoji outside the BMP therefore count as two.

The received-side attachment shape is broader than the send side. Full field list under
`Message.Attachment` in [models.md](models.md).

## Reading a received message

The fields you actually need off a message object, beyond `text`:

| Field | Notes |
| --- | --- |
| `id` | server id; sorts chronologically as a big integer, so compare numerically, not lexically |
| `source_guid` | echoed back. Match it to reconcile your outbox |
| `created_at` | epoch **seconds**, not milliseconds |
| `sender_id`, `name`, `avatar_url` | display identity captured at send time, unless you asked for `profile=current` |
| `sender_type` | `user`, `bot`, or `system` |
| `system` | boolean. `true` means this is an event notice, not a person talking |
| `favorited_by` | array of user ids who liked it. This is how like counts arrive |
| `reactions` | array of `{type, code/pack_id, user_ids}` |
| `pinned_at`, `pinned_by` | pin state rides on the message itself |
| `deleted_at`, `deletion_actor` | tombstone. The message still arrives, with `text` cleared |
| `parent_id` | set when the message belongs to a topic (subgroup) |

**`system: true` is the one that surprises people.** Membership changes, name changes, avatar
changes, and event notices all arrive inline as ordinary messages with `system` set and a
human-readable `text`. A client that filters them out loses "Kieran joined the group" from
the transcript. The structured version of the same change also arrives on the push channel,
so you will see both.

## Likes and reactions

Both go through one route, and the conversation id uses the `+` form for DMs:

```
POST https://api.groupme.com/v3/messages/{conversationId}/{messageId}/like
POST https://api.groupme.com/v3/messages/{conversationId}/{messageId}/unlike
```

A plain like sends no body. A reaction sends a `like_icon` object on the same `like` route:

```json
{ "like_icon": { "type": "unicode", "code": "👍" } }
```

or, for a legacy powerup sticker:

```json
{ "like_icon": { "type": "emoji", "pack_id": 3, "pack_index": 17 } }
```

`unlike` never carries a body. The available reaction set is not hardcoded; the client fetches it from
`https://cdn.groupme.com/assets/reactions.json?version=<ecs version>`. Microsoft "Hubble"
emoji render from `cdn.hubblecontent.osi.office.net`.

Reading likes:

```
GET https://api.groupme.com/v3/groups/{groupId}/likes?period={day|week|month}
GET https://api.groupme.com/v3/groups/{groupId}/likes/mine
GET https://api.groupme.com/v3/groups/{groupId}/likes/for_me
GET https://api.groupme.com/v4/likes/direct_messages/mine?other_user_id={userId}
GET https://api.groupme.com/v4/likes/direct_messages/for_me?other_user_id={userId}
```

## Read receipts

The v2 and v4 surfaces coexist depending on the `unreadSync` flag.

```
POST   https://v2.groupme.com/read_receipts            legacy, single
GET    https://api.groupme.com/v4/read_receipts        current
POST   https://api.groupme.com/v4/read_receipts        batch
POST   https://api.groupme.com/v4/read_receipts/{conversationId}
       { "last_read_message_id": "..." }
POST   https://api.groupme.com/v4/conversations/mark_all_read
```

## Pinning

```
POST https://api.groupme.com/v3/conversations/{conversationId}/messages/{messageId}/pin
POST https://api.groupme.com/v3/conversations/{conversationId}/messages/{messageId}/unpin
GET  https://api.groupme.com/v3/pinned/groups/{groupId}/messages
GET  https://api.groupme.com/v3/pinned/direct_messages?other_user_id={userId}
```

Pinned state also rides on the message object itself as `pinned_at` and `pinned_by`.


## Subgroups (topics)

A group may contain topics, which the API calls subgroups. They are conversations in every
way that matters, and they are close to invisible unless you go looking:

- They never appear in `GET /v3/groups`. Sampled across 20 groups, 0 of 6 topics showed up.
- `GET /v3/groups/{topicId}` answers **404**. A topic is not readable as a group.
- `GET /v3/groups/{parentId}/subgroups` is the only listing. `?include=unread_count` works.
- Their messages *are* read and written at the ordinary group routes:
  `GET /v3/groups/{topicId}/messages` answers 200.

`children_count` on the parent group is how you know to ask, and it is worth honouring: almost
no group has topics, so gating on it turns one request per conversation into one request per
account.

A topic carries its own `unread_count`, `last_read_message_id`, `muted_until`, `like_icon` and
`message_edit_period`, plus:

| field | meaning |
| ----- | ------- |
| `id`, `parent_id` | **numbers**, not strings, unlike every other id in this API |
| `topic` | the name. There is no `name` field |
| `type` | `announcement` or `private` |

`type` is the posting rule. `announcement` means admins and the owner only; `private` means
anybody in the parent group. Roles live on the *parent's* member list (`owner`, `admin`,
`user`), since a topic has no membership of its own.

Observed on a live group with `children_count: 6` — three `announcement` topics (rules,
announcements, confirmed kills) and three `private` ones.
