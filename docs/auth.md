# Authentication

## The access token

Every authenticated request carries the token in a header, not a query parameter:

```
X-Access-Token: <token>
```

The published GroupMe developer docs use `?token=`. Both work against v3, but the app only
ever sends the header. `BaseAuthenticatedRequest.getHeaders()` is the whole of it:

```java
map.put("X-Access-Token", AccountUtils.getAccessToken(context));
if (getMethod() == POST) map.put("Content-Type", "application/json");
```

The app has no token-refresh path at all. It holds one token indefinitely and only discards
it after five consecutive `401 unauthorized` responses, so if tokens do expire, the app's
answer is to log you out.

## User agent

```
GM-Android/16.10.4 (262370304; M:<manufacturer> <model>; O:<sdk int>; D:<device id>) <clientName>/<clientVersion> OkHttp/<okhttp version>
```

`clientName` and `clientVersion` identify the calling subsystem, so the tail varies per
request. A `; V:<flags>` segment is appended on debug builds and on any non-production
environment. Built in `com.groupme.net.UserAgentInterceptor`.

## Password login

```
POST https://v2.groupme.com/access_tokens
Content-Type: application/x-www-form-urlencoded
X-Access-Token: <pre-login hash, see below>
```

Form fields:

| Field | Value |
| --- | --- |
| `user_name` | email or phone |
| `password` | plaintext password |
| `grant_type` | `password` |
| `app_id` | `Android-<versionCode>`, e.g. `Android-262370304` |
| `app_version` | the version code again, as a string |
| `device_id` | `Settings.Secure.ANDROID_ID`, falling back to a random UUID only when that is empty, then persisted |
| `sisu_verification_token` | sign-up create-password flow only, not MFA |

The pre-login `X-Access-Token` is not a token at all. It is a SHA-256 of a fixed salt
concatenated with the platform id, device id, and username:

```
sha256("48ea3317-4a12-4a30-9b87-efdf2dc1b9ec" + platformId + deviceId + userName)
```

with `platformId = "Android-" + versionCode` and `deviceId` as in the table above. The salt
is a hardcoded constant in `AccountUtils.getHashedLoginToken`. It is a client-identity check,
not a secret: anything that can compute the hash can present it.

Responses:

- `201`: success. Body is `LoginResponse` with `response.access_token`, `response.user_id`,
  `response.user_name`, `response.image_url`.
- `202` with `meta.code` `20200`: a verification challenge. `response.verification` carries
  `type`, `long_pin`, `code`, `system_number`, and `methods.{sms,email}`.
- `meta.code` `40121`: the account is banned. Not a retryable state.
- anything else: failure.

If the ECS flag `sisuConfig.serverDrivenCodeFormatEnabled` is on, the client also sends
`X-Client-Capabilities: otp-variable-length` to signal it can render OTP fields of a
server-chosen length. Only `LoginRequest` sends it; `MfaLoginRequest` does not.

## Completing an MFA challenge

The re-post is a different request class, `MfaLoginRequest`, against the same
`/access_tokens` URL but with `Content-Type: application/json` and a JSON body: the same
`user_name`, `password`, `grant_type`, `app_id`, `app_version`, `device_id` fields, plus a
nested challenge object.

```json
{ "user_name": "...", "password": "...", "grant_type": "password",
  "app_id": "Android-262370304", "app_version": "262370304", "device_id": "...",
  "verification": { "code": "123456" } }
```

Immediately after a successful login the app fires
`POST https://api.groupme.com/v3/users/sms_mode/delete` to make sure SMS mode is off for the
new session.

## Logout

```
POST https://v2.groupme.com/access_tokens/current/destroy
```

## Social sign-in

Each provider has both a legacy v2 route and a newer v3 route. All are `POST`.

| Provider | Legacy | Current |
| --- | --- | --- |
| Facebook | `v2.groupme.com/registrations/facebook_create` | none |
| Google | `v2.groupme.com/registrations/google_plus` | `api.groupme.com/v3/registrations/google` |
| Microsoft | `v2.groupme.com/registrations/microsoft_sso` | `api.groupme.com/v3/registrations/microsoft` |

## Phone and email registration

The flow is a verification handshake rather than a single call.

1. `POST /v3/registrations/phone/verify` or `POST /v4/emails/validate`: check the identifier
   is usable.
2. `POST /v3/verifications/{verificationId}/initiate`: send the code.
3. `POST /v3/verifications/{verificationId}/confirm` (or `/v4/verifications/{id}/confirm`):
   submit it.
4. `POST /v4/users/create`: create the account.

Account recovery on a lost number goes through `POST /registrations/change_number` on v2,
which returns a `long_pin` and a `system_number` to text it to.

## Installation records

Separate from login, and registered alongside push, an install record identifies the device:

```
POST https://api.groupme.com/v3/installations

{
  "installation": {
    "client_id": "<device UUID>",
    "platform": "Android",
    "model": "...",
    "manufacturer": "...",
    "os_version": "...",
    "app_version": "16.10.4 (262370304)",
    "locale": "en_US",
    "country": "US",
    "language": "en"
  }
}
```

The `client_id` here is the same UUID sent as `device_id` during login, so generate it once
and persist it.

## Sign in with Apple, and the desktop handoff

Apple accounts cannot authenticate through any of the routes above. The Android app's
welcome screen offers only `btn_google` and `btn_microsoft` (its sign-in telemetry declares
an `APPLE` method, but nothing in the app ever fires it), and `dev.groupme.com/session/new`
takes an email or phone plus a password. An account created through Sign in with Apple has
neither, so it cannot reach the developer portal to collect a token or register an OAuth app.

The web client has a way in, built for GroupMe's own desktop app. From
`assets/js/desktopAuthHandoff-*.js`:

```js
var e = [`microsoft`, `google`, `facebook`, `apple`];
// reads: desktop_auth, provider, state, intent
window.location.href = `groupme://oauth/callback#${n}`;   // n = access_token=…&state=…
```

So:

```
https://web.groupme.com/signin?desktop_auth=1&provider=apple&state=<nonce>&intent=signin
   → the normal web sign-in, whatever the account uses
   → groupme://oauth/callback#access_token=<token>&state=<nonce>
```

Providers are `apple`, `google`, `microsoft`, `facebook`. `intent` is `signin` or `signup`.
The `state` is echoed back untouched, so generate a nonce and check it.

No client id and no app registration: this is not the documented OAuth flow, it is the
mechanism their web client already implements for their own desktop client. It is the only
route an Apple-registered account has, and the token it returns is an ordinary access token.

Note the token arrives in the URL **fragment**, not the query.

## Multi-factor auth

| Action | Route |
| --- | --- |
| Read MFA state | `GET /v3/user/mfa` |
| Open a channel (send a code) | `POST /v3/user/mfa/channel` |
| Generate backup codes | `POST /v3/user/mfa/backup` |

## Device attestation

`GET https://api.groupme.com/v1/nonce` returns a nonce for Play Integrity. The resulting
token is attached to sensitive calls via `com.groupme.net.TokenData`, and the client reports
success and failure of that path as `DeviceCertificationAPIEvent` telemetry. The server-side
enforcement level is not visible from the APK.
