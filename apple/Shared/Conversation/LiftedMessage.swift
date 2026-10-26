import XeniaCore
import SwiftUI

#if os(iOS)
import UIKit

/// A message held to react or act on it, as Messages lifts one: the conversation blurs, the
/// bubble rises clear of it, its Tapbacks wait in a glass bar above, and what can be done with
/// it sits in a menu below. A double tap lifts it with the Tapbacks only.
struct LiftedMessage: Identifiable {
    let message: TimelineMessage
    /// Where the bubble (with its Tapbacks) is in the window.
    let frame: CGRect
    let context: ConversationContext
    let showsMenu: Bool
    /// The Tapbacks offered, read from the message once as it lifts.
    let suggestions: [String]

    var id: String { message.id }
}

extension ConversationModel {
    /// Lifts a message over the conversation, from where its bubble is now.
    func lift(_ message: TimelineMessage, from anchor: LiftAnchorBox, context: ConversationContext, showsMenu: Bool) {
        guard let frame = anchor.frame() else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            lifted = LiftedMessage(
                message: message, frame: frame, context: context, showsMenu: showsMenu,
                suggestions: ReactionSuggestions.suggest(for: message)
            )
        }
    }
}

// MARK: - Finding the bubble

/// Holds the bubble's UIKit view, so its place in the window is read when it's held, not tracked
/// as the conversation scrolls.
@MainActor
final class LiftAnchorBox {
    fileprivate weak var view: UIView?

    func frame() -> CGRect? {
        guard let view, let window = view.window else { return nil }
        return view.convert(view.bounds, to: window)
    }
}

struct LiftAnchor: UIViewRepresentable {
    let box: LiftAnchorBox

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        box.view = view
    }
}

/// Holding a bubble: a UIKit long press, so a drag that starts on a bubble still scrolls.
struct LiftPress: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let onLift: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let press = UILongPressGestureRecognizer()
        press.minimumPressDuration = 0.32
        press.isEnabled = isEnabled
        return press
    }

    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        if recognizer.state == .began { onLift() }
    }
}

// MARK: - The lifted message

struct LiftedMessageView: View {
    let lifted: LiftedMessage

    @Environment(ConversationModel.self) private var conversation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var menuHeight: CGFloat = 0
    @State private var choosingEmoji = false
    /// Bumped by choosing a Tapback: felt here, since the conversation is covered.
    @State private var reactions = 0
    @ScaledMetric(relativeTo: .body) private var tapbackSize = Theme.Metrics.tapback

    /// The lifted message going back into the conversation.
    static let settle = Animation.spring(duration: 0.3, bounce: 0)

