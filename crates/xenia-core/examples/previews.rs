#![recursion_limit = "256"]
//! Signs in to the local test server from a fresh data folder and prints the conversation list's
//! preview for every room, as a first launch would show it. Sends nothing.
//!
//!   cargo run -p xenia-core --example previews
//!
//! Uses a throwaway data folder and signs out at the end.

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};

use xenia_core::*;

#[derive(Default)]
struct Memory(Mutex<HashMap<String, String>>);

impl SecretStore for Memory {
    fn load(&self, key: String) -> Option<String> {
        self.0.lock().unwrap().get(&key).cloned()
    }
    fn save(&self, key: String, value: String) -> bool {
        self.0.lock().unwrap().insert(key, value);
        true
    }
    fn delete(&self, key: String) {
        self.0.lock().unwrap().remove(&key);
    }
}

#[derive(Default)]
struct Events {
    rooms: Mutex<Option<Vec<RoomSummary>>>,
}

impl ClientListener for Events {
    fn on_session_changed(&self, _: SessionState) {}
    fn on_account_changed(&self, _: Account) {}
    fn on_connection_changed(&self, _: ConnectionState) {}
    fn on_rooms_changed(&self, rooms: Vec<RoomSummary>, is_loaded: bool) {
        if is_loaded {
            *self.rooms.lock().unwrap() = Some(rooms);
        }
    }
    fn on_incoming_message(&self, _: IncomingMessage) {}
    fn on_encryption_changed(&self, _: EncryptionStatus) {}
    fn on_verification_request(&self, _: VerificationPeer) {}
}

fn describe(preview: &RoomPreview) -> String {
    match preview {
        RoomPreview::Invite { inviter } => format!("invite from {inviter:?}"),
        RoomPreview::Empty { .. } => "EMPTY (No messages yet)".into(),
        RoomPreview::Message { sender, body, .. } => {
            format!("message {sender:?}: {}", body.text().unwrap_or("(media)"))
        }
        RoomPreview::Note { note } => format!("note {note:?}"),
    }
}

#[tokio::main]
async fn main() {
    let dir = tempfile::tempdir().unwrap();
    let config = ClientConfig {
        data_dir: dir.path().join("data").to_string_lossy().into(),
        cache_dir: dir.path().join("cache").to_string_lossy().into(),
        device_name: "Xenia previews check".into(),
        user_agent: "Xenia/previews".into(),
        default_server: "localhost:8008".into(),
    };
    let events = Arc::new(Events::default());
    let client = XeniaClient::new(config, Arc::new(Memory::default()), events.clone());
    client.clone().sign_in("localhost:8008".into(), "luke".into(), "relay-dev-password".into()).await.unwrap();

    while events.rooms.lock().unwrap().is_none() {
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    // Give late previews (found by looking further back) a moment to arrive.
    tokio::time::sleep(Duration::from_secs(5)).await;

    let rooms = events.rooms.lock().unwrap().clone().unwrap_or_default();
    for room in &rooms {
        println!("{:<28} {}", room.name, describe(&room.preview));
    }
    let empty = rooms.iter().filter(|r| matches!(r.preview, RoomPreview::Empty { .. })).count();
    println!("{} rooms, {empty} without a preview", rooms.len());
    client.sign_out().await;
}
