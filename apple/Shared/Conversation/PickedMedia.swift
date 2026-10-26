import CoreTransferable
import Foundation
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// A photo or video from the Photos picker, received as a file (the originals can be large, so
/// they're never loaded into memory whole).
struct PickedMedia: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            PickedMedia(url: try keep(received.file))
        }
        FileRepresentation(importedContentType: .movie) { received in
            PickedMedia(url: try keep(received.file))
        }
    }

    nonisolated static var folder: URL {
        FileManager.default.temporaryDirectory.appending(path: "Picked", directoryHint: .isDirectory)
    }

    /// Done with the copy (the attachment made from it has its own).
    func remove() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// A picture pasted as data, written to a file of its own to send.
    @concurrent
    static func saving(_ data: Data, as type: UTType) async throws -> PickedMedia {
        let folder = Self.folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = String(localized: "Pasted Image")
        let file = folder.appending(path: type.preferredFilenameExtension.map { "\(name).\($0)" } ?? name)
        try data.write(to: file)
        return PickedMedia(url: file)
    }

    /// The received file is only valid during the import: copy it somewhere it stays.
    private static func keep(_ file: URL) throws -> URL {
        let folder = Self.folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    #if os(iOS)
    /// A photo or video was copied. Asking doesn't read it, so iOS shows no paste banner.
    static var isOnPasteboard: Bool {
        let pasteboard = UIPasteboard.general
        return pasteboard.hasImages || pasteboard.contains(pasteboardTypes: [UTType.movie, .mpeg4Movie, .quickTimeMovie].map(\.identifier), inItemSet: nil)
    }

    static func canLoad(from provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
    }

    static func load(from provider: NSItemProvider) async throws -> PickedMedia {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: PickedMedia.self) { continuation.resume(with: $0) }
        }
    }
    #endif
}
