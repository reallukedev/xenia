import Foundation
import XeniaCore

/// Where each pin sits, saved with its favourite as Matrix's tag `order` (0 to 1, lowest first),
/// so every device, and other clients, show the pins in the same order.
nonisolated enum PinOrder {
    /// Pins given a place come first, in that order; newer ones follow, by name.
    static func sorted(_ rooms: [RoomSummary]) -> [RoomSummary] {
        rooms.sorted { a, b in
            switch (a.favouriteOrder, b.favouriteOrder) {
            case let (x?, y?) where x != y: x < y
            case (_?, nil): true
            case (nil, _?): false
            default: a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// The places to save so the pins read in `ids`' order, and only those that change. A moved
    /// pin takes a place between its new neighbors; when they leave no room, or the pins have no
    /// places yet, every pin gets an evenly spaced one.
    static func changes(for ids: [String], current: [String: Double]) -> [String: Double] {
        let places = ids.map { current[$0] }
        if isAscending(places) { return [:] }
        for index in ids.indices {
            var others = places
            others.remove(at: index)
            guard isAscending(others) else { continue }
            let before = index > 0 ? places[index - 1] ?? 0 : 0
            let after = index < ids.count - 1 ? places[index + 1] ?? 1 : 1
            if after - before > minimumGap {
                return [ids[index]: (before + after) / 2]
            }
        }
        var spread: [String: Double] = [:]
        for (index, id) in ids.enumerated() {
            let place = Double(index + 1) / Double(ids.count + 1)
            if current[id] != place { spread[id] = place }
        }
        return spread
    }

    /// Closer than this, places would soon run out of room between them.
    private static let minimumGap = 1e-6

    /// Every pin has a place, each after the last.
    private static func isAscending(_ places: [Double?]) -> Bool {
        var last = -Double.infinity
        for place in places {
            guard let place, place > last else { return false }
            last = place
        }
        return true
    }
}
