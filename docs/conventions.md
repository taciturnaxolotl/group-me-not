# Conventions

Things that hold across almost every endpoint.

## Hosts

The app never hardcodes a full base URL. `com.groupme.android.Configuration` builds one
from a single root host. Only the `com.groupme.android.staging` build uses `groupme-b.com`;
both production and the internal-beta build (`com.groupme.android.internal`) are on
`groupme.com`. Everything else is a prefix on that root.

| Config accessor | Production value | Used for |
| --- | --- | --- |
| `getVersion1Host()` | `api.groupme.com/v1` | search, presence, calling, copilot, places |
| `getVersion2Host()` | `v2.groupme.com` | the oldest surviving endpoints: login, registration, invites, push, memberships |
| `getVersion2NewHost()` | `api.groupme.com/v2` | a small number of calling and matchup endpoints |
| `getVersion3Host()` | `api.groupme.com/v3` | the bulk of the API |
| `getVersion4Host()` | `api.groupme.com/v4` | newer surfaces: relationships, contacts, read receipts, requests |
| `getFayeHost()` | `wss://push.groupme.com:443/faye` | realtime push |
| `getImageServiceUploadURL()` | `https://m.groupme.com` | media upload v2 |
| `getImageServiceBaseUrl()` | `https://image.groupme.com` | image upload and CDN |
| `getVideoServiceUrl()` | `https://video.groupme.com/transcode` | video upload |
| `getDocumentServiceUrl()` | `https://file.groupme.com/v1` | document upload |
| `getGroupMeCdnHost()` | `cdn.groupme.com` | static JSON assets (themes, reactions, majors) |
| `getPowerUpHost()` | `powerup.groupme.com` | sticker packs |
| `getGroupMeWebHost()` | `web.groupme.com` | web views the app opens in a browser |

Note that v2 is two different things. `v2.groupme.com` is the legacy host; `api.groupme.com/v2`
is a newer namespace on the modern host. They are not interchangeable.

## Envelopes

Responses are wrapped:

```json
{
  "response": { "...": "the actual payload" },
  "meta": { "code": 200, "errors": [] }
}
```

`meta.code` repeats the HTTP status. `meta.errors` is an array of strings. The app's
`com.groupme.api.Meta` is exactly `{int code, String[] errors}` and nothing more.

On `401`, the client reads `meta.errors[0]`; when it equals `"unauthorized"` five times in a
row the app wipes local state and logs out. The counter lives in
`BaseAuthenticatedRequest.UnauthorizedCount` and resets on any successful response. It only
increments when the `401` carries `Content-Type: application/json` or `text/plain`, so a
`401` with any other content type never counts toward the logout.

Not everything is enveloped. The v1 and v4 surfaces frequently return bare objects, and the
CDN assets are plain JSON documents.

## Conversation ids

A group conversation id is just the group id. A DM conversation id is the two user ids
joined by a separator, **smaller numeric id first**:

```
buildConversationId(otherUserId, sep):
    a, b = int(otherUserId), int(myUserId)
    return f"{a}{sep}{b}" if a < b else f"{b}{sep}{a}"
```

The separator depends on the surface, which is the single most annoying detail in this API:

- `+` for REST paths under `/conversations/...` (`Endpoints.buildConversationId`)
- `_` for the Faye push channel `/direct_message/{id}` (`FayeService.buildChannelUrl`)

The `like`/`unlike` endpoint under `/v3/messages/` also uses the `+` form.

If either id fails to parse as a long, the app gives up and returns `null` rather than
falling back to string comparison. Non-numeric user ids would break DM addressing entirely.

## Paging

Two styles coexist.

- Offset paging: `?page=N&per_page=M`, on the v3 list endpoints (groups, chats, albums).
- Cursor paging: `?limit=N&cursor=...` or `?limit=N&page=<opaque>`, on the v4 contact
  suggestions and user calendar endpoints. Treat `page` as opaque; it decodes to the last id
  of the previous page, but that is an observation, not a contract.
- Message history: the app only ever sends `?before_id=<id>` to page backwards. The server
  also accepts `?after_id=<id>` to page forwards and a `limit` of up to 200, neither of which
  the app uses. Both are measured, not read from the binary; see
  [verified.md](verified.md) and [messaging.md](messaging.md).

## The `include` parameter

Group and chat reads take `?include=`, and the app picks the value from a server-driven
feature flag:

```java
isUnreadSyncEnabled() ? "read_receipts" : "unread_count"
```

`include` can repeat: the group index appends `&include=visibility&include=locations`.

## Feature flags

Nearly every behavioral fork in the client is gated by ECS (Microsoft's Experimentation and
Configuration Service) at `https://config.edge.skype.com/config/v1`, project `GroupMeAndroid`,
key `ecsSettings`. The parsed shape lives in `com.groupme.ecs.ECSConfigs`. This matters when
reading the endpoint list: some routes are only ever called when a flag is on, so a route
existing in the APK does not prove it is live for your account.
