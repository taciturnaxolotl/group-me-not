# Realtime push

GroupMe's realtime layer is [Faye](https://faye.jcoglan.com/) speaking the
[Bayeux](https://docs.cometd.org/current/reference/#_bayeux) protocol over a WebSocket. The
client implementation is `com.groupme.bayeux.BayeuxClient`, driven by
`com.groupme.android.push.FayeService`.

```
wss://push.groupme.com:443/faye
```

## Handshake

Standard Bayeux. Outgoing frames are a bare JSON **object**; inbound frames are arrays. `id`
is a fresh UUID per message, not a counter.

```json
{
  "channel": "/meta/handshake",
  "version": "1.0",
  "supportedConnectionTypes": ["websocket"],
  "id": "3f2a…"
}
```

The server replies with a `clientId`, which every subsequent message must carry.

That `supportedConnectionTypes` array is the app's, and it is a mistake to copy: the server
supports six transports, and offering only `websocket` means no realtime wherever WebSocket
is blocked. Offer all six and let Faye downgrade. List and measurements in
[verified.md](verified.md#the-push-server-supports-six-transports-the-android-app-offers-one).

Then connect:

```json
{ "channel": "/meta/connect", "clientId": "<id>", "connectionType": "websocket", "id": "a91c…" }
```

## Authentication

Auth rides in the Bayeux `ext` field, attached to outgoing messages by
`BayeuxClient.mExt`:

```json
{ "ext": { "access_token": "<X-Access-Token value>" } }
```

Same token as the REST API. There is no separate push credential.

`ext` is attached to subscribe, unsubscribe, and publish only. `BayeuxClient` explicitly
excludes `/meta/handshake`, `/meta/connect`, and `/meta/disconnect`, so the handshake itself
is unauthenticated.

## Channels

Subscribe with `/meta/subscribe` and a `subscription` field.

| Channel | Carries |
| --- | --- |
| `/user/{userId}` | everything addressed to you: new DMs, group invites, membership changes, typing, presence |
| `/group/{groupId}` | messages and events in one group |
| `/direct_message/{a}_{b}` | one DM thread, ids joined by an **underscore**, smaller first |
| `/copilot/session/{userId}/{sessionId}` | streaming assistant responses |

The underscore is the trap: everywhere else the same id joins with `+`. See
[conventions.md](conventions.md#conversation-ids).

The app subscribes to `/user/{id}` for the whole session and adds a `/group/` or
`/direct_message/` subscription only for the conversation currently on screen. That is a
client policy, not a server requirement.

## No replay

Bayeux has an optional `ack` extension for resuming a stream. This client does not use it:
`ext` carries only the access token, and the sole `acknowledge()` method matches a subscribe
response to its pending subscription by `clientId`. On reconnect,
`onBayeuxHandshakeComplete` just re-subscribes.

**Events published while you were disconnected are lost.** The server does not offer the
extension either: a handshake or connect carrying `ext: {"ack": ...}` comes back with no
`ext` field ([verified](verified.md#the-ack-extension-is-not-enabled)). Close the gap with a
REST reconcile; see [offline.md](offline.md).

Keepalive is a ping every `advice.timeout - 30000` ms, so an idle socket at the observed
600000 costs one frame roughly every 9.5 minutes.

## Message envelope

Payloads arrive under the Bayeux `data` field, modelled by `com.groupme.api.FayeMessage`.
`FayeMessage.Data` is `{ "subject": <object>, "user_id": "..." }`, and a sibling `type`
string selects how `subject` is parsed. `subject` holds the affected object in the same
shape the REST API returns it.

The main dispatch method in `FayeService` did not decompile (it is a 1232-instruction
switch), so the mapping from `type` to payload class is not fully recoverable statically.

Three separate type vocabularies exist and it is easy to conflate them. They are not
interchangeable:

**1. Faye envelope types.** The only `type` literals actually in `FayeService`:

- `favorite`, `like.delete`, `typing`

**2. FCM data-message types**, in `GroupMeFcmListenerService`, used when the app is
backgrounded:

- `line.create` (a new group message), `direct_message.create`, `direct_message.request`,
  `reaction`, `direct.call.missed`, `group.call.started`

**3. System-message event types**, carried as `event.type` on an ordinary message object with
`system: true`, and rendered inline in the transcript. These arrive through either transport
as part of the message, not as a push envelope type. Handled in `SystemViewHolder` and
`MessageProcessor`:

- Messages: `message.update`, `message.deleted`, `message.pinned`, `message.unpinned`
- Membership: `membership.announce.joined`, `.added`, `.rejoined`, `.coco.added`,
  `membership.notifications.removed`, `.exited`, `.admin.new_pending_user`
- Group settings: `group.name_change`, `group.avatar_change`, `group.topic_change`,
  `group.topic_removed`, `group.owner_changed`, `group.type_change`,
  `group.role_change_admin`, `group.shared`, `group.unshared`,
  `group.visibility_set.{searchable,hidden,community}`,
  `group.office_mode_{enabled,disabled}`, `group.requires_approval_{enabled,disabled}`,
  `group.like_icon_set`, `group.like_icon_removed`,
  `group.chat_theme_settings_change`, `group.chat_theme_settings_removed`
- Topics: `group.subgroup_created`, `group.subgroup_removed`, `group.subgroup_name_change`,
  `group.subgroup_description_change`, `group.subgroup_description_removed`,
  `group.subgroup_avatar_change`, `group.subgroup_type_change`,
  `group.subgroup_like_icon_change`, `group.subgroup_attribute_change`
- Polls: `poll.reminder`, `poll.finished`
- Calls: `group.call.started`, `group.call.ended`

Typing is the one thing the client *publishes*, to the group or DM channel:

```json
{ "data": { "type": "typing", "user_id": "<me>", "started": 1730000000000 } }
```

`started` is epoch milliseconds. Two timings matter and neither is negotiated, so a client
that picks different ones will look wrong to everyone else:

- **Publish** on every keystroke, throttled to at most one per **1000 ms**
  (`InputBarFragment.mLastTypingNotificationSentAt`).
- **Expire** a received indicator **1500 ms** after the last event for that user; a new event
  resets the timer (`ChatFragment.TypingPerson`).

There is no "stopped typing" event. The indicator disappears by timeout only. Whether the
server echoes your own typing back is untested; the app filters on `user_id` regardless.

## Firebase fallback

When the app is backgrounded, delivery moves to FCM. Registration is a separate REST call:

```
POST https://v2.groupme.com/push_registrations
Content-Type: application/json
X-Access-Token: <token>

{ "push_registration": { "service": "google_cloud_messaging", "registration_id": "<FCM token>" } }
```

Deregister with:

```
POST https://v2.groupme.com/push_registrations/destroy

{ "registration_id": "<FCM token>" }
```

Note the asymmetry: register nests under `push_registration`, destroy does not.
