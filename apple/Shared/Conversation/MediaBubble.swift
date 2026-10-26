import XeniaCore
import SwiftUI

/// A photo or video, shown at its own shape, with the caption in a bubble below. Clicking opens
/// Quick Look, zooming out of the bubble (it plays videos, zooms photos, and shares or saves
/// either).
struct MediaBubble: View {
    let message: TimelineMessage
    let media: MediaInfo
    let caption: String?
    let isVideo: Bool
    var durationMs: UInt64? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.conversationContext) private var context
    @Environment(\.displayScale) private var scale
    @State private var image: PlatformImage?
    @State private var blur: CGImage?

    var body: some View {
        VStack(alignment: message.isOwn ? .trailing : .leading, spacing: 3) {
            if let reply = message.reply {
                ReplyQuote(reply: reply, isOwn: false)
                    .frame(maxWidth: size.width)
            }
            Button(action: open) {
                ZStack {
                    if let preview = blur ?? BlurPreview.cached(media.blurhash) {
                        // The photo's own colors, softly, until it arrives.
                        Image(decorative: preview, scale: 1)
                            .resizable()
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                    if let shown {
                        Image(platformImage: shown)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity.animation(Theme.Motion.contentFade))
                    } else if media.blurhash == nil {
                        Image(systemName: isVideo ? "video" : "photo")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    if isVideo && !opening {
                        Image(systemName: "play.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(.ultraThinMaterial, in: .circle)
                            .environment(\.colorScheme, .dark)
                    }
                    if opening {
                        ProgressView()
                            .padding(Theme.Spacing.m)
                            .background(.ultraThinMaterial, in: .circle)
                    } else if failed {
                        Label("Couldn’t Download", systemImage: "exclamationmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, Theme.Spacing.s)
                            .padding(.vertical, Theme.Spacing.xs)
                            .background(.ultraThinMaterial, in: .capsule)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if isVideo, let durationMs, durationMs > 0 {
                        Text(Duration.milliseconds(Int64(durationMs)).formatted(.time(pattern: .minuteSecond)))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.45), radius: 2, y: 0.5)
                            .padding(.leading, Theme.Spacing.s + (tail == .leading ? BubbleShape.tailWidth : 0))
                            .padding(.bottom, Theme.Spacing.s - 2)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: size.width + (tail == nil ? 0 : BubbleShape.tailWidth), height: size.height)
                .clipShape(shape)
                .overlay {
                    shape.stroke(.primary.opacity(0.08), lineWidth: 0.5)
                }
                .contentShape(shape)
                .background {
                    PreviewAnchor(id: message.id, image: shown, previewer: context.previewer)
                }
                // The tail hangs into the margin, as text bubbles' tails do, so edges line up.
                .padding(message.isOwn ? .trailing : .leading, tail == nil ? 0 : -BubbleShape.tailWidth)
            }
            .buttonStyle(.plain)
            .attachmentDrag(message, previewer: context.previewer) {
                if let shown { Image(platformImage: shown).resizable().scaledToFit().frame(maxWidth: 160, maxHeight: 160) }
            }
            .accessibilityLabel(Text(isVideo ? "Video" : "Photo"))
            .accessibilityValue(isVideo && durationMs != nil ? Text(Duration.milliseconds(Int64(durationMs ?? 0)).formatted(.units(allowed: [.minutes, .seconds], width: .wide))) : Text(""))
            .accessibilityHint(Text("Opens it full size"))
            if let caption {
                TextBubble(message: message.withoutReply) {
                    Text(caption)
                }
            }
        }
        .task(id: media.source) {
            await loadBlur()
            await load()
        }
    }

    /// The last photo of a run wears the bubble's tail (unless a caption bubble follows it,
    /// which carries the tail instead).
    private var tail: BubbleShape.Edge? {
        guard message.run.isLast, caption == nil else { return nil }
        return message.isOwn ? .trailing : .leading
    }

    private var shape: BubbleShape {
        BubbleShape(radius: Theme.Metrics.bubbleRadius, tail: tail, tailInside: true)
    }

    private var key: String {
        MediaLoader.thumbnailKey(media.thumbnail ?? media.source, width: size.width)
    }

    private var shown: PlatformImage? {
        image ?? model.media.cached(key)
    }

    /// The photo's shape, fit into the bubble's box.
    private var size: CGSize {
        let maxSide = min(Theme.Metrics.photoMax, context.bubbleMaxWidth)
        let width = CGFloat(media.width), height = CGFloat(media.height)
        guard width > 0, height > 0 else { return CGSize(width: maxSide, height: maxSide * 0.75) }
        let ratio = min(max(width / height, 0.5), 2.2)
        return ratio >= 1
            ? CGSize(width: maxSide, height: (maxSide / ratio).rounded())
            : CGSize(width: (maxSide * ratio).rounded(), height: maxSide)
    }

    /// Usually decoded already, as the rows arrived.
    private func loadBlur() async {
        blur = nil
        guard let hash = media.blurhash, BlurPreview.cached(hash) == nil, shown == nil else { return }
        blur = await BlurPreview.image(hash)
    }

    private func load() async {
        // A reused row may still hold the photo it showed before.
        image = nil
        guard shown == nil else { return }
        // A video without a poster frame has nothing small to show; loading its source would
        // download the whole video just to fail decoding it.
        if isVideo && media.thumbnail == nil { return }
        let source = media.thumbnail ?? media.source
        image = await model.media.thumbnail(source, width: size.width, height: size.height, scale: scale)
    }

    private var opening: Bool { context.previewer?.openingID == message.id }
    private var failed: Bool { context.previewer?.failedIDs.contains(message.id) == true }

    private func open() {
        context.previewer?.open(message.id)
    }
}

/// Decoded BlurHash previews, decoded off the main thread and kept, so a row drawn again
/// doesn't decode again.
nonisolated enum BlurPreview {
    private nonisolated(unsafe) static let cache = NSCache<NSString, CGImage>()

    static func cached(_ hash: String?) -> CGImage? {
        guard let hash else { return nil }
        return cache.object(forKey: hash as NSString)
    }

    @concurrent
    static func image(_ hash: String) async -> CGImage? {
        if let hit = cached(hash) { return hit }
        guard let image = BlurHash.image(hash) else { return nil }
        cache.setObject(image, forKey: hash as NSString)
        return image
    }

    @concurrent
    static func decode(_ hashes: [String]) async {
        for hash in hashes where cached(hash) == nil {
            if let image = BlurHash.image(hash) { cache.setObject(image, forKey: hash as NSString) }
        }
    }
}

/// A sticker: the image alone, no bubble.
struct StickerView: View {
    let media: MediaInfo

    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: 140, height: 140)
        .task(id: media.source) {
            image = nil
            image = await model.media.thumbnail(media.thumbnail ?? media.source, width: 140, height: 140, scale: scale)
        }
        .accessibilityLabel(Text("Sticker"))
    }
}

extension TimelineMessage {
    /// The same message without its reply quote, for a caption under a photo.
    var withoutReply: TimelineMessage {
        TimelineMessage(
            id: id, eventId: eventId, senderId: senderId, senderName: senderName, senderAvatarUrl: senderAvatarUrl,
            isOwn: isOwn, timestampMs: timestampMs, content: content, isEdited: isEdited, mentionsMe: mentionsMe,
            sendState: sendState, reactions: reactions, reply: nil, thread: thread, readBy: readBy, canEdit: canEdit,
            canReply: canReply, canForward: canForward, canRedact: canRedact, isPinned: isPinned, run: run, showSender: showSender,
            delivery: delivery, seen: seen, isHighlighted: isHighlighted
        )
    }
}
