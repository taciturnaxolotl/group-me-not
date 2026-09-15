# group-me-not / web

A GroupMe client for the browser, shaped like Slack.

The iOS client in `../ios` took its cues from iMessage. This one takes them
from Slack, because that is the shape GroupMe's own data already has and has
never been drawn as: **a group is a section, its topics are the channels inside
it, and DMs are their own section.** Flat left-aligned messages, hover
toolbars, a `⌘K` switcher, reactions as chips.

## It has no backend

Not "the backend is small". There isn't one. This is a static bundle that talks
straight to GroupMe.

That is only possible because of two things worth writing down, both measured
rather than assumed:

- **Every GroupMe host answers CORS preflight with `Access-Control-Allow-Origin: *`.**
  `api.groupme.com`, `image.groupme.com`, `video.groupme.com`, `file.groupme.com`,
  and — surprisingly — `v2.groupme.com/access_tokens`, which means real password
  sign-in works from a static page.
- **`wss://push.groupme.com/faye` accepts a handshake and a signed subscribe from
  any origin.** WebSockets are not subject to CORS. The official web client
  ships all 37 KB of `faye.min.js` and negotiates down to JSONP long-polling,
  because `POST /faye` genuinely has no CORS headers. Over a WebSocket none of
  that matters, so `realtime/bayeux.ts` is about 200 lines and gets a real
  duplex socket instead of a poll loop.

## Running it

```sh
bun install
bun run dev      # http://localhost:5273
```

Sign in with a GroupMe password, or paste an access token if a captcha gets in
the way.

```sh
bun run build    # static files in dist/, host them anywhere
bun run check    # svelte-check
```

There is also a scratch probe for poking the live API while developing:

```sh
GMN_TOKEN=… bun scripts/probe.ts get /v3/groups per_page=100
```

## How it is put together

```
src/lib/
  api/        HTTP client, error taxonomy, the typed GroupMe surface
  auth/       password + MFA login, token storage
  model/      domain types, id ordering, wire→domain normalisation
  realtime/   Bayeux over WebSocket, push event decoding
  store/      IndexedDB, and the range tracking that makes gaps visible
  sync/       the engine: conversations, history, outbox
  state/      Svelte 5 reactive state
  ui/         components
```

The rule everything follows, inherited from the iOS client:

> local storage is the truth, the network updates local storage, the UI
> observes local storage.

Nothing on screen ever waits for a request. A cold start draws the sidebar from
IndexedDB before the first request has left the machine, and a send is a local
write that the outbox takes responsibility for delivering.

## Things the API does that will surprise you

Most of these cost someone a day. They are all commented at the site where they
matter; this is the index.

**`since_id` is not a catch-up parameter.** It looks like one. It returns the
*newest* messages rather than the ones following your anchor, so using it to
catch up after being offline silently skips the middle and never goes back.
Measured on a real group of 550 messages, anchoring 90 back and asking for 20:

| param | first id returned | |
|---|---|---|
| `after_id` | `…899368629784` | the message right after the anchor ✓ |
| `since_id` | `…935525972245019` | the newest message in the group ✗ |
| `before_id` | `…898791705019` | the message right before the anchor ✓ |

`api/groupme.ts` does not expose `since_id` at all.

**Image variants differ per host, and a wrong one costs you megabytes.**
`i.groupme.com` takes a suffix (`.avatar`, `.preview`, `.large`).
`m.groupme.com` instead replaces the `.original` segment and only understands
`large` and `small`. An unrecognised variant does not 404 — it silently serves
the original. Measured on one photo: `.large` 126 KB, `.small` 32 KB,
`.preview` **5104 KB**, because `preview` is not a word that host knows.

**Message ids exceed `Number.MAX_SAFE_INTEGER.`** They are 18-digit decimal
strings and they are the sort key for the whole app. `Number(id)` silently
rounds. Compare with `cmpId`.

**A DM's id is two ids joined, and the separator depends on the surface.** REST
routes want `a+b`; the push channel wants `a_b`. Both sorted numerically,
smaller first. The wrong order 404s in a way that reads as "no such
conversation".

**409 on send means success.** The server dedupes on `source_guid`, so a retry
after a timeout comes back 409 — it has the message, it just will not hand it
back. Treating that as an error shows a delivered message as failed.

**One reaction per person, and a second `like` is silently ignored.** Changing
glyph means `unlike` *then* `like`, in that order, honouring the first result.
Skip the unlike and the server answers 200, changes nothing, and the UI
disagrees with reality until the next refetch.

**Not every reaction is a character.** GroupMe "powerups" arrive as
`{type: "emoji", pack_id, pack_index}` with no glyph, and the pack fields are
JSON numbers on some messages and quoted strings on others *in the same array*.
The packs are single-column sprite sheets; pack 20 is 80×3600, 45 cells.

**`/user/{me}` does carry topic messages.** `../docs/push.md` says it does not,
and that a client must subscribe to each topic separately. That was true once.
Measured now: subscribe to `/user/{me}`, `/group/{topicId}` and
`/group/{parentId}`, all three succeed, then post to the topic and to the
parent — both arrive on `/user/{me}` tagged with their own `group_id`, and
nothing arrives on either group channel. One subscription covers everything.
Group channels are still worth having for typing indicators.

**304 means "nothing there", not "something went wrong".** Message pages past
either end of a conversation answer 304 with no body. A client that treats
non-2xx as failure retries a perfectly good "no news" three times and then
shows an error.

## What is not here yet

Sending attachments (the upload paths are written and typed but no picker is
wired up), polls and events render as chips rather than as controls, no message
search, no group administration, no threads-as-panels.
