import CryptoKit
import Foundation
import ImageIO
import XeniaCore
import SwiftUI
import UniformTypeIdentifiers

/// Avatars, photos and files, loaded through the core (which authenticates, decrypts and caches
/// on disk) and kept decoded in memory. One load per image and size, shared by every view.
@Observable
final class MediaLoader {
    @ObservationIgnored private let client: XeniaClient
    @ObservationIgnored private let session: SessionGate
    @ObservationIgnored private let cache = NSCache<NSString, PlatformImage>()
    @ObservationIgnored private var inflight: [String: Task<PlatformImage?, Never>] = [:]
    /// Loads that failed, when, and how many times: tried again after a while (longer after
    /// each failure), since most failures pass but a missing image never comes back.
    @ObservationIgnored private var failed: [String: (at: Date, count: Int)] = [:]
    /// Bumped by `clear()`, so loads that finish after a sign-out don't fill the new cache.
    @ObservationIgnored private var generation = 0

    init(client: XeniaClient, session: SessionGate) {
        self.client = client
        self.session = session
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    /// A cached image, without waiting: from memory, or for avatars, from the copy kept on disk
    /// so faces show on the first frame after launch. `warmAvatars` keeps that disk read off the
    /// main thread for everything after the first frame.
    func cached(_ key: String) -> PlatformImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard key.hasPrefix("avatar:"), !missingOnDisk.contains(key) else { return nil }
        guard let image = AvatarDiskCache.read(key) else {
            missingOnDisk.insert(key)
            return nil
        }
        cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
        return image
    }

    /// Avatar keys with no copy on disk, so a face without one isn't looked for on every draw.
    @ObservationIgnored private var missingOnDisk: Set<String> = []

    /// Reads the avatars kept on disk for these keys into memory, off the main thread, so rows
    /// that scroll in find their faces there rather than reading the disk while drawing.
    func warmAvatars(_ keys: [String]) async {
        let wanted = Set(keys).filter { key in
            key.hasPrefix("avatar:") && !missingOnDisk.contains(key) && cache.object(forKey: key as NSString) == nil
        }
        guard !wanted.isEmpty else { return }
        let started = generation
        let found = await AvatarDiskCache.read(Array(wanted))
        guard started == generation else { return }
        for key in wanted {
            guard let image = found[key] else {
                missingOnDisk.insert(key)
                continue
            }
            if cache.object(forKey: key as NSString) == nil {
                cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
            }
        }
    }

    func avatar(_ mxc: String, points: CGFloat, scale: CGFloat) async -> PlatformImage? {
        let pixels = Self.avatarPixels(points: points)
        return await image(key: Self.avatarKey(mxc, points: points), maxPixels: CGFloat(pixels)) { [client] in
            try await client.loadAvatar(mxcUrl: mxc, sizePx: pixels)
        }
    }

    /// Avatars come in three sizes, so a face shown in the list, a bubble and Details downloads
    /// once or twice, not once per size. Each is sharp at 3x for the sizes it covers.
    static func avatarPixels(points: CGFloat) -> UInt32 {
        points <= 40 ? 128 : points <= 88 ? 272 : 400
    }

    static func avatarKey(_ mxc: String, points: CGFloat) -> String {
        "avatar:\(mxc)@\(avatarPixels(points: points))"
    }

    /// A photo scaled to fit a box, for bubbles.
    func thumbnail(_ source: String, width: CGFloat, height: CGFloat, scale: CGFloat) async -> PlatformImage? {
        let w = UInt32((width * scale).rounded(.up))
        let h = UInt32((height * scale).rounded(.up))
        return await image(key: Self.thumbnailKey(source, width: width), maxPixels: CGFloat(max(w, h))) { [client] in
            try await client.loadThumbnail(source: source, widthPx: w, heightPx: h)
        }
    }

    static func thumbnailKey(_ source: String, width: CGFloat) -> String {
        "thumb:\(source)@\(Int(width))"
    }

