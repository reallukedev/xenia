//! Push: telling the server where to send this device's pushes, and turning a push (a room and
//! an event, nothing more) into a notification inside the iOS Notification Service Extension,
//! which runs in its own process with the app's stores.
//!
//! Pushes carry only IDs (`event_id_only`), so neither the gateway nor Apple ever sees who wrote
//! what. The extension fetches and decrypts the event itself.

use std::sync::Arc;

use crate::{
    client::XeniaClient,
    content::{Actor, Summary, picture_of, summarize},
    error::{XeniaError, Result},
    models::NotificationMode,
    notifications::{IncomingMessage, effective_mode, mode_notifies},
    platform::{ClientConfig, SecretStore},
    runtime::run,
    session::{Process, SESSION_KEY, Server, StoredSession, build_client, lock_crypto_store},
    text::first_name,
};
use matrix_sdk::{
    Client,
    deserialized_responses::TimelineEvent,
    room::MessagesOptions,
    ruma::{
        EventId, MilliSecondsSinceUnixEpoch, OwnedUserId, RoomId, UInt,
        api::client::push::{Pusher, PusherIds, PusherInit, PusherKind},
        events::room::message::RoomMessageEventContent,
        push::{HttpPusherData, PushFormat},
    },
};
use matrix_sdk_ui::{
    notification_client::{
        NotificationClient, NotificationEvent, NotificationProcessSetup, NotificationStatus, RawNotificationEvent,
    },
    timeline::TimelineItemContent,
};

/// Where this device's pushes go.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PushRegistration {
    /// The device's push token, as the gateway expects it (APNs: hex).
    pub push_key: String,
    /// Identifies the app to the gateway, like "dev.xenia.matrix.ios".
    pub app_id: String,
    /// The gateway's notify endpoint, like "https://push.example.org/_matrix/push/v1/notify".
    pub gateway_url: String,
    pub app_name: String,
    pub device_name: String,
    /// The language notifications are written in, like "en".
    pub lang: String,
}

/// What Apple is told to show if the extension can't run (it ran out of memory, say): the same
/// words as the extension's own fallback, and permission for the extension to rewrite them.
fn default_payload() -> serde_json::Value {
    serde_json::json!({
        "aps": {
            "mutable-content": 1,
            "alert": { "title": "Xenia", "loc-key": "New Message", "loc-args": [] },
            "sound": "default",
        }
    })
}

/// A pushed message, described for the notification extension.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PushedMessage {
    pub message: IncomingMessage,
    /// The room's mode says this one shouldn't alert (a group set to mentions only, say), though
    /// the homeserver pushed it: the device's own settings narrow what the server sends.
    pub is_quiet: bool,
}

#[uniffi::export]
impl XeniaClient {
    /// Registers (or refreshes) this device's pusher. Safe to call on every launch: the server
    /// replaces a pusher with the same key and app ID.
    pub async fn register_pusher(&self, registration: PushRegistration) -> Result<()> {
        let core = self.core().await?;
        run(async move {
            let mut data = HttpPusherData::new(registration.gateway_url.clone());
            data.format = Some(PushFormat::EventIdOnly);
            if let serde_json::Value::Object(payload) = serde_json::json!({ "default_payload": default_payload() }) {
                data.data = payload.into_iter().collect();
            }
            let pusher: Pusher = PusherInit {
                ids: PusherIds::new(registration.push_key, registration.app_id),
                kind: PusherKind::Http(data),
                app_display_name: registration.app_name,
                device_display_name: registration.device_name,
                profile_tag: None,
                lang: registration.lang,
            }
            .into();
            core.client.pusher().set(pusher, false).await?;
            Ok(())
        })
        .await
    }

    /// Stops pushes to this device (notifications turned off, or signing out).
    pub async fn unregister_pusher(&self, push_key: String, app_id: String) -> Result<()> {
        let core = self.core().await?;
        run(async move {
            core.client.pusher().delete(PusherIds::new(push_key, app_id)).await?;
            Ok(())
        })
        .await
    }
}

