import AppKit
import XeniaCore
import SwiftUI

/// What a message's menu can do, from the SwiftUI row that draws it.
struct MessageMenuActions {
    let message: TimelineMessage
    let conversation: ConversationModel
    let context: ConversationContext
    let confirmDelete: () -> Void
}

extension View {
    /// The Mac's message menu, as Messages draws it: right-click, Control-click or click and hold
    /// a message for a grid of Tapbacks over the usual commands.
    func macMessageMenu(_ actions: MessageMenuActions) -> some View {
        overlay { MessageMenuAnchor(actions: actions) }
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                MessageMenuHost.host(for: actions.message.id)?.popUp()
            })
            // VoiceOver reaches the same menu (VO-Shift-M), and Reply directly.
            .accessibilityAction(.showMenu) {
                MessageMenuHost.host(for: actions.message.id)?.popUp()
            }
            .accessibilityAction(named: Text("Reply")) {
                if actions.message.canReply { actions.conversation.reply(to: actions.message) }
            }
    }
}

private struct MessageMenuAnchor: NSViewRepresentable {
    let actions: MessageMenuActions

    func makeNSView(context: Context) -> MessageMenuHost { MessageMenuHost() }

    func updateNSView(_ view: MessageMenuHost, context: Context) {
        view.actions = actions
        view.register()
    }
}

/// Sits over a bubble, invisible to ordinary clicks, and answers the menu clicks.
final class MessageMenuHost: NSView {
    var actions: MessageMenuActions?

    private static let hosts = NSMapTable<NSString, MessageMenuHost>.strongToWeakObjects()

    /// The bubble showing this message, if it's in a window.
    static func host(for messageID: String) -> MessageMenuHost? {
        guard let host = hosts.object(forKey: messageID as NSString), host.window != nil,
              host.actions?.message.id == messageID
        else { return nil }
        return host
    }

    func register() {
        guard window != nil, let id = actions?.message.id else { return }
        Self.hosts.setObject(self, forKey: id as NSString)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        register()
    }

    /// Only a menu click lands here; every other click goes through to the bubble.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, frame.contains(point) else { return nil }
        let isMenuClick = event.type == .rightMouseDown || event.type == .rightMouseUp
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        return isMenuClick ? self : nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeMenu()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = makeMenu() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.mouseDown(with: event)
        }
    }

    /// Opens the menu under the bubble's top corner, for click and hold and ⌘T.
    func popUp() {
        guard let menu = makeMenu(), let message = actions?.message else { return }
        let x = message.isOwn ? bounds.maxX - 220 : bounds.minX
        menu.popUp(positioning: nil, at: NSPoint(x: max(bounds.minX, x), y: isFlipped ? bounds.minY : bounds.maxY), in: self)
    }

    private func makeMenu() -> NSMenu? {
        guard let actions else { return nil }
        return MessageMenuBuilder(actions: actions, host: self).build()
    }
}

/// Builds the menu: the Tapback grid, then the commands in Messages' order.
@MainActor
private struct MessageMenuBuilder {
    let actions: MessageMenuActions
    let host: MessageMenuHost

    private var message: TimelineMessage { actions.message }
    private var conversation: ConversationModel { actions.conversation }

