import CoreGraphics
import Foundation

/// The pixel size GroupMe writes into its media URLs.
///
/// Every host puts the dimensions in the path, and every host puts them
/// somewhere different:
///
///     https://i.groupme.com/486x281.jpeg.6381f1f67dd64013a98e2c945044fab1
///     https://m.groupme.com/uploads/659c31aa…/3024x4032.original.jpeg
///     https://v.groupme.com/117088005/2026-08-31T05:48:48Z/7ee0c134.1126x2436r0.mp4
///
/// So a photo's shape is known before a byte of it is fetched. That is the whole
/// trick behind drawing images at their true aspect ratio without the transcript
/// jumping when they arrive: the box is reserved from the URL, and the pixels
/// land in a space that was already the right shape.
nonisolated enum MediaDimensions {

    /// The size declared by the URL, or nil when it declares none.
    ///
    /// Scans every dot-separated piece of every path component rather than
    /// guessing which one holds it. The previous version read only the first
    /// component, which is right for `i.groupme.com` and wrong for both of the
    /// others, so every photo posted through media v2 and every video fell back
    /// to a fixed box and drew cropped.
    static func declared(in url: URL?) -> CGSize? {
        guard let url else { return nil }
        for component in url.pathComponents where component != "/" {
            for piece in component.split(separator: ".") {
                if let size = parse(String(piece)) { return size }
            }
        }
        return nil
    }

    /// Reads `486x281`, or `1126x2436r0` with the transcoder's rotation suffix.
    static func parse(_ piece: String) -> CGSize? {
        // `r` and anything after it is orientation, not size.
        let stem = piece.split(separator: "r", maxSplits: 1).first.map(String.init) ?? piece
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

/// The resized copies GroupMe will serve of a picture it hosts.
///
/// Two hosts, two schemes, measured 2026-08-31 against live images:
///
/// `i.groupme.com`, by appending a suffix:
///
/// | suffix     | from 1024×1024 | bytes  |
/// | ---------- | -------------- | ------ |
/// | *(none)*   | 1024×1024      | 207 KB |
/// | `.large`   | 960×960        | 122 KB |
/// | `.preview` | 200×200        | 13 KB  |
/// | `.avatar`  | 60×60          | 2.5 KB |
///
/// `m.groupme.com`, by replacing the `.original` segment:
///
/// | segment      | from 1333×1000 | bytes  |
/// | ------------ | -------------- | ------ |
/// | `.original`  | 1333×1000      | 163 KB |
/// | `.large`     | 1200×900       | 68 KB  |
/// | `.small`     | 300×225        | 15 KB  |
///
/// The difference that matters: `i.groupme.com`'s small copies are **square
/// crops**, while `m.groupme.com`'s keep the aspect ratio. So the placeholder
/// from one host is a stand-in and the placeholder from the other is genuinely
/// the picture, smaller.
///
/// This is worth a great deal on a weak connection, which is the point of this
/// client. Drawing a photo 240 points wide needs 720 pixels at the very most; a
/// transcript was downloading half-megabyte originals to do it.
nonisolated enum GroupMeImage {
    /// What a copy is *for*, rather than what it is called. The names differ by
    /// host and the callers do not care.
    enum Size {
        /// Big enough for anything drawn inline in a transcript.
        case inline
        /// Small enough to arrive almost at once, for standing in while the
        /// real picture loads.
        case placeholder
        /// A face in a list.
        case face
    }

    /// The named rendering of `url`, or nil when there is no such thing.
    ///
    /// Nil rather than a guess for any host that is not GroupMe's: a
    /// `linked_image` can point anywhere, and a video poster on
    /// `v.groupme.com` is served at one size only.
    static func variant(_ size: Size, of url: URL?) -> URL? {
        guard let url else { return nil }
        switch url.host() {
        case "i.groupme.com": return appendingSuffix(size, to: url)
        case "m.groupme.com": return replacingSegment(size, in: url)
        default: return nil
        }
    }

    // MARK: i.groupme.com

    private static func appendingSuffix(_ size: Size, to url: URL) -> URL? {
        let suffix: String
        switch size {
        case .inline: suffix = "large"
        case .placeholder: suffix = "preview"
        case .face: suffix = "avatar"
        }
        let name = url.lastPathComponent
        // A variant of a variant is a 404.
        guard !["large", "preview", "avatar"].contains(where: { name.hasSuffix(".\($0)") })
        else { return nil }
        return URL(string: url.absoluteString + "." + suffix)
    }

    // MARK: m.groupme.com

    /// `/uploads/{id}/{width}x{height}.{segment}.{ext}`, where the segment names
    /// the rendering. Rewritten in place rather than appended, because appending
    /// would leave `.original` in the path and the service would ignore us.
    private static func replacingSegment(_ size: Size, in url: URL) -> URL? {
        let segment: String
        switch size {
        case .inline: segment = "large"
        // No `.avatar` on this host, and `.small` is 15 KB, which is a perfectly
        // good face and a perfectly good stand-in.
        case .placeholder, .face: segment = "small"
        }

        var components = url.pathComponents.filter { $0 != "/" }
        guard let name = components.popLast() else { return nil }
        var pieces = name.split(separator: ".").map(String.init)
        guard pieces.count >= 3,
              ["original", "large", "small", "thumbnail"].contains(pieces[pieces.count - 2])
        else { return nil }
        pieces[pieces.count - 2] = segment

        var rebuilt = URLComponents(url: url, resolvingAgainstBaseURL: false)
        rebuilt?.path = "/" + (components + [pieces.joined(separator: ".")]).joined(separator: "/")
        return rebuilt?.url
    }
}