    private static let gap: CGFloat = 8
    private static let margin: CGFloat = 12
    private static let menuWidth: CGFloat = 250

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            let bubble = lifted.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            let place = placement(bubble: bubble, in: proxy.size)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.regularMaterial)
                    .opacity(shown ? 1 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { dismiss() }
                    .accessibilityHidden(true)

                BubbleWithTapbacks(message: lifted.message, tapback: min(tapbackSize, Theme.Metrics.tapback * 1.6))
                    .environment(\.conversationContext, lifted.context)
                    // Quick Look and Share stay anchored to the bubble in the conversation.
                    .environment(\.marksPreviewAnchors, false)
                    .allowsHitTesting(false)
                    .overlay { DragOut(lifted: lifted, dismiss: { dismiss() }) }
                    .frame(width: bubble.width, height: bubble.height)
                    .scaleEffect(shown && !reduceMotion ? 1.02 : 1)
                    .shadow(color: .black.opacity(shown ? 0.12 : 0), radius: 14, y: 6)
                    .position(x: bubble.midX, y: bubble.midY + (shown ? place.shift : 0))
                    .accessibilityHidden(true)

                TapbackBar(message: lifted.message, suggestions: lifted.suggestions, shown: shown, choosingEmoji: $choosingEmoji) { emoji in
                    react(emoji)
                }
                .fixedSize()
                .scaleEffect(shown || reduceMotion ? 1 : 0.4, anchor: lifted.message.isOwn ? .bottomTrailing : .bottomLeading)
                .opacity(shown ? 1 : 0)
                .alignmentGuide(.leading) { $0[lifted.message.isOwn ? .trailing : .leading] - place.barX }
                .alignmentGuide(.top) { $0[.bottom] - place.barBottom }

                if lifted.showsMenu {
                    LiftedMenu(groups: actions, contentHeight: $menuHeight) { action in
                        dismiss(then: action)
                    }
                    .frame(width: Self.menuWidth, height: min(menuHeight, place.menuMaxHeight))
                    .scaleEffect(shown && !choosingEmoji || reduceMotion ? 1 : 0.5, anchor: lifted.message.isOwn ? .topTrailing : .topLeading)
                    .opacity(shown && !choosingEmoji ? 1 : 0)
                    .animation(Theme.Motion.panel, value: choosingEmoji)
                    .offset(x: place.menuX, y: place.menuTop)
                }
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: shown) { _, new in new }
        .sensoryFeedback(.impact(weight: .light), trigger: reactions)
        .onAppear {
            // A turn later, once the menu has been measured, so the message knows where to rise to.
            DispatchQueue.main.async {
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.42, bounce: 0.22)) { shown = true }
            }
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { dismiss() }
    }

    // MARK: Placement

    private struct Placement {
        /// How far the bubble moves so the bar and menu fit on screen.
        var shift: CGFloat
        var barX: CGFloat
        var barBottom: CGFloat
        var menuX: CGFloat
        var menuTop: CGFloat
        var menuMaxHeight: CGFloat
    }

    private func placement(bubble: CGRect, in size: CGSize) -> Placement {
        let gap = Self.gap
        let bar: CGFloat = TapbackBar.height
        // Choosing any emoji, the keyboard takes the menu's place.
        let hasMenu = lifted.showsMenu && !choosingEmoji
        let menu = hasMenu ? menuHeight : 0
        let top = gap
        let bottom = size.height - gap
        var shift: CGFloat = 0
        let neededTop = bubble.minY - gap - bar
        if neededTop < top { shift = top - neededTop }
        let neededBottom = bubble.maxY + (hasMenu ? gap + menu : 0)
        if neededBottom + shift > bottom { shift = max(top - neededTop, bottom - neededBottom) }
        let moved = bubble.offsetBy(dx: 0, dy: shift)
        // A bubble too tall for both: the menu sits over its lower part, against the bottom.
        let menuTop = min(moved.maxY + gap, bottom - menu)
        let isOwn = lifted.message.isOwn
        let edge = isOwn ? moved.maxX : moved.minX
        let barX = min(max(edge, Self.margin), size.width - Self.margin)
        let menuX = isOwn
            ? min(moved.maxX, size.width - Self.margin) - Self.menuWidth
            : max(moved.minX, Self.margin)
        return Placement(
            shift: shift, barX: barX, barBottom: moved.minY - gap,
            menuX: max(Self.margin, min(menuX, size.width - Self.margin - Self.menuWidth)),
            menuTop: menuTop, menuMaxHeight: max(160, bottom - menuTop)
        )
    }

    // MARK: Acting

    private func react(_ emoji: String) {
        RecentReactions.use(emoji)
        reactions += 1
        conversation.toggleReaction(emoji, on: lifted.message, feedback: false)
        dismiss()
    }

    /// Settles the bubble back into the conversation, then does what was chosen: sheets open
    /// once the lifted message is gone.
    private func dismiss(then action: (() -> Void)? = nil) {
        choosingEmoji = false
        withAnimation(reduceMotion ? .easeOut(duration: 0.18) : Self.settle) {
            shown = false
        } completion: {
            conversation.afterLift = action
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { conversation.lifted = nil }
        }
    }

    private var actions: [[LiftedAction]] {
        LiftedAction.groups(for: lifted.message, context: lifted.context, conversation: conversation)
    }
}

/// Over a lifted photo, video or file: touching and holding it again picks it up, to drop into
/// another app, as in Messages. A tap puts it back.
private struct DragOut: View {
    let lifted: LiftedMessage
    let dismiss: () -> Void

    var body: some View {
        if let attachment = MessageAttachment(lifted.message), let previewer = lifted.context.previewer {
            Color.clear
                .contentShape(.rect)
                .onTapGesture(perform: dismiss)
                .attachmentDrag(attachment, previewer: previewer) {
                    if let image = previewer.bubbleImage(for: attachment.id) ?? FileIcon.icon(for: attachment.type) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 160, maxHeight: 160)
                    }
                }
        }
    }
}

// MARK: - Tapbacks

