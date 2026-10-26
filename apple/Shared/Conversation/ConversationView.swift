import XeniaCore
import SwiftUI

/// A conversation or a thread: the timeline, newest at the bottom, and the composer.
struct ConversationView: View {
    let roomID: String
    let focus: TimelineFocus
    /// Opens a thread from its root, over the conversation.
    var openThread: (String) -> Void = { _ in }

    @Environment(AppModel.self) private var model
    @State private var conversation: ConversationModel
    @State private var isOpen = false

    init(roomID: String, focus: TimelineFocus = .live, openThread: @escaping (String) -> Void = { _ in }) {
        self.roomID = roomID
        self.focus = focus
        self.openThread = openThread
        _conversation = State(initialValue: ConversationModel(roomID: roomID, focus: focus))
    }

    var body: some View {
        TimelineScroll(conversation: conversation, openThread: openThread)
            .environment(conversation)
            .task {
                // Opened from the saved list at launch: the session is still on its way.
                await model.session.wait()
                guard !Task.isCancelled else { return }
                await conversation.open(model: model)
                isOpen = true
                sendDroppedFiles()
            }
            .onChange(of: model.navigation.droppedFiles) { sendDroppedFiles() }
            .onDisappear { conversation.close() }
            .errorAlert("Something Went Wrong", message: $conversation.errorMessage)
            .sheet(item: $conversation.forwarding) { message in
                ForwardSheet(message: message, fromRoomID: roomID)
                    .environment(conversation)
            }
            .sheet(item: $conversation.reporting) { message in
                ReportSheet(message: message)
                    .environment(conversation)
            }
            #if os(iOS)
            .fullScreenCover(item: $conversation.lifted, onDismiss: {
                let action = conversation.afterLift
                conversation.afterLift = nil
                action?()
            }) { lifted in
                LiftedMessageView(lifted: lifted)
                    .environment(conversation)
                    .presentationBackground(.clear)
            }
            #endif
            #if os(iOS)
            .sensoryFeedback(trigger: conversation.feedback) { _, new in new?.haptic }
            #endif
            .alert(
                "Delete This Message?",
                isPresented: Binding(get: { conversation.deleting != nil }, set: { if !$0 { conversation.deleting = nil } }),
                presenting: conversation.deleting
            ) { message in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { conversation.delete(message) }
            } message: { _ in
                Text("It’s removed for everyone in the conversation.")
            }
            .sheet(item: $conversation.viewingReceipts) { message in
                ReadReceiptsSheet(message: message)
                    .environment(conversation)
            }
            #if os(iOS)
            .sheet(item: $conversation.selectingText) { message in
                SelectTextSheet(message: message)
            }
            #endif
            .sheet(isPresented: $conversation.isCreatingPoll) {
                NewPollSheet()
                    .environment(conversation)
            }
            .alert(
                "End This Poll?",
                isPresented: Binding(get: { conversation.endingPoll != nil }, set: { if !$0 { conversation.endingPoll = nil } }),
                presenting: conversation.endingPoll
            ) { message in
                Button("Cancel", role: .cancel) {}
                Button("End Poll", role: .destructive) { conversation.endPoll(message) }
            } message: { _ in
                Text("Everyone will see the results, and no one can vote after that.")
            }
    }

    /// Files dropped on this conversation's row in the sidebar, sent as a drop on it would be.
    private func sendDroppedFiles() {
        guard isOpen, conversation.threadRoot == nil else { return }
        let files = model.navigation.takeDroppedFiles(for: roomID)
        if !files.isEmpty { conversation.sendFiles(files) }
    }
}

private struct TimelineScroll: View {
    @Bindable var conversation: ConversationModel
    let openThread: (String) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isNearBottom = true
    @State private var previewer = AttachmentPreviewer()
    #if os(macOS)
    @Environment(\.mediaViewer) private var mediaViewer
    #endif
    @State private var members: [Member] = []
    @State private var scroller = TimelineScroller()
    @State private var insets = EdgeInsets()
    @State private var isVisible = false

