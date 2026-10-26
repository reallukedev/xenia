import QuickLook
import XeniaCore
import SwiftUI
#if os(macOS)
import AppKit
import Quartz
#else
import UIKit
#endif

/// Opens a conversation's photos, videos and files in Quick Look, as Messages does: zooming out
/// of the bubble that was clicked, with every other attachment in the conversation a swipe (or
/// an arrow key) away. Files download when they're first shown, and the neighbors of the one
/// showing download ahead, so paging through rarely waits.
@Observable
final class AttachmentPreviewer: NSObject {
    /// The attachment being downloaded to open, for the bubble's spinner.
    private(set) var openingID: String?
    /// Attachments that couldn't be downloaded, for the bubble to say so.
    private(set) var failedIDs: Set<String> = []

    /// The conversation's attachments, read when one opens.
    @ObservationIgnored var attachments: () -> [MessageAttachment] = { [] }
    @ObservationIgnored private var media: MediaLoader?
    /// What Quick Look is paging through: fixed while it's open, so new messages don't shift it.
    @ObservationIgnored private var shown: [MessageAttachment] = []
    @ObservationIgnored private var files: [String: URL] = [:]
    @ObservationIgnored private var downloads: [String: Task<URL?, Never>] = [:]
    /// Pages Quick Look couldn't download, so asking again doesn't start another download.
    @ObservationIgnored private var failedPages: Set<String> = []
    /// Opening or sharing: cancelled by another, or by the conversation closing.
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// Every view that has marked an attachment's bubble, held weakly: a reused row's view may
    /// mark another attachment by now, and the hidden measuring copy draws its own.
    @ObservationIgnored private var anchors: [String: NSHashTable<PreviewAnchorView>] = [:]
    #if os(iOS)
    @ObservationIgnored private weak var controller: QLPreviewController?
    #else
    /// The window's viewer: attachments open there rather than in Quick Look's panel.
    @ObservationIgnored weak var viewer: MediaViewerState?
    #endif

    /// Files this size or smaller download ahead while a neighbor is showing.
    private static let prefetchLimit: UInt64 = 25 * 1024 * 1024

    /// Quick Look is open on this conversation's attachments.
    var isShowing: Bool {
        #if os(macOS)
        false
        #else
        controller != nil
        #endif
    }

    func attach(media: MediaLoader) {
        self.media = media
    }

    /// Downloads the attachment if needed and opens Quick Look on it.
    func open(_ id: String) {
        let all = attachments()
        guard let attachment = all.first(where: { $0.id == id }) else { return }
        start(attachment) { [weak self] _ in
            guard let self else { return }
            shown = all
            failedPages = []
            present(at: shown.firstIndex(of: attachment) ?? 0)
            prefetch(around: attachment.id)
        }
    }

    /// Downloads the attachment if needed and offers the share sheet, from its bubble.
    func share(_ attachment: MessageAttachment) {
        start(attachment) { [weak self] url in
            self?.presentShareSheet(url, from: self?.liveAnchor(for: attachment.id))
        }
    }

    /// Downloads, showing the bubble's spinner, then acts, unless something else was opened
    /// meanwhile or the conversation closed.
    private func start(_ attachment: MessageAttachment, then action: @escaping (URL) -> Void) {
        pending?.cancel()
        failedIDs.remove(attachment.id)
        openingID = attachment.id
        pending = Task { [weak self] in
            guard let self else { return }
            let url = await file(for: attachment)
            guard !Task.isCancelled else { return }
            openingID = nil
            pending = nil
            guard let url else {
                failedIDs.insert(attachment.id)
                return
            }
            action(url)
        }
    }

    /// Stops an open or share that's still downloading.
    private func cancelPending() {
        pending?.cancel()
        pending = nil
        openingID = nil
    }

    /// The downloaded file, for Save, Share and Copy.
    func file(for attachment: MessageAttachment) async -> URL? {
        if let done = downloadedFile(attachment.id) { return done }
        if let running = downloads[attachment.id] { return await running.value }
        guard let media else { return nil }
        let task = Task<URL?, Never> { try? await media.file(attachment.source, name: attachment.fileName) }
        downloads[attachment.id] = task
        let url = await task.value
        downloads[attachment.id] = nil
        if let url { files[attachment.id] = url }
        return url
    }

    /// The file, if it's already downloaded: a drag can hand it over at once.
    func readyFile(for attachment: MessageAttachment) -> URL? {
        downloadedFile(attachment.id)
    }

    /// Starts downloading a photo or a file that isn't big, ahead of a drag (the pointer is over
    /// it on the Mac).
    func prefetch(_ attachment: MessageAttachment) {
        guard downloadedFile(attachment.id) == nil, downloads[attachment.id] == nil,
              attachment.kind == .photo || (attachment.size ?? .max) <= Self.prefetchLimit else { return }
        Task { _ = await file(for: attachment) }
    }

