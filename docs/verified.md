# Verified against the live API

Everything else in this repo is read out of the APK. This page is different: it was measured
against `api.groupme.com` and `push.groupme.com` on **2026-08-30**, and added to on
**2026-09-15**, from an authenticated session in the web client, using read-only `GET`
requests against my own account. Each section says which date it belongs to where it matters.

No writes were performed for the 2026-08-30 pass. The 2026-09-15 additions include one that
did: a message posted to a group of my own and deleted again, with consent, to watch what a
deletion puts on the wire. Nothing touched another user's data.

Where a finding contradicts what the Android app does, the live behavior wins and the
contradiction is called out, because those gaps are exactly where a better client lives.

## Forward pagination works, and the two parameters are not interchangeable

The Android app only ever sends `before_id`. Both forward parameters work on `/v3` message
reads, for groups and DMs alike, and they behave **differently**:

| Parameter | Returns | Order |
| --- | --- | --- |
| `after_id={id}` | the messages **immediately following** the anchor | oldest first (ascending) |
| `since_id={id}` | the **most recent** messages in the conversation | newest first (descending) |

The distinction only shows up when there is a gap. Anchored ~600 messages back in a busy
group and asking for 5:

```
after_id  -> 178759035407904117 … 178760179066284764   (adjacent to the anchor)
since_id  -> 178812440241256031 … 178810958760895101   (the newest 5 in the group)
```

`since_id` jumped the entire gap. **Use `after_id` for catch-up sync.** `since_id` looks like
it works, and silently loses every message in between. That is the bug that would make a
rebuilt client mysteriously miss messages after a long offline stretch.

Confirmed identical on both:

```
GET /v3/groups/{groupId}/messages?after_id={id}&limit=200
GET /v3/direct_messages?other_user_id={userId}&after_id={id}&limit=200
```

DM responses envelope under `direct_messages`, groups under `messages`; both carry a `count`.

## `limit` goes to 200, not 100

The app uses 100 and the published docs say 100. The real cap is 200:

```
limit=200  ->  200 OK, 200 messages
limit=500  ->  400 Bad Request, meta.errors: ["limit must be between 1 and 200"]
```

Straight halving of round trips on a catch-up sync. The error message is also a nice
confirmation that `meta.errors` sometimes carries genuinely useful text.

## The push server supports six transports; the Android app offers one

Handshake against `push.groupme.com/faye` advertises:

```json
{
  "successful": true,
  "version": "1.0",
  "supportedConnectionTypes": [
    "long-polling", "cross-origin-long-polling", "callback-polling",
    "websocket", "eventsource", "in-process"
  ],
  "advice": { "reconnect": "retry", "interval": 0, "timeout": 600000 }
}
```

`BayeuxClient.sendHandshake()` in the Android app puts exactly one entry in that array:

```java
JSONArray jSONArray = new JSONArray();
jSONArray.put("websocket");
```

So on any network where WebSocket is blocked or unreliable (captive portals, school and
corporate wifi, some carrier middleboxes), **the Android app has no fallback and simply gets
no realtime**, while the server would happily serve it over long-polling or SSE. The web
client negotiates all five and lands on JSONP callback-polling.

For a rebuild: offer the full list, let Faye downgrade, and treat transport loss as expected
rather than fatal. `advice.timeout` is 600000, so a long-poll holds for ten minutes.

Note that `push.groupme.com/faye` does **not** allow cross-origin `POST`: a direct POST
returns `503`. The web client uses JSONP `GET` for that reason. A native client using
WebSocket or long-polling is unaffected.

## The ack extension is not enabled

Bayeux's optional `ack` extension would let a reconnecting client ask for the events it
missed. The Android client never requests it, and the server does not offer it.

Handshake with the extension requested:

