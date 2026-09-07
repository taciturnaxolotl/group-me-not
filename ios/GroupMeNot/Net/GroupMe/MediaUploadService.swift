import Foundation
import OSLog

/// What an upload produced.
nonisolated struct UploadedMedia: Hashable, Sendable {
    /// The URL that goes in the attachment.
    var url: String
    /// The poster frame, for video. Nil for stills.
    var previewURL: String?
}

/// Why an upload did not happen.
///
/// The whole reason this is typed: the outbox has to tell "the radio was off"
/// from "GroupMe will never accept this file" without reading strings. The first
/// is a wait, the second is a dead end, and treating either as the other is how
/// a client either drops a photo or retries a rejected one until the battery is
/// flat.
nonisolated enum MediaUploadError: Error, Sendable {
    /// No network, DNS, timeout. Always worth another go.
    case transport(URLError)
    /// The service answered with something retryable: 5xx, 408, 429.
    case unavailable(status: Int, retryAfter: TimeInterval?)
    /// No token, or the one we have was refused.
    case unauthenticated
    /// The service refused this file and will refuse it again. A `415` from the
    /// transcoder, a `400` from the picture service, an oversize body.
    case rejected(status: Int?, detail: String)
    /// A 2xx whose body was not what the endpoint documents. Not retryable: the
    /// bytes may well have landed, but we have no URL to reference them by, and
    /// pushing them again would only produce a second orphan.
    case malformed(String)
    /// The transcoder was still working when the deadline ran out. The job is
    /// still queued on their side; a later attempt re-posts it.
    case transcodeTimedOut
    /// The queued file is gone from disk.
    case missingFile

    /// True when trying again later could plausibly work.
    var isRetryable: Bool {
        switch self {
        case .transport, .unavailable, .transcodeTimedOut: true
        case .unauthenticated, .rejected, .malformed, .missingFile: false
        }
    }

    /// True when the fix is a new token rather than a new attempt.
    var needsCredentials: Bool {
        if case .unauthenticated = self { return true }
        if case .unavailable(let status, _) = self { return status == 401 || status == 403 }
        return false
    }

    var retryAfter: TimeInterval? {
        if case .unavailable(_, let after) = self { return after }
        return nil
    }
}

