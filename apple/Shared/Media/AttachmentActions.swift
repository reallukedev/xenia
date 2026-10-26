import Photos
import XeniaCore
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension View {
    /// Photos and files drag out of the conversation into Finder, Mail, Photos or any app that
    /// takes a file, as in Messages: on the Mac by dragging, on iPhone by touching and holding,
    /// then moving.
    @ViewBuilder
    func attachmentDrag(_ message: TimelineMessage, previewer: AttachmentPreviewer?, @ViewBuilder preview: () -> some View) -> some View {
        if let attachment = MessageAttachment(message) {
            attachmentDrag(attachment, previewer: previewer, preview: preview)
        } else {
            self
        }
    }

    @ViewBuilder
    func attachmentDrag(_ attachment: MessageAttachment, previewer: AttachmentPreviewer?, @ViewBuilder preview: () -> some View) -> some View {
        if let previewer {
            onDrag {
                AttachmentActions.itemProvider(for: attachment, previewer: previewer)
            } preview: {
                preview()
            }
            #if os(macOS)
            // The pointer resting on it is a good sign a drag is coming: fetch it, so the drop
            // gets a real file at once.
            .onHover { if $0 { previewer.prefetch(attachment) } }
            #endif
        } else {
            self
        }
    }
}

/// Save and Copy for an attachment, from its message's menu.
enum AttachmentActions {
    /// Files dragged out lately, by name: one let go over the conversation again isn't new.
    private static var recentDrags: [String: Date] = [:]

    static func isOwnDrag(_ url: URL) -> Bool {
        recentDrags = recentDrags.filter { Date.now.timeIntervalSince($0.value) < 60 }
        return url.path(percentEncoded: false).contains("/Caches/Xenia/files/") || recentDrags[url.lastPathComponent] != nil
    }

    /// What a drag carries: the file itself, downloaded when the drop asks for it (or at once
    /// when it already is), under its own name.
    static func itemProvider(for attachment: MessageAttachment, previewer: AttachmentPreviewer) -> NSItemProvider {
        let provider = NSItemProvider()
        recentDrags[attachment.fileName] = .now
        provider.suggestedName = attachment.fileName
        let ready = previewer.readyFile(for: attachment)
        provider.registerFileRepresentation(for: attachment.type, visibility: .all, openInPlace: false) { completion in
            let progress = Progress(totalUnitCount: 1)
            // NSItemProvider's completion may be called from any thread.
            let done = ProviderCompletion(handler: completion)
            Task { @MainActor in
                let url = await previewer.file(for: attachment)
                progress.completedUnitCount = 1
                done.handler(url, false, url == nil ? CocoaError(.fileReadUnknown) : nil)
            }
            return progress
        }
        // Apps that only take a file's address get one when the file is here already.
        if let ready { provider.registerObject(ready as NSURL, visibility: .all) }
        return provider
    }

    enum Failure: LocalizedError {
        case download, photos

        var errorDescription: String? {
            switch self {
            case .download: String(localized: "Xenia couldn’t download it. Check your connection and try again.")
            case .photos: String(localized: "Xenia couldn’t save it to Photos. Allow Xenia to add photos in Settings > Privacy & Security > Photos.")
            }
        }
    }

    static func copy(_ attachment: MessageAttachment, previewer: AttachmentPreviewer) async throws {
        guard let url = await previewer.file(for: attachment) else { throw Failure.download }
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var objects: [NSPasteboardWriting] = [url as NSURL]
        if attachment.kind == .photo, let image = NSImage(contentsOf: url) { objects.insert(image, at: 0) }
        pasteboard.writeObjects(objects)
        #else
        if attachment.kind == .photo, let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) {
            UIPasteboard.general.image = image
        } else if let provider = NSItemProvider(contentsOf: url) {
            UIPasteboard.general.itemProviders = [provider]
        }
        #endif
    }

    #if os(macOS)
    /// Copies it into Downloads under a name that's free, and bounces the Downloads stack in
    /// the Dock as Safari does.
    static func saveToDownloads(_ attachment: MessageAttachment, previewer: AttachmentPreviewer) async throws {
        guard let url = await previewer.file(for: attachment) else { throw Failure.download }
        // The cached copy's name is already safe for a path; the sender's may hold slashes.
        let target = Self.freeName(for: url.lastPathComponent, in: Self.downloadsFolder())
        try await copy(url, to: target)
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: target.path(percentEncoded: false))
    }

    /// Off the main thread: a long video takes a moment to copy.
    @concurrent
    private static func copy(_ source: URL, to target: URL) async throws {
        try FileManager.default.copyItem(at: source, to: target)
    }

    /// The real Downloads folder: inside the sandbox, the user's own, not the container's.
    private static func downloadsFolder() -> URL {
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            return URL(filePath: String(cString: home)).appending(path: "Downloads", directoryHint: .isDirectory)
        }
        return URL.downloadsDirectory
    }

    /// "Photo.jpg", then "Photo 2.jpg", as Finder numbers copies.
    static func freeName(for name: String, in folder: URL) -> URL {
        let base = URL(filePath: name).deletingPathExtension().lastPathComponent
        let ext = URL(filePath: name).pathExtension
        var candidate = folder.appending(path: name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            let numbered = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            candidate = folder.appending(path: numbered)
            number += 1
        }
        return candidate
    }
    #else
    static func saveToPhotos(_ attachment: MessageAttachment, previewer: AttachmentPreviewer) async throws {
        guard let url = await previewer.file(for: attachment) else { throw Failure.download }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.photos }
        do {
            try await addToLibrary(url, isVideo: attachment.kind == .video)
        } catch {
            throw Failure.photos
        }
    }

    /// Photos runs the change block on its own queue, so it mustn't belong to the main actor.
    nonisolated private static func addToLibrary(_ url: URL, isVideo: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: isVideo ? .video : .photo, fileURL: url, options: nil)
        }
    }
    #endif
}

private nonisolated struct ProviderCompletion: @unchecked Sendable {
    let handler: (URL?, Bool, (any Error)?) -> Void
}