    func build() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if message.eventId != nil, message.sendState == .sent {
            menu.addItem(tapbackGrid(closing: menu))
            // ⌘T, then 1 to 6, as in Messages.
            for (index, emoji) in ReactionSuggestions.suggest(for: message).enumerated() {
                let item = ActionMenuItem(title: emoji) { react(emoji) }
                item.keyEquivalent = "\(index + 1)"
                item.keyEquivalentModifierMask = []
                item.isHidden = true
                item.allowsKeyEquivalentWhenHidden = true
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        var group: [NSMenuItem] = []
        if message.canReply {
            group.append(item("Reply", symbol: "arrowshape.turn.up.left") { conversation.reply(to: message) })
        }
        if !actions.context.isThread, message.canReply, let root = message.eventId {
            group.append(item("Reply in Thread", symbol: "bubble.left.and.text.bubble.right") { actions.context.openThread(root) })
        }
        if message.canEdit {
            group.append(item("Edit", symbol: "pencil") { conversation.edit(message) })
        }
        add(group, to: menu)

        group = []
        if let attachment = MessageAttachment(message), let previewer = actions.context.previewer {
            group.append(item("Open", symbol: "arrow.up.left.and.arrow.down.right") { previewer.open(attachment.id) })
            group.append(item("Share…", symbol: "square.and.arrow.up") { previewer.share(attachment) })
            group.append(item("Save to Downloads", symbol: "arrow.down.circle") {
                run { try await AttachmentActions.saveToDownloads(attachment, previewer: previewer) }
            })
            group.append(item("Copy", symbol: "doc.on.doc") {
                run { try await AttachmentActions.copy(attachment, previewer: previewer) }
            })
        } else if let text = message.plainText, !text.isEmpty {
            group.append(item("Copy", symbol: "doc.on.doc") { Pasteboard.copy(text) })
        }
        add(group, to: menu)

        group = []
        if message.canForward {
            group.append(item("Forward…", symbol: "arrowshape.turn.up.right") { conversation.forwarding = message })
        }
        if message.eventId != nil, message.sendState == .sent {
            group.append(item("Copy Link", symbol: "link") { conversation.copyLink(to: message) })
        }
        if message.isOwn, message.eventId != nil, message.sendState == .sent, message.content != .deleted {
            group.append(item("Read Receipts", symbol: "eye") { conversation.viewingReceipts = message })
        }
        add(group, to: menu)

        group = []
        if message.eventId != nil, message.sendState == .sent {
            group.append(item(message.isPinned ? "Unpin" : "Pin", symbol: message.isPinned ? "pin.slash" : "pin") {
                conversation.setPinned(message, !message.isPinned)
            })
        }
        if case .poll(_, _, _, _, _, _, true) = message.content {
            group.append(item("End Poll…", symbol: "checkmark.circle") { conversation.endingPoll = message })
        }
        if message.sendState == .failed {
            group.append(item("Try Again", symbol: "arrow.clockwise") { conversation.retry(message) })
        }
        add(group, to: menu)

        group = []
        if !message.isOwn, message.eventId != nil, message.content != .deleted {
            group.append(item("Report…", symbol: "exclamationmark.bubble") { conversation.reporting = message })
        }
        if message.canRedact, message.content != .deleted {
            group.append(item("Delete…", symbol: "trash", action: actions.confirmDelete))
        }
        add(group, to: menu)
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        return menu
    }

    private func tapbackGrid(closing menu: NSMenu) -> NSMenuItem {
        let suggested = ReactionSuggestions.suggest(for: message)
        let view = TapbackGridView(
            mine: Set(message.reactions.filter(\.isMine).map(\.key)),
            suggested: suggested,
            choose: { key in
                menu.cancelTracking()
                react(key)
            },
            pickAny: { [host] in
                menu.cancelTracking()
                EmojiReactionPicker.show(over: host) { react($0) }
            }
        )
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func react(_ key: String) {
        RecentReactions.use(key)
        conversation.toggleReaction(key, on: message)
    }

    private func item(_ title: LocalizedStringResource, symbol: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = ActionMenuItem(title: String(localized: title), action: action)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private func add(_ items: [NSMenuItem], to menu: NSMenu) {
        guard !items.isEmpty else { return }
        if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
        items.forEach(menu.addItem)
    }

    private func run(_ work: @escaping () async throws -> Void) {
        let conversation = conversation
        Task {
            do { try await work() } catch { conversation.errorMessage = Copy.error(error) }
        }
    }
}

/// A menu item that runs a closure. The item holds its handler, since targets aren't retained.
private func ActionMenuItem(title: String, action: @escaping () -> Void) -> NSMenuItem {
    let handler = MenuHandler(action)
    let item = NSMenuItem(title: title, action: #selector(MenuHandler.run), keyEquivalent: "")
    item.target = handler
    item.representedObject = handler
    return item
}

private final class MenuHandler: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run() { action() }
}

/// The top of the menu, as the iPhone's Tapback bar: six reactions chosen for this message, then
/// a button for any emoji. Ones I've already given are tinted; choosing one again takes it back. AppKit tracks
/// the pointer here, not SwiftUI: inside a menu that's what lets a reaction be chosen by holding
/// the button down on the message and letting go over it, as in Messages.
final class TapbackGridView: NSView {
    private let model: TapbackGridModel
    private let choose: (String) -> Void
    private let pickAny: () -> Void
    private let hosting: NSHostingView<TapbackGrid>
    /// The press began in the grid, or the pointer was dragged into it: only then does letting
    /// go choose (the release of the click that opened the menu mustn't).
    private var isTracking = false
    /// While the button that opened the menu is still held, the menu sends this view no events
    /// at all, so the pointer is followed by a timer that runs only while the menu is open.
    private var follower: Timer?
    private var wasHeld = false
    /// The cell under the pointer when the menu opened: letting go there without moving is the
    /// end of the opening click, not a choice.
    private var openedOver: String??
    private var didChoose = false

    init(mine: Set<String>, suggested: [String], choose: @escaping (String) -> Void, pickAny: @escaping () -> Void) {
        model = TapbackGridModel(mine: mine, rows: [suggested + [TapbackGrid.moreKey]])
        self.choose = choose
        self.pickAny = pickAny
        hosting = NSHostingView(rootView: TapbackGrid(model: model))
        super.init(frame: .zero)
        hosting.frame.size = hosting.fittingSize
        frame.size = hosting.fittingSize
        addSubview(hosting)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        follower?.invalidate()
        follower = nil
        guard window != nil else { return }
        wasHeld = NSEvent.pressedMouseButtons != 0
        openedOver = nil
        didChoose = false
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        // Menus track in their own run loop mode; common modes include it.
        RunLoop.main.add(timer, forMode: .common)
        follower = timer
    }

    /// Follows a held button: highlights the cell under the pointer, and letting go over one
    /// chooses it.
    private func follow() {
        guard let window, !didChoose else { return }
        let held = NSEvent.pressedMouseButtons != 0
        guard held || wasHeld else {
            // Opened from the keyboard, or by a click already let go: nothing to follow.
            follower?.invalidate()
            follower = nil
            return
        }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let key = key(at: point)
        if openedOver == nil { openedOver = .some(key) }
        if held {
            if model.highlighted != key { model.highlighted = key }
            if key != openedOver ?? nil { isTracking = true }
        } else {
            wasHeld = false
            // Released: the menu sends this view its own mouse events from here on.
            follower?.invalidate()
            follower = nil
            if isTracking, let key { pick(key) }
        }
        if held { wasHeld = true }
    }

    /// The cell under a point, by the grid's fixed geometry.
    private func key(at event: NSEvent) -> String? {
        key(at: convert(event.locationInWindow, from: nil))
    }

    private func key(at point: NSPoint) -> String? {
        let column = Int(floor((point.x - TapbackGrid.inset.leading + TapbackGrid.spacing / 2) / (TapbackGrid.cell.width + TapbackGrid.spacing)))
        let row = Int(floor((point.y - TapbackGrid.inset.top + TapbackGrid.spacing / 2) / (TapbackGrid.cell.height + TapbackGrid.spacing)))
        guard model.rows.indices.contains(row), model.rows[row].indices.contains(column) else { return nil }
        return model.rows[row][column]
    }

    private func track(_ event: NSEvent) {
        model.highlighted = key(at: event)
    }

    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseEntered(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) {
        model.highlighted = nil
    }

    override func mouseDown(with event: NSEvent) {
        isTracking = true
        track(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        isTracking = true
        track(event)
    }

    override func mouseDragged(with event: NSEvent) {
        isTracking = true
        track(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        isTracking = true
        track(event)
    }

    override func mouseUp(with event: NSEvent) { release(event) }
    override func rightMouseUp(with event: NSEvent) { release(event) }

    private func release(_ event: NSEvent) {
        guard isTracking, let key = key(at: event) else { return }
        pick(key)
    }

    private func pick(_ key: String) {
        guard !didChoose else { return }
        didChoose = true
        isTracking = false
        follower?.invalidate()
        follower = nil
        if key == TapbackGrid.moreKey { pickAny() } else { choose(key) }
    }
}

@Observable
final class TapbackGridModel {
    let mine: Set<String>
    let rows: [[String]]
    var highlighted: String?

    init(mine: Set<String>, rows: [[String]]) {
        self.mine = mine
        self.rows = rows
    }
}

/// The grid as drawn. Still, as Messages' is: a soft square behind the one under the pointer,
/// nothing that grows or moves.
struct TapbackGrid: View {
    let model: TapbackGridModel

    static let moreKey = "xenia.more"
    static let cell = CGSize(width: 36, height: 34)
    static let spacing: CGFloat = 4
    static let inset = EdgeInsets(top: 6, leading: 10, bottom: 4, trailing: 10)

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(model.rows.indices, id: \.self) { row in
                HStack(spacing: Self.spacing) {
                    ForEach(model.rows[row], id: \.self) { key in
                        TapbackCell(key: key, isMine: model.mine.contains(key), isHighlighted: model.highlighted == key)
                    }
                }
            }
        }
        .padding(Self.inset)
    }
}

private struct TapbackCell: View {
    let key: String
    let isMine: Bool
    let isHighlighted: Bool

    var body: some View {
        Group {
            if key == TapbackGrid.moreKey {
                Image(systemName: "face.smiling")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary, .background)
                            .offset(x: 3, y: 2)
                    }
                    .accessibilityLabel(Text("More Emoji"))
            } else {
                Text(key)
                    .font(.system(size: 22))
                    .accessibilityLabel(Text(key))
            }
        }
        .frame(width: TapbackGrid.cell.width, height: TapbackGrid.cell.height)
        .background(fill, in: .rect(cornerRadius: 8, style: .continuous))
        .accessibilityAddTraits(isMine ? [.isButton, .isSelected] : .isButton)
    }

    private var fill: AnyShapeStyle {
        if isMine { return AnyShapeStyle(Color.ownBubble.opacity(isHighlighted ? 0.32 : 0.22)) }
        if isHighlighted { return AnyShapeStyle(.quaternary) }
        return key == TapbackGrid.moreKey ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(.clear)
    }
}

/// Any emoji as a Tapback, as in Messages: the system emoji picker opens beside the message and
/// what's chosen there becomes the reaction. A hidden field near the bubble takes the choice.
@MainActor
enum EmojiReactionPicker {
    private static weak var field: EmojiCatcher?

