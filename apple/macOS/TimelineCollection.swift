import AppKit
import XeniaCore
import SwiftUI

/// What the conversation asks of its timeline on the Mac: scroll to the newest message or to a row.
@MainActor
final class TimelineScroller {
    fileprivate weak var coordinator: TimelineCollection.Coordinator?

    func scrollToBottom(animated: Bool) {
        coordinator?.scrollToBottom(animated: animated)
    }

    func scroll(to rowID: String, anchor: TimelineCollection.Anchor, animated: Bool) {
        coordinator?.scroll(to: rowID, anchor: anchor, animated: animated)
    }
}

/// The conversation's rows on the Mac, in an AppKit scroll view that only draws what's on screen.
///
/// Each row is measured once at the window's width and remembered by its ID, so older messages
/// arriving above, or a row above the screen finding its real height, never move what's on
/// screen, and the newest message stays in view while it's being followed. Rows are SwiftUI views
/// in hosting controllers, reused as they scroll off. The conversation hears where it is (near the
/// top, near the bottom) only when that changes.
struct TimelineCollection: NSViewRepresentable {
    enum Anchor { case top, center, bottom }

    struct Edges: Equatable {
        var isNearTop = false
        var isNearBottom = true
    }

    let conversation: ConversationModel
    let context: ConversationContext
    let insets: EdgeInsets
    /// iPhone only: the Mac's Messages keeps bubbles still.
    var springs = false
    let scroller: TimelineScroller
    let onEdges: (Edges) -> Void

