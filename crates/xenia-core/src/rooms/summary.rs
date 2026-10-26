//! One conversation's summary, read from the SDK.

use std::{
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};

use eyeball::{AsyncLock, Subscriber};
use matrix_sdk::{
    Room, RoomDisplayName, RoomState, latest_events::LatestEventValue as SdkLatestEventValue,
    ruma::events::tag::TagName,
};
use matrix_sdk_ui::timeline::{LatestEventValue, LatestEventValueLocalState, RoomExt, TimelineDetails};
use tracing::warn;

use super::rules::{UnreadFacts, is_unread, scope_of, unread_kind};
use crate::{
    content::{Actor, Summary, mentions_me, picture_of, summarize},
    models::{NotificationMode, PreviewSender, RoomPreview, RoomSummary, SendState},
    notifications::IncomingMessage,
    text::first_name,
};

/// What the summary needs from outside the room itself.
pub(crate) struct SummaryContext<'a> {
    pub me: &'a str,
    pub my_name: &'a str,
    /// The user-defined mode from the push rules, if any (the room's cached one lags behind).
    pub mode: Option<matrix_sdk::notification_settings::RoomNotificationMode>,
    pub draft: Option<String>,
}

pub(crate) async fn build_summary(room: &Room, cx: SummaryContext<'_>) -> RoomSummary {
    let id = room.room_id().to_string();
    let is_invite = room.state() == RoomState::Invited;
    let is_direct = room.is_direct().await.unwrap_or(false);
    let is_dm = room.compute_is_dm().await.unwrap_or(false);
    let heroes = room.heroes().await;
    let hero = if is_direct { heroes.first() } else { None };

    // The SDK words two names itself, in English: a chat everyone else left ("Empty Room (was
    // Maya)") keeps the name it had, and one with no name at all falls through to what's left.
    let name = room
        .cached_display_name()
        .and_then(|n| match n {
            RoomDisplayName::Named(n) | RoomDisplayName::Aliased(n) | RoomDisplayName::Calculated(n) => Some(n),
            RoomDisplayName::EmptyWas(n) => Some(n),
            RoomDisplayName::Empty => None,
        })
        .filter(|n| !n.trim().is_empty())
        .or_else(|| room.name())
        .or_else(|| hero.and_then(|h| h.display_name.clone()))
        .unwrap_or_else(|| id.clone());

    let inviter_name = if is_invite {
        room.invite_details()
            .await
            .ok()
            .and_then(|d| d.inviter)
            .map(|m| m.display_name().map(str::to_owned).unwrap_or_else(|| m.user_id().to_string()))
    } else {
        None
    };

    let has_own_notification_mode = cx.mode.is_some();
    // No rule of its own: the defaults in `effective_notification_mode` apply.
    let mode = cx.mode.map(NotificationMode::from).unwrap_or(NotificationMode::AllMessages);
    let is_muted = mode == NotificationMode::Mute;

    let facts = UnreadFacts {
        is_invite,
        is_marked_unread: room.is_marked_unread(),
        mention_count: room.num_unread_mentions(),
        unread_count: room.num_unread_messages(),
        is_muted,
    };

    let favourite_order = if room.is_favourite() { favourite_order(room).await } else { None };

    let latest = room.latest_event().await;
    let (preview, timestamp_ms, last_send_state) = preview_of(latest, is_invite, is_dm, &cx);
    let preview = match preview {
        Some(p) => p,
        None if is_invite => RoomPreview::Invite { inviter: inviter_name.clone() },
        None => RoomPreview::Empty { is_encrypted: room.encryption_state().is_encrypted() },
    };
    let timestamp_ms = timestamp_ms.unwrap_or(0);

    RoomSummary {
        avatar_url: room.avatar_url().or_else(|| hero.and_then(|h| h.avatar_url.clone())).map(|u| u.to_string()),
        avatar_seed: hero.map(|h| h.user_id.to_string()).unwrap_or_else(|| id.clone()),
        dm_user_id: if is_dm { hero.map(|h| h.user_id.to_string()) } else { None },
        scope: scope_of(is_direct),
        is_direct,
        is_dm,
        is_encrypted: room.encryption_state().is_encrypted(),
        is_favourite: room.is_favourite(),
        favourite_order,
        is_low_priority: room.is_low_priority(),
        is_invite,
        is_public: room.is_public().unwrap_or(false),
        inviter_name,
        topic: room.topic().map(|t| t.trim().to_owned()).filter(|t| !t.is_empty()),
        alias: room.canonical_alias().map(|a| a.to_string()),
        member_count: room.joined_members_count(),
        unread_count: facts.unread_count,
        mention_count: facts.mention_count,
        is_marked_unread: facts.is_marked_unread,
        is_muted,
        notification_mode: mode,
        has_own_notification_mode,
        is_unread: is_unread(&facts),
        unread_kind: unread_kind(&facts),
        pinned_event_ids: room.pinned_event_ids().unwrap_or_default().iter().map(|e| e.to_string()).collect(),
        preview,
        timestamp_ms,
        draft: cx.draft.clone().filter(|d| !d.trim().is_empty()),
        last_send_state,
        id,
        name,
    }
}

