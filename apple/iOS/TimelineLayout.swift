import UIKit

/// The conversation's layout on iPhone: one column of rows, newest at the bottom.
///
/// The layout measures each row itself, once, as it nears the screen, and remembers it by row ID,
/// so older messages arriving above, or a row above the screen finding its real height, never
/// move what's on screen. (Cells never size themselves: a reused cell can report the height of
/// the row it showed before.) A conversation shorter than the screen
/// sits at the bottom, by the composer. While it scrolls, rows trail the motion in proportion to
/// their distance from the finger and spring back, as in Messages.
final class TimelineLayout: UICollectionViewLayout {
    /// The item IDs in order, set by the timeline before each update.
    var ids: [String] = [] {
        didSet { indexNeedsBuilding = true }
    }
    /// Whether the timeline is following the newest message, so rows that grow keep it in view.
    var isPinnedToBottom: () -> Bool = { true }
    var springsEnabled = false {
        didSet { if !springsEnabled { springs.reset() } }
    }
    /// Set for one update: rows added at the end arrive instead of appearing.
    var animatesAppends = false
    /// How each row added at the end arrives, for one update.
    var arrivals: [String: Arrival] = [:]

    enum Arrival {
        /// My message: rises out of the composer, as Messages sends.
        case sent
        /// Someone else's, or their typing: grows from its tail corner.
        case received
        /// A header or note: fades in.
        case plain
    }
    /// How far the conversation is swiped left to show each message's time.
    var revealOffset: CGFloat = 0 {
        didSet { if revealOffset != oldValue { invalidateLayout(with: SpringContext()) } }
    }
    /// How far a swipe brings the times in.
    static let revealWidth = Theme.Metrics.revealWidth

    /// A row's height at a width, measured by the timeline.
    var measure: (String, CGFloat) -> CGFloat? = { _, _ in nil }
    /// Set for one update: where the screen lands once rows change. The layout goes there in the
    /// same pass, so the rows that would show for a moment at the old offset are never built.
    var anchor: Anchor?

    enum Anchor {
        /// A row stays where it is on screen while rows change around it (older messages arriving above).
        case row(id: String, screenY: CGFloat)
        /// The newest message stays in view.
        case bottom
    }

    private var heights: [String: CGFloat] = [:]
    private var measuredWidth: CGFloat = 0
    private var frames: [CGRect] = []
    private var indexByID: [String: Int] = [:]
    private var indexNeedsBuilding = true
    private var contentHeight: CGFloat = 0
    private var needsFrames = true
    private var appendedFrom = Int.max
    private lazy var springs = RowSprings(layout: self)

    static let estimatedHeight: CGFloat = 64
    /// Rows are measured this far beyond each edge of the screen, before they show.
    private static let overscan: CGFloat = 500

