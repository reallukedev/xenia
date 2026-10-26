//! The live list of conversations.
//!
//! The SDK's room list sends diffs of `Room`s as sync runs. This keeps a mirror of it, builds a
//! [`RoomSummary`] for each room that changed (in parallel, newest read wins), and hands the app a
//! whole, ordered snapshot, coalesced so a burst of updates is one redraw.

pub(crate) mod rules;
mod summary;

use std::{
    collections::{HashMap, HashSet},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use eyeball_im::{Vector, VectorDiff};
use futures_util::{StreamExt, pin_mut};
use matrix_sdk::{Room, RoomState, notification_settings::RoomNotificationMode, ruma::events::tag::TagEvent};
use matrix_sdk_ui::room_list_service::{
    RoomListLoadingState, RoomListService,
    filters::{new_filter_all, new_filter_deduplicate_versions, new_filter_non_left, new_filter_not, new_filter_space},
};
use tokio::sync::{Notify, Semaphore};
use tracing::warn;

use self::summary::{LookBack, latest_is_edit, look_further_back, with_details};
pub(crate) use self::summary::{SummaryContext, build_summary};
use crate::{
    client::Core,
    models::{RoomPreview, RoomSummary},
    notifications::incoming_message,
    runtime::{TaskGuard, spawn},
    sync::MutexExt,
};

/// Rooms asked for per page. The lists are split and filtered in the app, so everything the
/// account has should arrive; the next page is requested as soon as one fills.
const PAGE_SIZE: usize = 200;
/// How long to gather updates before publishing: under a frame, so it never reads as lag.
const COALESCE: Duration = Duration::from_millis(24);
/// Events the room list syncs per room. The SDK previews the newest suitable one it has, so this
/// is enough to see past a few reactions, edits or state changes without a big first sync; rooms
/// that need more look further back on their own (see `look_further_back`).
pub(crate) const LIST_TIMELINE_LIMIT: u32 = 10;
/// Rooms looking further back for a preview at once, so a first sign-in doesn't flood the server.
const LOOK_BACKS_AT_ONCE: usize = 4;
/// Look-backs a session starts at most, retries included, however many rooms are quiet.
const MAX_LOOK_BACKS: usize = 200;

#[derive(Default)]
struct State {
    rooms: Vector<Room>,
    summaries: HashMap<String, RoomSummary>,
    /// Per room, the newest summary read started; an older read that finishes later is dropped.
    reads: HashMap<String, u64>,
    drafts: HashMap<String, String>,
    drafts_loaded: HashSet<String>,
    /// Rooms that looked further back for a preview and got an answer, so each does it once.
    looked_back: HashSet<String>,
    /// Rooms waiting to look back, or looking now.
    looking_back: HashSet<String>,
    /// Look-backs started this session, toward `MAX_LOOK_BACKS`.
    look_backs_started: usize,
    modes: HashMap<String, RoomNotificationMode>,
    loaded: bool,
    snapshot: Arc<Vec<RoomSummary>>,
    /// Whether the last published snapshot was sent as loaded, so the change to loaded publishes.
    published_loaded: bool,
    /// Whether anything was published yet: the first (maybe empty) snapshot always goes out.
    published: bool,
}

pub(crate) struct RoomListHub {
    core: Arc<Core>,
    state: Arc<Mutex<State>>,
    dirty: Arc<Notify>,
    tasks: Mutex<Vec<TaskGuard>>,
    look_backs: Arc<Semaphore>,
    /// Look-backs under way, by room: stopping the list cancels them.
    look_back_tasks: Mutex<HashMap<String, TaskGuard>>,
    /// Signed out: refreshes already under way finish quietly, announcing nothing.
    stopped: AtomicBool,
}

impl RoomListHub {
    pub(crate) fn new(core: Arc<Core>) -> Arc<Self> {
        Arc::new(Self {
            core,
            state: Arc::default(),
            dirty: Arc::new(Notify::new()),
            tasks: Mutex::default(),
            look_backs: Arc::new(Semaphore::new(LOOK_BACKS_AT_ONCE)),
            look_back_tasks: Mutex::default(),
            stopped: AtomicBool::new(false),
        })
    }

    /// Starts following the room list service's rooms.
    pub(crate) fn start(self: &Arc<Self>, service: Arc<RoomListService>) {
        let mut tasks = self.tasks.locked();

        // Publisher: waits for something to change, gathers a moment, publishes one snapshot.
        let hub = Arc::clone(self);
        tasks.push(TaskGuard::spawn(async move {
            loop {
                hub.dirty.notified().await;
                tokio::time::sleep(COALESCE).await;
                hub.publish();
            }
        }));

        // The list itself.
        let hub = Arc::clone(self);
        tasks.push(TaskGuard::spawn(async move {
            // It only fails while the service itself is starting or broken: ask again rather than
            // leave the list loading forever.
            let room_list = loop {
                match service.all_rooms().await {
                    Ok(list) => break list,
                    Err(error) => {
                        warn!("The room list didn't start: {error}");
                        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
                    }
                }
            };
            let loading = room_list.loading_state();
            let loading_hub = Arc::clone(&hub);
            let _loading = TaskGuard::spawn(async move {
                let mut loading = loading;
                loop {
                    if matches!(loading.get(), RoomListLoadingState::Loaded { .. }) {
                        loading_hub.state.locked().loaded = true;
                        loading_hub.dirty.notify_one();
                    }
                    if loading.next().await.is_none() {
                        break;
                    }
                }
            });

            let (stream, controller) = room_list.entries_with_dynamic_adapters(PAGE_SIZE);
            // Chats and Rooms are views of one list, split in the app, so both stay live for
            // the badges. The SDK only drops what no list shows: left rooms, spaces, and rooms
            // replaced by a newer version.
            controller.set_filter(Box::new(new_filter_all(vec![
                Box::new(new_filter_non_left()),
                Box::new(new_filter_not(Box::new(new_filter_space()))),
                Box::new(new_filter_deduplicate_versions()),
            ])));
            pin_mut!(stream);
            let mut pages = 1;
            while let Some(diffs) = stream.next().await {
                let changed = hub.apply(diffs);
                let count = hub.state.locked().rooms.len();
                if count >= pages * PAGE_SIZE {
                    pages += 1;
                    controller.add_one_page();
                }
                for room in changed {
                    hub.refresh_room(room);
                }
                hub.dirty.notify_one();
            }
        }));

        // Pins moved on another device: their order lives in the room's tags, which change
        // nothing else the list watches.
        let hub = Arc::clone(self);
        tasks.push(TaskGuard::spawn(async move {
            let tags = hub.core.client.observe_events::<TagEvent, Room>();
            let mut tags = tags.subscribe();
            while let Some((_, room)) = tags.next().await {
                hub.refresh_room(room);
            }
        }));

        // Notification modes: read now, and again whenever the push rules change.
        let hub = Arc::clone(self);
        tasks.push(TaskGuard::spawn(async move {
            let settings = hub.core.client.notification_settings().await;
            let mut changes = settings.subscribe_to_changes();
            loop {
                let rooms = settings.get_rooms_with_user_defined_rules(Some(true)).await;
                let mut modes = HashMap::new();
                for id in rooms {
                    if let Ok(room_id) = matrix_sdk::ruma::RoomId::parse(&id)
                        && let Some(mode) = settings.get_user_defined_room_notification_mode(&room_id).await
                    {
                        modes.insert(id, mode);
                    }
                }
                let changed = {
                    let mut state = hub.state.locked();
                    let changed = state.modes != modes;
                    state.modes = modes;
                    changed
                };
                if changed {
                    hub.refresh_all();
                }
                // Falling behind only means more changes than reads: read the modes again.
                if let Err(tokio::sync::broadcast::error::RecvError::Closed) = changes.recv().await {
                    break;
                }
            }
        }));
    }

    /// Applies the SDK's diffs to the mirror and returns the rooms that are new or changed.
    fn apply(&self, diffs: Vec<VectorDiff<matrix_sdk_ui::room_list_service::RoomListItem>>) -> Vec<Room> {
        let mut state = self.state.locked();
        let mut changed = Vec::new();
        for diff in diffs {
            let diff = diff.map(|item| item.into_inner());
            match &diff {
                VectorDiff::Append { values } | VectorDiff::Reset { values } => changed.extend(values.iter().cloned()),
                VectorDiff::PushFront { value }
                | VectorDiff::PushBack { value }
                | VectorDiff::Insert { value, .. }
                | VectorDiff::Set { value, .. } => changed.push(value.clone()),
                _ => {}
            }
            diff.apply(&mut state.rooms);
        }
        changed
    }

    /// Rebuilds one room's summary in the background.
    pub(crate) fn refresh_room(self: &Arc<Self>, room: Room) {
        let id = room.room_id().to_string();
        let seq = {
            let mut state = self.state.locked();
            let seq = state.reads.get(&id).copied().unwrap_or(0) + 1;
            state.reads.insert(id.clone(), seq);
            seq
        };
        let hub = Arc::clone(self);
        spawn(async move {
            let needs_draft = !hub.state.locked().drafts_loaded.contains(&id);
            if needs_draft {
                let draft = room.load_composer_draft(None).await.ok().flatten().map(|d| d.plain_text);
                let mut state = hub.state.locked();
                state.drafts_loaded.insert(id.clone());
                if let Some(text) = draft.filter(|t| !t.trim().is_empty()) {
                    state.drafts.entry(id.clone()).or_insert(text);
                }
            }
            let (mode, draft) = {
                let state = hub.state.locked();
                (state.modes.get(&id).cloned(), state.drafts.get(&id).cloned())
            };
            let my_name = hub.core.my_name();
            let summary =
                build_summary(&room, SummaryContext { me: &hub.core.user_id, my_name: &my_name, mode, draft }).await;
            let is_edit = latest_is_edit(&room);
            let needs_look_back =
                matches!(summary.preview, RoomPreview::Empty { .. }) && room.state() == RoomState::Joined;
            let (notification, look_back) = {
                let mut state = hub.state.locked();
                if state.reads.get(&id) != Some(&seq) {
                    return;
                }
                let previous = state.summaries.get(&id);
                // An edit alone isn't news; one that came in with a new message (the counts
                // went up) still announces it.
                let only_an_edit = is_edit
                    && previous.is_some_and(|p| {
                        summary.unread_count <= p.unread_count && summary.mention_count <= p.mention_count
                    });
                let notification = if state.loaded && !only_an_edit {
                    incoming_message(&summary, previous, &hub.core.notification_context(), &hub.core.keywords())
                } else {
                    None
                };
                let look_back = needs_look_back
                    && !state.looked_back.contains(&id)
                    && state.look_backs_started < MAX_LOOK_BACKS
                    && state.looking_back.insert(id.clone());
                if look_back {
                    state.look_backs_started += 1;
                }
                state.summaries.insert(id, summary);
                (notification, look_back)
            };
            if look_back {
                hub.look_back(room.clone());
            }
            if let Some(message) = notification {
                let message = with_details(&room, message).await;
                if !hub.stopped.load(Ordering::Relaxed) {
                    hub.core.listener.on_incoming_message(message);
                }
            }
            hub.dirty.notify_one();
        });
    }

    /// Finds an older event to preview for a room whose synced events had nothing to show.
    fn look_back(self: &Arc<Self>, room: Room) {
        let id = room.room_id().to_string();
        let hub = Arc::clone(self);
        let key = id.clone();
        // Held while the task is stored, so it can't finish and remove itself first.
        let mut tasks = self.look_back_tasks.locked();
        let task = TaskGuard::spawn(async move {
            let outcome = match hub.look_backs.acquire().await {
                Ok(_permit) if !hub.stopped.load(Ordering::Relaxed) => look_further_back(&room, &hub.stopped).await,
                _ => LookBack::Stopped,
            };
            // First, so a retry stored under the same room isn't the one removed. (This drops
            // the task's own guard; nothing below waits, so it runs to the end.)
            hub.look_back_tasks.locked().remove(&key);
            {
                let mut state = hub.state.locked();
                state.looking_back.remove(&key);
                // A failure (offline, say) may look again when the room next changes.
                if matches!(outcome, LookBack::Done { .. }) {
                    state.looked_back.insert(key);
                }
            }
            if outcome == (LookBack::Done { refresh: true }) && !hub.stopped.load(Ordering::Relaxed) {
                hub.refresh_room(room);
            }
        });
        tasks.insert(id, task);
    }

    /// Rebuilds every summary, for changes the list doesn't announce (mute, my display name).
    pub(crate) fn refresh_all(self: &Arc<Self>) {
        let rooms: Vec<Room> = self.state.locked().rooms.iter().cloned().collect();
        for room in rooms {
            self.refresh_room(room);
        }
    }

    /// Rebuilds one room's summary by ID, if it's in the list.
    pub(crate) fn refresh(self: &Arc<Self>, room_id: &str) {
        let room = self.state.locked().rooms.iter().find(|r| r.room_id().as_str() == room_id).cloned();
        if let Some(room) = room {
            self.refresh_room(room);
        }
    }

    fn publish(&self) {
        let (snapshot, loaded) = {
            let mut state = self.state.locked();
            let rooms: Vec<RoomSummary> =
                state.rooms.iter().filter_map(|room| state.summaries.get(room.room_id().as_str()).cloned()).collect();
            // Loaded means every room has its summary, so an empty list really is empty.
            let loaded = state.loaded && rooms.len() == state.rooms.len();
            if state.published && rooms == *state.snapshot && state.published_loaded == loaded {
                return;
            }
            state.published = true;
            state.published_loaded = loaded;
            state.snapshot = Arc::new(rooms);
            (Arc::clone(&state.snapshot), loaded)
        };
        self.core.listener.on_rooms_changed(snapshot.as_ref().clone(), loaded);
    }

    /// The latest snapshot, in list order.
    pub(crate) fn snapshot(&self) -> Arc<Vec<RoomSummary>> {
        Arc::clone(&self.state.locked().snapshot)
    }

    /// A room from the list, for timelines and actions.
    pub(crate) fn room(&self, room_id: &str) -> Option<Room> {
        let state = self.state.locked();
        state.rooms.iter().find(|r| r.room_id().as_str() == room_id).cloned()
    }

    /// Remembers a room's draft for the list's "Draft" line.
    pub(crate) fn set_draft(self: &Arc<Self>, room_id: &str, text: Option<String>) {
        {
            let mut state = self.state.locked();
            match text.filter(|t| !t.trim().is_empty()) {
                Some(t) => state.drafts.insert(room_id.to_owned(), t),
                None => state.drafts.remove(room_id),
            };
        }
        self.refresh(room_id);
    }

    pub(crate) fn stop(&self) {
        self.stopped.store(true, Ordering::Relaxed);
        self.tasks.locked().clear();
        self.look_back_tasks.locked().clear();
    }
}

impl Drop for RoomListHub {
    fn drop(&mut self) {
        self.stop();
    }
}
