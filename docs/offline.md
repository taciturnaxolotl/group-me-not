# Is this API good enough for an offline-first client?

Short answer: **yes for writes, adequate for catch-up, and cheap while connected.** You can
build a genuinely good offline client directly against it. The one thing the API cannot do
for you is tell you what you missed while you were gone.

This is design analysis, not measurement. Claims about the API's shape are sourced; the
byte-cost estimates are marked as estimates.

## Writes: the good news

`source_guid` is a real idempotency key. Reuse one and the server answers `409`, which means
the original landed. That single property is what makes an offline outbox safe: you can
replay a queued send blindly on reconnect without risking duplicates, which is the hard part
of offline messaging and the part most APIs get wrong.

Two caveats.

**The 409 carries no body.** You learn the message landed, not its server id. You need a
reconciling read afterwards to stitch your local row to the real message. Cheap, but it means
"send succeeded" is two round trips in the retry case.

**Only messages have a key.** Likes, pins, mutes, and read receipts have no dedup token. In
practice most are safe anyway because they *set state* rather than increment it: `like` /
`unlike`, `pin` / `unpin`, `mute` / `unmute` are all idempotent by construction, so replay
converges. The genuinely unsafe replays are creates: create group, create poll, add member.
Queue those with a client-side guard, or accept that they need connectivity.

## Catch-up: adequate, with one structural gap

**There is no global delta endpoint.** No `/changes?since=`. The nearest thing is
`/v4/relationships?since=`, which shows the pattern exists in their vocabulary but was never
extended to conversations.

What saves it is that the two conversation-list endpoints already carry enough to compute
what changed:

```
GET /v3/groups?omit=memberships&per_page=100   ->  messages.last_message_id, messages.count,
                                                    last_message_created_at, preview
GET /v3/chats?per_page=100                     ->  last_message (a full Message object),
                                                    last_read_message_id, unread_count
```

So the sync is:

1. Two calls (plus pages) to list conversations.
2. Diff each `last_message_id` against your local head.
3. For each conversation that moved, one `after_id` call at `limit=200`.

Fan-out is proportional to **conversations that changed**, not conversations you have. After
an hour offline that is usually two or three. After a week it is most of them.

Better still: the chats list embeds the *entire* last message, and the groups list embeds a
`preview`. If a conversation advanced by exactly one message, you already have it and can
skip the follow-up entirely. That is a meaningful saving on the common case of "phone woke
up, three chats have one new message each": three conversations changed, zero message calls.

`after_id` paging is gap-free and ordered ascending, so resuming a partial catch-up is just
"keep going from the last id you stored". No cursor state to persist beyond a message id per
conversation.

## Repeat cost

**No validators.** No `ETag`, no `Last-Modified`, on any endpoint. So a conversation-list poll
that finds nothing changed still costs a full conversation list. You cannot `304`. That is
the recurring tax on every foreground, every reconnect, every pull-to-refresh.

**The conversation list is not filterable.** No `?since=` on groups or chats, no
`?fields=`. `omit=memberships` is the only lever, and it is a big one: a group object with
several hundred `members` entries dwarfs everything else in the payload. Always send it, then
fetch members per conversation on demand.

**Estimated costs**, unmeasured, from field counts and typical shapes:

| Call | Rough size |
| --- | --- |
| `/v3/groups?omit=memberships`, ~20 groups | tens of KB |
| the same without `omit` | possibly 10× that |
| `/v3/messages?limit=200` | ~100 KB |
| a reconnect reconcile, nothing changed | two full conversation lists, no `304` available |
| Faye idle, per ~9.5 minutes | one WebSocket ping frame |

Worth measuring properly before optimizing. I did not.

**But you should not be polling at all.** The primary transport is a WebSocket
(`wss://push.groupme.com:443/faye`), and while it is up, `/user/{id}` tells you what changed.
Idle cost is one Bayeux ping every `advice.timeout - 30s`, which at the observed 600000 is a
ping roughly every 9.5 minutes. That is effectively free.

So the missing `ETag` only bites on the calls a connected client does not make. It matters on
cold start and on reconnect, not on a steady-state refresh, because a correctly built client
has no steady-state refresh.

## REST catch-up cannot see edits or deletions