/// The glass bar of Tapbacks above a lifted message: six chosen for it, then any emoji. Mine are
/// marked; choosing one again takes it back.
private struct TapbackBar: View {
    let message: TimelineMessage
    let suggestions: [String]
    let shown: Bool
    @Binding var choosingEmoji: Bool
    let choose: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 52
    private static let cell: CGFloat = 42

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(suggestions.enumerated()), id: \.element) { index, emoji in
                let isMine = message.reactions.contains { $0.isMine && $0.key == emoji }
                Button { choose(emoji) } label: {
                    Text(emoji)
                        .font(.system(size: 27))
                        .frame(width: Self.cell, height: Self.cell)
                        .background(isMine ? AnyShapeStyle(Color.ownBubble) : AnyShapeStyle(.clear), in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(PressScaleButtonStyle())
                // Each pops in a moment after the one before, from the bubble's side outward.
                .scaleEffect(shown || reduceMotion ? 1 : 0.4)
                .animation(pop(delay: Double(index) * 0.025), value: shown)
                .accessibilityLabel(Text(emoji))
                .accessibilityAddTraits(isMine ? .isSelected : [])
            }
            Button {
                choosingEmoji = true
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.cell, height: Self.cell)
                    .background(.fill.tertiary, in: .circle)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary, .background)
                            .offset(x: -3, y: -3)
                    }
            }
            .buttonStyle(PressScaleButtonStyle())
            .scaleEffect(shown || reduceMotion ? 1 : 0.4)
            .animation(pop(delay: 0.15), value: shown)
            .accessibilityLabel(Text("More Emoji"))
            .background {
                EmojiInput(isActive: $choosingEmoji, choose: choose)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .accessibilityHidden(true)
            }
        }
        .padding(5)
        .frame(height: Self.height)
        .glassEffect(.regular.interactive(), in: .capsule)
        .sensoryFeedback(.selection, trigger: choosingEmoji) { _, new in new }
    }

    /// Popping in staggers; going away, they settle with the bubble, all at once, so none is
    /// still shrinking when the lifted message is gone.
    private func pop(delay: Double) -> Animation? {
        guard !reduceMotion else { return nil }
        return shown ? .spring(duration: 0.4, bounce: 0.35).delay(delay) : LiftedMessageView.settle
    }
}

/// A hidden field that brings up the emoji keyboard, for any emoji as a Tapback.
private struct EmojiInput: UIViewRepresentable {
    @Binding var isActive: Bool
    let choose: (String) -> Void

    func makeUIView(context: Context) -> EmojiField {
        let field = EmojiField()
        field.onPick = { choose($0) }
        field.onEnd = { isActive = false }
        return field
    }

    func updateUIView(_ field: EmojiField, context: Context) {
        field.onPick = { choose($0) }
        if isActive, !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !isActive, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    final class EmojiField: UITextField, UITextFieldDelegate {
        var onPick: (String) -> Void = { _ in }
        var onEnd: () -> Void = {}

        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self
            autocorrectionType = .no
            tintColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        /// Opens on the emoji keyboard, as Messages does for any Tapback.
        override var textInputMode: UITextInputMode? {
            UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if let emoji = string.first, emoji.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x238C }) {
                onPick(String(emoji))
            }
            return false
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            onEnd()
        }
    }
}

// MARK: - The menu

