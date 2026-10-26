//! Opens a conversation as someone who joined after it started, in a room that shows its history
//! only to members, and asks for older messages the way scrolling to the top does. Prints how
//! many requests it took for the timeline to say there's nothing more to load.
//!
//!   cargo run -p xenia-core --example history_start -- <user> <password> <room id>
//!
//! Uses a throwaway data folder and signs out at the end.

#![recursion_limit = "256"]

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

#[derive(Default)]
struct Rows(Mutex<Option<TimelineUpdate>>);

impl TimelineListener for Rows {
    fn on_update(&self, update: TimelineUpdate) {
        *self.0.lock().unwrap() = Some(update);
    }
    fn on_typing(&self, _: Vec<Reader>) {}
}

#[tokio::main]
async fn main() {
    let mut args = std::env::args().skip(1);
    let (user, password, room_id) = (args.next().unwrap(), args.next().unwrap(), args.next().unwrap());
    let dir = tempfile::tempdir().unwrap();
    let config = ClientConfig {
        data_dir: dir.path().join("data").to_string_lossy().into(),
        cache_dir: dir.path().join("cache").to_string_lossy().into(),
        device_name: "Xenia history check".into(),
        user_agent: "Xenia/history".into(),
        default_server: "localhost:8008".into(),
    };
    let events = Arc::new(Events::default());
    let client = XeniaClient::new(config, Arc::new(Memory::default()), events.clone());
    client.clone().sign_in("localhost:8008".into(), user, password).await.unwrap();
    while !events.rooms.lock().unwrap().iter().any(|r| r.id == room_id) {
        tokio::time::sleep(Duration::from_millis(200)).await;
    }

    let rows = Arc::new(Rows::default());
    let timeline = client.timeline(room_id, TimelineFocus::Live, rows.clone()).await.unwrap();
    let mut requests = 0;
    let started = std::time::Instant::now();
    loop {
        tokio::time::sleep(Duration::from_millis(300)).await;
        let Some(update) = rows.0.lock().unwrap().clone() else { continue };
        if update.is_at_start || requests >= 60 {
            let messages = update.rows.iter().filter(|r| matches!(r, TimelineRow::Message { .. })).count();
            println!(
                "requests {requests}, at start {}, starts at join {}, {messages} messages shown, {:.1}s",
                update.is_at_start,
                update.history_starts_at_join,
                started.elapsed().as_secs_f32()
            );
            break;
        }
        if update.is_ready && !update.is_loading_older {
            requests += 1;
            timeline.load_older().await;
        }
    }
    client.sign_out().await;
}
