import AVFoundation
import Foundation
import ImageIO
import OSLog
import XeniaCore
import UniformTypeIdentifiers

/// Turns a picked photo or file into something the core can send: a readable file in a temporary
/// folder, with its type, size and, for images, its dimensions. The work (copying, re-encoding,
/// the BlurHash) runs off the main thread.
nonisolated enum AttachmentMaker {
    private static let log = Logger(subsystem: "dev.xenia.matrix", category: "conversation")

    /// A file chosen from Files, Finder or Photos, copied so it stays readable after access ends.
    /// Photos and videos are cleaned first: their location is removed, and HEIC becomes JPEG so
    /// every Matrix client can show it.
    @concurrent
    static func fromFile(_ source: URL, caption: String? = nil) async throws -> Attachment {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        // An empty file would upload as nothing: say so instead of sending it.
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let type = UTType(filenameExtension: source.pathExtension) ?? .data
        if type.conforms(to: .image), !type.conforms(to: .gif), let cleaned = try? cleanedPhoto(source) {
            return describe(url: cleaned.url, name: cleaned.url.lastPathComponent, type: cleaned.type, caption: caption)
        }
        if type.conforms(to: .movie), let cleaned = await cleanedVideo(source) {
            return describe(url: cleaned.url, name: cleaned.url.lastPathComponent, type: cleaned.type, caption: caption)
        }
        let name = source.lastPathComponent
        let url = try temporaryURL(named: name)
        try FileManager.default.copyItem(at: source, to: url)
        return describe(url: url, name: name, type: type, caption: caption)
    }

    /// Rewrites a photo without its GPS location (and in a format every client shows), keeping its
    /// orientation and color.
    private static func cleanedPhoto(_ source: URL) throws -> (url: URL, type: UTType) {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              let sourceType = CGImageSourceGetType(input).flatMap({ UTType($0 as String) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // HEIC as JPEG and TIFF (a picture copied on the Mac) as PNG, so every Matrix client shows it.
        let outputType: UTType = if sourceType.conforms(to: .heic) || sourceType.conforms(to: .heif) {
            .jpeg
        } else if sourceType.conforms(to: .tiff) {
            .png
        } else {
            sourceType
        }
        let base = source.deletingPathExtension().lastPathComponent
        let name = "\(base).\(outputType.preferredFilenameExtension ?? source.pathExtension)"
        let url = try temporaryURL(named: name)
        guard let output = CGImageDestinationCreateWithURL(url as CFURL, outputType.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var properties = (CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any]) ?? [:]
        properties[kCGImagePropertyGPSDictionary] = kCFNull
        properties[kCGImageDestinationLossyCompressionQuality] = 0.9
        CGImageDestinationAddImageFromSource(output, input, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
        return (url, outputType)
    }

    /// Rewrites a video without its location and other personal metadata: copied as it is when
    /// the format allows, re-encoded when it doesn't. Nil (and the original is sent) only when
    /// neither works.
    private static func cleanedVideo(_ source: URL) async -> (url: URL, type: UTType)? {
        let asset = AVURLAsset(url: source)
        let sharable = (try? await asset.load(.metadata)).map {
            AVMetadataItem.metadataItems(from: $0, filteredBy: .forSharing())
        } ?? []
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            let sourceType = AVFileType(UTType(filenameExtension: source.pathExtension)?.identifier ?? "")
            let supported = session.supportedFileTypes
            guard let fileType = [sourceType, .mov, .mp4].first(where: supported.contains) ?? supported.first,
                  let type = UTType(fileType.rawValue) else { continue }
            session.metadata = sharable
            session.metadataItemFilter = .forSharing()
            let base = source.deletingPathExtension().lastPathComponent
            do {
                let url = try temporaryURL(named: "\(base).\(type.preferredFilenameExtension ?? source.pathExtension)")
                try await session.export(to: url, as: fileType)
                return (url, type)
            } catch {
                log.error("Couldn't clean a video with \(preset, privacy: .public): \(String(describing: error), privacy: .private)")
            }
        }
        log.fault("Sending a video as it is: it couldn't be cleaned of its location")
        return nil
    }

    private static func describe(url: URL, name: String, type: UTType, caption: String?) -> Attachment {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? NSNumber)?.uint64Value
        var width: UInt32?
        var height: UInt32?
        var blurhash: String?
        if type.conforms(to: .image),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = properties[kCGImagePropertyPixelWidth] as? Int,
           let h = properties[kCGImagePropertyPixelHeight] as? Int {
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            // Orientations 5 to 8 are rotated a quarter turn.
            let rotated = (5...8).contains(orientation)
            width = UInt32(rotated ? h : w)
            height = UInt32(rotated ? w : h)
            let small: [CFString: Any] = [
                // The photo's own small thumbnail when it has one, rather than decoding it all.
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
            ]
            blurhash = CGImageSourceCreateThumbnailAtIndex(source, 0, small as CFDictionary).flatMap { BlurHash.encode($0) }
        }
        return Attachment(
            path: url.path(percentEncoded: false),
            filename: name,
            mimetype: type.preferredMIMEType ?? "application/octet-stream",
            size: size,
            width: width,
            height: height,
            durationMs: nil,
            blurhash: blurhash,
            caption: caption,
            thumbnailPath: nil
        )
    }

    /// For a video: its size, length and a JPEG poster frame, so the bubble shows a picture on
    /// every device before anyone downloads the video. Anything else comes back unchanged.
    @concurrent
    static func withVideoDetails(_ attachment: Attachment) async -> Attachment {
        guard attachment.mimetype.hasPrefix("video/") else { return attachment }
        let asset = AVURLAsset(url: URL(filePath: attachment.path))
        var durationMs = attachment.durationMs
        var width = attachment.width
        var height = attachment.height
        var thumbnailPath: String?
        var blurhash = attachment.blurhash
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            durationMs = UInt64(max(0, duration.seconds * 1000))
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let size = natural.applying(transform)
            width = UInt32(abs(size.width))
            height = UInt32(abs(size.height))
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        let poster = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600))
        if let frame = poster?.image { blurhash = BlurHash.encode(frame) }
        if let (frame, _) = poster,
           let url = try? temporaryURL(named: "thumbnail.jpg"),
           let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, frame, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            if CGImageDestinationFinalize(destination) {
                thumbnailPath = url.path(percentEncoded: false)
            }
        }
        return Attachment(
            path: attachment.path, filename: attachment.filename, mimetype: attachment.mimetype, size: attachment.size,
            width: width, height: height, durationMs: durationMs, blurhash: blurhash,
            caption: attachment.caption, thumbnailPath: thumbnailPath
        )
    }

    private static var outgoing: URL {
        FileManager.default.temporaryDirectory.appending(path: "Outgoing", directoryHint: .isDirectory)
    }

    private static func temporaryURL(named name: String) throws -> URL {
        let folder = outgoing.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: name)
    }

    /// The core has its own copy once a send is queued: the temporary files can go.
    static func remove(_ attachment: Attachment) {
        for path in [attachment.path, attachment.thumbnailPath].compactMap(\.self) {
            let folder = URL(filePath: path).deletingLastPathComponent()
            // Only folders this made, never a file someone dropped from their own disk.
            guard folder.deletingLastPathComponent().standardizedFileURL == outgoing.standardizedFileURL else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Clears what earlier launches left behind (a send cut short when the app quit).
    @concurrent
    static func removeLeftovers() async {
        for folder in [outgoing, PickedMedia.folder] {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
