//! The conversation list as it last looked, saved by the app so the next launch can draw it on
//! the first frame, before the stores open. Apps store the bytes; the core only reads and writes
//! the format, so every platform shares it.

use crate::models::{Account, RoomSummary};

/// What the list showed: who was signed in and their conversations.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct ListSnapshot {
    pub account: Option<Account>,
    pub rooms: Vec<RoomSummary>,
    /// The list's "verify this device" card was showing, so it's drawn in place from the start.
    pub needs_verification: bool,
}

/// Bumped when the records change shape, so an old snapshot is ignored rather than misread.
const VERSION: u32 = 2;

#[derive(serde::Serialize, serde::Deserialize)]
struct Stored {
    version: u32,
    snapshot: ListSnapshot,
}

/// The snapshot as bytes to save.
#[uniffi::export]
pub fn encode_list_snapshot(snapshot: ListSnapshot) -> Vec<u8> {
    serde_json::to_vec(&Stored { version: VERSION, snapshot }).unwrap_or_default()
}

/// A saved snapshot, or nothing when it's missing, damaged or from another version.
#[uniffi::export]
pub fn decode_list_snapshot(bytes: Vec<u8>) -> Option<ListSnapshot> {
    let stored: Stored = serde_json::from_slice(&bytes).ok()?;
    (stored.version == VERSION).then_some(stored.snapshot)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::content::Body;
    use crate::models::{NotificationMode, PreviewSender, RoomPreview, Scope, UnreadKind};

    #[test]
    fn round_trips_and_rejects_junk() {
        let room = RoomSummary {
            id: "!a:x".into(),
            name: "Maya".into(),
            avatar_url: Some("mxc://x/a".into()),
            avatar_seed: "@maya:x".into(),
            dm_user_id: Some("@maya:x".into()),
            scope: Scope::Chats,
            is_direct: true,
            is_dm: true,
            is_encrypted: true,
            is_favourite: true,
            favourite_order: None,
            is_low_priority: false,
            is_invite: false,
            is_public: false,
            inviter_name: None,
            topic: None,
            alias: None,
            member_count: 2,
            unread_count: 1,
            mention_count: 0,
            is_marked_unread: false,
            is_muted: false,
            notification_mode: NotificationMode::AllMessages,
            has_own_notification_mode: false,
            is_unread: true,
            unread_kind: UnreadKind::Unread,
            pinned_event_ids: vec![],
            preview: RoomPreview::Message {
                sender: Some(PreviewSender::Other { first_name: "Maya".into() }),
                body: Body::Image { caption: Some("Sunset".into()) },
                mentions_me: false,
                is_own: false,
            },
            timestamp_ms: 1_700_000_000_000,
            draft: Some("See you".into()),
            last_send_state: None,
        };
        let snapshot = ListSnapshot { account: None, rooms: vec![room], needs_verification: true };
        assert_eq!(decode_list_snapshot(encode_list_snapshot(snapshot.clone())), Some(snapshot));
        assert_eq!(decode_list_snapshot(b"not json".to_vec()), None);
        assert_eq!(decode_list_snapshot(br#"{"version":0,"snapshot":{"account":null,"rooms":[]}}"#.to_vec()), None);
    }
}
