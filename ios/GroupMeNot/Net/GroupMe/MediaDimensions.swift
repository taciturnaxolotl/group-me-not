import CoreGraphics
import Foundation

/// The pixel size GroupMe writes into its media URLs.
///
/// Their CDN names every upload after the picture's dimensions:
///
///     https://i.groupme.com/486x281.jpeg.6381f1f67dd64013a98e2c945044fab1
///     https://i.groupme.com/1024x1024.jpeg.45043fe768fd4636bfc6b8fffd8d7389
///
/// The leading path component is `{width}x{height}`, so a photo's shape is
/// known before a byte of it is fetched. That is the whole trick behind drawing
/// images at their true aspect ratio without the transcript jumping when they
/// arrive: the box is reserved from the URL, and the pixels land inside a
/// space that was already the right shape.
nonisolated enum MediaDimensions {

    /// The size declared by the URL, or nil when it declares none.
    ///
    /// Plenty of URLs take the nil path and that is fine: older messages, other
    /// hosts, some video stills, and the `file://` URLs a queued upload points
    /// at while it is still on the phone. Callers fall back to a fixed box for
    /// those rather than guessing a shape.
    static func declared(in url: URL?) -> CGSize? {
        guard let url, let first = url.pathComponents.first(where: { $0 != "/" }) else { return nil }
        return parse(first)
    }

    /// Reads `486x281` off the front of a filename, ignoring the extension and
    /// the hash that follow it.
    static func parse(_ component: String) -> CGSize? {
        guard let stem = component.split(separator: ".").first else { return nil }
        let parts = stem.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let width = Int(parts[0]), let height = Int(parts[1]),
              // Anything outside this is a filename that merely looks like a
              // size, not a picture we are about to draw.
              (1...20_000).contains(width), (1...20_000).contains(height)
        else { return nil }
        return CGSize(width: width, height: height)
    }
}


/// The resized copies GroupMe's CDN will serve of any picture it hosts.
///
/// Appending a suffix to an `i.groupme.com` URL returns a smaller rendering of
/// the same image. Measured against two live pictures on 2026-08-31:
///
/// | suffix     | 1024×1024 source | bytes   |
/// | ---------- | ---------------- | ------- |
/// | *(none)*   | 1024×1024        | 207 KB  |
/// | `.large`   | 960×960          | 122 KB  |
/// | `.preview` | 200×200          | 13 KB   |
/// | `.avatar`  | 60×60            | 2.5 KB  |
///
/// `.large` caps the long edge at 960 and keeps the aspect ratio. `.preview`
/// and `.avatar` are square: they crop rather than letterbox, so they are
/// stand-ins and thumbnails, never the picture itself.
///
/// This is worth a good deal on a weak connection, which is the whole point of
/// this client. A transcript full of photographs was downloading full-resolution
/// originals to draw them 240 points wide.
nonisolated enum GroupMeImage {
    enum Variant: String {
        /// The long edge capped at 960. Plenty for anything drawn inline.
        case large
        /// 200 square. Small enough to arrive almost at once, which makes it the
        /// thing to show while the real picture is still coming.
        case preview
        /// 60 square, for a face in a list.
        case avatar
    }

    private static let host = "i.groupme.com"

    /// The named rendering of `url`, or nil when there is no such thing.
    ///
    /// Nil rather than a guess for anything not on GroupMe's own picture host:
    /// a `linked_image` can point anywhere, and appending `.preview` to somebody
    /// else's URL is a request for a file that does not exist.
    static func variant(_ variant: Variant, of url: URL?) -> URL? {
        guard let url, url.host() == host else { return nil }
        let name = url.lastPathComponent
        // Already a variant. Asking for a variant of a variant is a 404.
        guard !Variant.allSuffixes.contains(where: { name.hasSuffix($0) }) else { return nil }
        return URL(string: url.absoluteString + "." + variant.rawValue)
    }
}

private extension GroupMeImage.Variant {
    static let allSuffixes: [String] = [".large", ".preview", ".avatar"]
}
