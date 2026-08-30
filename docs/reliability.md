# Reliability on bad networks

This is the part of the app worth rebuilding. What follows is what the client actually does
on a weak connection, why it fails the way it does, and what a replacement should do instead.

Everything in the "what the app does" sections is read from the decompiled source. The
"what to do instead" sections are design recommendations, not observed behavior.

## What to do instead

Ordered by expected impact per unit of work. The evidence for each is below.

1. **Outbox with automatic drain on reconnect.** `WorkManager` + `NetworkType.CONNECTED` +
   exponential backoff, keyed on `source_guid`. The server's 409 makes this safe.
2. **One sane default retry policy.** ~25 s budget, exponential with full jitter, retry on
   transport errors and 408/429/5xx, honor `Retry-After` when present.
3. **Negotiate every Faye transport**, not just WebSocket. One-line change, and it is the
   difference between "realtime works on school wifi" and "realtime silently never works".
4. **Catch-up sync on `after_id` with `limit=200`.** Gap-free and half the round trips.
   Never `since_id`.
5. **Measured connection quality**, not a 2G string comparison, driving timeouts and page
   sizes.
6. **Resumable media upload** on the Azure blob path.
7. Keep the Faye connection but treat it as an optimization, never as the source of truth.
   Reconcile against a real sync on every foreground.

Conditional requests are off the table: the server exposes no `ETag` or `Last-Modified`, so
there is no validator to send. Cache on time and on push events instead.

## The headline number

193 classes directly extend the app's two request base classes, `BaseRequest` and
`BaseAuthenticatedRequest`. Nine of them get a retry policy. The other 184 inherit Volley's
`DefaultRetryPolicy()`:

```java
new DefaultRetryPolicy(2500, 1, 1.0f)   // timeout 2500 ms, 1 retry, backoff multiplier 1.0
```

Read Volley's `retry()` before believing the multiplier means what it looks like:

```java
this.mCurrentTimeoutMs = i + ((int) (i * this.mBackoffMultiplier));
```

The new timeout is `t + t*multiplier`, so `1.0f` **doubles** it. A flat policy would need
`0.0f`. The default therefore gives two attempts of 2.5 s and 5 s: a **7.5-second** budget,
not five seconds, and it does back off.

That is still tight. Two attempts and 7.5 seconds is a reasonable ceiling for a fast network
and a coin flip on a congested cell. There is no jitter anywhere, so every client that
retries does so in lockstep.

The nine exceptions. Budget is the sum of the per-attempt timeouts, with attempts equal to
`maxRetries + 1`:

| Class | Policy | Budget |
| --- | --- | --- |
| `AddMemberResultsRequest` | `(2500, 5, 2.0f)` | ~910 s across 6 attempts |
| `ContactsBatchResultRequest` | `(30000, 1, 1.0f)` | 90 s |
| `CallingRepository` disconnect ×2 | `(5000, 2, 1.0f)` | 35 s |
| `HeartbeatProcessor` | `(5000, 2, 1.0f)` | 35 s |
| `GroupSuggestionsRequest` | `(10000, 1, 1.0f)` | 30 s |
| `BlockUserRequest` | `(7000, 1, 1.0f)` | 21 s |
| `SendCopilotMessageRequest` | `(10000, 0, 1.0f)` | 10 s, no retry |
| `ConfirmAgeRequest` | `(0, -1, 1.0f)` | no retry, and see below |
| attested requests (in `OkHttp3Stack`) | `(5000, 0, 1.0f)` | 5 s, **no retry** |

Six set their own policy; three (`CallDisconnectRequest`, `DMCallDisconnectRequest`,
`CallHeartbeatRequest`) have it set by the caller. Adding members and importing contacts got
the careful treatment. Sending a message did not.

`ConfirmAgeRequest` deserves its own line: a timeout of `0` reaches
`OkHttp3Stack.getClientWithTimeout(0)`, and OkHttp reads zero as **no timeout**. That request
can hang forever.

The attested-request row is the sharp edge. In `OkHttp3Stack`, a request carrying Play
Integrity headers has its retry policy overwritten to zero retries:

```java
if (z2) {
    request.setRetryPolicy(new DefaultRetryPolicy(5000, 0, 1.0f));
}
```

`OkHttp3Stack` does this, not the request class, so it silently overrides whatever the
request asked for, and because it runs inside `executeRequest` it also resets any grown
timeout on every attempt. It fires when the request is a `com.groupme.net.Request` with a
non-null `TokenData` carrying at least one token. The attestation token is probably
single-use, which would explain it. The effect either way: the app's most security-sensitive
calls are its most fragile.

