//! The Mac app's launch, headless, against the local test server: restore, then sign in when
//! nothing was saved, as `AppModel.start` does with `-XeniaDevSignIn`. The session secret lives in
//! a file in the data folder, so several runs at once share it the way copies of the app share the
//! Keychain.
//!
//!   cargo run -p xenia-core --example session_flow -- <data dir> <user> <password> <seconds> [sign-out]
//!
//! An empty password only restores.

use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};

use xenia_core::*;

/// Secrets in a JSON file, read and written on every call.
struct FileSecrets(PathBuf, Mutex<()>);

impl FileSecrets {
    fn read(&self) -> HashMap<String, String> {
        std::fs::read(&self.0).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }
    fn write(&self, map: &HashMap<String, String>) -> bool {
        std::fs::write(&self.0, serde_json::to_vec(map).unwrap_or_default()).is_ok()
    }
}

impl SecretStore for FileSecrets {
    fn load(&self, key: String) -> Option<String> {
        let _held = self.1.lock().unwrap();
        self.read().get(&key).cloned()
    }
    fn save(&self, key: String, value: String) -> bool {
        let _held = self.1.lock().unwrap();
        let mut map = self.read();
        map.insert(key, value);
        self.write(&map)
    }
    fn delete(&self, key: String) {
        let _held = self.1.lock().unwrap();
        let mut map = self.read();
        map.remove(&key);
        self.write(&map);
    }
}

struct Log;

impl ClientListener for Log {
    fn on_session_changed(&self, state: SessionState) {
        match state {
            SessionState::SignedIn { account } => println!("session: signed in as {}", account.user_id),
            other => println!("session: {other:?}"),
        }
    }
    fn on_account_changed(&self, _: Account) {}
    fn on_connection_changed(&self, state: ConnectionState) {
        println!("connection: {state:?}");
    }
    fn on_rooms_changed(&self, rooms: Vec<RoomSummary>, is_loaded: bool) {
        if is_loaded {
            println!("rooms: {}", rooms.len());
        }
    }
    fn on_incoming_message(&self, _: IncomingMessage) {}
    fn on_encryption_changed(&self, _: EncryptionStatus) {}
    fn on_verification_request(&self, _: VerificationPeer) {}
}

fn folders(dir: &Path) -> Vec<String> {
    std::fs::read_dir(dir.join("data/sessions"))
        .map(|d| d.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect())
        .unwrap_or_default()
}

#[tokio::main]
async fn main() {
    let mut args = std::env::args().skip(1);
    let dir = PathBuf::from(args.next().expect("a data dir"));
    let user = args.next().expect("a user");
    let password = args.next().expect("a password");
    let seconds: u64 = args.next().and_then(|s| s.parse().ok()).unwrap_or(5);
    let sign_out = args.next().as_deref() == Some("sign-out");
    std::fs::create_dir_all(&dir).expect("the data dir");
    let config = ClientConfig {
        data_dir: dir.join("data").to_string_lossy().into(),
        cache_dir: dir.join("cache").to_string_lossy().into(),
        device_name: "Xenia session flow".into(),
        user_agent: "Xenia/flow".into(),
        default_server: "localhost:8008".into(),
    };
    let secrets = Arc::new(FileSecrets(dir.join("secrets.json"), Mutex::new(())));
    let client = XeniaClient::new(config, secrets, Arc::new(Log));

    client.clone().restore().await;
    // An empty password stands for launching without a sign-in to fall back on.
    if client.account().is_none() && !password.is_empty() {
        let result = client.clone().sign_in("localhost:8008".into(), user, password).await;
        println!("sign_in: {:?}", result.map(|a| a.user_id));
    }
    tokio::time::sleep(Duration::from_secs(seconds)).await;
    println!("account: {:?}", client.account().map(|a| a.user_id));
    println!("folders: {:?}", folders(&dir));
    if sign_out {
        client.sign_out().await;
        println!("folders after sign-out: {:?}", folders(&dir));
    }
}