    @Environment(AppModel.self) private var model

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = TimelineScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.verticalScrollElasticity = .allowed
        let document = TimelineDocumentView()
        document.wantsLayer = true
        scrollView.documentView = document
        context.coordinator.attach(scrollView, document: document)
        scroller.coordinator = context.coordinator
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.model = model
        scroller.coordinator = coordinator
        coordinator.setInsets(NSEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0))
        coordinator.update()
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        fileprivate var parent: TimelineCollection?
        fileprivate var model: AppModel?
        private weak var scrollView: NSScrollView?
        private weak var document: TimelineDocumentView?

        private var ids: [String] = []
        private var rowsByID: [String: TimelineRow] = [:]
        /// The core's rows by ID and in order, as of `indexedRevision`.
        private var indexedRows: [String: TimelineRow] = [:]
        private var indexedIDs: [String] = []
        private var indexedRevision = -1
        private var heights: [String: CGFloat] = [:]
        private var tops: [CGFloat] = []
        private var indexByID: [String: Int] = [:]
        private var contentHeight: CGFloat = 0
        private var measuredWidth: CGFloat = 0
        private var insets = NSEdgeInsets()

        private var hosts: [String: NSHostingController<AnyView>] = [:]
        private var pool: [NSHostingController<AnyView>] = []
        /// Rows whose content changed since they were drawn, and since they were measured.
        private var stale: Set<String> = []
        private var remeasure: Set<String> = []

        /// How many times each row was drawn anew in place.
        private var redraws: [String: Int] = [:]
        private var shownTyping: [Reader] = []
        private var shownContext: ConversationContext?
        private var didInitialScroll = false
        private var edges = Edges()
        /// Following the newest message: true until the person scrolls away from it.
        private var isPinnedToBottom = true
        /// Moving the scroll view ourselves, which says nothing about what the person wants.
        private var isScrollingByCode = 0
        /// Gliding down to new messages: the glide, not each update, brings the bottom into view.
        private var isGlidingToBottom = false
        /// Which glide is the latest, so an earlier one ending doesn't end it.
        private var glide = 0
        /// Rows that just arrived at the end, faded in when they're first drawn.
        private var arriving: Set<String> = []
        private var isTiling = false
        private var lastClipSize = CGSize.zero

        private static let estimatedHeight: CGFloat = 52
        /// Rows drawn beyond each edge of the screen, so they're ready before they show.
        private static let overscan: CGFloat = 400
        /// Rows this near the screen are built and measured ahead, between frames, so scrolling
        /// reaches rows that are ready instead of building them on its frames.
        private static let aheadDistance: CGFloat = 900
        /// Rows this near the screen keep what they drew, so scrolling back doesn't build them
        /// again. Past what's built ahead, or rows at the edge would be built and dropped in turn.
        private static let keepDistance: CGFloat = aheadDistance + overscan + 400
        /// Extra room under the newest message, above the composer.
        private static let bottomGap: CGFloat = Theme.Spacing.s

        enum Item {
            static let loading = "xenia.loading"
            static let older = "xenia.older"
            static let start = "xenia.start"
            static let typing = "xenia.typing"
            static let all: Set<String> = [loading, older, start, typing]
        }

        func attach(_ scrollView: TimelineScrollView, document: TimelineDocumentView) {
            self.scrollView = scrollView
            self.document = document
            scrollView.onResize = { [weak self] in self?.tile() }
            scrollView.onReveal = { [weak self] offset, ended in self?.reveal(offset, ended: ended) }
            scrollView.onReplyBegin = { [weak self] point in self?.beginReply(at: point) ?? false }
            scrollView.onReply = { [weak self] offset, ended in self?.pullReply(offset, ended: ended) }
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView
            )
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: Content

        /// The conversation's context, with bubbles as wide as this timeline allows.
        private var rowContext: ConversationContext {
            var context = parent?.context ?? ConversationContext()
            context.bubbleMaxWidth = min((width) * Theme.Metrics.bubbleWidthFraction, Theme.Metrics.bubbleMaxWidth)
            return context
        }

        private func content(for id: String) -> AnyView {
            guard let parent, let model else { return AnyView(EmptyView()) }
            let view = Group {
                switch id {
                case Item.loading:
                    LoadingBubbles(isGroup: rowContext.isGroup)
                case Item.older:
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.m)
                case Item.start:
                    ConversationStart()
                case Item.typing:
                    TypingIndicator(people: shownTyping, isGroup: rowContext.isGroup)
                        .padding(.top, Theme.Spacing.s)
                default:
                    if let row = rowsByID[id] {
                        TimelineRowView(row: row)
                    }
                }
            }
            // A reused row starts fresh: no state carries over from the message it showed before.
            .id(RowIdentity(id: id, redraw: redraws[id] ?? 0))
            .frame(maxWidth: .infinity, alignment: .top)
            .environment(model)
            .environment(parent.conversation)
            .environment(\.conversationContext, rowContext)
            // Hosted rows don't inherit the window's environment: links in bubbles open in Xenia.
            .environment(\.openURL, OpenURLAction { [links = model.links] in links.handle($0) })
            return AnyView(view)
        }

        // MARK: Updates

        func update() {
            guard let parent else { return }
            let conversation = parent.conversation

            // The timeline is asked to update for many reasons (the room list, typing, the
            // composer); the rows are only walked when the core sent new ones.
            let rows = conversation.rows
            let rowsChanged = conversation.rowsRevision != indexedRevision
            if rowsChanged {
                indexedRevision = conversation.rowsRevision
                indexedRows = [:]
                indexedIDs = []
                indexedRows.reserveCapacity(rows.count)
                indexedIDs.reserveCapacity(rows.count)
                for row in rows {
                    if case .start = row { continue }
                    guard indexedRows.updateValue(row, forKey: row.id) == nil else { continue }
                    indexedIDs.append(row.id)
                }
            }

            var next: [String] = []
            var nextRows: [String: TimelineRow] = [:]
            if !conversation.isReady {
                next = [Item.loading]
            } else {
                if conversation.isLoadingOlder {
                    next.append(Item.older)
                } else if conversation.isAtStart && conversation.threadRoot == nil {
                    next.append(Item.start)
                }
                next += indexedIDs
                nextRows = indexedRows
                if !conversation.typing.isEmpty && conversation.isAtEnd {
                    next.append(Item.typing)
                }
            }

            var changed: Set<String> = []
            let context = rowContext
            let contextChanged = shownContext.map { !$0.sameLayout(as: context) } ?? false
            if rowsChanged || contextChanged || rowsByID.count != nextRows.count {
                for (id, row) in nextRows where rowsByID[id] != nil && (contextChanged || rowsByID[id] != row) {
                    changed.insert(id)
                }
            }
            if contextChanged { changed.formUnion(Item.all) }
            _ = conversation.layoutRevision
            // A row drawn differently without changing (its link's card arrived) is drawn anew,
            // so it's measured as it now draws.
            for id in conversation.takeRowsToLayOut() where nextRows[id] != nil {
                redraws[id, default: 0] += 1
                changed.insert(id)
            }
            if conversation.typing != shownTyping { changed.insert(Item.typing) }
            shownTyping = conversation.typing
            shownContext = context
            if contextChanged {
                stale.formUnion(hosts.keys)
                remeasure.formUnion(heights.keys)
            }
            guard next != ids || !changed.isEmpty else { return }

            let anchor = isPinnedToBottom ? nil : captureAnchor()
            let kept = ids.filter { $0 != Item.typing }
            let appendsOnly = didInitialScroll && !kept.isEmpty && next.starts(with: kept) && next.count > kept.count
            let glides = isPinnedToBottom && appendsOnly && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if glides {
                arriving.formUnion(next[kept.count...])
                // Set before the rows are laid out again, so nothing jumps to the new bottom first.
                isGlidingToBottom = true
            }
            let replacesLoading = ids == [Item.loading] && next != ids
            ids = next
            rowsByID = nextRows
            stale.formUnion(changed)
            // A change can alter a row's height: measure it again when it's drawn.
            remeasure.formUnion(changed)
            let keep = Set(next)
            heights = heights.filter { keep.contains($0.key) }
            redraws = redraws.filter { keep.contains($0.key) }
            rebuildTops()

            if !didInitialScroll {
                if conversation.isReady { initialScroll() } else { tile() }
                if replacesLoading { fadeIn() }
            } else if glides {
                // Measure the new rows where the screen is now, then glide to where they end.
                tile()
                scrollToBottom(animated: true)
            } else if isPinnedToBottom {
                scrollToBottom(animated: false)
            } else if let anchor {
                restore(anchor)
            } else {
                tile()
            }
            reportEdges()
        }

        func setInsets(_ newInsets: NSEdgeInsets) {
            guard let scrollView,
                  newInsets.top != insets.top || newInsets.bottom != insets.bottom else { return }
            let fromBottom = maxOffset - scrollView.contentView.bounds.minY
            insets = newInsets
            isScrollingByCode += 1
            scrollView.contentInsets = NSEdgeInsets(top: newInsets.top, left: 0, bottom: newInsets.bottom + Self.bottomGap, right: 0)
            scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: newInsets.bottom, right: 0)
            isScrollingByCode -= 1
            rebuildTops()
            setOffset(isPinnedToBottom ? maxOffset : maxOffset - fromBottom)
        }

        // MARK: Layout

        private var width: CGFloat {
            scrollView?.contentView.bounds.width ?? 0
        }

        private var visibleHeight: CGFloat {
            guard let scrollView else { return 0 }
            return scrollView.contentView.bounds.height - insets.top - insets.bottom - Self.bottomGap
        }

        private func rebuildTops() {
            tops.removeAll(keepingCapacity: true)
            indexByID.removeAll(keepingCapacity: true)
            var y: CGFloat = 0
            for (index, id) in ids.enumerated() {
                tops.append(y)
                indexByID[id] = index
                y += heights[id] ?? Self.estimatedHeight
            }
            // A short conversation sits at the bottom, by the composer.
            let visible = visibleHeight
            if y < visible {
                let shift = visible - y
                for index in tops.indices { tops[index] += shift }
                y = visible
            }
            contentHeight = y
            isScrollingByCode += 1
            document?.setFrameSize(NSSize(width: width, height: contentHeight))
            isScrollingByCode -= 1
            // Following the newest message, it stays in view as heights change; settling it here
            // also keeps AppKit from clamping the position later, which would read as a scroll.
            if isPinnedToBottom && !isGlidingToBottom { setOffset(maxOffset) }
        }

        private func frame(at index: Int) -> CGRect {
            CGRect(x: 0, y: tops[index], width: width, height: heights[ids[index]] ?? Self.estimatedHeight)
        }

        /// The first row whose bottom is below `y`.
        private func firstIndex(below y: CGFloat) -> Int {
            var low = 0
            var high = tops.count
            while low < high {
                let mid = (low + high) / 2
                if frame(at: mid).maxY <= y { low = mid + 1 } else { high = mid }
            }
            return low
        }

        /// Draws the rows on screen (and a little beyond), measuring any it hasn't seen. Rows
        /// above the screen that change height move the scroll position by as much, so nothing
        /// on screen moves.
        func tile() {
            guard !isTiling, let scrollView, width > 0 else { return }
            isTiling = true
            defer { isTiling = false }

            if width != measuredWidth {
                // A new width wraps text differently: measure again, keeping the screen in place.
                let anchor = isPinnedToBottom ? nil : captureAnchor()
                measuredWidth = width
                heights.removeAll()
                // Bubbles take their widest from the timeline's width: draw every row again.
                stale.formUnion(hosts.keys)
                shownContext = rowContext
                rebuildTops()
                if let anchor { restore(anchor) }
            }

            var visibleIDs: Set<String> = []
            for _ in 0..<4 {
                let bounds = scrollView.contentView.bounds
                let screenTop = bounds.minY + insets.top
                let range = bounds.insetBy(dx: 0, dy: -Self.overscan)
                var grewAbove: CGFloat = 0
                var changed = false
                visibleIDs = []
                var index = firstIndex(below: range.minY)
                while index < ids.count, tops[index] < range.maxY {
                    visibleIDs.insert(ids[index])
                    if let growth = draw(at: index, screenTop: screenTop) {
                        changed = true
                        grewAbove += growth
                    }
                    index += 1
                }
                guard changed else { break }
                settle(grewAbove: grewAbove, from: bounds)
            }

            // Rows a little way off keep what they drew, so scrolling back doesn't build them
            // again. The rows that animate (loading, typing) stop as soon as they leave.
            let kept = scrollView.contentView.bounds.insetBy(dx: 0, dy: -Self.keepDistance)
            for (id, host) in hosts where !visibleIDs.contains(id) {
                if !Item.all.contains(id), let index = indexByID[id], frame(at: index).intersects(kept) { continue }
                host.view.isHidden = true
                // Nothing keeps running off screen (the loading shimmer would, forever).
                host.rootView = AnyView(EmptyView())
                hosts[id] = nil
                pool.append(host)
            }
            placeHosts()
            for id in visibleIDs {
                guard let host = hosts[id], host.view.isHidden else { continue }
                host.view.isHidden = false
                if arriving.remove(id) != nil { arrive(host.view, as: arrival(of: id)) }
            }
            buildAhead()
        }

        /// Builds the row at `index` if it isn't, and measures it if it hasn't been or changed.
        /// Returns how much rows above the screen grew when its height changed, else nil.
        private func draw(at index: Int, screenTop: CGFloat) -> CGFloat? {
            let id = ids[index]
            let host = host(for: id)
            guard heights[id] == nil || remeasure.contains(id) else { return nil }
            remeasure.remove(id)
            let old = heights[id] ?? Self.estimatedHeight
            let measured = ceil(host.sizeThatFits(in: CGSize(width: width, height: 100_000)).height)
            heights[id] = measured
            guard abs(measured - old) > 0.5 else { return nil }
            return tops[index] + old <= screenTop ? measured - old : 0
        }

        /// After rows found their heights: what's on screen stays put, or the newest message stays in view.
        private func settle(grewAbove: CGFloat, from bounds: CGRect) {
            rebuildTops()
            if isGlidingToBottom {
                // The glide settles at the new bottom when it ends.
            } else if isPinnedToBottom {
                setOffset(maxOffset)
            } else if grewAbove != 0 {
                setOffset(bounds.minY + grewAbove)
            }
        }

        private func placeHosts() {
            for (id, host) in hosts {
                guard let index = indexByID[id] else { continue }
                var frame = frame(at: index)
                if id == replyRow { frame.origin.x = replyShift }
                if host.view.frame != frame { host.view.frame = frame }
            }
        }

        // MARK: Building ahead

        private var isBuildingAhead = false
        /// When the person last moved the conversation.
        private var lastScroll: CFTimeInterval = 0

        /// Builds and measures rows near the screen a little at a time, between frames: a sliver
        /// of each frame while the conversation moves, batches back to back once it's still.
        private func buildAhead() {
            guard !isBuildingAhead else { return }
            isBuildingAhead = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let moving = CACurrentMediaTime() - self.lastScroll < 0.1
                guard self.buildAhead(budget: moving ? 0.002 : 0.008) else {
                    self.isBuildingAhead = false
                    return
                }
                if moving {
                    // The next scroll asks again; if none comes, carry on once it's still.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.isBuildingAhead = false
                        self?.buildAhead()
                    }
                } else {
                    self.isBuildingAhead = false
                    self.buildAhead()
                }
            }
        }

        /// Returns whether rows near the screen are still waiting.
        private func buildAhead(budget: CFTimeInterval) -> Bool {
            guard !isTiling, let scrollView, width > 0, width == measuredWidth, !ids.isEmpty else { return false }
            let bounds = scrollView.contentView.bounds
            let screenTop = bounds.minY + insets.top
            let reach = Self.aheadDistance + Self.overscan
            let first = firstIndex(below: bounds.minY - reach)
            let middle = min(firstIndex(below: bounds.minY), ids.count)
            func waiting(_ index: Int) -> Bool {
                let id = ids[index]
                return !Item.all.contains(id) && (hosts[id] == nil || heights[id] == nil || remeasure.contains(id))
            }
            // Nearest first: walking up from the screen, then down from it.
            var order: [Int] = []
            var up = middle - 1
            var down = middle
            while order.count < 24, up >= first || (down < ids.count && tops[down] <= bounds.maxY + reach) {
                if up >= first {
                    if waiting(up) { order.append(up) }
                    up -= 1
                }
                if order.count < 24, down < ids.count, tops[down] <= bounds.maxY + reach {
                    if waiting(down) { order.append(down) }
                    down += 1
                }
            }
            guard !order.isEmpty else { return false }
            isTiling = true
            let start = CACurrentMediaTime()
            var grewAbove: CGFloat = 0
            var changed = false
            var done = 0
            for index in order {
                // At least one row each time, so a slow row can't stall building.
                if done > 0, CACurrentMediaTime() - start > budget { break }
                if let growth = draw(at: index, screenTop: screenTop) {
                    changed = true
                    grewAbove += growth
                }
                done += 1
            }
            if changed { settle(grewAbove: grewAbove, from: bounds) }
            placeHosts()
            isTiling = false
            return done < order.count || order.count == 24
        }

        private enum Arrival {
            /// Mine: rises out of the message field, as Messages sends.
            case sent
            /// Someone else's, or their typing: grows from its tail corner.
            case received
            /// A header or note: fades in.
            case plain
        }

        private func arrival(of id: String) -> Arrival {
            if id == Item.typing { return .received }
            guard case .message(let message) = rowsByID[id] else { return .plain }
            return message.isOwn ? .sent : .received
        }

        /// A new row arrives as the conversation glides up to it.
        private func arrive(_ view: NSView, as arrival: Arrival) {
            view.wantsLayer = true
            guard let layer = view.layer else { return }
            let bounds = layer.bounds
            // Layer coordinates follow the view's: down is +y in a flipped view.
            let down: CGFloat = view.isFlipped ? 1 : -1
            let bottom = view.isFlipped ? bounds.maxY : bounds.minY
            let start: CATransform3D
            switch arrival {
            case .sent:
                // From where the field is, a little smaller, to its place.
                let pivot = CGPoint(x: bounds.maxX, y: bottom)
                start = CATransform3DConcat(Self.scale(0.94, around: pivot), CATransform3DMakeTranslation(0, 46 * down, 0))
            case .received:
                start = Self.scale(0.82, around: CGPoint(x: bounds.minX + 40, y: bottom))
            case .plain:
                start = CATransform3DIdentity
            }
            let move = CASpringAnimation(keyPath: "transform")
            move.fromValue = NSValue(caTransform3D: start)
            move.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            move.damping = 22
            move.stiffness = 260
            move.mass = 1
            move.duration = min(move.settlingDuration, 0.45)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = arrival == .sent ? 0.12 : 0.22
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let group = CAAnimationGroup()
            group.animations = arrival == .plain ? [fade] : [move, fade]
            group.duration = arrival == .plain ? fade.duration : move.duration
            layer.add(group, forKey: "arrive")
        }

        private static func scale(_ factor: CGFloat, around point: CGPoint) -> CATransform3D {
            var transform = CATransform3DMakeTranslation(point.x, point.y, 0)
            transform = CATransform3DScale(transform, factor, factor, 1)
            return CATransform3DTranslate(transform, -point.x, -point.y, 0)
        }

        /// The first messages replace the loading shapes with a cross-fade, not a cut.
        private func fadeIn() {
            guard let document else { return }
            document.wantsLayer = true
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.22
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            document.layer?.add(fade, forKey: "replaceLoading")
        }

        private func host(for id: String) -> NSHostingController<AnyView> {
            if let host = hosts[id] {
                if stale.remove(id) != nil { host.rootView = content(for: id) }
                return host
            }
            stale.remove(id)
            let host: NSHostingController<AnyView>
            if let reused = pool.popLast() {
                host = reused
                host.rootView = content(for: id)
            } else {
                host = NSHostingController(rootView: content(for: id))
                host.sizingOptions = []
                host.safeAreaRegions = []
                host.view.isHidden = true
                document?.addSubview(host.view)
            }
            hosts[id] = host
            return host
        }

        // MARK: Times

        /// Slides every row left by `offset`, bringing in the times and read faces that wait past
        /// the trailing edge; ending springs them back, as on iPhone.
        func reveal(_ offset: CGFloat, ended: Bool) {
            guard let layer = document?.layer else { return }
            let limit = Theme.Metrics.revealWidth
            // Past the times, it resists like a rubber band.
            let shift = offset <= limit ? offset : limit + (offset - limit) * 0.15
            let target = ended ? CATransform3DIdentity : CATransform3DMakeTranslation(-shift, 0, 0)
            if ended, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let spring = CASpringAnimation(keyPath: "sublayerTransform")
                spring.fromValue = NSValue(caTransform3D: layer.presentation()?.sublayerTransform ?? layer.sublayerTransform)
                spring.toValue = NSValue(caTransform3D: target)
                spring.damping = 26
                spring.stiffness = 300
                spring.duration = min(spring.settlingDuration, 0.45)
                layer.add(spring, forKey: "reveal")
            } else {
                layer.removeAnimation(forKey: "reveal")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayerTransform = target
            CATransaction.commit()
        }

        // MARK: Swipe to reply

        /// The message being swiped right, and how far it has moved.
        private var replyRow: String?
        private var replyShift: CGFloat = 0
        private var replyArmed = false
        private lazy var replyMark = ReplyMarkView()

        private static let replyThreshold: CGFloat = 64

        func beginReply(at windowPoint: NSPoint) -> Bool {
            guard let document, replyRow == nil else { return false }
            let point = document.convert(windowPoint, from: nil)
            let index = firstIndex(below: point.y)
            guard index < ids.count, tops[index] <= point.y, let host = hosts[ids[index]],
                  case .message(let message) = rowsByID[ids[index]], message.canReply
            else { return false }
            replyRow = ids[index]
            replyShift = 0
            replyArmed = false
            let row = frame(at: index)
            let size = ReplyMarkView.size
            replyMark.frame = CGRect(x: Theme.Spacing.m, y: row.midY - size / 2, width: size, height: size)
            replyMark.alphaValue = 0
            replyMark.isArmed = false
            // Under the row, so the message slides off it.
            document.addSubview(replyMark, positioned: .below, relativeTo: host.view)
            return true
        }

        func pullReply(_ offset: CGFloat, ended: Bool) {
            guard let id = replyRow, let host = hosts[id], let index = indexByID[id] else {
                replyRow = nil
                return
            }
            let threshold = Self.replyThreshold
            if ended {
                let replies = replyArmed
                replyRow = nil
                replyShift = 0
                replyArmed = false
                let rest = frame(at: index)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : 0.32
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                    host.view.animator().frame = rest
                    replyMark.animator().alphaValue = 0
                }
                if replies, case .message(let message) = rowsByID[id] {
                    parent?.conversation.reply(to: message)
                }
                return
            }
            // Past the threshold it resists like a rubber band.
            replyShift = offset < threshold ? offset : threshold + (offset - threshold) * 0.25
            var frame = frame(at: index)
            frame.origin.x = replyShift
            host.view.frame = frame
            replyMark.alphaValue = min(replyShift / threshold, 1)
            let armed = replyShift >= threshold
            if armed != replyArmed {
                replyArmed = armed
                replyMark.isArmed = armed
                // The trackpad clicks as it arms, as the iPhone taps.
                if armed { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            }
        }

        // MARK: Positions

        private var minOffset: CGFloat { -insets.top }

        private var maxOffset: CGFloat {
            guard let scrollView else { return 0 }
            let clip = scrollView.contentView.bounds.height
            return max(minOffset, contentHeight + insets.bottom + Self.bottomGap - clip)
        }

        private func setOffset(_ y: CGFloat) {
            guard let scrollView else { return }
            let clamped = max(minOffset, min(maxOffset, y))
            guard abs(clamped - scrollView.contentView.bounds.minY) > 0.25 else { return }
            isScrollingByCode += 1
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: clamped))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isScrollingByCode -= 1
        }

        private struct ScreenAnchor {
            let id: String
            let screenY: CGFloat
        }

        private func captureAnchor() -> ScreenAnchor? {
            guard let scrollView, !tops.isEmpty else { return nil }
            let offset = scrollView.contentView.bounds.minY
            var index = firstIndex(below: offset + insets.top + 1)
            while index < ids.count {
                if !Item.all.contains(ids[index]) {
                    return ScreenAnchor(id: ids[index], screenY: tops[index] - offset)
                }
                index += 1
            }
            return nil
        }

        private func restore(_ anchor: ScreenAnchor) {
            guard let index = indexByID[anchor.id] else { return }
            setOffset(tops[index] - anchor.screenY)
            tile()
        }

        func scrollToBottom(animated: Bool) {
            guard let scrollView else { return }
            isPinnedToBottom = true
            guard animated else {
                setOffset(maxOffset)
                tile()
                return
            }
            isScrollingByCode += 1
            isGlidingToBottom = true
            glide += 1
            let current = glide
            let target = maxOffset
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                context.allowsImplicitAnimation = true
                scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isScrollingByCode -= 1
                    // A newer glide is under way: it settles the bottom when it ends.
                    guard current == self.glide else { return }
                    self.isGlidingToBottom = false
                    self.arriving.formIntersection(self.ids)
                    // Rows measured on the way down may have moved the bottom; a person who
                    // scrolled away meanwhile is left where they are.
                    if abs(scrollView.contentView.bounds.minY - target) < 2 {
                        self.setOffset(self.maxOffset)
                    } else {
                        self.isPinnedToBottom = scrollView.contentView.bounds.minY >= self.maxOffset - 2
                    }
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                    self.tile()
                    self.reportEdges()
                }
            }
        }

        func scroll(to rowID: String, anchor: Anchor, animated: Bool) {
            guard indexByID[rowID] != nil else { return }
            isPinnedToBottom = false
            func target() -> CGFloat? {
                guard let index = indexByID[rowID] else { return nil }
                let frame = frame(at: index)
                return switch anchor {
                case .top: frame.minY - insets.top
                case .center: frame.midY - insets.top - visibleHeight / 2
                case .bottom: frame.maxY - insets.top - visibleHeight
                }
            }
            // Twice: the rows around the target measure themselves once they're drawn.
            for _ in 0..<2 {
                guard let y = target() else { return }
                setOffset(y)
                tile()
            }
            if anchor == .bottom { isPinnedToBottom = true }
            reportEdges()
        }

        private func initialScroll() {
            guard let parent else { return }
            didInitialScroll = true
            let conversation = parent.conversation
            if let focused = conversation.focusedRowID {
                scroll(to: focused, anchor: .center, animated: false)
            } else if let marker = conversation.rows.first(where: { if case .readMarker = $0 { true } else { false } }) {
                scroll(to: marker.id, anchor: .top, animated: false)
            } else {
                scrollToBottom(animated: false)
            }
        }

        // MARK: Scrolling

        @objc private func boundsChanged() {
            guard let scrollView else { return }
            let size = scrollView.contentView.bounds.size
            if size != lastClipSize {
                // The window resized: a conversation being followed stays at its newest message.
                lastClipSize = size
                rebuildTops()
                if isPinnedToBottom { setOffset(maxOffset) }
            } else if isScrollingByCode == 0 {
                // Not code moving it, so the person: wheel, trackpad, scroller or keyboard.
                isPinnedToBottom = scrollView.contentView.bounds.minY >= maxOffset - 2
                lastScroll = CACurrentMediaTime()
            }
            tile()
            reportEdges()
        }

        private func reportEdges() {
            guard let scrollView, didInitialScroll else { return }
            let bounds = scrollView.contentView.bounds
            let next = Edges(
                // Within three screens of the top: the next page is fetched before it's reached.
                isNearTop: bounds.minY + insets.top < bounds.height * 3,
                isNearBottom: bounds.minY >= maxOffset - 120
            )
            // Near the top, the next page is asked for on every scroll and every update, so
            // loading never stalls; the conversation sends one request at a time and none while
            // one is out or the beginning is loaded.
            if next.isNearTop { parent?.conversation.loadOlder() }
            guard next != edges else { return }
            edges = next
            // After this update, not during it: the conversation's state changes in response.
            DispatchQueue.main.async { [weak self] in self?.parent?.onEdges(next) }
        }
    }
}

