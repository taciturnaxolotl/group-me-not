import CoreGraphics
import UIKit

/// Decodes the `blur_hash` GroupMe attaches to most media-v2 uploads.
///
/// A hundred-odd characters that unpack into a blurred approximation of the
/// picture. The point is not that it is pretty; the point is that it needs no
/// request. Every other placeholder in this app, however small, is a round trip
/// that has to finish before anything appears, and on the connections this
/// client exists for that is the difference between a transcript of photographs
/// and a transcript of grey rectangles.
///
/// The format is [blurha.sh](https://blurha.sh): base-83 digits holding a few
/// DCT components. This is the reference decoder, transcribed; the only liberty
/// taken is refusing malformed input rather than trapping on it, because the
/// string comes off the wire and a bad one must cost a placeholder, not a crash.
nonisolated enum BlurHash {

    /// A blurred image of `size` points, or nil if the hash is not one.
    ///
    /// Deliberately tiny by default. The result is blurred beyond recognition
    /// anyway, so decoding it at display resolution is arithmetic nobody can
    /// see; a 32-point image stretched over a bubble looks identical and costs a
    /// thousandth as much.
    static func image(from hash: String, size: CGSize = CGSize(width: 32, height: 32)) -> UIImage? {
        let digits = hash.unicodeScalars.map { alphabet[$0] ?? -1 }
        guard digits.count >= 6, !digits.contains(-1) else { return nil }

        // The first digit packs the component counts: 1...9 each way.
        let sizeFlag = digits[0]
        let columns = (sizeFlag % 9) + 1
        let rows = (sizeFlag / 9) + 1
        guard digits.count == 4 + 2 * columns * rows else { return nil }

        let maximum = (Double(digits[1]) + 1) / 166
        var components: [(Double, Double, Double)] = []
        components.reserveCapacity(columns * rows)

        for index in 0..<(columns * rows) {
            if index == 0 {
                let value = decode(digits, at: 2, count: 4)
                components.append(decodeDC(value))
            } else {
                let value = decode(digits, at: 4 + index * 2, count: 2)
                components.append(decodeAC(value, maximum: maximum))
            }
        }

        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var r = 0.0, g = 0.0, b = 0.0
                for j in 0..<rows {
                    for i in 0..<columns {
                        let basis = cos(Double.pi * Double(x) * Double(i) / Double(width))
                            * cos(Double.pi * Double(y) * Double(j) / Double(height))
                        let component = components[i + j * columns]
                        r += component.0 * basis
                        g += component.1 * basis
                        b += component.2 * basis
                    }
                }
                let offset = (y * width + x) * 4
                pixels[offset] = toByte(r)
                pixels[offset + 1] = toByte(g)
                pixels[offset + 2] = toByte(b)
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true,
                intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: Base 83

    private static let characters = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")

    /// Built once. Decoding a hash per image with a linear search through 83
    /// characters per digit would be the slowest part of a job whose entire
    /// selling point is that it is instant.
    private static let alphabet: [Unicode.Scalar: Int] = {
        var table: [Unicode.Scalar: Int] = [:]
        for (index, character) in characters.enumerated() {
            table[character.unicodeScalars.first!] = index
        }
        return table
    }()

    private static func decode(_ digits: [Int], at offset: Int, count: Int) -> Int {
        digits[offset..<(offset + count)].reduce(0) { $0 * 83 + $1 }
    }

    // MARK: Colour

    private static func decodeDC(_ value: Int) -> (Double, Double, Double) {
        (linear(value >> 16), linear((value >> 8) & 255), linear(value & 255))
    }

    private static func decodeAC(_ value: Int, maximum: Double) -> (Double, Double, Double) {
        let r = Double(value / (19 * 19))
        let g = Double((value / 19) % 19)
        let b = Double(value % 19)
        return (signPow((r - 9) / 9) * maximum,
                signPow((g - 9) / 9) * maximum,
                signPow((b - 9) / 9) * maximum)
    }

    private static func signPow(_ value: Double) -> Double {
        copysign(pow(abs(value), 2), value)
    }

    /// sRGB to linear, and back below. The blur is averaged in linear light,
    /// which is the only place averaging colours gives the colour a person would
    /// call the average.
    private static func linear(_ value: Int) -> Double {
        let v = Double(value) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func toByte(_ value: Double) -> UInt8 {
        let clamped = max(0, min(1, value))
        let srgb = clamped <= 0.0031308
            ? clamped * 12.92
            : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, (srgb * 255).rounded())))
    }
}
