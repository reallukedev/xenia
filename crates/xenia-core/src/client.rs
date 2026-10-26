//! `XeniaClient`: the object an app holds for its whole life.
//!
//! It owns the session (sign in, restore, sign out), the sync service and the room list, and it
//! reports everything the app shows through one [`ClientListener`]. Work that belongs to one
//! screen (a timeline, a search, a thread list) comes from here as its own object.

use std::sync::{
    Arc, Mutex, Once, RwLock,
    atomic::{AtomicBool, Ordering},
};

use matrix_sdk::{
    Client, RoomState, SessionChange,
    notification_settings::RoomNotificationMode,
    room::RoomMember,
    ruma::{
        OwnedUserId, RoomId, RoomOrAliasId, UserId,
        api::client::{
            receipt::create_receipt::v3::ReceiptType,
            room::{Visibility, create_room::v3::Request as CreateRoomRequest, create_room::v3::RoomPreset},
            session::get_login_types::v3::LoginType,
        },
        events::room::encryption::RoomEncryptionEventContent,
        events::{InitialStateEvent, receipt::ReceiptThread},
        serde::Raw,
    },
};
use matrix_sdk_ui::{
    room_list_service::State as RoomListState,
    sync_service::{State as SyncState, SyncService},
};
use tracing::{info, warn};

use crate::{
    encryption::{EncryptionStatus, watch_encryption},
    error::{XeniaError, Result},
    models::{
        Account, ConnectionState, ListFilter, Member, NotificationMode, Person, RoomSummary, Scope, SessionState,
        SignOutReason,
    },
    notifications::{IncomingMessage, NotificationContext},
    platform::{ClientConfig, SecretStore},
    rooms::{RoomListHub, rules},
    runtime::{TaskGuard, run},
    session::{
        Process, SESSION_KEY, Server, StoredSession, build_client, lock_crypto_store, new_passphrase, remove_stores,
    },
    sync::{MutexExt, RwLockExt},
};

/// Everything Xenia reports to the app. Calls arrive on background threads; the app hops to its
/// UI thread itself.
#[uniffi::export(with_foreign)]
pub trait ClientListener: Send + Sync {
    fn on_session_changed(&self, state: SessionState);
    fn on_account_changed(&self, account: Account);
    fn on_connection_changed(&self, state: ConnectionState);
    /// The whole list, in order (newest activity first). `is_loaded` turns true once the first
    /// full page has arrived, so an empty list then really means no conversations.
    fn on_rooms_changed(&self, rooms: Vec<RoomSummary>, is_loaded: bool);
    /// A message that deserves a notification on this device.
    fn on_incoming_message(&self, message: IncomingMessage);
    fn on_encryption_changed(&self, status: EncryptionStatus);
    /// Another device (or person) asks to verify with this one. Pick it up with
    /// `incoming_verification`.
    fn on_verification_request(&self, peer: crate::verification::VerificationPeer);
}

/// What the rest of the crate shares about the signed-in session.
pub(crate) struct Core {
    pub client: Client,
    pub user_id: String,
    pub listener: Arc<dyn ClientListener>,
    my_name: RwLock<String>,
    /// The account's notification keywords, which notify like mentions.
    keywords: RwLock<Vec<String>>,
    notification_context: Arc<Mutex<NotificationContext>>,
    public_receipts: Arc<AtomicBool>,
    show_membership: Arc<AtomicBool>,
}

impl Core {
    pub(crate) fn keywords(&self) -> Vec<String> {
        self.keywords.read_now().clone()
    }

    /// Reads the keywords from the account's push rules again.
    pub(crate) async fn reload_keywords(&self) {
        let words = self.client.notification_settings().await.enabled_keywords().await;
        *self.keywords.write_now() = words.into_iter().collect();
    }

    /// Joins, leaves and name changes appear in conversations.
    pub(crate) fn shows_membership(&self) -> bool {
        self.show_membership.load(Ordering::Relaxed)
    }

    pub(crate) fn my_name(&self) -> String {
        self.my_name.read_now().clone()
    }

    pub(crate) fn notification_context(&self) -> NotificationContext {
        self.notification_context.locked().clone()
    }

    /// The receipt to send when marking something read: public, or private to my own devices.
    pub(crate) fn read_receipt(&self) -> ReceiptType {
        if self.public_receipts.load(Ordering::Relaxed) { ReceiptType::Read } else { ReceiptType::ReadPrivate }
    }
}

struct Active {
    core: Arc<Core>,
    stored: StoredSession,
    sync: Arc<SyncService>,
    hub: Arc<RoomListHub>,
    _tasks: Vec<TaskGuard>,
}

/// What a server offers, checked while someone types its address.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ServerInfo {
    /// The address sign-in will use, like "https://matrix-client.matrix.org".
    pub homeserver_url: String,
    pub supports_password: bool,
    /// Offers signing in through a web page (SSO or OIDC).
    pub supports_web_login: bool,
    /// Offers the sync Xenia needs.
    pub supports_sliding_sync: bool,
}

/// A public room in a server's directory.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DirectoryRoom {
    pub id: String,
    pub name: String,
    pub topic: Option<String>,
    pub alias: Option<String>,
    pub avatar_url: Option<String>,
    pub member_count: u64,
    /// I'm already in it.
    pub is_joined: bool,
    /// Anyone can join (not knock-only or invite-only).
    pub can_join: bool,
}

#[derive(uniffi::Object)]
pub struct XeniaClient {
    config: ClientConfig,
    secrets: Arc<dyn SecretStore>,
    listener: Arc<dyn ClientListener>,
    active: tokio::sync::RwLock<Option<Active>>,
    /// A copy of the signed-in account for synchronous reads.
    account: RwLock<Option<Account>>,
    notification_context: Arc<Mutex<NotificationContext>>,
    public_receipts: Arc<AtomicBool>,
    show_membership: Arc<AtomicBool>,
    /// Held while a session is restored, signed in or signed out. One at a time: two clients on
    /// one account's stores would corrupt them, a second sign-in would leave a device behind,
    /// and a sign-out must never delete stores a restore is opening.
    gate: tokio::sync::Mutex<()>,
    /// A sign-out is waiting for the gate: a restore waiting to retry gives up instead.
    sign_out_requested: AtomicBool,
    sign_out_wakes: tokio::sync::Notify,
}

static TRACING: Once = Once::new();