async fn favourite_order(room: &Room) -> Option<f64> {
    let tags = room.tags().await.ok().flatten()?;
    tags.get(&TagName::Favorite)?.order
}

fn profile_name(profile: &TimelineDetails<matrix_sdk_ui::timeline::Profile>) -> Option<String> {
    match profile {
        TimelineDetails::Ready(p) => p.display_name.clone().filter(|n| !n.trim().is_empty()),
        _ => None,
    }
}

type Preview = (Option<RoomPreview>, Option<i64>, Option<SendState>);

fn preview_of(latest: LatestEventValue, is_invite: bool, is_dm: bool, cx: &SummaryContext<'_>) -> Preview {
    match latest {
        LatestEventValue::None => (None, None, None),
        LatestEventValue::RemoteInvite { timestamp, inviter_profile, inviter, .. } => {
            let inviter = profile_name(&inviter_profile).or_else(|| inviter.map(|i| i.to_string()));
            (Some(RoomPreview::Invite { inviter }), Some(timestamp.get().into()), None)
        }
        LatestEventValue::Remote { timestamp, sender, is_own, profile, content } => {
            if is_invite {
                return (None, Some(timestamp.get().into()), None);
            }
            let name = profile_name(&profile).unwrap_or_else(|| sender.to_string());
            let preview = message_preview(&content, &name, is_own, is_dm, cx);
            (preview, Some(timestamp.get().into()), None)
        }
        LatestEventValue::Local { timestamp, profile, content, state, sender } => {
            let name = profile_name(&profile).unwrap_or_else(|| sender.to_string());
            let preview = message_preview(&content, &name, true, is_dm, cx);
            let send = match state {
                LatestEventValueLocalState::IsSending => SendState::Sending,
                LatestEventValueLocalState::HasBeenSent => SendState::Sent,
                LatestEventValueLocalState::CannotBeSent => SendState::Failed,
            };
            (preview, Some(timestamp.get().into()), Some(send))
        }
    }
}

fn message_preview(
    content: &matrix_sdk_ui::timeline::TimelineItemContent,
    name: &str,
    is_own: bool,
    is_dm: bool,
    cx: &SummaryContext<'_>,
) -> Option<RoomPreview> {
    match summarize(content, Actor { name, is_you: is_own }, cx.me) {
        Summary::Message { body, .. } => {
            let sender = if is_own {
                (!is_dm).then_some(PreviewSender::You)
            } else {
                (!is_dm).then(|| PreviewSender::Other { first_name: first_name(name) })
            };
            let mentions_me = !is_own && mentions_me(content, cx.me, cx.my_name);
            Some(RoomPreview::Message { sender, body, mentions_me, is_own })
        }
        // "You joined" rather than "No messages yet": a room joined a moment ago usually has
        // history, it just hasn't been read here.
        Summary::Note(note) => Some(RoomPreview::Note { note }),
        Summary::Hidden => None,
    }
}

/// The room's latest event edits an earlier message. The SDK shows an edit as the latest message
/// (at the edit's time), so the list reads right, but it's not a new message to announce.
pub(crate) fn latest_is_edit(room: &Room) -> bool {
    let SdkLatestEventValue::Remote(event) = (**room).latest_event() else { return false };
    crate::push::is_edit(event.raw())
}

/// Who wrote a message about to be announced and any picture in it, from the room's latest event
/// (the summary keeps only what the list shows).
pub(crate) async fn with_details(room: &Room, mut message: IncomingMessage) -> IncomingMessage {
    // So the app's notification can stand in for the push's generic one for the same event.
    if let SdkLatestEventValue::Remote(event) = (**room).latest_event() {
        message.event_id = event.event_id().map(|id| id.to_string());
    }
    if let LatestEventValue::Remote { sender, profile, content, .. } = room.latest_event().await {
        message.sender_id = Some(sender.to_string());
        if let TimelineDetails::Ready(profile) = &profile {
            message.sender_full_name = profile.display_name.clone();
            message.sender_avatar_url = profile.avatar_url.as_ref().map(|u| u.to_string());
        }
        message.picture = picture_of(&content);
    }
    message
}

