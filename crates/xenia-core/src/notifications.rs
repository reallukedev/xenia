//! When a change to a conversation deserves a notification on this device.
//!
//! While Xenia runs, the room list sees each new message. While it's suspended or closed, the
//! homeserver pushes and the iPhone's notification extension decides (see `push.rs`). Both follow
//! `effective_mode`, which matches what the homeserver's push rules do with each mode.

use matrix_sdk::notification_settings::RoomNotificationMode;

use crate::{
    content::Body,
    models::{NotificationMode, RoomPreview, RoomSummary},
};

impl From<RoomNotificationMode> for NotificationMode {
    fn from(mode: RoomNotificationMode) -> Self {
        match mode {
            RoomNotificationMode::AllMessages => NotificationMode::AllMessages,
            RoomNotificationMode::MentionsAndKeywordsOnly => NotificationMode::MentionsOnly,
            RoomNotificationMode::Mute => NotificationMode::Mute,
        }
    }
}

/// How a room notifies this device: the mode the person chose for it, or without one, the app's
/// defaults. Direct chats notify for everything; groups follow the Rooms setting, and public rooms
/// (often big and busy) notify only for mentions.
pub(crate) fn effective_mode(
    own: Option<NotificationMode>,
    is_direct: bool,
    is_public: bool,
    rooms_notify_for_all: bool,
) -> NotificationMode {
    match own {
        Some(mode) => mode,
        None if is_direct => NotificationMode::AllMessages,
        None if is_public || !rooms_notify_for_all => NotificationMode::MentionsOnly,
        None => NotificationMode::AllMessages,
    }
}

/// How `room` notifies this device, for showing in its settings.
#[uniffi::export]
pub fn effective_notification_mode(room: RoomSummary, rooms_notify_for_all: bool) -> NotificationMode {
    effective_mode(
        room.has_own_notification_mode.then_some(room.notification_mode),
        room.is_direct,
        room.is_public,
        rooms_notify_for_all,
    )
}

/// Whether a message in a room with `mode` notifies. Mute means nothing, mentions included, as
/// the homeserver's push rules have it (a muted room's rule outranks the mention rules).
pub(crate) fn mode_notifies(mode: NotificationMode, is_ping: bool) -> bool {
    match mode {
        NotificationMode::AllMessages => true,
        NotificationMode::MentionsOnly => is_ping,
        NotificationMode::Mute => false,
    }
}

/// This device's notification settings and what's on screen, set by the app.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct NotificationContext {
    /// The app is in front.
    pub is_active: bool,
    /// The conversation on screen, if any.
    pub open_room_id: Option<String>,
    /// Groups notify for everything, or only mentions (direct chats always notify).
    pub rooms_notify_for_all: bool,
}

impl Default for NotificationContext {
    fn default() -> Self {
        Self { is_active: true, open_room_id: None, rooms_notify_for_all: true }
    }
}

/// A message the app should announce.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct IncomingMessage {
    pub room_id: String,
    pub room_name: String,
    pub is_direct: bool,
    /// The sender's first name in groups; `None` in one-to-one chats, where the room's name is
    /// the person.
    pub sender_name: Option<String>,
    pub body: Body,
    /// It mentions me: a ping, sent Time Sensitive where the platform has that.
    pub is_ping: bool,
    pub timestamp_ms: i64,
    /// The room's avatar, for notifications that show one.
    pub avatar_url: Option<String>,
    pub avatar_seed: String,
    /// Who wrote it, for the notification's person: their ID, full name and photo.
    pub sender_id: Option<String>,
    pub sender_full_name: Option<String>,
    pub sender_avatar_url: Option<String>,
    /// A photo (or a video's still) to show with it, as a handle for `load_thumbnail`.
    pub picture: Option<String>,
    /// The message, when known.
    pub event_id: Option<String>,
}

