import Foundation
import XeniaCore
import UniformTypeIdentifiers

/// A photo, video, audio clip or file in a conversation: what Quick Look shows, and what Save,
/// Share and Copy hand on.
nonisolated struct MessageAttachment: Identifiable, Hashable, Sendable {
    enum Kind: Hashable {
        case photo, video, audio, file
    }

    /// The message's row ID, so the bubble that shows it can be found again.
    let id: String
    let kind: Kind
    /// Pass to `MediaLoader.file`.
    let source: String
    /// The name it's saved under: always with an extension, so Quick Look knows what it is.
    let fileName: String
    /// Quick Look's title: who sent a photo or video (as Messages titles them), a file's name.
    let title: String
    let size: UInt64?
    /// The small image the bubble shows, for the zoom into Quick Look.
    let thumbnailSource: String?
    /// Who sent it ("You" for me) and when, for the viewer's title.
    let sender: String
    let timestampMs: Int64

    init?(_ message: TimelineMessage) {
        id = message.id
        sender = Self.sender(of: message)
        timestampMs = message.timestampMs
        switch message.content {
        case .image(let media, _):
            kind = .photo
            source = media.source
            fileName = Self.fileName(media.filename, mimetype: media.mimetype, kind: .photo)
            title = Self.sender(of: message)
            size = media.size
            thumbnailSource = media.thumbnail ?? media.source
        case .video(let media, _, _):
            kind = .video
            source = media.source
            fileName = Self.fileName(media.filename, mimetype: media.mimetype, kind: .video)
            title = Self.sender(of: message)
            size = media.size
            thumbnailSource = media.thumbnail
        case .audio(let source, let filename, _, let size, let mimetype, let isVoice, _):
            kind = .audio
            self.source = source
            fileName = Self.fileName(isVoice ? String(localized: "Voice Message") : filename, mimetype: mimetype, kind: .audio)
            title = isVoice ? String(localized: "Voice Message") : fileName
            self.size = size
            thumbnailSource = nil
        case .file(let source, let filename, let size, let mimetype, _):
            kind = .file
            self.source = source
            fileName = Self.fileName(filename, mimetype: mimetype, kind: .file)
            title = fileName
            self.size = size
            thumbnailSource = nil
        default:
            return nil
        }
    }

    /// Photos' file names are rarely chosen by anyone, so they're titled by who sent them.
    private static func sender(of message: TimelineMessage) -> String {
        message.isOwn ? String(localized: "You") : message.senderName
    }

    var type: UTType {
        UTType(filenameExtension: URL(filePath: fileName).pathExtension) ?? .data
    }

    /// Every attachment in the rows, oldest first, as Quick Look pages through them.
    @MainActor static func all(in rows: [TimelineRow]) -> [MessageAttachment] {
        rows.compactMap { $0.message.flatMap(MessageAttachment.init) }
    }

    /// A name Quick Look can open. Other apps often send a photo named "Image" or a caption in
    /// place of a name; without a known extension Quick Look shows only an icon, so one is added
    /// from the MIME type, or the kind when there's none.
    static func fileName(_ name: String, mimetype: String?, kind: Kind) -> String {
        // A name is the sender's to choose, so it may hold a path; only its last part counts.
        let trimmed = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let base = trimmed.isEmpty ? defaultName(kind) : trimmed
        let current = URL(filePath: base).pathExtension
        if !current.isEmpty, let type = UTType(filenameExtension: current), !type.isDynamic {
            return base
        }
        let fromMime = mimetype.flatMap { UTType(mimeType: $0) }
        let fallback: UTType? = switch kind {
        case .photo: .jpeg
        case .video: .mpeg4Movie
        case .audio: .mpeg4Audio
        case .file: nil
        }
        guard let type = fromMime ?? fallback, var ext = type.preferredFilenameExtension else { return base }
        // MPEG-4 audio's own extension is "mp4", which Finder shows as a movie.
        if type == .mpeg4Audio { ext = "m4a" }
        return "\(base).\(ext)"
    }

    private static func defaultName(_ kind: Kind) -> String {
        switch kind {
        case .photo: String(localized: "Photo")
        case .video: String(localized: "Video")
        case .audio: String(localized: "Audio")
        case .file: String(localized: "File")
        }
    }
}
