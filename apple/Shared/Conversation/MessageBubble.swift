import XeniaCore
import SwiftUI

/// The bubble itself, by kind of message.
struct MessageBubble: View {
    let message: TimelineMessage

    @Environment(\.conversationContext) private var context
    /// Emoji on their own grow with the text, staying well above it.
    @ScaledMetric(relativeTo: .largeTitle) private var jumboSize: CGFloat = 52

    var body: some View {
        content
            .opacity(message.sendState == .sending ? 0.72 : 1)
            .animation(Theme.Motion.contentFade, value: message.sendState)
            #if os(macOS)
            .help(Text(TimeFormat.clock(message.timestampMs)))
            #endif
            // One element per message, except a poll: each choice is its own button to vote with.
            .accessibilityElement(children: isPoll ? .contain : .combine)
            .accessibilityLabel(accessibilityLabel)
    }

    private var isPoll: Bool {
        if case .poll = message.content { true } else { false }
    }

    @ViewBuilder
    private var content: some View {
        switch message.content {
        case .text(let blocks, let plain, let kind, let isJumbo):
            if isJumbo && message.reply == nil {
                Text(plain)
                    .font(.system(size: jumboSize))
                    .padding(.vertical, Theme.Spacing.xxs)
            } else if let preview = linkPreview {
                // As in Messages: a message that's only a link is just its card; otherwise the
                // card follows the text and wears the tail.
                VStack(alignment: message.isOwn ? .trailing : .leading, spacing: 3) {
                    if !Self.isOnlyLink(plain, preview.url) {
                        TextBubble(message: message, hasTail: false) {
                            textContent(blocks: blocks, kind: kind)
                        }
                    }
                    LinkPreviewCard(preview: preview, message: message)
                }
            } else {
                TextBubble(message: message) {
                    textContent(blocks: blocks, kind: kind)
                }
            }
        case .image(let media, let caption):
            MediaBubble(message: message, media: media, caption: caption, isVideo: false)
        case .video(let media, let duration, let caption):
            MediaBubble(message: message, media: media, caption: caption, isVideo: true, durationMs: duration)
        case .sticker(let media, _):
            StickerView(media: media)
        case .file(_, _, _, _, let caption):
            if let attachment = MessageAttachment(message) {
                TextBubble(message: message) {
                    FileBubbleContent(attachment: attachment, caption: caption, isOwn: message.isOwn)
                }
            }
        case .audio(_, _, let duration, _, _, let isVoice, let caption):
            if let attachment = MessageAttachment(message) {
                TextBubble(message: message) {
                    AudioBubbleContent(attachment: attachment, durationMs: duration, isVoice: isVoice, caption: caption, isOwn: message.isOwn)
                }
            }
        case .poll(let question, let answers, let isDisclosed, let maxSelections, let voterCount, let isEnded, _):
            PollCard(
                message: message, question: question, answers: answers, isDisclosed: isDisclosed,
                maxSelections: maxSelections, voterCount: voterCount, isEnded: isEnded
            )
        case .location(let geoUri, let description):
            TextBubble(message: message) {
                LocationContent(geoURI: geoUri, description: description)
            }
        case .deleted:
            QuietBubble(symbol: "trash", text: "Message deleted", isOwn: message.isOwn)
        case .encrypted:
            QuietBubble(symbol: "lock", text: "Waiting for this message to unlock", isOwn: message.isOwn)
                .help(Text("This message is encrypted and this device doesn’t have its key yet. It unlocks when the key arrives from chat backup or another of your devices."))
        case .unsupported:
            QuietBubble(symbol: "questionmark.bubble", text: "Xenia can’t show this message yet", isOwn: message.isOwn)
        }
    }

    private func textContent(blocks: [RichBlock], kind: TextKind) -> some View {
        TextContent(blocks: blocks, kind: kind, message: message)
            #if os(macOS)
            // Click and drag selects words, as in Messages on the Mac.
            .textSelection(.enabled)
            #endif
    }

