import Foundation
import Observation
import XeniaCore

/// Search everywhere: conversations by name (instant, from memory), people and public rooms in
/// the server's directories, and words in messages. In one conversation it searches messages
/// only, with filters, back through history this device never downloaded.
@Observable
final class SearchModel {
    var query = ""
    /// Narrows a conversation's search (From, Mentions Me, kinds, dates).
    var filters = SearchFilters.none
    private(set) var conversations: [RoomSummary] = []
    private(set) var people: [Person] = []
    private(set) var publicRooms: [DirectoryRoom] = []
    private(set) var messages: [MessageHit] = []
    private(set) var isSearchingPeople = false
    private(set) var isSearchingMessages = false
    private(set) var messagesDone = false
    private(set) var messagesFailed = false
    /// What the message results cover so far: the server's search, how far back a walk got.
    private(set) var coverage = SearchCoverage.none
    /// A long walk through history stopped to ask before reading further.
    private(set) var isPaused = false

    @ObservationIgnored private var search: MessageSearch?
    /// What the open message search is for, so coming back to the same words picks it up
    /// where it stopped instead of starting over.
    @ObservationIgnored private var searchKey: Key?
    @ObservationIgnored private var generation = 0
    /// One batch at a time per query: the last row appearing again mustn't ask twice.
    @ObservationIgnored private var loadingGeneration: Int?
    /// Results to gather before stopping; scrolling to the end asks for more.
    @ObservationIgnored private var wanted = SearchModel.page
    /// Batches in a row that found nothing new, for pausing a walk that's reading a long history
    /// for little.
    @ObservationIgnored private var emptyBatches = 0

    private struct Key: Equatable {
        let term: String
        let scope: SearchScope
        let filters: SearchFilters
    }

    private static let page = 30
    /// About 20,000 messages read without a match before asking to go on.
    private static let emptyBatchesBeforePause = 25

    var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Words or filters: something to look for.
    var hasCriteria: Bool { trimmed.count >= 2 || !filters.isEmpty }

    /// Nothing found and nothing still looking. One letter only matches names, so it can be
    /// empty too. A failed message search says so in its own section instead.
    var isEmptyResult: Bool {
        !trimmed.isEmpty && conversations.isEmpty && people.isEmpty && publicRooms.isEmpty && messages.isEmpty
            && !isSearchingPeople && !isSearchingMessages && !messagesFailed
    }

    /// Runs after each change to the query or filters; waits for a pause in typing before the
    /// slower parts. `scope` narrows it to one conversation: then only messages are searched.
    func run(model: AppModel, scope: SearchScope = .everywhere) async {
        generation += 1
        let current = generation
        let term = trimmed
        let rooms = model.rooms
        let isEverywhere = scope == .everywhere
        conversations = term.isEmpty || !isEverywhere ? [] : (
            model.client.filterRooms(rooms: rooms, scope: .chats, filter: .all, query: term)
                + model.client.filterRooms(rooms: rooms, scope: .rooms, filter: .all, query: term)
        ).filter { !$0.isInvite }
        // Filters only narrow one conversation's search; everywhere, words lead.
        let filters = isEverywhere ? SearchFilters.none : filters
        let key = Key(term: term, scope: scope, filters: filters)
        // Back from a result, or the panel reopened: the same search, carried on.
        if key == searchKey, search != nil, !messagesFailed {
            await gather()
            return
        }
        search?.cancel()
        search = nil
        messages = []
        messagesDone = false
        messagesFailed = false
        coverage = .none
        isPaused = false
        wanted = Self.page
        emptyBatches = 0
        searchKey = nil
        guard term.count >= 2 || (!isEverywhere && !filters.isEmpty) else {
            people = []
            publicRooms = []
            isSearchingPeople = false
            isSearchingMessages = false
            return
        }
        isSearchingPeople = isEverywhere
        isSearchingMessages = true
        do {
            try await Task.sleep(for: .milliseconds(280))
        } catch {
            return
        }
        guard current == generation else { return }
        async let foundPeople = isEverywhere ? try? model.client.searchPeople(query: term) : []
        async let foundRooms = isEverywhere ? try? model.client.publicRooms(query: term) : []
        async let opened = try? model.client.searchMessages(query: term, scope: scope, filters: filters)
        let (peopleResult, roomsResult, searchResult) = await (foundPeople, foundRooms, opened)
        guard current == generation else { return }
        let known = Set(rooms.compactMap(\.dmUserId))
        // People you already chat with show as conversations; the directory adds everyone else.
        people = (peopleResult ?? []).filter { !known.contains($0.userId) }
        // Rooms you're in show as conversations already.
        publicRooms = (roomsResult ?? []).filter { !$0.isJoined }
        isSearchingPeople = false
        search = searchResult
        searchKey = searchResult == nil ? nil : key
        if searchResult == nil {
            messagesFailed = true
            isSearchingMessages = false
        } else {
            await gather()
        }
    }

    /// The end of the results came into view: look for more.
    func loadMoreMessages() async {
        guard !isPaused else { return }
        wanted = messages.count + Self.page
        await gather()
    }

    /// Goes on reading a long history after a pause.
    func keepSearching() async {
        isPaused = false
        emptyBatches = 0
        await gather()
    }

    /// Asks for batches until there are `wanted` results, the sources run out, or a walk has
    /// read a long way without finding anything.
    private func gather() async {
        guard let search, loadingGeneration != generation else { return }
        let current = generation
        loadingGeneration = current
        defer { if loadingGeneration == current { loadingGeneration = nil } }
        isSearchingMessages = true
        // Only while someone's looking: a closed search mustn't keep reading history. (Swift's
        // cancellation doesn't reach the core; each batch is one bounded step of it.)
        while !messagesDone, messages.count < wanted, !isPaused, current == generation, !Task.isCancelled {
            do {
                let batch = try await search.nextBatch()
                guard current == generation else { return }
                if let batch {
                    let seen = Set(messages.map(\.eventId))
                    let fresh = batch.filter { !seen.contains($0.eventId) }
                    if fresh.isEmpty {
                        emptyBatches += 1
                    } else {
                        emptyBatches = 0
                        // Sources answer out of step: keep the whole list newest first.
                        messages = (messages + fresh).sorted { $0.timestampMs > $1.timestampMs }
                    }
                } else {
                    messagesDone = true
                }
                coverage = await search.coverage()
                guard current == generation else { return }
                if !messagesDone, emptyBatches >= Self.emptyBatchesBeforePause {
                    isPaused = true
                }
                // Only a walk hands back empty batches worth asking again for.
                if batch?.isEmpty == true, !coverage.walksHistory {
                    messagesDone = true
                }
            } catch {
                guard current == generation else { return }
                messagesFailed = true
                messagesDone = true
            }
        }
        isSearchingMessages = false
    }
}

extension SearchFilters {
    static let none = SearchFilters(senders: [], mentionsMe: false, kinds: [], afterMs: nil, beforeMs: nil)

    var isEmpty: Bool { self == .none }
}

extension SearchCoverage {
    static let none = SearchCoverage(
        includesServer: false, walksHistory: false, searchedBackToMs: nil, reachedStart: false, historyFailed: false
    )
}
