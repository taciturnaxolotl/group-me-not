import AVKit
import Photos
import SwiftUI

/// Full screen, one attachment.
///
/// Modelled on the photo viewer in Messages, because that is the shape iOS
/// readers already know: a black ground, floating glass controls that get out of
/// the way on a tap, and a picture that pinches, pans, and falls away when you
/// drag it down. The chrome is deliberately sparse. Every control here does
/// something real; none of it is there to fill the corners.
struct MediaViewer: View {
    /// Every picture the message carried, so a swipe reaches the rest.
    let attachments: [Message.Attachment]
    /// Which one was tapped.
    let initialIndex: Int

    @Environment(\.dismiss) private var dismiss

    @State private var index: Int = 0
    /// Whether the bars are showing. Starts hidden: the picture is what was
    /// asked for, and chrome that arrives uninvited is chrome that has to be
    /// dismissed before the photo can be looked at. A tap brings it back, and a
    /// downward drag closes the viewer without it.
    @State private var isChromeVisible = false
    /// The loaded picture, held here rather than inside the zoom view so the
    /// share and save actions have something to hand over.
    @State private var image: UIImage?
    /// How far a dismissing drag has got, and how much of the ground it has
    /// taken with it.
    @State private var dragOffset: CGSize = .zero
    @State private var saveResult: SaveResult?
    /// The height of the top bar, measured, so the letterbox test below knows
    /// how far down the bar actually reaches.
    @State private var topBarHeight: CGFloat = 0
    /// The screen, for the same test.
    @State private var canvas: CGSize = .zero

    /// Past this much downward travel the picture is let go rather than
    /// snapping back. Roughly a thumb's comfortable reach.
    private static let dismissDistance: CGFloat = 140

