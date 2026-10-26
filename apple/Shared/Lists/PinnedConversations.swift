import XeniaCore
import SwiftUI

/// Pinned conversations (Matrix favorites) above the list, as Messages pins them: big photos in rows of
/// three, the name under each, and a dot when something's new. The list below leaves them out.
struct PinnedConversations: View {
    let rooms: [RoomSummary]
    /// Asks before leaving (the list owns the confirmation dialog).
    let confirmLeave: (RoomSummary) -> Void

    @Environment(AppModel.self) private var model
    #if os(macOS)
    @State private var table = EnclosingTable()
    #endif
    /// The pins' order while one is dragged, and until the server has the new one.
    @State private var arranged: [String]?
    @State private var dragging: String?

    /// Messages shows nine at most; more favorites stay in the list.
    static let limit = 9

    /// The favorites to pin, in the order they were arranged, never invitations.
    static func pins(from rooms: [RoomSummary]) -> [RoomSummary] {
        Array(PinOrder.sorted(rooms.filter { $0.isFavourite && !$0.isInvite }).prefix(limit))
    }

    /// The pins in the order they're drawn: as arranged by a drag, any new ones after.
    private var shown: [RoomSummary] {
        guard let arranged else { return rooms }
        let byID = Dictionary(rooms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return arranged.compactMap { byID[$0] } + rooms.filter { !arranged.contains($0.id) }
    }

    var body: some View {
        // One grid of pins, not rows of them: a pin keeps its identity as others come and go,
        // so it slides to its new place instead of fading out and back in. Short rows keep
        // their pins in columns, as Messages' do.
        LazyVGrid(columns: Self.columns, spacing: Self.rowSpacing) {
            ForEach(shown) { room in
                Pin(room: room, isSelected: isSelected(room)) { open(room) }
                    #if os(macOS)
                    // Lifted while the pointer carries it from place to place.
                    .scaleEffect(dragging == room.id ? 1.08 : 1)
                    .shadow(color: .black.opacity(dragging == room.id ? 0.2 : 0), radius: 8, y: 3)
                    .zIndex(dragging == room.id ? 1 : 0)
                    #else
                    // Its copy follows the finger; its place shows where it will land.
                    .opacity(dragging == room.id ? 0.35 : 1)
                    #endif
                    // Each pin takes drags itself: the list's rows only take drops whole.
                    .overlay {
                        #if os(macOS)
                        // Its own clicks and menu too: the list's would ring the whole row of pins.
                        PinMenuAnchor(
                            menu: RoomContextMenu(room: room, confirmLeave: confirmLeave).environment(model),
                            dragID: room.id,
                            open: { open(room) },
                            drag: dragEvents(room.id)
                        )
                        #else
                        // Its own taps, long press and drag, as Messages' pins: in a list row,
                        // SwiftUI would give every long press to the row's first menu and lift
                        // the whole row of pins with it.
                        PinTouchAnchor(
                            dragID: room.id,
                            open: { open(room) },
                            menu: { PinMenu.make(for: room, actions: RoomActions(model: model), confirmLeave: confirmLeave) },
                            drag: dragEvents(room.id)
                        )
                        #endif
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Theme.Motion.row, value: shown.map(\.id))
        .onChange(of: rooms.map(\.id)) { _, ids in
            // The server has caught up: its order takes over again.
            if dragging == nil, arranged == ids { arranged = nil }
        }
        #if os(macOS)
        .background(EnclosingTableReader(table: table))
        #endif
    }

    /// What a drag over the pin `id` does to the pins.
    private func dragEvents(_ id: String) -> PinDragEvents {
        PinDragEvents(
            begin: { beginDrag(id) },
            enter: {
                withAnimation(Theme.Motion.row) { drag(over: id) }
            },
            end: { dropped in withAnimation(Theme.Motion.row) { endDrag(dropped: dropped) } }
        )
    }

    private func beginDrag(_ id: String) {
        guard dragging == nil, rooms.contains(where: { $0.id == id }) else { return }
        dragging = id
        arranged = shown.map(\.id)
    }

    /// Moves the dragged pin to the place of `target`.
    private func drag(over target: String) {
        guard let dragging, target != dragging, var ids = arranged,
              let from = ids.firstIndex(of: dragging), let to = ids.firstIndex(of: target)
        else { return }
        ids.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
        arranged = ids
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    /// Saves the new order when the pin was let go on the pins; anywhere else, they go back.
    private func endDrag(dropped: Bool) {
        guard dragging != nil else { return }
        dragging = nil
        guard let ids = arranged else { return }
        guard dropped, ids != rooms.map(\.id) else {
            arranged = nil
            return
        }
        RoomActions(model: model).arrangePins(ids, pins: rooms) { arranged = nil }
    }

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.s, alignment: .top), count: 3)

    #if os(macOS)
    private static let rowSpacing: CGFloat = Theme.Spacing.m
    #else
    private static let rowSpacing: CGFloat = Theme.Spacing.l
    #endif

    private func isSelected(_ room: RoomSummary) -> Bool {
        #if os(macOS)
        model.navigation.selectedRoomID == room.id
        #else
        false
        #endif
    }

    private func open(_ room: RoomSummary) {
        model.navigation.open(roomID: room.id, scope: room.scope)
        #if os(macOS)
        // Opening from the keyboard can still select the pins' row, highlighting every pin; the
        // open pin shows its own ring instead. After the list has done its part.
        DispatchQueue.main.async { table.deselectAll() }
        #endif
    }
}

/// A pin being dragged: it starts, passes over a pin, and ends, let go on a pin or not.
struct PinDragEvents {
    var begin: () -> Void
    var enter: () -> Void
    var end: (_ dropped: Bool) -> Void
}

#if os(iOS)
/// Over each pin on iPhone: opens it on a tap, lifts it from its own place for its menu, and
/// carries it to another pin's place, as Messages does.
private struct PinTouchAnchor: UIViewRepresentable {
    let dragID: String
    let open: () -> Void
    let menu: () -> UIMenu
    let drag: PinDragEvents

    func makeUIView(context: Context) -> PinTouchView { PinTouchView() }

    func updateUIView(_ view: PinTouchView, context: Context) {
        view.dragID = dragID
        view.open = open
        view.menu = menu
        view.drag = drag
    }
}

final class PinTouchView: UIView, UIContextMenuInteractionDelegate, UIDragInteractionDelegate, UIDropInteractionDelegate {
    var dragID = ""
    var open: (() -> Void)?
    var menu: (() -> UIMenu)?
    var drag: PinDragEvents?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addInteraction(UIContextMenuInteraction(delegate: self))
        let dragging = UIDragInteraction(delegate: self)
        dragging.isEnabled = true // Off by default on iPhone.
        addInteraction(dragging)
        addInteraction(UIDropInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func tapped() { open?() }

    /// The pin as drawn here, lifted from its own place.
    private func lifted() -> UITargetedPreview? {
        guard let window, let snapshot = window.resizableSnapshotView(
            from: convert(bounds, to: window), afterScreenUpdates: false, withCapInsets: .zero
        ) else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: bounds, cornerRadius: 18)
        return UITargetedPreview(view: snapshot, parameters: parameters, target: UIPreviewTarget(container: self, center: CGPoint(x: bounds.midX, y: bounds.midY)))
    }

    // MARK: Menu

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu() }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration, highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        lifted()
    }

