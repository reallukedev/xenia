import XeniaCore
import SwiftUI

extension Color {
    /// The stable color of a person or room, from its Matrix ID.
    static func person(_ id: String) -> Color {
        let index = Int(avatarColorIndex(id: id))
        return Theme.personColors[index % Theme.personColors.count]
    }
}