/// Opens the signed-in session in the notification extension, without syncing, and describes
/// pushed events. One per extension process; reuse it across pushes.
#[derive(uniffi::Object)]
pub struct PushDecoder {
    client: Client,
    /// Taken on drop, to be released on the runtime (see `Drop`).
    notifications: Option<NotificationClient>,
    me: String,
}

impl Drop for PushDecoder {
    fn drop(&mut self) {
        // The SDK's stores must be closed on the Tokio runtime, but the app releases this object
        // on its own thread: hand the last references to the runtime to drop there.
        let client = self.client.clone();
        let notifications = self.notifications.take();
        crate::runtime::spawn(async move {
            drop(notifications);
            drop(client);
        });
    }
}

/// Which notification extension is opening the session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum NotificationExtension {
    /// Turns pushes into notifications.
    Service,
    /// Shows a notification's conversation and sends replies.
    Content,
}

/// Opens the signed-in session for a notification extension, or `None` when no one is signed in
/// (a push that arrived after signing out).
#[uniffi::export]
pub async fn open_push_decoder(
    config: ClientConfig,
    secrets: Arc<dyn SecretStore>,
    extension: NotificationExtension,
) -> Result<Option<Arc<PushDecoder>>> {
    crate::client::init_tracing();
    let process = match extension {
        NotificationExtension::Service => Process::NotificationExtension,
        NotificationExtension::Content => Process::NotificationContent,
    };
    run(async move {
        let Some(raw) = secrets.load(SESSION_KEY.to_owned()) else { return Ok(None) };
        let stored: StoredSession = serde_json::from_str(&raw).map_err(XeniaError::generic)?;
        let client =
            build_client(&config, Server::Url(&stored.homeserver_url), &stored.folder, &stored.passphrase, process)
                .await?;
        client.restore_session(stored.session).await?;
        lock_crypto_store(&client, process).await?;
        let me = client.user_id().ok_or(XeniaError::NotSignedIn)?.to_string();
        let notifications = match extension {
            NotificationExtension::Service => Some(
                NotificationClient::new(client.clone(), NotificationProcessSetup::MultipleProcesses)
                    .await
                    .map_err(XeniaError::generic)?,
            ),
            NotificationExtension::Content => None,
        };
        Ok(Some(Arc::new(PushDecoder { client, notifications, me })))
    })
    .await
}

/// A message in a notification's conversation, for the expanded notification.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct NotificationLine {
    pub event_id: String,
    pub sender_id: String,
    pub sender_name: String,
    pub is_you: bool,
    pub body: crate::content::Body,
    pub timestamp_ms: i64,
    /// A photo or a video's still, as a handle for `load_thumbnail`.
    pub picture: Option<String>,
}

