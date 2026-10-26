import Foundation
import Observation
import OSLog
import XeniaCore

/// One open conversation or thread: its rows from the core, the composer, and what you can do.
@Observable
final class ConversationModel {
    let roomID: String
    let focus: TimelineFocus

    private static let log = Logger(subsystem: "dev.xenia.matrix", category: "conversation")

    private(set) var rows: [TimelineRow] = [] {
        didSet { rowsRevision &+= 1 }
    }
    /// Bumped with every new set of rows, so the timeline can tell in O(1) whether they changed.
    @ObservationIgnored private(set) var rowsRevision = 0
    private(set) var isReady = false
    private(set) var isLoadingOlder = false
    private(set) var isAtStart = false
    /// The top is where I joined: the room keeps earlier messages from new members.
    private(set) var historyStartsAtJoin = false
    private(set) var isAtEnd = true
    private(set) var focusedRowID: String?
    /// The conversation couldn't be opened (left elsewhere, or the stores failed): there's
    /// nothing to show or send to until it's tried again.
    private(set) var failedToOpen = false
    /// Who's typing right now, not including me.
    private(set) var typing: [Reader] = []
    /// Bumped when a row the person should see arrives while they're reading history.
    private(set) var newMessagesBelow = 0
    /// Bumped on every send, so the conversation scrolls down to show it.
    private(set) var sends = 0
    /// The latest haptic answering something the person did here: never set by what arrives.
    private(set) var feedback: Feedback?

    // Composer.
    var text = "" {
        didSet { textChanged(from: oldValue) }
    }
    var mentions: [MentionRef] = []
    private(set) var replyingTo: TimelineMessage?
    private(set) var editing: TimelineMessage?
    var errorMessage: String?

    // What the conversation presents for a message: rows are recycled, so they can't.
    var forwarding: TimelineMessage?
    var reporting: TimelineMessage?
    /// One of my messages, opened to see who has read it.
    var viewingReceipts: TimelineMessage?
    /// A message to confirm deleting.
    var deleting: TimelineMessage?
    #if os(iOS)
    /// A message held to react or act on it.
    var lifted: LiftedMessage?
    /// What was chosen from a lifted message, done once it has settled back.
    @ObservationIgnored var afterLift: (() -> Void)?
    #endif
    var endingPoll: TimelineMessage?
    /// iPhone: a message opened to select part of its text.
    var selectingText: TimelineMessage?
    var isCreatingPoll = false

    @ObservationIgnored private var controller: TimelineController?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var draftTask: Task<Void, Never>?
    @ObservationIgnored private var draftArrivals: NSObjectProtocol?
    @ObservationIgnored private var typingTask: Task<Void, Never>?
    @ObservationIgnored private var restoringDraft = false
    @ObservationIgnored private var draftLoaded = false
    @ObservationIgnored private var isOpening = false
    @ObservationIgnored private var lastMessageID: String?
    /// One history request at a time: the core's own flag only arrives with its next update.
    @ObservationIgnored private var requestingOlder = false
    @ObservationIgnored private var requestingNewer = false
    /// The newest row this conversation last marked read.
    @ObservationIgnored private var markedRowID: String?

    isolated deinit {
        if let draftArrivals { NotificationCenter.default.removeObserver(draftArrivals) }
    }

    init(roomID: String, focus: TimelineFocus) {
        self.roomID = roomID
        self.focus = focus
        if case .event = focus { isAtEnd = false }
    }

    var threadRoot: String? {
        if case .thread(let root) = focus { root } else { nil }
    }

    // MARK: Lifecycle

    func open(model: AppModel) async {
        // One open at a time: Try Again and the view's own task can both ask.
        guard controller == nil, !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        self.model = model
        // The draft is local and quick; the timeline can take seconds. Load the draft first so
        // nothing typed meanwhile overwrites it.
        if !draftLoaded {
            if let draft = await model.client.loadDraft(roomId: roomID, threadRoot: threadRoot), text.isEmpty {
                restoringDraft = true
                text = draft
                restoringDraft = false
            }
            draftLoaded = true
        }
        followDraftArrivals()
        let events = TimelineEvents()
        events.conversation = self
        do {
            controller = try await model.client.timeline(roomId: roomID, focus: focus, listener: events)
            failedToOpen = false
        } catch {
            failedToOpen = true
            isReady = true
        }
    }

