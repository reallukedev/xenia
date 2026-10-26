import XeniaCore
import SwiftUI

/// Xenia's tokens. Screens use these, never raw numbers, so both platforms stay consistent and
/// each keeps its own density (the Mac's body text is 13 pt and its rows 28 pt; never a blown-up
/// iPhone).
enum Theme {
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    enum Metrics {
        #if os(macOS)
        static let rowAvatar: CGFloat = 40
        static let messageAvatar: CGFloat = 24
        static let headerAvatar: CGFloat = 24
        static let detailAvatar: CGFloat = 64
        static let memberAvatar: CGFloat = 24
        static let bubbleMaxWidth: CGFloat = 520
        static let photoMax: CGFloat = 320
        static let bubbleRadius: CGFloat = 14
        static let bubbleVerticalPadding: CGFloat = 6
        static let tapback: CGFloat = 24
        static let pageMargin: CGFloat = 16
        static let minTarget: CGFloat = 28
        #else
        static let rowAvatar: CGFloat = 46
        static let messageAvatar: CGFloat = 28
        static let headerAvatar: CGFloat = 32
        static let detailAvatar: CGFloat = 88
        static let memberAvatar: CGFloat = 36
        static let bubbleMaxWidth: CGFloat = 560
        static let photoMax: CGFloat = 240
        static let bubbleRadius: CGFloat = 18
        static let bubbleVerticalPadding: CGFloat = 7
        static let tapback: CGFloat = 30
        static let pageMargin: CGFloat = 16
        static let minTarget: CGFloat = 44
        #endif
        /// Bubbles never run wider than this share of the conversation.
        static let bubbleWidthFraction: CGFloat = 0.75
        /// How far a swipe slides the conversation to bring in each message's time and who has
        /// read it.
        static let revealWidth: CGFloat = 96
    }

    /// Every animation, named by what moves, so the whole app moves the same way. Springs finish
    /// under 0.35 s; under Reduce Motion, movement becomes a cross-fade.
    enum Motion {
        /// A control acknowledging a press.
        static let press = Animation.snappy(duration: 0.14)
        /// A value changing in place: a count, a check, a reaction.
        static let flip = Animation.snappy(duration: 0.22)
        /// Rows entering, leaving, a bubble appearing.
        static let row = Animation.smooth(duration: 0.28)
        /// A surface opening: the reply bar, the jump-to-latest button.
        static let panel = Animation.smooth(duration: 0.34)
        /// A palette summoned from the keyboard (⌘K): quick, so typing can start at once.
        static let palette = Animation.snappy(duration: 0.18)
        /// A photo replacing its placeholder.
        static let contentFade = Animation.easeOut(duration: 0.22)
        /// Hover on the Mac.
        static let hover = Animation.easeOut(duration: 0.13)
    }

    /// Each person has a stable color, chosen by the core from their ID, worn on their avatar and
    /// on their name in groups. System colors, so they adapt to dark mode and Increase Contrast.
    /// The order matches the core's palette.
    static let personColors: [Color] = [.red, .orange, .green, .teal, .blue, .indigo, .purple, .pink, .brown]
}