    @Environment(AppModel.self) private var model

    /// The card for the message's link, once the server has read the page.
    private var linkPreview: LinkPreviews.Preview? {
        guard model.preferences.linkPreviews, let url = model.linkPreviews.link(in: message) else { return nil }
        return model.linkPreviews.preview(for: url)
    }

    private static func isOnlyLink(_ text: String, _ url: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == url || trimmed + "/" == url || trimmed == url + "/"
    }

    private var accessibilityLabel: Text {
        let sender = message.isOwn ? String(localized: "You") : message.senderName
        let body = Copy.preview(of: message.body, sender: sender)
        let time = TimeFormat.clock(message.timestampMs)
        return Text("\(sender), \(body), \(time)")
    }
}

/// A bubble for text and files: own messages in the accent color, others in gray, a
/// mention of me tinted, the tail on the last of a run, and the replied-to message quoted inside.
struct TextBubble<Content: View>: View {
    let message: TimelineMessage
    /// Off when a link's card below carries the tail.
    var hasTail = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs + 2) {
            if let reply = message.reply {
                ReplyQuote(reply: reply, isOwn: message.isOwn)
            }
            content
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Metrics.bubbleVerticalPadding)
        .foregroundStyle(message.isOwn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .tint(message.isOwn ? .white : .accentColor)
        .background(
            BubbleFill(isOwn: message.isOwn, mentionsMe: message.mentionsMe),
            in: BubbleShape(radius: Theme.Metrics.bubbleRadius, tail: message.run.isLast && hasTail ? (message.isOwn ? .trailing : .leading) : nil)
        )
    }
}

/// The bubble's color. Own: the accent. Others: the Messages gray, tinted orange when they
/// mention me.
struct BubbleFill: ShapeStyle {
    let isOwn: Bool
    let mentionsMe: Bool

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        if isOwn { return Color.ownBubble.resolve(in: environment) }
        let gray = Color.incomingBubble.resolve(in: environment)
        guard mentionsMe else { return gray }
        let orange = Color.orange.resolve(in: environment)
        let amount: Float = environment.colorScheme == .dark ? 0.16 : 0.14
        return Color.Resolved(
            red: gray.red + (orange.red - gray.red) * amount,
            green: gray.green + (orange.green - gray.green) * amount,
            blue: gray.blue + (orange.blue - gray.blue) * amount
        )
    }
}

private struct TextContent: View {
    let blocks: [RichBlock]
    let kind: TextKind
    let message: TimelineMessage

    var body: some View {
        switch kind {
        case .normal:
            RichTextView(blocks: blocks, isOwn: message.isOwn)
        case .notice:
            RichTextView(blocks: blocks, isOwn: message.isOwn)
                .opacity(0.8)
        case .emote:
            let name = Text(message.isOwn ? String(localized: "You") : message.senderName).bold()
            let words = Text(message.plainText ?? "").italic()
            Text("\(name) \(words)")
        }
    }
}

/// Deleted, still-encrypted and unsupported messages: an outlined bubble in quiet type.
private struct QuietBubble: View {
    let symbol: String
    let text: LocalizedStringKey
    let isOwn: Bool

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.subheadline.italic())
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, 7)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius, style: .continuous)
                    .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
    }
}

private struct LocationContent: View {
    let geoURI: String
    let description: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = mapsURL { openURL(url) }
        } label: {
            Label(description ?? String(localized: "Shared Location"), systemImage: "mappin.and.ellipse")
        }
        .buttonStyle(.plain)
        .disabled(mapsURL == nil)
    }

    /// "geo:37.78,-122.40" opens in Maps.
    private var mapsURL: URL? {
        let coordinates = geoURI.replacingOccurrences(of: "geo:", with: "").split(separator: ";").first.map(String.init) ?? ""
        guard coordinates.contains(",") else { return nil }
        return URL(string: "https://maps.apple.com/?ll=\(coordinates)")
    }
}
