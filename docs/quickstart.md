# The minimum viable client

Everything a client has to do, in order, with links to the detail. If you read one file
first, read this one.

## Getting a token

You probably do not need to implement login.

The API authenticates on the token value alone. I confirmed a session token works as
`X-Access-Token` against v1, v3, and v4; the personal token from
[dev.groupme.com](https://dev.groupme.com) is the same 40-character shape and the published
docs accept it as `?token=`, so it should work in the header too. I did not test a dev token
specifically.

Implement the password flow in [auth.md](auth.md) only if you need users to sign in inside
your own app. That is where the hardcoded pre-login hash comes in, and it exists solely to
authenticate the `POST /access_tokens` call itself. It is not needed for any other endpoint.

```
X-Access-Token: <token>
```

## 1. Register an installation (optional but polite)

```
POST https://api.groupme.com/v3/installations
{ "installation": { "client_id": "<uuid you generate once>", "platform": "Android", ... } }
```

Full body in [auth.md](auth.md#installation-records). Skip it if you are not doing push; nothing
else depends on it.

## 2. Who am I

```
GET https://api.groupme.com/v3/users/me
```

You need your own user id for two things: DM conversation ids, and the `/user/{id}` push
channel. Cache it.

## 3. List conversations

Two calls, because groups and DMs are separate endpoints:

```
GET https://api.groupme.com/v3/groups?per_page=100&page=1&omit=memberships
GET https://api.groupme.com/v3/chats?per_page=100&page=1
```

Both are offset-paged. Page until a short page comes back; the app caps at 100 pages.

`omit=memberships` is the one real payload-size lever here. A group's member list can be
hundreds of entries and you almost never need it in a conversation list. Omit it, then fetch
members per-conversation when someone opens one.

Groups with topics (subgroups) need one extra call each:

```
GET https://api.groupme.com/v3/groups/{groupId}/subgroups
```

Nice-to-haves the app and web client both fetch here: `/v4/pinned_conversations`,
`/v4/read_receipts`, `/v4/relationships?limit=200` (cursor-paged), `/v3/directories`.

## 4. Subscribe to push

Connect to `wss://push.groupme.com:443/faye`, handshake, then subscribe to `/user/{myId}`.
That one channel carries everything addressed to you.

**Offer every transport in the handshake**, not just `websocket`. The server supports
`long-polling`, `cross-origin-long-polling`, `callback-polling`, `websocket`, `eventsource`,
and `in-process`. The Android app offers only `websocket` and therefore has no realtime at
all on networks that block it. This is the cheapest reliability win available to you.

Auth rides in the Bayeux `ext` field as `{"access_token": "..."}`. Details and the full event
vocabulary in [push.md](push.md).

Treat push as an optimization, never as the source of truth. Reconcile with a real fetch on
every foreground.

## 5. Open a conversation

```
GET https://api.groupme.com/v3/groups/{groupId}?             # or /v3/chats/{conversationId}
GET https://api.groupme.com/v3/groups/{groupId}/messages?acceptFiles=true&limit=200
```

`acceptFiles` is not optional in practice: omit it and document attachments are silently
stripped from the response.

A plain group read already includes members, `unread_count`, `last_read_message_id`, and
`last_read_at`, so you can compute "what did I miss" without a second call. `include=` adds
nothing on a single-group read ([verified](verified.md)).

Page backwards with `before_id`. Page forwards, after being offline, with `after_id`. Never
`since_id`: it returns the newest messages and skips the gap.

## 6. Send a message

```
POST https://api.groupme.com/v3/groups/{groupId}/messages
POST https://api.groupme.com/v3/direct_messages          # recipient goes in the body

{ "message": { "source_guid": "<uuid>", "text": "hello", "attachments": [] } }
```

Generate `source_guid` yourself and **persist it before the request goes out**. It is the
idempotency key: a reused one returns `409`, which means the original send succeeded. That
makes retrying safe, so build the retry.

Attachments reference URLs from the media services, never inline bytes. See
[uploads.md](uploads.md).

## 7. Mark as read

```
POST https://api.groupme.com/v4/read_receipts/{conversationId}
```

Batch these. The server rate-limits them and the app drains them from a dirty-flag queue for
exactly that reason.

## The shape of a client that survives bad networks

The four decisions that matter most, drawn from what the app gets wrong
([reliability.md](reliability.md)):

1. **One default retry policy, applied everywhere.** ~25 s budget, exponential with full
   jitter, retry on transport errors and 408/429/5xx. The app's stock two attempts over
   7.5 seconds, with no jitter, is the single biggest cause of its flakiness.
2. **A real outbox.** Persist queued sends, drain on reconnect via a platform scheduler, key
   on `source_guid`. The app never retries a failed send without a user tap.
3. **Every Faye transport offered**, so realtime degrades instead of vanishing.
4. **`after_id` with `limit=200`** for catch-up, so returning from offline costs one pass
   instead of a refetch-and-diff.

Caching has to be time-based or push-driven. The server exposes no `ETag` or `Last-Modified`,
so conditional requests are not available.
