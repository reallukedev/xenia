import XeniaCore
import SwiftUI

/// A link's card, as Messages draws one: the page's image across the top, then its title and
/// site on the gray of a received bubble, wearing the tail when it ends a run. Clicking opens the
/// link.
struct LinkPreviewCard: View {
    let preview: LinkPreviews.Preview
    let message: TimelineMessage

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.conversationContext) private var context
    @State private var image: PlatformImage?

    #if os(macOS)
    private static let width: CGFloat = 300
    #else
    private static let width: CGFloat = 264
    #endif

    var body: some View {
        let width = min(Self.width, context.bubbleMaxWidth)
        let tail: BubbleShape.Edge? = message.run.isLast ? (message.isOwn ? .trailing : .leading) : nil
        let tailWidth = tail == nil ? 0 : BubbleShape.tailWidth
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                if let source = preview.image {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        if let shown = image ?? model.linkPreviews.cachedImage(for: source) {
                            Image(platformImage: shown)
                                .resizable()
                                .scaledToFill()
                        }
                    }
                    .frame(width: width, height: (width * aspect).rounded())
                    .clipped()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.title ?? host)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(host)
                        .font(.footnote)
                        .foregroundStyle(message.isOwn ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.s + 1)
                .frame(width: width, alignment: .leading)
            }
            // The tail hangs into the margin, as text bubbles' tails do.
            .padding(message.isOwn ? .trailing : .leading, tailWidth)
            // The bubble's own color, as the text above it wears.
            .background(BubbleFill(isOwn: message.isOwn, mentionsMe: message.mentionsMe))
            .clipShape(BubbleShape(radius: Theme.Metrics.bubbleRadius, tail: tail, tailInside: true))
            .padding(message.isOwn ? .trailing : .leading, -tailWidth)
            .foregroundStyle(message.isOwn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .task(id: preview.image) {
            guard let source = preview.image, image == nil else { return }
            image = await model.linkPreviews.image(for: source)
        }
        #if os(macOS)
        .help(preview.url)
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(preview.title ?? host), \(host)"))
        .accessibilityAddTraits(.isLink)
        .accessibilityHint(Text("Opens the link"))
    }

    /// The image's own shape, kept between a wide banner and a square.
    private var aspect: CGFloat {
        guard preview.imageWidth > 0, preview.imageHeight > 0 else { return 0.52 }
        return min(1, max(0.4, CGFloat(preview.imageHeight) / CGFloat(preview.imageWidth)))
    }

    /// "apple.com", for "https://www.apple.com/iphone/".
    private var host: String {
        guard let host = URL(string: preview.url)?.host() else { return preview.siteName ?? preview.url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func open() {
        guard let url = URL(string: preview.url) else { return }
        openURL(url)
    }
}
