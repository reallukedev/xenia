import CoreGraphics
import Foundation

/// BlurHash (blurha.sh): a photo's colors in a few dozen characters, sent with it so every
/// client can draw a soft preview before the photo downloads. Element and most Matrix clients
/// send and show them.
nonisolated enum BlurHash {
    /// A small image of the hash, to be stretched over the photo's frame. Nil for a malformed hash.
    static func image(_ hash: String, width: Int = 24, height: Int = 24, punch: Float = 1) -> CGImage? {
        let chars = Array(hash.utf8)
        guard chars.count >= 6, let sizeFlag = decode83(chars[0..<1]), let quantisedMax = decode83(chars[1..<2]) else { return nil }
        let numY = sizeFlag / 9 + 1
        let numX = sizeFlag % 9 + 1
        guard chars.count == 4 + 2 * numX * numY else { return nil }
        let maximum = Float(quantisedMax + 1) / 166 * punch

        var colors: [(Float, Float, Float)] = []
        for index in 0..<(numX * numY) {
            if index == 0 {
                guard let value = decode83(chars[2..<6]) else { return nil }
                colors.append((linear(value >> 16), linear((value >> 8) & 255), linear(value & 255)))
            } else {
                guard let value = decode83(chars[(4 + index * 2)..<(6 + index * 2)]) else { return nil }
                let r = value / (19 * 19), g = (value / 19) % 19, b = value % 19
                colors.append((
                    signedPow(Float(r - 9) / 9, 2) * maximum,
                    signedPow(Float(g - 9) / 9, 2) * maximum,
                    signedPow(Float(b - 9) / 9, 2) * maximum
                ))
            }
        }

        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var r: Float = 0, g: Float = 0, b: Float = 0
                for j in 0..<numY {
                    let basisY = cos(Float.pi * Float(y) * Float(j) / Float(height))
                    for i in 0..<numX {
                        let basis = cos(Float.pi * Float(x) * Float(i) / Float(width)) * basisY
                        let color = colors[i + j * numX]
                        r += color.0 * basis
                        g += color.1 * basis
                        b += color.2 * basis
                    }
                }
                let offset = (y * width + x) * 4
                pixels[offset] = sRGB(r)
                pixels[offset + 1] = sRGB(g)
                pixels[offset + 2] = sRGB(b)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// The hash of a photo, from a copy shrunk to a few dozen pixels.
    static func encode(_ image: CGImage, componentsX: Int = 4, componentsY: Int = 3) -> String? {
        let width = 32
        let height = max(1, min(64, Int((CGFloat(image.height) / CGFloat(max(image.width, 1)) * 32).rounded())))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var factors: [(Float, Float, Float)] = []
        for j in 0..<componentsY {
            for i in 0..<componentsX {
                let normalisation: Float = (i == 0 && j == 0) ? 1 : 2
                var r: Float = 0, g: Float = 0, b: Float = 0
                for y in 0..<height {
                    let basisY = cos(Float.pi * Float(j) * Float(y) / Float(height))
                    for x in 0..<width {
                        let basis = normalisation * cos(Float.pi * Float(i) * Float(x) / Float(width)) * basisY
                        let offset = (y * width + x) * 4
                        r += basis * linear(Int(pixels[offset]))
                        g += basis * linear(Int(pixels[offset + 1]))
                        b += basis * linear(Int(pixels[offset + 2]))
                    }
                }
                let scale = 1 / Float(width * height)
                factors.append((r * scale, g * scale, b * scale))
            }
        }

        let dc = factors[0]
        let ac = factors.dropFirst()
        var hash = encode83((componentsX - 1) + (componentsY - 1) * 9, length: 1)
        var maximum: Float = 1
        if let largest = ac.map({ max(abs($0.0), abs($0.1), abs($0.2)) }).max() {
            let quantised = Int(max(0, min(82, (largest * 166 - 0.5).rounded(.down))))
            maximum = Float(quantised + 1) / 166
            hash += encode83(quantised, length: 1)
        } else {
            hash += encode83(0, length: 1)
        }
        hash += encode83((Int(sRGB(dc.0)) << 16) + (Int(sRGB(dc.1)) << 8) + Int(sRGB(dc.2)), length: 4)
        for factor in ac {
            func quantise(_ value: Float) -> Int {
                Int(max(0, min(18, (signedPow(value / maximum, 0.5) * 9 + 9.5).rounded(.down))))
            }
            hash += encode83(quantise(factor.0) * 19 * 19 + quantise(factor.1) * 19 + quantise(factor.2), length: 2)
        }
        return hash
    }

    // MARK: Helpers

    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~".utf8)
    private static let lookup: [UInt8: Int] = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })

    private static func decode83(_ chars: ArraySlice<UInt8>) -> Int? {
        var value = 0
        for char in chars {
            guard let digit = lookup[char] else { return nil }
            value = value * 83 + digit
        }
        return value
    }

    private static func encode83(_ value: Int, length: Int) -> String {
        var result = ""
        for index in 1...length {
            let digit = (value / Int(pow(83, Double(length - index)))) % 83
            result.append(Character(UnicodeScalar(alphabet[digit])))
        }
        return result
    }

    private static func linear(_ value: Int) -> Float {
        let v = Float(value) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func sRGB(_ value: Float) -> UInt8 {
        let v = max(0, min(1, value))
        return v <= 0.0031308 ? UInt8(v * 12.92 * 255 + 0.5) : UInt8((1.055 * pow(v, 1 / 2.4) - 0.055) * 255 + 0.5)
    }

    private static func signedPow(_ value: Float, _ exponent: Float) -> Float {
        copysign(pow(abs(value), exponent), value)
    }
}
