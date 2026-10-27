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
    /// Starts a reply to the message the pictures came in. Nil hides the button.
    var onReply: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var index: Int = 0
    /// Whether the bars are showing. Starts shown, the way Photos and Messages
    /// open: the controls are how you learn what the viewer can do, and a tap
    /// on the picture clears them when you only want to look.
    @State private var isChromeVisible = true
    /// Whether the run is laid out as a grid instead of one page at a time.
    @State private var isShowingGrid = false
    /// Asking whether to save a second copy of a photo already in the library.
    @State private var isConfirmingDuplicate = false
    /// The loaded picture, held here rather than inside the zoom view so the
    /// share and save actions have something to hand over.
    @State private var image: UIImage?
    /// How far a dismissing drag has got, and how much of the ground it has
    /// taken with it.
    @State private var dragOffset: CGSize = .zero
    @State private var saveResult: SaveResult?
    /// Bumped on every successful save. A save that worked is confirmed with
    /// a tap of the haptic engine rather than an alert to dismiss.
    @State private var saveCount = 0
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
        .overlay {
            if isShowingGrid {
                MediaGrid(
                    attachments: attachments,
                    onOpen: { position in
                        resetZoom()
                        index = position
                        withAnimation(.easeInOut(duration: 0.2)) { isShowingGrid = false }
                    },
                    onBack: { withAnimation(.easeInOut(duration: 0.2)) { isShowingGrid = false } },
                    onReply: onReply.map { reply in { close(then: reply) } },
                    onSave: save(_:))
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!isChromeVisible && !isShowingGrid)
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
        .sensoryFeedback(.success, trigger: saveCount)
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
                    pan = clamped(
                        CGSize(
                            width: committedPan.width + value.translation.width,
                            height: committedPan.height + value.translation.height),
                        at: scale)
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
                // Zooming out gives back the room the picture was using, so the
                // pan comes back in with it rather than leaving the photo
                // parked off to one side at life size.
                pan = clamped(pan, at: scale)
            }
            .onEnded { _ in
                committedScale = scale
                committedPan = pan
                if scale <= 1 { withAnimation(.snappy(duration: 0.2)) { resetZoom() } }
            }
    }

    /// A pan held inside the picture's own edges.
    ///
    /// The room to move is however much of the photo the canvas cannot show at
    /// this zoom, halved because the overflow is shared between the two sides.
    /// Zero on an axis that does not overflow, which is what keeps a letterboxed
    /// photo centred however hard it is shoved, and what stops a zoomed one from
    /// being flung somewhere there is no gesture to bring it back from.
    private func clamped(_ pan: CGSize, at scale: CGFloat) -> CGSize {
        let drawn = drawnSize ?? canvas
        let room = CGSize(
            width: max(0, (drawn.width * scale - canvas.width) / 2),
            height: max(0, (drawn.height * scale - canvas.height) / 2))
        return CGSize(
            width: min(max(pan.width, -room.width), room.width),
            height: min(max(pan.height, -room.height), room.height))
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
            if attachments.count > 1 {
                circleButton("square.grid.2x2", label: "All Photos") {
                    withAnimation(.easeInOut(duration: 0.2)) { isShowingGrid = true }
                }
            } else {
                // Balances the close button so the title sits truly centred.
                Color.clear.frame(width: 40, height: 40)
            }
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
            Button("Save to Photos", systemImage: "square.and.arrow.down", action: saveCurrent)
                .disabled(attachment == nil)
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

    /// Two clusters, the way Photos lays it out: things you do *with* the
    /// picture on the leading edge, and the ways it leaves the app on the
    /// trailing one. Each cluster is one capsule of glass rather than a row of
    /// separate buttons, so it reads as a toolbar instead of as scattered dots.
    private var bottomBar: some View {
        HStack {
            HStack(spacing: 4) {
                toolbarButton(isZoomed ? "minus.magnifyingglass" : "plus.magnifyingglass",
                              label: isZoomed ? "Zoom Out" : "Zoom In", action: toggleZoom)
                if let onReply {
                    toolbarButton("arrowshape.turn.up.left", label: "Reply") { close(then: onReply) }
                }
            }
            .glassEffect(.regular.interactive(), in: .capsule)

            Spacer()

            HStack(spacing: 4) {
                toolbarButton(saveSymbol, label: "Save to Photos",
                              action: saveCurrent)
                    .disabled(attachment == nil)
                    .duplicatePrompt(isPresented: $isConfirmingDuplicate, count: 1) { saveCurrent(force: true) }
                shareButton
            }
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .padding(.top, 24)
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

    /// The decoded picture when there is one, so the share sheet shows a
    /// preview; the file itself otherwise, which is what a video needs.
    @ViewBuilder private var shareButton: some View {
        if let image {
            ShareLink(
                item: Image(uiImage: image),
                preview: SharePreview("Photo", image: Image(uiImage: image))
            ) { toolbarGlyph("square.and.arrow.up") }
                .accessibilityLabel("Share")
        } else if let mediaURL {
            ShareLink(item: mediaURL) { toolbarGlyph("square.and.arrow.up") }
                .accessibilityLabel("Share")
        }
    }

    private func toolbarButton(
        _ symbol: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { toolbarGlyph(symbol) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }

    private func toolbarGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 52, height: 48)
            .contentShape(.rect)
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
    /// Unknown shapes answer true, because a bar that is occasionally redundant
    /// is a much smaller fault than a close button nobody can see.
    private var barOverlapsPicture: Bool {
        guard topBarHeight > 0, let drawn = drawnSize else { return true }
        return (canvas.height - drawn.height) / 2 < topBarHeight
    }

    /// The picture's rectangle at life size, which is what both the bar's ground
    /// and the pan's bounds are measured against. Nil while the shape is unknown:
    /// the dimensions come out of the URL, and a photo that has not arrived yet
    /// has none to declare.
    private var drawnSize: CGSize? {
        guard canvas.width > 0, canvas.height > 0,
            let size = MediaDimensions.declared(in: mediaURL) ?? image?.size,
            size.width > 0, size.height > 0
        else { return nil }
        let fit = min(canvas.width / size.width, canvas.height / size.height)
        return CGSize(width: size.width * fit, height: size.height * fit)
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

    /// Saves the photo on screen, or, if this phone has saved it before, asks
    /// first, the way Photos does when you save something it already has.
    private func saveCurrent() { saveCurrent(force: false) }

    /// Filled once the photo is in the library, and every time it is opened
    /// after that. The change of icon is the confirmation; nothing else is.
    private var saveSymbol: String {
        guard let attachment, PhotoLibrary.isSaved(attachment) else { return "square.and.arrow.down" }
        return "square.and.arrow.down.fill"
    }

    private func saveCurrent(force: Bool) {
        guard let attachment else { return }
        if !force, PhotoLibrary.isSaved(attachment) {
            isConfirmingDuplicate = true
            return
        }
        Task {
            _ = await save([attachment])
        }
    }

    /// Saves the originals, not the decoded picture on screen, so a photo keeps
    /// its resolution and a video is saved as a video. Only failures speak up.
    private func save(_ items: [Message.Attachment]) async -> Bool {
        do {
            try await PhotoLibrary.save(items)
            saveCount += 1
            return true
        } catch PhotoLibrary.SaveError.denied {
            saveResult = .denied
        } catch {
            saveResult = .failed
        }
        return false
    }

    /// Takes the viewer down before acting, for actions that belong to the
    /// conversation underneath rather than to the picture.
    private func close(then action: @escaping () -> Void) {
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            action()
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

/// What to say after a save that did not work. Success gets no alert, only a
/// haptic: an alert asks to be dismissed, and a save that worked has nothing
/// to say that needs answering.
private enum SaveResult: String, Identifiable {
    case denied, failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .denied: "No Access to Photos"
        case .failed: "Could Not Save"
        }
    }

    var message: String {
        switch self {
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

/// Every picture in the run at once, two to a row.
///
/// Each photo sits in a square cell at its own shape, the way the Photos
/// album view draws a burst: portraits stand tall, landscapes lie flat, and
/// nothing is cropped to make the grid tidier than the pictures are.
private struct MediaGrid: View {
    let attachments: [Message.Attachment]
    let onOpen: (Int) -> Void
    let onBack: () -> Void
    let onReply: (() -> Void)?
    let onSave: ([Message.Attachment]) async -> Bool

    @State private var isSelecting = false
    @State private var selected: Set<Int> = []
    @State private var isSaving = false
    @State private var isConfirmingDuplicate = false

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { position, item in
                    cell(item, at: position)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .top, spacing: 12) { topBar }
        .background(Color(white: 0.11).ignoresSafeArea())
        .sensoryFeedback(.selection, trigger: selected)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            glassCircle("chevron.left", label: "Back", action: onBack)
            Spacer()
            glassCircle(saveSymbol, label: saveLabel, action: save)
                .disabled(isSaving || (isSelecting && selected.isEmpty))
                .duplicatePrompt(isPresented: $isConfirmingDuplicate, count: itemsToSave.count) {
                    save(force: true)
                }
            if let onReply, !isSelecting {
                glassCircle("arrowshape.turn.up.left", label: "Reply", action: onReply)
            }
            Button(isSelecting ? "Done" : "Select") {
                withAnimation(.snappy(duration: 0.2)) {
                    isSelecting.toggle()
                    selected = []
                }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var saveSymbol: String {
        return PhotoLibrary.areAllSaved(itemsToSave) ? "square.and.arrow.down.fill" : "square.and.arrow.down"
    }

    private var saveLabel: String {
        return isSelecting ? "Save \(selected.count) Selected" : "Save All"
    }

    private func cell(_ item: Message.Attachment, at position: Int) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let box = fitted(item, in: proxy.size)
                    RemoteImage(
                        url: GroupMeImage.variant(.inline, of: Self.stillURL(of: item)) ?? Self.stillURL(of: item),
                        maxPixelSize: proxy.size.width * 3,
                        blurHash: item.blurHash
                    ) {
                        Rectangle().fill(.white.opacity(0.08))
                    }
                    .frame(width: box.width, height: box.height)
                    .clipShape(.rect(cornerRadius: 22, style: .continuous))
                    .overlay {
                        if item.type == "video" {
                            Image(systemName: "play.circle.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.white, .black.opacity(0.35))
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isSelecting { checkmark(selected.contains(position)) }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .contentShape(.rect)
            .onTapGesture {
                guard isSelecting else { return onOpen(position) }
                if selected.contains(position) { selected.remove(position) } else { selected.insert(position) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.type == "video" ? "Video" : "Photo")
            .accessibilityAddTraits(selected.contains(position) ? [.isButton, .isSelected] : .isButton)
    }

    private func checkmark(_ isOn: Bool) -> some View {
        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 24))
            .foregroundStyle(.white, isOn ? Color.accentColor : .clear)
            .shadow(color: .black.opacity(0.4), radius: 2)
            .padding(8)
    }

    /// The largest box of the picture's shape that fits the cell, or the whole
    /// cell when the URL does not say what shape that is.
    private func fitted(_ item: Message.Attachment, in cell: CGSize) -> CGSize {
        guard let size = MediaDimensions.declared(in: Self.stillURL(of: item)),
            size.width > 0, size.height > 0
        else { return cell }
        let fit = min(cell.width / size.width, cell.height / size.height)
        return CGSize(width: size.width * fit, height: size.height * fit)
    }

    private static func stillURL(of item: Message.Attachment) -> URL? {
        (item.previewUrl ?? item.url ?? item.sourceUrl).flatMap(URL.init(string:))
    }

    private var itemsToSave: [Message.Attachment] {
        isSelecting ? selected.sorted().map { attachments[$0] } : attachments
    }

    private func save() { save(force: false) }

    private func save(force: Bool) {
        let items = itemsToSave
        guard !items.isEmpty else { return }
        if !force, PhotoLibrary.areAllSaved(items) {
            isConfirmingDuplicate = true
            return
        }
        isSaving = true
        Task {
            let worked = await onSave(items)
            isSaving = false
            guard worked else { return }
            withAnimation(.snappy) {
                isSelecting = false
                selected = []
            }
        }
    }

    private func glassCircle(
        _ symbol: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

extension View {
    /// The question Photos asks when you save something it already has.
    ///
    /// A confirmation dialog anchored to the save button, which iOS draws as a
    /// popover coming off the button rather than as a sheet across the screen.
    func duplicatePrompt(
        isPresented: Binding<Bool>, count: Int, saveAnyway: @escaping () -> Void
    ) -> some View {
        confirmationDialog("Already Saved", isPresented: isPresented, titleVisibility: .hidden) {
            Button(count == 1 ? "Save Duplicate" : "Save Duplicates", action: saveAnyway)
        } message: {
            Text(count == 1
                ? "This photo has already been saved to your photo library."
                : "These photos have already been saved to your photo library.")
        }
    }
}