/// Tells the timeline when its size changes, to draw the rows for the new size, and turns
/// sideways two-finger swipes into gestures: to the left reveals the times, to the right on a
/// message replies to it, as on iPhone.
final class TimelineScrollView: NSScrollView {
    var onResize: () -> Void = {}
    /// How far the fingers have pulled the rows left, and whether they've let go.
    var onReveal: (CGFloat, Bool) -> Void = { _, _ in }
    /// A swipe right begins over a point in the window: true if a message there can be replied to.
    var onReplyBegin: (NSPoint) -> Bool = { _ in false }
    /// How far the fingers have pulled that message right, and whether they've let go.
    var onReply: (CGFloat, Bool) -> Void = { _, _ in }

    private var laidOutSize = NSSize.zero

    private enum Swipe { case undecided, revealing, replying, scrolling }
    private var swipe = Swipe.scrolling
    private var pulled: CGFloat = 0
    /// The fling after a sideways swipe mustn't scroll the conversation.
    private var swallowsMomentum = false

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began {
            swipe = .undecided
            pulled = 0
            swallowsMomentum = false
        }
        if !event.momentumPhase.isEmpty {
            if !swallowsMomentum { super.scrollWheel(with: event) }
            return
        }
        // Only a trackpad gesture swipes; a mouse wheel always scrolls.
        guard event.hasPreciseScrollingDeltas, !event.phase.isEmpty, event.phase != .mayBegin else {
            super.scrollWheel(with: event)
            return
        }
        // The fingers' own direction, whatever the scrolling direction setting.
        let fingers = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        if swipe == .undecided {
            let dx = abs(event.scrollingDeltaX)
            let dy = abs(event.scrollingDeltaY)
            if dx > 0 || dy > 0 {
                if dx <= dy * 1.4 {
                    swipe = .scrolling
                } else if fingers < 0 {
                    swipe = .revealing
                } else {
                    swipe = onReplyBegin(event.locationInWindow) ? .replying : .scrolling
                }
            }
        }
        guard swipe == .revealing || swipe == .replying else {
            super.scrollWheel(with: event)
            return
        }
        swallowsMomentum = true
        let ended = event.phase == .ended || event.phase == .cancelled
        if swipe == .revealing {
            pulled = max(0, pulled - fingers)
            onReveal(pulled, ended)
        } else {
            pulled = max(0, pulled + fingers)
            onReply(pulled, ended)
        }
        if ended { swipe = .scrolling }
    }

    override func layout() {
        super.layout()
        guard frame.size != laidOutSize else { return }
        laidOutSize = frame.size
        onResize()
    }
}

