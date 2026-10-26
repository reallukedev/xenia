import AVFoundation
import XeniaCore
import SwiftUI

/// A file inside a bubble, as Messages draws one: the system's icon for its kind (or, once it's
/// on this device, a picture of its first page), its name, and what it is. Clicking opens it in
/// Quick Look.
struct FileBubbleContent: View {
    let attachment: MessageAttachment
    let caption: String?
    let isOwn: Bool

    @Environment(\.conversationContext) private var context
    @Environment(\.displayScale) private var scale
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var thumbnail: PlatformImage?

    #if os(macOS)
    private static let iconSize = CGSize(width: 36, height: 44)
    #else
    private static let iconSize = CGSize(width: 40, height: 50)
    #endif
    /// Small documents download by themselves for their first page, as Messages' do.
    private static let autoDownloadLimit: UInt64 = 5 * 1024 * 1024

    var body: some View {
        let opening = context.previewer?.openingID == attachment.id
        let failed = context.previewer?.failedIDs.contains(attachment.id) == true
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Button {
                context.previewer?.open(attachment.id)
            } label: {
                HStack(spacing: Theme.Spacing.m - 2) {
                    icon(opening: opening, failed: failed)
                        .frame(width: Self.iconSize.width, height: Self.iconSize.height)
                        .background {
                            PreviewAnchor(id: attachment.id, image: thumbnail ?? FileIcon.icon(for: attachment.type), previewer: context.previewer)
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(attachment.fileName)
                            .font(Self.nameFont)
                            .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                            .truncationMode(.middle)
                        Text(failed ? Self.failedText : detail)
                            .font(.caption)
                            .foregroundStyle(isOwn ? AnyShapeStyle(.white.opacity(0.78)) : AnyShapeStyle(.secondary))
                            .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    }
                    .frame(minWidth: 80, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .attachmentDrag(attachment, previewer: context.previewer) {
                if let icon = thumbnail ?? FileIcon.icon(for: attachment.type) {
                    Image(platformImage: icon).resizable().scaledToFit().frame(width: 64, height: 64)
                }
            }
            .accessibilityLabel(Text("\(FileIcon.kindName(attachment.type) ?? String(localized: "File")), \(attachment.fileName)"))
            .accessibilityValue(Text(detail))
            .accessibilityHint(Text("Opens it in Quick Look"))
            if let caption {
                Text(caption)
            }
        }
        .task(id: attachment.source) { await loadThumbnail() }
    }

    @ViewBuilder
    private func icon(opening: Bool, failed: Bool) -> some View {
        ZStack {
            if let thumbnail {
                Image(platformImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .clipShape(.rect(cornerRadius: 3, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(.black.opacity(0.12), lineWidth: 0.5)
                    }
            } else if let icon = FileIcon.icon(for: attachment.type) {
                Image(platformImage: icon)
                    .resizable()
                    .scaledToFit()
            }
            if opening {
                ProgressView()
                    .controlSize(.small)
                    .padding(Theme.Spacing.xs)
                    .background(.regularMaterial, in: .circle)
            } else if failed {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
            }
        }
        .animation(Theme.Motion.contentFade, value: thumbnail == nil)
    }

    private static var nameFont: Font {
        #if os(macOS)
        .body.weight(.medium)
        #else
        .subheadline.weight(.semibold)
        #endif
    }

    private static var failedText: String {
        #if os(macOS)
        String(localized: "Couldn’t Download. Click to Try Again.")
        #else
        String(localized: "Couldn’t Download. Tap to Try Again.")
        #endif
    }

    /// "PDF Document · 30 KB".
    private var detail: String {
        var parts: [String] = []
        if let kind = FileIcon.kindName(attachment.type) { parts.append(kind) }
        if let size = attachment.size { parts.append(Int64(size).formatted(.byteCount(style: .file))) }
        if parts.isEmpty { parts.append(String(localized: "File")) }
        return parts.joined(separator: " · ")
    }

    private var thumbnailKey: String { "file:\(attachment.source)" }

    private func loadThumbnail() async {
        thumbnail = FileIcon.cachedThumbnail(thumbnailKey)
        guard thumbnail == nil, FileIcon.hasPage(attachment.type), let previewer = context.previewer,
              (attachment.size ?? .max) <= Self.autoDownloadLimit,
              let url = await previewer.file(for: attachment)
        else { return }
        thumbnail = await FileIcon.thumbnail(of: url, key: thumbnailKey, size: Self.iconSize, scale: scale)
    }
}

/// An audio message: play and pause, its waveform filling as it plays, and its length. Voice
/// messages are just that; other audio files carry their name above.
struct AudioBubbleContent: View {
    let attachment: MessageAttachment
    let durationMs: UInt64?
    let isVoice: Bool
    let caption: String?
    let isOwn: Bool

    @Environment(\.conversationContext) private var context
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var levels: [Float]?
    @State private var fileDuration: TimeInterval?
    @State private var failed = false
    @State private var loading = false

    private var playback: AudioPlayback { .shared }
    private static let barCount = 34
    /// Audio this short downloads by itself, for its waveform.
    private static let autoDownloadLimit: UInt64 = 5 * 1024 * 1024
    #if os(macOS)
    private static let button: CGFloat = 26
    #else
    private static let button: CGFloat = 30
    #endif
    private static let reach = max(0, (Theme.Metrics.minTarget - button) / 2)

    var body: some View {
        let isCurrent = playback.currentID == attachment.id
        let isPlaying = isCurrent && playback.isPlaying
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if !isVoice {
                Text(attachment.fileName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: Theme.Spacing.s + 2) {
                Button(action: toggle) {
                    ZStack {
                        Circle().fill(isOwn ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                        if loading {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(isOwn ? Color.ownBubble : .white)
                        } else {
                            Image(systemName: failed ? "exclamationmark" : isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: Self.button * 0.42, weight: .bold))
                                .foregroundStyle(isOwn ? AnyShapeStyle(Color.ownBubble) : AnyShapeStyle(.white))
                                .offset(x: isPlaying || failed ? 0 : 1)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .frame(width: Self.button, height: Self.button)
                    // A full-size target, reaching past the drawn circle.
                    .padding(Self.reach)
                    .contentShape(.circle)
                    .padding(-Self.reach)
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityLabel(Text(isPlaying ? "Pause" : "Play"))

                // At the largest text sizes the clock goes under the waveform, so the bubble fits.
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.xxs))
                    : AnyLayout(HStackLayout(spacing: Theme.Spacing.s))
                layout {
                    // The sweep runs in Core Animation: SwiftUI hears only play and pause, so a
                    // playing message costs nothing per frame.
                    WaveformBars(levels: levels, count: Self.barCount, isOwn: isOwn)
                        .overlay {
                            PlayedSweep(
                                levels: levels, count: Self.barCount, isOwn: isOwn,
                                progress: isCurrent ? progressNow : 0, isPlaying: isPlaying,
                                remaining: isCurrent ? max(0, playback.duration - playback.currentTime) : 0
                            )
                        }
                        .frame(width: CGFloat(Self.barCount) * 4 - 2, height: Self.button * 0.8)
                    // The clock ticks once a second, sized by its longest value so the bubble
                    // never changes width as it does.
                    TimelineView(.animation(minimumInterval: 1, paused: !isPlaying)) { _ in
                        Text(verbatim: "00:00")
                            .hidden()
                            .overlay(alignment: .trailing) {
                                Text(verbatim: clock(isCurrent && playback.currentTime > 0 ? playback.currentTime : totalDuration))
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(isOwn ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    }
                }
                .accessibilityHidden(true)
            }
            if let caption {
                Text(caption)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(isVoice ? "Voice Message" : "Audio, \(attachment.fileName)"))
        .accessibilityValue(Text(Duration.seconds(totalDuration).formatted(.units(allowed: [.minutes, .seconds], width: .wide))))
        .accessibilityAction(named: Text(isPlaying ? "Pause" : "Play"), toggle)
        .task(id: attachment.source) { await loadWaveform(download: (attachment.size ?? .max) <= Self.autoDownloadLimit) }
    }

    private var progressNow: Double {
        let duration = playback.duration
        return duration > 0 ? min(1, playback.currentTime / duration) : 0
    }

    private var totalDuration: TimeInterval {
        if let durationMs, durationMs > 0 { return TimeInterval(durationMs) / 1000 }
        return fileDuration ?? 0
    }

    private func clock(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded(.down)).formatted(.time(pattern: .minuteSecond))
    }

    private func toggle() {
        guard let previewer = context.previewer, !loading else { return }
        let resuming = playback.currentID == attachment.id
        if !resuming { playback.prepare(attachment.id) }
        Task {
            failed = false
            loading = true
            let url = await previewer.file(for: attachment)
            loading = false
            guard let url else {
                failed = true
                return
            }
            // Stopped (the conversation closed) or another clip started while this downloaded.
            if !resuming, playback.pendingID != attachment.id { return }
            // A format the player can't read still gets a hearing in Quick Look.
            if await !playback.toggle(attachment.id, file: url) {
                previewer.open(attachment.id)
                return
            }
            if levels == nil { await loadWaveform(download: true) }
        }
    }

    private func loadWaveform(download: Bool) async {
        let key = "wave:\(attachment.source)"
        if let hit = Waveform.cached(key) {
            levels = hit
            return
        }
        guard download, let previewer = context.previewer, let url = await previewer.file(for: attachment) else { return }
        levels = await Waveform.levels(of: url, key: key, count: Self.barCount)
        if durationMs == nil, let duration = try? await AVURLAsset(url: url).load(.duration) {
            fileDuration = duration.seconds
        }
    }
}

/// The waveform, faint. Before the file is here, a row of dots.
private struct WaveformBars: View {
    let levels: [Float]?
    let count: Int
    let isOwn: Bool

    var body: some View {
        Canvas { context, size in
            context.fill(Waveform.path(levels: levels, count: count, in: size), with: .color(isOwn ? .white.opacity(0.4) : .primary.opacity(0.25)))
        }
    }
}

extension Waveform {
    static let barWidth: CGFloat = 2

    /// Every bar as one path: centered vertically, at least a dot tall.
    static func path(levels: [Float]?, count: Int, in size: CGSize) -> Path {
        var path = Path()
        let step = size.width / CGFloat(count)
        for index in 0..<count {
            let level = CGFloat(levels?[safe: index] ?? 0)
            let height = max(barWidth, level * size.height)
            let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2, width: barWidth, height: height)
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
        }
        return path
    }
}

/// The played part of the waveform, solid, revealed left to right by a Core Animation mask
/// that runs on its own from play to the end (or to pause).
private struct PlayedSweep {
    let levels: [Float]?
    let count: Int
    let isOwn: Bool
    let progress: Double
    let isPlaying: Bool
    let remaining: TimeInterval

    @MainActor
    func configure(_ view: SweepView, environment: EnvironmentValues) {
        let color = (isOwn ? Color.white : Color.primary).resolve(in: environment).cgColor
        view.update(levels: levels, count: count, color: color, progress: progress, isPlaying: isPlaying, remaining: remaining)
    }
}

#if os(macOS)
extension PlayedSweep: NSViewRepresentable {
    func makeNSView(context: Context) -> SweepView { SweepView() }
    func updateNSView(_ view: SweepView, context: Context) { configure(view, environment: context.environment) }
}
#else
extension PlayedSweep: UIViewRepresentable {
    func makeUIView(context: Context) -> SweepView { SweepView() }
    func updateUIView(_ view: SweepView, context: Context) { configure(view, environment: context.environment) }
}
#endif

private final class SweepView: PlatformView {
    private let bars = CAShapeLayer()
    private let reveal = CALayer()
    private var levels: [Float]?
    private var count = 0
    private var progress: Double = 0
    private var isPlaying = false
    private var remaining: TimeInterval = 0
    private var hasSwept = false

    init() {
        super.init(frame: .zero)
        #if os(macOS)
        wantsLayer = true
        #else
        isUserInteractionEnabled = false
        #endif
        reveal.backgroundColor = CGColor(gray: 0, alpha: 1)
        reveal.anchorPoint = CGPoint(x: 0, y: 0.5)
        bars.mask = reveal
        platformLayer.addSublayer(bars)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(levels: [Float]?, count: Int, color: CGColor, progress: Double, isPlaying: Bool, remaining: TimeInterval) {
        bars.fillColor = color
        let reshape = levels != self.levels || count != self.count
        let restart = !hasSwept || isPlaying != self.isPlaying || abs(progress - self.progress) > 0.02
        hasSwept = true
        self.levels = levels
        self.count = count
        self.progress = progress
        self.isPlaying = isPlaying
        self.remaining = remaining
        if reshape { reshapeBars() }
        if restart { sweep() }
    }

    #if os(macOS)
    override func layout() {
        super.layout()
        relayout()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private var platformLayer: CALayer { layer! }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        relayout()
    }

    private var platformLayer: CALayer { layer }
    #endif

    private func relayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.frame = bounds
        reveal.bounds = CGRect(origin: .zero, size: bounds.size)
        reveal.position = CGPoint(x: 0, y: bounds.midY)
        CATransaction.commit()
        // The sweep scales the mask, so a new size needs no restart; restarting from the last
        // update's progress would jump it back.
        reshapeBars()
    }

    private func reshapeBars() {
        guard count > 0, bounds.width > 0 else { return }
        bars.path = Waveform.path(levels: levels, count: count, in: bounds.size).cgPath
    }

    private func sweep() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        reveal.removeAllAnimations()
        reveal.transform = CATransform3DMakeScale(max(0.0001, progress), 1, 1)
        CATransaction.commit()
        guard isPlaying, remaining > 0 else { return }
        let animation = CABasicAnimation(keyPath: "transform.scale.x")
        animation.fromValue = max(0.0001, progress)
        animation.toValue = 1
        animation.duration = remaining
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        reveal.add(animation, forKey: "sweep")
    }
}

/// Shrinks a little while pressed, as Messages' controls do.
struct PressScaleButtonStyle: ButtonStyle {
    /// How far it gives under a finger: small controls give more than wide rows.
    var pressed: CGFloat = 0.88

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressed : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