    // MARK: Building

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width = collectionView.bounds.width
        if width != measuredWidth {
            // Text wraps differently at a new width: every row is measured again.
            measuredWidth = width
            heights.removeAll()
            needsFrames = true
        }
        guard needsFrames else { return }
        needsFrames = false
        buildFrames()
        // The rows on screen and near it get their real heights now: where the screen will be
        // once the anchor is back in place, or where it is.
        if measureRows(in: screenAfterUpdate.insetBy(dx: 0, dy: -Self.overscan), visibleTop: nil) != nil {
            buildFrames()
        }
    }

    /// The visible rect once this update settles.
    private var screenAfterUpdate: CGRect {
        guard let collectionView else { return .zero }
        var rect = collectionView.bounds
        if let y = anchoredOffset { rect.origin.y = y }
        return rect
    }

    /// The scroll position that keeps the anchor where it was on screen.
    private var anchoredOffset: CGFloat? {
        guard let anchor, let collectionView else { return nil }
        let inset = collectionView.adjustedContentInset
        let lowest = -inset.top
        let highest = max(lowest, contentHeight + inset.bottom - collectionView.bounds.height)
        switch anchor {
        case .row(let id, let screenY):
            guard let index = indexByID[id], index < frames.count else { return nil }
            return min(highest, max(lowest, frames[index].minY - screenY))
        case .bottom:
            return highest
        }
    }

    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        guard let y = anchoredOffset else { return super.targetContentOffset(forProposedContentOffset: proposedContentOffset) }
        return CGPoint(x: proposedContentOffset.x, y: y)
    }

    private func buildFrames() {
        guard let collectionView else { return }
        let width = collectionView.bounds.width
        let count = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0
        frames.removeAll(keepingCapacity: true)
        // Heights change far more often than rows do (every row measured while scrolling).
        let buildsIndex = indexNeedsBuilding || indexByID.count != count
        if buildsIndex { indexByID.removeAll(keepingCapacity: true) }
        indexNeedsBuilding = false
        var y: CGFloat = 0
        for index in 0..<count {
            let id = index < ids.count ? ids[index] : ""
            let height = heights[id] ?? Self.estimatedHeight
            frames.append(CGRect(x: 0, y: y, width: width, height: height))
            if buildsIndex { indexByID[id] = index }
            y += height
        }
        // A short conversation sits at the bottom of the screen.
        let inset = collectionView.adjustedContentInset
        let visible = collectionView.bounds.height - inset.top - inset.bottom
        if y < visible {
            let shift = visible - y
            for index in frames.indices { frames[index].origin.y += shift }
            y = visible
        }
        contentHeight = y
    }

    /// Measures the rows in `rect` that haven't been. Returns how much rows above `visibleTop`
    /// grew (all growth while following the newest message), or nil when nothing was measured.
    private func measureRows(in rect: CGRect, visibleTop: CGFloat?) -> CGFloat? {
        guard let collectionView, collectionView.bounds.width > 0 else { return nil }
        let width = collectionView.bounds.width
        var measuredAny = false
        var grewAbove: CGFloat = 0
        var index = firstIndex(atOrBelow: rect.minY)
        while index < frames.count, index < ids.count, frames[index].minY <= rect.maxY {
            let id = ids[index]
            if heights[id] == nil, let height = measure(id, width) {
                heights[id] = height
                measuredAny = true
                let delta = height - frames[index].height
                if let visibleTop, frames[index].maxY <= visibleTop + 1 || isPinnedToBottom() {
                    grewAbove += delta
                }
            }
            index += 1
        }
        return measuredAny ? grewAbove : nil
    }

    /// Measures rows that will show soon (just above the screen first, then below) for up to
    /// `budget` seconds, between frames, so scrolling reaches rows that are already measured.
    /// Rows above the screen that change height move the scroll position by as much, so nothing
    /// on screen moves. Returns whether more rows near the screen are waiting.
    func measureAhead(budget: CFTimeInterval) -> Bool {
        let limit = 24
        guard let collectionView, collectionView.bounds.width > 0, !frames.isEmpty else { return false }
        let width = collectionView.bounds.width
        let bounds = collectionView.bounds
        let top = bounds.minY + collectionView.adjustedContentInset.top
        let reach = bounds.height * 4
        let first = firstIndex(atOrBelow: bounds.minY - reach)
        let last = min(frames.count, ids.count)
        var visibleFirst = firstIndex(atOrBelow: bounds.minY)
        visibleFirst = min(visibleFirst, last)
        // Nearest first: walking up from the screen, then down from it.
        var order: [Int] = []
        var up = visibleFirst - 1
        var down = visibleFirst
        while order.count < limit, up >= first || (down < last && frames[down].minY <= bounds.maxY + reach) {
            if up >= first {
                if heights[ids[up]] == nil { order.append(up) }
                up -= 1
            }
            if order.count < limit, down < last, frames[down].minY <= bounds.maxY + reach {
                if heights[ids[down]] == nil { order.append(down) }
                down += 1
            }
        }
        guard !order.isEmpty else { return false }
        var grewAbove: CGFloat = 0
        let start = CACurrentMediaTime()
        var measuredAll = true
        for (count, index) in order.enumerated() {
            // At least one row each time, so a slow row can't stall measuring.
            if count > 0, CACurrentMediaTime() - start > budget {
                measuredAll = false
                break
            }
            guard let height = measure(ids[index], width) else { continue }
            heights[ids[index]] = height
            if frames[index].maxY <= top + 1 || isPinnedToBottom() { grewAbove += height - frames[index].height }
        }
        let context = UICollectionViewLayoutInvalidationContext()
        if grewAbove != 0 { context.contentOffsetAdjustment = CGPoint(x: 0, y: grewAbove) }
        invalidateLayout(with: context)
        return !measuredAll || order.count == limit
    }

    private func hasUnmeasuredRows(in rect: CGRect) -> Bool {
        var index = firstIndex(atOrBelow: rect.minY)
        while index < frames.count, index < ids.count, frames[index].minY <= rect.maxY {
            if heights[ids[index]] == nil { return true }
            index += 1
        }
        return false
    }

    /// Rows whose content changed are measured again when they're next near the screen.
    func forgetHeights(of changed: [String]) {
        for id in changed { heights[id] = nil }
    }

    func forgetAllHeights() {
        heights.removeAll()
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
        if !(context is SpringContext) { needsFrames = true }
        super.invalidateLayout(with: context)
    }

    // MARK: Attributes

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !frames.isEmpty else { return [] }
        var result: [UICollectionViewLayoutAttributes] = []
        var index = firstIndex(atOrBelow: rect.minY)
        while index < frames.count, frames[index].minY <= rect.maxY {
            result.append(attributes(at: index, displaced: true))
            index += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard frames.indices.contains(indexPath.item) else { return nil }
        return attributes(at: indexPath.item, displaced: false)
    }

    private func attributes(at index: Int, displaced: Bool) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
        attributes.frame = frames[index]
        var lag: CGFloat = 0
        if displaced, springsEnabled, index < ids.count {
            lag = springs.offset(for: ids[index])
        }
        if lag != 0 || revealOffset != 0 {
            attributes.transform = CGAffineTransform(translationX: -revealOffset, y: lag)
        }
        return attributes
    }

    /// The first row whose bottom is at or below `y`.
    private func firstIndex(atOrBelow y: CGFloat) -> Int {
        var low = 0
        var high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].maxY < y { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Where a row sits, for scrolling to it.
    func frame(for id: String) -> CGRect? {
        indexByID[id].map { frames[$0] }
    }

    /// The first row whose bottom is below `y`, and where it sits: the anchor that keeps the
    /// screen still while rows change above it.
    func firstRow(below y: CGFloat, where include: (String) -> Bool) -> (id: String, minY: CGFloat)? {
        var index = firstIndex(atOrBelow: y + 1)
        while index < frames.count, index < ids.count {
            if include(ids[index]) { return (ids[index], frames[index].minY) }
            index += 1
        }
        return nil
    }

    // MARK: Scrolling

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let collectionView else { return false }
        if newBounds.width != collectionView.bounds.width { return true }
        let delta = newBounds.minY - collectionView.bounds.minY
        if springsEnabled, delta != 0 { springs.scrolled(by: delta, in: newBounds) }
        return (springsEnabled && delta != 0) || hasUnmeasuredRows(in: newBounds.insetBy(dx: 0, dy: -Self.overscan))
    }

    override func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
        guard let collectionView, newBounds.width == collectionView.bounds.width else {
            return super.invalidationContext(forBoundsChange: newBounds)
        }
        let top = newBounds.minY + collectionView.adjustedContentInset.top
        guard let grewAbove = measureRows(in: newBounds.insetBy(dx: 0, dy: -Self.overscan), visibleTop: top) else {
            return SpringContext()
        }
        // Rows coming into view were measured: frames are rebuilt, and growth above the screen
        // moves the scroll position by as much, so what's on screen stays put.
        let context = UICollectionViewLayoutInvalidationContext()
        if grewAbove != 0 { context.contentOffsetAdjustment = CGPoint(x: 0, y: grewAbove) }
        return context
    }

    fileprivate func springsMoved() {
        invalidateLayout(with: SpringContext())
    }

    fileprivate func visibleIDs(in rect: CGRect) -> [(id: String, midY: CGFloat)] {
        var result: [(String, CGFloat)] = []
        var index = firstIndex(atOrBelow: rect.minY)
        while index < frames.count, index < ids.count, frames[index].minY <= rect.maxY {
            result.append((ids[index], frames[index].midY))
            index += 1
        }
        return result
    }

    // MARK: Updates

    override func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
        super.prepare(forCollectionViewUpdates: updateItems)
        appendedFrom = Int.max
        guard animatesAppends else { return }
        let inserted = updateItems.compactMap { $0.updateAction == .insert ? $0.indexPathAfterUpdate?.item : nil }
        // At the end, or just above the typing dots, which stay last.
        if let first = inserted.min(), let last = inserted.max(), last >= frames.count - 2 {
            appendedFrom = first
        }
    }

    override func finalizeCollectionViewUpdates() {
        super.finalizeCollectionViewUpdates()
        appendedFrom = Int.max
        animatesAppends = false
        arrivals = [:]
    }

    override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard frames.indices.contains(itemIndexPath.item) else { return nil }
        let attributes = attributes(at: itemIndexPath.item, displaced: false)
        guard itemIndexPath.item >= appendedFrom, itemIndexPath.item < ids.count else { return attributes }
        let size = attributes.frame.size
        // Rows arriving mid-swipe start swiped, like the rest.
        let reveal = CGAffineTransform(translationX: -revealOffset, y: 0)
        switch arrivals[ids[itemIndexPath.item]] ?? .plain {
        case .sent:
            // The scroll already carries it up from the composer's edge; this adds the last of
            // the way out of the field.
            attributes.transform = reveal.translatedBy(x: 0, y: min(size.height, 44) * 0.6)
        case .received:
            // Scaled about the bubble's tail corner (bottom leading), not the row's center.
            let scale: CGFloat = 0.82
            let corner = CGPoint(x: -size.width / 2 + Theme.Spacing.l, y: size.height / 2)
            attributes.transform = CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: corner.x * (1 - scale) - revealOffset, y: corner.y * (1 - scale)))
            attributes.alpha = 0
        case .plain:
            attributes.alpha = 0
        }
        return attributes
    }
}