Outside this list, `com.android.volley.toolbox.ImageRequest` sets `(1000, 2, 2.0f)`, which
governs every image load in the app.

**The fix is one retry policy, applied by default**, with real exponential backoff and full
jitter: a 20 to 30 second budget for interactive reads, much longer for background sync,
retrying on connection errors and on 408/429/5xx. Never retry a non-idempotent write without
an idempotency key. GroupMe gives you one.

## "Slow network" detection is 2G-only

```java
public static final boolean isSlowNetwork() {
    return Intrinsics.areEqual(getCellularNetworkType(), CellularSubType.Cellular2G.getValue());
}
```

That is the entire adaptive-networking story. And the one thing it changes is the socket
send buffer during media uploads: 512 KB normally, 1 KB on 2G
(`MediaUpload.sendBufferSize` / `slowNetworkSendBufferSize`).

Nothing measures actual throughput or latency. A 4G connection at one bar behind a
congested tower is treated identically to fiber-backed wifi. LTE with 40% packet loss reads
as "fast".

**Measure instead.** Keep an exponentially-weighted moving average of request latency and
success rate per host. Feed that into timeout selection, page size, image resolution, and
whether to prefetch at all. `NetworkCapabilities.getLinkDownstreamBandwidthKbps()` is a
starting hint, but observed request latency is the honest signal.

## Failed sends do not retry themselves

Message send status is an integer column, `messages.send_status`, from
`com.groupme.model.Message.Status`:

| Value | Name |
| --- | --- |
| 0 | `Failed` |
| 1 | `Sending` |
| 2 | `Sent` |
| 3 | `EditFailed` |
| 4 | `EditSending` |
| 5 | `EditSent` |
| 6 | `PermanentFailure` |
| 7 | `ContentBlocked` |

When a send fails, the app writes `Failed`, raises a `MessageFailedNotification`, and stops.
Every path back is a user tap: the notification action (`RetryMessageReceiver`), the in-chat
retry affordance (`ChatFragment.onMessageRetryClicked`), the error-tap dialog, and the media
carousel's retry.

There is exactly one automatic background action on the outbox and it runs the wrong way.
`MessageUtils.failPendingMessages` flips any `Sending` row older than 120 seconds to
`Failed`, and `ConversationUtils` flips all `Sending` rows to `Failed` wholesale on startup.
The app has a sweep. It gives up rather than retrying.

