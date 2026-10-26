import XeniaCore
import SwiftUI

/// One conversation in a list: who, when, and the latest words, with a leading dot when there's
/// something new (an orange "@" when someone mentioned you).
struct ConversationRow: View {
    let room: RoomSummary
    /// The Mac's sidebar draws a hairline under the text, as Messages does, except beside the
    /// selected row.
    var showsSeparator = false

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.reservesUnreadSpace) private var reservesUnreadSpace
    @Environment(\.dayClock) private var clock

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                accessibilityLayout
            } else {
                standardLayout
            }
        }
        .padding(.vertical, rowPadding)
        #if os(macOS)
        .overlay(alignment: .bottom) {
            if showsSeparator {
                Rectangle()
                    .fill(.separator)
                    .frame(height: 1 / 2)
                    .padding(.leading, separatorLeading)
            }
        }
        #endif
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityActions {
            // The combined row hides its Accept and Decline buttons from VoiceOver.
            if room.isInvite { InviteAccessibilityActions(room: room) }
        }
    }

    /// At accessibility sizes, side by side can't fit: the face on top, then the name, the time
    /// and the preview, each on their own lines, never cut to a letter. The dot keeps its slot in
    /// the margin, so the text starts where it does at other sizes.
    private var accessibilityLayout: some View {
        HStack(alignment: .top, spacing: reservesUnreadSpace ? unreadGap : 0) {
            if reservesUnreadSpace {
                UnreadMark(kind: room.unreadKind)
                    .frame(height: Theme.Metrics.rowAvatar)
            }
            accessibilityStack
        }
    }

    private var accessibilityStack: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.s) {
                AvatarView(name: room.name, seed: room.avatarSeed, url: room.avatarUrl, size: Theme.Metrics.rowAvatar, isRoom: room.isRoom)
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                if room.isMuted {
                    Image(systemName: "bell.slash.fill").foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                Text(room.name)
                    .font(nameFont)
                    .lineLimit(3)
                if room.isRoom {
                    RoomBadge(isPublic: room.isPublic)
                }
            }
            Text(TimeFormat.list(room.timestampMs, now: clock.now))
                .font(timeFont)
                .foregroundStyle(.secondary)
            PreviewLine(room: room)
                .font(previewFont)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            if room.isInvite {
                InviteButtons(roomID: room.id)
            }
        }
    }

    private var standardLayout: some View {
        HStack(alignment: .center, spacing: reservesUnreadSpace ? unreadGap : 0) {
            if reservesUnreadSpace {
                UnreadMark(kind: room.unreadKind)
            }
            HStack(alignment: .center, spacing: Theme.Spacing.m) {
                AvatarView(name: room.name, seed: room.avatarSeed, url: room.avatarUrl, size: Theme.Metrics.rowAvatar, isRoom: room.isRoom)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                        Text(room.name)
                            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                            .font(nameFont)
                            .lineLimit(1)
                        if room.isRoom {
                            RoomBadge(isPublic: room.isPublic)
                        }
                        Spacer(minLength: Theme.Spacing.s)
                        Text(TimeFormat.list(room.timestampMs, now: clock.now))
                            .font(timeFont)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .layoutPriority(1)
                        #if os(iOS)
                        // Messages sets the disclosure chevron right after the time.
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        #endif
                    }
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                        PreviewLine(room: room)
                            .font(previewFont)
                            .foregroundStyle(.secondary)
                            // An invitation's one line sits right on its buttons, not a blank line above.
                            .lineLimit(previewLines, reservesSpace: previewLines > 1 && !room.isInvite)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if room.isMuted {
                            // Where Messages puts it: under the time, at the end of the preview.
                            Image(systemName: "bell.slash.fill")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    if room.isInvite {
                        InviteButtons(roomID: room.id)
                            .padding(.top, Theme.Spacing.xs)
                    }
                }
            }
        }
    }

    private var accessibilityText: Text {
        var parts = [room.name]
        switch room.unreadKind {
        case .mention: parts.append(String(localized: "Mentions you"))
        case .unread: parts.append(String(localized: "Unread"))
        case .none: break
        }
        if room.isRoom { parts.append(room.isPublic ? String(localized: "Public room") : String(localized: "Room")) }
        if room.isMuted { parts.append(String(localized: "Muted")) }
        // What the row shows, in the order it shows it.
        if let draft = room.draft {
            parts.append(String(localized: "Draft: \(draft)"))
        } else if room.lastSendState == .failed {
            parts.append(String(localized: "Not Delivered"))
        } else {
            parts.append(Copy.preview(room))
        }
        parts.append(TimeFormat.list(room.timestampMs, now: clock.now))
        return Text(parts.joined(separator: ", "))
    }

    // The Mac sizes are Messages' sidebar, measured: a 14-point name over a 13-point preview.
    private var nameFont: Font {
        #if os(macOS)
        .system(size: 14, weight: .semibold)
        #else
        .body.weight(.semibold)
        #endif
    }

    private var timeFont: Font {
        #if os(macOS)
        .body
        #else
        .subheadline
        #endif
    }

    private var previewFont: Font {
        #if os(macOS)
        .body
        #else
        .subheadline
        #endif
    }

    private var previewLines: Int { 2 }

    private var rowPadding: CGFloat {
        #if os(macOS)
        Theme.Spacing.s + 1
        #else
        0
        #endif
    }

    /// Where the name starts, past the dot's slot and the photo.
    private var separatorLeading: CGFloat {
        (reservesUnreadSpace ? 15 + unreadGap : 0) + Theme.Metrics.rowAvatar + Theme.Spacing.m
    }

    /// The unread dot sits in the margin, close to the avatar, as in Messages.
    private var unreadGap: CGFloat {
        #if os(macOS)
        Theme.Spacing.s
        #else
        Theme.Spacing.xs + 2
        #endif
    }
}