This one is easy to miss and it undercuts the tidy `after_id` story above.

`after_id` returns messages whose id is greater than the anchor. An edit does not change a
message's id, and neither does a delete. So forward paging never revisits anything you
already have, and **an edit or deletion of an older message is invisible to a REST-only
catch-up.** Your local copy keeps showing the pre-edit text forever.

The objects carry the information (`Message.updated_at`, `deleted_at`, `deletion_actor`), but
nothing lets you query on it. There is no `updated_since` anywhere in the API; the only
`since=` parameter is on `/v4/relationships`.

The one partial signal is `messages.last_message_updated_at` in the group list, which tells
you if the *newest* message changed. An edit fifty messages back produces nothing.

So the only ways to learn about an edit are:

- receive the live `message.update` / `message.deleted` event, which you missed by being
  offline, or
- refetch history you already have and diff `updated_at`, which is exactly the expensive
  thing you were avoiding.

This is the strongest argument for a relay, and a better one than replay-in-general: a
process that stays connected sees those events, and nothing else can recover them.

## The real gap: Faye has no replay

This is the structural problem for an offline client, and it is not the one I first reached
for.

Bayeux has an optional `ack` extension that lets a reconnecting client say "I last saw event
N, send me the rest". GroupMe's client does not use it. `BayeuxClient` sends only
`{"access_token": ...}` in `ext`, and the one `acknowledge()` method in the codebase just
matches a subscribe response to its pending subscription by `clientId`. On reconnect,
`onBayeuxHandshakeComplete` simply re-subscribes to `/user/{id}`.

**Anything published while you were disconnected is gone.** The socket does not replay it,
and there is no "events since" endpoint to ask instead.

That is exactly the offline case. Which means:

- While connected: the WebSocket is cheap, complete, and you need almost no REST.
- Across a disconnect: you have no idea what you missed, so you must reconcile through the
  REST list-and-diff described above, every single time.

