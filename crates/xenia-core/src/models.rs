//! The records apps read. They're view-ready: an app draws them without asking the SDK anything.

use crate::content::{Body, Note};

/// The signed-in person.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record, serde::Serialize, serde::Deserialize)]
pub struct Account {
    pub user_id: String,
    pub display_name: Option<String>,
    /// An `mxc://` URL; load it with `XeniaClient::load_avatar`.
    pub avatar_url: Option<String>,
    pub device_id: String,
    /// The homeserver's address, like "https://matrix.example.org".
    pub homeserver: String,
}

impl Account {
    /// The display name, or the user ID when there isn't one.
    pub fn name(&self) -> String {
        self.display_name.clone().filter(|n| !n.trim().is_empty()).unwrap_or_else(|| self.user_id.clone())
    }
}

/// Where the session stands.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SessionState {
    /// Reading the saved session at launch.
    Restoring,
    /// No one is signed in. `reason` says why the last session ended, when it ended by itself.
    SignedOut {
        reason: Option<SignOutReason>,
    },
    SignedIn {
        account: Account,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SignOutReason {
    /// The server revoked the session: signed out from another device, or the password changed.
    SessionRevoked,
    /// The saved session couldn't be opened on this device just now. It's kept, and the next
    /// launch tries again; signing in replaces it.
    RestoreFailed,
}

/// The connection to the server, for the "Connecting…" and offline indicators.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ConnectionState {
    /// Starting up, or catching up after a pause.
    Connecting,
    Connected,
    /// No network: messages wait and send when the connection returns.
    Offline,
    /// The server is reachable but sync keeps failing.
    Error,
}

/// Which list a conversation lives in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum, serde::Serialize, serde::Deserialize)]
pub enum Scope {
    /// Direct chats: one to one, or a small personal group marked direct.
    Chats,
    /// Groups and public rooms.
    Rooms,
}

/// A list's filter.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ListFilter {
    All,
    Unread,
    Favourites,
}

/// What a conversation row's leading dot says.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum, serde::Serialize, serde::Deserialize)]
pub enum UnreadKind {
    None,
    Unread,
    /// Someone mentioned you: shown even when the conversation is muted.
    Mention,
}

/// How a room notifies this device.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum, serde::Serialize, serde::Deserialize)]
pub enum NotificationMode {
    AllMessages,
    MentionsOnly,
    Mute,
}

/// A conversation, as the lists show it.
#[derive(Debug, Clone, PartialEq, uniffi::Record, serde::Serialize, serde::Deserialize)]
pub struct RoomSummary {
    pub id: String,
    pub name: String,
    /// An `mxc://` URL: the room's photo, or for a DM the other person's.
    pub avatar_url: Option<String>,
    /// Picks the avatar's color and initials when there's no photo: the other person's ID for a
    /// DM, the room's ID otherwise.
    pub avatar_seed: String,
    /// For a DM, the other person's user ID.
    pub dm_user_id: Option<String>,
    pub scope: Scope,
    pub is_direct: bool,
    /// A direct chat with exactly one other person.
    pub is_dm: bool,
    pub is_encrypted: bool,
    pub is_favourite: bool,
    /// Where the person put this pin among the others: the favourite tag's `order`, from 0 to 1.
    pub favourite_order: Option<f64>,
    pub is_low_priority: bool,
    pub is_invite: bool,
    pub is_public: bool,
    /// For invitations: who invited me.
    pub inviter_name: Option<String>,
    pub topic: Option<String>,
    /// The room's address, like "#design:example.org".
    pub alias: Option<String>,
    pub member_count: u64,
    pub unread_count: u64,
    pub mention_count: u64,
    pub is_marked_unread: bool,
    pub is_muted: bool,
    /// The room's own setting, or `AllMessages` when it has none (see `has_own_notification_mode`).
    pub notification_mode: NotificationMode,
    /// The person chose a mode for this room. Without one, `effective_notification_mode` applies
    /// the app's defaults.
    pub has_own_notification_mode: bool,
    /// Wants attention (counts toward the tab badge and the Unread filter).
    pub is_unread: bool,
    pub unread_kind: UnreadKind,
    pub pinned_event_ids: Vec<String>,
    pub preview: RoomPreview,
    /// When the latest activity happened, for sorting and the row's time. Zero when unknown.
    pub timestamp_ms: i64,
    /// Unsent text in the composer, shown as "Draft" in the list.
    pub draft: Option<String>,
    /// The latest message I sent is still sending, or failed.
    pub last_send_state: Option<SendState>,
}

/// The second line of a conversation row.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum, serde::Serialize, serde::Deserialize)]
pub enum RoomPreview {
    /// An invitation; `inviter` is the inviter's name if known.
    Invite { inviter: Option<String> },
    /// Nothing to show yet. `is_encrypted` lets the app say so.
    Empty { is_encrypted: bool },
    /// A message. `sender` is set when the app should prefix it ("Maya: ", "You: "): in groups,
    /// and for my own messages outside one-to-one chats.
    Message { sender: Option<PreviewSender>, body: Body, mentions_me: bool, is_own: bool },
    /// A change to the conversation ("Maya joined"), which reads without a sender.
    Note { note: Note },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum, serde::Serialize, serde::Deserialize)]
pub enum PreviewSender {
    You,
    /// Someone else, by first name.
    Other {
        first_name: String,
    },
}

/// Where a message I sent stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum, serde::Serialize, serde::Deserialize)]
pub enum SendState {
    Sending,
    Sent,
    Failed,
}

/// Someone in a conversation or the server's directory.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Person {
    pub user_id: String,
    pub display_name: Option<String>,
    pub avatar_url: Option<String>,
}

impl Person {
    pub fn name(&self) -> String {
        self.display_name.clone().filter(|n| !n.trim().is_empty()).unwrap_or_else(|| self.user_id.clone())
    }
}

/// A member of a room.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Member {
    pub user_id: String,
    pub name: String,
    pub avatar_url: Option<String>,
    /// Invited but hasn't joined yet.
    pub is_invited: bool,
    /// Can moderate: remove people, change settings.
    pub is_admin: bool,
    pub is_you: bool,
}
