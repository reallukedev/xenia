import XeniaCore
import SwiftUI

/// A text message's blocks: paragraphs with emphasis, links and mention pills, quotes, lists,
/// headings and code.
struct RichTextView: View {
    let blocks: [RichBlock]
    let isOwn: Bool
    var font: Font = .body

    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        Group {
            if blocks.count == 1, case .paragraph(let spans) = blocks[0] {
                // The common case: one paragraph, one Text.
                Text(RichText.attributed(spans, isOwn: isOwn))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(blocks.indices, id: \.self) { index in
                        RichBlockView(block: blocks[index], isOwn: isOwn)
                            .padding(.top, index == 0 ? 0 : Self.gap(after: blocks[index - 1], before: blocks[index]))
                    }
                }
            }
        }
        // Hebrew or Arabic lines run from the right, whichever way Xenia itself reads.
        .multilineTextAlignment(RichText.isRightToLeft(blocks) == (layoutDirection == .rightToLeft) ? .leading : .trailing)
    }
}

extension RichTextView {
    /// Space between blocks, as Notes sets a document: a list's items sit close together, a
    /// heading sits close to what it heads and well apart from what came before.
    static func gap(after previous: RichBlock, before next: RichBlock) -> CGFloat {
        switch (previous, next) {
        case (.listItem, .listItem): 3
        case (.heading, _): 3
        case (_, .heading): Theme.Spacing.m
        default: Theme.Spacing.s - 2
        }
    }
}

private struct RichBlockView: View {
    let block: RichBlock
    let isOwn: Bool

    var body: some View {
        switch block {
        case .paragraph(let spans):
            Text(RichText.attributed(spans, isOwn: isOwn))
        case .heading(let level, let spans):
            Text(RichText.attributed(spans, isOwn: isOwn))
                // Headings read as a bold line, like a bold paragraph used as one; the largest
                // are a step up. Smaller than the body would look like a footnote.
                .font(level <= 1 ? .title3.weight(.semibold) : .body.weight(.semibold))
        case .quote(let spans):
            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isOwn ? Color.white.opacity(0.6) : Color.secondary.opacity(0.5))
                    .frame(width: 3)
                Text(RichText.attributed(spans, isOwn: isOwn))
                    .opacity(0.85)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let text, _):
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(Theme.Spacing.s)
            }
            .scrollIndicators(.hidden)
            .background(isOwn ? Color.black.opacity(0.18) : Color.primary.opacity(0.07), in: .rect(cornerRadius: 8))
        case .listItem(let marker, let depth, let spans):
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s - 2) {
                Text(marker)
                    .monospacedDigit()
                    .opacity(0.7)
                    .frame(minWidth: 10, alignment: .trailing)
                Text(RichText.attributed(spans, isOwn: isOwn))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .rule:
            Divider()
        }
    }
}

enum RichText {
    /// Whether the message's first letter belongs to a script written right to left.
    static func isRightToLeft(_ blocks: [RichBlock]) -> Bool {
        for block in blocks {
            let spans: [RichSpan] = switch block {
            case .paragraph(let spans), .heading(_, let spans), .quote(let spans), .listItem(_, _, let spans): spans
            case .code, .rule: []
            }
            for span in spans {
                for scalar in span.text.unicodeScalars where scalar.properties.isAlphabetic {
                    return rightToLeftScripts.contains { $0.contains(scalar.value) }
                }
            }
        }
        return false
    }

    /// Hebrew, Arabic, Syriac, Thaana, N'Ko and their presentation forms.
    private static let rightToLeftScripts: [ClosedRange<UInt32>] = [
        0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF,
    ]

    static func attributed(_ spans: [RichSpan], isOwn: Bool) -> AttributedString {
        var out = AttributedString()
        for span in spans {
            var piece = AttributedString(span.text)
            var intent: InlinePresentationIntent = []
            if span.bold { intent.insert(.stronglyEmphasized) }
            if span.italic { intent.insert(.emphasized) }
            if span.strike { intent.insert(.strikethrough) }
            if span.code { intent.insert(.code) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if let link = span.link, let url = URL(string: link) {
                piece.link = url
                piece.underlineStyle = .single
                if isOwn { piece.foregroundColor = .white }
            }
            if let mention = span.mention {
                piece.font = .body.weight(.semibold)
                if !isOwn { piece.foregroundColor = .mentionText }
                // A person's pill opens your chat with them.
                piece.link = URL(string: "https://matrix.to/#/\(mention)")
            }
            out.append(piece)
        }
        return out
    }
}
