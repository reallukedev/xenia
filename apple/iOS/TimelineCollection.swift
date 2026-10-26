import XeniaCore
import SwiftUI
import UIKit

/// What the conversation asks of its timeline on iPhone: scroll to the newest message or to a row.
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

/// The conversation's rows on iPhone, in a collection view, as Messages draws them: the screen
/// stays still while older messages arrive above, rows trail the scroll and spring back, new
/// messages rise into place, and dragging down tucks the keyboard away.
///
/// Rows are SwiftUI views in cells, measured by the layout. The conversation tells the timeline where it is
/// (near the top, near the bottom) only when that changes, never per frame.
struct TimelineCollection: UIViewControllerRepresentable {
    enum Anchor { case top, center, bottom }

    struct Edges: Equatable {
        var isNearTop = false
        var isNearBottom = true
    }

    let conversation: ConversationModel
    let context: ConversationContext
    let insets: EdgeInsets
    let springs: Bool
    let scroller: TimelineScroller
    let onEdges: (Edges) -> Void

    @Environment(AppModel.self) private var model

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> TimelineViewController {
        let coordinator = context.coordinator
        let layout = TimelineLayout()
        layout.isPinnedToBottom = { [weak coordinator] in coordinator?.isPinnedToBottom ?? true }
        layout.measure = { [weak coordinator] id, width in coordinator?.measure(id, width: width) }
        let collectionView = TimelineCollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        collectionView.showsHorizontalScrollIndicator = false
        // The layout measures rows itself.
        collectionView.selfSizingInvalidation = .disabled
        // Messages soften as they pass under the bar and the composer.
        collectionView.topEdgeEffect.style = .soft
        collectionView.bottomEdgeEffect.style = .soft
        collectionView.bottomEdgeEffect.isHidden = false
        collectionView.delegate = coordinator
        coordinator.attach(collectionView, layout: layout)
        scroller.coordinator = coordinator
        let controller = TimelineViewController(collectionView: collectionView)
        coordinator.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: TimelineViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.model = model
        scroller.coordinator = coordinator
        coordinator.layout?.springsEnabled = springs
        let insets = UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
        if insets != coordinator.insets {
            context.animate {
                coordinator.setInsets(insets)
            }
        }
        coordinator.update()
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate, UIGestureRecognizerDelegate {
        fileprivate var parent: TimelineCollection?
        fileprivate var model: AppModel?
        fileprivate private(set) var layout: TimelineLayout?
        fileprivate private(set) var insets: UIEdgeInsets = .zero
        private weak var collectionView: UICollectionView?
        /// Rows' hosting controllers are its children, so what they present has a home.
        fileprivate weak var controller: UIViewController?
        private var dataSource: UICollectionViewDiffableDataSource<Int, String>?

        private var rowsByID: [String: TimelineRow] = [:]
        /// The core's rows by ID and in order, as of `indexedRevision`.
        private var indexedRows: [String: TimelineRow] = [:]
        private var indexedIDs: [String] = []
        private var indexedRevision = -1
        private var shownIDs: [String] = []
        private var shownTyping: [Reader] = []
        private var shownContext: ConversationContext?
        private var didInitialScroll = false
        private var edges = Edges()
        /// Following the newest message: true until the person scrolls away from it.
        fileprivate private(set) var isPinnedToBottom = true

        /// Extra room under the newest message, above the composer.
        private static let bottomGap: CGFloat = Theme.Spacing.s

        enum Item {
            static let loading = "xenia.loading"
            static let older = "xenia.older"
            static let start = "xenia.start"
            static let typing = "xenia.typing"
            static let all: Set<String> = [loading, older, start, typing]
        }

        func attach(_ collectionView: TimelineCollectionView, layout: TimelineLayout) {
            self.collectionView = collectionView
            self.layout = layout
            collectionView.onWidthChange = { [weak self] in self?.widthChanged() }
            collectionView.onTextChange = { [weak self] in self?.textChanged() }
            let reveal = UIPanGestureRecognizer(target: self, action: #selector(revealTimes(_:)))
            reveal.delegate = self
            collectionView.addGestureRecognizer(reveal)
            revealPan = reveal
            let registration = UICollectionView.CellRegistration<TimelineCell, String> { [weak self] cell, _, id in
                guard let self else { return }
                cell.itemID = id
                cell.show(AnyView(self.content(for: id).id(id)), in: self.controller)
            }
            dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
                collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
            }
        }

        // MARK: Content

        /// Measures rows on their own, never through a cell (a reused cell can report the height
        /// of the row it showed before). One hidden controller, in the timeline for its traits
        /// (text size, bold text); each row gets a fresh identity, so no state carries over.
        private lazy var sizer: UIHostingController<AnyView> = {
            let sizer = UIHostingController(rootView: AnyView(EmptyView()))
            sizer.sizingOptions = []
            sizer.safeAreaRegions = []
            sizer.view.isHidden = true
            collectionView?.addSubview(sizer.view)
            return sizer
        }()

        private func sizeRow(_ id: String, width: CGFloat) -> CGFloat {
            sizer.rootView = AnyView(content(for: id).id(id))
            let height = ceil(sizer.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            // Nothing stays running in the hidden sizer (the typing dots, the loading pulse).
            sizer.rootView = AnyView(EmptyView())
            return height
        }

        /// Heights by row at `measuredWidth`, until the row changes.
        private var measured: [String: CGFloat] = [:]
        private var measuredWidth: CGFloat = 0

        func measure(_ id: String, width: CGFloat) -> CGFloat? {
            guard width > 0 else { return nil }
            if width != measuredWidth {
                measured.removeAll()
                measuredWidth = width
            }
            if let height = measured[id] { return height }
            let height = sizeRow(id, width: width)
            measured[id] = height
            return height
        }

        /// The conversation's context, with bubbles as wide as this timeline allows.
        private var rowContext: ConversationContext {
            var context = parent?.context ?? ConversationContext()
            context.bubbleMaxWidth = min((collectionView?.bounds.width ?? 0) * Theme.Metrics.bubbleWidthFraction, Theme.Metrics.bubbleMaxWidth)
            return context
        }

        @ViewBuilder
        private func content(for id: String) -> some View {
            if let parent, let model {
                Group {
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
                .environment(model)
                .environment(parent.conversation)
                .environment(\.conversationContext, rowContext)
                // Hosted rows don't inherit the window's environment: links in bubbles open in Xenia.
                .environment(\.openURL, OpenURLAction { [links = model.links] in links.handle($0) })
            }
        }

        // MARK: Updates

        func update() {
            // Rows measured before the timeline has a width would be measured wrong: wait for it.
            guard let parent, let dataSource, let collectionView, let layout, collectionView.bounds.width > 0 else { return }
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
                    // The core's IDs are unique; a repeat would crash the data source.
                    guard indexedRows.updateValue(row, forKey: row.id) == nil else { continue }
                    indexedIDs.append(row.id)
                }
            }

            var ids: [String] = []
            var nextRows: [String: TimelineRow] = [:]
            if !conversation.isReady {
                ids = [Item.loading]
            } else {
                if conversation.isLoadingOlder {
                    ids.append(Item.older)
                } else if conversation.isAtStart && conversation.threadRoot == nil {
                    ids.append(Item.start)
                }
                ids += indexedIDs
                nextRows = indexedRows
                if !conversation.typing.isEmpty && conversation.isAtEnd {
                    ids.append(Item.typing)
                }
            }

            var changed: [String] = []
            let context = rowContext
            let contextChanged = textNeedsMeasuring || (shownContext.map { !$0.sameLayout(as: context) } ?? false)
            textNeedsMeasuring = false
            if rowsChanged || contextChanged || rowsByID.count != nextRows.count {
                for (id, row) in nextRows where rowsByID[id] != nil && (contextChanged || rowsByID[id] != row) {
                    changed.append(id)
                }
            }
            if contextChanged {
                changed += ids.filter { Item.all.contains($0) && shownIDs.contains($0) }
            }
            _ = conversation.layoutRevision
            changed += conversation.takeRowsToLayOut().filter { rowsByID[$0] != nil && !changed.contains($0) }
            if conversation.typing != shownTyping, ids.contains(Item.typing), shownIDs.contains(Item.typing) {
                changed.append(Item.typing)
            }
            shownTyping = conversation.typing
            shownContext = context
            // Every row may draw differently now: rows are measured again as they show.
            if contextChanged {
                measured.removeAll()
                layout.forgetAllHeights()
            }
            for id in changed { measured[id] = nil }
            layout.forgetHeights(of: changed)

            guard ids != shownIDs || !changed.isEmpty else { return }

            let previousIDs = shownIDs
            rowsByID = nextRows
            shownIDs = ids

            let pinned = isPinnedToBottom
            let anchor = pinned ? nil : captureAnchor()
            let kept = previousIDs.filter { $0 != Item.typing }
            let appendsOnly = !previousIDs.isEmpty && didInitialScroll && ids.starts(with: kept) && ids.count > kept.count
            let animated = pinned && appendsOnly && !UIAccessibility.isReduceMotionEnabled
            layout.animatesAppends = animated
            if animated {
                layout.arrivals = Dictionary(uniqueKeysWithValues: ids[kept.count...].map { ($0, arrival(of: $0)) })
            }
            // The first messages replace the loading shapes with a cross-fade, not a cut.
            let replacesLoading = previousIDs == [Item.loading] && ids != previousIDs

            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids)
            snapshot.reconfigureItems(changed.filter { nextRows[$0] != nil || (Item.all.contains($0) && ids.contains($0)) })
            layout.ids = ids

            // Rows that changed in place (a reaction, Delivered becoming Read, an edit) ease to
            // their new height instead of jumping.
            let resizes = ids == previousIDs && didInitialScroll && !UIAccessibility.isReduceMotionEnabled
            if let anchor {
                layout.anchor = .row(id: anchor.id, screenY: anchor.screenY)
            } else if !appendsOnly, pinned, didInitialScroll || conversation.focusedRowID == nil && !hasReadMarker {
                layout.anchor = .bottom
            }
            let apply = { [self] in
                defer { layout.anchor = nil }
                dataSource.apply(snapshot, animatingDifferences: animated || resizes)
                collectionView.layoutIfNeeded()
                if !didInitialScroll {
                    if conversation.isReady { initialScroll() }
                } else if pinned {
                    scrollToBottom(animated: false)
                } else if let anchor {
                    restore(anchor)
                }
            }
            if animated {
                // One spring moves the new row and the scroll together, as Messages does.
                UIView.animate(springDuration: 0.42, bounce: 0.14, initialSpringVelocity: 0, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: apply)
            } else if resizes {
                UIView.animate(springDuration: 0.3, bounce: 0, initialSpringVelocity: 0, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: apply)
            } else {
                apply()
            }
            if replacesLoading {
                // A fade on the layer alone: a view transition would capture the rows before
                // they're scrolled to the newest message.
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = 0.22
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                collectionView.layer.add(fade, forKey: "replaceLoading")
            }
            reportEdges()
            measureAhead()
        }

        /// Where the first open lands instead of the newest message.
        private var hasReadMarker: Bool {
            rowsByID.values.contains { if case .readMarker = $0 { true } else { false } }
        }

        private func arrival(of id: String) -> TimelineLayout.Arrival {
            if id == Item.typing { return .received }
            guard let message = rowsByID[id]?.message else { return .plain }
            return message.isOwn ? .sent : .received
        }

        /// The first width, or a new one (rotation): bubbles take a new widest size and text wraps
        /// differently, so rows are drawn and measured again.
        private func widthChanged() {
            update()
        }

        /// Text Size or Bold Text changed: every row draws at a new height.
        private var textNeedsMeasuring = false

        private func textChanged() {
            textNeedsMeasuring = true
            update()
        }

        func setInsets(_ newInsets: UIEdgeInsets) {
            guard let collectionView, let layout else { return }
            let fromBottom = maxOffset - collectionView.contentOffset.y
            insets = newInsets
            var content = newInsets
            content.bottom += Self.bottomGap
            collectionView.contentInset = content
            collectionView.verticalScrollIndicatorInsets = newInsets
            layout.invalidateLayout()
            collectionView.layoutIfNeeded()
            // The composer and keyboard push the conversation up, as in Messages.
            let target = isPinnedToBottom ? maxOffset : maxOffset - fromBottom
            collectionView.contentOffset.y = max(minOffset, min(maxOffset, target))
        }

        // MARK: Positions

        private var minOffset: CGFloat {
            -(collectionView?.adjustedContentInset.top ?? 0)
        }

        private var maxOffset: CGFloat {
            guard let collectionView else { return 0 }
            let inset = collectionView.adjustedContentInset
            // The layout's own height: the scroll view's copy can lag a pass behind.
            let height = layout?.collectionViewContentSize.height ?? collectionView.contentSize.height
            return max(minOffset, height + inset.bottom - collectionView.bounds.height)
        }

        private struct ScreenAnchor {
            let id: String
            let screenY: CGFloat
        }

        /// The first message on screen and where it sits, so updates above it leave it there.
        private func captureAnchor() -> ScreenAnchor? {
            guard let collectionView, let layout else { return nil }
            let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
            guard let row = layout.firstRow(below: top, where: { !Item.all.contains($0) }) else { return nil }
            return ScreenAnchor(id: row.id, screenY: row.minY - collectionView.contentOffset.y)
        }

        private func restore(_ anchor: ScreenAnchor) {
            settle { [weak self] in
                guard let self, let frame = self.layout?.frame(for: anchor.id) else { return nil }
                return frame.minY - anchor.screenY
            }
        }

        func scrollToBottom(animated: Bool) {
            guard let collectionView else { return }
            isPinnedToBottom = true
            collectionView.layoutIfNeeded()
            if animated {
                collectionView.setContentOffset(CGPoint(x: 0, y: maxOffset), animated: true)
            } else {
                settle { [weak self] in self?.maxOffset }
            }
        }

        /// Moves to a target that depends on heights, measuring the rows that come into view and
        /// moving again until it holds (rows measure themselves as they near the screen).
        private func settle(_ target: () -> CGFloat?) {
            guard let collectionView else { return }
            for _ in 0..<4 {
                collectionView.layoutIfNeeded()
                guard let y = target() else { return }
                let clamped = max(minOffset, min(maxOffset, y))
                guard abs(clamped - collectionView.contentOffset.y) > 0.5 else { return }
                collectionView.contentOffset.y = clamped
            }
            collectionView.layoutIfNeeded()
        }

        func scroll(to rowID: String, anchor: TimelineCollection.Anchor, animated: Bool) {
            guard let collectionView, let layout, layout.frame(for: rowID) != nil else { return }
            isPinnedToBottom = false
            func target() -> CGFloat? {
                guard let frame = layout.frame(for: rowID) else { return nil }
                let inset = collectionView.adjustedContentInset
                let visible = collectionView.bounds.height - inset.top - inset.bottom
                let y: CGFloat = switch anchor {
                case .top: frame.minY - inset.top
                case .center: frame.midY - inset.top - visible / 2
                case .bottom: frame.maxY - inset.top - visible
                }
                return max(minOffset, min(maxOffset, y))
            }
            if animated {
                guard let first = target() else { return }
                collectionView.setContentOffset(CGPoint(x: 0, y: first), animated: true)
                return
            }
            settle(target)
            if anchor == .bottom || settled(atBottom: collectionView) { isPinnedToBottom = true }
        }

        private func settled(atBottom collectionView: UICollectionView) -> Bool {
            collectionView.contentOffset.y >= maxOffset - 2
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
            // Cells that measured themselves after the first pass move the target: settle once more.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let focused = conversation.focusedRowID {
                    self.scroll(to: focused, anchor: .center, animated: false)
                } else if self.isPinnedToBottom {
                    self.scrollToBottom(animated: false)
                }
                self.reportEdges()
            }
        }

        // MARK: Scrolling

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            measureAhead()
            if scrollView.isTracking || scrollView.isDecelerating {
                isPinnedToBottom = settled(atBottom: scrollView as! UICollectionView)
            }
            reportEdges()
        }

        func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            // A row that left the conversation (the loading shimmer) stops; one merely scrolled
            // away may be shown again without being configured again, so it keeps its content.
            guard let cell = cell as? TimelineCell, let id = cell.itemID, !shownIDs.contains(id) else { return }
            cell.clear()
        }

        // MARK: Times

        private weak var revealPan: UIPanGestureRecognizer?

        /// Swiping the conversation left brings every message's time in from the trailing edge;
        /// letting go springs it back, as in Messages.
        @objc private func revealTimes(_ pan: UIPanGestureRecognizer) {
            guard let collectionView, let layout else { return }
            let limit = TimelineLayout.revealWidth
            switch pan.state {
            case .began, .changed:
                let pulled = max(0, -pan.translation(in: collectionView).x)
                // Past the times, it resists like a rubber band.
                layout.revealOffset = pulled <= limit ? pulled : limit + (pulled - limit) * 0.15
            default:
                UIView.animate(springDuration: 0.4, bounce: 0, initialSpringVelocity: 0, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                    layout.revealOffset = 0
                    collectionView.layoutIfNeeded()
                }
            }
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard recognizer === revealPan, let pan = recognizer as? UIPanGestureRecognizer else { return true }
            // Mostly sideways and to the left; a swipe right on a bubble replies instead.
            let velocity = pan.velocity(in: pan.view)
            return velocity.x < 0 && abs(velocity.x) > abs(velocity.y) * 1.4
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            recognizer === revealPan && other === collectionView?.panGestureRecognizer
        }

        // MARK: Measuring ahead

        private var isMeasuringAhead = false

        /// Measures the rows near the screen a little at a time, between frames, so a flick
        /// reaches rows that are ready instead of measuring them on its frames. While the finger
        /// or a flick moves the conversation, a sliver of each frame (the next scroll asks again);
        /// once it's still, batches back to back until the rows near the screen are done.
        private func measureAhead() {
            guard !isMeasuringAhead else { return }
            isMeasuringAhead = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let collectionView = self.collectionView else { return }
                self.isMeasuringAhead = false
                let moving = collectionView.isTracking || collectionView.isDecelerating
                let more = self.layout?.measureAhead(budget: moving ? 0.002 : 0.008) == true
                if more, !moving { self.measureAhead() }
            }
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            reportEdges()
            measureAhead()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { measureAhead() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            measureAhead()
        }

        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            isPinnedToBottom = false
            return true
        }

        private func reportEdges() {
            guard let collectionView, didInitialScroll else { return }
            let offset = collectionView.contentOffset.y
            let next = Edges(
                // Within three screens of the top: the next page is fetched before it's reached.
                isNearTop: offset + collectionView.adjustedContentInset.top < collectionView.bounds.height * 3,
                isNearBottom: offset >= maxOffset - 120
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

/// Holds the timeline, and parents its rows' hosting controllers.
final class TimelineViewController: UIViewController {
    private let collectionView: UICollectionView

    init(collectionView: UICollectionView) {
        self.collectionView = collectionView
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = collectionView
    }
}

/// Tells the timeline when its width changes.
final class TimelineCollectionView: UICollectionView {
    var onWidthChange: () -> Void = {}
    var onTextChange: () -> Void = {}
    private var laidOutWidth: CGFloat = 0

    override init(frame: CGRect, collectionViewLayout layout: UICollectionViewLayout) {
        super.init(frame: frame, collectionViewLayout: layout)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitLegibilityWeight.self]) { (view: Self, _) in
            // Once the rows' hosts have the new traits too.
            DispatchQueue.main.async { [weak view] in view?.onTextChange() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width != laidOutWidth {
            laidOutWidth = bounds.width
            // After this layout pass, not inside it.
            if bounds.width > 0 { DispatchQueue.main.async { [weak self] in self?.onWidthChange() } }
        }
    }
}

/// A row's cell: SwiftUI in a hosting controller that ignores the safe area. Rows pass under the
/// bars, and the safe area there would otherwise push each row's content into itself. It takes
/// the height the layout measured.
private final class TimelineCell: UICollectionViewCell {
    private var host: UIHostingController<AnyView>?
    /// The row it shows.
    var itemID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ content: AnyView, in parent: UIViewController?) {
        if let host {
            host.rootView = content
            return
        }
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        host.sizingOptions = []
        host.view.backgroundColor = .clear
        host.view.frame = contentView.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        parent?.addChild(host)
        contentView.addSubview(host.view)
        host.didMove(toParent: parent)
        self.host = host
    }

    func clear() {
        itemID = nil
        host?.rootView = AnyView(EmptyView())
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        layoutAttributes
    }
}

private extension ConversationContext {
    /// Whether rows would draw the same in either context. The closures are the same actions.
    func sameLayout(as other: ConversationContext) -> Bool {
        isGroup == other.isGroup && isThread == other.isThread && bubbleMaxWidth == other.bubbleMaxWidth
    }
}