    /// The file behind a message, saved under its own name, for Quick Look, sharing and dragging.
    func file(_ source: String, name: String) async throws -> URL {
        await session.wait()
        try Task.checkCancellation()
        let path = try await client.saveMedia(source: source, filename: name)
        return URL(filePath: path)
    }

    func clear() {
        generation += 1
        cache.removeAllObjects()
        missingOnDisk = []
        AvatarDiskCache.removeAll()
        inflight.values.forEach { $0.cancel() }
        inflight = [:]
        failed = [:]
    }

    private func image(key: String, maxPixels: CGFloat, load: @escaping @Sendable () async throws -> Data) async -> PlatformImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if let failure = failed[key], Date.now.timeIntervalSince(failure.at) < Self.retryDelay(after: failure.count) {
            return nil
        }
        if let running = inflight[key] { return await running.value }
        let started = generation
        let task = Task<PlatformImage?, Never> { [session] in
            // A photo in the saved list waits for the session rather than failing.
            await session.wait()
            guard !Task.isCancelled, let data = try? await load() else { return nil }
            return await Self.decode(data, maxPixels: maxPixels)
        }
        inflight[key] = task
        let image = await task.value
        // Signed out meanwhile: this belongs to the old account.
        guard started == generation else { return nil }
        if inflight[key] == task { inflight[key] = nil }
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
            failed[key] = nil
            if key.hasPrefix("avatar:") {
                missingOnDisk.remove(key)
                AvatarDiskCache.write(image, key: key)
            }
        } else {
            failed[key] = (.now, (failed[key]?.count ?? 0) + 1)
        }
        return image
    }

    /// 30 seconds after the first failure, doubling each time, up to an hour.
    static func retryDelay(after failures: Int) -> TimeInterval {
        min(3600, 30 * pow(2, Double(max(0, failures - 1))))
    }

    /// Decodes and downsamples off the main thread, so scrolling never waits on JPEG decoding.
    @concurrent
    static func decode(_ data: Data, maxPixels: CGFloat) async -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixels, 64),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return platformImage(cgImage)
    }

    nonisolated fileprivate static func platformImage(_ cgImage: CGImage) -> PlatformImage {
        #if os(macOS)
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        UIImage(cgImage: cgImage)
        #endif
    }

    private static func cost(of image: PlatformImage) -> Int {
        #if os(macOS)
        let size = image.size
        return Int(size.width * size.height * 4)
        #else
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
        #endif
    }
}

/// Avatars kept on disk, small, so the saved list's faces draw at once on the next launch.
/// In Caches: the system may clear them, and they come back from the server.
nonisolated private enum AvatarDiskCache {
    private static var folder: URL {
        URL.cachesDirectory.appending(path: "Avatars", directoryHint: .isDirectory)
    }

    private static func url(_ key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return folder.appending(path: name + ".png", directoryHint: .notDirectory)
    }

    static func read(_ key: String) -> PlatformImage? {
        guard let data = try? Data(contentsOf: url(key)) else { return nil }
        return PlatformImage(data: data)
    }

    /// Several at once, decoded here rather than when first drawn. Keys without a copy are
    /// left out.
    @concurrent
    static func read(_ keys: [String]) async -> [String: PlatformImage] {
        var images: [String: PlatformImage] = [:]
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        for key in keys {
            guard let source = CGImageSourceCreateWithURL(url(key) as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options) else { continue }
            images[key] = MediaLoader.platformImage(cgImage)
        }
        return images
    }

    static func write(_ image: PlatformImage, key: String) {
        #if os(macOS)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        #else
        guard let cg = image.cgImage else { return }
        #endif
        let target = url(key)
        // Encoding a PNG takes a few milliseconds: never on the main thread.
        Task.detached(priority: .utility) {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, cg, nil)
            guard CGImageDestinationFinalize(destination) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Whole or not at all: a launch reading it halfway would find no face.
            try? (data as Data).write(to: target, options: .atomic)
        }
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }
}
