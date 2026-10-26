#![recursion_limit = "256"]
//! A headless run of the core against the local test server: signs in, waits for the room list,
//! opens the first conversation and sends a file, printing what the app would be told.
//!
//!   cargo run -p xenia-core --example smoke -- <path to a file to send>
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
    rooms: Mutex<Vec<RoomSummary>>,
}

impl ClientListener for Events {
    fn on_session_changed(&self, state: SessionState) {
        println!("session: {state:?}");
    }
    fn on_account_changed(&self, _: Account) {}
    fn on_connection_changed(&self, state: ConnectionState) {
        println!("connection: {state:?}");
    }
    fn on_rooms_changed(&self, rooms: Vec<RoomSummary>, is_loaded: bool) {
        if is_loaded {
            *self.rooms.lock().unwrap() = rooms;
        }
    }
    fn on_incoming_message(&self, _: IncomingMessage) {}
    fn on_encryption_changed(&self, _: EncryptionStatus) {}
    fn on_verification_request(&self, peer: VerificationPeer) {
        println!("verification request from {}", peer.user_id);
    }
}

struct Rows;

impl TimelineListener for Rows {
    fn on_update(&self, update: TimelineUpdate) {
        if let Some(TimelineRow::Message { message }) =
            update.rows.iter().rev().find(|r| matches!(r, TimelineRow::Message { .. }))
        {
            println!("newest: {:?} {:?}", message.send_state, std::mem::discriminant(&message.content));
        }
    }
    fn on_typing(&self, _: Vec<Reader>) {}
}

#[tokio::main]
async fn main() {
    let file = std::env::args().nth(1).expect("a file to send");
    let dir = tempfile::tempdir().unwrap();
    let config = ClientConfig {
        data_dir: dir.path().join("data").to_string_lossy().into(),
        cache_dir: dir.path().join("cache").to_string_lossy().into(),
        device_name: "Xenia smoke test".into(),
        user_agent: "Xenia/smoke".into(),
        default_server: "localhost:8008".into(),
    };
    let events = Arc::new(Events::default());
    let client = XeniaClient::new(config, Arc::new(Memory::default()), events.clone());
    client.clone().sign_in("localhost:8008".into(), "luke".into(), "relay-dev-password".into()).await.unwrap();

    let room = loop {
        if let Some(room) = events.rooms.lock().unwrap().iter().find(|r| r.is_dm).cloned() {
            break room;
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    };
    println!("sending to {}", room.name);
    let timeline = client.timeline(room.id.clone(), TimelineFocus::Live, Arc::new(Rows)).await.unwrap();
    let size = std::fs::metadata(&file).unwrap().len();
    let mime = if file.ends_with(".png") { "image/png" } else { "image/jpeg" };
    timeline
        .send_attachment(
            Attachment {
                path: file.clone(),
                filename: std::path::Path::new(&file).file_name().unwrap().to_string_lossy().into(),
                mimetype: mime.into(),
                size: Some(size),
                width: None,
                height: None,
                duration_ms: None,
                blurhash: None,
                caption: None,
                thumbnail_path: None,
            },
            None,
        )
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_secs(6)).await;
    client.sign_out().await;
}
