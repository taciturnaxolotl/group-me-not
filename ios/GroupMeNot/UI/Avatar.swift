import SwiftUI
import UIKit

// MARK: - Avatar

/// A circular profile or group image with an initials fallback.
///
/// Every avatar in the app goes through here so that the same face loads once
/// and then comes out of memory, including across cell reuse. Sizing is
/// explicit rather than inherited, because a list row that lets its image
/// decide its own height is a list row that jumps.
struct Avatar: View {
    /// The remote image, if the server gave us one.
    let url: String?
    /// The name to derive initials from when there is no image.
    let name: String
    /// Diameter in points. Grows with Dynamic Type at the call site, not here.
    var size: CGFloat = 48
    /// Groups without a picture get a people glyph rather than initials, which
    /// read as a person's name and mislead.
    var isGroup: Bool = false

    var body: some View {
        RemoteImage(
            url: source,
            // Retina plus a little headroom. Downsampling at decode time is
            // what keeps a list of forty avatars off the main thread.
            maxPixelSize: size * 3
        ) {
            InitialsFill(name: name, isGroup: isGroup)
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        // The surrounding row already speaks the name; a second reading of it
        // just slows VoiceOver down.
        .accessibilityHidden(true)
    }

    /// A rendering big enough for the size being drawn, and no bigger.
    ///
    /// A profile picture is stored at whatever size it was uploaded, which for a
    /// photo off a phone is a couple of hundred kilobytes drawn at 28 points. The
    /// small copies exist precisely for this, so a conversation list of forty
    /// faces costs kilobytes rather than megabytes.
    ///
    /// The threshold is the size the copy actually is. GroupMe's face rendering
    /// is 60 pixels square, so it holds up to 20 points on a 3× screen and turns
    /// soft above that; a header drawn at 56 needs the next one up. Deriving it
    /// from `size` means no call site has to remember this, and one that changes
    /// its mind about how big it wants to be gets the right file automatically.
    private var source: URL? {
        let original = URL(string: url ?? "")
        let wanted: GroupMeImage.Size = size * 3 <= 60 ? .face : .placeholder
        return GroupMeImage.variant(wanted, of: original) ?? original
    }
}

/// The fallback: two initials on a colour derived from the name, so the same
/// person is the same colour every time you see them.
private struct InitialsFill: View {
    let name: String
    let isGroup: Bool

    var body: some View {
        ZStack {
            Rectangle().fill(tint.gradient)
            if let initials {
                Text(initials)
                    .font(.system(size: 100, weight: .medium, design: .rounded))
                    .minimumScaleFactor(0.01)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .foregroundStyle(.white)
            } else {
                Image(systemName: isGroup ? "person.2.fill" : "person.fill")
                    .font(.system(size: 100))
                    .minimumScaleFactor(0.01)
                    .padding(10)
                    .foregroundStyle(.white)
            }
        }
    }

    /// Up to two initials, taken from the first and last word. Grapheme
    /// clusters, not scalars, so an emoji or an accented letter survives.
    private var initials: String? {
        let words = name
            .split(whereSeparator: { $0.isWhitespace })
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber || $0.unicodeScalars.first?.properties.isEmoji == true }) }
        guard let first = words.first else { return nil }
        let letters = [first.first].compactMap(\.self)
            + (words.count > 1 ? [words[words.index(before: words.endIndex)].first].compactMap(\.self) : [])
        let result = String(letters).uppercased()
        return result.isEmpty ? nil : result
    }

    /// System colours only, so the palette follows the user's appearance and
    /// accessibility settings instead of fighting them.
    private var tint: Color {
        let palette: [Color] = [.blue, .indigo, .purple, .pink, .red, .orange, .brown, .green, .teal, .cyan]
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

// MARK: - Remote image

/// An image loaded from the network, cached in memory, with a placeholder that
/// occupies the same space.
///
/// `AsyncImage` re-fetches on every reappearance, which in a scrolling list
/// means a flicker per cell and a redundant request per scroll. This keeps a
/// decoded copy, so the second showing is synchronous and silent.
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    var maxPixelSize: CGFloat?
    /// A smaller copy of the same picture, shown while the real one is on its
    /// way. Loaded in parallel rather than in sequence: it is a head start, not
    /// a step the full image has to wait behind.
    var previewURL: URL?
    /// The `blur_hash` GroupMe sent with this attachment, if it sent one. The
    /// only placeholder that needs no network at all, so it is the one that is
    /// there on the frame the message appears.
    var blurHash: String?
    /// The pixel size of whatever arrived, for callers that reserved space from
    /// a guess and want to correct it. Ignored by everything drawing into a
    /// fixed box, which is most of them.
    var onLoad: ((CGSize) -> Void)?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var preview: UIImage?
    @State private var blurred: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if let preview {
                // Blurred, and not out of decoration. It is a 200-pixel crop
                // standing in for a full photograph; drawn sharp it reads as a
                // bad image rather than as one that has not arrived. Blurred it
                // reads as exactly what it is.
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 8)
                    .clipped()
                    .transition(.opacity)
            } else if let blurred {
                Image(uiImage: blurred)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                placeholder()
            }
        }
        // Keyed on the request, so a reused row cancels the load it no longer
        // wants and starts the one it does.
        .task(id: request) { await load() }
        .task(id: previewRequest) { await loadPreview() }
        .task(id: blurHash) { await decodeHash() }
    }

    /// Off the main actor, because it is a loop over every pixel of the result
    /// and the result is wanted during a scroll.
    private func decodeHash() async {
        guard let blurHash, !blurHash.isEmpty else {
            blurred = nil
            return
        }
        let decoded = await Task.detached(priority: .utility) {
            BlurHash.image(from: blurHash)
        }.value
        guard !Task.isCancelled, image == nil else { return }
        blurred = decoded
    }

    private var previewRequest: ImageLoader.Request? {
        previewURL.map { ImageLoader.Request(url: $0, maxPixelSize: nil) }
    }

    /// Races the real load rather than gating it. If the full picture wins, this
    /// result is simply never drawn, which costs 13 KB and is the right trade at
    /// any speed worth having a placeholder for.
    private func loadPreview() async {
        guard let previewRequest else {
            preview = nil
            return
        }
        if let hit = ImageLoader.shared.cached(previewRequest) {
            preview = hit
            return
        }
        preview = nil
        let loaded = await ImageLoader.shared.image(for: previewRequest)
        guard !Task.isCancelled, image == nil else { return }
        withAnimation(.easeOut(duration: 0.12)) { preview = loaded }
    }

    private var request: ImageLoader.Request? {
        url.map { ImageLoader.Request(url: $0, maxPixelSize: maxPixelSize) }
    }

    private func load() async {
        guard let request else {
            image = nil
            return
        }
        // A cache hit resolves before the first frame, so a scrolled-back-to
        // row never flashes its placeholder.
        if let hit = ImageLoader.shared.cached(request) {
            image = hit
            onLoad?(hit.size)
            return
        }
        image = nil
        let loaded = await ImageLoader.shared.image(for: request)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.15)) { image = loaded }
        if let loaded { onLoad?(loaded.size) }
    }
}