/// Sessions whose sign-out never reached the server (signed out offline, say). Their tokens
/// still work there, and their pushers keep sending this device pushes, so the logout is tried
/// again each time a session starts here.
const PENDING_LOGOUTS_KEY: &str = "xenia.pendingLogouts.v1";

#[derive(serde::Serialize, serde::Deserialize)]
struct PendingLogout {
    homeserver_url: String,
    session: matrix_sdk::authentication::matrix::MatrixSession,
}

pub(crate) fn init_tracing() {
    TRACING.call_once(|| {
        let filter = tracing_subscriber::EnvFilter::try_from_env("XENIA_LOG")
            .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn,xenia_core=info,matrix_sdk::encryption=warn"));
        let _ = tracing_subscriber::fmt().with_env_filter(filter).with_ansi(false).with_target(false).try_init();
    });
}

impl XeniaClient {
    pub(crate) async fn core(&self) -> Result<Arc<Core>> {
        self.active.read().await.as_ref().map(|a| Arc::clone(&a.core)).ok_or(XeniaError::NotSignedIn)
    }

    pub(crate) async fn hub(&self) -> Result<Arc<RoomListHub>> {
        self.active.read().await.as_ref().map(|a| Arc::clone(&a.hub)).ok_or(XeniaError::NotSignedIn)
    }

    /// A room by ID, from the list or the client.
    pub(crate) async fn sdk_room(&self, room_id: &str) -> Result<matrix_sdk::Room> {
        let guard = self.active.read().await;
        let active = guard.as_ref().ok_or(XeniaError::NotSignedIn)?;
        if let Some(room) = active.hub.room(room_id) {
            return Ok(room);
        }
        let id = RoomId::parse(room_id)?;
        active.core.client.get_room(&id).ok_or(XeniaError::NotFound)
    }

    fn set_account(&self, account: Option<Account>) {
        *self.account.write_now() = account.clone();
        if let Some(account) = account {
            self.listener.on_account_changed(account);
        }
    }

    fn save_session(&self, stored: &StoredSession) -> Result<()> {
        let json = serde_json::to_string(stored).map_err(XeniaError::generic)?;
        if self.secrets.save(SESSION_KEY.to_owned(), json) {
            Ok(())
        } else {
            Err(XeniaError::generic("the session couldn't be saved"))
        }
    }

    fn load_session(&self) -> Option<StoredSession> {
        let raw = self.secrets.load(SESSION_KEY.to_owned())?;
        match serde_json::from_str(&raw) {
            Ok(stored) => Some(stored),
            Err(error) => {
                warn!("The saved session couldn't be read: {error}");
                None
            }
        }
    }

    /// Starts sync and the room list for a signed-in client, and remembers it.
    async fn activate(self: &Arc<Self>, client: Client, stored: StoredSession) -> Result<Account> {
        let user_id = client.user_id().ok_or(XeniaError::NotSignedIn)?.to_string();
        lock_crypto_store(&client, Process::App).await?;
        let core = Arc::new(Core {
            client: client.clone(),
            user_id: user_id.clone(),
            listener: Arc::clone(&self.listener),
            my_name: RwLock::new(String::new()),
            keywords: RwLock::default(),
            notification_context: Arc::clone(&self.notification_context),
            public_receipts: Arc::clone(&self.public_receipts),
            show_membership: Arc::clone(&self.show_membership),
        });

        // Offline mode keeps the service alive through network drops and resumes by itself.
        let sync = Arc::new(
            SyncService::builder(client.clone())
                .with_offline_mode()
                .with_room_list_timeline_limit(crate::rooms::LIST_TIMELINE_LIMIT)
                .build()
                .await
                .map_err(XeniaError::generic)?,
        );
        let hub = RoomListHub::new(Arc::clone(&core));
        hub.start(sync.room_list_service());
        crate::verification::watch_verification_requests(&client, Arc::clone(&self.listener));

        let tasks = vec![
            self.watch_connection(&sync),
            self.watch_session_changes(&client, stored.folder.clone()),
            watch_encryption(&client, Arc::clone(&self.listener)),
        ];

        self.retry_pending_logouts();

        let account = Account {
            user_id: user_id.clone(),
            display_name: None,
            avatar_url: None,
            device_id: client.device_id().map(|d| d.to_string()).unwrap_or_default(),
            homeserver: client.homeserver().to_string().trim_end_matches('/').to_owned(),
        };

        *self.active.write().await =
            Some(Active { core: Arc::clone(&core), stored, sync: Arc::clone(&sync), hub, _tasks: tasks });
        self.set_account(Some(account.clone()));
        self.listener.on_session_changed(SessionState::SignedIn { account: account.clone() });
        sync.start().await;

        // The profile arrives a moment later; the account updates when it does.
        let this = Arc::clone(self);
        let keywords = Arc::clone(&core);
        crate::runtime::spawn(async move {
            this.reload_profile().await;
            keywords.reload_keywords().await;
        });
        Ok(account)
    }

    fn pending_logouts(&self) -> Vec<PendingLogout> {
        self.secrets
            .load(PENDING_LOGOUTS_KEY.to_owned())
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default()
    }

    /// Changes the stored list under a lock, read and written in one go, so a sign-out recorded
    /// while a retry is out isn't lost when the retry saves what's left.
    fn update_pending_logouts(&self, change: impl FnOnce(&mut Vec<PendingLogout>)) {
        static LOCK: Mutex<()> = Mutex::new(());
        let _held = LOCK.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut pending = self.pending_logouts();
        change(&mut pending);
        match serde_json::to_string(&pending) {
            Ok(json) if !pending.is_empty() => {
                self.secrets.save(PENDING_LOGOUTS_KEY.to_owned(), json);
            }
            _ => self.secrets.delete(PENDING_LOGOUTS_KEY.to_owned()),
        }
    }

    fn add_pending_logout(&self, homeserver_url: String, session: matrix_sdk::authentication::matrix::MatrixSession) {
        self.update_pending_logouts(|pending| pending.push(PendingLogout { homeserver_url, session }));
    }

