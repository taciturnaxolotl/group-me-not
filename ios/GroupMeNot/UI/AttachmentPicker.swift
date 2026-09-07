import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import os

// MARK: - Presenting

extension View {
    /// Attach the picker to a view and drive it from one boolean.
    ///
    /// Self-contained on purpose: the caller owns a `Bool` and a closure and
    /// nothing else. Everything about sources, permissions, loading and the two
    /// different system pickers stays in here.
    ///
    /// `onPick` fires once, on the main actor, with everything the user chose,
    /// already written to disk. It does not fire for a cancellation, and it does
    /// not fire empty.
    func attachmentPicker(
        isPresented: Binding<Bool>,
        onPick: @escaping ([PickedMedia]) -> Void
    ) -> some View {
        modifier(AttachmentPickerModifier(isPresented: isPresented, onPick: onPick))
    }
}

private struct AttachmentPickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onPick: ([PickedMedia]) -> Void

    @State private var isLibraryPresented = false
    @State private var isCameraPresented = false
    @State private var selection: [PhotosPickerItem] = []
    @State private var isLoading = false

    private static let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "picker")

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Attach", isPresented: $isPresented, titleVisibility: .hidden) {
                Button("Photo Library") { isLibraryPresented = true }
                // No camera in the simulator, and no point offering one.
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo or Video") { isCameraPresented = true }
                }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(
                isPresented: $isLibraryPresented,
                selection: $selection,
                // Enough for a burst of holiday photos, few enough that the
                // outbox is not asked to drain a hundred uploads at once.
                maxSelectionCount: 10,
                matching: .any(of: [.images, .videos]))
            .fullScreenCover(isPresented: $isCameraPresented) {
                CameraPicker { picked in
                    isCameraPresented = false
                    if let picked { onPick([picked]) }
                }
                .ignoresSafeArea()
            }
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                selection = []
                isLoading = true
                Task {
                    let loaded = await MediaLoader.load(items)
                    isLoading = false
                    guard !loaded.isEmpty else {
                        Self.log.notice("nothing usable came back from the photo picker")
                        return
                    }
                    onPick(loaded)
                }
            }
            // The transfer off the photo library can take a beat for a long
            // video, and a composer that looks frozen is worse than one that
            // says it is busy.
            .overlay {
                if isLoading {
                    ProgressView()
                        .padding(20)
                        .background(.regularMaterial, in: .rect(cornerRadius: 14, style: .continuous))
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isLoading)
    }
}

// MARK: - Loading what the library hands over