    // MARK: Drag

    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
        let item = UIDragItem(itemProvider: NSItemProvider(object: dragID as NSString))
        item.localObject = dragID
        return [item]
    }

    func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: any UIDragSession) -> UITargetedDragPreview? {
        guard let preview = lifted() else { return nil }
        return UITargetedDragPreview(view: preview.view, parameters: preview.parameters, target: preview.target)
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: any UIDragSession) {
        drag?.begin()
    }

    /// Let go on a pin, the new order is saved; anywhere else, the pins go back.
    func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession, didEndWith operation: UIDropOperation) {
        drag?.end(operation == .move)
    }

    // MARK: Drop

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        session.localDragSession?.items.first?.localObject is String
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: any UIDropSession) {
        drag?.enter()
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .move)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {}
}

/// A pin's menu on iPhone, made in UIKit to lift the pin from its own place. The same items as
/// `RoomContextMenu`, which pins never show as an invitation.
enum PinMenu {
    static func make(for room: RoomSummary, actions: RoomActions, confirmLeave: @escaping (RoomSummary) -> Void) -> UIMenu {
        let read = room.isUnread
            ? UIAction(title: String(localized: "Mark as Read"), image: UIImage(systemName: "checkmark.message")) { _ in actions.toggleRead(room) }
            : UIAction(title: String(localized: "Mark as Unread"), image: UIImage(systemName: "message.badge")) { _ in actions.toggleRead(room) }
        let pin = room.isFavourite
            ? UIAction(title: String(localized: "Unpin"), image: UIImage(systemName: "pin.slash")) { _ in actions.toggleFavourite(room) }
            : UIAction(title: String(localized: "Pin"), image: UIImage(systemName: "pin")) { _ in actions.toggleFavourite(room) }
        let current = actions.notificationMode(room)
        func mode(_ mode: NotificationMode, _ title: String, _ image: String) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: image), state: mode == current ? .on : .off) { _ in actions.setMode(room, mode) }
        }
        let notifications = UIMenu(
            title: String(localized: "Notifications"),
            image: UIImage(systemName: room.isMuted ? "bell.slash" : "bell"),
            children: [
                mode(.allMessages, String(localized: "All Messages"), "bell"),
                mode(.mentionsOnly, String(localized: "Mentions Only"), "at"),
                mode(.mute, String(localized: "Mute"), "bell.slash"),
            ]
        )
        let leave = UIAction(
            title: room.isDm ? String(localized: "Delete Chat…") : String(localized: "Leave…"),
            image: UIImage(systemName: "rectangle.portrait.and.arrow.right"),
            attributes: .destructive
        ) { _ in confirmLeave(room) }
        return UIMenu(children: [read, pin, notifications, UIMenu(options: .displayInline, children: [leave])])
    }
}
#endif