/// Keywords notify like mentions. The server's keyword rules notify without highlighting, so a
/// match is checked here, or mentions-only conversations would stay quiet.
pub(crate) fn mentions_keyword(text: Option<&str>, keywords: &[String]) -> bool {
    text.is_some_and(|text| keywords.iter().any(|word| crate::content::mentions_word(text, word)))
}

/// Whether `room`'s latest change deserves a notification, given what was known before.
pub(crate) fn incoming_message(
    room: &RoomSummary,
    previous: Option<&RoomSummary>,
    cx: &NotificationContext,
    keywords: &[String],
) -> Option<IncomingMessage> {
    let previous = previous?;
    if room.is_invite {
        return None;
    }
    let RoomPreview::Message { sender, body, mentions_me, is_own } = &room.preview else {
        return None;
    };
    // My own messages, from this device or another.
    if *is_own {
        return None;
    }
    // Only a message newer than the one we last saw. (Unread counts settle a moment later, so
    // they can't be the trigger.)
    if room.timestamp_ms <= previous.timestamp_ms {
        return None;
    }
    let is_ping =
        *mentions_me || room.mention_count > previous.mention_count || mentions_keyword(body.text(), keywords);
    let own_mode = room.has_own_notification_mode.then_some(room.notification_mode);
    let mode = effective_mode(own_mode, room.is_direct, room.is_public, cx.rooms_notify_for_all);
    if !mode_notifies(mode, is_ping) {
        return None;
    }
    // In the foreground, banner only from inside a different conversation, as Messages does: the
    // list already shows what's new.
    if cx.is_active && (cx.open_room_id.is_none() || cx.open_room_id.as_deref() == Some(room.id.as_str())) {
        return None;
    }
    let sender_name = match sender {
        Some(crate::models::PreviewSender::Other { first_name }) => Some(first_name.clone()),
        _ => None,
    };
    Some(IncomingMessage {
        room_id: room.id.clone(),
        room_name: room.name.clone(),
        is_direct: room.is_direct,
        sender_name,
        body: body.clone(),
        is_ping,
        timestamp_ms: room.timestamp_ms,
        avatar_url: room.avatar_url.clone(),
        avatar_seed: room.avatar_seed.clone(),
        // Filled in from the room's latest event by the caller (see `rooms::with_details`).
        sender_id: None,
        sender_full_name: None,
        sender_avatar_url: None,
        picture: None,
        event_id: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{models::PreviewSender, rooms::rules::tests::room};

    fn message(r: &mut RoomSummary, at: i64, from: &str, mentions_me: bool) {
        r.timestamp_ms = at;
        r.preview = RoomPreview::Message {
            sender: Some(PreviewSender::Other { first_name: from.into() }),
            body: Body::Text { text: "hi".into() },
            mentions_me,
            is_own: false,
        };
    }

    fn background() -> NotificationContext {
        NotificationContext { is_active: false, open_room_id: None, rooms_notify_for_all: true }
    }

    #[test]
    fn rooms_without_their_own_mode_follow_the_defaults() {
        use NotificationMode::*;
        assert_eq!(effective_mode(None, true, false, false), AllMessages, "direct chats always notify");
        assert_eq!(effective_mode(None, false, false, true), AllMessages, "groups follow the Rooms setting");
        assert_eq!(effective_mode(None, false, false, false), MentionsOnly);
        assert_eq!(effective_mode(None, false, true, true), MentionsOnly, "public rooms only for mentions");
        assert_eq!(effective_mode(Some(AllMessages), false, true, false), AllMessages, "a choice wins");
        assert_eq!(effective_mode(Some(Mute), true, false, true), Mute);
    }

    #[test]
    fn new_group_message_notifies_in_background() {
        let before = room("!a", "Design", false);
        let mut after = before.clone();
        message(&mut after, 10, "Maya", false);
        after.unread_count = 1;
        let n = incoming_message(&after, Some(&before), &background(), &[]).unwrap();
        assert_eq!(n.sender_name.as_deref(), Some("Maya"));
        assert!(!n.is_ping);
    }

    #[test]
    fn nothing_on_first_sight_or_old_messages() {
        let mut r = room("!a", "Design", false);
        message(&mut r, 10, "Maya", false);
        assert!(incoming_message(&r, None, &background(), &[]).is_none());
        assert!(incoming_message(&r, Some(&r.clone()), &background(), &[]).is_none());
    }

    #[test]
    fn muted_rooms_stay_silent_even_for_mentions_as_pushes_do() {
        let mut before = room("!a", "Design", false);
        before.notification_mode = NotificationMode::Mute;
        before.has_own_notification_mode = true;
        let mut after = before.clone();
        message(&mut after, 10, "Maya", false);
        assert!(incoming_message(&after, Some(&before), &background(), &[]).is_none());
        message(&mut after, 11, "Maya", true);
        assert!(incoming_message(&after, Some(&before), &background(), &[]).is_none());
    }

    #[test]
    fn public_rooms_notify_for_mentions_unless_set_to_all_messages() {
        let mut before = room("!a", "Announcements", false);
        before.is_public = true;
        let mut after = before.clone();
        message(&mut after, 10, "Maya", false);
        assert!(incoming_message(&after, Some(&before), &background(), &[]).is_none());
        message(&mut after, 11, "Maya", true);
        assert!(incoming_message(&after, Some(&before), &background(), &[]).is_some());

        // Choosing All Messages for it is a choice the defaults must not override.
        before.has_own_notification_mode = true;
        after.has_own_notification_mode = true;
        message(&mut after, 12, "Maya", false);
        assert!(incoming_message(&after, Some(&before), &background(), &[]).is_some());
        let cx = NotificationContext { rooms_notify_for_all: false, ..background() };
        assert!(incoming_message(&after, Some(&before), &cx, &[]).is_some());
    }

    #[test]
    fn keywords_ping_even_where_only_mentions_notify() {
        let cx = NotificationContext { rooms_notify_for_all: false, ..background() };
        let before = room("!a", "Ops", false);
        let mut after = before.clone();
        message(&mut after, 10, "Maya", false);
        assert!(incoming_message(&after, Some(&before), &cx, &["deploy".into()]).is_none());
        if let RoomPreview::Message { body, .. } = &mut after.preview {
            *body = Body::Text { text: "The Deploy failed".into() };
        }
        let n = incoming_message(&after, Some(&before), &cx, &["deploy".into()]).unwrap();
        assert!(n.is_ping);
        assert!(incoming_message(&after, Some(&before), &cx, &["deployment".into()]).is_none());
    }

    #[test]
    fn mentions_only_setting_quiets_groups_not_chats() {
        let cx = NotificationContext { rooms_notify_for_all: false, ..background() };
        let before = room("!a", "Design", false);
        let mut after = before.clone();
        message(&mut after, 10, "Maya", false);
        assert!(incoming_message(&after, Some(&before), &cx, &[]).is_none());

        let before = room("!b", "Maya", true);
        let mut after = before.clone();
        message(&mut after, 10, "Maya", false);
        after.unread_count = 1;
        assert!(incoming_message(&after, Some(&before), &cx, &[]).is_some());
    }

    #[test]
    fn foreground_only_from_another_conversation() {
        let before = room("!a", "Design", false);
        let mut after = before.clone();
        message(&mut after, 10, "Maya", false);
        let list = NotificationContext { is_active: true, open_room_id: None, rooms_notify_for_all: true };
        assert!(incoming_message(&after, Some(&before), &list, &[]).is_none());
        let same = NotificationContext { open_room_id: Some("!a".into()), ..list.clone() };
        assert!(incoming_message(&after, Some(&before), &same, &[]).is_none());
        let other = NotificationContext { open_room_id: Some("!z".into()), ..list };
        assert!(incoming_message(&after, Some(&before), &other, &[]).is_some());
    }
}
