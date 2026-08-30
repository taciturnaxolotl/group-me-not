# A buffering relay: design sketch

A process that holds the Faye connection on your behalf, streams events straight through to a
connected client, and buffers recent ones so it can replay what you missed on reconnect.

Everything in memory, nothing at rest, no restart survival. That constraint is not a
compromise: it removes most of what would otherwise be hard.

It is worth building for one reason above all others. **It is the only way to see edits and
deletions you missed.** REST catch-up cannot recover those; see
[offline.md](offline.md#rest-catch-up-cannot-see-edits-or-deletions). Replay of new messages
is a convenience, `after_id` already handles that.

## Be the `ack` extension GroupMe isn't

The design falls out of one observation. Bayeux already has a standard mechanism for exactly
this, the `ack` extension, and GroupMe's server does not implement it
([verified](verified.md#the-ack-extension-is-not-enabled)).

So the relay's entire job is: **speak Bayeux upstream without `ack`, speak Bayeux downstream
with it.**

```
client  --- Bayeux + ext:{ack} --->  relay  --- Bayeux, no ack --->  push.groupme.com
```

That is what "transparent" should mean here. Not an invented protocol, but the protocol the
client already speaks, with the extension the upstream is missing:

```
→ handshake   ext: {ack: true}
← handshake   ext: {ack: true}              relay confirms it supports it

→ connect     ext: {ack: 4711}              "I have everything through 4711"
← connect     ext: {ack: 4890}  + messages  everything from 4712 to 4890
```

Any off-the-shelf Faye client gets this for free. And the fallback is perfect: point the same
client at `push.groupme.com` directly and it works, just without replay. A dead relay
degrades you to a normal client rather than a broken one, and you get that property without
writing any fallback code.

## Credentials

The client passes its own token in `ext` on connect, exactly as it would upstream. The relay
uses it to open the upstream connection and never writes it anywhere.

It does have to keep it in RAM after you disconnect, because holding the upstream connection
open while you are gone is the entire point. So the honest statement is not "never holds your
token" but:

> the token lives in memory, for as long as your session is buffered, and is gone on eviction
> or restart.

Session TTL and buffer window are the same number. Pick something like 30 minutes.

## What in-memory buys you

Four of the five things I would otherwise call hard simply evaporate:

- **No persistence layer.** None.
- **No secrets at rest.** No encryption story, no database to breach.
- **Restart semantics become free.** Generate a random epoch at process start. A restart means
  a new epoch, every client sees a mismatch, every client does a full REST reconcile. Correct
  by construction rather than by care. A Faye client that finds its `clientId` unknown already
  re-handshakes, so this is standard behaviour, not a special case.
- **Eviction is a TTL**, not a policy question.

## The one thing still worth being careful about

The buffer is bounded, so a client that has been away too long cannot be served a complete
replay. It must be told, not silently given a partial one.

In Bayeux terms that is clean: if the client's `clientId` has expired, or its `ack` number is
older than the oldest event you still hold, refuse the session. The client re-handshakes,
gets a fresh `clientId`, and falls back to a REST reconcile.

```
← connect  {successful: false, error: "401::Unknown client", advice: {reconnect: "handshake"}}
```

This is the correctness boundary and the only place a bug becomes silent permanent
divergence. Everything else in the design fails loudly.

The same applies when the relay's *own* upstream connection drops: it does not know what it
missed either. For a first version, bump the epoch and let clients reconcile. It is honest,
it is simple, and it is what they would do on a cold start anyway. Having the relay do one
REST reconcile and synthesise the results into the buffer is a nice optimisation later, not a
requirement.

## Consolidation, later

Folding the buffer before replay (twelve edits to final text, thirty likes to one reaction
state, typing events dropped entirely) is the fun part and it is where "you missed six hours"
becomes twenty events instead of two thousand.

But it is in tension with transparency, because folded events no longer correspond 1:1 to
what upstream sent. Negotiate it rather than assuming it:

```
→ handshake   ext: {ack: true, consolidate: true}
```

With a recent-only buffer it also matters less than it would with a long one. Ship without
it.

One rule when you do add it: collapse *within* an entity, preserve order *across* them. Two
edits to different messages fold independently; a delete followed by a repost must stay in
order.

## If it is public

"Anyone can connect and use it" is the nicest property of the pass-through design and also
the thing that needs a moment's thought. Even with nothing on disk, a public instance is an
intermediary holding other people's tokens and messages in RAM.

Minimum sensible limits: one upstream connection per token, a cap on downstream sessions per
token, a cap on buffer bytes per session, and a global connection ceiling. Otherwise one
client can pin unbounded memory.

Self-hosting should be the expected deployment and the documented default. A public instance
is fine as a convenience, but it should be an explicit choice by someone who has read what it
holds, not the path of least resistance.

## Effort

- **Core, working:** a weekend. Bayeux server semantics, one upstream client, a ring buffer
  per session, the `ack` extension. Genuinely small.
- **The careful bits:** session TTL, buffer caps, the expiry-to-`RESET` path, upstream
  reconnect. Another few days, and it is where the attention should go.
- **Consolidation:** a day, whenever you want it.

The permanent cost is operating it, which is why the fallback property matters so much: if it
is down, nobody is stuck.

## Recommendation

Build the client first. It works against the API as it ships and it is the thing you actually
want to use.

Add the relay when the edit and delete blindness starts bothering you, because that is the one
problem the client cannot solve alone. Build it as the `ack` extension and nothing else: no
proxying of reads or writes, which keep going direct to GroupMe.
