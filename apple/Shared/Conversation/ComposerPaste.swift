#if os(macOS)
import AppKit
import ObjectiveC

/// Pasting a photo or a file into the Mac's message field attaches it, as in Messages, whether by
/// ⌘V, Edit > Paste or dropping it on the field; text still pastes as text.
///
/// The field is edited by SwiftUI's own text view, which reads only text. That text view is given
/// a subclass that also reads files and images while it's editing a message field: files ahead
/// of text (a file copied in Finder also carries its name as text), images after it (text copied
/// from a document can carry a picture of itself). Any other field it edits reads as before.
///
/// Why a runtime subclass: every way in reaches the text view's `readSelection(from:type:)`, and
/// nothing public sits in front of it. `onPasteCommand` and `pasteDestination` only hear Paste
/// when no text view takes it first, and a replaced Edit > Paste would still miss the field's
/// own context menu and drops onto it. The subclass overrides only those two public NSTextView
/// methods and falls back to the original's, so if SwiftUI's view ever changes shape, pasting
/// is text-only again rather than broken.
enum ComposerPaste {
    /// Sends what's on the pasteboard in this type. True when it was taken as attachments.
    typealias Handler = (NSPasteboard, NSPasteboard.PasteboardType) -> Bool

    static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
    ]

    private static let prefix = "XeniaComposerPaste_"
    private static let handlers = NSMapTable<NSTextView, HandlerBox>.weakToStrongObjects()

    private final class HandlerBox {
        let handler: Handler
        /// The field being edited when this was installed. The text view is SwiftUI's field
        /// editor, which can go on to edit another field in the window: that one only takes text.
        weak var field: AnyObject?

        init(_ handler: @escaping Handler, field: AnyObject?) {
            self.handler = handler
            self.field = field
        }
    }

    /// Lets this text view take attachments, handing them to `handler`. Safe to call again.
    static func install(on textView: NSTextView, handler: @escaping Handler) {
        handlers.setObject(HandlerBox(handler, field: textView.delegate), forKey: textView)
        guard let current = object_getClass(textView) else { return }
        let name = NSStringFromClass(current)
        // Already done, or the class belongs to key-value observing, which mustn't be subclassed.
        guard !name.hasPrefix(prefix), !name.hasPrefix("NSKVONotifying_"),
              let subclass = subclass(of: current) else { return }
        object_setClass(textView, subclass)
    }

    /// The handler for what this text view is editing now, if it's a message field.
    fileprivate static func handler(for textView: NSTextView) -> Handler? {
        guard let box = handlers.object(forKey: textView), let field = box.field, field === textView.delegate else { return nil }
        return box.handler
    }

    private static func subclass(of base: AnyClass) -> AnyClass? {
        let name = prefix + NSStringFromClass(base)
        if let existing = NSClassFromString(name) { return existing }
        let readable = #selector(getter: NSTextView.readablePasteboardTypes)
        let read = #selector(NSTextView.readSelection(from:type:))
        guard let readableMethod = class_getInstanceMethod(base, readable),
              let readMethod = class_getInstanceMethod(base, read),
              let subclass = objc_allocateClassPair(base, name, 0)
        else { return nil }

        typealias ReadableIMP = @convention(c) (AnyObject, Selector) -> NSArray
        typealias ReadIMP = @convention(c) (AnyObject, Selector, NSPasteboard, NSString) -> Bool
        let baseReadable = unsafeBitCast(method_getImplementation(readableMethod), to: ReadableIMP.self)
        let baseRead = unsafeBitCast(method_getImplementation(readMethod), to: ReadIMP.self)

        let readableTypes: @convention(block) (NSTextView) -> NSArray = { view in
            let base = baseReadable(view, readable)
            guard MainActor.assumeIsolated({ handler(for: view) != nil }) else { return base }
            let text = (base as? [String] ?? []).filter { $0 != NSPasteboard.PasteboardType.fileURL.rawValue }
            return ([NSPasteboard.PasteboardType.fileURL.rawValue] + text + imageTypes.map(\.rawValue)) as NSArray
        }
        let readSelection: @convention(block) (NSTextView, NSPasteboard, NSString) -> Bool = { view, pasteboard, type in
            let type = NSPasteboard.PasteboardType(type as String)
            let taken = MainActor.assumeIsolated {
                guard type == .fileURL || imageTypes.contains(type), let handler = handler(for: view) else { return false }
                return handler(pasteboard, type)
            }
            return taken || baseRead(view, read, pasteboard, type.rawValue as NSString)
        }
        class_addMethod(subclass, readable, imp_implementationWithBlock(readableTypes), method_getTypeEncoding(readableMethod))
        class_addMethod(subclass, read, imp_implementationWithBlock(readSelection), method_getTypeEncoding(readMethod))
        objc_registerClassPair(subclass)
        return subclass
    }
}
#endif
