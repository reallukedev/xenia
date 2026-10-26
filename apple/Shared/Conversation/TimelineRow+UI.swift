import XeniaCore

extension TimelineMessage: @retroactive Identifiable {}

extension TimelineRow: @retroactive Identifiable {
    public var id: String {
        switch self {
        case .message(let message): message.id
        case .header(let id, _), .noteGroup(let id, _), .readMarker(let id), .start(let id): id
        case .note(let line): line.id
        }
    }

    var message: TimelineMessage? {
        if case .message(let message) = self { message } else { nil }
    }

    var isMessage: Bool { message != nil }
}

extension TimelineMessage {
    /// The words of a text message, for Copy and quotes.
    var plainText: String? {
        switch content {
        case .text(_, let plain, _, _): plain
        case .image(_, let caption), .video(_, _, let caption): caption
        case .file(_, let name, _, _, let caption): caption ?? name
        default: nil
        }
    }

    /// A photo's or video's BlurHash, for the soft preview before it arrives.
    var blurhash: String? {
        switch content {
        case .image(let media, _), .video(let media, _, _): media.blurhash
        default: nil
        }
    }

    var body: Body {
        switch content {
        case .text(_, let plain, let kind, _):
            switch kind {
            case .notice: .notice(text: plain)
            case .emote: .emote(text: plain)
            case .normal: .text(text: plain)
            }
        case .image(_, let caption): .image(caption: caption)
        case .video(_, _, let caption): .video(caption: caption)
        case .audio(_, _, _, _, _, let isVoice, let caption): isVoice ? .voice : .audio(caption: caption)
        case .file(_, let name, _, _, let caption): .file(name: name, caption: caption)
        case .sticker(_, let description): .sticker(description: description)
        case .poll(let question, _, _, _, _, _, _): .poll(question: question)
        case .location: .location
        case .deleted: .deleted
        case .encrypted: .encrypted
        case .unsupported: .unsupported
        }
    }
}
