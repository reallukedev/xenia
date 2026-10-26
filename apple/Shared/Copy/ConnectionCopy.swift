import Foundation
import XeniaCore

enum ConnectionCopy {
    /// A list's subtitle while the connection isn't normal; nothing when all is well.
    static func subtitle(_ state: ConnectionState) -> String? {
        switch state {
        case .connected: nil
        case .connecting: String(localized: "Connecting…")
        case .offline: String(localized: "Offline · Messages send when you reconnect")
        case .error: String(localized: "Can’t reach your server right now")
        }
    }
}
