//! Search: messages from up to three places at once, merged. This device's encrypted index
//! covers end-to-end encrypted rooms, which the server can't read; the server's search covers
//! every unencrypted message, including ones this device has never downloaded. In one
//! conversation, a walk back through its history covers what neither can: encrypted messages
//! this device never received, and filters without words ("photos from Maya").

use std::{
    collections::{HashSet, VecDeque},
    pin::Pin,
    sync::{
        Arc, LazyLock,
        atomic::{AtomicBool, Ordering},
    },
};

use futures_util::{Stream, StreamExt};
use matrix_sdk::{
    Client, Room,
    deserialized_responses::TimelineEvent,
    room::MessagesOptions,
    ruma::OwnedEventId,
    ruma::{
        OwnedRoomId, OwnedUserId, UInt,
        api::client::search::search_events::v3::{Categories, Criteria, EventContext, OrderBy, Request},
        events::AnySyncTimelineEvent,
        serde::Raw,
    },
};
use matrix_sdk_ui::timeline::{Profile, TimelineItemContent};
use regex::Regex;
use tokio::sync::Mutex;
use tracing::warn;

use crate::{
    client::XeniaClient,
    content::{Body, Summary, mentions_me, summarize_msg_like},
    error::{XeniaError, Result},
    models::Scope,
    runtime::run,
    text::normalize_for_search,
};

/// Results asked for per batch, from each source.
const BATCH: usize = 20;
/// Messages asked of the server per page of a history walk, and the most pages one batch reads
/// before handing back what it has, so the app can say how far back it got.
const WALK_PAGE: u32 = 100;
const WALK_PAGES_PER_BATCH: usize = 8;

/// What a search can be narrowed to besides its words.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct SearchFilters {
    /// Only messages from these people, by Matrix ID. Empty: anyone.
    pub senders: Vec<String>,
    /// Only messages that mention me.
    pub mentions_me: bool,
    /// Only these kinds of message. Empty: any.
    pub kinds: Vec<MessageKind>,
    /// Sent at or after this time (milliseconds since 1970).
    pub after_ms: Option<i64>,
    /// Sent before this time.
    pub before_ms: Option<i64>,
}

impl SearchFilters {
    fn is_empty(&self) -> bool {
        *self == SearchFilters::default()
    }
}

/// A kind of message to search for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum MessageKind {
    Photo,
    Video,
    File,
    /// A message with a web link in it.
    Link,
    /// Voice messages and other audio.
    Audio,
    Poll,
}

/// How far a conversation's history walk has got, for the app to say what's covered.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct SearchCoverage {
    /// The server's search answered, so results reach past what this device has downloaded.
    pub includes_server: bool,
    /// This search walks the conversation's history.
    pub walks_history: bool,
    /// The oldest message the walk has read so far.
    pub searched_back_to_ms: Option<i64>,
    /// The walk reached the start of the conversation (or the earliest date asked for).
    pub reached_start: bool,
    /// The walk stopped because the history couldn't be read (offline, or the server refused).
    pub history_failed: bool,
}

static LINK: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)\b(?:https?://|www\.)\S").expect("valid link pattern"));

/// What a message is, as far as the filters care.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Facts {
    /// Its words (and a file's name), lowercased without accents.
    text: String,
    kind: Option<MessageKind>,
    has_link: bool,
    sender: String,
    mentions_me: bool,
    timestamp_ms: i64,
}

impl Facts {
    fn of(body: &Body, sender: &str, mentions_me: bool, timestamp_ms: i64) -> Facts {
        let words = body.text().unwrap_or_default();
        let text = match body {
            Body::File { name, .. } => format!("{name} {words}"),
            _ => words.to_owned(),
        };
        let kind = match body {
            Body::Image { .. } | Body::Gallery { .. } | Body::Sticker { .. } => Some(MessageKind::Photo),
            Body::Video { .. } => Some(MessageKind::Video),
            Body::File { .. } => Some(MessageKind::File),
            Body::Audio { .. } | Body::Voice => Some(MessageKind::Audio),
            Body::Poll { .. } => Some(MessageKind::Poll),
            _ => None,
        };
        Facts {
            has_link: LINK.is_match(words),
            text: fold(&text),
            kind,
            sender: sender.to_owned(),
            mentions_me,
            timestamp_ms,
        }
    }
}