    /// A file downloaded earlier, if it's still there: Settings > Storage can clear the files
    /// while this is open.
    private func downloadedFile(_ id: String) -> URL? {
        guard let url = files[id] else { return nil }
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        files[id] = nil
        return nil
    }

    fileprivate func register(_ anchor: PreviewAnchorView) {
        let id = anchor.attachmentID
        guard !id.isEmpty else { return }
        if anchors.count > 256 { anchors = anchors.filter { $0.value.count > 0 } }
        let views = anchors[id] ?? .weakObjects()
        views.add(anchor)
        anchors[id] = views
    }

    /// The bubble showing this attachment on screen, found when it's needed rather than kept as
    /// the last one drawn: the measuring copy is hidden, and a row scrolled away has moved on.
    fileprivate func liveAnchor(for id: String) -> PreviewAnchorView? {
        anchors[id]?.allObjects.first { $0.attachmentID == id && $0.isShowing }
    }

    fileprivate func anchor(for index: Int) -> PreviewAnchorView? {
        guard shown.indices.contains(index) else { return nil }
        return liveAnchor(for: shown[index].id)
    }

    fileprivate func item(at index: Int) -> PreviewItem {
        let attachment = shown[index]
        let item = PreviewItem(url: downloadedFile(attachment.id), title: attachment.title)
        if item.url == nil, !failedPages.contains(attachment.id) { load(index) }
        return item
    }

    /// Downloads an attachment Quick Look paged to, then shows it.
    private func load(_ index: Int) {
        let attachment = shown[index]
        Task {
            guard await file(for: attachment) != nil else {
                failedPages.insert(attachment.id)
                return
            }
            refreshIfShowing(index)
            prefetch(around: attachment.id)
        }
    }

    private func prefetch(around id: String) {
        guard let index = shown.firstIndex(where: { $0.id == id }) else { return }
        for neighbor in [index - 1, index + 1] where shown.indices.contains(neighbor) {
            let attachment = shown[neighbor]
            guard downloadedFile(attachment.id) == nil, attachment.kind == .photo || (attachment.size ?? .max) <= Self.prefetchLimit else { continue }
            Task { _ = await file(for: attachment) }
        }
    }

    fileprivate func closed() {
        shown = []
    }
}

/// One page in Quick Look. Its URL is empty until the file has downloaded.
private nonisolated final class PreviewItem: NSObject, QLPreviewItem, Sendable {
    let url: URL?
    let title: String

    init(url: URL?, title: String) {
        self.url = url
        self.title = title
    }

    var previewItemURL: URL? { url }
    var previewItemTitle: String? { title }
}

// MARK: - The bubble's anchor

/// Marks where an attachment's bubble is, so Quick Look can zoom out of it and back into it.
struct PreviewAnchor: View {
    let id: String
    /// What the bubble shows, for the zoom.
    let image: PlatformImage?
    let previewer: AttachmentPreviewer?

    @Environment(\.marksPreviewAnchors) private var marks

    var body: some View {
        if let previewer, marks {
            AnchorRepresentable(id: id, image: image, previewer: previewer)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

extension EnvironmentValues {
    /// Off for a copy of a bubble drawn elsewhere (a lifted message): Quick Look and Share
    /// anchor to the bubble in the conversation.
    @Entry var marksPreviewAnchors = true
}

#if os(macOS)
final class PreviewAnchorView: NSView {
    var attachmentID = ""
    var image: NSImage?
    weak var previewer: AttachmentPreviewer?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    fileprivate var isShowing: Bool {
        window != nil && !isHiddenOrHasHiddenAncestor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        previewer?.register(self)
    }
}

private struct AnchorRepresentable: NSViewRepresentable {
    let id: String
    let image: PlatformImage?
    let previewer: AttachmentPreviewer

    func makeNSView(context: Context) -> PreviewAnchorView { PreviewAnchorView() }

    func updateNSView(_ view: PreviewAnchorView, context: Context) {
        view.attachmentID = id
        view.image = image
        view.previewer = previewer
        previewer.register(view)
    }
}

/// Quick Look's panel only stays open while something in the responder chain controls it. The
/// app delegate is always in the chain, so it hands control to the conversation that opened it.
extension XeniaAppDelegate {
    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { AttachmentPreviewer.active != nil }
    }

    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = AttachmentPreviewer.active
            panel.delegate = AttachmentPreviewer.active
        }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            // The panel doesn't retain these; leave nothing behind for it to call.
            panel.dataSource = nil
            panel.delegate = nil
            AttachmentPreviewer.active?.closed()
            AttachmentPreviewer.active = nil
        }
    }
}

