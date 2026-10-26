import PhotosUI
import XeniaCore
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// The message field at the bottom of a conversation: attachments on the leading side, the
/// field, and Send inside it once there's something to send. Mentions are suggested as you type
/// "@"; replying or editing shows a bar above.
struct ComposerView: View {
    @Bindable var conversation: ConversationModel
    let members: [Member]

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var showingPhotos = false
    @State private var showingFiles = false
    #if os(iOS)
    @State private var showingCamera = false
    @State private var cameraDenied = false
    #endif

    var body: some View {
        let query = mentionQuery(textBeforeCursor: conversation.text)
        VStack(spacing: Theme.Spacing.s) {
            if let query {
                MentionSuggestions(members: members, query: query) { member in
                    conversation.insertMention(member, replacingQuery: query)
                }
                .transition(barTransition)
            }
            if conversation.replyingTo != nil || conversation.editing != nil {
                ContextBar(conversation: conversation)
                    .transition(barTransition)
            }
            HStack(alignment: .bottom, spacing: Theme.Spacing.s) {
                AttachMenu(showingPhotos: $showingPhotos, showingFiles: $showingFiles, creatingPoll: $conversation.isCreatingPoll, camera: camera, paste: paste)
                field
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.top, Theme.Spacing.s)
        .padding(.bottom, bottomPadding)
        #if os(macOS)
        .background {
            // Messages fade out under the composer instead of showing through around it.
            Rectangle()
                .fill(.background)
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.92), location: 0.45), .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
                }
                .padding(.top, -Theme.Spacing.l)
                .allowsHitTesting(false)
        }
        #endif
        // Typing carries no animation of its own: the suggestions coming and going need one.
        .animation(Theme.Motion.flip, value: query != nil)
        .animation(Theme.Motion.panel, value: conversation.replyingTo?.id)
        .animation(Theme.Motion.panel, value: conversation.editing?.id)
        .photosPicker(isPresented: $showingPhotos, selection: $pickedPhotos, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { conversation.sendFiles(urls) }
        }
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            sendPhotos(items)
            pickedPhotos = []
        }
        .onChange(of: conversation.sends) {
            if let room = model.room(conversation.roomID) {
                MessageDonation.donate(sendingTo: room, members: members)
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker(onCapture: send)
                .ignoresSafeArea()
        }
        .alert("Camera Access Is Off", isPresented: $cameraDenied) {
            Button("Cancel", role: .cancel) {}
            Button("Open Settings") {
                if let settings = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(settings)
                }
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text("To take photos and videos to send, allow Xenia to use the camera in Settings.")
        }
        #endif
        #if os(macOS)
        // A thread opened over the conversation: typing goes to the thread, not the one behind.
        .onAppear { if conversation.threadRoot != nil { focused = true } }
        #endif
        #if os(macOS)
        .onChange(of: focused, initial: true) { _, isFocused in
            guard isFocused else { return }
            // Spelling and grammar are checked as you type, as in Messages. After focus lands, when
            // the field's editor is the one taking the keys.
            DispatchQueue.main.async {
                guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
                editor.isContinuousSpellCheckingEnabled = true
                editor.isGrammarCheckingEnabled = true
                ComposerPaste.install(on: editor) { pasteboard, type in
                    attach(from: pasteboard, type: type)
                }
            }
        }
        #endif
        .onChange(of: conversation.editing?.id) { _, editing in
            if editing != nil { focused = true }
        }
        .onChange(of: conversation.replyingTo?.id) { _, replying in
            if replying != nil { focused = true }
        }
        #if os(iOS)
        // Photos dragged in from another app (on iPad, or held on iPhone) are sent, as in Messages.
        .dropDestination(for: PickedMedia.self) { items, _ in
            for item in items { send(item) }
            return !items.isEmpty
        }
        #endif
    }

    /// An input method has text it hasn't committed yet (Japanese, Chinese): Return is its, to
    /// confirm the word.
    private static var isComposing: Bool {
        #if os(macOS)
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
        #else
        (FirstResponder.current as? UITextInput)?.markedTextRange != nil
        #endif
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.xs) {
            TextField(placeholder, text: $conversation.text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($focused)
                .padding(.leading, Theme.Spacing.m)
                .padding(.vertical, 9)
                // A hardware keyboard (the Mac, an iPad's): Return sends, Shift or Option-Return
                // starts a new line, as in Messages. The onscreen keyboard's Return is a new line.
                .onKeyPress(.return, phases: .down) { press in
                    guard !Self.isComposing else { return .ignored }
                    if !press.modifiers.isDisjoint(with: [.shift, .option]) {
                        #if os(macOS)
                        // At the cursor: the field would otherwise take Shift-Return as Send.
                        (NSApp.keyWindow?.firstResponder as? NSTextView)?.insertNewlineIgnoringFieldEditor(nil)
                        return .handled
                        #else
                        return .ignored
                        #endif
                    }
                    // After the key event: the text view ignores its text being cleared during
                    // its own keystroke, and would keep showing what was sent.
                    DispatchQueue.main.async { send() }
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard !Self.isComposing else { return .ignored }
                    return conversation.editLastMessage() ? .handled : .ignored
                }
                .onKeyPress(.escape) {
                    guard conversation.replyingTo != nil || conversation.editing != nil else { return .ignored }
                    conversation.cancelReplyOrEdit()
                    return .handled
                }
                .onKeyPress(.tab) {
                    guard let query = mentionQuery(textBeforeCursor: conversation.text),
                          let first = MentionSuggestions.matches(members, query).first else { return .ignored }
                    conversation.insertMention(first, replacingQuery: query)
                    return .handled
                }
            #if os(macOS)
            if !conversation.canSend {
                // Messages offers emoji in the empty field; Send takes its place once there's text.
                Button {
                    focused = true
                    DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.trailing, Theme.Spacing.xs)
                .padding(.bottom, 4)
                .help("Emoji & Symbols (⌃⌘Space)")
                .accessibilityLabel(Text("Emoji & Symbols"))
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else {
                SendButton(isEnabled: true, isEditing: conversation.editing != nil, ownsShortcut: focused, action: send)
                    .padding(.trailing, Theme.Spacing.xs)
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            #else
            SendButton(isEnabled: conversation.canSend, isEditing: conversation.editing != nil, ownsShortcut: focused, action: send)
                .padding(.trailing, Theme.Spacing.xs)
                .padding(.bottom, 4)
            #endif
        }
        .composerFieldBackground()
        #if os(macOS)
        .animation(Theme.Motion.flip, value: conversation.canSend)
        #endif
    }

    private var barTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    private var placeholder: String {
        if conversation.threadRoot != nil { return String(localized: "Reply in Thread") }
        if let room = model.room(conversation.roomID) {
            return room.isEncrypted ? String(localized: "Encrypted Message") : String(localized: "Message")
        }
        return String(localized: "Message")
    }

    /// The Mac's field floats clear of the window's edge, as Messages' does.
    private var bottomPadding: CGFloat {
        #if os(macOS)
        Theme.Spacing.m
        #else
        Theme.Spacing.s
        #endif
    }

    private func send() {
        conversation.send()
    }

    /// The camera, where this iPhone has one Xenia may use. Refused before, it says where to
    /// allow it instead.
    private var camera: (() -> Void)? {
        #if os(iOS)
        guard CameraPicker.isAvailable else { return nil }
        return {
            if CameraPicker.isDenied { cameraDenied = true } else { showingCamera = true }
        }
        #else
        nil
        #endif
    }

    private var paste: (([NSItemProvider]) -> Void)? {
        #if os(iOS)
        pasteMedia
        #else
        nil
        #endif
    }

    private func sendPhotos(_ items: [PhotosPickerItem]) {
        for item in items {
            conversation.sendAttachment(unreadable: String(localized: "Xenia couldn’t get that item from your library.")) {
                guard let picked = try await item.loadTransferable(type: PickedMedia.self) else { throw CocoaError(.fileNoSuchFile) }
                defer { picked.remove() }
                return try await AttachmentMaker.fromFile(picked.url)
            }
        }
    }

    /// A photo or video already copied here (dropped in): sent, then its copy removed.
    private func send(_ picked: PickedMedia) {
        conversation.sendAttachment(unreadable: String(localized: "Xenia couldn’t read that photo.")) {
            defer { picked.remove() }
            return try await AttachmentMaker.fromFile(picked.url)
        }
    }

    #if os(iOS)
    /// A photo or video just taken: sent, then its copy removed.
    private func send(_ capture: CameraPicker.Capture) {
        conversation.sendAttachment(unreadable: String(localized: "Xenia couldn’t save what you took with the camera.")) {
            let picked = try await capture.file()
            defer { picked.remove() }
            return try await AttachmentMaker.fromFile(picked.url)
        }
    }
    #endif

    #if os(macOS)
    /// A file or picture pasted or dropped on the field. A bubble dragged out of this
    /// conversation and let go over it again isn't a new file.
    private func attach(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if type == .fileURL {
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            let files = urls.filter { !AttachmentActions.isOwnDrag($0) }
            conversation.sendFiles(files)
            return !files.isEmpty
        }
        guard let data = pasteboard.data(forType: type), let kind = UTType(type.rawValue) else { return false }
        conversation.sendAttachment(unreadable: String(localized: "Xenia couldn’t read what you pasted.")) {
            let picked = try await PickedMedia.saving(data, as: kind)
            defer { picked.remove() }
            return try await AttachmentMaker.fromFile(picked.url)
        }
        return true
    }
    #endif

    #if os(iOS)
    /// Photos and videos from the pasteboard, sent as they are.
    private func pasteMedia(_ providers: [NSItemProvider]) {
        for provider in providers where PickedMedia.canLoad(from: provider) {
            conversation.sendAttachment(unreadable: String(localized: "Xenia couldn’t read what you pasted.")) {
                let picked = try await PickedMedia.load(from: provider)
                defer { picked.remove() }
                return try await AttachmentMaker.fromFile(picked.url)
            }
        }
    }
    #endif
}

private struct SendButton: View {
    let isEnabled: Bool
    let isEditing: Bool
    /// Only the focused composer answers ⌘Return: the Mac can show a thread's beside the
    /// conversation's.
    let ownsShortcut: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isEditing ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: size))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, isEnabled ? Color.ownBubble : Color.secondary.opacity(0.35))
                .contentTransition(.symbolEffect(.replace))
                #if os(macOS)
                // The symbol's own box is taller than the circle: pin it, so it centers in the field.
                .frame(width: size, height: size)
                #else
                .fullSizeTarget(size)
                #endif
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .scaleEffect(isEnabled ? 1 : 0.92)
        .animation(Theme.Motion.flip, value: isEnabled)
        .accessibilityLabel(Text(isEditing ? "Save Edit" : "Send"))
        .keyboardShortcut(ownsShortcut ? KeyboardShortcut(.return, modifiers: .command) : nil)
        #if os(macOS)
        .help(isEditing ? "Save Edit (Return)" : "Send (Return)")
        #endif
    }

    private var size: CGFloat {
        #if os(macOS)
        26
        #else
        30
        #endif
    }
}