/// Uploads photos and videos to the services that hold them.
///
/// Attachments are never inline. Each media type has its own host, its own
/// shape, and its own idea of what "done" means, and this actor is where all of
/// that stays:
///
/// - **Images** go to `m.groupme.com/uploads` for a pre-signed Azure URL and
///   then straight to Azure, falling back to the older `image.groupme.com`
///   multipart route when that path is unavailable.
/// - **Video** goes to the transcoder, which answers with a status URL and
///   makes you poll it. The poll branches on the HTTP status, never on the
///   `status` string in the body, and it has a deadline.
///
/// Nothing here knows about messages, conversations or the queue. It takes
/// bytes and gives back URLs, and every way it can fail is in
/// ``MediaUploadError``.
actor MediaUploadService {

    /// How long we are willing to wait for a transcode before giving the job
    /// back to the outbox. Long enough for a minute of phone video, short enough
    /// that a stuck job does not hold a drain open all afternoon.
    static let transcodeDeadline: TimeInterval = 180
    /// Ceiling on poll attempts, so a clock that jumps backwards cannot turn the
    /// deadline into a loop that never ends.
    static let maxTranscodePolls = 120

    /// The docs' rule for the pre-signed URL request: two retries, jittered, and
    /// only on 5xx. `RetryPolicy` counts total attempts, hence three.
    private static let uploadURLRetry = RetryPolicy(maxAttempts: 3, base: 0.5, cap: 8)

    private let session: URLSession
    private let tokenProvider: @Sendable () async -> String?
    private let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "upload")

    /// Its own session rather than `APIClient`'s, and for a reason that matters:
    /// `APIClient` stamps `X-Access-Token` on every request it makes, and one of
    /// the requests here must not carry it. See ``putToPresignedURL(_:data:mimeType:)``.
    init(tokenProvider: @escaping @Sendable () async -> String?) {
        let config = URLSessionConfiguration.default
        // Uploads are big and slow; the per-request timeout is the one that
        // would otherwise kill a video halfway up a weak connection.
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = false
        // Never serve an upload, or a transcode poll, from a cache.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        self.session = URLSession(configuration: config)
        self.tokenProvider = tokenProvider
    }

    // MARK: - The one call the outbox makes

    /// Get a queued attachment onto a media service and hand back its URLs.
    ///
    /// - Parameters:
    ///   - media: the queued row, whose bytes are in the vault.
    ///   - senderID: our user id, which media v2 wants in the body.
    ///   - groupID: the group, when there is one. Media v2 takes it; DMs omit it.
    ///   - conversationID: the REST conversation id, which the transcoder
    ///     requires as a header.
    ///   - onProgress: called with 0...1 as the bytes go out. Off the main
    ///     actor, and often, so a caller that redraws from it should coalesce.
    /// - Parameters:
    ///   - guid: the queued message this belongs to, and `index` which of its
    ///     attachments. Neither is used to talk to GroupMe. They ride on the
    ///     transfer so that an answer arriving in some later launch of the app
    ///     can be matched back to the row that was waiting for it; see
    ///     ``UploadJob``.
    func upload(
        _ media: PendingMedia,
        guid: String,
        index: Int,
        senderID: String?,
        groupID: String?,
        conversationID: String?,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> UploadedMedia {
        // Measured, not read. The only thing every path needs about the file up
        // front is how big it is, and a video read into memory to find that out
        // is a hundred megabytes of a phone's RAM spent on a number the file
        // system already knows.
        let size = (try? media.localURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0 else { throw MediaUploadError.missingFile }

        switch media.kind {
        case .image:
            return try await uploadImage(
                size: size, media: media, guid: guid, index: index,
                senderID: senderID, groupID: groupID, onProgress: onProgress)
        case .video:
            return try await uploadVideo(
                media: media, guid: guid, index: index,
                conversationID: conversationID, onProgress: onProgress)
        }
    }

    // MARK: - Sending bytes

    /// Every request that carries a file goes out this way.
    ///
    /// Through the background session, always, and not only when the app is on
    /// its way out: a transfer that starts in the foreground and is still going
    /// when the screen locks is exactly the one worth saving, and there is no
    /// moment at which we could usefully have switched it over. The await here
    /// is the ordinary case; the durable one is ``BackgroundUploads``.
    private func sendFile(
        _ request: URLRequest, from file: URL, job: UploadJob,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Data {
        do {
            return try await BackgroundUploads.shared.send(
                request, from: file, job: job, onProgress: onProgress)
        } catch let urlError as URLError {
            throw MediaUploadError.transport(urlError)
        }
    }

    /// A multipart body around a file, written out without ever holding it.
    ///
    /// The envelope is a few dozen bytes and the file is the rest, so this
    /// copies the file through in chunks rather than loading it to concatenate.
    /// A minute of 4K video is a few hundred megabytes; the difference between
    /// streaming it and holding it is the difference between an upload and a
    /// memory warning.
    private func stagedMultipart(
        _ file: URL, boundary: String, filename: String, mimeType: String, for job: UploadJob
    ) throws -> URL {
        let directory = Self.stagingDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent("\(job.guid)-\(job.index)-\(job.step.rawValue)")
        try? FileManager.default.removeItem(at: staged)
        guard FileManager.default.createFile(atPath: staged.path, contents: nil) else {
            throw MediaUploadError.missingFile
        }

        let out = try FileHandle(forWritingTo: staged)
        defer { try? out.close() }
        var prologue = Data()
        prologue.append(Data("--\(boundary)\r\n".utf8))
        prologue.append(Data(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        prologue.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        try out.write(contentsOf: prologue)

        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return staged
    }


    static let stagingDirectory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("uploads", isDirectory: true)

    /// Throw away staged bodies nothing is using any more.
    ///
    /// A day, because a background transfer may legitimately still be queued
    /// hours later on a connection the system is waiting for.
    static func sweepStagedBodies(olderThan age: TimeInterval = 24 * 3_600) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: stagingDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified > cutoff { continue }
            try? manager.removeItem(at: file)
        }
    }

    // MARK: - Images

    /// Media v2 first, the picture service second.
    ///
    /// The fallback is not belt and braces. Media v2 needs a sender id, which a
    /// cold start with no `/users/me` yet may not have, and it is the newer of
    /// the two paths; `image.groupme.com` has been there the whole time. A
    /// *retryable* v2 failure is not swallowed, though, because falling back on
    /// a dead radio would just fail twice and blame the wrong endpoint.
    private func uploadImage(
        size: Int, media: PendingMedia, guid: String, index: Int,
        senderID: String?, groupID: String?,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> UploadedMedia {
        if let senderID {
            do {
                return try await uploadViaMediaV2(
                    size: size, media: media, guid: guid, index: index,
                    senderID: senderID, groupID: groupID,
                    onProgress: onProgress)
            } catch let error as MediaUploadError where !error.isRetryable && !error.needsCredentials {
                log.notice("media v2 refused this image, trying the picture service")
            }
        }
        return try await uploadToPictureService(
            media: media, guid: guid, index: index, onProgress: onProgress)
    }

    /// `POST https://image.groupme.com/pictures`, one multipart part named
    /// `file`. Returns `{ "payload": { "url": … } }`.
    private func uploadToPictureService(
        media: PendingMedia, guid: String, index: Int,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> UploadedMedia {
        guard let token = await tokenProvider() else { throw MediaUploadError.unauthenticated }
        let url = URL(string: "https://image.groupme.com/pictures")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Access-Token")
        let boundary = "gmn.\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let job = UploadJob(guid: guid, index: index, step: .pictureService)
        let staged = try stagedMultipart(
            media.localURL, boundary: boundary,
            filename: "file.\(media.fileExtension)", mimeType: media.mimeType, for: job)

        let body = try await sendFile(request, from: staged, job: job, onProgress: onProgress)
        try? FileManager.default.removeItem(at: staged)
        guard let payload = try? JSONDecoder().decode(PictureResponse.self, from: body),
              let uploaded = payload.payload?.url, !uploaded.isEmpty
        else { throw MediaUploadError.malformed("image.groupme.com returned no url") }
        return UploadedMedia(url: uploaded)
    }

    /// Ask `m.groupme.com` for a pre-signed URL, then PUT the bytes at Azure.
    private func uploadViaMediaV2(
        size: Int, media: PendingMedia, guid: String, index: Int,
        senderID: String, groupID: String?,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> UploadedMedia {
        let ticket = try await requestUploadURL(
            size: size, media: media, senderID: senderID, groupID: groupID)
        guard let target = URL(string: ticket.uploadUrl ?? ""),
              let render = ticket.renderUrl, !render.isEmpty
        else { throw MediaUploadError.malformed("m.groupme.com returned an incomplete ticket") }

        // The ticket is a few hundred bytes and the blob is the whole picture,
        // so the PUT is the only part of this path worth reporting on.
        //
        // It is also the one transfer whose answer we do not need: the ticket
        // has already said what the file will be called, so the job carries the
        // finished URL with it and a PUT that lands while the app is asleep is
        // self-explaining.
        try await putToPresignedURL(
            target, file: media.localURL, mimeType: media.mimeType,
            job: UploadJob(
                guid: guid, index: index, step: .presignedPut,
                renderURL: render, thumbnailURL: ticket.thumbnailUrl),
            onProgress: onProgress)
        return UploadedMedia(url: render, previewURL: ticket.thumbnailUrl)
    }

    /// `POST https://m.groupme.com/uploads`. Retried twice on 5xx and nothing
    /// else, which is the rule the service documents.
    private func requestUploadURL(
        size: Int, media: PendingMedia, senderID: String, groupID: String?
    ) async throws -> UploadTicket {
        guard let token = await tokenProvider() else { throw MediaUploadError.unauthenticated }

        var request = URLRequest(url: URL(string: "https://m.groupme.com/uploads")!)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Access-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONEncoder().encode(UploadTicketRequest(
            extension: media.fileExtension,
            senderId: senderID,
            // A string, not a number. The service is picky about it.
            fileSize: String(size),
            width: media.width,
            height: media.height,
            groupId: groupID))

        var attempt = 0
        while true {
            do {
                let body = try await perform(request)
                guard let ticket = try? JSONDecoder().decode(UploadTicket.self, from: body) else {
                    throw MediaUploadError.malformed("m.groupme.com returned an unreadable ticket")
                }
                return ticket
            } catch let error as MediaUploadError {
                // Only 5xx, per the documented behaviour. A transport failure is
                // the outbox's to wait out, not this loop's.
                guard case .unavailable(let status, _) = error, (500...599).contains(status),
                      attempt + 1 < Self.uploadURLRetry.maxAttempts
                else { throw error }
                try? await Task.sleep(for: .seconds(Self.uploadURLRetry.delay(forAttempt: attempt)))
                attempt += 1
            }
        }
    }

    /// PUT the raw bytes at the pre-signed URL.
    ///
    /// **No `X-Access-Token`.** `uploadUrl` is an Azure Blob SAS URL: the
    /// signature in the query string is the credential, the host is Microsoft's,
    /// and sending a GroupMe token there would hand our access token to a party
    /// that has no business holding it. `x-ms-blob-type` is Azure's, and the
    /// PUT is rejected without it.
    private func putToPresignedURL(
        _ url: URL, file: URL, mimeType: String, job: UploadJob,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
        // Straight from the vault. The file is already on disk and already the
        // exact bytes to send, so there is nothing to stage.
        _ = try await sendFile(request, from: file, job: job, onProgress: onProgress)
    }

    // MARK: - Video

    /// Post to the transcoder, then poll until it says done, fails, or the
    /// deadline passes.
    private func uploadVideo(
        media: PendingMedia, guid: String, index: Int, conversationID: String?,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> UploadedMedia {
        guard let token = await tokenProvider() else { throw MediaUploadError.unauthenticated }

        // Already handed to the transcoder on some earlier attempt. Pushing the
        // file again would be uploading a video twice to ask the same question.
        if let existing = media.transcodeStatusUrl.flatMap(URL.init(string:)) {
            onProgress?(1)
            return try await pollTranscode(existing, token: token)
        }

        guard let conversationID, !conversationID.isEmpty else {
            throw MediaUploadError.rejected(
                status: nil, detail: "the transcoder requires a conversation id")
        }

        var request = URLRequest(url: URL(string: "https://video.groupme.com/transcode")!)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Access-Token")
        request.setValue(conversationID, forHTTPHeaderField: "X-Conversation-ID")
        let boundary = "gmn.\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let job = UploadJob(guid: guid, index: index, step: .transcode)
        let staged = try stagedMultipart(
            media.localURL, boundary: boundary,
            filename: "file.\(media.fileExtension)", mimeType: media.mimeType, for: job)

        let body = try await sendFile(request, from: staged, job: job, onProgress: onProgress)
        try? FileManager.default.removeItem(at: staged)
        guard let started = try? JSONDecoder().decode(TranscodeStart.self, from: body),
              let statusURL = started.status_url.flatMap(URL.init(string:))
        else { throw MediaUploadError.malformed("the transcoder returned no status url") }

        return try await pollTranscode(statusURL, token: token)
    }

    /// Poll the status URL, branching on the HTTP status.
    ///
    /// The body carries a `status` string and it is not read, because it is not
    /// the thing that changes: `201` means done, `202` means keep waiting, `415`
    /// means the file will never transcode. Anything else is a transport
    /// problem wearing a status code.
    ///
    /// Two independent stops, a wall-clock deadline and an attempt ceiling,
    /// because one of them is enough right up until the system clock moves. When
    /// either fires the job is handed back to the outbox as retryable: the
    /// transcode is still running on GroupMe's side, and a later attempt costs
    /// one more POST rather than a lost video.
    private func pollTranscode(_ statusURL: URL, token: String) async throws -> UploadedMedia {
        let deadline = Date().addingTimeInterval(Self.transcodeDeadline)
        var polls = 0

        while polls < Self.maxTranscodePolls, Date() < deadline {
            // Back off gently: a short clip is often ready on the second ask,
            // and a long one does not benefit from being asked twice a second.
            try? await Task.sleep(for: .seconds(min(1.5 + Double(polls) * 0.5, 5)))
            polls += 1

            var request = URLRequest(url: statusURL)
            request.setValue(token, forHTTPHeaderField: "X-Access-Token")

            let data: Data, response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let urlError as URLError {
                throw MediaUploadError.transport(urlError)
            }
            guard let http = response as? HTTPURLResponse else {
                throw MediaUploadError.malformed("answer was not HTTP")
            }

            switch http.statusCode {
            case 201:
                guard let done = try? JSONDecoder().decode(TranscodeResult.self, from: data),
                      let url = done.url, !url.isEmpty
                else { throw MediaUploadError.malformed("the transcoder finished with no url") }
                return UploadedMedia(url: url, previewURL: done.thumbnail_url)
            case 202:
                continue
            case 415:
                throw MediaUploadError.rejected(
                    status: 415, detail: "that video format was rejected")
            default:
                throw Self.error(for: http, body: data)
            }
        }
        throw MediaUploadError.transcodeTimedOut
    }

    // MARK: - Plumbing

    /// One request, with every failure translated into a ``MediaUploadError``.
    ///
    /// Sends through `upload(for:from:)` rather than `data(for:)` when somebody
    /// is watching. The two do the same thing on the wire; only the upload form
    /// takes a per-task delegate, and that delegate is the only way URLSession
    /// will say how many bytes have actually left the phone.
    /// The small requests: the ticket, and the transcode polls. Anything
    /// carrying a file goes through ``sendFile(_:from:job:onProgress:)``
    /// instead, which is a different session for a different reason.
    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw MediaUploadError.transport(urlError)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MediaUploadError.malformed("answer was not HTTP")
        }
        guard (200...299).contains(http.statusCode) else {
            throw Self.error(for: http, body: data)
        }
        return data
    }

    /// The one place a status code becomes a verdict.
    private static func error(for http: HTTPURLResponse, body: Data) -> MediaUploadError {
        let after = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        switch http.statusCode {
        case 401, 403:
            return .unauthenticated
        case 408, 429, 500...599:
            return .unavailable(status: http.statusCode, retryAfter: after)
        default:
            let detail = String(data: body.prefix(256), encoding: .utf8) ?? ""
            return .rejected(status: http.statusCode, detail: detail)
        }
    }


    // MARK: - Wire shapes

    // Hand-written rather than run through the app's snake_case decoder: these
    // four services disagree about casing with each other, so each shape spells
    // its own keys.

    private nonisolated struct PictureResponse: Decodable, Sendable {
        struct Payload: Decodable, Sendable { var url: String? }
        var payload: Payload?
    }

    private nonisolated struct UploadTicketRequest: Encodable, Sendable {
        var `extension`: String
        var senderId: String
        var fileSize: String
        var width: Int?
        var height: Int?
        var groupId: String?
    }

    private nonisolated struct UploadTicket: Decodable, Sendable {
        var uploadUrl: String?
        var renderUrl: String?
        var thumbnailUrl: String?
        var transcriptUrl: String?
    }

    private nonisolated struct TranscodeStart: Decodable, Sendable {
        var status_url: String?
    }

    private nonisolated struct TranscodeResult: Decodable, Sendable {
        var url: String?
        var thumbnail_url: String?
    }
}

