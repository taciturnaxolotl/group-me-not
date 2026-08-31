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
