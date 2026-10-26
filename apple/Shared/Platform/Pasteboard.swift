import XeniaCore
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Pasteboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// How long a copied secret stays on the pasteboard.
    private static let secretLifetime = Duration.seconds(120)

    /// Copies a secret like a recovery key: it stays on this device and leaves the pasteboard
    /// after two minutes, as passwords copied from a password manager do.
    static func copySecret(_ text: String) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // The convention clipboard histories and Universal Clipboard tools follow to skip a secret.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let copied = pasteboard.changeCount
        Task {
            try? await Task.sleep(for: secretLifetime)
            // Only if it's still the secret: something copied since stays.
            if NSPasteboard.general.changeCount == copied { NSPasteboard.general.clearContents() }
        }
        #else
        UIPasteboard.general.setItems([[UTType.plainText.identifier: text]], options: [
            .localOnly: true,
            .expirationDate: Date.now.addingTimeInterval(TimeInterval(secretLifetime.components.seconds)),
        ])
        #endif
    }
}