    /// Ends, on their servers, sessions signed out here while offline. Ones the server answered
    /// for (signed out, or the token already gone) are forgotten; ones it couldn't take now
    /// (unreachable, busy, failing) wait for next time.
    fn retry_pending_logouts(self: &Arc<Self>) {
        static RETRYING: AtomicBool = AtomicBool::new(false);
        let pending = self.pending_logouts();
        if pending.is_empty() || RETRYING.swap(true, Ordering::AcqRel) {
            return;
        }
        let this = Arc::clone(self);
        crate::runtime::spawn(async move {
            let mut handled = Vec::new();
            for item in pending {
                let result = async {
                    let client = Client::builder().homeserver_url(&item.homeserver_url).build().await?;
                    crate::session::require_secure(&client.homeserver())?;
                    client.restore_session(item.session.clone()).await?;
                    client.logout().await?;
                    Ok::<_, XeniaError>(())
                }
                .await;
                let answered = match &result {
                    Ok(()) => true,
                    // Its token can't be sent safely: drop it rather than try forever.
                    Err(XeniaError::InsecureServer) => true,
                    Err(error) => is_session_gone(error),
                };
                match result {
                    Ok(()) => info!("Signed out a session that was signed out offline"),
                    Err(error) if answered => info!("Dropped a pending sign-out the server answered: {error}"),
                    Err(error) => info!("A pending sign-out waits for next time: {error}"),
                }
                if answered {
                    handled.push(item.session.tokens.access_token.clone());
                }
            }
            this.update_pending_logouts(|pending| {
                pending.retain(|p| !handled.contains(&p.session.tokens.access_token));
            });
            RETRYING.store(false, Ordering::Release);
        });
    }

    /// Reads my name and photo from the server again.
    pub(crate) async fn reload_profile(&self) {
        let Ok(core) = self.core().await else { return };
        let account = core.client.account();
        let name = account.get_display_name().await.ok().flatten();
        let avatar = account.get_avatar_url().await.ok().flatten();
        let changed = {
            let mut my_name = core.my_name.write_now();
            let new = name.clone().unwrap_or_default();
            let changed = *my_name != new;
            *my_name = new;
            changed
        };
        // Summaries built before the name arrived missed mentions by name.
        if changed && let Ok(hub) = self.hub().await {
            hub.refresh_all();
        }
        let current = self.account.read_now().clone();
        if let Some(mut current) = current {
            current.display_name = name;
            current.avatar_url = avatar.map(|a| a.to_string());
            self.set_account(Some(current));
        }
    }

    fn watch_connection(self: &Arc<Self>, sync: &Arc<SyncService>) -> TaskGuard {
        let listener = Arc::clone(&self.listener);
        let mut sync_states = sync.state();
        let mut list_states = sync.room_list_service().state();
        TaskGuard::spawn(async move {
            let mut sync_state = sync_states.get();
            let mut list_state = list_states.get();
            let mut last = None;
            loop {
                let connection = match &sync_state {
                    SyncState::Offline => ConnectionState::Offline,
                    SyncState::Error(_) => ConnectionState::Error,
                    SyncState::Running if matches!(list_state, RoomListState::Running) => ConnectionState::Connected,
                    _ => ConnectionState::Connecting,
                };
                if last != Some(connection) {
                    last = Some(connection);
                    listener.on_connection_changed(connection);
                }
                tokio::select! {
                    next = sync_states.next() => match next { Some(s) => sync_state = s, None => break },
                    next = list_states.next() => match next { Some(s) => list_state = s, None => break },
                }
            }
        })
    }

    fn watch_session_changes(self: &Arc<Self>, client: &Client, folder: String) -> TaskGuard {
        let this = Arc::downgrade(self);
        let mut changes = client.subscribe_to_session_changes();
        let client = client.clone();
        TaskGuard::spawn(async move {
            loop {
                let change = match changes.recv().await {
                    Ok(change) => change,
                    // Fell behind: save the tokens in case a refresh was missed. (A revoked token
                    // keeps failing, so that change comes again.)
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => SessionChange::TokensRefreshed,
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                };
                let Some(this) = this.upgrade() else { break };
                match change {
                    SessionChange::UnknownToken(token) => {
                        // Even a soft logout is the end here: signing in again makes a new device
                        // (Xenia doesn't resume one), so the old stores could never be used.
                        info!("The server ended the session (soft logout: {})", token.soft_logout);
                        // Ending the session drops this task; do it from a fresh one. It waits its
                        // turn with sign-ins and sign-outs, and ends only this session: by then
                        // another may have taken its place.
                        let folder = folder.clone();
                        crate::runtime::spawn(async move {
                            let _gate = this.gate.lock().await;
                            let running = this.active.read().await.as_ref().map(|a| a.stored.folder.clone());
                            if running.as_deref() == Some(folder.as_str()) {
                                this.end_session(Some(SignOutReason::SessionRevoked), Ending::Forget).await;
                            }
                        });
                        break;
                    }
                    SessionChange::TokensRefreshed => {
                        let stored = this.active.read().await.as_ref().map(|a| a.stored.clone());
                        if let (Some(mut stored), Some(session)) = (stored, client.matrix_auth().session()) {
                            stored.session = session;
                            this.save_refreshed_session(&stored);
                        }
                    }
                }
            }
        })
    }

    /// Stops the running session and reports `SignedOut`. `reason` explains it to the person
    /// when it happened by itself; `ending` says whether anything on disk goes with it.
    async fn end_session(&self, reason: Option<SignOutReason>, ending: Ending) {
        let active = self.active.write().await.take();
        if let Some(active) = &active {
            active.hub.stop();
            active.sync.stop().await;
        }
        if ending == Ending::Forget {
            if let Some(active) = &active {
                remove_stores(&self.config, &active.stored.folder).await;
                self.forget_saved_session(&active.stored.folder);
            }
            self.remove_saved_files().await;
        }
        *self.account.write_now() = None;
        self.listener.on_session_changed(SessionState::SignedOut { reason });
    }

    /// Decrypted copies of attachments belong to the session that opened them.
    async fn remove_saved_files(&self) {
        if let Err(error) = tokio::fs::remove_dir_all(crate::media::saved_files_dir(&self.config.cache_dir)).await
            && error.kind() != std::io::ErrorKind::NotFound
        {
            warn!("Couldn't remove saved files: {error}");
        }
    }

    /// Ends a session saved here but not running (kept after a restore that failed): on the
    /// server when it can be reached, and on this device now. Call with the gate held.
    async fn discard_saved_session(&self) {
        let Some(saved) = self.load_session() else { return };
        self.add_pending_logout(saved.homeserver_url.clone(), saved.session.clone());
        remove_stores(&self.config, &saved.folder).await;
        self.forget_saved_session(&saved.folder);
        self.remove_saved_files().await;
    }

