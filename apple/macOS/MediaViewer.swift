import AVKit
import AppKit
import ImageIO
import PDFKit
import Quartz
import XeniaCore
import SwiftUI
import UniformTypeIdentifiers

/// The Mac's viewer for a conversation's photos, videos and files. It opens inside the window,
/// as Photos shows a photo: zooming out of the bubble that was clicked, over the conversation,
/// with the toolbar trading the conversation's buttons for the photo's own. The arrow keys page
/// through every attachment in the conversation; Esc or Space goes back.
@Observable
final class MediaViewerState {
    enum Phase { case opening, open, closing }

    private(set) var items: [MessageAttachment] = []
    private(set) var index = 0
    private(set) var phase: Phase?
    /// Grows from the bubble to its place, and shrinks back on closing.
    var presented = false
    /// The current item's file, once it's downloaded.
    private(set) var file: URL? {
        didSet { if file != oldValue { openTitle = Self.openTitle(for: file) } }
    }
    /// The app the file opens in, by name: "Open in Preview". Looked up once per file, not on
    /// every toolbar redraw.
    private(set) var openTitle = String(localized: "Open")
    /// A photo's full image, or the bubble's smaller one until it arrives.
    private(set) var image: NSImage?
    private(set) var failed = false
    /// The item just saved to Downloads, for the button's checkmark.
    private(set) var savedID: String?
    var error: String?

    @ObservationIgnored private var previewer: AttachmentPreviewer?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var savedReset: Task<Void, Never>?

    var isOpen: Bool { phase != nil }

    var current: MessageAttachment? {
        items.indices.contains(index) ? items[index] : nil
    }

    func show(_ items: [MessageAttachment], at index: Int, previewer: AttachmentPreviewer) {
        guard !items.isEmpty else { return }
        self.items = items
        self.index = min(max(0, index), items.count - 1)
        self.previewer = previewer
        presented = false
        phase = .opening
        // The message field mustn't keep typing behind the viewer.
        NSApp.keyWindow?.makeFirstResponder(nil)
        load()
    }

    /// The zoom in has finished: the photo can be zoomed and paged.
    func settle() {
        if phase == .opening { phase = .open }
    }

    func move(by step: Int) {
        guard phase == .open, items.indices.contains(index + step) else { return }
        index += step
        load()
    }

    func close() {
        guard phase == .open || phase == .opening else { return }
        loading?.cancel()
        phase = .closing
    }

    func isShowing(from previewer: AttachmentPreviewer) -> Bool {
        isOpen && self.previewer === previewer
    }

    /// Ends at once, with no zoom: the conversation is going away.
    func closeNow() {
        loading?.cancel()
        finish()
    }

    func finish() {
        phase = nil
        presented = false
        items = []
        file = nil
        image = nil
        previewer = nil
    }

    /// Where the current item's bubble is in the window, if it's on screen.
    func bubble() -> CGRect? {
        guard let current else { return nil }
        return previewer?.bubbleFrame(for: current.id)
    }

    private func load() {
        loading?.cancel()
        guard let item = current, let previewer else { return }
        failed = false
        file = previewer.readyFile(for: item)
        image = item.kind == .photo || item.kind == .video ? previewer.bubbleImage(for: item.id) : nil
        loading = Task { [weak self] in
            let url = await previewer.file(for: item)
            guard let self, !Task.isCancelled, current?.id == item.id else { return }
            file = url
            failed = url == nil
            if item.kind == .photo, let url, let full = await Self.decode(url) {
                guard !Task.isCancelled, current?.id == item.id else { return }
                image = NSImage(cgImage: full, size: NSSize(width: full.width, height: full.height))
            }
            // The neighbors download while this one is looked at.
            for neighbor in [index - 1, index + 1] where items.indices.contains(neighbor) {
                previewer.prefetch(items[neighbor])
            }
        }
    }

    func retry() {
        load()
    }

    /// Off the main thread, upright, and no bigger than a screen needs.
    @concurrent
    private static func decode(_ url: URL) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 6000,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: Actions

    func copy() {
        guard let item = current, let previewer else { return }
        Task {
            do { try await AttachmentActions.copy(item, previewer: previewer) } catch { self.error = Copy.error(error) }
        }
    }

    func saveToDownloads() {
        guard let item = current, let previewer else { return }
        Task {
            do {
                try await AttachmentActions.saveToDownloads(item, previewer: previewer)
                savedID = item.id
                savedReset?.cancel()
                savedReset = Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    savedID = nil
                }
            } catch {
                self.error = Copy.error(error)
            }
        }
    }

    private static func openTitle(for file: URL?) -> String {
        guard let file, let app = NSWorkspace.shared.urlForApplication(toOpen: file) else { return String(localized: "Open") }
        let name = FileManager.default.displayName(atPath: app.path(percentEncoded: false))
        return String(localized: "Open in \(name.hasSuffix(".app") ? String(name.dropLast(4)) : name)")
    }

    func openInApp() {
        guard let file else { return }
        NSWorkspace.shared.open(file)
    }
}