    /// The page being looked at. Falls back rather than trapping: `index` is
    /// clamped on appear, but a viewer opened on an empty run should show
    /// nothing rather than crash.
    private var attachment: Message.Attachment? {
        attachments.indices.contains(index) ? attachments[index] : attachments.first
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(backdropOpacity)
                .ignoresSafeArea()

            pages
                .offset(dragOffset)
                .scaleEffect(dragScale)
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { canvas = $0 }
        .onAppear {
            guard !attachments.isEmpty else { return }
            index = min(max(initialIndex, 0), attachments.count - 1)
        }
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottom) { bottomBar }
        .statusBarHidden()
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .alert(item: $saveResult) { result in
            Alert(title: Text(result.title), message: Text(result.message),
                  dismissButton: .default(Text("OK")))
        }
    }

    /// One page per picture. Paging is the system's, so the rubber band at
    /// either end and the speed of a flick are the ones every other iOS gallery
    /// has; writing our own would only be a worse copy of it.
    private var pages: some View {
        TabView(selection: $index) {
            ForEach(Array(attachments.enumerated()), id: \.offset) { position, item in
                page(for: item)
                    .tag(position)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
    }

    @ViewBuilder private func page(for item: Message.Attachment) -> some View {
        if item.type == "video", let url = Self.mediaURL(of: item) {
            VideoPlayer(player: AVPlayer(url: url))
                .ignoresSafeArea()
        } else {
            ZoomableImage(
                url: Self.mediaURL(of: item),
                onLoad: { loaded in
                    // Only the page being looked at owns the share and save
                    // actions. Without this test a neighbouring page finishing
                    // its download would quietly swap what the buttons act on.
                    if item.url == attachment?.url { image = loaded }
                },
                onSingleTap: toggleChrome,
                onDismissDrag: { translation, animated in
                    guard animated else {
                        dragOffset = translation
                        return
                    }
                    withAnimation(.snappy(duration: 0.25)) { dragOffset = translation }
                },
                onDismiss: { dismiss() },
                dismissDistance: Self.dismissDistance)
        }
    }

    // MARK: Chrome

    /// Close on the leading edge where a thumb can reach it, and the title in
    /// the middle. The menu hangs off the title rather than sitting apart from
    /// it, which is what makes the chevron read as "there is more about this
    /// photo" instead of as another button.
    private var topBar: some View {
        HStack {
            circleButton("xmark", label: "Close") { dismiss() }
            Spacer()
            titleMenu
            Spacer()
            // Balances the close button so the title sits truly centred.
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { topBarHeight = $0 }
        // A band, but only when the bar has a picture to stand out against.
        //
        // White glyphs over an arbitrary photo are legible on some pictures and
        // invisible on others, so the band exists for the pictures that reach
        // the top of the screen. A letterboxed one does not: the bar sits on
        // plain black, where nothing could be more readable, and the material
        // would only be a lighter rectangle drawn over darkness for no reason.
        .background {
            if barOverlapsPicture {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea(edges: .top)
            }
        }
        .opacity(isChromeVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isChromeVisible)
        .allowsHitTesting(isChromeVisible)
    }

    private var titleMenu: some View {
        Menu {
            Button("Save to Photos", systemImage: "square.and.arrow.down", action: save)
                .disabled(image == nil)
            Button("Copy", systemImage: "doc.on.doc", action: copy)
                .disabled(image == nil)
        } label: {
            HStack(spacing: 6) {
                Text(attachment?.type == "video" ? "Video" : "Photo")
                    .font(.headline)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
                    .glassEffect(.regular, in: .circle)
            }
            .foregroundStyle(.white)
        }
        .accessibilityLabel("Photo options")
    }

    /// Share alone on the trailing edge, the way Messages puts it. Absent
    /// entirely until there is something to share, because a share button that
    /// does nothing is worse than none.
    @ViewBuilder private var bottomBar: some View {
        HStack {
            Spacer()
            if let image {
                ShareLink(
                    item: Image(uiImage: image),
                    preview: SharePreview("Photo", image: Image(uiImage: image))
                ) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .accessibilityLabel("Share")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 24)
        // A wash rather than a bar. There is one button down here and it is
        // already glass, so it needs separation from the picture and nothing
        // more; a second opaque band would frame the photo on two sides and
        // make the screen feel smaller than it is.
        .background {
            LinearGradient(
                colors: [.clear, .black.opacity(0.45)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
        .opacity(isChromeVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isChromeVisible)
        .allowsHitTesting(isChromeVisible)
    }

    private func circleButton(
        _ symbol: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .accessibilityLabel(label)
    }

    // MARK: Behaviour

    /// Whether the top bar actually covers any of the photo.
    ///
    /// The picture is drawn to fit, so its height on screen follows from its
    /// aspect ratio and the canvas. If the top of that rectangle falls below the
    /// bottom of the bar, the bar is over letterbox and needs no ground.
    ///
    /// Unknown shapes answer true, because a bar that is occasionally redundant
    /// is a much smaller fault than a close button nobody can see.
    private var barOverlapsPicture: Bool {
        guard canvas.width > 0, canvas.height > 0, topBarHeight > 0 else { return true }
        guard let size = MediaDimensions.declared(in: mediaURL) ?? image?.size,
              size.width > 0, size.height > 0
        else { return true }
        let drawnHeight = min(canvas.height, canvas.width * size.height / size.width)
        let pictureTop = (canvas.height - drawnHeight) / 2
        return pictureTop < topBarHeight
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) { isChromeVisible.toggle() }
    }

    /// The ground thins out as the picture is dragged away, so the transcript
    /// underneath comes back gradually rather than all at once at the end.
    private var backdropOpacity: Double {
        let travel = min(abs(dragOffset.height) / (Self.dismissDistance * 2), 1)
        return 1 - travel * 0.85
    }

    /// A little shrink as it goes, which is what makes the gesture read as
    /// putting the picture back rather than sliding it off an edge.
    private var dragScale: CGFloat {
        1 - min(abs(dragOffset.height) / 2200, 0.12)
    }

    // MARK: Actions

    /// Asks for add-only access, which is the narrowest permission that can
    /// save a photo: it never lets this app read the library back.
    private func save() {
        guard let image else { return }
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                saveResult = .denied
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
                saveResult = .saved
            } catch {
                saveResult = .failed
            }
        }
    }

    private func copy() {
        guard let image else { return }
        UIPasteboard.general.image = image
    }

    /// The full-size asset, not the thumbnail: `url` first, and the preview only
    /// as a fallback for a video we have not got a playable copy of.
    private var mediaURL: URL? { attachment.flatMap(Self.mediaURL(of:)) }

    static func mediaURL(of attachment: Message.Attachment) -> URL? {
        let candidate = attachment.url ?? attachment.sourceUrl ?? attachment.previewUrl
        return candidate.flatMap(URL.init(string:))
    }
}

/// What to say after a save attempt. An alert rather than a silent success,
/// because the picture does not visibly change and the only feedback the system
/// gives is the one we provide.
private enum SaveResult: String, Identifiable {
    case saved, denied, failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .saved: "Saved"
        case .denied: "No Access to Photos"
        case .failed: "Could Not Save"
        }
    }

    var message: String {
        switch self {
        case .saved: "The photo is in your library."
        case .denied: "Allow adding photos in Settings to save this one."
        case .failed: "Something went wrong writing to your photo library."
        }
    }
}

/// Pinch, pan, double tap, and drag away.
///
/// Built on the loader everything else uses, so an image already on screen in
/// the transcript opens instantly rather than downloading a second time. No
/// `maxPixelSize`: this is the one place the full resolution is the point.
private struct ZoomableImage: View {
    let url: URL?
    let onLoad: (UIImage) -> Void
    let onSingleTap: () -> Void
    /// Reports the dismissing drag up to the owner, which is the one that
    /// moves the picture. Doing it here as well would move it twice as fast as
    /// the finger. The flag is set only for the snap back, which is a movement
    /// the reader should see; the drag itself must track the finger exactly.
    let onDismissDrag: (CGSize, Bool) -> Void
    let onDismiss: () -> Void
    let dismissDistance: CGFloat

    @State private var scale: CGFloat = 1
    @State private var committed: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private var isZoomed: Bool { scale > 1.01 }

    var body: some View {
        RemoteImage(url: url, onLoad: nil) {
            ProgressView().tint(.white)
        }
        .scaledToFit()
        .scaleEffect(scale)
        .offset(offset)
        .gesture(magnify)
        // Panning while zoomed and dragging to dismiss while not are the same
        // finger doing two different jobs, so only one of them is ever live.
        .simultaneousGesture(isZoomed ? pan : nil)
        .simultaneousGesture(isZoomed ? nil : dismissDrag)
        .onTapGesture(count: 2) { toggleZoom() }
        // Ordered after the double tap so a second tap is not swallowed by the
        // first. SwiftUI resolves the higher count first when both are present.
        .onTapGesture { onSingleTap() }
        .animation(.snappy(duration: 0.25), value: scale)
        .accessibilityLabel("Photo")
        .task(id: url) { await preload() }
    }

    /// Hands the decoded picture up so the chrome can share and save it. The
    /// loader dedupes, so this costs nothing beyond the draw already happening.
    private func preload() async {
        guard let url else { return }
        let request = ImageLoader.Request(url: url, maxPixelSize: nil)
        if let hit = ImageLoader.shared.cached(request) {
            onLoad(hit)
            return
        }
        if let loaded = await ImageLoader.shared.image(for: request) { onLoad(loaded) }
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

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: committedOffset.width + value.translation.width,
                    height: committedOffset.height + value.translation.height)
            }
            .onEnded { _ in committedOffset = offset }
    }

    /// Drag the picture away to close.
    ///
    /// Only a mostly-vertical drag counts. Horizontal belongs to the pager, and
    /// this gesture runs alongside it, so without the dominance test a swipe
    /// towards the next photo would also start dragging this one off the screen.
    /// The `minimumDistance` is what keeps a tap from registering as either.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard Self.isVertical(value.translation) else { return }
                onDismissDrag(value.translation, false)
            }
            .onEnded { value in
                let travelled = abs(value.translation.height) > dismissDistance
                let flicked = abs(value.predictedEndTranslation.height) > dismissDistance * 2
                guard Self.isVertical(value.translation), travelled || flicked else {
                    onDismissDrag(.zero, true)
                    return
                }
                onDismiss()
            }
    }

    private static func isVertical(_ translation: CGSize) -> Bool {
        abs(translation.height) > abs(translation.width)
    }

    private func toggleZoom() {
        if isZoomed {
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