    /// Waits up to `delay` before a restore tries again; false when a sign-out asked it to stop.
    async fn wait_to_retry(&self, delay: std::time::Duration) -> bool {
        let wake = self.sign_out_wakes.notified();
        tokio::pin!(wake);
        wake.as_mut().enable();
        if self.sign_out_requested.load(Ordering::Acquire) {
            return false;
        }
        tokio::select! {
            () = tokio::time::sleep(delay) => !self.sign_out_requested.load(Ordering::Acquire),
            () = wake => false,
        }
    }

    /// Deletes the saved session, but only if it's still the one in `folder`. The secret store
    /// is shared (another copy of the app, the notification extensions), and a newer session
    /// saved there by someone else isn't this one to forget.
    fn forget_saved_session(&self, folder: &str) {
        if self.load_session().is_some_and(|saved| saved.folder == folder) {
            self.secrets.delete(SESSION_KEY.to_owned());
        }
    }

    /// Saves refreshed tokens, unless another sign-in has replaced the saved session meanwhile.
    fn save_refreshed_session(&self, stored: &StoredSession) {
        if self.load_session().is_some_and(|saved| saved.folder != stored.folder) {
            return;
        }
        if let Err(error) = self.save_session(stored) {
            warn!("Couldn't save refreshed tokens: {error}");
        }
    }
}

/// What ending a session does to what's saved on this device.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Ending {
    /// The session is over for good (signed out here, or the server ended it): its saved secret,
    /// stores and decrypted files go.
    Forget,
    /// It can't run now but may later (a store that wouldn't open): the secret and the stores,
    /// with the encryption keys, stay for next time.
    Keep,
}

#[uniffi::export]
impl XeniaClient {
    #[uniffi::constructor]
    pub fn new(config: ClientConfig, secrets: Arc<dyn SecretStore>, listener: Arc<dyn ClientListener>) -> Arc<Self> {
        init_tracing();
        Arc::new(Self {
            config,
            secrets,
            listener,
            active: tokio::sync::RwLock::new(None),
            account: RwLock::new(None),
            notification_context: Arc::default(),
            public_receipts: Arc::new(AtomicBool::new(true)),
            show_membership: Arc::new(AtomicBool::new(true)),
            gate: tokio::sync::Mutex::new(()),
            sign_out_requested: AtomicBool::new(false),
            sign_out_wakes: tokio::sync::Notify::new(),
        })
    }

    /// The server the sign-in screen starts with.
    pub fn default_server(&self) -> String {
        self.config.default_server.clone()
    }

    /// Comes back signed in if a session was saved. Reports `SignedIn` or `SignedOut`.
    pub async fn restore(self: Arc<Self>) {
        let this = Arc::clone(&self);
        run(async move {
            // Whatever holds the gate reports to the same listener, so a second caller (another
            // window) has nothing to do.
            let Ok(_gate) = this.gate.try_lock() else { return };

            // A session already running (a Mac window reopened) is simply reported again, whatever
            // the secret store says this moment.
            if let Some(account) = this.account() {
                this.listener.on_session_changed(SessionState::SignedIn { account });
                return;
            }
            this.listener.on_session_changed(SessionState::Restoring);
            let Some(stored) = this.load_session() else {
                this.listener.on_session_changed(SessionState::SignedOut { reason: None });
                return;
            };
            let mut delay = std::time::Duration::from_secs(2);
            // Opening the stores can fail for a moment (the notification extension holding the
            // database, a busy disk): only give the session up after it keeps failing.
            let mut local_failures = 0;
            loop {
                // Signed out or in again elsewhere while waiting to retry: this session is over.
                if this.load_session().is_none_or(|s| s.folder != stored.folder) {
                    this.listener.on_session_changed(SessionState::SignedOut { reason: None });
                    return;
                }
                let restored = async {
                    let client = build_client(
                        &this.config,
                        Server::Url(&stored.homeserver_url),
                        &stored.folder,
                        &stored.passphrase,
                        Process::App,
                    )
                    .await?;
                    client.restore_session(stored.session.clone()).await?;
                    Ok::<_, XeniaError>(client)
                }
                .await;
                match restored {
                    // A sign-out came in while the stores opened: it ends this session instead.
                    Ok(_) if this.sign_out_requested.load(Ordering::Acquire) => return,
                    Ok(client) => {
                        if let Err(error) = this.activate(client, stored.clone()).await {
                            warn!("Couldn't start the restored session: {error}");
                            this.end_session(Some(SignOutReason::RestoreFailed), Ending::Keep).await;
                        }
                        return;
                    }
                    // A network problem is never a reason to throw the session (and its keys)
                    // away: wait and try again.
                    Err(XeniaError::ServerUnreachable) => {
                        this.listener.on_connection_changed(ConnectionState::Offline);
                        if !this.wait_to_retry(delay).await {
                            return;
                        }
                        delay = (delay * 2).min(std::time::Duration::from_secs(60));
                    }
                    Err(error) if local_failures < 3 => {
                        local_failures += 1;
                        warn!("Couldn't restore the session (attempt {local_failures}), trying again: {error}");
                        if !this.wait_to_retry(std::time::Duration::from_secs(1 << local_failures)).await {
                            return;
                        }
                    }
                    Err(error) => {
                        // Not today, but nothing is thrown away: a store that wouldn't open (held
                        // by another process, a full disk) may open next launch, and its keys are
                        // the only copy of older messages. Nor is the session ended on the server.
                        warn!("Couldn't restore the session; keeping it for next time: {error}");
                        this.end_session(Some(SignOutReason::RestoreFailed), Ending::Keep).await;
                        return;
                    }
                }
            }
        })
        .await
    }

    /// Checks what a typed server address offers, for the sign-in screen.
    pub async fn check_server(&self, address: String) -> Result<ServerInfo> {
        run(async move {
            let client = Client::builder()
                .server_name_or_homeserver_url(crate::session::normalize_server(&address))
                .build()
                .await?;
            crate::session::require_secure(&client.homeserver())?;
            let login_types = client.matrix_auth().get_login_types().await?;
            let supports_password = login_types.flows.iter().any(|f| matches!(f, LoginType::Password(_)));
            let supports_web_login = login_types.flows.iter().any(|f| matches!(f, LoginType::Sso(_)));
            let supports_sliding_sync = client
                .available_sliding_sync_versions()
                .await
                .iter()
                .any(|v| matches!(v, matrix_sdk::sliding_sync::Version::Native));
            Ok(ServerInfo {
                homeserver_url: client.homeserver().to_string().trim_end_matches('/').to_owned(),
                supports_password,
                supports_web_login,
                supports_sliding_sync,
            })
        })
        .await
    }