private struct Pin: View {
    let room: RoomSummary
    let isSelected: Bool
    let action: () -> Void

    #if os(macOS)
    private nonisolated static let avatar: CGFloat = 66
    #else
    private nonisolated static let avatar: CGFloat = 76
    #endif

    #if os(macOS)
    private static let nameFont = Font.body
    #else
    private static let nameFont = Font.caption
    #endif

    /// Wide enough to read a few words, narrow enough to stay over its own pin.
    #if os(macOS)
    private static let bubbleWidth = avatar + 32
    #else
    private static let bubbleWidth = avatar + 44
    #endif
    /// How far the bubble comes down over the photo: its top part, clear of the face.
    private nonisolated static let bubbleOverlap = avatar * 0.38

    /// The newest message, while it's unread and someone else's.
    private var latest: String? {
        guard room.isUnread, case .message(let sender, let body, _, let isOwn) = room.preview, !isOwn else { return nil }
        return Copy.messageText(sender, body: body, roomName: room.name)
    }

    private var accessibilityLabel: String {
        guard room.isUnread else { return room.name }
        if let latest { return String(localized: "\(room.name), Unread, \(latest)") }
        return String(localized: "\(room.name), Unread")
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.Spacing.xs + 2) {
                AvatarView(name: room.name, seed: room.avatarSeed, url: room.avatarUrl, size: Self.avatar, isRoom: room.isRoom)
                    .padding(3)
                    .overlay {
                        // Selected on the Mac: ringed in the accent, as Messages rings a pin.
                        AvatarShape(isRoom: room.isRoom)
                            .strokeInside(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2.5)
                    }
                    .overlay(alignment: .top) {
                        // The newest message, floating over the photo until it's read, as
                        // Messages does for pins.
                        if let latest {
                            LatestBubble(text: latest, width: Self.bubbleWidth)
                                .alignmentGuide(.top) { $0[.bottom] - Self.bubbleOverlap }
                                .transition(.scale(scale: 0.5, anchor: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(Theme.Motion.row, value: latest)
                // The dot sits before the name, as on Messages' pins.
                HStack(spacing: Theme.Spacing.xs) {
                    if room.unreadKind != .none {
                        PinUnreadMark(kind: room.unreadKind)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                    Text(room.name)
                        .font(Self.nameFont.weight(room.isUnread ? .semibold : .regular))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .animation(Theme.Motion.flip, value: room.unreadKind)
                .padding(.horizontal, Theme.Spacing.xxs)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        // Still, as Messages' pins: no hover and no press animation.
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(Text("Pinned. Opens the conversation."))
    }
}

/// The newest message over a pin: one line in a gray bubble, the width of the words up to
/// `width`, centered over the photo.
private struct LatestBubble: View {
    let text: String
    let width: CGFloat

    var body: some View {
        Text(text)
            .font(Self.font)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.incomingBubble, in: .rect(cornerRadius: 13, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            .frame(width: width)
            .accessibilityHidden(true)
    }

    #if os(macOS)
    private static let font = Font.caption
    #else
    private static let font = Font.footnote
    #endif
}

/// The unread dot before a pin's name, or the mention mark.
private struct PinUnreadMark: View {
    let kind: UnreadKind

    var body: some View {
        switch kind {
        case .mention:
            Image(systemName: "at")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 13, height: 13)
                .background(.orange, in: .circle)
        default:
            Circle()
                .fill(.tint)
                .frame(width: 8, height: 8)
        }
    }
}

#if os(macOS)
/// A pin's clicks, drags and right-click menu, answered here instead of by the list: the list
/// would select the whole row of pins on mouse down, tinting them, and outline every pin while
/// the menu is open. Messages' pins stay still when pressed.
private struct PinMenuAnchor<Menu: View>: NSViewRepresentable {
    let menu: Menu
    let dragID: String
    let open: () -> Void
    let drag: PinDragEvents

    func makeNSView(context: Context) -> PinMenuView {
        PinMenuView()
    }

    func updateNSView(_ view: PinMenuView, context: Context) {
        view.makeMenu = { [menu] in NSHostingMenu(rootView: menu) }
        view.open = open
        view.dragID = dragID
        view.drag = drag
    }
}

final class PinMenuView: NSView {
    var makeMenu: (() -> NSMenu)?
    var open: (() -> Void)?
    var dragID = ""
    var drag: PinDragEvents?
    private var pressedAt: NSPoint?
    private var isDragging = false
    /// The pin under the pointer while dragging.
    private weak var over: PinMenuView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, frame.contains(point) else { return nil }
        let isClick = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp].contains(event.type)
        return isClick ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        popUp(event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            popUp(event)
        } else {
            pressedAt = event.locationInWindow
        }
    }

    /// Past a few points, the press drags the pin, as in Messages: it takes the place of each
    /// pin it passes over. The pins stay in the list, so no system drag is needed.
    override func mouseDragged(with event: NSEvent) {
        guard let start = pressedAt else { return }
        if !isDragging {
            guard hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
            isDragging = true
            over = self
            drag?.begin()
            NSCursor.closedHand.push()
        }
        if let pin = pin(at: event.locationInWindow), pin !== over {
            over = pin
            pin.drag?.enter()
        }
    }

    /// Opens on release over the pin, as a button does; after a drag, the new order is saved.
    override func mouseUp(with event: NSEvent) {
        defer { pressedAt = nil; over = nil }
        if isDragging {
            isDragging = false
            NSCursor.pop()
            drag?.end(true)
            return
        }
        guard pressedAt != nil, !event.modifierFlags.contains(.control),
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        open?()
    }

    /// The pin at a point in the window. Hit testing answers for pins during a drag (see above).
    private func pin(at point: NSPoint) -> PinMenuView? {
        guard let content = window?.contentView, let frame = content.superview else { return nil }
        return frame.hitTest(frame.convert(point, from: nil)) as? PinMenuView
    }

    private func popUp(_ event: NSEvent) {
        guard let menu = makeMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// The list's table, found from inside one of its rows.
final class EnclosingTable {
    weak var marker: NSView?

    func deselectAll() {
        var view = marker?.superview
        while let current = view, !(current is NSTableView) { view = current.superview }
        (view as? NSTableView)?.deselectAll(nil)
    }
}

private struct EnclosingTableReader: NSViewRepresentable {
    let table: EnclosingTable

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        table.marker = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        table.marker = view
    }
}
#endif

private extension Shape {
    /// A border drawn inside the shape's frame.
    func strokeInside(_ style: AnyShapeStyle, lineWidth: CGFloat) -> some View {
        stroke(style, lineWidth: lineWidth).padding(lineWidth / 2)
    }
}
