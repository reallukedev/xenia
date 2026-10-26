#if os(iOS)
import Testing
import UIKit
@testable import Xenia

@MainActor
@Suite("Timeline layout")
struct TimelineLayoutTests {
    /// A timeline of fixed-height rows, recording which rows it was asked to measure.
    private final class Harness {
        let layout = TimelineLayout()
        let collectionView: UICollectionView
        let dataSource: UICollectionViewDiffableDataSource<Int, String>
        var measured: [String] = []

        init(ids: [String]) {
            collectionView = UICollectionView(frame: CGRect(x: 0, y: 0, width: 400, height: 800), collectionViewLayout: layout)
            let registration = UICollectionView.CellRegistration<UICollectionViewCell, String> { _, _, _ in }
            dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
                collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
            }
            layout.isPinnedToBottom = { false }
            layout.measure = { [unowned self] id, _ in
                measured.append(id)
                return 100
            }
            show(ids)
        }

        func show(_ ids: [String]) {
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids)
            layout.ids = ids
            dataSource.apply(snapshot, animatingDifferences: false)
            collectionView.layoutIfNeeded()
        }

        func screenY(of id: String) -> CGFloat? {
            layout.frame(for: id).map { $0.minY - collectionView.contentOffset.y }
        }
    }

    private static func rows(_ range: Range<Int>) -> [String] {
        range.map { "m\($0)" }
    }

    @Test("Older rows arriving above leave the row on screen where it was, without building the rows the old offset would show")
    func prependKeepsAnchor() throws {
        let harness = Harness(ids: Self.rows(50..<100))
        // Every row measured once, so the screen sits on real heights.
        for _ in 0..<10 where harness.layout.measureAhead(budget: 1) {}
        harness.collectionView.contentOffset.y = 2_000
        harness.collectionView.layoutIfNeeded()
        let before = try #require(harness.screenY(of: "m70"))
        harness.measured = []

        harness.layout.anchor = .row(id: "m70", screenY: before)
        harness.show(Self.rows(20..<100))
        harness.layout.anchor = nil

        #expect(harness.screenY(of: "m70") == before)
        // The older rows sit far above the screen: none of them were built for a moment at the old offset.
        #expect(harness.measured.allSatisfy { !Self.rows(20..<50).contains($0) })
    }
}
#endif