/// The words and filters of one search, checked against each message found.
#[derive(Debug, Clone)]
struct Query {
    /// The query's words, normalized: a message must contain every one.
    terms: Vec<String>,
    filters: SearchFilters,
}

impl Query {
    fn new(query: &str, filters: SearchFilters) -> Query {
        // Quotes and punctuation around a word ("lunch", lunch?) aren't part of it.
        let terms = fold(query)
            .split_whitespace()
            .map(|word| word.trim_matches(|c: char| !c.is_alphanumeric()))
            .filter(|word| !word.is_empty())
            .map(str::to_owned)
            .collect();
        Query { terms, filters }
    }

    fn has_words(&self) -> bool {
        !self.terms.is_empty()
    }

    /// Whether there's anything to look for at all.
    fn is_empty(&self) -> bool {
        self.terms.is_empty() && self.filters.is_empty()
    }

    /// `check_words` is off for what the index or the server found: they matched the words
    /// already, by their own rules (stems, word boundaries), which a substring check would undo.
    fn matches(&self, facts: &Facts, check_words: bool) -> bool {
        let f = &self.filters;
        if !f.senders.is_empty() && !f.senders.contains(&facts.sender) {
            return false;
        }
        if f.mentions_me && !facts.mentions_me {
            return false;
        }
        if f.after_ms.is_some_and(|after| facts.timestamp_ms < after)
            || f.before_ms.is_some_and(|before| facts.timestamp_ms >= before)
        {
            return false;
        }
        if !f.kinds.is_empty()
            && !f.kinds.iter().any(|kind| match kind {
                MessageKind::Link => facts.has_link,
                kind => facts.kind == Some(*kind),
            })
        {
            return false;
        }
        // Words in a message must be in its text; a filter alone matches captionless photos too.
        !check_words || self.terms.iter().all(|term| facts.text.contains(term.as_str()))
    }

    /// Filters only the walk can apply: the server's search narrows by sender, nothing else.
    fn needs_walk(&self) -> bool {
        let f = &self.filters;
        f.mentions_me || !f.kinds.is_empty() || f.after_ms.is_some() || f.before_ms.is_some()
    }
}

/// Lowercased, without accents, with curly apostrophes made straight: "Don’t" finds "don't".
fn fold(text: &str) -> String {
    normalize_for_search(text).replace(['\u{2019}', '\u{2018}'], "'")
}

/// Where to search.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SearchScope {
    Everywhere,
    Chats,
    Rooms,
    /// One conversation, from its Details.
    Room {
        room_id: String,
    },
}

/// A message that matched.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MessageHit {
    pub room_id: String,
    pub event_id: String,
    pub sender_id: String,
    pub sender_name: String,
    pub sender_avatar_url: Option<String>,
    pub is_own: bool,
    pub body: Body,
    /// The words that matched against, for snippets and highlighting.
    pub text: String,
    pub timestamp_ms: i64,
}

/// A result and, from the server, who sent it (the server's search carries profiles along).
type Found = (Room, TimelineEvent, Option<(String, Option<String>)>);

/// The local index's results in batches of `BATCH`: its streams yield bigger pages, and every
/// result is loaded before the app sees any of a batch.
struct IndexResults<T> {
    pages: Pin<Box<dyn Stream<Item = std::result::Result<Vec<T>, String>> + Send>>,
    pending: VecDeque<T>,
}