/// Fetches, downsamples, and remembers images.
///
/// Two layers: `URLCache` on disk for the bytes, and an `NSCache` of decoded,
/// display-ready `UIImage`s for the pixels. The second is what actually makes
/// scrolling smooth, since decoding a JPEG is far more expensive than reading
/// one off flash.
actor ImageLoader {
    static let shared = ImageLoader()

    /// A URL plus the size we want it at. Two sizes of the same picture are
    /// two cache entries, because sharing them would mean re-scaling.
    nonisolated struct Request: Hashable, Sendable {
        var url: URL
        var maxPixelSize: CGFloat?

        var cacheKey: String {
            maxPixelSize.map { "\(url.absoluteString)@\(Int($0))" } ?? url.absoluteString
        }
    }

    /// Thread-safe by construction, so the synchronous peek below does not need
    /// to hop onto the actor and cost a frame.
    nonisolated private let memory = ImageMemoryCache()
    private var inFlight: [Request: Task<UIImage?, Never>] = [:]
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(
            memoryCapacity: 8 * 1024 * 1024,
            diskCapacity: 128 * 1024 * 1024,
            directory: nil
        )
        // Avatars and photos are immutable at their URL, so the disk copy is
        // always good enough and worth preferring over a round trip.
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration)
    }

    /// The decoded image if we already have it. Safe to call from `body`.
    nonisolated func cached(_ request: Request) -> UIImage? {
        memory.value(forKey: request.cacheKey)
    }

    /// Loads the image, joining an existing load for the same request rather
    /// than starting a second one. A list of forty rows showing the same
    /// group's photo makes exactly one request.
    func image(for request: Request) async -> UIImage? {
        if let hit = memory.value(forKey: request.cacheKey) { return hit }
        if let existing = inFlight[request] { return await existing.value }

        let task = Task<UIImage?, Never> { [session] in
            guard let (data, response) = try? await session.data(from: request.url) else { return nil }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            guard let decoded = UIImage(data: data) else { return nil }
            return await Self.prepare(decoded, maxPixelSize: request.maxPixelSize)
        }
        inFlight[request] = task
        let image = await task.value
        inFlight[request] = nil

        if let image {
            memory.insert(image, forKey: request.cacheKey)
        }
        return image
    }

    /// Downsamples and pre-decodes off the main thread. `byPreparingThumbnail`
    /// does both in one pass; `byPreparingForDisplay` handles the full-size
    /// case where there is nothing to shrink.
    private static func prepare(_ image: UIImage, maxPixelSize: CGFloat?) async -> UIImage? {
        guard let maxPixelSize else { return await image.byPreparingForDisplay() ?? image }
        let longest = max(image.size.width, image.size.height) * image.scale
        guard longest > maxPixelSize, longest > 0 else {
            return await image.byPreparingForDisplay() ?? image
        }
        let ratio = maxPixelSize / longest
        let target = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        return await image.byPreparingThumbnail(ofSize: target) ?? image
    }
}

/// A thin wrapper so the `NSCache` generic can cross isolation boundaries with
/// its safety spelled out rather than assumed.
nonisolated private final class ImageMemoryCache: @unchecked Sendable {
    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 500
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func value(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, forKey key: String) {
        // Cost in bytes, roughly, so the limit means what it says.
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}
