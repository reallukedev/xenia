import CoreGraphics
import Foundation
import Testing
@testable import Xenia

@Suite("BlurHash")
struct BlurHashTests {
    @Test("Decodes the reference hash and refuses malformed ones")
    func decoding() throws {
        let image = try #require(BlurHash.image("LEHV6nWB2yk8pyo0adR*.7kCMdnj", width: 24, height: 16))
        #expect(image.width == 24 && image.height == 16)
        // One character short, an unknown character, and nothing at all.
        #expect(BlurHash.image("LEHV6nWB2yk8pyo0adR*.7kCMdn") == nil)
        #expect(BlurHash.image("LEHV6nWB2yk8pyo0adR*.7kCMd\"j") == nil)
        #expect(BlurHash.image("") == nil)
    }

    @Test("A photo's colors survive the round trip, where they were")
    func roundTrip() throws {
        // Red on the left half, blue on the right.
        let photo = try #require(Self.image(width: 64, height: 48) { x, _ in x < 32 ? (220, 30, 30) : (30, 40, 220) })
        let hash = try #require(BlurHash.encode(photo))
        #expect(hash.count == 4 + 2 * 4 * 3)

        let preview = try #require(BlurHash.image(hash, width: 32, height: 24))
        let left = try Self.pixel(preview, x: 2, y: 12)
        let right = try Self.pixel(preview, x: 29, y: 12)
        #expect(left.r > left.b + 60)
        #expect(right.b > right.r + 60)
    }

    @Test("A flat color comes back as that color")
    func flatColor() throws {
        let photo = try #require(Self.image(width: 40, height: 40) { _, _ in (90, 160, 70) })
        let hash = try #require(BlurHash.encode(photo))
        let preview = try #require(BlurHash.image(hash, width: 8, height: 8))
        // BlurHash's cosine basis lightens the edges a little, so compare the average.
        var total = (r: 0, g: 0, b: 0)
        for y in 0..<8 {
            for x in 0..<8 {
                let p = try Self.pixel(preview, x: x, y: y)
                total = (total.r + Int(p.r), total.g + Int(p.g), total.b + Int(p.b))
            }
        }
        #expect(abs(total.r / 64 - 90) <= 4 && abs(total.g / 64 - 160) <= 4 && abs(total.b / 64 - 70) <= 4, "\(total) \(hash)")
    }

    // MARK: Helpers

    private static func image(width: Int, height: Int, color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage? {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let offset = (y * width + x) * 4
                pixels[offset] = r
                pixels[offset + 1] = g
                pixels[offset + 2] = b
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        let data = try #require(image.dataProvider?.data as Data?)
        let offset = y * image.bytesPerRow + x * 4
        return (data[offset], data[offset + 1], data[offset + 2])
    }
}