impl<T> IndexResults<T> {
    fn new<E: std::fmt::Display>(
        pages: impl Stream<Item = std::result::Result<Vec<T>, E>> + Send + 'static,
    ) -> IndexResults<T> {
        // The index's error type isn't public: only its message is kept.
        IndexResults { pages: Box::pin(pages.map(|page| page.map_err(|e| e.to_string()))), pending: VecDeque::new() }
    }

    /// The next batch, or `None` once the index runs out (or fails).
    async fn next(&mut self) -> Option<Vec<T>> {
        while self.pending.len() < BATCH {
            match self.pages.next().await {
                Some(Ok(page)) => self.pending.extend(page),
                Some(Err(error)) => {
                    warn!("The local search index failed: {error}");
                    break;
                }
                None => break,
            }
        }
        if self.pending.is_empty() {
            return None;
        }
        let take = self.pending.len().min(BATCH);
        Some(self.pending.drain(..take).collect())
    }
}

enum LocalSearch {
    /// Every joined room, or only those in `rooms` (one list's, by the list's own rules).
    Everywhere(Client, IndexResults<(OwnedRoomId, f32, OwnedEventId)>, Option<HashSet<OwnedRoomId>>),
    Room(Room, IndexResults<(f32, OwnedEventId)>),
}

impl LocalSearch {
    async fn next(&mut self) -> Option<Vec<Found>> {
        match self {
            LocalSearch::Everywhere(client, results, rooms) => {
                // A batch can be all other-list rooms: keep reading until something here matches,
                // or the index runs out, so a busy group never hides a chat's older match.
                loop {
                    let ids = results.next().await?;
                    let mut out = Vec::with_capacity(ids.len());
                    for (room_id, _score, event_id) in ids {
                        if rooms.as_ref().is_some_and(|rooms| !rooms.contains(&room_id)) {
                            continue;
                        }
                        let Some(room) = client.get_room(&room_id) else { continue };
                        match room.load_or_fetch_event(&event_id, None).await {
                            Ok(event) => out.push((room, event, None)),
                            Err(error) => warn!("A search result couldn't be loaded: {error}"),
                        }
                    }
                    if !out.is_empty() || rooms.is_none() {
                        return Some(out);
                    }
                }
            }
            LocalSearch::Room(room, results) => {
                let ids = results.next().await?;
                let mut out = Vec::with_capacity(ids.len());
                for (_score, event_id) in ids {
                    if let Ok(event) = room.load_or_fetch_event(&event_id, None).await {
                        out.push((room.clone(), event, None));
                    }
                }
                Some(out)
            }
        }
    }
}

/// The server's search, a page at a time.
struct ServerSearch {
    term: String,
    /// The unencrypted rooms in scope, or `None` for every room I'm in (results from encrypted
    /// ones are dropped: the server can't have read them).
    rooms: Option<Vec<OwnedRoomId>>,
    /// Only these senders, when the search is narrowed to some.
    senders: Option<Vec<OwnedUserId>>,
    next_batch: Option<String>,
    is_done: bool,
    /// The server answered at least once.
    answered: bool,
}