The app *does* watch connectivity, through `NetworkStateAwareFragment` and
`NetworkStateAwareListFragment`. Regaining a connection can trigger a *conversation* sync,
though only on the conversation list and only when a calling flag happens to be on; see
[offline.md](offline.md#what-the-app-does-today). None of it touches the outbox. There is no
`Worker`, sync adapter, or `JobScheduler` anywhere in the app that retries a failed send.

This is the biggest single win available in a rebuild. Type a message in a tunnel, come out
the other side, and it sits there greyed out until you happen to notice.

**Build a real outbox.** Persist the queued message with its `source_guid`, enqueue a
`WorkManager` job with `NetworkType.CONNECTED` and exponential backoff, and let the platform
handle the wake-up. The app already does exactly this for read receipts, so the pattern is
sitting in the codebase. It was just never applied to sending.

## Sends are idempotent, so retry freely

`PostMessageRequest.parseNetworkError` has this:

```java
if (i2 == 409) {
    markDuplicateAsSent();
    return null;
}
```

The server returns **409 Conflict** when a `source_guid` is reused, and the client treats
that as success. So `source_guid` is a genuine idempotency key and aggressive client-side
retry of a send is safe: worst case you get a 409 and mark it sent.

One gap: the 409 body is not parsed, so a client that retries into a 409 knows the message
landed but does not learn its server-assigned message id. You have to resync the conversation
to pick it up.

Other send outcomes worth handling:

| Status | Meaning |
| --- | --- |
| `409` | duplicate `source_guid`, already sent, treat as success |
| `422` | message rejected, "links not allowed" |
| `403` + meta `45018`/`45019` | assistant DM not permitted |

## Read receipts get the treatment everything should have

`ReadCursorManager` and `ReadReceiptSyncWorker` are the well-built corner of the app. Local
rows carry an `is_synced_to_server` flag, unsynced cursors are collected with a plain SQL
predicate, and a `WorkManager` job with `NetworkType.CONNECTED` and 10-minute exponential
backoff drains them. (`UnreadSyncConfig.batchSize` is declared as 50 but has no readers, so
the drain is unchunked.)

It even handles rate limits properly: a 429 schedules a separate unique work request,
`unread_batch_sync_429_retry`, with a 1-hour initial delay and 1-hour exponential backoff.

There is also random jitter on enqueue (`migrationJitterMinutes`, default 1440;
`postMigrationJitterMinutes`, default 60) to avoid stampeding the server after a client
rollout.

**This is the model.** Dirty flag in the database, scheduled drain, backoff-aware, jittered.
Apply it to sends, likes, pins, mutes, and profile edits.

With the same caveat as the sync engine below: `UnreadSyncConfig.enabled` also defaults to
false.

## Conversation sync has a real engine, switched off

`ConversationSyncWorker` and friends are a proper sync engine: expedited `WorkManager`,
`NetworkType.CONNECTED` constraint, unique work name `conversation_sync_all` with
`REPLACE` policy, parallel group and chat streams, page size 100, at most 100 pages per
stream (`ConversationSyncPolicy.maxPagesPerStream`), and a sane retry config:

and a retry config that is actually sane: 2 retries, backoff 2.0, 500 ms jitter, over a
sensible set of retryable codes (see [errors.md](errors.md#what-to-retry)).

Two catches. `SyncConfig.useConversationSyncEngine` defaults to **false**, and even when on,
`ConversationSyncEngineRouting` only routes through the engine when the sync source is
`LOGIN` or `EMPTY_CHAT_REPAIR`. The expedited flag is
`OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST`, so it degrades under quota, and the
network constraint is set only on the full-sync enqueue: `enqueueSingle` and
`enqueueCallStateSync` carry no constraints at all.

## Message history only pages backwards

The client only ever sends `before_id`. It has no forward-pagination path, so catching up
after time offline means refetching the newest page and diffing locally. On a thin
connection that is a wasted round trip of mostly-known data.

It does not have to. `after_id` works and pages forward gap-free, and `limit` goes to 200
rather than the 100 the app sends. Use `after_id`, never `since_id`, for reasons measured in
[verified.md](verified.md#forward-pagination-works-and-the-two-parameters-are-not-interchangeable).

## The push connection has no fallback

`BayeuxClient.sendHandshake()` offers the server exactly one transport:

```java
JSONArray jSONArray = new JSONArray();
jSONArray.put("websocket");
```

The server supports six ([verified](verified.md#the-push-server-supports-six-transports-the-android-app-offers-one)).
So where WebSocket is blocked or mangled, the app does not degrade to polling. It goes quiet
until FCM happens to deliver something.

**Offer every transport** and let Faye downgrade. Treat transport loss as an expected
condition with a reconnect budget, not a fatal error.

## Media upload tuning

| Setting | Default |
| --- | --- |
| `connectTimeoutSeconds` | 60 |
| `readTimeoutSeconds` | 60 |
| `writeTimeoutSeconds` | 0, which OkHttp reads as **no write timeout at all** |
| `sendBufferSize` | 524288 |
| `slowNetworkSendBufferSize` | 1024 |
| `videoServicePollTimeoutSeconds` | 300 |

Note the asymmetry: uploads get a 60-second read timeout while ordinary API calls get 2.5.
Somebody knew the default was too tight and fixed it only where uploads were visibly
breaking. The write timeout of 0 is worse than the doc-comment reading suggests, because
`Network.getClientWithTimeOuts` guards on `>= 0` and therefore calls `writeTimeout(0)`
explicitly, which OkHttp treats as infinite.

There is no chunked or resumable upload anywhere. A video upload that dies at 90% starts
over. The media v2 path hands out an Azure Blob SAS URL
(see [uploads.md](uploads.md)), and Azure blob supports block-level uploads with
`comp=block`/`comp=blocklist`, so resumable uploads may be achievable on that path without
any GroupMe cooperation. Untested: it depends on what the SAS actually grants.

## Caching

Volley's `DiskBasedCache` lives at `<cacheDir>/volley` and is on by default; only 12 request
classes opt out with `setShouldCache(false)` (sends, login, and most of the discovery
surfaces).

`BaseRequest.parseNetworkResponse` contains a curious fallback: when a response carries
`Access-Control-Max-Age` but no `Cache-Control`, it synthesizes one from the CORS preflight
header.

```java
if (headers.containsKey("Access-Control-Max-Age") && !headers.containsKey("Cache-Control")) {
    headers.put("Cache-Control", "max-age=" + headers.get("Access-Control-Max-Age"));
}
```

In practice it never fires: v3 does send `Cache-Control`, and the server offers no validator
to revalidate against ([verified](verified.md#cache-headers-a-correction)). Caching has to be
time-based or push-driven, which makes the transport question above matter more, not less.
