import CryptoKit
import Foundation
import ImageIO
import XeniaCore
import SwiftUI
import UniformTypeIdentifiers

/// Link previews, read by the homeserver (so sites never see this device) as messages arrive,
/// and kept on disk until they pass a size limit, oldest first. Nothing is ever sent with a
/// message.
@MainActor
@Observable
final class LinkPreviews {
    /// What a card shows. `isEmpty` marks a page with nothing to show, so it isn't asked again.
    struct Preview: Codable, Equatable {
        var url: String
        var title: String?
        var siteName: String?
        var image: String?
        var imageWidth: Int
        var imageHeight: Int
        var isEmpty = false
    }

    /// Previews and their images stay until they take this much space.
    nonisolated static let limit = 100 * 1024 * 1024

    private let client: XeniaClient
    private let media: MediaLoader
    private let folder: URL
    @ObservationIgnored private var memory: [String: Preview] = [:]
    /// URLs with nothing on disk, so drawing a row doesn't look twice.
    @ObservationIgnored private var notOnDisk: Set<String> = []
    @ObservationIgnored private var loading: Set<String> = []
    /// Requests that failed (the server is down, or doesn't make previews), and when.
    @ObservationIgnored private var failed: [String: Date] = [:]
    @ObservationIgnored private var images: [String: PlatformImage] = [:]
    /// Links found in messages, by message and body, so text isn't scanned on every draw.
    @ObservationIgnored private var links: [String: String?] = [:]
    @ObservationIgnored private var bytesWritten = 0
    /// Links whose card arrived while Xenia was open: cards drawn before it draw again.
    private var arrived: Set<String> = []

    init(client: XeniaClient, media: MediaLoader) {
        self.client = client
        self.media = media
        folder = URL.cachesDirectory.appending(path: "LinkPreviews", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    // MARK: Reading

    /// The preview to show for a link, if one is ready: from memory, or from disk.
    func preview(for url: String) -> Preview? {
        _ = arrived.contains(url)
        if let preview = memory[url] { return preview.isEmpty ? nil : preview }
        guard !notOnDisk.contains(url) else { return nil }
        guard let data = try? Data(contentsOf: file(url, "json")), let preview = try? JSONDecoder().decode(Preview.self, from: data) else {
            notOnDisk.insert(url)
            return nil
        }
        memory[url] = preview
        return preview.isEmpty ? nil : preview
    }

    /// The first web link in a text message, if it should have a card: not a matrix.to link,
    /// which already opens in Xenia.
    func link(in message: TimelineMessage) -> String? {
        guard case .text = message.content, let text = message.plainText else { return nil }
        let key = "\(message.id)|\(text.hashValue)"
        if let found = links[key] { return found }
        let found = Self.firstLink(in: text)
        links[key] = found
        return found
    }

    /// Making a detector costs far more than running one, and every new message is checked.
    private nonisolated static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    nonisolated static func firstLink(in text: String) -> String? {
        guard let detector else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  let host = url.host()?.lowercased(), host != "matrix.to"
            else { continue }
            return url.absoluteString
        }
        return nil
    }

    // MARK: Loading

    /// Loads previews for the links in these rows that don't have one yet, and calls `ready`
    /// with the rows whose card arrived, so the timeline draws them again.
    func prefetch(_ rows: [TimelineRow], ready: @escaping ([String]) -> Void) {
        var wanted: [String: [String]] = [:]
        for row in rows {
            guard let message = row.message, let url = link(in: message) else { continue }
            guard memory[url] == nil, preview(for: url) == nil, memory[url] == nil, !loading.contains(url) else { continue }
            if let at = failed[url], Date.now.timeIntervalSince(at) < 600 { continue }
            wanted[url, default: []].append(message.id)
        }
        for (url, ids) in wanted {
            loading.insert(url)
            Task {
                let found = await fetch(url)
                loading.remove(url)
                if found { ready(ids) }
            }
        }
    }

    private func fetch(_ url: String) async -> Bool {
        let preview: Preview
        do {
            if let found = try await client.linkPreview(url: url) {
                preview = Preview(
                    url: url, title: found.title, siteName: found.siteName, image: found.image,
                    imageWidth: Int(found.imageWidth), imageHeight: Int(found.imageHeight)
                )
            } else {
                preview = Preview(url: url, imageWidth: 0, imageHeight: 0, isEmpty: true)
            }
        } catch {
            failed[url] = .now
            return false
        }
        // The image comes first, so the card shows whole when it appears.
        if let source = preview.image { _ = await image(for: source) }
        memory[url] = preview
        notOnDisk.remove(url)
        arrived.insert(url)
        if let data = try? JSONEncoder().encode(preview) { write(data, to: file(url, "json")) }
        return !preview.isEmpty
    }

    /// A preview's image, from memory or disk, or downloaded through the homeserver and kept.
    func cachedImage(for source: String) -> PlatformImage? {
        images[source]
    }

    func image(for source: String) async -> PlatformImage? {
        if let image = images[source] { return image }
        let path = file(source, "jpg")
        // Decoded here, off the main thread, rather than when the card first draws.
        if let data = await Self.read(path), let image = await MediaLoader.decode(data, maxPixels: 800) {
            images[source] = image
            touch(path)
            return image
        }
        guard let image = await media.thumbnail(source, width: 400, height: 400, scale: 2) else { return nil }
        images[source] = image
        if let data = Self.jpeg(image) { write(data, to: path) }
        return image
    }

    // MARK: Disk

    private func file(_ key: String, _ ext: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appending(path: "\(hash).\(ext)")
    }

    private func write(_ data: Data, to url: URL) {
        try? data.write(to: url, options: .atomic)
        bytesWritten += data.count
        // Checked now and then, not on every write.
        if bytesWritten > 2 * 1024 * 1024 {
            bytesWritten = 0
            let folder = folder
            Task.detached(priority: .utility) { Self.trim(folder) }
        }
    }

    /// Reading a preview counts as using it, so the ones still seen stay longest.
    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path(percentEncoded: false))
    }

    /// Removes the least recently used files until the folder is under the limit.
    nonisolated private static func trim(_ folder: URL) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        let entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > limit else { return }
        for (url, size, _) in entries.sorted(by: { $0.2 < $1.2 }) {
            try? FileManager.default.removeItem(at: url)
            total -= size
            if total <= limit * 9 / 10 { break }
        }
    }

    /// How much space previews take, for Settings > Storage.
    nonisolated func bytes() async -> Int {
        let folder = folder
        return await Task.detached(priority: .utility) {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }.value
    }

    func clear() {
        memory = [:]
        notOnDisk = []
        failed = [:]
        images = [:]
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @concurrent
    private static func read(_ url: URL) async -> Data? {
        try? Data(contentsOf: url)
    }

    private static func jpeg(_ image: PlatformImage) -> Data? {
        #if os(macOS)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
        #else
        return image.jpegData(compressionQuality: 0.8)
        #endif
    }
}