impl ServerSearch {
    async fn next(&mut self, client: &Client) -> Option<Vec<Found>> {
        if self.is_done {
            return None;
        }
        let mut criteria = Criteria::new(self.term.clone());
        criteria.order_by = Some(OrderBy::Recent);
        criteria.filter.rooms = self.rooms.clone();
        criteria.filter.senders = self.senders.clone();
        criteria.filter.limit = UInt::new(BATCH as u64);
        criteria.filter.types = Some(vec!["m.room.message".to_owned()]);
        let mut context = EventContext::new();
        context.before_limit = UInt::MIN;
        context.after_limit = UInt::MIN;
        context.include_profile = true;
        criteria.event_context = context;
        let mut categories = Categories::new();
        categories.room_events = Some(criteria);
        let mut request = Request::new(categories);
        request.next_batch = self.next_batch.clone();

        let response = match client.send(request).await {
            Ok(response) => response,
            Err(error) => {
                // Offline, or a server without search: the local index still answers.
                warn!("Server search failed: {error}");
                self.is_done = true;
                return None;
            }
        };
        self.answered = true;
        let results = response.search_categories.room_events;
        self.next_batch = results.next_batch;
        self.is_done = self.next_batch.is_none();
        let mut out = Vec::with_capacity(results.results.len());
        for result in results.results {
            let Some(raw) = result.result else { continue };
            let Ok(Some(room_id)) = raw.get_field::<OwnedRoomId>("room_id") else { continue };
            let Some(room) = client.get_room(&room_id).filter(server_can_read) else { continue };
            let sender = raw.get_field::<OwnedUserId>("sender").ok().flatten();
            let profile = sender
                .and_then(|s| result.context.profile_info.get(&s))
                .map(|p| (p.displayname.clone().unwrap_or_default(), p.avatar_url.as_ref().map(|a| a.to_string())));
            let raw: Raw<AnySyncTimelineEvent> = raw.cast_unchecked();
            // The server indexes edits as messages of their own; the original stands for them.
            if crate::push::is_edit(&raw) {
                continue;
            }
            out.push((room, TimelineEvent::from_plaintext(raw), profile.filter(|(name, _)| !name.trim().is_empty())));
        }
        Some(out)
    }
}

/// One conversation's history, newest first, read from the server a page at a time and
/// decrypted here. Covers what the index and the server's search can't: encrypted messages this
/// device never received, and filters without words.
struct HistoryWalk {
    room: Room,
    /// Where the next page starts; `None` before the first, which starts at the newest.
    from: Option<String>,
    started: bool,
    reached_start: bool,
    failed: bool,
    oldest_ms: Option<i64>,
}

impl HistoryWalk {
    fn new(room: Room) -> HistoryWalk {
        HistoryWalk { room, from: None, started: false, reached_start: false, failed: false, oldest_ms: None }
    }

    /// Reads up to `WALK_PAGES_PER_BATCH` pages, stopping early once `BATCH` messages match.
    /// `None` once the walk has reached the start.
    async fn next(&mut self, search: &MessageSearch) -> Option<Vec<Found>> {
        if self.reached_start {
            return None;
        }
        let mut out = Vec::new();
        for _ in 0..WALK_PAGES_PER_BATCH {
            if search.cancelled.load(Ordering::Relaxed) {
                return None;
            }
            let mut options = MessagesOptions::backward();
            options.from = self.from.clone();
            options.limit = UInt::from(WALK_PAGE);
            let page = match self.room.messages(options).await {
                Ok(page) => page,
                Err(error) => {
                    warn!("A conversation's history couldn't be read for search: {error}");
                    self.failed = true;
                    self.reached_start = true;
                    break;
                }
            };
            self.started = true;
            self.from = page.end.clone();
            if page.end.is_none() || page.chunk.is_empty() {
                self.reached_start = true;
            }
            let after = search.query.filters.after_ms;
            // A whole page older than the earliest date asked for: the rest is older still. (One
            // old event alone proves nothing; a server's clock can be off.)
            let all_older = after.is_some_and(|after| {
                page.chunk.iter().all(|e| e.timestamp().is_some_and(|t| i64::from(t.get()) < after))
            });
            for event in page.chunk {
                let Some(at) = event.timestamp().map(|t| i64::from(t.get())) else { continue };
                self.oldest_ms = Some(self.oldest_ms.map_or(at, |oldest| oldest.min(at)));
                if is_searchable_event(event.raw()) && search.examine(&self.room, &event, true).await.is_some() {
                    out.push((self.room.clone(), event, None));
                }
            }
            if all_older {
                self.reached_start = true;
            }
            if self.reached_start || out.len() >= BATCH {
                break;
            }
        }
        Some(out)
    }
}

/// A message, sticker or poll, not an edit or a change to the room.
fn is_searchable_event(raw: &Raw<AnySyncTimelineEvent>) -> bool {
    let kind = raw.get_field::<String>("type").ok().flatten();
    matches!(kind.as_deref(), Some("m.room.message" | "m.sticker" | "m.poll.start" | "org.matrix.msc3381.poll.start"))
        && !crate::push::is_edit(raw)
}