    static func show(over host: NSView, choose: @escaping (String) -> Void) {
        guard let window = host.window, let content = window.contentView else { return }
        field?.finish()
        let isOwn = (host as? MessageMenuHost)?.actions?.message.isOwn ?? false
        let corner = host.convert(NSPoint(x: isOwn ? host.bounds.minX : host.bounds.maxX, y: host.bounds.midY), to: content)
        let catcher = EmojiCatcher(catcherFrame: NSRect(x: corner.x, y: corner.y, width: 1, height: 1))
        catcher.onPick = choose
        content.addSubview(catcher)
        field = catcher
        // The picker opens after the menu has finished closing.
        DispatchQueue.main.async {
            window.makeFirstResponder(catcher)
            NSApp.orderFrontCharacterPalette(nil)
        }
    }
}

private final class EmojiCatcher: NSTextView {
    var onPick: ((String) -> Void)?
    private weak var previousResponder: NSResponder?

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        alphaValue = 0.01
        drawsBackground = false
        isRichText = false
        setAccessibilityElement(false)
    }

    convenience init(catcherFrame frame: NSRect) {
        self.init(frame: frame, textContainer: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func becomeFirstResponder() -> Bool {
        previousResponder = window?.firstResponder
        return super.becomeFirstResponder()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        if let emoji = text.first, emoji.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x238C }) {
            onPick?(String(emoji))
        }
        finish()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { DispatchQueue.main.async { [weak self] in self?.removeFromSuperview() } }
        return resigned
    }

    func finish() {
        onPick = nil
        let window = window
        let previous = previousResponder
        removeFromSuperview()
        if let window, let previous, previous !== self { window.makeFirstResponder(previous) }
    }
}

#Preview("Tapback Grid") {
    // As it sits at the top of the menu, for "We shipped it!": one already mine, one under the pointer.
    let model = TapbackGridModel(mine: ["🎉"], rows: [["🎉", "🥳", "👏", "❤️", "😍", "🙌", TapbackGrid.moreKey]])
    model.highlighted = "❤️"
    return TapbackGrid(model: model)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .padding(30)
}