    /// Opens the conversation again after it failed to.
    func retryOpen() async {
        guard let model, controller == nil else { return }
        failedToOpen = false
        isReady = false
        await open(model: model)
    }

    /// The conversation left the screen (closed, or covered by Details or a thread): keep the
    /// draft and stop typing. The timeline stays open until the conversation goes away for good,
    /// so coming back from Details doesn't load it again.
    func close() {
        saveDraftNow()
        typingTask?.cancel()
        if let controller {
            Task { await controller.setTyping(typing: false) }
        }
    }

    func apply(_ update: TimelineUpdate) {
        let newest = update.rows.last(where: \.isMessage)?.message
        // Count only other people's new messages; my own sends scroll me down anyway.
        if let lastMessageID, let newest, newest.id != lastMessageID, !newest.isOwn, isReady {
            newMessagesBelow += 1
        }
        lastMessageID = newest?.id
        rows = update.rows
        warmFaces(in: update.rows)
        warmBlurs(in: update.rows)
        if let model, model.preferences.fetchesLinkPreviews(encrypted: model.room(roomID)?.isEncrypted ?? true) {
            // As messages arrive, not when they're scrolled to, so cards are ready to show.
            model.linkPreviews.prefetch(update.rows) { [weak self] ids in self?.layOutAgain(ids) }
        }
        isReady = update.isReady
        isLoadingOlder = update.isLoadingOlder
        isAtStart = update.isAtStart
        historyStartsAtJoin = update.historyStartsAtJoin
        isAtEnd = update.isAtEnd
        if focusedRowID == nil { focusedRowID = update.focusedRowId }
    }

    /// Senders whose faces were already looked for on disk.
    @ObservationIgnored private var warmedFaces: Set<String> = []

    /// Reads the faces kept on disk for new senders off the main thread, so their rows find them
    /// in memory rather than reading the disk while they draw.
    private func warmFaces(in rows: [TimelineRow]) {
        guard let model else { return }
        var keys: [String] = []
        for row in rows {
            guard let url = row.message?.senderAvatarUrl, warmedFaces.insert(url).inserted else { continue }
            keys.append(MediaLoader.avatarKey(url, points: Theme.Metrics.messageAvatar))
        }
        guard !keys.isEmpty else { return }
        Task { await model.media.warmAvatars(keys) }
    }

    /// Photos' BlurHash previews already decoded.
    @ObservationIgnored private var warmedBlurs: Set<String> = []

    /// Decodes new photos' BlurHash previews off the main thread, so their bubbles draw them at
    /// once instead of decoding while they draw.
    private func warmBlurs(in rows: [TimelineRow]) {
        var hashes: [String] = []
        for row in rows {
            guard let hash = row.message?.blurhash, warmedBlurs.insert(hash).inserted else { continue }
            hashes.append(hash)
        }
        guard !hashes.isEmpty else { return }
        Task { await BlurPreview.decode(hashes) }
    }

    func apply(typing people: [Reader]) {
        typing = people
    }

    func resetNewMessages() {
        newMessagesBelow = 0
    }

    // MARK: History

    /// Older messages, when the person nears the top. Returns at once if a request is already
    /// out or the beginning is loaded.
    func loadOlder() {
        guard let controller, isReady, !requestingOlder, !isLoadingOlder, !isAtStart else { return }
        requestingOlder = true
        Task {
            await controller.loadOlder()
            requestingOlder = false
        }
    }

    func loadNewer() {
        guard let controller, !requestingNewer, !isAtEnd else { return }
        requestingNewer = true
        Task {
            await controller.loadNewer()
            requestingNewer = false
        }
    }