#[derive(uniffi::Object)]
pub struct MessageSearch {
    client: Client,
    me: String,
    my_name: String,
    query: Query,
    local: Mutex<Option<LocalSearch>>,
    server: Mutex<ServerSearch>,
    walk: Mutex<Option<HistoryWalk>>,
    /// Event IDs already returned, so a message found in more than one place shows once.
    seen: Mutex<HashSet<String>>,
    /// The app moved on to another query: stop asking the server.
    cancelled: AtomicBool,
}

impl MessageSearch {
    /// What a message reads as and whether it matches, before anything slower (its sender's
    /// name) is looked up: most of a history walk's messages stop here.
    async fn examine(&self, room: &Room, event: &TimelineEvent, check_words: bool) -> Option<(Body, i64)> {
        let sender = event.sender()?;
        let timestamp_ms = event.timestamp().map(|t| i64::from(t.get())).unwrap_or(0);
        let highlighted = event.push_actions().is_some_and(|actions| actions.iter().any(|a| a.is_highlight()));
        let content = TimelineItemContent::from_event(room, event.clone()).await?;
        let Summary::Message { body } = (match &content {
            TimelineItemContent::MsgLike(msg) => summarize_msg_like(msg),
            _ => return None,
        }) else {
            return None;
        };
        // Nothing to show for these: a filter on its own would list them as empty rows.
        if matches!(body, Body::Deleted | Body::Encrypted | Body::Unsupported | Body::Location) {
            return None;
        }
        let is_own = sender.as_str() == self.me;
        let mentions = !is_own
            && self.query.filters.mentions_me
            && (highlighted || mentions_me(&content, &self.me, &self.my_name));
        let facts = Facts::of(&body, sender.as_str(), mentions, timestamp_ms);
        self.query.matches(&facts, check_words).then_some((body, timestamp_ms))
    }

    async fn hit(
        &self,
        room: &Room,
        event: TimelineEvent,
        known: Option<(String, Option<String>)>,
        check_words: bool,
    ) -> Option<MessageHit> {
        let (body, timestamp_ms) = self.examine(room, &event, check_words).await?;
        let sender = event.sender()?;
        let event_id = event.event_id()?;
        let is_own = sender.as_str() == self.me;
        // The server sends names with its results; the others ask the room.
        let (sender_name, avatar) = match known {
            Some((name, avatar)) => (name, avatar),
            None => {
                let profile = Profile::load(room, &sender).await;
                let avatar = profile.as_ref().and_then(|p| p.avatar_url.as_ref()).map(|a| a.to_string());
                let name = profile
                    .and_then(|p| p.display_name)
                    .filter(|n| !n.trim().is_empty())
                    .unwrap_or_else(|| sender.to_string());
                (name, avatar)
            }
        };
        let text = match &body {
            Body::File { name, caption } => caption.clone().unwrap_or_else(|| name.clone()),
            body => body.text().unwrap_or_default().to_owned(),
        };
        Some(MessageHit {
            room_id: room.room_id().to_string(),
            event_id: event_id.to_string(),
            sender_id: sender.to_string(),
            sender_name,
            sender_avatar_url: avatar,
            is_own,
            body,
            text,
            timestamp_ms,
        })
    }
}