#[uniffi::export]
impl PushDecoder {
    /// The notification for a pushed event, decrypted, or `None` when there's nothing to show (my
    /// own message, a blocked sender, a deleted message, one the push rules filter out, or a
    /// reaction or edit). A message the room's mode keeps quiet comes back marked `is_quiet`.
    pub async fn describe(
        self: Arc<Self>,
        room_id: String,
        event_id: String,
        rooms_notify_for_all: bool,
    ) -> Result<Option<PushedMessage>> {
        let this = Arc::clone(&self);
        run(async move {
            let room_id = RoomId::parse(&room_id)?;
            let event_id = EventId::parse(&event_id)?;
            let notifications = this.notifications.as_ref().ok_or(XeniaError::NotSignedIn)?;
            let status = notifications.get_notification(&room_id, &event_id).await.map_err(XeniaError::generic)?;
            let item = match status {
                NotificationStatus::Event(item) => item,
                NotificationStatus::EventNotFound => return Err(XeniaError::NotFound),
                NotificationStatus::EventFilteredOut | NotificationStatus::EventRedacted => return Ok(None),
            };
            let sender = match &item.event {
                NotificationEvent::Timeline(event) => event.sender().to_owned(),
                NotificationEvent::Invite(event) => event.sender.clone(),
            };
            if sender.as_str() == this.me {
                return Ok(None);
            }
            let sender_name = item.sender_display_name.clone().unwrap_or_else(|| sender.to_string());
            let is_direct = item.is_direct_message_room;
            let mut is_ping = item.has_mention.unwrap_or(false);
            let is_public =
                matches!(item.room_join_rule, Some(matrix_sdk::ruma::events::room::join_rules::JoinRule::Public));
            let own_mode = this
                .client
                .notification_settings()
                .await
                .get_user_defined_room_notification_mode(&room_id)
                .await
                .map(NotificationMode::from);
            let room_name = item.room_computed_display_name.clone();
            let (body, picture) = match &item.raw_event {
                // An edit replaces a message already announced.
                RawNotificationEvent::Timeline(raw) if is_edit(raw) => return Ok(None),
                RawNotificationEvent::Timeline(raw) => {
                    let room = notifications.get_room(&room_id).or_else(|| this.client.get_room(&room_id));
                    let content = match room {
                        Some(room) => {
                            TimelineItemContent::from_event(&room, TimelineEvent::from_plaintext(raw.clone())).await
                        }
                        None => None,
                    };
                    let picture = content.as_ref().and_then(picture_of);
                    match content.map(|c| summarize(&c, Actor { name: &sender_name, is_you: false }, &this.me)) {
                        Some(Summary::Message { body, .. }) => (body, picture),
                        // Reactions, edits and state changes don't notify.
                        Some(_) => return Ok(None),
                        None => (crate::content::Body::Encrypted, None),
                    }
                }
                RawNotificationEvent::Invite(_) => (crate::content::Body::Invite, None),
            };
            if !is_ping {
                let keywords: Vec<String> =
                    this.client.notification_settings().await.enabled_keywords().await.into_iter().collect();
                is_ping = crate::notifications::mentions_keyword(body.text(), &keywords);
            }
            let is_quiet =
                !mode_notifies(effective_mode(own_mode, is_direct, is_public, rooms_notify_for_all), is_ping);
            let timestamp_ms = match &item.event {
                NotificationEvent::Timeline(event) => i64::from(event.origin_server_ts().get()),
                NotificationEvent::Invite(_) => chrono::Utc::now().timestamp_millis(),
            };
            let message = IncomingMessage {
                room_id: room_id.to_string(),
                room_name,
                is_direct,
                sender_name: if is_direct { None } else { Some(first_name(&sender_name)) },
                body,
                is_ping,
                timestamp_ms,
                avatar_url: item.room_avatar_url.clone(),
                avatar_seed: if is_direct { sender.to_string() } else { room_id.to_string() },
                sender_id: Some(sender.to_string()),
                sender_full_name: item.sender_display_name.clone(),
                sender_avatar_url: item.sender_avatar_url.clone(),
                picture,
                event_id: Some(event_id.to_string()),
            };
            Ok(Some(PushedMessage { message, is_quiet }))
        })
        .await
    }

    /// Conversations flagged unread by hand, other than `except_room_id`, that have no unread
    /// notifications. The server's badge counts only conversations with unread notifications,
    /// so these are what the app's own badge has and a push's doesn't.
    pub fn flagged_unread_rooms(&self, except_room_id: String) -> u32 {
        let flagged = self.client.joined_rooms().into_iter().filter(|room| {
            room.room_id().as_str() != except_room_id
                && room.is_marked_unread()
                && room.unread_notification_counts().notification_count == 0
        });
        u32::try_from(flagged.count()).unwrap_or(u32::MAX)
    }

    /// A square avatar, `size_px` on a side.
    pub async fn load_avatar(self: Arc<Self>, mxc_url: String, size_px: u32) -> Result<Vec<u8>> {
        let client = self.client.clone();
        run(async move { crate::media::avatar_bytes(&client, mxc_url, size_px).await }).await
    }

    /// A photo scaled to fit (encrypted ones come whole).
    pub async fn load_thumbnail(self: Arc<Self>, source: String, width_px: u32, height_px: u32) -> Result<Vec<u8>> {
        let client = self.client.clone();
        run(async move { crate::media::thumbnail_bytes(&client, source, width_px, height_px).await }).await
    }