```
GET /faye?message=[{"channel":"/meta/handshake","version":"1.0",
                    "supportedConnectionTypes":["long-polling"],
                    "ext":{"ack":true},"id":"h"}]&jsonp=cb

-> {"channel":"/meta/handshake","successful":true,"version":"1.0",
    "supportedConnectionTypes":[...],"clientId":"...",
    "advice":{"reconnect":"retry","interval":0,"timeout":600000}}
```

No `ext` in the reply. A server with the extension enabled echoes `ext: {"ack": true}` here.

The behavioural check is stronger than the absence. Sending `ext: {"ack": 0}` on
`/meta/connect`, with `advice: {"timeout": 0}` to force an immediate return rather than a
long poll:

```
-> {"id":"c","clientId":"...","channel":"/meta/connect","successful":true,
    "advice":{"reconnect":"retry","interval":0,"timeout":600000}}
```

Again no `ext`. With the extension on, every connect response carries `ext: {"ack": N}`
carrying the current message counter.

**Consequence: nothing published while you are disconnected can be recovered from the push
layer.** Reconnect means reconciling over REST. See [offline.md](offline.md).

The handshake is unauthenticated, so this is testable without a token. Note also that a
cross-origin `POST` to `/faye` hangs rather than returning promptly; the JSONP `GET` form is
what the web client uses and what answers.

## Cache headers: a correction

I previously wrote that the API sends no `Cache-Control`. That is wrong. The v3 endpoints do:

```
Cache-Control: must-revalidate, private, max-age=0
```

Observed on `/v3/groups/{id}/messages`, `/v3/groups`, and `/v3/users/me`. `/v4/relationships`
sends no cache headers at all.

This matters for reading the Android source: `BaseRequest.parseNetworkResponse` only
synthesizes a `Cache-Control` from `Access-Control-Max-Age` when `Cache-Control` is absent,
so on these endpoints that code path never fires.

`max-age=0, must-revalidate` means "always revalidate", which would be fine if there were
anything to revalidate *with*. There is not:

- no `ETag`
- no `Last-Modified`
- no `Expires`

So conditional requests are genuinely unavailable on v3. My earlier suggestion to add
`If-None-Match` should be dropped: the server offers no validator. Client-side caching has to
be time-based and optimistic, or driven by the push channel.

## No rate-limit headers on normal responses

No `X-RateLimit-*`, no `Retry-After` on any successful response, so you cannot see your
budget before you spend it.