/// Turns `PhotosPickerItem`s into files on disk.
///
/// A namespace of async functions rather than an actor: there is no state to
/// protect here, only work to do somewhere other than the main actor.
nonisolated enum MediaLoader {
    private static let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "picker")

    /// The longest edge we will upload.
    ///
    /// 4096 was here first and it is the wrong trade. A phone camera's output is
    /// already under it, so nothing was being scaled at all: a photo went up at
    /// full size, four or five megabytes of it, over whatever connection
    /// happened to be there — and then came back down displayed at a fraction of
    /// that, because GroupMe serves its own smaller variants to everybody
    /// reading. The upload was paying for detail nobody would be shown.
    ///
    /// 2560 is still larger than any screen this lands on and larger than the
    /// biggest variant the service hands back, so a picture opened full screen
    /// is unchanged to look at. It is roughly a third of the bytes.
    static let maxImageEdge: CGFloat = 2560

    /// Quality for the re-encode. 0.85 is the knee: below it JPEG starts
    /// showing itself around text and edges, above it the file grows for
    /// detail the eye is not collecting.
    static let imageQuality: CGFloat = 0.85

    static func load(_ items: [PhotosPickerItem]) async -> [PickedMedia] {
        var results: [PickedMedia] = []
        for item in items {
            if let picked = await load(item) { results.append(picked) }
        }
        return results
    }

    private static func load(_ item: PhotosPickerItem) async -> PickedMedia? {
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        do {
            return isVideo ? try await loadVideo(item) : try await loadImage(item)
        } catch {
            log.error("could not load a picked item: \(error)")
            return nil
        }
    }

    private static func loadImage(_ item: PhotosPickerItem) async throws -> PickedMedia? {
        guard let data = try await item.loadTransferable(type: Data.self) else { return nil }
        let type = item.supportedContentTypes.first { $0.conforms(to: .image) }
        return try await normalisedImage(data, declaredType: type)
    }

    /// Keep the file as it came when GroupMe understands it and it is not
    /// enormous; otherwise re-encode as JPEG.
    ///
    /// The case that forces this is HEIC, which every recent iPhone produces by
    /// default and which most people reading the message cannot open. Animated
    /// GIFs are passed through untouched: re-encoding one would silently turn it
    /// into a still, which is worse than a large upload.
    static func normalisedImage(_ data: Data, declaredType: UTType?) async throws -> PickedMedia? {
        guard let image = UIImage(data: data) else { return nil }
        let pixels = CGSize(
            width: image.size.width * image.scale, height: image.size.height * image.scale)

        let passthrough: Set<UTType> = [.jpeg, .png, .gif]
        let longest = max(pixels.width, pixels.height)
        let keepAsIs = declaredType.map { candidate in
            passthrough.contains { candidate.conforms(to: $0) }
        } ?? false

        if keepAsIs, longest <= maxImageEdge || declaredType?.conforms(to: .gif) == true {
            let ext = declaredType?.preferredFilenameExtension ?? "jpg"
            let mime = declaredType?.preferredMIMEType ?? "image/jpeg"
            let url = try write(data, extension: ext)
            return PickedMedia(
                kind: .image, fileURL: url, mimeType: mime, fileExtension: ext,
                width: Int(pixels.width), height: Int(pixels.height))
        }

        let scaled = longest > maxImageEdge
            ? (await image.byPreparingThumbnail(ofSize: CGSize(
                width: image.size.width * (maxImageEdge / longest),
                height: image.size.height * (maxImageEdge / longest))) ?? image)
            : image
        guard let jpeg = scaled.jpegData(compressionQuality: Self.imageQuality) else { return nil }
        let url = try write(jpeg, extension: "jpg")
        return PickedMedia(
            kind: .image, fileURL: url, mimeType: "image/jpeg", fileExtension: "jpg",
            width: Int(scaled.size.width * scaled.scale),
            height: Int(scaled.size.height * scaled.scale))
    }

    private static func loadVideo(_ item: PhotosPickerItem) async throws -> PickedMedia? {
        guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { return nil }
        return await describe(movie.url)
    }

    /// Measure a video and pull a poster frame out of it.
    ///
    /// The poster is what makes a queued video look like a video in the
    /// transcript instead of a grey box: the transcoder's own thumbnail does not
    /// exist until it has finished, which may be minutes away or, offline, not
    /// today.
    static func describe(_ url: URL) async -> PickedMedia? {
        // Shrink it first, and only then measure it. Everything below describes
        // whatever file is actually going to be uploaded.
        let url = await compressed(url) ?? url
        let asset = AVURLAsset(url: url)
        var size: CGSize?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let natural = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            // Applying the transform is what keeps a portrait clip from being
            // reported as landscape, which is how you get a sideways thumbnail.
            let oriented = natural.applying(transform)
            size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        }

        var preview: URL?
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)
        if let (frame, _) = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)),
           let jpeg = UIImage(cgImage: frame).jpegData(compressionQuality: 0.8) {
            preview = try? write(jpeg, extension: "jpg")
        }

        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension.lowercased()
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "video/mp4"
        return PickedMedia(
            kind: .video, fileURL: url, previewURL: preview, mimeType: mime, fileExtension: ext,
            width: size.map { Int($0.width) }, height: size.map { Int($0.height) })
    }

    /// The longest edge a video is allowed to keep. GroupMe transcodes on its
    /// own side anyway, so anything above this is detail we pay to upload and
    /// the server then throws away.
    private static let videoPreset = AVAssetExportPreset1280x720

    /// Videos small enough already are left alone; there is no sense re-encoding
    /// a clip that somebody else already compressed.
    private static let videoPassthroughBytes = 8 * 1024 * 1024

    /// Re-encode a video down to something a phone can actually send.
    ///
    /// This is the single biggest thing standing between this app and a video
    /// message that arrives. A modern iPhone records 4K at around 50 Mbit/s, so
    /// half a minute of footage is the better part of two hundred megabytes, and
    /// the app was uploading that byte for byte: pictures were being resized on
    /// the way out and video was not. At 720p the same clip is a tenth the size,
    /// and GroupMe's transcoder was going to reduce it regardless.
    ///
    /// Returns nil rather than throwing, and every caller falls back to the
    /// original. A clip that will not export is still a clip worth sending
    /// slowly.
    private static func compressed(_ url: URL) async -> URL? {
        let asset = AVURLAsset(url: url)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > videoPassthroughBytes else { return nil }

        guard let session = AVAssetExportSession(asset: asset, presetName: videoPreset)
        else { return nil }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        do {
            try await session.export(to: output, as: .mp4)
        } catch {
            log.notice("could not compress a video, sending it as it came: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let after = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // A re-encode that made the file bigger is a re-encode worth discarding.
        guard after > 0, after < size else {
            try? FileManager.default.removeItem(at: output)
            return nil
        }
        log.debug("compressed video from \(size) to \(after) bytes")
        return output
    }

    static func write(_ data: Data, extension ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(ext)")
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// A movie transferred as a file rather than as bytes.
///
/// `loadTransferable(type: Data.self)` would work and would also read the whole
/// clip into memory on the way past. This copies it straight to a temporary
/// file, which is where it wants to end up anyway.
nonisolated struct PickedMovie: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

// MARK: - Camera

/// The system camera, for the one thing `PhotosPicker` cannot do.
///
/// `UIImagePickerController` rather than anything newer because it is still the
/// only capture UI that comes for free, handles both stills and video, and needs
/// no `AVCaptureSession` of our own.
struct CameraPicker: UIViewControllerRepresentable {
    /// Called with what was captured, or nil if the user backed out.
    let onFinish: (PickedMedia?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        controller.videoQuality = .typeHigh
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onFinish: (PickedMedia?) -> Void

        init(onFinish: @escaping (PickedMedia?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let movie = info[.mediaURL] as? URL {
                Task {
                    let picked = await MediaLoader.describe(movie)
                    self.onFinish(picked)
                }
                return
            }
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.9)
            else {
                onFinish(nil)
                return
            }
            Task {
                let picked = try? await MediaLoader.normalisedImage(data, declaredType: .jpeg)
                self.onFinish(picked)
            }
        }
    }
}