    /// Signs in with a username (or full Matrix ID) and password.
    pub async fn sign_in(self: Arc<Self>, server: String, username: String, password: String) -> Result<Account> {
        let this = Arc::clone(&self);
        run(async move {
            // The app only offers signing in while signed out; getting here otherwise is a race
            // (a restore finishing, two sign-ins at once). Replacing the session would orphan
            // its device on the server, so the one already there stays.
            let Ok(_gate) = this.gate.try_lock() else {
                return Err(XeniaError::generic("a session is already starting"));
            };
            if this.account().is_some() {
                return Err(XeniaError::generic("already signed in"));
            }
            let folder = uuid::Uuid::new_v4().to_string();
            let passphrase = new_passphrase();
            let attempt = async {
                let client =
                    build_client(&this.config, Server::Typed(&server), &folder, &passphrase, Process::App).await?;
                let login_types = client.matrix_auth().get_login_types().await?;
                if !login_types.flows.iter().any(|f| matches!(f, LoginType::Password(_))) {
                    return Err(XeniaError::PasswordLoginUnsupported);
                }
                let username = username.trim();
                client
                    .matrix_auth()
                    .login_username(username, &password)
                    .initial_device_display_name(&this.config.device_name)
                    .send()
                    .await?;
                let session = client.matrix_auth().session().ok_or(XeniaError::NotSignedIn)?;
                // Only now, with the new session in hand, does one kept after a restore that
                // failed go (its device on the server, its stores and keys here): a wrong password
                // or a dropped connection must never cost the only copy of those keys.
                this.discard_saved_session().await;
                let stored = StoredSession {
                    session,
                    homeserver_url: client.homeserver().to_string(),
                    folder: folder.clone(),
                    passphrase: passphrase.clone(),
                };
                this.save_session(&stored)?;
                let signed_in = client.clone();
                let activated = this.activate(client, stored.clone()).await;
                if activated.is_err() {
                    // Signed in on the server but not here: end that session there too, now or
                    // when the network allows, rather than leave a device behind.
                    if signed_in.logout().await.is_err() {
                        this.add_pending_logout(stored.homeserver_url, stored.session);
                    }
                }
                activated
            }
            .await;
            if attempt.is_err() {
                // The session may already be saved; left behind, the next launch would restore
                // it into empty stores without its keys.
                if this.load_session().is_some_and(|s| s.folder == folder) {
                    this.secrets.delete(SESSION_KEY.to_owned());
                }
                remove_stores(&this.config, &folder).await;
            }
            attempt
        })
        .await
    }

    /// Signs out: tells the server, then forgets the session and its stores on this device.
    pub async fn sign_out(self: Arc<Self>) {
        let this = Arc::clone(&self);
        run(async move {
            // Wait for any restore or sign-in to finish (a restore waiting to retry stops now),
            // so nothing deletes stores while they're being opened.
            this.sign_out_requested.store(true, Ordering::Release);
            this.sign_out_wakes.notify_waiters();
            let _gate = this.gate.lock().await;
            this.sign_out_requested.store(false, Ordering::Release);
            let current = this
                .active
                .read()
                .await
                .as_ref()
                .map(|a| (a.core.client.clone(), a.stored.clone(), Arc::clone(&a.sync)));
            if let Some((client, stored, sync)) = current {
                sync.stop().await;
                if let Err(error) = client.logout().await {
                    warn!("The logout request failed; clearing the session anyway: {error}");
                    // Offline, busy or failing: the server still has the session (and its
                    // pusher). Try again later, unless it already forgot the session.
                    if !is_session_gone(&XeniaError::from(error)) {
                        this.add_pending_logout(stored.homeserver_url, stored.session);
                    }
                }
            } else {
                this.discard_saved_session().await;
            }
            this.end_session(None, Ending::Forget).await;
        })
        .await
    }

    /// The signed-in account, if any.
    pub fn account(&self) -> Option<Account> {
        self.account.read_now().clone()
    }

    // MARK: Lists

    /// The conversations one list shows, from the latest snapshot.
    pub fn rooms(&self, scope: Scope, filter: ListFilter, query: String) -> Vec<RoomSummary> {
        rules::filter_rooms(&self.room_snapshot(), Some(scope), filter, &query)
    }

    /// Conversations in a scope that want attention, for badges.
    pub fn unread_total(&self, scope: Scope) -> u32 {
        rules::unread_total(&self.room_snapshot(), scope)
    }

    /// Filters a list the app already holds (the same rules as `rooms`).
    pub fn filter_rooms(
        &self,
        rooms: Vec<RoomSummary>,
        scope: Scope,
        filter: ListFilter,
        query: String,
    ) -> Vec<RoomSummary> {
        rules::filter_rooms(&rooms, Some(scope), filter, &query)
    }

    /// Chats and rooms in one list (the unified view), with the same rules as `filter_rooms`.
    pub fn filter_all_rooms(&self, rooms: Vec<RoomSummary>, filter: ListFilter, query: String) -> Vec<RoomSummary> {
        rules::filter_rooms(&rooms, None, filter, &query)
    }

    // MARK: This device

    /// What's on screen and how this device notifies, for deciding notifications.
    pub fn set_notification_context(&self, context: NotificationContext) {
        *self.notification_context.locked() = context;
    }

    /// Whether reading a conversation tells the people in it. Off, Xenia still marks it read,
    /// with a private receipt only my own devices see.
    pub fn set_send_read_receipts(&self, enabled: bool) {
        self.public_receipts.store(enabled, Ordering::Relaxed);
    }

    /// Whether conversations show people joining, leaving and changing their names. Takes
    /// effect in conversations opened after the change.
    pub fn set_show_membership_changes(&self, show: bool) {
        self.show_membership.store(show, Ordering::Relaxed);
    }

    /// The app went to the background (iOS suspends it; sync stops cleanly first).
    pub async fn pause(&self) {
        let sync = self.active.read().await.as_ref().map(|a| Arc::clone(&a.sync));
        if let Some(sync) = sync {
            run(async move { sync.stop().await }).await;
        }
    }