/// The reply arrow a message uncovers as it's swiped right, filling with the accent once
/// letting go would reply.
private final class ReplyMarkView: NSView {
    static let size: CGFloat = 30

    private let symbol = NSImageView()

    var isArmed = false {
        didSet {
            guard isArmed != oldValue else { return }
            symbol.contentTintColor = isArmed ? .controlAccentColor : .secondaryLabelColor
            if isArmed { symbol.addSymbolEffect(.bounce) }
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        symbol.image = NSImage(systemSymbolName: "arrowshape.turn.up.left.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        symbol.contentTintColor = .secondaryLabelColor
        symbol.translatesAutoresizingMaskIntoConstraints = false
        addSubview(symbol)
        NSLayoutConstraint.activate([
            symbol.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = Self.size / 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct RowIdentity: Hashable {
    let id: String
    let redraw: Int
}

/// Rows stack from the top, as in a list.
final class TimelineDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private extension ConversationContext {
    /// Whether rows would draw the same in either context. The closures are the same actions.
    func sameLayout(as other: ConversationContext) -> Bool {
        isGroup == other.isGroup && isThread == other.isThread && bubbleMaxWidth == other.bubbleMaxWidth
    }
}

/// The soft scroll edge, for the AppKit timeline: content behind it blurs, most at the edge
/// and easing off toward the conversation, as Liquid Glass bars' scroll edges do.
struct SoftScrollEdge: NSViewRepresentable {
    let edge: VerticalEdge

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = EdgeBlurView()
        view.material = .headerView
        view.blendingMode = .withinWindow
        view.state = .active
        view.edge = edge
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    private final class EdgeBlurView: NSVisualEffectView {
        var edge: VerticalEdge = .top
        private var maskedSize = CGSize.zero

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            // Drawn again only when the size changes: layout runs on every scroll of the timeline.
            guard bounds.height > 0, bounds.size != maskedSize else { return }
            maskedSize = bounds.size
            // Opaque at the edge, clear where the conversation is.
            let size = bounds.size
            maskImage = NSImage(size: size, flipped: false) { [edge] rect in
                let gradient = NSGradient(colorsAndLocations:
                    (.black.withAlphaComponent(0.82), 0), (.black.withAlphaComponent(0.66), 0.4), (.black.withAlphaComponent(0.25), 0.75), (.clear, 1))
                gradient?.draw(in: rect, angle: edge == .top ? -90 : 90)
                return true
            }
        }
    }
}