    /// Marks the conversation read, once per newest message.
    func markRead() {
        guard let controller, let newest = rows.last?.id, newest != markedRowID else { return }
        markedRowID = newest
        Task { await controller.markRead() }
        model?.notifier.clear(roomID: roomID)
    }

    // MARK: Composer

    var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func reply(to message: TimelineMessage) {
        // Replying ends an edit: the edited text leaves and what was being typed comes back.
        if editing != nil {
            editing = nil
            restoreStashedDraft()
        }
        replyingTo = message
    }

    /// What was typed before an edit began, restored when the edit ends.
    @ObservationIgnored private var stashedDraft: (text: String, mentions: [MentionRef])?

    func edit(_ message: TimelineMessage) {
        guard case .text(_, let plain, _, _) = message.content else { return }
        if editing == nil { stashedDraft = (text, mentions) }
        replyingTo = nil
        editing = message
        // As it was typed, formatting and mentions included, so the edit doesn't lose them.
        let editable = controller?.editableText(rowId: message.id)
        restoringDraft = true
        text = editable?.text ?? plain
        mentions = editable?.mentions ?? []
        restoringDraft = false
    }

    private func restoreStashedDraft() {
        guard let stash = stashedDraft else { return }
        stashedDraft = nil
        restoringDraft = true
        text = stash.text
        mentions = stash.mentions
        restoringDraft = false
    }

    /// Edits my newest message (↑ in an empty composer on the Mac).
    func editLastMessage() -> Bool {
        guard text.isEmpty else { return false }
        let mine = rows.reversed().compactMap(\.message).first { $0.isOwn && $0.canEdit }
        guard let mine else { return false }
        edit(mine)
        return true
    }

    func cancelReplyOrEdit() {
        let wasEditing = editing != nil
        replyingTo = nil
        editing = nil
        if wasEditing { restoreStashedDraft() }
    }

    func send() {
        guard canSend, let controller else { return }
        let message = composeMessage(text: text, mentions: mentions)
        let replyID = replyingTo?.id
        let editID = editing?.id
        let typed = (text: text, mentions: mentions, reply: replyingTo, edit: editing)
        if editID == nil { sends += 1 }
        give(.sent)
        text = ""
        mentions = []
        replyingTo = nil
        editing = nil
        if editID != nil {
            // The edit is sent; whatever was being typed before it comes back.
            restoreStashedDraft()
        } else {
            saveDraftNow()
        }
        Task {
            await controller.setTyping(typing: false)
            do {
                if let editID {
                    try await controller.edit(rowId: editID, message: message)
                } else {
                    try await controller.send(message: message, replyTo: replyID)
                }
            } catch {
                fail(error)
                giveBack(typed)
            }
        }
    }

    /// A send the core refused (nothing was queued): the words go back in the composer. A new
    /// message only goes back into an empty one; a failed edit reopens, keeping what's there.
    private func giveBack(_ typed: (text: String, mentions: [MentionRef], reply: TimelineMessage?, edit: TimelineMessage?)) {
        guard replyingTo == nil, editing == nil else { return }
        if let edit = typed.edit {
            stashedDraft = (text, mentions)
            editing = edit
        } else {
            guard text.isEmpty else { return }
            replyingTo = typed.reply
        }
        restoringDraft = true
        text = typed.text
        mentions = typed.mentions
        restoringDraft = false
        if typed.edit == nil { saveDraftNow() }
    }

    func insertMention(_ member: Member, replacingQuery query: String) {
        let token = "@" + query
        if text.hasSuffix(token) {
            text.removeLast(token.count)
        }
        text += "@\(member.name) "
        if !mentions.contains(where: { $0.userId == member.userId }) {
            mentions.append(MentionRef(userId: member.userId, name: member.name))
        }
    }

    /// Attachments go out one after another, in the order they were chosen, even when one takes
    /// longer to prepare (a video's poster frame).
    @ObservationIgnored private var attachmentQueue: Task<Void, Never>?