    /// The app came back: sync picks up where it left off.
    pub async fn resume(&self) {
        let sync = self.active.read().await.as_ref().map(|a| Arc::clone(&a.sync));
        if let Some(sync) = sync {
            run(async move { sync.start().await }).await;
        }
    }

    // MARK: Conversation actions
    // Shared by the list's menus and swipes, the Mac menu bar and the info screen, so every
    // door does the same thing.

    /// Marks a conversation read (and clears a manual unread flag).
    pub async fn mark_read(&self, room_id: String) -> Result<()> {
        let room = self.sdk_room(&room_id).await?;
        let core = self.core().await?;
        let hub = self.hub().await?;
        run(async move {
            if room.is_marked_unread() {
                room.set_unread_flag(false).await?;
            }
            if let Some(event_id) = latest_event_id(&room).await {
                room.send_single_receipt(core.read_receipt(), ReceiptThread::Unthreaded, event_id).await?;
            }
            hub.refresh(&room_id);
            Ok(())
        })
        .await
    }

    /// Flags a conversation unread (or clears the flag).
    pub async fn set_marked_unread(&self, room_id: String, unread: bool) -> Result<()> {
        if !unread {
            return self.mark_read(room_id).await;
        }
        let room = self.sdk_room(&room_id).await?;
        let hub = self.hub().await?;
        run(async move {
            room.set_unread_flag(true).await?;
            hub.refresh(&room_id);
            Ok(())
        })
        .await
    }

    /// Marks every unread conversation in a list (or everywhere) read.
    pub async fn mark_all_read(&self, scope: Option<Scope>) -> Result<()> {
        let snapshot = self.room_snapshot();
        let ids: Vec<String> = snapshot
            .iter()
            .filter(|r| !r.is_invite && r.is_unread && scope.is_none_or(|s| r.scope == s))
            .map(|r| r.id.clone())
            .collect();
        for id in ids {
            if let Err(error) = self.mark_read(id).await {
                warn!("Couldn't mark a conversation read: {error}");
            }
        }
        Ok(())
    }

    pub async fn set_favourite(&self, room_id: String, favourite: bool) -> Result<()> {
        let room = self.sdk_room(&room_id).await?;
        let hub = self.hub().await?;
        run(async move {
            room.set_is_favourite(favourite, None).await?;
            hub.refresh(&room_id);
            Ok(())
        })
        .await
    }

    /// Moves a pin: saves its place among the others, so every device shows the same order.
    pub async fn set_favourite_order(&self, room_id: String, order: f64) -> Result<()> {
        let room = self.sdk_room(&room_id).await?;
        let hub = self.hub().await?;
        run(async move {
            room.set_is_favourite(true, Some(order)).await?;
            hub.refresh(&room_id);
            Ok(())
        })
        .await
    }

    pub async fn set_notification_mode(&self, room_id: String, mode: NotificationMode) -> Result<()> {
        let core = self.core().await?;
        let hub = self.hub().await?;
        run(async move {
            let settings = core.client.notification_settings().await;
            let id = RoomId::parse(&room_id)?;
            let result = match mode {
                NotificationMode::Mute => settings.set_room_notification_mode(&id, RoomNotificationMode::Mute).await,
                NotificationMode::MentionsOnly => {
                    settings.set_room_notification_mode(&id, RoomNotificationMode::MentionsAndKeywordsOnly).await
                }
                NotificationMode::AllMessages => {
                    settings.set_room_notification_mode(&id, RoomNotificationMode::AllMessages).await
                }
            };
            result.map_err(XeniaError::generic)?;
            hub.refresh(&room_id);
            Ok(())
        })
        .await
    }

    pub async fn leave(&self, room_id: String) -> Result<()> {
        let room = self.sdk_room(&room_id).await?;
        run(async move { room.leave().await.map_err(XeniaError::from) }).await
    }

    pub async fn accept_invite(&self, room_id: String) -> Result<()> {
        let room = self.sdk_room(&room_id).await?;
        run(async move { room.join().await.map_err(XeniaError::from) }).await
    }

    pub async fn decline_invite(&self, room_id: String) -> Result<()> {
        let room = self.sdk_room(&room_id).await?;
        run(async move { room.leave().await.map_err(XeniaError::from) }).await
    }

    /// Joins "#room:server" or "!id:server". Returns the room ID.
    pub async fn join(&self, address: String) -> Result<String> {
        let core = self.core().await?;
        run(async move {
            let address = address.trim();
            let id = RoomOrAliasId::parse(address).map_err(|_| XeniaError::NotFound)?;
            let via: Vec<_> = id.server_name().map(|s| vec![s.to_owned()]).unwrap_or_default();
            let room = core.client.join_room_by_id_or_alias(&id, &via).await?;
            Ok(room.room_id().to_string())
        })
        .await
    }

    /// Opens the existing chat with someone, or starts an encrypted one. Returns the room ID.
    pub async fn start_direct_chat(&self, user_id: String) -> Result<String> {
        let core = self.core().await?;
        run(async move {
            let user = UserId::parse(&user_id)?;
            if let Some(room) = core.client.get_dm_room(&user)
                && room.state() == RoomState::Joined
            {
                return Ok(room.room_id().to_string());
            }
            let room = core.client.create_dm(&user).await?;
            Ok(room.room_id().to_string())
        })
        .await
    }

    /// Creates an encrypted group with a name and people. Returns the room ID.
    pub async fn create_group(&self, name: String, user_ids: Vec<String>) -> Result<String> {
        let core = self.core().await?;
        run(async move {
            let invite: Vec<OwnedUserId> = user_ids.iter().filter_map(|u| UserId::parse(u).ok()).collect();
            let mut request = CreateRoomRequest::new();
            let name = name.trim();
            if !name.is_empty() {
                request.name = Some(name.to_owned());
            }
            request.invite = invite;
            request.is_direct = false;
            request.preset = Some(RoomPreset::PrivateChat);
            request.visibility = Visibility::Private;
            let encryption =
                InitialStateEvent::with_empty_state_key(RoomEncryptionEventContent::with_recommended_defaults());
            request.initial_state = vec![Raw::new(&encryption).map_err(XeniaError::generic)?.cast_unchecked()];
            let room = core.client.create_room(request).await?;
            Ok(room.room_id().to_string())
        })
        .await
    }

    pub async fn invite(&self, room_id: String, user_ids: Vec<String>) -> Result<()> {
        let room = self.sdk_room(&room_id).await?;
        run(async move {
            for user in user_ids {
                room.invite_user_by_id(&UserId::parse(&user)?).await?;
            }
            Ok(())
        })
        .await
    }

