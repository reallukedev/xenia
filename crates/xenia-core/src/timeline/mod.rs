//! A conversation (or one thread) as rows ready to draw, and everything you can do in it.

mod layout;
mod receipts;
mod rows;

use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
};

use futures_util::StreamExt;
use matrix_sdk::room::edit::EditedContent;
use matrix_sdk::ruma::api::client::receipt::create_receipt::v3::ReceiptType;
use matrix_sdk::{
    Room,
    attachment::{AttachmentInfo, BaseAudioInfo, BaseFileInfo, BaseImageInfo, BaseVideoInfo},
    ruma::{
        EventId, OwnedEventId, RoomId, UInt,
        events::{
            Mentions,
            poll::{
                start::PollKind,
                unstable_end::UnstablePollEndEventContent,
                unstable_response::UnstablePollResponseEventContent,
                unstable_start::{
                    NewUnstablePollStartEventContent, UnstablePollAnswer, UnstablePollAnswers,
                    UnstablePollStartContentBlock, UnstablePollStartEventContent,
                },
            },
            room::message::{
                EmoteMessageEventContent, FormattedBody, MessageType, RoomMessageEventContent,
                RoomMessageEventContentWithoutRelation, TextMessageEventContent,
            },
        },
    },
};
use matrix_sdk_ui::timeline::{
    AttachmentConfig, AttachmentSource, RoomExt, Timeline, TimelineEventFocusThreadMode, TimelineEventItemId,
    TimelineFocus as SdkFocus, TimelineItem, TimelineReadReceiptTracking,
};
use tokio::sync::Notify;
use tracing::warn;

use self::{
    layout::{Raw, lay_out, mark_seen},
    rows::{Context, People, raw_row},
};
use crate::{
    client::{Core, XeniaClient},
    content::{Body, Note},
    error::{XeniaError, Result},
    models::SendState,
    rooms::RoomListHub,
    runtime::{TaskGuard, run},
    sync::MutexExt,
    text::{ComposedMessage, RichBlock},
};

// MARK: Records

