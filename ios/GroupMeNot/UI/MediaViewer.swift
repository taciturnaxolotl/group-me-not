import AVKit
import SwiftUI

/// Full screen, one attachment.
///
/// Deliberately plain: a black ground, the picture as large as it will go, and
/// one way out. A photo viewer that decorates itself is a photo viewer that gets
/// in the way of the photo.
struct MediaViewer: View {
    let attachment: Message.Attachment

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if attachment.type == "video", let url = mediaURL {
                VideoPlayer(player: AVPlayer(url: url))
                    .ignoresSafeArea()
            } else {
                ZoomableImage(url: mediaURL)
            }
        }
        .overlay(alignment: .topTrailing) { closeButton }
        .statusBarHidden()
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.black.opacity(0.45), in: .circle)
        }
        .padding(16)
        .accessibilityLabel("Close")
    }

    /// The full-size asset, not the thumbnail: `url` first, and the preview only
    /// as a fallback for a video we have not got a playable copy of.
    private var mediaURL: URL? {
        let candidate = attachment.url ?? attachment.sourceUrl ?? attachment.previewUrl
        return candidate.flatMap(URL.init(string:))
    }
}

/// Pinch and drag, with a double tap to toggle.
///
/// Built on the loader everything else uses, so an image already on screen in
/// the transcript opens instantly rather than downloading a second time. No
/// `maxPixelSize`: this is the one place the full resolution is the point.
private struct ZoomableImage: View {
    let url: URL?

    @State private var scale: CGFloat = 1
    @State private var committed: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    var body: some View {
        RemoteImage(url: url) {
            ProgressView().tint(.white)
        }
        .scaledToFit()
        .scaleEffect(scale)
        .offset(offset)
        .gesture(magnify)
        .simultaneousGesture(scale > 1 ? drag : nil)
        .onTapGesture(count: 2) { toggleZoom() }
        .animation(.snappy(duration: 0.25), value: scale)
        .accessibilityLabel("Photo")
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // Clamped rather than free: an unbounded pinch leaves the user
                // looking at four grey pixels with no way back.
                scale = min(max(committed * value.magnification, 1), 6)
            }
            .onEnded { _ in
                committed = scale
                if scale <= 1 { resetPan() }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: committedOffset.width + value.translation.width,
                    height: committedOffset.height + value.translation.height)
            }
            .onEnded { _ in committedOffset = offset }
    }

    private func toggleZoom() {
        if scale > 1 {
            scale = 1
            committed = 1
            resetPan()
        } else {
            scale = 2.5
            committed = 2.5
        }
    }

    private func resetPan() {
        offset = .zero
        committedOffset = .zero
    }
}