extension AttachmentPreviewer: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// The conversation whose attachments the panel shows.
    fileprivate static weak var active: AttachmentPreviewer?

    fileprivate func present(at index: Int) {
        if let viewer {
            viewer.show(shown, at: index, previewer: self)
            return
        }
        guard let panel = QLPreviewPanel.shared() else { return }
        Self.active = self
        panel.updateController()
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = index
        #if DEBUG
        // Backstage draws the app off screen and never makes it active, which hides panels.
        if ProcessInfo.processInfo.environment["BACKSTAGE_STAGE"] != nil { panel.hidesOnDeactivate = false }
        #endif
        if panel.isVisible {
            panel.refreshCurrentPreviewItem()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    fileprivate func refreshIfShowing(_ index: Int) {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible, panel.dataSource === self,
              panel.currentPreviewItemIndex == index
        else { return }
        panel.refreshCurrentPreviewItem()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        shown.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        item(at: index)
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let anchor = anchor(for: panel.currentPreviewItemIndex), let window = anchor.window else { return .zero }
        return window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let image = anchor(for: panel.currentPreviewItemIndex)?.image else { return nil }
        contentRect?.pointee = NSRect(origin: .zero, size: image.size)
        return image
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        false
    }

    fileprivate func presentShareSheet(_ url: URL, from anchor: PreviewAnchorView?) {
        guard let anchor, anchor.window != nil else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    /// Where an attachment's bubble is in its window, from the top left, while it's on screen.
    func bubbleFrame(for id: String) -> CGRect? {
        guard let anchor = liveAnchor(for: id), let content = anchor.window?.contentView, !anchor.visibleRect.isEmpty
        else { return nil }
        var frame = anchor.convert(anchor.bounds, to: content)
        if !content.isFlipped { frame.origin.y = content.bounds.height - frame.maxY }
        return frame
    }

    /// What an attachment's bubble shows, for the viewer to start from.
    func bubbleImage(for id: String) -> NSImage? {
        liveAnchor(for: id)?.image
    }

    /// Closes Quick Look, or the viewer, if it's showing this conversation's attachments.
    func dismiss() {
        cancelPending()
        if let viewer, viewer.isShowing(from: self) { viewer.closeNow() }
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.dataSource === self else { return }
        panel.orderOut(nil)
        panel.dataSource = nil
        panel.delegate = nil
        closed()
        Self.active = nil
        panel.updateController()
    }
}
#else
final class PreviewAnchorView: UIView {
    var attachmentID = ""
    var image: UIImage?
    weak var previewer: AttachmentPreviewer?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    fileprivate var isShowing: Bool {
        guard window != nil else { return false }
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.alpha < 0.01 { return false }
            view = current.superview
        }
        return true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        previewer?.register(self)
    }
}

private struct AnchorRepresentable: UIViewRepresentable {
    let id: String
    let image: PlatformImage?
    let previewer: AttachmentPreviewer

    func makeUIView(context: Context) -> PreviewAnchorView { PreviewAnchorView() }

    func updateUIView(_ view: PreviewAnchorView, context: Context) {
        view.attachmentID = id
        view.image = image
        view.previewer = previewer
        previewer.register(view)
    }
}

extension AttachmentPreviewer: QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    fileprivate func present(at index: Int) {
        guard let presenter = Self.topController() else { return }
        let controller = QLPreviewController()
        controller.dataSource = self
        controller.delegate = self
        controller.currentPreviewItemIndex = index
        self.controller = controller
        presenter.present(controller, animated: true)
    }

    fileprivate func presentShareSheet(_ url: URL, from anchor: PreviewAnchorView?) {
        guard let presenter = Self.topController() else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let anchor, anchor.window != nil {
            sheet.popoverPresentationController?.sourceView = anchor
            sheet.popoverPresentationController?.sourceRect = anchor.bounds
        }
        presenter.present(sheet, animated: true)
    }

    fileprivate func refreshIfShowing(_ index: Int) {
        guard let controller, controller.currentPreviewItemIndex == index else { return }
        controller.refreshCurrentPreviewItem()
    }

    private static func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        shown.count
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        item(at: index)
    }

    func previewController(_ controller: QLPreviewController, frameFor item: any QLPreviewItem, inSourceView view: AutoreleasingUnsafeMutablePointer<UIView?>) -> CGRect {
        guard let anchor = anchor(for: controller.currentPreviewItemIndex) else { return .zero }
        view.pointee = anchor
        return anchor.bounds
    }

    func previewController(_ controller: QLPreviewController, transitionImageFor item: any QLPreviewItem, contentRect: UnsafeMutablePointer<CGRect>) -> UIImage? {
        guard let image = anchor(for: controller.currentPreviewItemIndex)?.image else { return nil }
        contentRect.pointee = CGRect(origin: .zero, size: image.size)
        return image
    }

    func previewControllerDidDismiss(_ controller: QLPreviewController) {
        self.controller = nil
        closed()
    }

    /// What an attachment's bubble shows, to lift it out by.
    func bubbleImage(for id: String) -> UIImage? {
        anchors[id]?.allObjects.first { $0.attachmentID == id && $0.image != nil }?.image
    }

    /// Closes Quick Look if it's showing this conversation's attachments.
    func dismiss() {
        cancelPending()
        controller?.dismiss(animated: false)
        controller = nil
        closed()
    }
}
#endif
