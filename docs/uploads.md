# Media uploads

Attachments are never uploaded inline with the message. Every media type goes to its own
service first, and the message body then references the returned URL. Four separate services,
four different shapes.

## Images

```
POST https://image.groupme.com/pictures
X-Access-Token: <token>
Content-Type: multipart/form-data
```

One form part named `file`, with filename `file.jpg` and the real MIME type on the part.
Response:

```json
{ "payload": { "url": "https://i.groupme.com/..." } }
```

Put that `url` into an `image` attachment. `source_url` on the attachment is for meme edits:
it points at the unmodified original so clients can offer "view original".

### Where the pixels actually live

Three hosts, and a client has to know all three. Sampled 2026-08-31 across 47 image
attachments in twelve groups: 38 were on `m.groupme.com`, the rest on `i.groupme.com`.
Videos are on `v.groupme.com` or `m.groupme.com`.

| host | shape |
| ---- | ----- |
| `i.groupme.com` | `/{w}x{h}.{ext}.{hash}` |
| `m.groupme.com` | `/uploads/{id}/{w}x{h}.original.{ext}` |
| `v.groupme.com` | `/{group}/{timestamp}/{hash}.{w}x{h}r{rotation}.mp4` |

**Every one of them puts the dimensions in the path, and every one puts them somewhere
different.** A parser that reads only the first path component works on `i.groupme.com` and
silently fails on the other two.

### Resized copies

`i.groupme.com` takes a suffix. Measured from a 1024×1024 original:

| suffix     | result    | bytes  |
| ---------- | --------- | ------ |
| *(none)*   | 1024×1024 | 207 KB |
| `.large`   | 960×960   | 122 KB |
| `.preview` | 200×200   | 13 KB  |
| `.avatar`  | 60×60     | 2.5 KB |

`m.groupme.com` instead replaces the `.original` segment. Measured from a 1333×1000 original:

| segment     | result    | bytes  |
| ----------- | --------- | ------ |
| `.original` | 1333×1000 | 163 KB |
| `.large`    | 1200×900  | 68 KB  |
| `.small`    | 300×225   | 15 KB  |

An unrecognised segment or suffix serves the original rather than 404ing, so a typo is silent
and expensive. A variant of a variant on `i.groupme.com` *is* a 404.

The important difference: `i.groupme.com`'s small copies are **square crops**, while
`m.groupme.com`'s keep the aspect ratio. One is a stand-in; the other is genuinely the
picture, smaller.

`v.groupme.com` serves one size. Its `preview_url` is the poster frame at full resolution,
which for a phone video is a six-figure number of bytes.

Worth a great deal on a weak connection. Drawing a photo 240 points wide needs 720 pixels at
the very most, so `.large` is already more detail than can be shown.

### `blur_hash`

Most attachments uploaded through media v2 carry one, alongside `url`: 38 of the 47 sampled.

```json
{ "type": "image", "url": "https://m.groupme.com/uploads/…/3024x4032.original.jpeg",
  "blur_hash": "^iHU:{S6M{R+WBs.~pNHM{WVNGV@tRRjR*jZM|WBWAxZbIR*aet7Rjk…" }
```

It is a [BlurHash](https://blurha.sh): a hundred-odd characters that decode locally into a
blurred approximation of the picture. No request, no wait. The one placeholder that is already
there on the frame the message appears.

## Media v2 (pre-signed URLs)

The newer path asks for an upload URL first rather than posting bytes to GroupMe.

```
POST https://m.groupme.com/uploads
X-Access-Token: <token>

{
  "extension": "jpg",
  "senderId": "<user id>",
  "fileSize": "12345",
  "width": 1080,
  "height": 1920,
  "groupId": "<optional>"
}
```

Returns four URLs:

```json
{
  "uploadUrl": "...",
  "renderUrl": "...",
  "thumbnailUrl": "...",
  "transcriptUrl": "..."
}
```

The client then `PUT`s the raw bytes to `uploadUrl`:

```
PUT <uploadUrl>
Content-Type: <real mime type>
x-ms-blob-type: BlockBlob
```

Note the absence of `X-Access-Token`. `uploadUrl` is an Azure Blob Storage SAS URL, the SAS
itself is the credential, and the bytes never touch GroupMe's servers. Do not send a GroupMe
token to Azure. `renderUrl` is what goes in the attachment.

The URL request retries up to twice with jittered exponential backoff, but only on `5xx`.

## Video

Two steps, because transcoding is asynchronous.

```
POST https://video.groupme.com/transcode
X-Access-Token: <token>
X-Conversation-ID: <conversation id>
Content-Type: multipart/form-data
```

Part `file`, filename `file.mp4`, type `video/mp4`. Response:

```json
{ "status_url": "https://video.groupme.com/..." }
```

Then poll `status_url`, branching on the **HTTP status**, not on a body field:

- `201` with a body: done. `{ "url": "...", "thumbnail_url": "..." }`
- `202`: still transcoding, poll again until the client's deadline elapses
- `415`: permanent failure, the format was rejected
- anything else: treat as a transport error

The response carries a `status` string too, but the client never reads it.

`url` and `thumbnail_url` become the `video` attachment's `url` and `preview_url`.
`X-Conversation-ID` is required. The method that builds it did not decompile, so whether DMs
use the combined `{a}+{b}` form here is inferred from the document-upload path, which does.

## Documents

Three steps against `https://file.groupme.com/v1/{conversationId}/`.

1. Upload:
   ```
   POST https://file.groupme.com/v1/{conversationId}/files?name=<filename>
   X-Access-Token: <token>
   ```
   Raw bytes in the body, no multipart wrapper. A `201` returns
   `{ "status_url": "...?job=<id>" }`. There is no `job_id` field: the client extracts the
   job id by taking everything after the first `=` in `status_url`.

2. Poll:
   ```
   GET https://file.groupme.com/v1/{conversationId}/uploadStatus?job=<job id>
   ```
   Returns `202` while pending, `200` with `{"status": "completed", "file_id": "..."}` when
   done. The client recurses immediately on any non-`completed` status, with no backoff, no
   depth limit, and no deadline. Unlike the video poller, which has a `TaskDeadline`, this
   one can spin forever. Do not copy it.

3. Reference `file_id` in a `file` attachment.

Metadata and download for an existing file:

```
GET https://file.groupme.com/v1/{conversationId}/fileData/{fileId}
GET https://file.groupme.com/v1/{conversationId}/files/{fileId}
```

## Albums

Albums are a separate index over media already uploaded, not another upload path.

```
POST https://api.groupme.com/v3/conversations/{conversationId}/albums/create
     { "title": "..." }
POST https://api.groupme.com/v3/conversations/{conversationId}/albums/media?album_id={id}
     [ { "media_source": "...", "media_url": "...", "media_type": "...",
         "preview_url": "...", "blur_hash": "..." } ]
```

The media body is a bare JSON **array**, not an object. `media_source`, `media_url`, and
`media_type` are always present; `preview_url` and `blur_hash` only when non-empty.

See [the endpoint reference](endpoints.md#albums) for the rest.

## blur_hash

Image, video, and album attachments all carry an optional `blur_hash`, a
[BlurHash](https://blurha.sh/) string the client computes locally before upload and uses as a
placeholder while the real asset loads. The server stores and echoes it; it does not generate
it.