/// What a timeline shows.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum TimelineFocus {
    /// The conversation, live, with thread replies left to their threads.
    Live,
    /// One thread, from its root.
    Thread { root_event_id: String },
    /// The conversation around one message (from search or a permalink).
    Event { event_id: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct RunPosition {
    /// First bubble of a run: shows the sender's name in groups.
    pub is_first: bool,
    /// Last bubble of a run: carries the avatar, the tail and the wider gap below.
    pub is_last: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TextKind {
    Normal,
    /// From a bot or service: drawn quieter.
    Notice,
    /// "/me waves": drawn as an action after the sender's name.
    Emote,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MediaInfo {
    /// Pass to `load_thumbnail`, `load_media` or `save_media`.
    pub source: String,
    pub thumbnail: Option<String>,
    /// Zero when unknown.
    pub width: u32,
    pub height: u32,
    pub blurhash: Option<String>,
    pub mimetype: Option<String>,
    pub size: Option<u64>,
    pub filename: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum MessageContent {
    Text {
        blocks: Vec<RichBlock>,
        plain: String,
        kind: TextKind,
        is_jumbo: bool,
    },
    Image {
        media: MediaInfo,
        caption: Option<String>,
    },
    Video {
        media: MediaInfo,
        duration_ms: Option<u64>,
        caption: Option<String>,
    },
    Audio {
        source: String,
        filename: String,
        duration_ms: Option<u64>,
        size: Option<u64>,
        mimetype: Option<String>,
        is_voice: bool,
        caption: Option<String>,
    },
    File {
        source: String,
        filename: String,
        size: Option<u64>,
        mimetype: Option<String>,
        caption: Option<String>,
    },
    Sticker {
        media: MediaInfo,
        description: String,
    },
    Poll {
        question: String,
        answers: Vec<PollAnswer>,
        /// Votes show as they come in; otherwise only once the poll ends.
        is_disclosed: bool,
        /// How many answers each person may choose.
        max_selections: u32,
        /// People who have voted, each counted once.
        voter_count: u32,
        is_ended: bool,
        /// My poll, still open: I can end it.
        can_end: bool,
    },
    Location {
        geo_uri: String,
        description: Option<String>,
    },
    Deleted,
    /// Couldn't be decrypted (yet): the key may still arrive from backup or another device.
    Encrypted,
    Unsupported,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollAnswer {
    /// Pass to `vote`.
    pub id: String,
    pub text: String,
    pub votes: u32,
    pub is_mine: bool,
    /// Who chose it, with their names and photos (shown only when results are).
    pub voters: Vec<Reader>,
    /// Among the most voted, once the poll has ended.
    pub is_winner: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Reaction {
    pub key: String,
    pub count: u32,
    pub is_mine: bool,
    /// Who reacted, by name; empty for me (the app says "You").
    pub sender_names: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ReplyState {
    Loading,
    Ready,
    /// The original message can't be loaded (deleted, or from before I joined).
    Unavailable,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ReplyPreview {
    pub event_id: String,
    pub sender_id: Option<String>,
    pub sender_name: Option<String>,
    pub is_own: bool,
    pub body: Option<Body>,
    pub state: ReplyState,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ThreadSummary {
    pub reply_count: u32,
    /// Replies I haven't read, and whether one of them is about me.
    pub unread: crate::models::UnreadKind,
    pub latest_sender_id: Option<String>,
    pub latest_sender_name: Option<String>,
    pub latest_sender_avatar_url: Option<String>,
    pub latest_body: Option<Body>,
    pub latest_timestamp_ms: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Reader {
    pub user_id: String,
    pub name: String,
    pub avatar_url: Option<String>,
}

/// "Delivered" or "Read", under my newest message.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Delivery {
    pub is_read: bool,
    /// Who has read it (for "Read by Maya and Sam" in groups).
    pub readers: Vec<Reader>,
}

/// Who has read a run of messages: shown beside its last bubble when the conversation is
/// swiped to reveal times.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Seen {
    /// Some of who has read the run (a few at most, however big the room).
    pub read: Vec<Reader>,
    /// Everyone who has read it.
    pub read_count: u32,
    /// How many people could have: everyone in the room but me and the sender. 0 when unknown.
    pub others: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TimelineMessage {
    /// Stable across the local echo and the server's copy: use it as the row's identity.
    pub id: String,
    pub event_id: Option<String>,
    pub sender_id: String,
    pub sender_name: String,
    pub sender_avatar_url: Option<String>,
    pub is_own: bool,
    pub timestamp_ms: i64,
    pub content: MessageContent,
    pub is_edited: bool,
    /// Mentions me (by ID, pill or @room): the bubble is highlighted.
    pub mentions_me: bool,
    pub send_state: SendState,
    pub reactions: Vec<Reaction>,
    pub reply: Option<ReplyPreview>,
    /// This message starts a thread.
    pub thread: Option<ThreadSummary>,
    /// Others whose read receipt sits on this message.
    pub read_by: Vec<Reader>,
    pub can_edit: bool,
    pub can_reply: bool,
    /// A sent message whose content can be copied to another conversation.
    pub can_forward: bool,
    pub can_redact: bool,
    pub is_pinned: bool,
    pub run: RunPosition,
    /// Show the sender's name above the bubble (groups, first of a run, not mine).
    pub show_sender: bool,
    /// Set on my newest message when nobody has written since.
    pub delivery: Option<Delivery>,
    /// On the last message of a run: who has read the run.
    pub seen: Option<Seen>,
    /// The message a search or link jumped to.
    pub is_highlighted: bool,
}

/// A note in the timeline.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct NoteLine {
    pub id: String,
    pub timestamp_ms: i64,
    pub note: Note,
}

// Rows cross the boundary by value; boxing the message would only add an allocation per row.
#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum TimelineRow {
    Message {
        message: TimelineMessage,
    },
    /// The time a sitting started, after a pause or on a new day: "Today 9:41 AM".
    Header {
        id: String,
        timestamp_ms: i64,
    },
    Note {
        line: NoteLine,
    },
    /// Several notes in a row, folded into one line until expanded.
    NoteGroup {
        id: String,
        notes: Vec<NoteLine>,
    },
    /// Where new messages start.
    ReadMarker {
        id: String,
    },
    /// The very beginning of the conversation.
    Start {
        id: String,
    },
}

impl TimelineRow {
    pub fn id(&self) -> &str {
        match self {
            TimelineRow::Message { message } => &message.id,
            TimelineRow::Note { line } => &line.id,
            TimelineRow::Header { id, .. }
            | TimelineRow::NoteGroup { id, .. }
            | TimelineRow::ReadMarker { id }
            | TimelineRow::Start { id } => id,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TimelineUpdate {
    pub rows: Vec<TimelineRow>,
    /// Loaded at least once: an empty list now really means an empty conversation.
    pub is_ready: bool,
    pub is_loading_older: bool,
    /// The beginning of the conversation is loaded, or as far back as I'm allowed to see.
    pub is_at_start: bool,
    /// Earlier messages exist, but the room shows them only to people who were there.
    pub history_starts_at_join: bool,
    /// The newest messages are loaded (false for a jump into the past until it catches up).
    pub is_at_end: bool,
    /// For a jump to a message: the row to scroll to.
    pub focused_row_id: Option<String>,
}

/// Something to send as a file.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Attachment {
    /// A file on disk the app can read.
    pub path: String,
    pub filename: String,
    pub mimetype: String,
    pub size: Option<u64>,
    /// For photos and videos.
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub duration_ms: Option<u64>,
    pub blurhash: Option<String>,
    pub caption: Option<String>,
    /// A JPEG poster frame for a video, so others see a picture before they download it.
    pub thumbnail_path: Option<String>,
}

#[uniffi::export(with_foreign)]
pub trait TimelineListener: Send + Sync {
    fn on_update(&self, update: TimelineUpdate);
    /// The people typing right now, not including me, with their names and photos.
    fn on_typing(&self, people: Vec<Reader>);
}

// MARK: Controller

/// How long to wait after history failed to load before asking again.
const HISTORY_RETRY: std::time::Duration = std::time::Duration::from_secs(15);
/// How long to gather changes before publishing: a page of history arrives as its items, the
/// end of the request and receipts, and each publish redraws on the app's main thread.
const COALESCE: std::time::Duration = std::time::Duration::from_millis(12);

#[derive(Default)]
struct State {
    items: eyeball_im::Vector<Arc<TimelineItem>>,
    /// Rows already built, per item, reused while the item is unchanged.
    cache: HashMap<String, (Arc<TimelineItem>, Option<Raw>)>,
    targets: HashMap<String, TimelineEventItemId>,
    expanded: HashSet<String>,
    people: People,
    is_ready: bool,
    is_loading_older: bool,
    is_at_start: bool,
    /// Older pages come back empty because the room hides history from before I joined.
    history_hidden: bool,
    /// The server refused history because I'm not a member yet: joining lifts it.
    refused_before_joining: bool,
    is_at_end: bool,
    requested_details: HashSet<String>,
    /// The first message after "New Messages" when the conversation first loaded (`Some(None)`
    /// when there was no marker). The line stays where it was when the person arrived: messages
    /// that come in while they're reading don't get a line of their own.
    marker_anchor: Option<Option<String>>,
    /// The first page has loaded (or wasn't needed): the read marker, if any, is in place.
    settled: bool,
    /// What cached rows were built against; when it changes, they're rebuilt.
    cache_context: (Vec<String>, String),
    /// When loading history last failed: asking again at once would fail the same way.
    history_failed_at: Option<std::time::Instant>,
    /// Each thread's unread state, by root, with the key it was worked out for (its latest
    /// reply): a new reply works it out again, and so does a receipt of mine in that thread.
    thread_unread: HashMap<String, (String, crate::models::UnreadKind)>,
    /// Threads being worked out now.
    thread_scans: HashSet<String>,
}

struct Shared {
    timeline: Arc<Timeline>,
    room: Room,
    core: Arc<Core>,
    hub: Arc<RoomListHub>,
    listener: Arc<dyn TimelineListener>,
    focus: TimelineFocus,
    is_group: bool,
    can_redact_others: bool,
    state: Mutex<State>,
    dirty: Notify,
    /// A request for older (or newer) messages is in flight. Separate from `is_loading_older`,
    /// which the SDK's own status also writes, so two requests can never overlap.
    paginating_back: AtomicBool,
    paginating_forward: AtomicBool,
    /// The newest event this timeline last marked read, so scrolling near the bottom again
    /// doesn't send the same receipts again.
    last_marked: Mutex<Option<OwnedEventId>>,
}

#[derive(uniffi::Object)]
pub struct TimelineController {
    shared: Arc<Shared>,
    typing: AtomicBool,
    _tasks: Vec<TaskGuard>,
}

impl Shared {
    fn rebuild_and_publish(self: &Arc<Self>) {
        let update = {
            let mut guard = self.state.locked();
            let state = &mut *guard;
            if state.refused_before_joining && self.room.state() == matrix_sdk::RoomState::Joined {
                state.refused_before_joining = false;
                state.history_hidden = false;
            }
            state.people.learn(&state.items.iter().cloned().collect::<Vec<_>>());
            let pinned: Vec<String> =
                self.room.pinned_event_ids().unwrap_or_default().iter().map(|e| e.to_string()).collect();
            let my_name = self.core.my_name();
            // Pins and my name aren't part of an item, so a change to either rebuilds every row.
            let context = (pinned.clone(), my_name.clone());
            if state.cache_context != context {
                state.cache.clear();
                state.cache_context = context;
            }
            let cx = Context {
                me: &self.core.user_id,
                my_name: &my_name,
                people: &state.people,
                pinned: &pinned,
                can_redact_others: self.can_redact_others,
                thread_unread: &state.thread_unread,
            };
            let shows_membership = self.core.shows_membership();
            let mut cache = std::mem::take(&mut state.cache);
            let mut next_cache = HashMap::with_capacity(state.items.len());
            let mut raw = Vec::with_capacity(state.items.len());
            let mut missing_replies = Vec::new();
            // Who has read how far: each receipt, and each sender's own message (sending
            // reads everything before it), counts for the newest message at or before it.
            let mut read_up_to: HashMap<String, String> = HashMap::new();
            let mut newest_message: Option<String> = None;
            state.targets.clear();
            for item in &state.items {
                let key = item.unique_id().0.clone();
                // Receipts and names can change without the item changing identity, so the
                // cache only holds while the item is the very same object.
                let row = match cache.remove(&key) {
                    Some((cached, row)) if Arc::ptr_eq(&cached, item) => row,
                    _ => raw_row(item, &cx),
                };
                if let Some(Raw::Message(m)) = &row {
                    newest_message = Some(m.id.clone());
                }
                if let Some(event) = item.as_event() {
                    state.targets.insert(key.clone(), event.identifier());
                    if let Some(newest) = &newest_message {
                        for user in event
                            .read_receipts()
                            .keys()
                            .map(|u| u.as_str())
                            .chain(std::iter::once(event.sender().as_str()))
                        {
                            read_up_to.insert(user.to_string(), newest.clone());
                        }
                    }
                }
                if let Some(Raw::Message(m)) = &row
                    && let Some(reply) = &m.reply
                    && reply.state == ReplyState::Loading
                    && let Some(id) = &m.event_id
                    && !state.requested_details.contains(id)
                {
                    missing_replies.push(id.clone());
                }
                if let Some(row) = row.clone()
                    && (shows_membership || !is_membership(&row))
                {
                    raw.push(row);
                }
                next_cache.insert(key, (Arc::clone(item), row));
            }
            state.cache = next_cache;
            let mut scans = Vec::new();
            for item in &state.items {
                let Some(event) = item.as_event() else { continue };
                let Some(msg) = event.content().as_msglike() else { continue };
                let (Some(summary), Some(root)) = (&msg.thread_summary, event.event_id()) else { continue };
                let key = rows::thread_key(summary);
                let root = root.to_string();
                let known = state.thread_unread.get(&root).is_some_and(|(k, _)| *k == key);
                if !known && rows::may_be_unread(summary, &self.core.user_id) && state.thread_scans.insert(root.clone())
                {
                    scans.push((root, key));
                } else if !known && !rows::may_be_unread(summary, &self.core.user_id) {
                    state.thread_unread.insert(root, (key, crate::models::UnreadKind::None));
                }
            }
            if !scans.is_empty() {
                let shared = Arc::clone(self);
                crate::runtime::spawn(async move { shared.scan_threads(scans).await });
            }
            for id in &missing_replies {
                state.requested_details.insert(id.clone());
            }
            if !raw.is_empty() {
                state.is_ready = true;
            }
            let mut rows = lay_out(raw, self.is_group, &state.expanded, &self.core.user_id);
            let members = self.room.joined_members_count();
            mark_seen(&mut rows, &read_up_to, members, &state.people, &self.core.user_id);
            let anchor = marker_anchor(&rows);
            match &state.marker_anchor {
                None if state.settled || anchor.is_some() => state.marker_anchor = Some(anchor),
                Some(first) if *first != anchor => rows.retain(|r| !matches!(r, TimelineRow::ReadMarker { .. })),
                _ => {}
            }
            let focused_row_id = match &self.focus {
                TimelineFocus::Event { event_id } => rows.iter_mut().find_map(|row| match row {
                    TimelineRow::Message { message } if message.event_id.as_deref() == Some(event_id.as_str()) => {
                        message.is_highlighted = true;
                        Some(message.id.clone())
                    }
                    _ => None,
                }),
                _ => None,
            };
            if !missing_replies.is_empty() {
                let timeline = Arc::clone(&self.timeline);
                crate::runtime::spawn(async move {
                    for id in missing_replies {
                        if let Ok(event_id) = EventId::parse(&id) {
                            let _ = timeline.fetch_details_for_event(&event_id).await;
                        }
                    }
                });
            }
            TimelineUpdate {
                rows,
                is_ready: state.is_ready,
                is_loading_older: state.is_loading_older,
                is_at_start: state.is_at_start || state.history_hidden,
                history_starts_at_join: state.history_hidden && !state.is_at_start,
                is_at_end: state.is_at_end,
                focused_row_id,
            }
        };
        self.listener.on_update(update);
    }

    /// Works out threads' unread state from their replies, then redraws the rows that lead
    /// them if it changed.
    async fn scan_threads(self: Arc<Self>, scans: Vec<(String, String)>) {
        let Ok(me) = matrix_sdk::ruma::UserId::parse(&self.core.user_id) else { return };
        let mut changed = false;
        for (root, key) in scans {
            let kind = match EventId::parse(&root) {
                Ok(id) => crate::threads::thread_unread(&self.room, &id, &me).await,
                Err(_) => crate::models::UnreadKind::None,
            };
            let mut state = self.state.locked();
            state.thread_scans.remove(&root);
            let previous = state.thread_unread.insert(root.clone(), (key, kind));
            if previous.map(|(_, k)| k) != Some(kind) {
                changed = true;
                // The row that leads the thread is built again with what was found.
                let stale: Vec<String> = state
                    .targets
                    .iter()
                    .filter(|(_, target)| matches!(target, TimelineEventItemId::EventId(id) if id.as_str() == root))
                    .map(|(row, _)| row.clone())
                    .collect();
                for row in stale {
                    state.cache.remove(&row);
                }
            }
        }
        if changed {
            self.dirty.notify_one();
        }
    }

    fn target(&self, row_id: &str) -> Result<TimelineEventItemId> {
        self.state.locked().targets.get(row_id).cloned().ok_or(XeniaError::NotFound)
    }

    fn event_id(&self, row_id: &str) -> Result<OwnedEventId> {
        match self.target(row_id)? {
            TimelineEventItemId::EventId(id) => Ok(id),
            TimelineEventItemId::TransactionId(_) => Err(XeniaError::NotFound),
        }
    }

    /// The room shows history only from when I joined (or was invited), and that moment is loaded.
    /// After a few empty pages in a row, my join is enough whatever the room says it shows: some
    /// servers hide what came before it anyway.
    fn hides_history_before_me(&self, state: &State, empty_pages: u32) -> bool {
        use matrix_sdk::ruma::events::room::history_visibility::HistoryVisibility;
        use matrix_sdk_ui::timeline::{MembershipChange, TimelineItemContent};
        let from_invite = match self.room.history_visibility_or_default() {
            HistoryVisibility::Joined => false,
            HistoryVisibility::Invited => true,
            _ if empty_pages >= 3 => true,
            _ => return false,
        };
        state.items.iter().filter_map(|item| item.as_event()).any(|event| match event.content() {
            TimelineItemContent::MembershipChange(change) if change.user_id().as_str() == self.core.user_id => {
                matches!(
                    change.change(),
                    Some(MembershipChange::Joined | MembershipChange::InvitationAccepted | MembershipChange::KnockAccepted)
                ) || (from_invite && matches!(change.change(), Some(MembershipChange::Invited)))
            }
            _ => false,
        })
    }

    async fn paginate_backwards(self: Arc<Self>, count: u16) {
        if self.paginating_back.swap(true, Ordering::AcqRel) {
            return;
        }
        let blocked = {
            let state = self.state.locked();
            state.is_at_start || state.history_hidden || state.history_failed_at.is_some_and(|at| at.elapsed() < HISTORY_RETRY)
        };
        if blocked {
            self.paginating_back.store(false, Ordering::Release);
            return;
        }
        self.state.locked().is_loading_older = true;
        self.dirty.notify_one();
        // A page of only hidden events (reactions, state changes) adds nothing to scroll to, and
        // with no new rows appearing the app would never ask again: keep going until something
        // visible arrives or the beginning is reached.
        let visible = |state: &State| {
            state.items.iter().filter(|i| i.as_event().is_some_and(|e| e.content().as_msglike().is_some())).count()
        };
        let before = visible(&self.state.locked());
        let mut empty_pages = 0;
        for _ in 0..5 {
            let oldest = oldest_event(&self.state.locked());
            let result = self.timeline.paginate_backwards(count).await;
            let mut state = self.state.locked();
            match result {
                Ok(hit_start) => {
                    state.is_at_start = hit_start;
                    state.history_failed_at = None;
                    // Where history is for members only, the server answers every page before
                    // my join with nothing and another page to ask for, all the way back to the
                    // room's creation: an empty page once my join is loaded is as far as I see.
                    if !hit_start && oldest_event(&state) == oldest {
                        empty_pages += 1;
                        state.history_hidden = self.hides_history_before_me(&state, empty_pages);
                    }
                }
                // Not a member yet (added but not joined), or the server won't show this room's
                // past: asking again won't change that.
                Err(error) if error.to_string().contains("M_FORBIDDEN") => {
                    state.history_hidden = true;
                    state.refused_before_joining = self.room.state() != matrix_sdk::RoomState::Joined;
                    break;
                }
                Err(error) => {
                    warn!("Loading history failed: {error}");
                    state.history_failed_at = Some(std::time::Instant::now());
                    break;
                }
            }
            if state.is_at_start || state.history_hidden || visible(&state) > before {
                break;
            }
        }
        let retry = {
            let mut state = self.state.locked();
            state.is_loading_older = false;
            state.is_ready = true;
            state.settled = true;
            // Opened offline with nothing kept: there's no row to scroll to and so nothing to ask
            // again with, so it asks again itself once the wait is over.
            state.history_failed_at.is_some() && visible(&state) == 0
        };
        self.paginating_back.store(false, Ordering::Release);
        self.dirty.notify_one();
        if retry {
            self.retry_history_later(count);
        }
    }

    /// Kept out of `paginate_backwards`, which it calls: a task spawned inside it would need its
    /// own future to be sendable before that's known.
    fn retry_history_later(self: &Arc<Self>, count: u16) {
        let weak = Arc::downgrade(self);
        crate::runtime::spawn(async move {
            tokio::time::sleep(HISTORY_RETRY).await;
            if let Some(shared) = weak.upgrade() {
                shared.paginate_backwards(count).await;
            }
        });
    }
}

/// The oldest event loaded, to tell whether a page of history added anything.
fn oldest_event(state: &State) -> Option<TimelineEventItemId> {
    state.items.iter().find_map(|item| item.as_event().map(|event| event.identifier()))
}

/// People joining, leaving or renaming themselves, which Settings can hide.
fn is_membership(row: &Raw) -> bool {
    matches!(row, Raw::Note(line) if matches!(line.note, Note::Membership { .. } | Note::Renamed { .. }))
}

/// The first message after the read marker, if there is one.
fn marker_anchor(rows: &[TimelineRow]) -> Option<String> {
    let at = rows.iter().position(|r| matches!(r, TimelineRow::ReadMarker { .. }))?;
    rows[at..].iter().find_map(|r| match r {
        TimelineRow::Message { message } => Some(message.id.clone()),
        _ => None,
    })
}

pub(crate) fn message_content(message: &ComposedMessage) -> RoomMessageEventContentWithoutRelation {
    let msgtype = match (&message.html, message.is_emote) {
        (Some(html), true) => MessageType::Emote(EmoteMessageEventContent::html(message.body.clone(), html.clone())),
        (None, true) => MessageType::Emote(EmoteMessageEventContent::plain(message.body.clone())),
        (Some(html), false) => MessageType::Text(TextMessageEventContent::html(message.body.clone(), html.clone())),
        (None, false) => MessageType::Text(TextMessageEventContent::plain(message.body.clone())),
    };
    let mut mentions = Mentions::with_user_ids(message.mentioned_user_ids.iter().filter_map(|u| u.parse().ok()));
    mentions.room = message.mentions_room;
    RoomMessageEventContentWithoutRelation::new(msgtype).add_mentions(mentions)
}

/// Reads a JPEG thumbnail for an attachment. A thumbnail that can't be read is left out rather
/// than failing the send.
async fn thumbnail(path: &str) -> Option<matrix_sdk::attachment::Thumbnail> {
    let data = tokio::fs::read(path).await.ok()?;
    let (width, height) = jpeg_size(&data)?;
    Some(matrix_sdk::attachment::Thumbnail {
        size: UInt::new(data.len() as u64)?,
        width: UInt::from(width),
        height: UInt::from(height),
        content_type: mime::IMAGE_JPEG,
        data,
    })
}

/// A JPEG's pixel size, from its first start-of-frame marker.
fn jpeg_size(data: &[u8]) -> Option<(u32, u32)> {
    if data.get(0..2)? != [0xFF, 0xD8] {
        return None;
    }
    let mut at = 2;
    while at + 9 < data.len() {
        if data[at] != 0xFF {
            return None;
        }
        let marker = data[at + 1];
        let length = usize::from(u16::from_be_bytes([data[at + 2], data[at + 3]]));
        // SOF0 to SOF15, except DHT (C4), JPG (C8) and DAC (CC).
        if (0xC0..=0xCF).contains(&marker) && ![0xC4, 0xC8, 0xCC].contains(&marker) {
            let height = u16::from_be_bytes([data[at + 5], data[at + 6]]);
            let width = u16::from_be_bytes([data[at + 7], data[at + 8]]);
            return Some((u32::from(width), u32::from(height)));
        }
        at += 2 + length;
    }
    None
}

/// A poll's opening event, with a plain-text copy for clients that can't show polls.
fn poll_start(
    question: &str,
    answers: &[String],
    max_selections: u32,
    is_disclosed: bool,
) -> Result<NewUnstablePollStartEventContent> {
    let question = question.trim();
    let answers: Vec<&str> = answers.iter().map(|a| a.trim()).filter(|a| !a.is_empty()).collect();
    if question.is_empty() || answers.len() < 2 {
        return Err(XeniaError::generic("a poll needs a question and two answers"));
    }
    let choices: Vec<UnstablePollAnswer> =
        answers.iter().enumerate().map(|(i, text)| UnstablePollAnswer::new(format!("answer-{i}"), *text)).collect();
    let choices =
        UnstablePollAnswers::try_from(choices).map_err(|_| XeniaError::generic("a poll has at most 20 answers"))?;
    let mut block = UnstablePollStartContentBlock::new(question, choices);
    block.max_selections = UInt::from(max_selections.clamp(1, answers.len() as u32));
    block.kind = if is_disclosed { PollKind::Disclosed } else { PollKind::Undisclosed };
    let fallback = std::iter::once(question.to_owned())
        .chain(answers.iter().enumerate().map(|(i, a)| format!("{}. {a}", i + 1)))
        .collect::<Vec<_>>()
        .join("\n");
    Ok(NewUnstablePollStartEventContent::plain_text(fallback, block))
}

fn uint(value: Option<u64>) -> Option<UInt> {
    value.and_then(UInt::new)
}

#[uniffi::export]
impl TimelineController {
    /// Loads older messages.
    pub async fn load_older(&self) {
        let shared = Arc::clone(&self.shared);
        run(shared.paginate_backwards(30)).await
    }

    /// Loads newer messages (after jumping to a message in the past).
    pub async fn load_newer(&self) {
        let shared = Arc::clone(&self.shared);
        run(async move {
            if shared.state.locked().is_at_end || shared.paginating_forward.swap(true, Ordering::AcqRel) {
                return;
            }
            match shared.timeline.paginate_forwards(30).await {
                Ok(hit_end) => shared.state.locked().is_at_end = hit_end,
                Err(error) => warn!("Loading newer messages failed: {error}"),
            }
            shared.paginating_forward.store(false, Ordering::Release);
            shared.dirty.notify_one();
        })
        .await
    }

    /// Sends a message, as a reply when `reply_to` names a row.
    pub async fn send(&self, message: ComposedMessage, reply_to: Option<String>) -> Result<()> {
        let shared = Arc::clone(&self.shared);
        let reply_to = reply_to.map(|row| shared.event_id(&row)).transpose()?;
        run(async move {
            let content = message_content(&message);
            match reply_to {
                Some(event_id) => shared.timeline.send_reply(content, event_id).await?,
                None => shared.timeline.send(RoomMessageEventContent::from(content).into()).await?,
            };
            Ok(())
        })
        .await
    }

    /// Replaces the text of one of my messages.
    pub async fn edit(&self, row_id: String, message: ComposedMessage) -> Result<()> {
        let shared = Arc::clone(&self.shared);
        let target = shared.target(&row_id)?;
        run(async move {
            shared.timeline.edit(&target, EditedContent::RoomMessage(message_content(&message))).await?;
            Ok(())
        })
        .await
    }

    /// Deletes a message (or cancels one that hasn't sent).
    pub async fn delete(&self, row_id: String) -> Result<()> {
        let shared = Arc::clone(&self.shared);
        let target = shared.target(&row_id)?;
        run(async move {
            shared.timeline.redact(&target, None).await?;
            Ok(())
        })
        .await
    }

    pub async fn toggle_reaction(&self, row_id: String, key: String) -> Result<()> {
        let shared = Arc::clone(&self.shared);
        let target = shared.target(&row_id)?;
        run(async move {
            shared.timeline.toggle_reaction(&target, &key).await?;
            Ok(())
        })
        .await
    }

    /// Tries a failed message again.
    pub async fn retry(&self, row_id: String) -> Result<()> {
        let shared = Arc::clone(&self.shared);
        run(async move {
            let item = {
                let state = shared.state.locked();
                state.items.iter().find(|i| i.unique_id().0 == row_id).cloned()
            };
            let handle =
                item.and_then(|i| i.as_event().and_then(|e| e.local_echo_send_handle())).ok_or(XeniaError::NotFound)?;
            handle.unwedge().await.map_err(XeniaError::generic)?;
            Ok(())
        })
        .await
    }

    pub async fn set_pinned(&self, row_id: String, pinned: bool) -> Result<()> {
        let shared = Arc::clone(&self.shared);
        let event_id = shared.event_id(&row_id)?;
        run(async move {
            if pinned {
                shared.room.pin_event(&event_id).await?;
            } else {
                shared.room.unpin_event(&event_id).await?;
            }
            shared.hub.refresh(shared.room.room_id().as_str());
            Ok(())
        })
        .await
    }

    /// "Typing" goes on keystrokes (the SDK throttles resends); "stopped" goes once.
    pub async fn set_typing(&self, typing: bool) {
        if !typing && !self.typing.load(Ordering::Relaxed) {
            return;
        }
        self.typing.store(typing, Ordering::Relaxed);
        let room = self.shared.room.clone();
        run(async move {
            let _ = room.typing_notice(typing).await;
        })
        .await
    }

    /// Marks everything shown as read (publicly or privately, per the setting). Cheap to call
    /// often: nothing is sent unless a newer message arrived since the last call, and the SDK
    /// drops receipts the server already has.
    pub async fn mark_read(&self) {
        let shared = Arc::clone(&self.shared);
        run(async move {
            let Some(latest) = shared.timeline.latest_event_id().await else { return };
            {
                let mut last = shared.last_marked.locked();
                if last.as_ref() == Some(&latest) {
                    return;
                }
                *last = Some(latest.clone());
            }
            let receipt = shared.core.read_receipt();
            let result = if shared.focus == TimelineFocus::Live {
                // The receipt and the fully-read marker (so other devices and the next visit
                // agree) go in one request.
                let receipts = matrix_sdk::room::Receipts::new().fully_read_marker(latest.clone());
                let receipts = match receipt {
                    ReceiptType::Read => receipts.public_read_receipt(latest),
                    _ => receipts.private_read_receipt(latest),
                };
                shared.timeline.send_multiple_receipts(receipts).await
            } else {
                // A thread's newest reply says nothing about the rest of the conversation.
                shared.timeline.send_single_receipt(receipt, latest).await.map(|_| ())
            };
            if let Err(error) = result {
                warn!("Marking read failed: {error}");
                // Let the next call try again.
                *shared.last_marked.locked() = None;
            }
            shared.hub.refresh(shared.room.room_id().as_str());
        })
        .await
    }

    /// Sends a photo, video, audio clip or file.
    pub async fn send_attachment(&self, attachment: Attachment, reply_to: Option<String>) -> Result<()> {
        let shared = Arc::clone(&self.shared);
        let reply_to = reply_to.map(|row| shared.event_id(&row)).transpose()?;
        run(async move {
            let mime: mime::Mime = attachment.mimetype.parse().unwrap_or(mime::APPLICATION_OCTET_STREAM);
            let size = uint(attachment.size);
            let info = match mime.type_() {
                mime::IMAGE => AttachmentInfo::Image(BaseImageInfo {
                    width: uint(attachment.width.map(u64::from)),
                    height: uint(attachment.height.map(u64::from)),
                    size,
                    blurhash: attachment.blurhash.clone(),
                    is_animated: None,
                }),
                mime::VIDEO => AttachmentInfo::Video(BaseVideoInfo {
                    duration: attachment.duration_ms.map(std::time::Duration::from_millis),
                    width: uint(attachment.width.map(u64::from)),
                    height: uint(attachment.height.map(u64::from)),
                    size,
                    blurhash: attachment.blurhash.clone(),
                }),
                mime::AUDIO => AttachmentInfo::Audio(BaseAudioInfo {
                    duration: attachment.duration_ms.map(std::time::Duration::from_millis),
                    size,
                    waveform: None,
                }),
                _ => AttachmentInfo::File(BaseFileInfo { size }),
            };
            let caption = attachment.caption.as_deref().map(str::trim).filter(|c| !c.is_empty()).map(|c| {
                FormattedBody::markdown(c)
                    .map(|f| TextMessageEventContent::html(c, f.body))
                    .unwrap_or_else(|| TextMessageEventContent::plain(c))
            });
            let thumbnail = match &attachment.thumbnail_path {
                Some(path) => thumbnail(path).await,
                None => None,
            };
            let config =
                AttachmentConfig { info: Some(info), caption, in_reply_to: reply_to, thumbnail, ..Default::default() };
            let source = AttachmentSource::File(PathBuf::from(&attachment.path));
            // Through the send queue: the photo appears at once as a local echo, and a failed
            // upload can be retried like any message.
            shared.timeline.send_attachment(source, mime, config).use_send_queue().await?;
            Ok(())
        })
        .await
    }

    /// Votes in a poll: the whole selection, replacing any earlier vote (empty withdraws it).
    pub async fn vote(&self, row_id: String, answer_ids: Vec<String>) -> Result<()> {
        let shared = Arc::clone(&self.shared);
        let event_id = shared.event_id(&row_id)?;
        run(async move {
            let content = UnstablePollResponseEventContent::new(answer_ids, event_id);
            shared.timeline.send(content.into()).await?;
            Ok(())
        })
        .await
    }

    /// Ends one of my polls, showing everyone the results.
    pub async fn end_poll(&self, row_id: String) -> Result<()> {
        let shared = Arc::clone(&self.shared);
        let event_id = shared.event_id(&row_id)?;
        run(async move {
            let content = UnstablePollEndEventContent::new("The poll has ended.", event_id);
            shared.timeline.send(content.into()).await?;
            Ok(())
        })
        .await
    }

    /// Starts a poll. `max_selections` above one lets people choose several answers.
    pub async fn create_poll(
        &self,
        question: String,
        answers: Vec<String>,
        max_selections: u32,
        is_disclosed: bool,
    ) -> Result<()> {
        let shared = Arc::clone(&self.shared);
        run(async move {
            let content = poll_start(&question, &answers, max_selections, is_disclosed)?;
            shared.timeline.send(UnstablePollStartEventContent::New(content).into()).await?;
            Ok(())
        })
        .await
    }

    /// Sends a copy of a message to another conversation: its text or file as it is, without
    /// its reply, thread or mentions, so nobody is notified twice.
    pub async fn forward(&self, row_id: String, to_room_id: String) -> Result<()> {
        let shared = Arc::clone(&self.shared);
        let msgtype = {
            let state = shared.state.locked();
            let item = state.items.iter().find(|i| i.unique_id().0 == row_id).ok_or(XeniaError::NotFound)?;
            let message = item.as_event().and_then(|e| e.content().as_message()).ok_or(XeniaError::NotFound)?;
            message.msgtype().clone()
        };
        run(async move {
            let target = RoomId::parse(&to_room_id)?;
            let room = shared.room.client().get_room(&target).ok_or(XeniaError::NotFound)?;
            let content = RoomMessageEventContent::new(msgtype).add_mentions(Mentions::new());
            room.send_queue().send(content.into()).await.map_err(XeniaError::generic)?;
            Ok(())
        })
        .await
    }

    /// Reports a message to the server's administrators.
    pub async fn report(&self, row_id: String, reason: Option<String>) -> Result<()> {
        let shared = Arc::clone(&self.shared);
        let event_id = shared.event_id(&row_id)?;
        run(async move {
            let reason = reason.map(|r| r.trim().to_owned()).filter(|r| !r.is_empty());
            shared.room.report_content(event_id, reason).await?;
            Ok(())
        })
        .await
    }

    /// Who has read a message, with when, and who in the room hasn't yet.
    pub async fn read_receipts(&self, row_id: String) -> Result<receipts::ReadReceipts> {
        let shared = Arc::clone(&self.shared);
        let (target, marks, sender) = {
            let state = shared.state.locked();
            let target = state.items.iter().position(|i| i.unique_id().0 == row_id).ok_or(XeniaError::NotFound)?;
            let sender = state.items[target].as_event().ok_or(XeniaError::NotFound)?.sender().to_string();
            let mut marks = receipts::ReadMarks::new();
            // Oldest first, so each person ends at their newest: a receipt, or a message of
            // their own (sending reads everything before it).
            for (index, item) in state.items.iter().enumerate() {
                let Some(event) = item.as_event() else { continue };
                for (user, receipt) in event.read_receipts() {
                    marks.insert(user.to_string(), (index, receipt.ts.map(|t| i64::from(t.get()))));
                }
                marks.insert(event.sender().to_string(), (index, Some(i64::from(event.timestamp().get()))));
            }
            (target, marks, sender)
        };
        run(async move {
            let members: Vec<Reader> = shared
                .room
                .members(matrix_sdk::RoomMemberships::JOIN)
                .await?
                .iter()
                .map(|m| Reader {
                    user_id: m.user_id().to_string(),
                    name: m.display_name().filter(|n| !n.trim().is_empty()).unwrap_or(m.user_id().as_str()).to_owned(),
                    avatar_url: m.avatar_url().map(|a| a.to_string()),
                })
                .collect();
            Ok(receipts::split(target, &marks, &members, &sender, &shared.core.user_id))
        })
        .await
    }

    /// A matrix.to link to a message, for sharing it with people in the conversation.
    pub async fn permalink(&self, row_id: String) -> Result<String> {
        let shared = Arc::clone(&self.shared);
        let event_id = shared.event_id(&row_id)?;
        run(async move {
            let uri = shared.room.matrix_to_event_permalink(event_id).await?;
            Ok(uri.to_string())
        })
        .await
    }

    /// One of my text messages as the composer should show it for editing, with its formatting
    /// and mentions; `None` for anything that isn't a text message.
    pub fn editable_text(&self, row_id: String) -> Option<crate::text::EditableText> {
        let state = self.shared.state.locked();
        let item = state.items.iter().find(|i| i.unique_id().0 == row_id)?;
        let message = item.as_event()?.content().as_message()?;
        let (body, html, is_emote) = match message.msgtype() {
            MessageType::Text(c) => (&c.body, crate::content::html_of(c.formatted.as_ref()), false),
            MessageType::Emote(c) => (&c.body, crate::content::html_of(c.formatted.as_ref()), true),
            _ => return None,
        };
        Some(crate::text::editable_text(body, html, is_emote))
    }

    /// Unfolds a group of notes.
    pub fn expand_notes(&self, group_id: String) {
        self.shared.state.locked().expanded.insert(group_id);
        self.shared.dirty.notify_one();
    }
}

impl Drop for TimelineController {
    fn drop(&mut self) {
        if self.typing.load(Ordering::Relaxed) {
            let room = self.shared.room.clone();
            crate::runtime::spawn(async move {
                let _ = room.typing_notice(false).await;
            });
        }
    }
}

#[uniffi::export]
impl XeniaClient {
    /// Opens a conversation, a thread or a moment in the past. The first screenful loads right
    /// away; updates arrive on `listener` until the controller is dropped.
    pub async fn timeline(
        &self,
        room_id: String,
        focus: TimelineFocus,
        listener: Arc<dyn TimelineListener>,
    ) -> Result<Arc<TimelineController>> {
        let room = self.sdk_room(&room_id).await?;
        let core = self.core().await?;
        let hub = self.hub().await?;
        let sync = self.sync_service().await;
        run(async move {
            if let Some(sync) = sync {
                sync.room_list_service().set_room_subscriptions(&[room.room_id()]).await;
            }
            let (sdk_focus, prefix, tracking) = match &focus {
                TimelineFocus::Live => (
                    SdkFocus::Live { hide_threaded_events: true },
                    None,
                    TimelineReadReceiptTracking::MessageLikeEvents,
                ),
                TimelineFocus::Thread { root_event_id } => (
                    SdkFocus::Thread { root_event_id: EventId::parse(root_event_id)? },
                    Some(format!("thread:{root_event_id}:")),
                    TimelineReadReceiptTracking::MessageLikeEvents,
                ),
                TimelineFocus::Event { event_id } => (
                    SdkFocus::Event {
                        target: EventId::parse(event_id)?,
                        num_context_events: 40,
                        thread_mode: TimelineEventFocusThreadMode::Automatic { hide_threaded_events: true },
                    },
                    Some(format!("event:{event_id}:")),
                    TimelineReadReceiptTracking::Disabled,
                ),
            };
            let mut builder = room.timeline_builder().with_focus(sdk_focus).track_read_marker_and_receipts(tracking);
            if let Some(prefix) = prefix {
                builder = builder.with_internal_id_prefix(prefix);
            }
            let timeline = Arc::new(builder.build().await?);

            let is_group = !room.compute_is_dm().await.unwrap_or(false);
            let can_redact_others = room
                .power_levels()
                .await
                .ok()
                .zip(core.client.user_id())
                .is_some_and(|(p, me)| p.user_can_redact_event_of_other(me));

            let shared = Arc::new(Shared {
                timeline: Arc::clone(&timeline),
                room: room.clone(),
                core,
                hub,
                listener: Arc::clone(&listener),
                is_group,
                can_redact_others,
                state: Mutex::new(State {
                    is_at_end: !matches!(focus, TimelineFocus::Event { .. }),
                    ..State::default()
                }),
                focus,
                dirty: Notify::new(),
                paginating_back: AtomicBool::new(false),
                paginating_forward: AtomicBool::new(false),
                last_marked: Mutex::new(None),
            });

            let mut tasks = Vec::new();

            // Publisher: one rebuild per burst of changes.
            let publisher = Arc::clone(&shared);
            tasks.push(TaskGuard::spawn(async move {
                loop {
                    publisher.dirty.notified().await;
                    tokio::time::sleep(COALESCE).await;
                    publisher.rebuild_and_publish();
                }
            }));

            // Items.
            let (items, mut stream) = timeline.subscribe().await;
            shared.state.locked().items = items;
            shared.dirty.notify_one();
            let follower = Arc::clone(&shared);
            tasks.push(TaskGuard::spawn(async move {
                while let Some(diffs) = stream.next().await {
                    {
                        let mut state = follower.state.locked();
                        for diff in diffs {
                            diff.apply(&mut state.items);
                        }
                    }
                    follower.dirty.notify_one();
                }
            }));

            // The live timeline reports its own back-pagination state.
            if let Some((status, mut updates)) = timeline.live_back_pagination_status().await {
                let apply = |shared: &Shared, status: matrix_sdk::event_cache::PaginationStatus| {
                    let mut state = shared.state.locked();
                    match status {
                        matrix_sdk::event_cache::PaginationStatus::Idle { hit_timeline_start } => {
                            state.is_loading_older = false;
                            state.is_at_start = hit_timeline_start;
                        }
                        matrix_sdk::event_cache::PaginationStatus::Paginating => state.is_loading_older = true,
                    }
                };
                apply(&shared, status);
                let watcher = Arc::clone(&shared);
                tasks.push(TaskGuard::spawn(async move {
                    while let Some(status) = updates.next().await {
                        apply(&watcher, status);
                        watcher.dirty.notify_one();
                    }
                }));
            }

            // Typing.
            let (typing_guard, mut typing) = room.subscribe_to_typing_notifications();
            let typing_shared = Arc::clone(&shared);
            let typing_listener = Arc::clone(&listener);
            tasks.push(TaskGuard::spawn(async move {
                let _guard = typing_guard;
                loop {
                    let user_ids = match typing.recv().await {
                        Ok(user_ids) => user_ids,
                        // Only the latest list matters, and the next one is complete.
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                    };
                    let people: Vec<Reader> = {
                        let state = typing_shared.state.locked();
                        user_ids
                            .iter()
                            .filter(|u| u.as_str() != typing_shared.core.user_id)
                            .map(|u| state.people.reader(u.as_str()))
                            .collect()
                    };
                    typing_listener.on_typing(people);
                }
            }));

            // My receipts in threads, from any device: the summaries don't carry them, so a read
            // has that thread looked at again.
            let receipts = shared
                .core
                .client
                .observe_room_events::<matrix_sdk::ruma::events::receipt::SyncReceiptEvent, Room>(room.room_id());
            let receipts_shared = Arc::clone(&shared);
            tasks.push(TaskGuard::spawn(async move {
                let mut receipts = receipts.subscribe();
                while let Some((event, _room)) = receipts.next().await {
                    let me = receipts_shared.core.user_id.as_str();
                    let roots: HashSet<String> = event
                        .content
                        .values()
                        .flat_map(|by_type| by_type.values())
                        .flat_map(|by_user| by_user.iter())
                        .filter(|(user, _)| user.as_str() == me)
                        .filter_map(|(_, receipt)| match &receipt.thread {
                            matrix_sdk::ruma::events::receipt::ReceiptThread::Thread(root) => Some(root.to_string()),
                            _ => None,
                        })
                        .collect();
                    if roots.is_empty() {
                        continue;
                    }
                    // Worked out again for the reply it was worked out for; the row keeps what it
                    // shows until the answer changes.
                    let scans: Vec<(String, String)> = {
                        let mut state = receipts_shared.state.locked();
                        let known: Vec<(String, String)> = roots
                            .into_iter()
                            .filter_map(|root| state.thread_unread.get(&root).map(|(key, _)| (root, key.clone())))
                            .collect();
                        known.into_iter().filter(|(root, _)| state.thread_scans.insert(root.clone())).collect()
                    };
                    if !scans.is_empty() {
                        Arc::clone(&receipts_shared).scan_threads(scans).await;
                    }
                }
            }));

            // Names for receipts and typing: everyone in the room, once.
            let people_shared = Arc::clone(&shared);
            tasks.push(TaskGuard::spawn(async move {
                if let Ok(members) = people_shared.room.members(matrix_sdk::RoomMemberships::JOIN).await {
                    {
                        let mut state = people_shared.state.locked();
                        for m in members {
                            if let Some(name) = m.display_name().filter(|n| !n.trim().is_empty()) {
                                state.people.names.insert(
                                    m.user_id().to_string(),
                                    (name.to_owned(), m.avatar_url().map(|a| a.to_string())),
                                );
                            }
                        }
                        // Rows cached before the names arrived are rebuilt.
                        state.cache.clear();
                    }
                    people_shared.dirty.notify_one();
                }
            }));

            // The first screenful.
            let first = Arc::clone(&shared);
            crate::runtime::spawn(async move {
                let has_items = first.state.locked().items.iter().filter(|i| i.as_event().is_some()).count();
                if has_items < 20 {
                    first.clone().paginate_backwards(40).await;
                } else {
                    {
                        let mut state = first.state.locked();
                        state.is_ready = true;
                        state.settled = true;
                    }
                    first.dirty.notify_one();
                }
            });

            Ok(Arc::new(TimelineController { shared, typing: AtomicBool::new(false), _tasks: tasks }))
        })
        .await
    }
}

#[uniffi::export]
impl XeniaClient {
    /// Sends a message without opening the conversation (a reply from a notification).
    pub async fn send_message(&self, room_id: String, message: ComposedMessage) -> Result<()> {
        let room = self.sdk_room(&room_id).await?;
        run(async move {
            room.send(RoomMessageEventContent::from(message_content(&message))).await?;
            Ok(())
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::{jpeg_size, poll_start};

    #[test]
    fn polls_need_a_question_and_two_real_answers() {
        assert!(poll_start("Lunch?", &["Tacos".into(), "  ".into()], 1, true).is_err());
        assert!(poll_start("  ", &["Tacos".into(), "Pho".into()], 1, true).is_err());
        let poll = poll_start(" Lunch? ", &["Tacos".into(), "".into(), "Pho".into()], 9, false).unwrap();
        assert_eq!(poll.poll_start.question.text, "Lunch?");
        assert_eq!(poll.poll_start.answers.len(), 2);
        // Never more choices than answers.
        assert_eq!(u64::from(poll.poll_start.max_selections), 2);
        assert_eq!(poll.text.as_deref(), Some("Lunch?\n1. Tacos\n2. Pho"));
    }

    #[test]
    fn jpeg_sizes_come_from_the_frame_header() {
        // SOI, an APP0 segment of 4 bytes, then SOF0 with height 480 and width 640.
        let jpeg = [
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x01, 0xE0, 0x02, 0x80, 0x03,
        ];
        assert_eq!(jpeg_size(&jpeg), Some((640, 480)));
        assert_eq!(jpeg_size(b"not a jpeg"), None);
        assert_eq!(jpeg_size(&[0xFF, 0xD8, 0x00]), None);
    }
}