extension EnvironmentValues {
    /// Rows keep a column for the unread dot only while something in the list is unread, so a
    /// caught-up list isn't indented for dots it doesn't have.
    @Entry var reservesUnreadSpace = true
}

/// Beside a room's name: a room, not a person, the way Messages marks a business. Public rooms,
/// which anyone can find and join, show a globe.
struct RoomBadge: View {
    let isPublic: Bool

    var body: some View {
        Image(systemName: isPublic ? "globe" : "number")
            .font(.caption.weight(.bold))
            .imageScale(.small)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

/// The preview line: a draft first (in red, as Mail does), a failed send, or the latest message.
private struct PreviewLine: View {
    let room: RoomSummary

    var body: some View {
        if let draft = room.draft {
            let label = Text("Draft").foregroundStyle(.red)
            Text("\(label) \(draft)")
        } else if room.lastSendState == .failed {
            let mark = Text(Image(systemName: "exclamationmark.circle.fill")).foregroundStyle(.red)
            Text("\(mark) \(Text("Not Delivered"))")
        } else if case .message(let sender, let body, _, _) = room.preview, let symbol = Copy.symbol(for: body) {
            // Media reads at a glance with its symbol, as in Messages: "Priya: [photo] Photo".
            let glyph = Text(Image(systemName: symbol))
            let text = Copy.messageText(sender, body: body, roomName: room.name)
            if let prefix = Copy.senderPrefix(sender, body: body) {
                Text("\(prefix) \(glyph) \(text)")
            } else {
                Text("\(glyph) \(text)")
            }
        } else {
            Text(Copy.preview(room))
        }
    }
}

/// The leading dot, in a fixed slot so every row's avatar lines up.
struct UnreadMark: View {
    let kind: UnreadKind

    var body: some View {
        ZStack {
            switch kind {
            case .unread:
                Circle()
                    .fill(.tint)
                    .frame(width: 10, height: 10)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            case .mention:
                Image(systemName: "at")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(.orange, in: .circle)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            case .none:
                EmptyView()
            }
        }
        .frame(width: 15)
        .animation(Theme.Motion.flip, value: kind)
        .accessibilityHidden(true)
    }
}
