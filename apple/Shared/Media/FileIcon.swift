import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The system's icon for a kind of file (the PDF page, the spreadsheet grid), and once the
/// file is on this device, Quick Look's picture of its first page.
enum FileIcon {
    private nonisolated(unsafe) static let icons = NSCache<NSString, PlatformImage>()
    private nonisolated(unsafe) static let thumbnails = NSCache<NSString, PlatformImage>()

    static func icon(for type: UTType) -> PlatformImage? {
        if let hit = icons.object(forKey: type.identifier as NSString) { return hit }
        #if os(macOS)
        let image: PlatformImage? = NSWorkspace.shared.icon(for: type)
        #else
        // Document interaction knows each type's icon from a name alone; the file needn't exist.
        let ext = type.preferredFilenameExtension ?? "data"
        let image = UIDocumentInteractionController(url: URL(filePath: NSTemporaryDirectory()).appending(path: "file.\(ext)")).icons.last
        #endif
        if let image { icons.setObject(image, forKey: type.identifier as NSString) }
        return image
    }

    static func cachedThumbnail(_ key: String) -> PlatformImage? {
        thumbnails.object(forKey: key as NSString)
    }

    /// Quick Look's thumbnail of a downloaded file, or nil when it has none (archives, unknown
    /// types), in which case the icon stays.
    static func thumbnail(of url: URL, key: String, size: CGSize, scale: CGFloat) async -> PlatformImage? {
        if let hit = cachedThumbnail(key) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        #if os(macOS)
        let image = representation.nsImage
        #else
        let image = representation.uiImage
        #endif
        thumbnails.setObject(image, forKey: key as NSString)
        return image
    }

    /// Kinds worth a picture of the first page. Plain text keeps its icon too: a few lines on a
    /// white page read as a blank tile at this size.
    static func hasPage(_ type: UTType) -> Bool {
        [UTType.pdf, .image, .presentation, .spreadsheet].contains { type.conforms(to: $0) }
            && !type.conforms(to: .text)
            || ["com.apple.keynote.key", "com.apple.iwork.pages.sffpages", "com.apple.iwork.numbers.sffnumbers",
                "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc"].contains(type.identifier)
    }

    /// "PDF Document", "Plain Text Document": the system's own name for the kind.
    static func kindName(_ type: UTType) -> String? {
        guard !type.isDynamic, type != .data else { return nil }
        guard let description = type.localizedDescription else { return nil }
        // English kinds in Title Case, as Messages shows them, keeping capitals already there:
        // "PDF document" becomes "PDF Document". Other languages have their own rules.
        guard Locale.current.language.languageCode == .english else { return description }
        return description.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