#[uniffi::export]
impl MessageSearch {
    /// The next batch of results, newest first within the batch, or `None` when there are no
    /// more. Each batch asks every source together. A batch can be empty while a history walk
    /// is still going: ask again, and `coverage` says how far back it got.
    pub async fn next_batch(self: Arc<Self>) -> Result<Option<Vec<MessageHit>>> {
        let this = Arc::clone(&self);
        run(async move {
            // A batch whose results were all seen already asks again, a few times at most.
            for _ in 0..3 {
                if this.cancelled.load(Ordering::Relaxed) {
                    return Ok(None);
                }
                let local = async {
                    let mut local = this.local.lock().await;
                    let found = match local.as_mut() {
                        Some(search) => search.next().await,
                        None => None,
                    };
                    if found.is_none() {
                        *local = None;
                    }
                    found
                };
                let server = async { this.server.lock().await.next(&this.client).await };
                let walk = async {
                    match this.walk.lock().await.as_mut() {
                        Some(walk) => walk.next(&this).await,
                        None => None,
                    }
                };
                let (local, server, walk) = tokio::join!(local, server, walk);
                if local.is_none() && server.is_none() && walk.is_none() {
                    return Ok(None);
                }
                let walked = walk.is_some();
                let mut hits = Vec::new();
                // The walk reads every message, so only its results need the words checked.
                let found = local
                    .into_iter()
                    .flatten()
                    .chain(server.into_iter().flatten())
                    .map(|found| (found, false))
                    .chain(walk.into_iter().flatten().map(|found| (found, true)));
                for ((room, event, known), check_words) in found {
                    let Some(id) = event.event_id().map(ToOwned::to_owned) else { continue };
                    if this.seen.lock().await.contains(id.as_str()) {
                        continue;
                    }
                    if let Some(hit) = this.hit(&room, event, known, check_words).await {
                        this.seen.lock().await.insert(id.to_string());
                        hits.push(hit);
                    }
                }
                // A walk's batch is worth reporting even when empty: it got further back.
                if !hits.is_empty() || walked {
                    hits.sort_by_key(|a| std::cmp::Reverse(a.timestamp_ms));
                    return Ok(Some(hits));
                }
            }
            Ok(Some(Vec::new()))
        })
        .await
    }

    /// Stops the search: batches already asked for end early and send nothing more. Swift's task
    /// cancellation doesn't reach Rust, so the app calls this when the query changes.
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Relaxed);
    }

    /// What the results so far cover, for the app to say.
    pub async fn coverage(&self) -> SearchCoverage {
        let includes_server = self.server.lock().await.answered;
        match self.walk.lock().await.as_ref() {
            Some(walk) => SearchCoverage {
                includes_server,
                walks_history: true,
                searched_back_to_ms: walk.started.then_some(walk.oldest_ms).flatten(),
                reached_start: walk.reached_start && !walk.failed,
                history_failed: walk.failed,
            },
            None => SearchCoverage { includes_server, ..SearchCoverage::default() },
        }
    }
}