    /// Sends a file once `prepare` has made it ready (off the main thread). `unreadable` is what
    /// to say if it can't be.
    func sendAttachment(unreadable: String, prepare: @escaping () async throws -> Attachment) {
        guard let controller else { return }
        let replyID = replyingTo?.id
        replyingTo = nil
        sends += 1
        give(.sent)
        let previous = attachmentQueue
        attachmentQueue = Task {
            await previous?.value
            let attachment: Attachment
            do {
                attachment = await AttachmentMaker.withVideoDetails(try await prepare())
            } catch {
                errorMessage = unreadable
                return
            }
            Self.log.info("Sending \(attachment.filename, privacy: .private) (\(attachment.mimetype, privacy: .public))")
            do {
                try await controller.sendAttachment(attachment: attachment, replyTo: replyID)
            } catch {
                Self.log.error("Sending an attachment failed: \(String(describing: error), privacy: .private)")
                fail(error)
            }
            // Queued or refused, the core no longer needs the temporary copy.
            AttachmentMaker.remove(attachment)
        }
    }

    /// Files from Finder, Files or a drop.
    func sendFiles(_ urls: [URL]) {
        for url in urls {
            sendAttachment(unreadable: String(localized: "Xenia couldn’t read “\(url.lastPathComponent)”.")) {
                try await AttachmentMaker.fromFile(url)
            }
        }
    }

    private func textChanged(from old: String) {
        guard !restoringDraft, text != old else { return }
        scheduleDraftSave()
        guard model?.preferences.sendTypingNotifications ?? true, let controller else { return }
        let typing = !text.isEmpty
        typingTask?.cancel()
        typingTask = Task {
            await controller.setTyping(typing: typing)
            guard typing else { return }
            // "Stopped" after a pause, as other clients expect.
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await controller.setTyping(typing: false)
        }
    }

