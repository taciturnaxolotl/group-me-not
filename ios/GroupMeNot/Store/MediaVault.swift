import Foundation
import OSLog

/// A photo or video the user has attached to a message we have not sent yet.
///
/// The bytes live on disk in ``MediaVault`` and this is the row that points at
/// them. It rides along on the outbox entry, which means an attachment survives
/// exactly what a queued text message survives: a dead radio, a force quit, a
/// reboot.
///
/// Only the *filename* is stored, never a path. iOS moves an app's container
/// between launches and installs, so a persisted absolute path is a path that
/// eventually points at nothing; the directory is resolved fresh each time and
/// the name is the only durable half.
///
/// `uploadedUrl` is written back as soon as the upload service returns one, so a
/// send that fails after the bytes are up does not push them a second time. That
/// is the difference between a retry costing a request and a retry costing the
/// user's data plan.
nonisolated struct PendingMedia: Codable, Hashable, Sendable, Identifiable {
    nonisolated enum Kind: String, Codable, Sendable {
        case image
        case video
    }

    var id: String
    var kind: Kind
    /// The file inside the vault directory. A name, not a path; see above.
    var filename: String
    /// A poster frame for a video, also inside the vault, so the transcript can
    /// draw something real before the transcoder has said anything.
    var previewFilename: String?
    var mimeType: String
    var fileExtension: String
    var width: Int?
    var height: Int?
    /// The media-service URL, once there is one.
    var uploadedUrl: String?
    /// The transcoder's thumbnail, for video.
    var uploadedPreviewUrl: String?

    var isUploaded: Bool { uploadedUrl != nil }

    var localURL: URL { MediaVault.directory.appendingPathComponent(filename) }

    var localPreviewURL: URL? {
        previewFilename.map { MediaVault.directory.appendingPathComponent($0) }
    }

    /// What this becomes on the wire, or the local stand-in before it is
    /// uploaded.
    ///
    /// The pre-upload form is a `file://` URL in the same field the server's URL
    /// will occupy. That is deliberate: the transcript's image loader takes a
    /// `URL` and `URLSession` reads `file://` as happily as `https://`, so one
    /// renderer draws a queued photo and a delivered one with no branch between
    /// them. Nothing ever sends this shape; ``Outbox`` refuses to hand a message
    /// to the API until every attachment has a real URL.
    var attachment: Message.Attachment {
        switch kind {
        case .image:
            Message.Attachment(
                type: "image",
                url: uploadedUrl ?? localURL.absoluteString)
        case .video:
            Message.Attachment(
                type: "video",
                url: uploadedUrl ?? localURL.absoluteString,
                previewUrl: uploadedPreviewUrl ?? localPreviewURL?.absoluteString)
        }
    }
}

/// One thing the user picked, already on disk and already measured.
///
/// A `URL` rather than a `Data`, all the way through, because a minute of 4K
/// video is a few hundred megabytes and holding that in memory to hand it to a
/// queue that may not drain for an hour is a way to be killed by the watchdog.
/// The file is in a temporary directory at this point; ``MediaVault`` moves it
/// somewhere durable the moment it is claimed.
nonisolated struct PickedMedia: Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var kind: PendingMedia.Kind
    var fileURL: URL
    /// A poster frame for video, written alongside it.
    var previewURL: URL?
    var mimeType: String
    var fileExtension: String
    var width: Int?
    var height: Int?
}

/// Where attached files wait for the network.
///
/// Application Support, not `tmp`. A queued attachment is user data that has to
/// outlive a relaunch, and the system empties temporary directories whenever it
/// feels like it; a photo lost that way is a photo the user believes they sent.
/// Excluded from backup all the same, because the bytes are a few seconds from
/// being on GroupMe's servers and nobody wants them in an iCloud backup twice.
actor MediaVault {
    static let shared = MediaVault()

    /// Resolved once per launch. The container path is stable within a process
    /// and nowhere else, which is why nothing persists it.
    nonisolated static let directory: URL = {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("GroupMeNot", isDirectory: true)
            .appendingPathComponent("PendingMedia", isDirectory: true)
    }()

    private let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "media")

    private func ensureDirectory() {
        var directory = Self.directory
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        try? directory.setResourceValues(resource)
    }

    /// Take ownership of a picked file, moving it out of wherever the picker
    /// left it and into the vault.
    ///
    /// Move first, then fall back to copy: a `PhotosPicker` transfer hands back
    /// a file in a temporary directory that is ours to move, but a camera
    /// capture or a file provider may not be.
    func adopt(_ picked: PickedMedia) throws -> PendingMedia {
        ensureDirectory()

        let name = "\(picked.id).\(picked.fileExtension)"
        let destination = Self.directory.appendingPathComponent(name)
        try place(picked.fileURL, at: destination)

        var previewName: String?
        if let preview = picked.previewURL {
            let candidate = "\(picked.id)-preview.jpg"
            if (try? place(preview, at: Self.directory.appendingPathComponent(candidate))) != nil {
                previewName = candidate
            }
        }

        return PendingMedia(
            id: picked.id,
            kind: picked.kind,
            filename: name,
            previewFilename: previewName,
            mimeType: picked.mimeType,
            fileExtension: picked.fileExtension,
            width: picked.width,
            height: picked.height)
    }

    private func place(_ source: URL, at destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    /// The bytes, or nil if the file has gone. A missing file is a permanent
    /// failure for the send that referenced it, not something to retry.
    nonisolated func data(for media: PendingMedia) throws -> Data {
        try Data(contentsOf: media.localURL, options: .mappedIfSafe)
    }

    func remove(_ media: PendingMedia) {
        try? FileManager.default.removeItem(at: media.localURL)
        if let preview = media.localPreviewURL {
            try? FileManager.default.removeItem(at: preview)
        }
    }

    func remove(_ media: [PendingMedia]) {
        for item in media { remove(item) }
    }

    /// Delete every file the outbox no longer refers to.
    ///
    /// Orphans are possible by design: the file is written before the queue row
    /// so a row never points at bytes that are not there, which means a crash in
    /// between leaves a file nobody claims. Sweeping is cheap and losing a photo
    /// is not, so the order stays that way and this cleans up after it.
    func sweep(keeping claimed: Set<String>) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for url in contents where !claimed.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
            removed += 1
        }
        if removed > 0 { log.notice("swept \(removed) unclaimed media files") }
    }

    /// Signing out takes the queue with it, so it takes the bytes too.
    func removeAll() {
        try? FileManager.default.removeItem(at: Self.directory)
    }
}