/// "+" on the leading side: Photos, Files and Poll, and on iPhone, the camera and a photo you
/// copied.
private struct AttachMenu: View {
    @Binding var showingPhotos: Bool
    @Binding var showingFiles: Bool
    @Binding var creatingPoll: Bool
    let camera: (() -> Void)?
    /// Sends the photos or videos on the pasteboard. The field itself only takes text.
    let paste: (([NSItemProvider]) -> Void)?

    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    @State private var canPaste = false
    #endif

    var body: some View {
        Menu {
            if let camera {
                Button("Camera", systemImage: "camera", action: camera)
            }
            Button("Photos & Videos", systemImage: "photo.on.rectangle") { showingPhotos = true }
            Button("Files", systemImage: "folder") { showingFiles = true }
            Button("Poll", systemImage: "chart.bar") { creatingPoll = true }
            #if os(iOS)
            if canPaste, let paste {
                Section {
                    // The system's own Paste: tapping it is consent, so iOS never asks to allow it.
                    PasteButton(supportedContentTypes: [.image, .movie]) { providers in
                        Task { @MainActor in paste(providers) }
                    }
                }
            }
            #endif
        } label: {
            Image(systemName: "plus")
                .font(.system(size: glyph, weight: .semibold))
                .frame(width: side, height: side)
                .contentShape(.circle)
                #if os(iOS)
                .fullSizeTarget(side)
                #endif
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .composerButtonBackground()
        .accessibilityLabel(Text("Attach"))
        #if os(macOS)
        .help("Photos, Files and Polls")
        #endif
        #if os(iOS)
        // Asking whether there's a photo doesn't read it, so nothing shows the paste banner.
        .task(id: scenePhase) {
            canPaste = PickedMedia.isOnPasteboard
            guard scenePhase == .active else { return }
            for await _ in NotificationCenter.default.notifications(named: UIPasteboard.changedNotification) {
                canPaste = PickedMedia.isOnPasteboard
            }
        }
        #endif
    }

    private var side: CGFloat {
        #if os(macOS)
        34
        #else
        38
        #endif
    }

    private var glyph: CGFloat {
        #if os(macOS)
        15
        #else
        17
        #endif
    }
}

/// "Replying to Maya" or "Editing Message", with a way out.
private struct ContextBar: View {
    @Bindable var conversation: ConversationModel

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: conversation.editing != nil ? "pencil" : "arrowshape.turn.up.left.fill")
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                conversation.cancelReplyOrEdit()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: Theme.Metrics.minTarget, minHeight: Theme.Metrics.minTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(conversation.editing != nil ? "Cancel Editing" : "Cancel Reply"))
            #if os(macOS)
            .help(conversation.editing != nil ? "Cancel Editing (Esc)" : "Cancel Reply (Esc)")
            #endif
        }
        .padding(.leading, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.xxs)
        .background(.bar, in: .rect(cornerRadius: 14, style: .continuous))
    }

    private var title: String {
        if conversation.editing != nil { return String(localized: "Editing Message") }
        guard let reply = conversation.replyingTo else { return "" }
        return reply.isOwn ? String(localized: "Replying to Yourself") : String(localized: "Replying to \(reply.senderName)")
    }

    private var snippet: String {
        let message = conversation.editing ?? conversation.replyingTo
        return message.map { Copy.preview(of: $0.body) } ?? ""
    }
}

private extension View {
    #if os(iOS)
    /// Answers touches across a full 44-point target, drawn at its own size, so the field
    /// doesn't grow to fit the target.
    func fullSizeTarget(_ side: CGFloat) -> some View {
        let reach = max(0, (Theme.Metrics.minTarget - side) / 2)
        return padding(reach).contentShape(.circle).padding(-reach)
    }
    #endif

    @ViewBuilder
    func composerFieldBackground() -> some View {
        #if os(iOS)
        self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20, style: .continuous))
        #else
        // Glass, as Messages draws its field on the Mac: a capsule at one line, rounding off as
        // it grows.
        self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18, style: .continuous))
        #endif
    }

    @ViewBuilder
    func composerButtonBackground() -> some View {
        self.glassEffect(.regular.interactive(), in: .circle)
    }
}

#if os(iOS)
/// The view taking the keys, for whether an input method is mid-word.
private enum FirstResponder {
    fileprivate static weak var found: UIResponder?

    static var current: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.xeniaReportFirstResponder), to: nil, from: nil, for: nil)
        return found
    }
}

private extension UIResponder {
    @objc func xeniaReportFirstResponder() {
        FirstResponder.found = self
    }
}
#endif