#[uniffi::export]
impl XeniaClient {
    /// Starts a message search: words, filters, or both. Ask for batches with `next_batch`.
    /// Filters without words only work in one conversation, where the history can be walked.
    pub async fn search_messages(
        &self,
        query: String,
        scope: SearchScope,
        filters: SearchFilters,
    ) -> Result<Arc<MessageSearch>> {
        let core = self.core().await?;
        let snapshot = self.room_snapshot();
        run(async move {
            let term = query.trim().to_owned();
            let query = Query::new(&term, filters);
            let has_words = query.has_words();
            let client = core.client.clone();
            let senders = (!query.filters.senders.is_empty())
                .then(|| query.filters.senders.iter().filter_map(|s| s.parse().ok()).collect::<Vec<OwnedUserId>>());
            let index = |iterator| has_words.then_some(iterator);
            let in_scope = |scope: Scope| -> Vec<OwnedRoomId> {
                snapshot.iter().filter(|r| r.scope == scope && !r.is_invite).filter_map(|r| r.id.parse().ok()).collect()
            };
            // Chats and Rooms search the rooms their lists show (by `is_direct`), not the SDK's
            // own idea of a DM, so a result never belongs to the other list.
            let listed = |scope: Scope| {
                let rooms = in_scope(scope);
                let local = index(LocalSearch::Everywhere(
                    client.clone(),
                    IndexResults::new(client.search_messages(term.clone()).build()),
                    Some(rooms.iter().cloned().collect()),
                ));
                // The server can't read encrypted rooms: it would only learn the term.
                let unencrypted: Vec<OwnedRoomId> =
                    rooms.into_iter().filter(|id| client.get_room(id).is_some_and(|r| server_can_read(&r))).collect();
                let readable = !unencrypted.is_empty();
                (local, Some(unencrypted), readable, None)
            };
            // The server is asked only when something it could read is in scope: otherwise it
            // would only learn the term.
            let (local, rooms, readable, walk) = match &scope {
                SearchScope::Everywhere => {
                    // Every room, without listing them (an account can have thousands).
                    let readable = client.joined_rooms().iter().any(server_can_read);
                    let local = index(LocalSearch::Everywhere(
                        client.clone(),
                        IndexResults::new(client.search_messages(term.clone()).build()),
                        None,
                    ));
                    (local, None, readable, None)
                }
                SearchScope::Chats => listed(Scope::Chats),
                SearchScope::Rooms => listed(Scope::Rooms),
                SearchScope::Room { room_id } => {
                    let id: OwnedRoomId = room_id.parse()?;
                    let room = client.get_room(&id).ok_or(XeniaError::NotFound)?;
                    let readable = server_can_read(&room);
                    // The server's search already covers an unencrypted room's whole history for
                    // words and senders; anything else needs the walk.
                    let walk = (!query.is_empty() && (!readable || !has_words || query.needs_walk()))
                        .then(|| HistoryWalk::new(room.clone()));
                    let local =
                        index(LocalSearch::Room(room.clone(), IndexResults::new(room.search_messages(term.clone()))));
                    (local, Some(vec![id]), readable, walk)
                }
            };
            Ok(Arc::new(MessageSearch {
                client,
                me: core.user_id.clone(),
                my_name: core.my_name(),
                local: Mutex::new(local),
                server: Mutex::new(ServerSearch {
                    is_done: !readable || !has_words,
                    term,
                    rooms,
                    senders,
                    next_batch: None,
                    answered: false,
                }),
                walk: Mutex::new(walk),
                query,
                seen: Mutex::default(),
                cancelled: AtomicBool::new(false),
            }))
        })
        .await
    }
}

/// Whether the server can read a room's messages, so asking it to search there is worth the
/// term. Only a room known to be unencrypted: before its encryption state arrives, it's not.
fn server_can_read(room: &matrix_sdk::Room) -> bool {
    is_readable(room.encryption_state())
}

fn is_readable(state: matrix_sdk::EncryptionState) -> bool {
    matches!(state, matrix_sdk::EncryptionState::NotEncrypted)
}

#[cfg(test)]
mod tests {
    use matrix_sdk::EncryptionState;

    use super::*;

    fn text(words: &str) -> Body {
        Body::Text { text: words.to_owned() }
    }

    fn facts(body: &Body) -> Facts {
        Facts::of(body, "@maya:x", false, 1_000)
    }

    fn query(words: &str, filters: SearchFilters) -> Query {
        Query::new(words, filters)
    }

    #[test]
    fn every_word_must_appear_ignoring_case_and_accents() {
        let message = facts(&text("Lunch at the Café on Friday?"));
        assert!(query("cafe friday", SearchFilters::default()).matches(&message, true));
        assert!(query("  LUNCH  ", SearchFilters::default()).matches(&message, true));
        assert!(!query("cafe saturday", SearchFilters::default()).matches(&message, true));
    }

    #[test]
    fn punctuation_and_curly_quotes_around_words_dont_count() {
        let message = facts(&text("Don’t forget: lunch at noon"));
        assert!(query("\"lunch\" noon?", SearchFilters::default()).matches(&message, true));
        assert!(query("don't", SearchFilters::default()).matches(&message, true));
        assert!(query("?!", SearchFilters::default()).is_empty());
    }