/// An invalidation that only moves rows by their springs, so frames aren't rebuilt.
private final class SpringContext: UICollectionViewLayoutInvalidationContext {}

/// Each visible row's lag behind the scroll, and the spring that brings it back.
@MainActor
private final class RowSprings {
    /// Weak: the display link keeps this alive, and it can outlive the conversation when someone
    /// leaves mid-flick.
    private weak var layout: TimelineLayout?
    private var states: [String: (offset: CGFloat, velocity: CGFloat)] = [:]
    private var link: CADisplayLink?
    private var touchY: CGFloat?
    private var lastTick: CFTimeInterval = 0

    /// How far a row can trail behind.
    private static let maxOffset: CGFloat = 30
    /// Rows this far from the finger trail by the whole scroll; nearer rows, proportionally less.
    private static let reach: CGFloat = 1100
    private static let stiffness: CGFloat = 210
    private static let damping: CGFloat = 21

    init(layout: TimelineLayout) {
        self.layout = layout
    }

    func offset(for id: String) -> CGFloat {
        states[id]?.offset ?? 0
    }

    func scrolled(by delta: CGFloat, in bounds: CGRect) {
        guard let layout, let collectionView = layout.collectionView else { return }
        // Only a finger or its flick: jumps, settling and pages arriving keep rows still.
        guard abs(delta) < 200, collectionView.isTracking || collectionView.isDecelerating else { return }
        let pan = collectionView.panGestureRecognizer
        if pan.state == .began || pan.state == .changed {
            touchY = pan.location(in: collectionView).y
        }
        let anchor = touchY ?? bounds.midY
        for (id, midY) in layout.visibleIDs(in: bounds) {
            let distance = abs(anchor - midY)
            let resistance = min(distance / Self.reach, 1)
            var state = states[id] ?? (0, 0)
            state.offset = max(-Self.maxOffset, min(Self.maxOffset, state.offset + delta * resistance))
            states[id] = state
        }
        start()
    }

    func reset() {
        states.removeAll()
        stop()
    }

    private func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTick = 0
    }

    private func stop() {
        link?.invalidate()
        link = nil
        touchY = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let layout else { return stop() }
        let dt = lastTick == 0 ? 1.0 / 120 : min(link.timestamp - lastTick, 1.0 / 30)
        lastTick = link.timestamp
        var moving = false
        for (id, state) in states {
            var (x, v) = state
            let a = -Self.stiffness * x - Self.damping * v
            v += a * dt
            x += v * dt
            if abs(x) < 0.05 && abs(v) < 0.5 {
                states[id] = nil
            } else {
                states[id] = (x, v)
                moving = true
            }
        }
        layout.springsMoved()
        // Settled: stop, even under a resting finger. The next scroll starts it again.
        if !moving { stop() }
    }
}
