import XeniaCore
import SwiftUI

/// A thread, opened over its conversation as Messages opens inline replies: the conversation
/// stays behind, blurred, so you know where you are, and closing returns to the same place.
/// The message that started the thread leads, its replies follow, and the field at the bottom
/// replies in the thread.
struct ThreadOverlay: View {
    let thread: ThreadRef
    let close: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShown = false
    #if os(iOS)
    @State private var grow = ThreadGrow()
    #endif

    var body: some View {
        let room = model.room(thread.roomID)
        ZStack {
            Rectangle()
                .fill(.thickMaterial)
                .ignoresSafeArea()
                .opacity(isShown ? 1 : 0)
                .onTapGesture(perform: dismiss)
                .accessibilityHidden(true)
            #if os(iOS)
            // Always there: UIKit grows it in and shrinks it out (see `ThreadGrow`).
            content(room: room)
            #else
            // Comes and goes as a transition, so nothing stays composited once it's in.
            if isShown {
                content(room: room)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 24)))
            }
            #endif
        }
        .onAppear {
            #if os(iOS)
            grow.origin = model.navigation.threadOrigin
            grow.reduceMotion = reduceMotion
            withAnimation(Theme.Motion.panel) { isShown = true }
            #else
            withAnimation(Theme.Motion.panel) { isShown = true }
            #endif
        }
        #if os(macOS)
        .onExitCommand(perform: dismiss)
        #endif
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, dismiss)
    }

    private var timeline: some View {
        ConversationView(roomID: thread.roomID, focus: .thread(rootEventId: thread.root))
            .id(thread.id)
    }

    #if os(iOS)
    /// A real navigation bar: the timeline is a UIKit view, and only UIKit's bar sits above it
    /// with the system's soft edge as replies pass under.
    private func content(room: RoomSummary?) -> some View {
        NavigationStack {
            timeline
                .navigationTitle("Thread")
                .navigationSubtitle(room?.name ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close Thread", systemImage: "xmark", action: dismiss)
                    }
                }
                .background { GrowProbe(grow: grow) }
        }
        .background(.clear)
        .containerBackground(.clear, for: .navigation)
    }
    #else
    private func content(room: RoomSummary?) -> some View {
        MacThreadColumn(thread: thread, room: room, close: dismiss)
    }
    #endif

    private func dismiss() {
        #if os(iOS)
        withAnimation(Theme.Motion.row) { isShown = false }
        grow.shrink {
            model.navigation.threadOrigin = nil
            close()
        }
        #else
        withAnimation(Theme.Motion.row) { isShown = false } completion: { close() }
        #endif
    }
}

#if os(iOS)
/// Grows the thread out of the "Replies" button it was opened from, and shrinks it back there on
/// closing, as a Messages reply view opens from its bubble. UIKit does it: SwiftUI's scale
/// doesn't reach into a navigation stack, which UIKit draws.
@MainActor
final class ThreadGrow {
    /// Where it was opened from, in the window; the middle of the screen when unknown.
    var origin: CGPoint?
    var reduceMotion = false
    private weak var view: UIView?

    /// The thread's view is in place: start it small at the origin and grow it.
    func attach(_ view: UIView) {
        guard self.view !== view else { return }
        self.view = view
        view.alpha = 0
        // On the next turn, once it's been laid out where it ends.
        DispatchQueue.main.async {
            view.superview?.layoutIfNeeded()
            if !self.reduceMotion { view.transform = self.shrunk(view) }
            UIView.animate(springDuration: self.reduceMotion ? 0.25 : 0.5, bounce: self.reduceMotion ? 0 : 0.2, initialSpringVelocity: 0, delay: 0, options: [.allowUserInteraction]) {
                view.transform = .identity
            }
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                view.alpha = 1
            }
        }
    }

    func shrink(then done: @escaping () -> Void) {
        guard let view else { return done() }
        UIView.animate(springDuration: 0.34, bounce: 0, initialSpringVelocity: 0, delay: 0, options: [.beginFromCurrentState]) {
            if !self.reduceMotion { view.transform = self.shrunk(view) }
        } completion: { _ in done() }
        UIView.animate(withDuration: 0.2, delay: 0.08, options: [.curveEaseOut, .beginFromCurrentState]) {
            view.alpha = 0
        }
    }

    /// A third of its size, centered on the origin.
    private func shrunk(_ view: UIView) -> CGAffineTransform {
        let scale: CGFloat = 0.3
        guard let window = view.window, let superview = view.superview else { return CGAffineTransform(scaleX: 0.9, y: 0.9) }
        let point = superview.convert(origin ?? CGPoint(x: window.bounds.midX, y: window.bounds.midY), from: window)
        let center = view.center
        return CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: (1 - scale) * (point.x - center.x), y: (1 - scale) * (point.y - center.y)))
    }
}

/// Finds the thread's navigation view for `ThreadGrow`.
private struct GrowProbe: UIViewRepresentable {
    let grow: ThreadGrow

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.grow = grow
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        weak var grow: ThreadGrow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var responder: UIResponder? = self
            while let current = responder {
                if let navigation = current as? UINavigationController {
                    grow?.attach(navigation.view)
                    return
                }
                responder = current.next
            }
        }
    }
}
#endif