**The server does not support it either.** Tested directly (see
[verified.md](verified.md#the-ack-extension-is-not-enabled)): a handshake carrying
`ext: {"ack": true}` comes back with no `ext` at all, and a `/meta/connect` carrying
`ext: {"ack": 0}` likewise returns no `ext` counter. With the extension enabled, Faye echoes
an ack counter on every connect response.

So there is no replay to be had at any layer of the stack as it ships. If you want it, you
have to build it.

## Verdict on a middle layer

**Do not start with one.** Build the direct client first. The four fixes in
[reliability.md](reliability.md) get you most of the way, and the API's idempotency means
the hard correctness problem is already solved for you.

Reasons to resist:

- A proxy must hold the user's access token. That is a real liability for a personal project,
  and a much worse one if other people use it.
- It becomes a hard dependency. Direct clients degrade to "slow" when things go wrong; a
  client behind a dead proxy is simply dead.
- It is always-on infrastructure to run and pay for.
- Faye already gives you cheap idle, and the two-call diff already bounds fan-out.

Reasons a middle layer would genuinely help, in order of actual value:

1. **Replay across a disconnect**, and with it edit and delete tracking. The relay holds the
   Faye socket while your phone is dark, buffers what arrives, and hands it over on
   reconnect. Replay of new messages is a convenience, since `after_id` can recover those.
   Replay of `message.update` and `message.deleted` is a capability, because as shown above
   REST cannot recover those at all. Design sketch in [relay.md](relay.md).
2. **Conditional requests.** The proxy caches the conversation list, computes its own `ETag`,
   and answers an unchanged fetch with a `304`. Smaller than it first looks, since a connected
   client barely fetches the list, but it still helps the cold-start and reconnect paths.
3. **Field stripping.** Return only what your UI renders. Message objects carry a lot of
   fields most clients never touch.
4. **One upstream identity.** Rate limits apply to the proxy's request pattern, which you
   control, instead of to N devices retrying independently.

Note what is *not* on that list: reliability of sends. That is already solved by
`source_guid`, client-side, with no server needed.

If you do build one, note that reason 1 forces a shape: buffering events while the client is
away means holding the socket, which means holding a credential at rest. There is no stateless
version of that. The honest minimum is a small service that keeps one Faye connection per
user and a bounded ring buffer of events, exposes "give me everything after event N", and
proxies nothing else. The client still talks to GroupMe directly for reads and writes and
falls back to list-and-diff whenever the service is unavailable, so the failure mode stays
soft.

That is a much smaller thing than a general proxy, and it is the only part that earns the
trust cost.

## What the app does today

Worth knowing before you design a replacement, because the answer is "it delegates".

**Faye is foreground-only.** The keepalive runnable in `FayeService` checks
`UIVisibility.isVisible()` on every tick. If the app is not on screen and no call is in
progress, it disconnects, shuts the client down, and stops the service:

```java
if (UIVisibility.isVisible() || mCallingRepository.isCallInProgress()) {
    mBayeuxClient.connect();
    mHandler.postDelayed(this, mPingInterval);
} else {
    mBayeuxClient.disconnect();
    mBayeuxClient.shutdown();
    stopSelf();
}
```

Teardown is lazy, at the next tick, so the socket lingers up to `advice.timeout - 30s` after
you background the app.

**FCM is the replay mechanism.** Once Faye is gone, delivery is Firebase, and
`GroupMeFcmListenerService` responds to a push by calling
`requestConversationSync(..., "fcm_push")`. Because FCM does store-and-forward, that is
effectively the app's answer to "what did I miss": Google holds the notification, delivers it
when you reconnect, and the app then does the REST list-and-diff.

It works, and it explains why the missing `ack` extension has never hurt them. It also means
a device without Play Services has essentially no catch-up path at all.

**Nothing syncs on Faye reconnect.** `onBayeuxConnect` is empty and
`onBayeuxHandshakeComplete` only re-subscribes. A socket drop and recovery triggers no
catch-up by itself.

**The full list of sync triggers**, all routing through `requestConversationSync`:

| Trigger | Source |
| --- | --- |
| `foreground` | app returns to the conversation list |
| `screen_on` | `ACTION_SCREEN_ON` broadcast |
| `pull_to_refresh` | manual |
| `sync_retry` | after a failed sync |
| `connection_restored` | connectivity regained, **but see below** |
| `fcm_push` | a Firebase push arrived |
| `registration`, `social_login`, `onboarding`, `widget`, `five_or_die` | one-off |

**`connection_restored` is gated behind a calling flag.** This looks like an accident:

```java
public void onConnectionAvailable() {
    boolean wasAvailable = getIsNetworkAvailable();
    super.onConnectionAvailable();
    if (!CallingUtils.isCallingEnabledOnConversationList() || wasAvailable) return;
    startConversationSync(..., "connection_restored");
}
```

`isCallingEnabledOnConversationList()` is
`callingAndMeetingSettings.enabled && groupCalling.l1Enabled`. So whether regaining
connectivity refreshes your conversation list depends on whether **group calling** is turned
on for you. Nothing about the sync needs calling; the check simply sits in front of it.

**In-chat reconnect barely does anything.** `ChatFragment.onConnectionAvailable` refetches
only when the adapter holds zero messages, or when pagination had already failed:

```java
if (adapter != null && adapter.getMessageCount() == 0 && mInitialMessageRequestFinished) {
    syncMessages();
} else if (paginateSyncFailed) {
    loadMessages();
}
```

Sit in a conversation that already has messages, lose signal, get it back: nothing refetches.
You look at stale content until you navigate away and return.

Taken together, the app has no replay of its own. It has FCM, a foreground sync, and a
reconnect path that is switched off unless an unrelated feature is enabled.

## The sync loop worth building

```
on foreground / reconnect:
    1. drain the outbox           (retry queued sends by source_guid, 409 = success)
    2. GET /v3/groups?omit=memberships   +  GET /v3/chats
    3. for each conversation whose last_message_id moved:
           if it advanced by exactly one and the list gave you that message: use it
           else: GET .../messages?after_id={localHead}&limit=200, paging until short
    4. GET /v4/read_receipts      (reconcile read state)
    5. reconnect Faye, offering every transport

while connected:
    apply Faye events as they arrive; the socket is cheap and complete
    no polling: an idle connection costs one ping per ~9.5 minutes

on every reconnect:
    run the whole loop again. Faye does not replay what you missed,
    so the REST diff is the only way to close the gap.
```

Everything above works against the API as it is today. No middle layer required.
