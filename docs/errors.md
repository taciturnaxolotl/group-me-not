# Errors and status codes

## The envelope

```json
{ "meta": { "code": 40901, "errors": ["Phone number already registered"] } }
```

`meta.code` is a five-digit code whose first three digits **usually** mirror the HTTP status.
`40901` arrives on an HTTP `409`, `42901` on a `429`, `20001` on a `200` or `201`.

The rule is a convention, not a guarantee: the `450xx` family arrives on HTTP `403`. Read the
HTTP status from the status line and treat `meta.code` as the specific reason.

That structure means a client can branch on `meta.code` alone and derive the HTTP class from
it. It also means a `2xxxx` code is not an error: several endpoints use `meta.code` to
communicate an outcome on an otherwise successful response.

`meta.errors` is an array of human-readable strings. It is not stable enough to branch on,
though the app does exactly that in a few places. `RegistrationViewModel` string-matches
the first error string to disambiguate `40003`: `startsWith("password")` means the password
was rejected, `contains("email")` means the email is taken, and anything else is treated as
the phone number already being registered.

## Codes recovered from the client

Everything below is a code the app explicitly branches on. This is not the server's full
vocabulary, only the part the Android client handles.

### Success-with-meaning (2xxxx)

Used by the group-join and event-join flows to report resulting membership state.

| Code | Meaning |
| --- | --- |
| `20000` | joined, membership `active` |
| `20001` | join requested, membership `requested_pending` |
| `20100` | joined, membership `active` (created) |
| `20101` | join requested, membership `requested_pending` (created) |
| `20110` | no membership resulted |
| `20200` | verification challenge issued; `response.verification` carries the details |

### Client errors (4xxxx)

| Code | HTTP | Meaning |
| --- | --- | --- |
| `40002` | 400 | missing password |
| `40003` | 400 | identifier taken (email or phone), disambiguated by the error string |
| `40004` | 400 | invalid registration |
| `40006` | 400 | missing email |
| `40081` | 400 | assistant group is at max size |
| `40101` | 401 | invalid verification token |
| `40121` | 401 | account banned. Not retryable |
| `40301`–`40303` | 403 | call forbidden |
| `40602` | 406 | PIN verification took too long |
| `40690` | 406 | GDPR / age gate; response carries a `verification.code` to continue with |
| `40901` | 409 | phone number already registered, or locked |
| `40902` | 409 | phone number change conflict |
| `41202` | 412 | poll precondition failed |
| `42901` | 429 | rate limited |
| `45018`, `45019` | 403 | assistant DM not allowed |
| `45020`–`45022` | 403 | assistant unavailable in this country |
| `45030`–`45032` | 403 | assistant blocked by age or location |

### Bare HTTP statuses the client treats specially

| Status | Where | Behavior |
| --- | --- | --- |
| `401` + `meta.errors[0] == "unauthorized"` | any authenticated request | five in a row logs the user out, but only when `Content-Type` is JSON or text ([conventions](conventions.md#envelopes)) |
| `403` | GDPR check | same handling as `40690` |
| `409` | message send | duplicate `source_guid`; **treated as success** |
| `422` | message send | rejected, "links not allowed" |
| `429` | read-receipt sync | schedules `unread_batch_sync_429_retry` with a **1-hour** initial delay and 1-hour exponential backoff |
| `201` | login | success |
| `202` | login | accepted but incomplete; MFA challenge follows |

## What to retry

The sync engine's list is the closest thing to an official answer in the binary:

```java
retryableCodes = {408, 500, 502, 503, 504};   // plus errorCode < 0, i.e. transport failures
```

That is the ECS-supplied *default* and the server can override it, so do not treat it as a
constant. Notably absent: `429`. With the default set, a rate-limited sync fails outright
rather than backing off, even though the read-receipt worker elsewhere handles 429 correctly.
If you are rebuilding, put 429 in the retry set.

Never retry `400`, `401`, `403`, `422`, or any `4xxxx` that describes a permanent state.
`409` on a send is not a retry case either. It means you already succeeded.

## Rate limiting

Rate limits are real and reachable: registration, friend suggestions, group joins, the emoji
picker, recaps, and read-receipt sync all have explicit `429` branches.

**The server does send `Retry-After` on at least some 429s.** `JoinGroupRequest` reads it
case-insensitively from both `allHeaders` and `headers`, converts it to hours, and shows
either "try again tomorrow" or "try again in N hours". `RecapTriggerResponse` carries a
`retryAfterSeconds` field in the body for the same purpose.

Successful responses carry no `X-RateLimit-*` and no `Retry-After`
([verified](verified.md#no-rate-limit-headers-on-normal-responses)), so you cannot see your
budget in advance. Read `Retry-After` when a 429 arrives, and fall back to exponential
backoff with jitter when it is absent.