/// One thing a lifted message's menu can do.
struct LiftedAction: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let symbol: String
    var isDestructive = false
    let perform: () -> Void

    /// The message's actions, in Messages' order: answering it, copying it, sharing it,
    /// organizing it, then reporting and deleting last.
    @MainActor
    static func groups(for message: TimelineMessage, context: ConversationContext, conversation: ConversationModel) -> [[LiftedAction]] {
        let attachment = MessageAttachment(message)
        let isSent = message.eventId != nil && message.sendState == .sent
        /// Copying and saving change nothing on screen, so they're felt once done.
        func run(_ work: @escaping () async throws -> Void) {
            conversation.perform {
                try await work()
                conversation.give(.succeeded)
            }
        }
        var groups: [[LiftedAction]] = []

        var answer: [LiftedAction] = []
        if message.canReply {
            answer.append(LiftedAction(id: "reply", title: "Reply", symbol: "arrowshape.turn.up.left") { conversation.reply(to: message) })
        }
        if !context.isThread, message.canReply, let root = message.eventId {
            answer.append(LiftedAction(id: "thread", title: "Reply in Thread", symbol: "bubble.left.and.text.bubble.right") { context.openThread(root) })
        }
        if message.canEdit {
            answer.append(LiftedAction(id: "edit", title: "Edit", symbol: "pencil") { conversation.edit(message) })
        }
        groups.append(answer)

        var copy: [LiftedAction] = []
        if let attachment, let previewer = context.previewer {
            copy.append(LiftedAction(id: "copy", title: "Copy", symbol: "doc.on.doc") {
                run { try await AttachmentActions.copy(attachment, previewer: previewer) }
            })
            copy.append(LiftedAction(id: "share", title: "Share…", symbol: "square.and.arrow.up") { previewer.share(attachment) })
            if attachment.kind == .photo || attachment.kind == .video {
                copy.append(LiftedAction(id: "save", title: "Save to Photos", symbol: "square.and.arrow.down") {
                    run { try await AttachmentActions.saveToPhotos(attachment, previewer: previewer) }
                })
            }
        } else if let text = message.plainText, !text.isEmpty {
            copy.append(LiftedAction(id: "copy", title: "Copy", symbol: "doc.on.doc") { conversation.copy(text) })
            copy.append(LiftedAction(id: "select", title: "Select Text", symbol: "text.cursor") { conversation.selectingText = message })
        }
        groups.append(copy)

        var share: [LiftedAction] = []
        if message.canForward {
            share.append(LiftedAction(id: "forward", title: "Forward…", symbol: "arrowshape.turn.up.right") { conversation.forwarding = message })
        }
        if isSent {
            share.append(LiftedAction(id: "link", title: "Copy Link", symbol: "link") { conversation.copyLink(to: message) })
        }
        if message.isOwn, isSent, message.content != .deleted {
            share.append(LiftedAction(id: "receipts", title: "Read Receipts", symbol: "eye") { conversation.viewingReceipts = message })
        }
        groups.append(share)

        var organize: [LiftedAction] = []
        if isSent {
            organize.append(LiftedAction(id: "pin", title: message.isPinned ? "Unpin" : "Pin", symbol: message.isPinned ? "pin.slash" : "pin") {
                conversation.setPinned(message, !message.isPinned)
            })
        }
        if case .poll(_, _, _, _, _, _, true) = message.content {
            organize.append(LiftedAction(id: "endPoll", title: "End Poll…", symbol: "checkmark.circle") { conversation.endingPoll = message })
        }
        if message.sendState == .failed {
            organize.append(LiftedAction(id: "retry", title: "Try Again", symbol: "arrow.clockwise") { conversation.retry(message) })
        }
        groups.append(organize)

        var last: [LiftedAction] = []
        if !message.isOwn, message.eventId != nil, message.content != .deleted {
            last.append(LiftedAction(id: "report", title: "Report…", symbol: "exclamationmark.bubble") { conversation.reporting = message })
        }
        if message.canRedact, message.content != .deleted {
            last.append(LiftedAction(id: "delete", title: "Delete…", symbol: "trash", isDestructive: true) { conversation.deleting = message })
        }
        groups.append(last)

        return groups.filter { !$0.isEmpty }
    }
}

/// The menu under a lifted message, drawn as iOS draws one: glass, a row per action with its
/// symbol at the trailing edge, and a thicker gap between groups. It scrolls when it can't fit.
private struct LiftedMenu: View {
    let groups: [[LiftedAction]]
    /// Its full height, measured inside the scroll view, so the message can make room for it.
    @Binding var contentHeight: CGFloat
    let choose: (@escaping () -> Void) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 {
                        Rectangle()
                            .fill(.primary.opacity(0.06))
                            .frame(height: 7)
                    }
                    ForEach(Array(group.enumerated()), id: \.element.id) { row, action in
                        if row > 0 {
                            Divider().padding(.leading, Theme.Spacing.l)
                        }
                        Button { choose(action.perform) } label: {
                            HStack {
                                Text(action.title)
                                Spacer(minLength: Theme.Spacing.m)
                                Image(systemName: action.symbol)
                                    .frame(width: 24)
                            }
                            .font(.body)
                            .foregroundStyle(action.isDestructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                            .padding(.horizontal, Theme.Spacing.l)
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                        }
                        .buttonStyle(MenuRowStyle())
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
    }
}

private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear))
    }
}
#endif
