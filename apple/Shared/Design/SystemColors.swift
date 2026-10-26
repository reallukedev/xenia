import XeniaCore
import SwiftUI

nonisolated extension Color {
    /// My own bubbles: Messages blue on every Mac, whatever the system accent.
    static let ownBubble = Color(red: 0.0, green: 0.478, blue: 1.0)

    /// The gray behind a person's initials in Messages, lighter at the top.
    static var monogram: LinearGradient {
        LinearGradient(colors: [monogramTop, monogramBottom], startPoint: .top, endPoint: .bottom)
    }

    #if os(macOS)
    private static let monogramTop = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.45, green: 0.46, blue: 0.50, alpha: 1)
            : NSColor(srgbRed: 0.66, green: 0.68, blue: 0.73, alpha: 1)
    })
    private static let monogramBottom = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.31, green: 0.32, blue: 0.35, alpha: 1)
            : NSColor(srgbRed: 0.52, green: 0.54, blue: 0.59, alpha: 1)
    })
    static let groupedBackground = Color(nsColor: .windowBackgroundColor)
    static let groupedCell = Color(nsColor: .controlBackgroundColor)
    /// Behind the messages. Hosted timeline rows can't read the window's background style, so
    /// anything that must be opaque against the conversation fills with this.
    static let conversationBackground = Color(nsColor: .textBackgroundColor)
    /// A mention in a received bubble. Lifted in Dark Mode, where the plain accent is too dim to
    /// read on the gray (or the orange of a bubble that mentions me).
    static let mentionText = Color(nsColor: NSColor(name: nil) { appearance in
        let accent = NSColor.controlAccentColor
        guard appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua else { return accent }
        return accent.blended(withFraction: 0.35, of: .white) ?? accent
    })
    /// Received message bubbles: the Messages gray.
    static let incomingBubble = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.231, green: 0.231, blue: 0.239, alpha: 1)
            : NSColor(srgbRed: 0.914, green: 0.914, blue: 0.922, alpha: 1)
    })
    #else
    private static let monogramTop = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.45, green: 0.46, blue: 0.50, alpha: 1)
            : UIColor(red: 0.66, green: 0.68, blue: 0.73, alpha: 1)
    })
    private static let monogramBottom = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.31, green: 0.32, blue: 0.35, alpha: 1)
            : UIColor(red: 0.52, green: 0.54, blue: 0.59, alpha: 1)
    })
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let groupedCell = Color(uiColor: .secondarySystemGroupedBackground)
    static let conversationBackground = Color(uiColor: .systemBackground)
    static let mentionText = Color(uiColor: UIColor { traits in
        let accent = (UIColor(named: "AccentColor") ?? .systemBlue).resolvedColor(with: traits)
        guard traits.userInterfaceStyle == .dark else { return accent }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        accent.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let lift: CGFloat = 0.35
        return UIColor(red: red + (1 - red) * lift, green: green + (1 - green) * lift, blue: blue + (1 - blue) * lift, alpha: alpha)
    })
    static let incomingBubble = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.149, green: 0.149, blue: 0.161, alpha: 1)
            : UIColor(red: 0.914, green: 0.914, blue: 0.922, alpha: 1)
    })
    #endif
}