    #[test]
    fn what_the_index_or_server_found_keeps_its_own_word_match() {
        // The server stems "meetings" to find "meeting"; only the filters are checked again.
        let message = facts(&text("The meeting moved"));
        assert!(query("meetings", SearchFilters::default()).matches(&message, false));
        let photos = SearchFilters { kinds: vec![MessageKind::Photo], ..SearchFilters::default() };
        assert!(!query("meetings", photos).matches(&message, false));
    }

    #[test]
    fn only_filters_the_server_cant_apply_need_the_walk() {
        let from = SearchFilters { senders: vec!["@maya:x".into()], ..SearchFilters::default() };
        assert!(!query("lunch", from).needs_walk());
        let dated = SearchFilters { before_ms: Some(1), ..SearchFilters::default() };
        assert!(query("lunch", dated).needs_walk());
    }

    #[test]
    fn a_files_name_counts_as_its_words() {
        let file = facts(&Body::File { name: "Q3 Budget.pdf".to_owned(), caption: None });
        assert!(query("budget", SearchFilters::default()).matches(&file, true));
    }

    #[test]
    fn a_filter_alone_matches_media_without_words() {
        let photos = SearchFilters { kinds: vec![MessageKind::Photo], ..SearchFilters::default() };
        assert!(query("", photos.clone()).matches(&facts(&Body::Image { caption: None }), true));
        assert!(query("", photos.clone()).matches(&facts(&Body::Gallery { count: 3 }), true));
        assert!(!query("", photos.clone()).matches(&facts(&Body::Video { caption: None }), true));
        assert!(!query("", photos).matches(&facts(&text("a photo, honestly")), true));
    }

    #[test]
    fn kinds_are_any_of_and_links_come_from_the_words() {
        let links_or_files =
            SearchFilters { kinds: vec![MessageKind::Link, MessageKind::File], ..SearchFilters::default() };
        assert!(query("", links_or_files.clone()).matches(&facts(&text("see https://example.org/a")), true));
        assert!(query("", links_or_files.clone()).matches(&facts(&text("www.example.org")), true));
        assert!(
            query("", links_or_files.clone()).matches(&facts(&Body::File { name: "a".into(), caption: None }), true)
        );
        assert!(!query("", links_or_files).matches(&facts(&text("http is a protocol")), true));
        let audio = SearchFilters { kinds: vec![MessageKind::Audio], ..SearchFilters::default() };
        assert!(query("", audio).matches(&facts(&Body::Voice), true));
    }

    #[test]
    fn senders_mentions_and_dates_narrow_together() {
        let message = Facts::of(&text("ping"), "@maya:x", true, 5_000);
        let from = |ids: &[&str]| SearchFilters {
            senders: ids.iter().map(|s| (*s).to_owned()).collect(),
            ..SearchFilters::default()
        };
        assert!(query("ping", from(&["@sam:x", "@maya:x"])).matches(&message, true));
        assert!(!query("ping", from(&["@sam:x"])).matches(&message, true));

        let mentions = SearchFilters { mentions_me: true, ..SearchFilters::default() };
        assert!(query("", mentions.clone()).matches(&message, true));
        assert!(!query("", mentions).matches(&Facts::of(&text("ping"), "@maya:x", false, 5_000), true));

        let window = |after, before| SearchFilters { after_ms: after, before_ms: before, ..SearchFilters::default() };
        assert!(query("", window(Some(5_000), Some(5_001))).matches(&message, true));
        assert!(!query("", window(Some(5_001), None)).matches(&message, true));
        assert!(!query("", window(None, Some(5_000))).matches(&message, true));
    }

    #[test]
    fn nothing_to_look_for_is_empty() {
        assert!(query("  ", SearchFilters::default()).is_empty());
        assert!(!query("", SearchFilters { mentions_me: true, ..SearchFilters::default() }).is_empty());
    }

    #[test]
    fn only_rooms_known_to_be_unencrypted_go_to_the_server() {
        assert!(is_readable(EncryptionState::NotEncrypted));
        assert!(!is_readable(EncryptionState::Encrypted));
        assert!(!is_readable(EncryptionState::Unknown));
    }
}