    pub async fn set_room_name(&self, room_id: String, name: String) -> Result<()> {
        let room = self.sdk_room(&room_id).await?;
        run(async move {
            room.set_name(name.trim().to_owned()).await?;
            Ok(())
        })
        .await
    }

    pub async fn set_room_topic(&self, room_id: String, topic: String) -> Result<()> {
        let room = self.sdk_room(&room_id).await?;
        run(async move {
            room.set_room_topic(topic.trim()).await?;
            Ok(())
        })
        .await
    }

    /// Joined and invited members, sorted by name.
    pub async fn members(&self, room_id: String) -> Result<Vec<Member>> {
        let room = self.sdk_room(&room_id).await?;
        let me = self.core().await?.user_id.clone();
        run(async move {
            let members = room.members(matrix_sdk::RoomMemberships::JOIN | matrix_sdk::RoomMemberships::INVITE).await?;
            let mut out: Vec<Member> = members.iter().map(|m| member(m, &me)).collect();
            out.sort_by_key(|m| crate::text::normalize_for_search(&m.name));
            Ok(out)
        })
        .await
    }

    /// People in the server's user directory.
    pub async fn search_people(&self, query: String) -> Result<Vec<Person>> {
        let core = self.core().await?;
        run(async move {
            let term = query.trim();
            if term.is_empty() {
                return Ok(Vec::new());
            }
            let response = core.client.search_users(term, 20).await?;
            Ok(response
                .results
                .into_iter()
                .filter(|u| u.user_id.as_str() != core.user_id)
                .map(|u| Person {
                    user_id: u.user_id.to_string(),
                    display_name: u.display_name,
                    avatar_url: u.avatar_url.map(|a| a.to_string()),
                })
                .collect())
        })
        .await
    }

    /// A person's profile, for a Matrix ID typed in full.
    pub async fn profile(&self, user_id: String) -> Result<Person> {
        let core = self.core().await?;
        run(async move {
            let user = UserId::parse(&user_id)?;
            let profile = core.client.account().fetch_user_profile_of(&user).await?;
            Ok(Person {
                user_id,
                display_name: profile.get("displayname").and_then(|v| v.as_str()).map(str::to_owned),
                avatar_url: profile.get("avatar_url").and_then(|v| v.as_str()).map(str::to_owned),
            })
        })
        .await
    }

    /// Public rooms on my server, matching `query`.
    pub async fn public_rooms(&self, query: String) -> Result<Vec<DirectoryRoom>> {
        let core = self.core().await?;
        let joined: std::collections::HashSet<String> =
            self.room_snapshot().iter().filter(|r| !r.is_invite).map(|r| r.id.clone()).collect();
        run(async move {
            use matrix_sdk::ruma::{
                api::client::directory::get_public_rooms_filtered::v3::Request, directory::Filter, room::JoinRuleKind,
            };
            let mut request = Request::new();
            let mut filter = Filter::new();
            let term = query.trim();
            if !term.is_empty() {
                filter.generic_search_term = Some(term.to_owned());
            }
            request.filter = filter;
            request.limit = Some(50u32.into());
            let response = core.client.public_rooms_filtered(request).await?;
            Ok(response
                .chunk
                .into_iter()
                .map(|r| DirectoryRoom {
                    id: r.room_id.to_string(),
                    name: r
                        .name
                        .filter(|n| !n.trim().is_empty())
                        .or_else(|| r.canonical_alias.as_ref().map(|a| a.to_string()))
                        .unwrap_or_else(|| r.room_id.to_string()),
                    topic: r.topic.map(|t| t.trim().to_owned()).filter(|t| !t.is_empty()),
                    alias: r.canonical_alias.map(|a| a.to_string()),
                    avatar_url: r.avatar_url.map(|a| a.to_string()),
                    member_count: r.num_joined_members.into(),
                    is_joined: joined.contains(r.room_id.as_str()),
                    can_join: matches!(r.join_rule, JoinRuleKind::Public),
                })
                .collect())
        })
        .await
    }

    // MARK: Drafts

    /// Unsent text for a conversation or thread.
    pub async fn load_draft(&self, room_id: String, thread_root: Option<String>) -> Option<String> {
        let room = self.sdk_room(&room_id).await.ok()?;
        run(async move {
            let root = thread_root.as_deref().and_then(|r| matrix_sdk::ruma::EventId::parse(r).ok());
            room.load_composer_draft(root.as_deref()).await.ok().flatten().map(|d| d.plain_text)
        })
        .await
    }

    /// Keeps unsent text; empty text clears the draft.
    pub async fn save_draft(&self, room_id: String, thread_root: Option<String>, text: String) {
        let Ok(room) = self.sdk_room(&room_id).await else {
            return;
        };
        let hub = self.hub().await.ok();
        run(async move {
            let root = thread_root.as_deref().and_then(|r| matrix_sdk::ruma::EventId::parse(r).ok());
            let result = if text.trim().is_empty() {
                room.clear_composer_draft(root.as_deref()).await
            } else {
                room.save_composer_draft(
                    matrix_sdk::ComposerDraft {
                        plain_text: text.clone(),
                        html_text: None,
                        draft_type: matrix_sdk::ComposerDraftType::NewMessage,
                        attachments: Vec::new(),
                    },
                    root.as_deref(),
                )
                .await
            };
            if let Err(error) = result {
                warn!("Couldn't save a draft: {error}");
            }
            if root.is_none()
                && let Some(hub) = hub
            {
                hub.set_draft(&room_id, Some(text));
            }
        })
        .await
    }

    // MARK: Profile

    pub async fn set_display_name(&self, name: String) -> Result<()> {
        let core = self.core().await?;
        run(async move { core.client.account().set_display_name(Some(name.trim())).await.map_err(XeniaError::from) })
            .await?;
        // Rebuilds the summaries too, since mentions by name change with it.
        self.reload_profile().await;
        Ok(())
    }
}

impl XeniaClient {
    /// The latest room list, empty before sign-in (or while signing in or out holds the lock).
    pub(crate) fn room_snapshot(&self) -> Arc<Vec<RoomSummary>> {
        let Ok(guard) = self.active.try_read() else { return Arc::default() };
        guard.as_ref().map(|a| a.hub.snapshot()).unwrap_or_default()
    }