// MARK: - The viewer

struct MediaViewer: View {
    @Bindable var state: MediaViewerState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    /// Room around the photo, as Photos leaves it.
    private static let margin: CGFloat = 20

    var body: some View {
        if let item = state.current, state.isOpen {
            GeometryReader { proxy in
                let area = CGRect(origin: .zero, size: proxy.size).insetBy(dx: Self.margin, dy: Self.margin)
                let origin = proxy.frame(in: .global).origin
                let source = state.bubble().map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
                ZStack {
                    content(item, area: area, source: source)
                        .id(item.id)
                        .transition(.opacity)
                    pager
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .background {
                Color.conversationBackground
                    .opacity(state.presented ? 1 : 0)
                    .ignoresSafeArea()
            }
            .contentShape(.rect)
            .onContinuousHover { phase in
                if case .active = phase { hovering = true } else { hovering = false }
            }
            .background { shortcuts }
            .onAppear(perform: open)
            .onChange(of: state.phase) { _, phase in
                if phase == .closing { shut() }
            }
            .animation(Theme.Motion.contentFade, value: item.id)
            .errorAlert("Couldn’t Finish", message: $state.error)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(item.title))
        }
    }

    private var motion: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.38, bounce: 0.12)
    }

    private func open() {
        withAnimation(motion) {
            state.presented = true
        } completion: {
            state.settle()
        }
    }

    private func shut() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .spring(duration: 0.32, bounce: 0)) {
            state.presented = false
        } completion: {
            state.finish()
        }
    }

    @ViewBuilder
    private func content(_ item: MessageAttachment, area: CGRect, source: CGRect?) -> some View {
        let settled = state.phase == .open
        switch item.kind {
        case .photo:
            if settled, let image = state.image {
                ZoomableImage(image: image)
                    .frame(width: area.width, height: area.height)
                    .position(x: area.midX, y: area.midY)
            } else {
                zooming(area: area, source: source)
            }
        case .video:
            if settled, let file = state.file {
                VideoView(url: file)
                    .frame(width: area.width, height: area.height)
                    .position(x: area.midX, y: area.midY)
            } else {
                zooming(area: area, source: source)
            }
            if settled, state.file == nil { loadingMark(in: area) }
        case .audio, .file:
            Group {
                if let file = state.file, item.type.conforms(to: .pdf) {
                    PDFDocumentView(url: file)
                } else if let file = state.file {
                    QuickLookView(url: file)
                } else if state.failed {
                    failure
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(width: area.width, height: area.height)
            .scaleEffect(state.presented ? 1 : 0.94)
            .opacity(state.presented ? 1 : 0)
            .position(x: area.midX, y: area.midY)
        }
        if state.failed, item.kind == .photo || item.kind == .video {
            failure.position(x: area.midX, y: area.midY)
        }
    }

    /// The photo on its way between the bubble and its place: cropped as the bubble crops it at
    /// one end, whole at the other.
    @ViewBuilder
    private func zooming(area: CGRect, source: CGRect?) -> some View {
        if let image = state.image {
            let fitted = Self.fit(image.size, in: area)
            let frame = state.presented ? fitted : (source ?? fitted.insetBy(dx: fitted.width * 0.04, dy: fitted.height * 0.04))
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: frame.width, height: frame.height)
                .clipShape(.rect(cornerRadius: state.presented ? 0 : Theme.Metrics.bubbleRadius, style: .continuous))
                .opacity(state.presented || source != nil ? 1 : 0)
                .position(x: frame.midX, y: frame.midY)
        } else if !state.failed {
            loadingMark(in: area)
        }
    }

    private func loadingMark(in area: CGRect) -> some View {
        ProgressView()
            .controlSize(.large)
            .position(x: area.midX, y: area.midY)
    }

    private var failure: some View {
        ContentUnavailableView {
            Label("Couldn’t Download", systemImage: "exclamationmark.circle")
        } description: {
            Text("Check your connection, then try again.")
        } actions: {
            Button("Try Again", action: state.retry)
        }
        .fixedSize()
    }

    /// Previous and next, at the sides while the pointer is over the viewer, as in Photos.
    private var pager: some View {
        HStack {
            pageButton("Previous", symbol: "chevron.backward", step: -1)
            Spacer()
            pageButton("Next", symbol: "chevron.forward", step: 1)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .opacity(hovering && state.phase == .open ? 1 : 0)
        .animation(Theme.Motion.hover, value: hovering)
    }

    @ViewBuilder
    private func pageButton(_ title: LocalizedStringKey, symbol: String, step: Int) -> some View {
        let enabled = state.items.indices.contains(state.index + step)
        Button(title, systemImage: symbol) { state.move(by: step) }
            .labelStyle(.iconOnly)
            .font(.title3.weight(.semibold))
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .opacity(enabled ? 1 : 0)
            .disabled(!enabled)
    }

    /// The keys that don't belong to a visible button.
    private var shortcuts: some View {
        ZStack {
            Button("Previous") { state.move(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Next") { state.move(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Close") { state.close() }
                .keyboardShortcut(.space, modifiers: [])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func fit(_ size: CGSize, in area: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return area }
        let scale = min(area.width / size.width, area.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: area.midX - fitted.width / 2, y: area.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }
}

/// The toolbar while the viewer is open: back, who sent it and when, then what can be done
/// with it.
struct MediaViewerToolbar: ToolbarContent {
    let state: MediaViewerState

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Back", systemImage: "chevron.backward") { state.close() }
                .keyboardShortcut(.cancelAction)
                .help("Back to Conversation (Esc)")
        }
        ToolbarItem(placement: .principal) {
            if let item = state.current {
                VStack(spacing: 0) {
                    Text(item.kind == .photo || item.kind == .video ? item.sender : item.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: 320)
            }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItemGroup(placement: .primaryAction) {
            let ready = state.file != nil
            Button("Copy", systemImage: "doc.on.doc", action: state.copy)
                .keyboardShortcut("c")
                .help("Copy (⌘C)")
            Button("Save to Downloads", systemImage: state.savedID == state.current?.id ? "checkmark" : "arrow.down.circle", action: state.saveToDownloads)
                .contentTransition(.symbolEffect(.replace))
                .help(state.savedID == state.current?.id ? "Saved to Downloads" : "Save to Downloads")
            if let file = state.file {
                ShareLink(item: file)
                    .help("Share")
            } else {
                Button("Share", systemImage: "square.and.arrow.up") {}
                    .disabled(true)
            }
            Button(state.openTitle, systemImage: "arrow.up.forward.app", action: state.openInApp)
                .disabled(!ready)
                .help(state.openTitle)
        }
    }

    private func subtitle(_ item: MessageAttachment) -> String {
        let (day, time) = TimeFormat.header(item.timestampMs)
        let when = time.hasPrefix(String(localized: "at")) ? "\(day) \(time)" : String(localized: "\(day) at \(time)")
        return item.kind == .photo || item.kind == .video ? when : "\(item.sender), \(when)"
    }
}

// MARK: - Pieces

/// A photo that pinches, double-clicks and scrolls like one in Preview: it fits the space at
/// first, centered, and zooms around the pointer.
private struct ZoomableImage: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> ZoomingScrollView { ZoomingScrollView() }

    func updateNSView(_ view: ZoomingScrollView, context: Context) {
        view.image = image
    }
}

private final class ZoomingScrollView: NSScrollView {
    private let imageView = NSImageView()
    private var fittedFor = CGSize.zero

    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            imageView.image = image
            fittedFor = .zero
            needsLayout = true
        }
    }

    init() {
        super.init(frame: .zero)
        contentView = CenteringClipView()
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        minMagnification = 1
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityElement(false)
        documentView = imageView
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard frame.size != fittedFor, let size = image?.size, size.width > 0, size.height > 0 else { return }
        fittedFor = frame.size
        let scale = min(frame.width / size.width, frame.height / size.height)
        magnification = 1
        imageView.frame = CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale))
        // Up to twice the photo's own pixels, and never less than four times the fit.
        maxMagnification = max(4, 2 / max(scale, 0.01))
    }

    @objc private func toggleZoom(_ recognizer: NSClickGestureRecognizer) {
        let point = recognizer.location(in: imageView)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            if magnification > 1.01 {
                animator().magnification = 1
            } else {
                animator().setMagnification(2.5, centeredAt: point)
            }
        }
    }
}

/// Keeps a document smaller than the view in the middle of it.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

/// A video, playing as soon as it opens. AppKit's AVPlayerView rather than SwiftUI's VideoPlayer:
/// on macOS 27.2 `_AVKit_SwiftUI` no longer links AVKit, so VideoPlayer's AVPlayerView subclass
/// can't find its superclass and the app aborts. Naming AVPlayerView here links AVKit ourselves.
private struct VideoView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard (view.player?.currentItem?.asset as? AVURLAsset)?.url != url else { return }
        view.player?.pause()
        let player = AVPlayer(url: url)
        view.player = player
        player.play()
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

/// A PDF's pages, scrolling and zooming as they do in Preview.
private struct PDFDocumentView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard view.document?.documentURL != url else { return }
        view.document = PDFDocument(url: url)
    }
}

/// Anything else, as Quick Look draws it in Finder: pages of a PDF, a document, an audio player.
private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.shouldCloseWithWindow = false
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

extension EnvironmentValues {
    /// The viewer that the conversation's attachments open in, on the Mac.
    @Entry var mediaViewer: MediaViewerState?
}