/// Everything threads need from a conversation screen, on either platform: the thread open
/// over it, and the list of its threads.
extension View {
    func threadPresentation(roomID: String) -> some View {
        modifier(ThreadPresentation(roomID: roomID))
    }
}

private struct ThreadPresentation: ViewModifier {
    let roomID: String
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chosenRoot: String?
    #if os(macOS)
    @State private var isSideBySide = true
    private nonisolated static let panelWidth: CGFloat = 400

    private func closeThread() {
        model.navigation.thread = nil
    }
    #endif

    func body(content: Content) -> some View {
        let navigation = model.navigation
        content
            #if os(iOS)
            .fullScreenCover(item: openThread) { thread in
                ThreadOverlay(thread: thread) { closeThread() }
                    .presentationBackground(.clear)
            }
            .sheet(isPresented: showingList, onDismiss: openChosenThread) {
                NavigationStack {
                    ThreadListView(roomID: roomID) { root in
                        // Opens once the sheet is gone: one presentation at a time.
                        chosenRoot = root
                        navigation.threadsRoomID = nil
                    }
                    .navigationTitle("Threads")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", role: .close) { navigation.threadsRoomID = nil }
                        }
                    }
                }
                // Most lists fit at half height, with the conversation still in view; pull up for more.
                .presentationDetents([.medium, .large])
            }
            #else
            .safeAreaInset(edge: .trailing, spacing: 0) {
                if isSideBySide, let thread = navigation.thread, thread.roomID == roomID {
                    ThreadPanel(thread: thread) { closeThread() }
                        .frame(width: Self.panelWidth)
                        .padding([.vertical, .trailing], Theme.Spacing.s)
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay {
                if !isSideBySide, let thread = navigation.thread, thread.roomID == roomID {
                    ThreadOverlay(thread: thread) { navigation.thread = nil }
                }
            }
            .animation(Theme.Motion.panel, value: navigation.thread)
            // Wide enough for both: the thread sits beside the conversation. Only which layout
            // to use comes from the width; nothing is sized from it.
            .onGeometryChange(for: Bool.self) { $0.size.width >= Self.panelWidth + 440 } action: { wide in
                isSideBySide = wide
                navigation.threadCoversConversation = !wide
            }
            #endif
    }

    #if os(iOS)
    /// The cover appears without UIKit's slide; the overlay fades itself in, as Messages does.
    private var openThread: Binding<ThreadRef?> {
        Binding(
            get: { model.navigation.thread?.roomID == roomID ? model.navigation.thread : nil },
            set: { model.navigation.thread = $0 }
        )
    }

    private func closeThread() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.navigation.thread = nil }
    }

    private func openChosenThread() {
        guard let root = chosenRoot else { return }
        chosenRoot = nil
        model.navigation.openThread(roomID: roomID, root: root)
    }

    private var showingList: Binding<Bool> {
        Binding(
            get: { model.navigation.threadsRoomID == roomID },
            set: { if !$0 { model.navigation.threadsRoomID = nil } }
        )
    }
    #endif
}

extension Navigation {
    /// Opens a thread over its conversation, without UIKit's slide on iPhone. On the Mac the
    /// panel slides in as it slides out.
    func openThread(roomID: String, root: String) {
        #if os(iOS)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { thread = ThreadRef(roomID: roomID, root: root) }
        #else
        thread = ThreadRef(roomID: roomID, root: root)
        #endif
    }
}

#if os(macOS)
/// A thread on the Mac: its header, the replies, and the field that replies in the thread. Shown
/// beside the conversation in a wide window, over it in a narrow one.
struct MacThreadColumn: View {
    let thread: ThreadRef
    let room: RoomSummary?
    let close: () -> Void

    @State private var headerHeight: CGFloat = 44

    var body: some View {
        ZStack(alignment: .top) {
            ConversationView(roomID: thread.roomID, focus: .thread(rootEventId: thread.root))
                .id(thread.id)
                .safeAreaInset(edge: .top, spacing: 0) {
                    Color.clear.frame(height: headerHeight)
                }
            // Above the timeline, so replies fade as they pass under it.
            header
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.s) {
            if let room {
                AvatarView(name: room.name, seed: room.avatarSeed, url: room.avatarUrl, size: Theme.Metrics.headerAvatar, isRoom: room.isRoom)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Thread")
                    .font(.headline)
                if let room {
                    Text(room.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Theme.Spacing.s)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(Text("Close Thread"))
            .help("Close Thread (Esc)")
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .background {
            // Replies fade as they pass under the header, as under the conversation's toolbar.
            Rectangle()
                .fill(.background)
                .mask {
                    LinearGradient(
                        stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.9), location: 0.55), .init(color: .clear, location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                }
                .padding(.bottom, -Theme.Spacing.xl)
                .allowsHitTesting(false)
        }
    }
}

/// The thread beside its conversation, in a wide window: both stay readable and live, the
/// conversation on the left, the thread as a card on the right.
private struct ThreadPanel: View {
    let thread: ThreadRef
    let close: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        MacThreadColumn(thread: thread, room: model.room(thread.roomID), close: close)
            .background(.background)
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.08), radius: 10, y: 2)
            .onExitCommand(perform: close)
    }
}
#endif
