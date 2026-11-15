import Foundation
import Photos
import UniformTypeIdentifiers

/// Writing attachments into the photo library, originals and all.
///
/// The bytes go in as they came from GroupMe rather than as a re-encoded
/// `UIImage`, so a saved photo keeps its full resolution and its metadata, and
/// a video is saved as a video rather than as its poster frame.
enum PhotoLibrary {
    enum SaveError: Error { case denied, download }

    // MARK: What has been saved

    /// Whether this phone has saved the attachment before. Read from views,
    /// and observed: a save anywhere redraws every button showing the same
    /// photo, so the pile in the transcript hears about a save in the viewer.
    static func isSaved(_ attachment: Message.Attachment) -> Bool {
        guard let key = key(of: attachment) else { return false }
        return SavedMedia.shared.urls.contains(key)
    }

    static func areAllSaved(_ attachments: [Message.Attachment]) -> Bool {
        !attachments.isEmpty && attachments.allSatisfy(isSaved)
    }

    private static func key(of attachment: Message.Attachment) -> String? {
        MediaViewer.mediaURL(of: attachment)?.absoluteString
    }

    private static func remember(_ attachments: [Message.Attachment]) {
        SavedMedia.shared.insert(attachments.compactMap(key(of:)))
    }

    // MARK: Saving

    /// Saves every attachment, in order, as one change to the library: either
    /// the whole pile lands or none of it does.
    ///
    /// Add-only access, which is the narrowest permission that can save a
    /// photo: it never lets this app read the library back.
    static func save(_ attachments: [Message.Attachment]) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }

        let files = try await withThrowingTaskGroup(of: (Int, URL, PHAssetResourceType).self) { group in
            for (index, attachment) in attachments.enumerated() {
                guard let url = MediaViewer.mediaURL(of: attachment) else { continue }
                let kind: PHAssetResourceType = attachment.type == "video" ? .video : .photo
                group.addTask { (index, try await download(url, as: kind), kind) }
            }
            var collected: [(Int, URL, PHAssetResourceType)] = []
            for try await file in group { collected.append(file) }
            return collected.sorted { $0.0 < $1.0 }
        }
        guard !files.isEmpty else { throw SaveError.download }

        try await PHPhotoLibrary.shared().performChanges {
            for (_, file, kind) in files {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                PHAssetCreationRequest.forAsset().addResource(with: kind, fileURL: file, options: options)
            }
        }
        remember(attachments)
    }

    /// A private copy of the asset, streamed to disk so a long video never sits in memory.
    /// Also copies `file://` vault URLs, which Photos must not be allowed to move.
    private static func download(_ url: URL, as kind: PHAssetResourceType) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: file)
            throw SaveError.download
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension(for: response.mimeType, as: kind))
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    /// From the MIME type, since GroupMe paths end in a hash; non-media types fall back.
    private static func fileExtension(for mimeType: String?, as kind: PHAssetResourceType) -> String {
        let expected: UTType = kind == .video ? .movie : .image
        guard let type = mimeType.flatMap({ UTType(mimeType: $0) }), type.conforms(to: expected),
              let ext = type.preferredFilenameExtension
        else { return kind == .video ? "mp4" : "jpeg" }
        return ext
    }
}

/// Media URLs this phone has written to the library, kept across launches.
///
/// Our own record rather than a question put to Photos, because add-only
/// access cannot read the library back. So a photo deleted from the library
/// since still counts as saved here; the worst that costs is a prompt
/// offering a duplicate of something that is no longer there.
@Observable
final class SavedMedia {
    static let shared = SavedMedia()

    private(set) var urls: Set<String>
    /// Oldest first, so the record can be trimmed from the front.
    @ObservationIgnored private var order: [String]

    private static let key = "PhotoLibrary.savedMediaURLs"
    private static let limit = 5000

    private init() {
        order = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        urls = Set(order)
    }

    func insert(_ new: [String]) {
        let fresh = new.filter { !urls.contains($0) }
        guard !fresh.isEmpty else { return }
        order = Array((order + fresh).suffix(Self.limit))
        urls = Set(order)
        UserDefaults.standard.set(order, forKey: Self.key)
    }
}