    /// The conversation's latest messages, oldest first, for the expanded notification. Asks the
    /// server, since the extension doesn't sync.
    pub async fn recent_messages(self: Arc<Self>, room_id: String, limit: u32) -> Result<Vec<NotificationLine>> {
        let this = Arc::clone(&self);
        run(async move {
            if limit == 0 {
                return Ok(Vec::new());
            }
            let room_id = RoomId::parse(&room_id)?;
            let room = this.client.get_room(&room_id).ok_or(XeniaError::NotFound)?;
            let mut options = MessagesOptions::backward();
            // Room changes and reactions come in between messages: look further back than shown.
            options.limit = UInt::from(limit.saturating_mul(3).clamp(10, 60));
            let page = room.messages(options).await?;
            let mut lines = Vec::new();
            let mut names: std::collections::HashMap<OwnedUserId, String> = std::collections::HashMap::new();
            for event in page.chunk {
                let Some(event_id) = event.event_id().map(ToOwned::to_owned) else { continue };
                let raw = event.raw();
                let Ok(Some(sender)) = raw.get_field::<OwnedUserId>("sender") else { continue };
                let timestamp_ms = raw
                    .get_field::<MilliSecondsSinceUnixEpoch>("origin_server_ts")
                    .ok()
                    .flatten()
                    .map(|t| i64::from(t.get()))
                    .unwrap_or_default();
                let Some(content) = TimelineItemContent::from_event(&room, event).await else { continue };
                let is_you = sender.as_str() == this.me;
                let name = match names.get(&sender) {
                    Some(name) => name.clone(),
                    None => {
                        let name = room
                            .get_member_no_sync(&sender)
                            .await
                            .ok()
                            .flatten()
                            .and_then(|m| m.display_name().map(str::to_owned))
                            .unwrap_or_else(|| sender.localpart().to_owned());
                        names.insert(sender.clone(), name.clone());
                        name
                    }
                };
                let Summary::Message { body } = summarize(&content, Actor { name: &name, is_you }, &this.me) else {
                    continue;
                };
                lines.push(NotificationLine {
                    event_id: event_id.to_string(),
                    sender_id: sender.to_string(),
                    sender_name: name,
                    is_you,
                    body,
                    timestamp_ms,
                    picture: picture_of(&content),
                });
                if lines.len() >= limit as usize {
                    break;
                }
            }
            lines.reverse();
            Ok(lines)
        })
        .await
    }

    /// Sends a reply typed into a notification. Replying isn't reading: no receipt goes out, and
    /// the conversation stays unread (my own message would otherwise count as reading it).
    pub async fn send_reply(self: Arc<Self>, room_id: String, text: String) -> Result<()> {
        let this = Arc::clone(&self);
        run(async move {
            let room_id = RoomId::parse(&room_id)?;
            let room = this.client.get_room(&room_id).ok_or(XeniaError::NotFound)?;
            let message = crate::text::compose_message(text, Vec::new());
            room.send(RoomMessageEventContent::from(crate::timeline::message_content(&message))).await?;
            if let Err(error) = room.set_unread_flag(true).await {
                tracing::warn!("Couldn't keep a replied conversation unread: {error}");
            }
            Ok(())
        })
        .await
    }
}

/// A pushed event that edits an earlier message (the SDK turns those into plain messages).
pub(crate) fn is_edit(raw: &matrix_sdk::ruma::serde::Raw<matrix_sdk::ruma::events::AnySyncTimelineEvent>) -> bool {
    #[derive(serde::Deserialize)]
    struct Relation {
        rel_type: Option<String>,
    }
    #[derive(serde::Deserialize)]
    struct Content {
        #[serde(rename = "m.relates_to")]
        relates_to: Option<Relation>,
    }
    raw.get_field::<Content>("content")
        .ok()
        .flatten()
        .and_then(|c| c.relates_to)
        .and_then(|r| r.rel_type)
        .is_some_and(|t| t == "m.replace")
}
