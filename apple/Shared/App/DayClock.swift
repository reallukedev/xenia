import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The moment relative dates are written from ("9:41 AM", "Yesterday"), moved on only when the
/// day changes or the clock or time zone is set, so the list stays right overnight without a
/// timer. The Mac app can run for days.
@Observable
final class DayClock {
    static let shared = DayClock()

    private(set) var now = Date.now

    private init() {
        var names: [Notification.Name] = [.NSCalendarDayChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange]
        #if os(iOS)
        // Also posted on returning to the front when midnight passed while suspended.
        names.append(UIApplication.significantTimeChangeNotification)
        #endif
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DayClock.shared.now = .now }
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var dayClock = DayClock.shared
}