    private func scheduleDraftSave() {
        guard draftLoaded else { return }
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveDraftNow()
        }
    }

    private func saveDraftNow() {
        draftTask?.cancel()
        guard let model, draftLoaded, editing == nil else { return }
        let text = self.text
        let roomID = self.roomID
        let root = threadRoot
        Task { await model.saveDraft(roomID: roomID, threadRoot: root, text: text) }
    }

    /// A draft typed on another device shows here if nothing's typed here: it never replaces words
    /// already in the composer.
    private func followDraftArrivals() {
        guard draftArrivals == nil else { return }
        draftArrivals = NotificationCenter.default.addObserver(forName: .xeniaDraftArrived, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo
            guard let room = info?["room"] as? String, let text = info?["text"] as? String else { return }
            let thread = info?["thread"] as? String
            MainActor.assumeIsolated {
                guard let self, room == self.roomID, thread == self.threadRoot,
                      self.editing == nil, self.text.isEmpty, !text.isEmpty else { return }
                self.restoringDraft = true
                self.text = text
                self.restoringDraft = false
            }
        }
    }

    // MARK: Message actions

    /// `feedback` is off where the Tapback is felt already (a lifted message, over the conversation).
    func toggleReaction(_ key: String, on message: TimelineMessage, feedback: Bool = true) {
        guard let controller else { return }
        if feedback { give(.reacted) }
        perform { try await controller.toggleReaction(rowId: message.id, key: key) }
    }

    func delete(_ message: TimelineMessage) {
        guard let controller else { return }
        perform { try await controller.delete(rowId: message.id) }
    }

    func retry(_ message: TimelineMessage) {
        guard let controller else { return }
        perform { try await controller.retry(rowId: message.id) }
    }

    func setPinned(_ message: TimelineMessage, _ pinned: Bool) {
        guard let controller else { return }
        perform {
            try await controller.setPinned(rowId: message.id, pinned: pinned)
            self.give(.succeeded)
        }
    }

    /// Votes for an answer (see `PollVote.selection`).
    func vote(_ answerID: String, in message: TimelineMessage) {
        guard let controller, case .poll(_, let answers, _, let maxSelections, _, let isEnded, _) = message.content,
              !isEnded,
              let selection = PollVote.selection(tapping: answerID, answers: answers, maxSelections: maxSelections)
        else { return }
        give(.voted)
        perform { try await controller.vote(rowId: message.id, answerIds: selection) }
    }

    func endPoll(_ message: TimelineMessage) {
        guard let controller else { return }
        perform { try await controller.endPoll(rowId: message.id) }
    }

    /// Starts a poll. Throws so the poll sheet can stay open with what was typed.
    func createPoll(question: String, answers: [String], allowsMultiple: Bool, showsResults: Bool) async throws {
        guard let controller else { throw XeniaError.NotFound }
        let answers = answers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        try await controller.createPoll(
            question: question.trimmingCharacters(in: .whitespacesAndNewlines),
            answers: answers,
            maxSelections: allowsMultiple ? UInt32(answers.count) : 1,
            isDisclosed: showsResults
        )
        sends += 1
        give(.sent)
    }

    /// Sends a copy of a message to another conversation.
    func forward(_ message: TimelineMessage, to roomID: String) async throws {
        guard let controller else { throw XeniaError.NotFound }
        try await controller.forward(rowId: message.id, toRoomId: roomID)
    }

    /// Copies a matrix.to link to the message.
    func copyLink(to message: TimelineMessage) {
        guard let controller else { return }
        perform { self.copy(try await controller.permalink(rowId: message.id)) }
    }

    /// Copies text: nothing on screen changes, so the copy is felt.
    func copy(_ text: String) {
        Pasteboard.copy(text)
        give(.succeeded)
    }

    /// Runs an action from a message, saying what went wrong if it fails.
    func perform(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { fail(error) }
        }
    }

    // MARK: Feedback

    /// A haptic answering the person, with a serial so the same kind twice still plays twice.
    struct Feedback: Equatable {
        enum Kind { case sent, reacted, voted, succeeded }
        let kind: Kind
        let serial: Int
    }

    func give(_ kind: Feedback.Kind) {
        feedback = Feedback(kind: kind, serial: (feedback?.serial ?? 0) &+ 1)
    }

    /// An action of mine failed: say what happened. The alert showing it is felt as an error.
    func fail(_ error: Error) {
        errorMessage = Copy.error(error)
    }

    /// Reports a message to the server's administrators. Throws so the report sheet can say so.
    func report(_ message: TimelineMessage, reason: String) async throws {
        guard let controller else { throw XeniaError.NotFound }
        try await controller.report(rowId: message.id, reason: reason.isEmpty ? nil : reason)
    }

    /// Bumped when rows draw differently without changing (a link's card arrived), so the
    /// timeline measures them again.
    private(set) var layoutRevision = 0
    @ObservationIgnored private var rowsToLayOut: Set<String> = []

    func layOutAgain(_ ids: [String]) {
        rowsToLayOut.formUnion(ids)
        layoutRevision += 1
    }

    /// The rows to measure again, once.
    func takeRowsToLayOut() -> Set<String> {
        defer { rowsToLayOut = [] }
        return rowsToLayOut
    }

    func readReceipts(for message: TimelineMessage) async throws -> ReadReceipts {
        guard let controller else { throw XeniaError.NotFound }
        return try await controller.readReceipts(rowId: message.id)
    }

    func expandNotes(_ id: String) {
        controller?.expandNotes(groupId: id)
    }
}

/// What a tap on a poll's answer sends.
enum PollVote {
    /// The whole new selection, in the poll's order: in a one-answer poll the tapped answer
    /// replaces my vote (tapping it again takes the vote back); in a several-answer poll it's
    /// added or removed. `nil` when the tap changes nothing (the limit is reached).
    static func selection(tapping answerID: String, answers: [PollAnswer], maxSelections: UInt32) -> [String]? {
        let mine = Set(answers.filter(\.isMine).map(\.id))
        if maxSelections <= 1 {
            return mine.contains(answerID) ? [] : [answerID]
        }
        if mine.contains(answerID) {
            return answers.map(\.id).filter { mine.contains($0) && $0 != answerID }
        }
        guard mine.count < maxSelections else { return nil }
        return answers.map(\.id).filter { mine.contains($0) || $0 == answerID }
    }
}
