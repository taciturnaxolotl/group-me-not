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

    /// How far the current page has been dragged sideways.
    @State private var pageDrag: CGFloat = 0
    /// Which way this drag turned out to be, decided once on the first few
    /// points of movement and held for the rest of the gesture.
    @State private var axis: Axis?

    /// Zoom belongs to the viewer rather than to a page, so the one gesture
    /// below can consult it, and so swiping away from a photo returns it to
    /// life size instead of leaving it magnified for whenever you come back.
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var committedPan: CGSize = .zero

    /// True from the moment a dismissal is committed to. The picture keeps
    /// travelling the way it was thrown rather than vanishing on release, which
    /// is the whole difference between a gesture that completes and one that is
    /// merely interrupted.
    @State private var isDismissing = false

    /// How far down the screen a drag has to get before letting go completes the
    /// dismissal. A fraction rather than a fixed distance: the gesture is "throw
    /// it off the screen", and how far that is depends on the screen.
    private static let dismissFraction: CGFloat = 0.16
    /// How far sideways before the page turns instead of springing back.
    private static let pageTurnFraction: CGFloat = 0.22

    private var isZoomed: Bool { scale > 1.01 }

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
                .scaleEffect(dragScale)
                .offset(dragOffset)
                .opacity(isDismissing ? 0 : 1)
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
        // Without this the cover paints its own opaque ground behind everything,
        // and fading `backdropOpacity` would reveal nothing but another black
        // rectangle. Clearing it is what puts the transcript back there.
        .presentationBackground(.clear)
        .persistentSystemOverlays(.hidden)
        .alert(item: $saveResult) { result in
            Alert(title: Text(result.title), message: Text(result.message),
                  dismissButton: .default(Text("OK")))
        }
    }

    /// One page per picture, laid out in a row and offset by hand.
    ///
    /// Deliberately not a `TabView`. A paging `TabView` is a `UIScrollView`
    /// underneath, and the drag-to-dismiss gesture on its contents has to
    /// negotiate with that scroll view's pan for every touch. Whoever wins, one
    /// of the two behaviours stops working, and here it was the swipe: the
    /// dismiss gesture claimed the touch and the pages never turned.
    ///
    /// So there is exactly one gesture in this view. It decides on the first few
    /// points of movement whether the finger is turning a page or throwing the
    /// picture away, and nothing has to be arbitrated at all.
    private var pages: some View {
        HStack(spacing: 0) {
            ForEach(Array(attachments.enumerated()), id: \.offset) { position, item in
                page(for: item, at: position)
                    .frame(width: canvas.width)
            }
        }
        .offset(x: -CGFloat(index) * canvas.width + pageDrag)
        .frame(width: canvas.width, alignment: .leading)
        .contentShape(.rect)
        .gesture(drag)
        .simultaneousGesture(magnify)
        .onTapGesture(count: 2) { toggleZoom() }
        // Ordered after the double tap so a second tap is not swallowed by the
        // first. SwiftUI resolves the higher count first when both are present.
        .onTapGesture { toggleChrome() }
        .ignoresSafeArea()
    }

    @ViewBuilder private func page(for item: Message.Attachment, at position: Int) -> some View {
        if item.type == "video", let url = Self.mediaURL(of: item) {
            VideoPage(url: url, isCurrent: position == index)
        } else {
            ZoomableImage(
                url: Self.mediaURL(of: item),
                // Only the page being looked at is zoomed or panned. The others
                // sit at life size waiting their turn.
                scale: position == index ? scale : 1,
                offset: position == index ? pan : .zero,
                onLoad: { loaded in
                    // Only the page being looked at owns the share and save
                    // actions. Without this test a neighbouring page finishing
                    // its download would quietly swap what the buttons act on.
                    if position == index { image = loaded }
                })
        }
    }

    // MARK: The one gesture

    private var drag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !isZoomed else {
                    pan = CGSize(
                        width: committedPan.width + value.translation.width,
                        height: committedPan.height + value.translation.height)
                    return
                }
                if axis == nil {
                    axis = abs(value.translation.width) > abs(value.translation.height)
                        ? .horizontal : .vertical
                }
                switch axis {
                case .horizontal: pageDrag = resisted(value.translation.width)
                case .vertical: dragOffset = value.translation
                case nil: break
                }
            }
            .onEnded { value in
                defer { axis = nil }
                guard !isZoomed else {
                    committedPan = pan
                    return
                }
                switch axis {
                case .horizontal: settlePage(value)
                case .vertical: settleDismiss(value)
                case nil: break
                }
            }
    }

    /// Half travel past either end, which is the standard way of saying "there
    /// is nothing over here" without simply refusing to move.
    private func resisted(_ translation: CGFloat) -> CGFloat {
        let atStart = index == 0 && translation > 0
        let atEnd = index == attachments.count - 1 && translation < 0
        return atStart || atEnd ? translation / 2.5 : translation
    }

    /// Turn the page, or spring back. Both are the same animation, because both
    /// are the offset returning to a whole number of pages.
    private func settlePage(_ value: DragGesture.Value) {
        let threshold = canvas.width * Self.pageTurnFraction
        let travelled = value.translation.width
        let predicted = value.predictedEndTranslation.width
        let wantsPrevious = travelled > threshold || predicted > canvas.width / 2
        let wantsNext = travelled < -threshold || predicted < -canvas.width / 2

        var target = index
        if wantsPrevious { target = max(index - 1, 0) }
        if wantsNext { target = min(index + 1, attachments.count - 1) }

        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
            if target != index { resetZoom() }
            index = target
            pageDrag = 0
        }
    }

    /// Let go, and the picture either springs back or carries on.
    ///
    /// The old version called `dismiss()` on release, so the photo stopped dead
    /// under the finger and the cover cut away underneath it. Every iOS viewer
    /// that does this finishes the throw: the picture keeps going the way it was
    /// sent, the ground goes with it, and only then is the cover taken down. The
    /// sleep is that animation's length, and the dismissal is untransacted so
    /// the system does not slide a second one over the top of it.
    private func settleDismiss(_ value: DragGesture.Value) {
        let threshold = max(canvas.height * Self.dismissFraction, 90)
        let travelled = abs(value.translation.height) > threshold
        let flicked = abs(value.predictedEndTranslation.height) > threshold * 2.5
        guard travelled || flicked else {
            // A spring, not a duration. Springing back is the one moment the
            // gesture has momentum of its own, and easing it out drops that on
            // the floor.
            withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                dragOffset = .zero
            }
            return
        }

        let heading: CGFloat = value.predictedEndTranslation.height >= 0 ? 1 : -1
        withAnimation(.easeOut(duration: 0.22)) {
            isDismissing = true
            dragOffset = CGSize(
                width: value.translation.width,
                height: heading * canvas.height)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
        }
    }

    /// Pinch. Simultaneous with the drag rather than exclusive, because a pinch
    /// is two fingers and a drag is one; they are never the same touch, and a
    /// zoom that had to wait for the drag to decline would miss its first frame.
    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // Clamped rather than free: an unbounded pinch leaves the user
                // looking at four grey pixels with no way back.
                scale = min(max(committedScale * value.magnification, 1), 6)
            }
            .onEnded { _ in
                committedScale = scale
                if scale <= 1 { withAnimation(.snappy(duration: 0.2)) { resetZoom() } }
            }
    }

    private func toggleZoom() {
        withAnimation(.snappy(duration: 0.25)) {
            if isZoomed {
                resetZoom()
            } else {
                scale = 2.5
                committedScale = 2.5
            }
        }
    }

    private func resetZoom() {
        scale = 1
        committedScale = 1
        pan = .zero
        committedPan = .zero
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
        // Tied to the ground rather than to its own flag, so a drag takes the
        // bars with it. Chrome left hanging over a photo that is on its way out
        // is the clearest possible sign that two things are animating separately.
        .opacity(isChromeVisible ? backdropOpacity : 0)
        .animation(.easeInOut(duration: 0.2), value: isChromeVisible)
        .allowsHitTesting(isChromeVisible && dragOffset == .zero)
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
        // Tied to the ground rather than to its own flag, so a drag takes the
        // bars with it. Chrome left hanging over a photo that is on its way out
        // is the clearest possible sign that two things are animating separately.
        .opacity(isChromeVisible ? backdropOpacity : 0)
        .animation(.easeInOut(duration: 0.2), value: isChromeVisible)
        .allowsHitTesting(isChromeVisible && dragOffset == .zero)
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
    /// How far through a dismissal the finger has got, as a fraction of the
    /// screen. Everything the gesture animates is a function of this one number,
    /// which is what keeps the pieces moving together instead of each on its own
    /// arbitrary curve.
    private var dragProgress: CGFloat {
        guard canvas.height > 0 else { return 0 }
        return min(abs(dragOffset.height) / canvas.height, 1)
    }

    /// The ground clears as the picture is thrown, and it clears *early*: fully
    /// transparent by the time the drag is a third of the way down, so what is
    /// underneath is visible well before the gesture ends. That is the part that
    /// makes this read as putting the photo back where it came from rather than
    /// as sliding a black card away.
    private var backdropOpacity: Double {
        Double(max(1 - dragProgress * 3, 0))
    }

    /// Shrinks as it goes, and much more than a token amount. A picture that
    /// only barely changes size reads as stuck; one that visibly recedes reads
    /// as going back into the conversation.
    private var dragScale: CGFloat {
        max(1 - dragProgress * 0.7, 0.62)
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

    /// `nonisolated` because `flatMap` calls it outside the actor, and it only
    /// ever reads its argument.
    nonisolated static func mediaURL(of attachment: Message.Attachment) -> URL? {
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

/// One picture, drawn at the scale and offset it is told.
///
/// Owns nothing but its pixels. Every gesture lives in ``MediaViewer``, because
/// zoom, pan, page and dismiss are four readings of the same finger and only one
/// place can decide which of them a given touch is.
///
/// Built on the loader everything else uses, so an image already on screen in
/// the transcript opens instantly rather than downloading a second time. No
/// `maxPixelSize`: this is the one place the full resolution is the point.
private struct ZoomableImage: View {
    let url: URL?
    let scale: CGFloat
    let offset: CGSize
    let onLoad: (UIImage) -> Void

    var body: some View {
        // The `.large` copy is almost always already in memory, because the
        // bubble that was tapped drew it a moment ago. So the viewer opens on a
        // picture rather than on a spinner, and sharpens to the original once
        // that arrives.
        RemoteImage(
            url: url,
            previewURL: GroupMeImage.variant(.inline, of: url)
        ) {
            ProgressView().tint(.white)
        }
        .scaledToFit()
        .scaleEffect(scale)
        .offset(offset)
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
}

/// One video page, with a player it makes once and keeps.
///
/// `VideoPlayer(player: AVPlayer(url:))` written inline in a `body` is a new
/// player on every update, and this view updates on every frame of a page drag.
/// The first of those players is the expensive one: making it drags AVKit in
/// for the first time — class realisation, category loading, a view controller
/// full of transport chrome — and on a real phone that is a third of a second
/// on the main thread, spent *inside* the presentation's own layout pass, so
/// the viewer sits half-open while it happens.
///
/// Making it in a task instead lets the sheet finish arriving first, and ties
/// the player to the page rather than to the body.
private struct VideoPage: View {
    let url: URL
    /// True only for the page on screen. A player is a decoder and a network
    /// connection; three of them for three pages is three times the cost of the
    /// one actually being watched.
    let isCurrent: Bool

    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.clear
            if let player {
                VideoPlayer(player: player)
                    .transition(.opacity)
            }
        }
        .task(id: isCurrent) {
            guard isCurrent else {
                // Kept rather than torn down: coming back to a page should not
                // pay for it twice, and a paused player costs nothing to hold.
                player?.pause()
                return
            }
            guard player == nil else { return }
            player = AVPlayer(url: url)
        }
    }
}
