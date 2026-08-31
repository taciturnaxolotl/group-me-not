import SwiftUI
import UIKit

/// One reaction, drawn.
///
/// Reactions travel through this app as opaque `String` glyphs, which is nearly
/// always a character and occasionally a pack token (``Message/PackGlyph``).
/// This is the one place that has to know the difference, so every other view
/// can go on treating a glyph as a string.
struct ReactionGlyph: View {
    let glyph: String
    /// Point size of the drawn emoji, matching what `Text` would give it.
    var size: CGFloat

    var body: some View {
        if let pack = Message.PackGlyph(token: glyph) {
            PackSprite(pack: pack, size: size)
        } else {
            Text(glyph).font(.system(size: size))
        }
    }
}

/// A cell out of a powerup pack's sprite sheet.
///
/// The art is a single-column strip on S3, one square cell per emoji, which is
/// why an index is enough to find one: the official picker positions it with
/// `IntOffset(y: -cellSize * index)` and nothing else
/// (`com.groupme.emojipicker.feature.emoji.VerticalSpritePosition`).
///
/// Nothing waits on it. The slot is reserved at the right size from the first
/// frame and the art drops in when it arrives, so a picker opened on the subway
/// draws immediately with a hole where the sticker would be rather than
/// stalling on a request that is not coming.
private struct PackSprite: View {
    let pack: Message.PackGlyph
    let size: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                // The same footprint as the loaded art, so nothing reflows when
                // it appears.
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .task(id: pack) { await load() }
    }

    private func load() async {
        let loaded = await PowerupSprites.shared.cell(pack, scale: displayScale)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.15)) { image = loaded }
    }
}

/// Fetches powerup sprite sheets and cuts single emoji out of them.
///
/// One sheet holds a whole pack, so the first sticker from a pack pays for the
/// download and every other one is free. Sheets are immutable at their URL and
/// go through ``ImageLoader``, which means the bytes land in the same disk cache
/// as avatars and survive a relaunch: a pack seen once renders offline.
actor PowerupSprites {
    static let shared = PowerupSprites()

    private let cells = SpriteMemoryCache()

    /// The sheet for `packID`, at the density bucket nearest `scale`.
    ///
    /// The bucket names are the client's own (`Glyph.GroupMe.getImageSize`), and
    /// the sheet is verified to exist: a ranged GET for pack 1 through 4 at
    /// `xhdpi.80x80` returns 206 with content.
    nonisolated static func sheetURL(packID: Int, scale: CGFloat) -> URL? {
        let bucket = switch scale {
        case 4...: "xxxhdpi.160x160"
        case 3..<4: "xxhdpi.120x120"
        case 2..<3: "xhdpi.80x80"
        case 1.5..<2: "hdpi.60x60"
        default: "mdpi.40x40"
        }
        return URL(string: "https://powerups.s3.amazonaws.com/emoji/\(packID)/keyboard.\(bucket).png")
    }

    func cell(_ pack: Message.PackGlyph, scale: CGFloat) async -> UIImage? {
        let key = "\(pack.token)@\(Int(scale))"
        if let hit = cells.value(forKey: key) { return hit }
        guard let url = Self.sheetURL(packID: pack.packID, scale: scale) else { return nil }
        // No downsampling: the strip is one cell wide and hundreds tall, and
        // shrinking it to fit a thumbnail budget would destroy the cell.
        guard let sheet = await ImageLoader.shared.image(
            for: ImageLoader.Request(url: url, maxPixelSize: nil))
        else { return nil }
        guard let cut = Self.crop(sheet, index: pack.index) else { return nil }
        cells.insert(cut, forKey: key)
        return cut
    }

    /// The `index`-th square of a single-column strip. A pack index past the end
    /// of its sheet is a reaction from a pack we have an older copy of, so it
    /// draws as nothing rather than as somebody else's emoji.
    private static func crop(_ sheet: UIImage, index: Int) -> UIImage? {
        guard let source = sheet.cgImage else { return nil }
        let side = source.width
        guard side > 0 else { return nil }
        let origin = index * side
        guard origin >= 0, origin + side <= source.height else { return nil }
        guard let cut = source.cropping(
            to: CGRect(x: 0, y: origin, width: side, height: side))
        else { return nil }
        return UIImage(cgImage: cut, scale: sheet.scale, orientation: .up)
    }
}

/// Same trick as `ImageMemoryCache`: an `NSCache` whose safety is stated rather
/// than assumed.
nonisolated private final class SpriteMemoryCache: @unchecked Sendable {
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.countLimit = 300 }

    func value(forKey key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    func insert(_ image: UIImage, forKey key: String) { cache.setObject(image, forKey: key as NSString) }
}