That does not mean 429s are silent. The client's own code shows the server sends
`Retry-After` on at least group-join limits: `JoinGroupRequest.findRetryAfterHeaderValue`
reads the header case-insensitively and converts it to hours. Read it when a 429 arrives, and
fall back to exponential backoff with jitter when it is absent. Details in
[errors.md](errors.md#rate-limiting).

I did not deliberately trip a 429, so which endpoints send the header is untested.

## `include=` is a no-op on single-group reads

A plain `GET /v3/groups/{groupId}` already returns everything:

```
id, group_id, name, phone_number, type, description, image_url, creator_user_id,
created_at, updated_at, expires_at, muted_until, recap_enabled, audio_message_disabled,
messages, max_members, theme_name, like_icon, requires_approval, show_join_question,
join_question, message_deletion_period, message_deletion_mode, message_edit_period,
system_message_settings, children_count, share_url, share_qr_code_url, directories,
members, members_count, locations, visibility, category_ids, active_call_participants,
unread_count, last_read_message_id, last_read_at, bot_settings
```

Adding `?include=members`, `read_receipts`, `unread_count`, `visibility`, or `locations`
changed nothing: all five are already present. I did not test `include` on the list
endpoints, where it may still matter; the app uses `omit=memberships` there to shrink the
payload.

Useful fields the Android client's URLs never hinted at: `last_read_message_id`,
`last_read_at`, and `unread_count` come back for free on a single-group read, which makes
"what did I miss" cheap to compute without a separate read-receipts call.

## v4 cursors are base64 of an id

The web client pages relationships like this:

```
GET /v4/relationships?include_blocked=true&limit=200
GET /v4/relationships?include_blocked=true&limit=200&page=MTE5MjM4OTQ2
GET /v4/relationships?include_blocked=true&limit=200&page=MTQzMzMxNDk2
```

`atob("MTE5MjM4OTQ2")` is `"119238946"`. The opaque cursor is just base64 of the last id in
the previous page. Treat it as opaque anyway, but it is handy to know it is stable and
orderable when debugging.

`include_blocked=true` is a parameter the Android app never sends.

## What the web client loads on cold start

For comparison with the Android sync path, the full first-paint sequence:

```
GET /v4/pinned_conversations
GET /v3/chats?per_page=100&page=1
GET /v3/groups?per_page=100&omit=memberships&page=1
GET /v4/read_receipts
GET /v1/presence/users/{myUserId}
GET /v3/groups/{id}/subgroups          (one per group that has topics)
GET /v3/directories
GET /v4/relationships?include_blocked=true&limit=200   (+ cursor pages)
```

and on opening a conversation:

```
GET /v3/pinned/groups/{groupId}/messages
GET /v3/poll/{groupId}
GET /v3/conversations/{groupId}/events/list?end_at={iso8601}&limit=100
GET /v3/groups/{groupId}/messages?acceptFiles=1&limit=100
GET /v3/groups/{groupId}?include=members
GET /v1/presence/groups/{groupId}/members
GET /v1/urls/preview?url={encoded}     (per link in view)
```

Two small differences from Android worth noting: the web client sends `acceptFiles=1` where
Android sends `acceptFiles=true` (both work), and it fetches static assets from
`groupme.com/assets/…` rather than `cdn.groupme.com/assets/…`.

## Presence can be published but not read

Measured 7 September 2026 against a live account, with a developer token and with the app's
own:

```
PUT  /v1/presence/status  {"status":"online"}     200  {"user_id":"…","status":"online"}
GET  /v1/presence/users/{id}                      401  40102 device_verification_failed
GET  /v1/presence/users?ids={id}                  401  40102
GET  /v1/presence/groups/{id}/members             401  40102
GET  /v1/presence/users/{id}?group_id={groupId}   401  40102
```

The `group_id` the official client sends when a profile is opened from inside a group makes
no difference, and neither does a User-Agent claiming to be GroupMe. The web client gets the
same 401 on its own presence calls, so this is not a matter of which token you hold.

The gate is platform attestation. `ProtectedRequestQueue` fetches a nonce from `/v1/nonce`,
has Play Integrity sign over it, and sends the result as `x-verify-token` and
`x-verify-token-standard` for the client id `com.groupme.android` (see `OkHttp3Stack`). That
is Google or Apple stating that this is *their* app with *their* signing certificate; no
other app can produce one, which is the point of it.

So a third-party client can tell people it is here, and cannot see anybody else. Reading is
not a thing to keep code warm for.

## `deletion_actor` is a role, and an admin delete removes the row

Measured **2026-09-15** across 25 groups, three pages of history each: 128 `message.deleted`
notices and 38 surviving tombstones.

Two claims in [messaging.md](messaging.md) were wrong, both read out of the APK.

**`deletion_actor` is a small role enum, not a user id.** Only three values appeared:

| Value | Notices | Surviving tombstones | Tombstone `text` |
| --- | --- | --- | --- |
| `sender` | 34 | 34 | "This message was deleted" |
| `admin` | 93 | 3 | "An admin deleted this message" |
| `system` | 1 | 1 | "This message was removed" |

The name reads exactly like an id, which is the trap: a client that files it where a user id
belongs ends up with a member called "admin".

**`text` is not cleared, it is rewritten.** The server substitutes its own sentence and
varies it by role, the way it does for every other system string. A client that renders
`text` verbatim gets the right words for free; one that writes its own should match the
vocabulary.

**The 93-against-3 is the finding that changes a design.** A `sender` delete leaves the row
in place as a tombstone, one for one, every time. An `admin` delete usually takes the row
away outright, so a later fetch does not return the message at all and there is nothing left
to mark. A client that was connected when it happened is the only thing that will ever show
a gap there. That makes the live event the sole source of truth for admin deletions, which
is a sharper version of the argument in
[offline.md](offline.md#the-real-gap-faye-has-no-replay): not merely "REST cannot tell you it
changed", but "REST cannot tell you it was ever there".

## The `message.deleted` notice names its target in `event.data`

Same measurement. The notice is an ordinary message with `system: true` and a fresh id of its
own. The id of the message it kills appears only in `event.data`:

```json
{
  "id": "178838685115412207",
  "system": true,
  "text": "A message was deleted.",
  "event": {
    "type": "message.deleted",
    "data": {
      "message_id": "178838673670894433",
      "deleted_at": 1788386851,
      "deletion_actor": "sender"
    }
  }
}
```

This confirms `Message.Event.data` (`LocalizedData`) in [models.md](models.md). It also means
a deletion cannot ride the ordinary "merge this message" path the way an edit can: the id on
the envelope belongs to the announcement, not to the victim.

`message.update` has the same shape, carrying `message_id`, `sender_id`, `updated_at` and the
new `message: {text, attachments}`.

## A delete arrives twice, on two channels

Measured **2026-09-15**, and this one needed a write: a throwaway message posted to a group of
my own and then deleted, with a socket open on both channels. `DELETE` answered `204`.

One deletion produced **two frames**, in the same millisecond, carrying the same fact in two
different shapes:

| Channel | Envelope `type` | `subject` |
| --- | --- | --- |
| `/group/{groupId}` | `message.deleted` | the **victim itself**, already tombstoned |
| `/user/{userId}` | `line.create` | a **system notice** naming it in `event.data` |

The group frame is the better one: same id as the message it replaces, `system: false`, text
already rewritten, and both `deleted_at` and `deletion_actor` on it.

```json
{ "type": "message.deleted", "subject": {
    "id": "178951848400451336", "system": false,
    "text": "This message was deleted",
    "deleted_at": "2026-09-16T00:28:08.0039Z", "deletion_actor": "sender" } }
```

But a client subscribes to `/group/{id}` only while that chat is on screen, and to
`/user/{id}` always. **So the notice is the frame you can count on and the tombstone is the
frame you would rather have.** A client that handles only one of them is wrong half the time,
and which half depends on where the user happens to be looking.

### `deleted_at` is an ISO 8601 string here, and only here

Look again at the tombstone above. Every other delivery of that same timestamp is an integer:

| Where | Value |
| --- | --- |
| REST history | `1788386851` |
| `event.data` on the notice | `1789518488` |
| the pushed tombstone | `"2026-09-16T00:28:08.0039Z"` |

Both forms of the same deletion parse to the same second, so this is presentation, not
disagreement. It still matters, because the failure is quiet in both directions. A strict
decoder throws on the string and drops the whole frame; a permissive one reads `Number(...)`
as `NaN`, which is falsy, and a message that was deleted looks like a message that was not.

`GroupEvent` carries the same warning about its own timestamps, so this is the second place
in the API where one field has two types. Assume it will not be the last.

## Still open

- Which endpoints send `Retry-After` on a 429. Group joins do, per the client source. The
  rest needs deliberately tripping a limit, which I did not do.
- Actual payload sizes. Every byte-cost figure in [offline.md](offline.md) is an estimate
  from field counts, not a measurement.
- Whether `409` on a duplicate `source_guid` returns the original message in its body. Needs
  a write, so it needs your call before I test it.
- The Faye event-type to payload mapping. Partly done now: a send, a delete and a read receipt
  were watched live (above). The rest of the vocabulary in [push.md](push.md) is still read
  out of the APK and unconfirmed, and the measured types already show the decompiled list is
  incomplete.
- Whether an `admin` delete pushes the same two frames a `sender` delete does. Testing it
  needs a second account with admin rights over a message that is not mine.