    var body: some View {
        let room = model.room(conversation.roomID)
        let context = ConversationContext(
            isGroup: !(room?.isDm ?? false),
            isThread: conversation.threadRoot != nil,
            openThread: openThread,
            scrollToEvent: scrollToEvent,
            previewer: previewer
        )

        timeline(context: context)
            .overlay {
                if conversation.failedToOpen {
                    ContentUnavailableView {
                        Label("Couldn’t Open the Conversation", systemImage: "exclamationmark.bubble")
                    } description: {
                        Text("Check your connection, then try again.")
                    } actions: {
                        Button("Try Again") { Task { await conversation.retryOpen() } }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // The animation stays inside the overlay: on the scroll view itself it would also
                // animate the scroll position, snapping someone reading history back to the bottom.
                let showsJump = !isNearBottom || !conversation.isAtEnd
                ZStack {
                    if showsJump {
                        JumpToLatestButton(count: conversation.newMessagesBelow, action: jumpToLatest)
                            .padding(Theme.Spacing.l)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .animation(Theme.Motion.panel, value: showsJump)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let room, room.isInvite {
                    InvitationBar(room: room)
                } else if !conversation.failedToOpen {
                    ComposerView(conversation: conversation, members: members)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                // Files dropped on the conversation are sent, as in Messages.
                // A bubble dragged out and let go over the conversation again isn't a new file.
                let files = urls.filter { $0.isFileURL && !AttachmentActions.isOwnDrag($0) }
                conversation.sendFiles(files)
                return !files.isEmpty
            }
            .onAppear {
                isVisible = true
                if isNearBottom { markReadIfVisible() }
                previewer.attach(media: model.media)
                previewer.attachments = { [conversation] in MessageAttachment.all(in: conversation.rows) }
                #if os(macOS)
                previewer.viewer = mediaViewer
                #endif
            }
            .onDisappear {
                // Covered by a thread, Details or another tab: what arrives now stays unread.
                isVisible = false
                // On iPhone, Quick Look covering the conversation is no reason to stop.
                guard !previewer.isShowing else { return }
                previewer.dismiss()
                AudioPlayback.shared.stopIfPlaying(in: conversation.rows)
            }
            .onChange(of: conversation.rows.last?.id) {
                if isNearBottom { reachedBottom() }
            }
            .onChange(of: conversation.sends) {
                // What I send, I see: back to the bottom, even from history.
                scrollToBottom(animated: true)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, isNearBottom { markReadIfVisible() }
            }
            .onChange(of: model.isActive) { _, active in
                if active, isNearBottom { markReadIfVisible() }
            }
            .onChange(of: model.navigation.thread) { _, thread in
                if thread == nil, isNearBottom { markReadIfVisible() }
            }
            .task(id: conversation.roomID) {
                await model.session.wait()
                guard !Task.isCancelled else { return }
                members = (try? await model.client.members(roomId: conversation.roomID)) ?? []
            }
            #if os(macOS)
            .onChange(of: model.navigation.menuRequest) { _, request in
                // The conversation's own timeline answers, not a thread's.
                guard conversation.threadRoot == nil, request == .tapback || request == .jumpToLatest else { return }
                model.navigation.menuRequest = nil
                if request == .tapback { tapbackLatest() } else { jumpToLatest() }
            }
            #endif
    }

    /// A collection view on iPhone and a scroll view of reused rows on the Mac, for Messages'
    /// scrolling. It runs under the bars and the composer, with the safe area as its insets, so
    /// messages pass under the glass.
    private func timeline(context: ConversationContext) -> some View {
        TimelineCollection(
            conversation: conversation,
            context: context,
            insets: insets,
            springs: springsBubbles,
            scroller: scroller
        ) { edges in
            if edges.isNearBottom != isNearBottom {
                isNearBottom = edges.isNearBottom
                if edges.isNearBottom { reachedBottom() }
            }
        }
        #if os(macOS)
        .overlay(alignment: .top) {
            // Messages blur softly as they pass under the toolbar, as the system's scroll edge
            // does; the AppKit timeline doesn't get that edge on its own.
            SoftScrollEdge(edge: .top)
                .frame(height: insets.top + Theme.Spacing.xl)
                .ignoresSafeArea(edges: .top)
        }
        #endif
        // Sideways the safe area still applies: the Mac's sidebar, the iPhone's landscape notch.
        .ignoresSafeArea(edges: .vertical)
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets = $0 }
    }

    /// Bubbles give as they scroll on iPhone, as in Messages; the Mac's Messages keeps them still.
    private var springsBubbles: Bool {
        #if os(iOS)
        !reduceMotion
        #else
        false
        #endif
    }

    #if os(macOS)
    /// Brings the newest message from someone else into view and opens its Tapbacks.
    private func tapbackLatest() {
        guard let latest = conversation.rows.last(where: { $0.message.map { !$0.isOwn && $0.eventId != nil } ?? false }) else { return }
        scroller.scroll(to: latest.id, anchor: .center, animated: false)
        DispatchQueue.main.async {
            MessageMenuHost.host(for: latest.id)?.popUp()
        }
    }
    #endif

    private func scrollToBottom(animated: Bool) {
        scroller.scrollToBottom(animated: animated)
    }

    private func scrollToEvent(_ eventID: String) {
        guard let row = conversation.rows.first(where: { $0.message?.eventId == eventID }) else { return }
        scroller.scroll(to: row.id, anchor: .center, animated: true)
    }

    private func reachedBottom() {
        conversation.resetNewMessages()
        markReadIfVisible()
        if !conversation.isAtEnd { conversation.loadNewer() }
    }

    private func jumpToLatest() {
        if !conversation.isAtEnd {
            // A jump into the past: reopen live.
            conversation.loadNewer()
        }
        scrollToBottom(animated: true)
        conversation.resetNewMessages()
    }

    private func markReadIfVisible() {
        // On the Mac a window behind other apps is still "active": what arrives there waits
        // until Xenia comes to the front, as in Messages.
        // A thread open over this conversation covers it, though it stays on screen.
        let isCovered = conversation.threadRoot == nil && model.navigation.threadCoversConversation
            && model.navigation.thread?.roomID == conversation.roomID
        guard isVisible, !isCovered, scenePhase == .active, model.isActive, conversation.isReady, conversation.isAtEnd else { return }
        conversation.markRead()
    }
}

/// The round button that returns to the newest message, with how many arrived meanwhile.
private struct JumpToLatestButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.body.weight(.semibold))
                .frame(width: Self.side, height: Self.side)
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text(count, format: .number)
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(.tint, in: .capsule)
                            .offset(x: 6, y: -6)
                            .contentTransition(.numericText(value: Double(count)))
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .animation(Theme.Motion.flip, value: count)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(count > 0 ? Text("Jump to Latest, ^[\(count) new message](inflect: true)") : Text("Jump to Latest"))
        #if os(macOS)
        .help("Jump to Latest (⌥⌘↓)")
        #endif
    }

    #if os(iOS)
    private static let side = Theme.Metrics.minTarget
    #else
    private static let side: CGFloat = 40
    #endif
}

#if os(iOS)
private extension ConversationModel.Feedback {
    var haptic: SensoryFeedback {
        switch kind {
        case .sent, .reacted: .impact(weight: .light)
        case .voted: .selection
        case .succeeded: .success
        }
    }
}
#endif

/// Where the composer would be, for an invitation: what it is, and the answer.
private struct InvitationBar: View {
    let room: RoomSummary

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            Text(Copy.invitation(from: room.inviterName, isDirect: room.isDm))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            InviteButtons(roomID: room.id, inRow: false)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.l)
        .background(.bar)
    }
}