/// Events asked for per look back, and how many looks a room gets.
const LOOK_BACK_BATCH: u16 = 20;
const LOOK_BACK_PAGES: usize = 3;
/// How long the SDK gets to work out a latest event from what it just loaded.
const LOOK_BACK_SETTLE: Duration = Duration::from_secs(2);
/// Rooms up to this size fetch their member list to name an older preview's sender.
const MEMBERS_TO_FETCH: u64 = 100;

/// How looking further back for a preview went.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum LookBack {
    /// Found an event to preview, or the history has none: no need to look again. `refresh` when
    /// the summary should be read again (the sender's name was learned).
    Done { refresh: bool },
    /// Couldn't look now (offline, the cache unavailable): worth another try later.
    Failed,
    /// The list stopped (signed out) partway.
    Stopped,
}

/// Loads older history until the SDK finds an event worth previewing.
///
/// The SDK picks the latest event from what's in memory, and the room list only syncs a few events
/// per room. When those are all reactions, edits, state changes and the like, the room reads
/// "No messages yet" until it's opened. Paginating its event cache in the background (disk first,
/// then the server) gives the SDK more to choose from; its latest-events task picks up the result
/// and the room list announces the change. `stopped` is checked between pages.
pub(crate) async fn look_further_back(room: &Room, stopped: &AtomicBool) -> LookBack {
    let is_stopped = || stopped.load(Ordering::Relaxed);
    let client = room.client();
    let mut latest = match client.latest_events().await.listen_and_subscribe_to_room(room.room_id()).await {
        Ok(Some(latest)) => latest,
        // Not a room the SDK follows: nothing to look for.
        Ok(None) => return LookBack::Done { refresh: false },
        Err(error) => {
            warn!("Looking back for a preview failed: {error}");
            return LookBack::Failed;
        }
    };
    // The SDK may still be working out a value from what sync just delivered.
    if settled_value(&mut latest).await.is_some() {
        return LookBack::Done { refresh: false };
    }
    let Ok((cache, _handles)) = room.event_cache().await else { return LookBack::Failed };
    let pagination = cache.pagination();
    for _ in 0..LOOK_BACK_PAGES {
        if is_stopped() {
            return LookBack::Stopped;
        }
        let outcome = match pagination.run_backwards_once(LOOK_BACK_BATCH).await {
            Ok(outcome) => outcome,
            Err(error) => {
                warn!("Looking back for a preview failed: {error}");
                return LookBack::Failed;
            }
        };
        if let Some(value) = settled_value(&mut latest).await {
            if is_stopped() {
                return LookBack::Stopped;
            }
            return LookBack::Done { refresh: learn_sender(room, &value).await };
        }
        if outcome.reached_start {
            break;
        }
    }
    // Looked as far as it's worth: a room this quiet reads "No messages yet".
    LookBack::Done { refresh: false }
}

/// The room's latest event, now or once the SDK computes one within [`LOOK_BACK_SETTLE`].
async fn settled_value(latest: &mut Subscriber<SdkLatestEventValue, AsyncLock>) -> Option<SdkLatestEventValue> {
    let value = latest.get().await;
    if !value.is_none() {
        return Some(value);
    }
    tokio::time::timeout(LOOK_BACK_SETTLE, async {
        while let Some(value) = latest.next().await {
            if !value.is_none() {
                return Some(value);
            }
        }
        None
    })
    .await
    .ok()
    .flatten()
}

/// Sync only brings the members who sent the events it delivered, so an older event's sender may
/// be unknown and the preview would show their user ID. Small rooms fetch the member list (which
/// opening the room would do anyway); big ones wait until they're opened.
async fn learn_sender(room: &Room, value: &SdkLatestEventValue) -> bool {
    let SdkLatestEventValue::Remote(event) = value else { return false };
    let Some(sender) = event.sender() else { return false };
    if room.joined_members_count() > MEMBERS_TO_FETCH || matches!(room.get_member_no_sync(&sender).await, Ok(Some(_))) {
        return false;
    }
    room.sync_members().await.is_ok()
}