    pub(crate) fn cache_dir(&self) -> String {
        self.config.cache_dir.clone()
    }

    pub(crate) async fn sync_service(&self) -> Option<Arc<SyncService>> {
        self.active.read().await.as_ref().map(|a| Arc::clone(&a.sync))
    }
}

fn member(m: &RoomMember, me: &str) -> Member {
    Member {
        user_id: m.user_id().to_string(),
        name: m
            .display_name()
            .map(str::to_owned)
            .filter(|n| !n.trim().is_empty())
            .unwrap_or_else(|| m.user_id().to_string()),
        avatar_url: m.avatar_url().map(|a| a.to_string()),
        is_invited: matches!(m.membership(), matrix_sdk::ruma::events::room::member::MembershipState::Invite),
        is_admin: m.power_level() >= matrix_sdk::ruma::int!(50),
        is_you: m.user_id().as_str() == me,
    }
}

async fn latest_event_id(room: &matrix_sdk::Room) -> Option<matrix_sdk::ruma::OwnedEventId> {
    let (cache, _drop) = room.event_cache().await.ok()?;
    let events = cache.events().await.ok()?;
    events.iter().rev().find_map(|e| e.event_id().map(ToOwned::to_owned))
}

/// The server has already ended the session (signed out elsewhere, or the token is unknown), so
/// there's nothing left to sign out.
fn is_session_gone(error: &XeniaError) -> bool {
    match error {
        XeniaError::Generic { message } | XeniaError::Forbidden { message } => {
            message.to_lowercase().contains("m_unknown_token")
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;

    #[derive(Default)]
    struct Secrets(Mutex<HashMap<String, String>>);

    impl SecretStore for Secrets {
        fn load(&self, key: String) -> Option<String> {
            self.0.locked().get(&key).cloned()
        }
        fn save(&self, key: String, value: String) -> bool {
            self.0.locked().insert(key, value);
            true
        }
        fn delete(&self, key: String) {
            self.0.locked().remove(&key);
        }
    }

    struct Quiet;

    impl ClientListener for Quiet {
        fn on_session_changed(&self, _: SessionState) {}
        fn on_account_changed(&self, _: Account) {}
        fn on_connection_changed(&self, _: ConnectionState) {}
        fn on_rooms_changed(&self, _: Vec<RoomSummary>, _: bool) {}
        fn on_incoming_message(&self, _: IncomingMessage) {}
        fn on_encryption_changed(&self, _: EncryptionStatus) {}
        fn on_verification_request(&self, _: crate::verification::VerificationPeer) {}
    }

    fn stored(folder: &str, token: &str) -> StoredSession {
        serde_json::from_value(serde_json::json!({
            "session": { "user_id": "@luke:x", "device_id": "DEVICE", "access_token": token },
            "homeserver_url": "http://x",
            "folder": folder,
            "passphrase": "secret",
        }))
        .expect("a stored session")
    }

    fn client_in(dir: &std::path::Path) -> Arc<XeniaClient> {
        let config = ClientConfig {
            data_dir: dir.join("data").to_string_lossy().into_owned(),
            cache_dir: dir.join("cache").to_string_lossy().into_owned(),
            device_name: String::new(),
            user_agent: String::new(),
            default_server: String::new(),
        };
        XeniaClient::new(config, Arc::new(Secrets::default()), Arc::new(Quiet))
    }

    /// A client sharing its secret store with another copy of the app, which has since signed in
    /// as the session in "newer".
    fn client_after_another_sign_in() -> Arc<XeniaClient> {
        let client = client_in(std::path::Path::new("/nonexistent"));
        client.save_session(&stored("newer", "new-token")).expect("saved");
        client
    }

    /// A session saved and given stores on disk but not running, as a restore that failed
    /// leaves it, plus a decrypted attachment.
    fn kept_session(dir: &std::path::Path) -> (Arc<XeniaClient>, Vec<std::path::PathBuf>) {
        let client = client_in(dir);
        client.save_session(&stored("kept", "kept-token")).expect("saved");
        let paths = crate::session::store_paths(&client.config, "kept");
        let saved_files = crate::media::saved_files_dir(&client.config.cache_dir);
        let leftovers = vec![paths.data, paths.cache, saved_files];
        for path in &leftovers {
            std::fs::create_dir_all(path).expect("a folder");
        }
        (client, leftovers)
    }

    #[test]
    fn ending_an_older_session_leaves_a_newer_saved_one_alone() {
        let client = client_after_another_sign_in();
        client.forget_saved_session("older");
        assert_eq!(client.load_session().map(|s| s.folder), Some("newer".to_owned()));
        client.forget_saved_session("newer");
        assert!(client.load_session().is_none());
    }

    #[tokio::test]
    async fn signing_out_ends_a_kept_session_that_never_ran() {
        let dir = tempfile::tempdir().expect("a folder");
        let (client, leftovers) = kept_session(dir.path());
        client.clone().sign_out().await;
        assert!(client.load_session().is_none());
        assert!(leftovers.iter().all(|path| !path.exists()), "stores and decrypted files are gone");
        let pending: Vec<String> =
            client.pending_logouts().into_iter().map(|p| p.session.tokens.access_token).collect();
        assert_eq!(pending, ["kept-token"], "the server is told when it can be reached");
    }

    #[tokio::test]
    async fn a_failed_sign_in_keeps_the_kept_session_and_its_keys() {
        let dir = tempfile::tempdir().expect("a folder");
        let (client, leftovers) = kept_session(dir.path());
        // Nothing listens there, as when offline: the sign-in fails before any login.
        let result = client.clone().sign_in("http://127.0.0.1:9".into(), "luke".into(), "pw".into()).await;
        assert!(result.is_err());
        assert_eq!(client.load_session().map(|s| s.folder), Some("kept".to_owned()));
        assert!(leftovers.iter().all(|path| path.exists()), "its stores are still there");
        assert!(client.pending_logouts().is_empty(), "its device isn't signed out");
    }

    #[test]
    fn refreshed_tokens_never_overwrite_a_newer_session() {
        let client = client_after_another_sign_in();
        client.save_refreshed_session(&stored("older", "refreshed"));
        assert_eq!(client.load_session().map(|s| s.session.tokens.access_token), Some("new-token".to_owned()));
        client.save_refreshed_session(&stored("newer", "refreshed"));
        assert_eq!(client.load_session().map(|s| s.session.tokens.access_token), Some("refreshed".to_owned()));
    }
}
