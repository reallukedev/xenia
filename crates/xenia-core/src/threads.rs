//! A room's threads, most recently active first.

use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Mutex},
};

use futures_util::StreamExt;
use matrix_sdk_ui::timeline::{
    RoomExt, ThreadListPaginationState, ThreadListService, TimelineDetails,
    thread_list_service::{ThreadListItem, ThreadListItemEvent},
};

use matrix_sdk::ruma::{EventId, OwnedEventId, OwnedUserId, UserId};

use crate::{
    client::XeniaClient,
    content::{Actor, Body, Summary, summarize},
    error::Result,
    models::UnreadKind,
    runtime::{TaskGuard, run},
    sync::MutexExt,
};

/// One message in a thread list row.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ThreadMessage {
    pub event_id: String,
    pub sender_id: String,
    pub sender_name: String,
    pub sender_avatar_url: Option<String>,
    pub is_own: bool,
    pub body: Body,
    pub timestamp_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ThreadEntry {
    pub root: ThreadMessage,
    pub latest: Option<ThreadMessage>,
    pub reply_count: u32,
    /// When the thread last had activity, for sorting.
    pub activity_ms: i64,
    /// Replies I haven't read, and whether one of them is about me.
    pub unread: UnreadKind,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ThreadListUpdate {
    pub threads: Vec<ThreadEntry>,
    pub is_loading: bool,
    pub is_at_end: bool,
}

#[uniffi::export(with_foreign)]
pub trait ThreadListListener: Send + Sync {
    fn on_update(&self, update: ThreadListUpdate);
}

#[derive(uniffi::Object)]
pub struct ThreadList {
    service: Arc<ThreadListService>,
    _tasks: Vec<TaskGuard>,
}

fn message(e: &ThreadListItemEvent, me: &str) -> ThreadMessage {
    let (name, avatar): (Option<String>, Option<String>) = match &e.sender_profile {
        TimelineDetails::Ready(p) => (
            p.display_name.clone().filter(|n: &String| !n.trim().is_empty()),
            p.avatar_url.as_ref().map(|a| a.to_string()),
        ),
        _ => (None, None),
    };
    let sender_name = name.unwrap_or_else(|| e.sender.to_string());
    let body = e
        .content
        .as_ref()
        .and_then(|c| match summarize(c, Actor { name: &sender_name, is_you: e.is_own }, me) {
            Summary::Message { body, .. } => Some(body),
            _ => None,
        })
        .unwrap_or(Body::Unsupported);
    ThreadMessage {
        event_id: e.event_id.to_string(),
        sender_id: e.sender.to_string(),
        sender_name,
        sender_avatar_url: avatar,
        is_own: e.is_own,
        body,
        timestamp_ms: e.timestamp.get().into(),
    }
}

/// What a listed thread's unread state was worked out for: its latest reply.
fn latest_key(item: &ThreadListItem) -> String {
    item.latest_event.as_ref().map(|e| e.event_id.to_string()).unwrap_or_default()
}

fn entries(items: &[ThreadListItem], me: &str, unread: &HashMap<String, (String, UnreadKind)>) -> Vec<ThreadEntry> {
    let mut out: Vec<ThreadEntry> = items
        .iter()
        .map(|item| {
            let root = message(&item.root_event, me);
            let latest = item.latest_event.as_ref().map(|e| message(e, me));
            let activity_ms = latest.as_ref().map(|l| l.timestamp_ms).unwrap_or(root.timestamp_ms);
            let unread = match unread.get(&root.event_id) {
                Some((key, kind)) if *key == latest_key(item) => *kind,
                _ => UnreadKind::None,
            };
            ThreadEntry { root, latest, reply_count: item.num_replies, activity_ms, unread }
        })
        .collect();
    out.sort_by_key(|a| std::cmp::Reverse(a.activity_ms));
    out
}

#[uniffi::export]
impl ThreadList {
    /// Loads the next page of threads.
    pub async fn load_more(&self) {
        let service = Arc::clone(&self.service);
        run(async move {
            if let Err(error) = service.paginate().await {
                tracing::warn!("Loading threads failed: {error}");
            }
        })
        .await
    }
}

#[uniffi::export]
impl XeniaClient {
    /// Follows a room's threads. The first page loads right away.
    pub async fn thread_list(&self, room_id: String, listener: Arc<dyn ThreadListListener>) -> Result<Arc<ThreadList>> {
        let room = self.sdk_room(&room_id).await?;
        let me = self.core().await?.user_id.clone();
        run(async move {
            let service = Arc::new(room.thread_list_service());
            let (initial, mut stream) = service.subscribe_to_items_updates();
            let mut pagination = service.subscribe_to_pagination_state_updates();
            let items = Arc::new(Mutex::new(initial.into_iter().collect::<eyeball_im::Vector<_>>()));
            let unread: Arc<Mutex<HashMap<String, (String, UnreadKind)>>> = Arc::default();
            // What's been asked for already, by root and latest reply, so each publish while a
            // scan runs doesn't queue the same threads again.
            let asked: Arc<Mutex<HashSet<(String, String)>>> = Arc::default();
            // Threads whose unread state needs working out, from their replies.
            let (scan_tx, mut scan_rx) = tokio::sync::mpsc::unbounded_channel::<Vec<(String, String)>>();

            let publish = {
                let items = Arc::clone(&items);
                let service = Arc::clone(&service);
                let listener = Arc::clone(&listener);
                let unread = Arc::clone(&unread);
                let asked = Arc::clone(&asked);
                let me = me.clone();
                move || {
                    // Held through the call, so two tasks publishing at once can't deliver an
                    // older list after a newer one.
                    let items = items.locked();
                    let list: Vec<ThreadListItem> = items.iter().cloned().collect();
                    let (is_loading, is_at_end) = match service.pagination_state() {
                        ThreadListPaginationState::Loading => (true, false),
                        ThreadListPaginationState::Idle { end_reached } => (false, end_reached),
                    };
                    let known = unread.locked().clone();
                    let missing: Vec<(String, String)> = list
                        .iter()
                        .filter(|item| item.latest_event.as_ref().is_some_and(|e| !e.is_own))
                        .map(|item| (item.root_event.event_id.to_string(), latest_key(item)))
                        .filter(|(root, key)| known.get(root).is_none_or(|(k, _)| k != key))
                        .filter(|pair| asked.locked().insert(pair.clone()))
                        .collect();
                    if !missing.is_empty() {
                        let _ = scan_tx.send(missing);
                    }
                    listener.on_update(ThreadListUpdate {
                        threads: entries(&list, &me, &known),
                        is_loading,
                        is_at_end,
                    });
                }
            };

            let scan_task = {
                let publish = publish.clone();
                let unread = Arc::clone(&unread);
                let room = room.clone();
                let me = me.clone();
                TaskGuard::spawn(async move {
                    let Ok(me) = UserId::parse(&me) else { return };
                    while let Some(scans) = scan_rx.recv().await {
                        let mut changed = false;
                        for (root, key) in scans {
                            if unread.locked().get(&root).is_some_and(|(k, _)| *k == key) {
                                continue;
                            }
                            let Ok(id) = EventId::parse(&root) else { continue };
                            let kind = thread_unread(&room, &id, &me).await;
                            unread.locked().insert(root, (key, kind));
                            changed |= kind != UnreadKind::None;
                        }
                        if changed {
                            publish();
                        }
                    }
                })
            };

            let items_task = {
                let items = Arc::clone(&items);
                let publish = publish.clone();
                TaskGuard::spawn(async move {
                    while let Some(diffs) = stream.next().await {
                        {
                            let mut list = items.locked();
                            for diff in diffs {
                                diff.apply(&mut list);
                            }
                        }
                        publish();
                    }
                })
            };
            let pagination_task = {
                let publish = publish.clone();
                TaskGuard::spawn(async move {
                    while pagination.next().await.is_some() {
                        publish();
                    }
                })
            };
            publish();
            let first = Arc::clone(&service);
            crate::runtime::spawn(async move {
                if let Err(error) = first.paginate().await {
                    tracing::warn!("Loading threads failed: {error}");
                }
            });
            Ok(Arc::new(ThreadList { service, _tasks: vec![items_task, pagination_task, scan_task] }))
        })
        .await
    }
}

/// Whether a thread has replies I haven't read, and whether any of them is about me: a
/// highlight from the push rules (a mention, @room from someone allowed to, a keyword) or my ID
/// in `m.mentions`. From the replies this device has, after my receipt in that thread.
pub(crate) async fn thread_unread(room: &matrix_sdk::Room, root: &EventId, me: &UserId) -> UnreadKind {
    use matrix_sdk::ruma::events::{
        receipt::{ReceiptThread, ReceiptType},
        relation::RelationType,
    };
    // Public and private receipts move separately (the setting can change): the later one counts.
    let mut read: Vec<OwnedEventId> = Vec::with_capacity(2);
    for kind in [ReceiptType::Read, ReceiptType::ReadPrivate] {
        let thread = ReceiptThread::Thread(root.to_owned());
        if let Ok(Some((id, _))) = room.load_user_receipt(kind, &thread, me).await {
            read.push(id);
        }
    }
    let Ok((cache, _handles)) = room.event_cache().await else { return UnreadKind::None };
    let Ok(replies) = cache.find_event_relations(root, Some(vec![RelationType::Thread])).await else {
        return UnreadKind::None;
    };
    let start = replies
        .iter()
        .rposition(|e| e.event_id().is_some_and(|id| read.iter().any(|r| r == id)))
        .map_or(0, |at| at + 1);
    let mut kind = UnreadKind::None;
    for event in &replies[start..] {
        let sender = event.raw().get_field::<OwnedUserId>("sender").ok().flatten();
        if sender.as_deref() == Some(me) {
            // A reply of mine means I'd read what came before it.
            kind = UnreadKind::None;
            continue;
        }
        let highlighted = event.push_actions().is_some_and(|actions| actions.iter().any(|a| a.is_highlight()));
        if highlighted || mentions_in_raw(event.raw(), me) {
            kind = UnreadKind::Mention;
        } else if kind == UnreadKind::None {
            kind = UnreadKind::Unread;
        }
    }
    kind
}

/// `m.mentions.user_ids` on an event's content.
fn mentions_in_raw(
    raw: &matrix_sdk::ruma::serde::Raw<matrix_sdk::ruma::events::AnySyncTimelineEvent>,
    me: &UserId,
) -> bool {
    #[derive(serde::Deserialize)]
    struct Mentions {
        #[serde(default)]
        user_ids: Vec<OwnedUserId>,
    }
    #[derive(serde::Deserialize)]
    struct Content {
        #[serde(rename = "m.mentions")]
        mentions: Option<Mentions>,
    }
    raw.get_field::<Content>("content")
        .ok()
        .flatten()
        .and_then(|c| c.mentions)
        .is_some_and(|m| m.user_ids.iter().any(|u| u == me))
}
