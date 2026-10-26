//! Sessions and verification: the account's signed-in devices, and comparing emoji with another
//! device (or person) so each trusts the other's encryption keys.

use std::{
    pin::Pin,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
};

use futures_util::{Stream, StreamExt};
use matrix_sdk::{
    Client,
    encryption::CrossSigningResetAuthType,
    encryption::verification::{
        CancelInfo, SasState, SasVerification, Verification as SdkVerification, VerificationRequest,
        VerificationRequestState,
    },
    ruma::{
        OwnedDeviceId, UserId,
        api::client::uiaa::{AuthData, MatrixUserIdentifier, Password, UserIdentifier},
        events::{
            key::verification::{VerificationMethod, cancel::CancelCode, request::ToDeviceKeyVerificationRequestEvent},
            room::message::{MessageType, OriginalSyncRoomMessageEvent},
        },
    },
};
use tracing::warn;

use crate::{
    client::{ClientListener, XeniaClient},
    error::{XeniaError, Result},
    runtime::{TaskGuard, run},
    sync::MutexExt,
};

// MARK: Records

/// One of the account's signed-in devices.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Session {
    pub device_id: String,
    /// What the device calls itself, like "Xenia on iPhone".
    pub name: Option<String>,
    pub last_seen_ms: Option<i64>,
    pub last_seen_ip: Option<String>,
    /// This device.
    pub is_current: bool,
    /// Cross-signed: its messages are trusted by my other devices.
    pub is_verified: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SasEmoji {
    pub symbol: String,
    /// The emoji's name in English, from the Matrix spec's list; apps may translate it.
    pub description: String,
}

/// Why a verification ended without trust.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum VerificationEnd {
    /// The other side declined or cancelled.
    Declined,
    /// I cancelled.
    CancelledHere,
    /// The emoji didn't match on one side.
    Mismatch,
    /// No answer in time.
    TimedOut,
    /// Another of my devices answered first.
    AnsweredElsewhere,
    /// Both sides asked at the same time, so both requests stopped.
    Crossed,
    Other,
}

/// Where a verification stands.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum VerificationState {
    /// Sent; waiting for the other device to accept.
    Requested,
    /// Someone asked to verify with this device: accept or decline.
    Incoming,
    /// Both sides agreed; the emoji are being worked out.
    Starting,
    /// Compare these with the other screen.
    Compare {
        emojis: Vec<SasEmoji>,
        decimals: Vec<u16>,
    },
    /// I said they match; waiting for the other side to say so too.
    Confirmed,
    Done,
    Ended {
        reason: VerificationEnd,
    },
}

/// Who a verification is with.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct VerificationPeer {
    pub flow_id: String,
    pub user_id: String,
    /// The other device's name, when it's known.
    pub device_name: Option<String>,
    pub device_id: Option<String>,
    /// One of my own devices.
    pub is_self: bool,
}

/// How much a person's encryption is trusted, for their Details.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PersonTrust {
    Verified,
    NotVerified,
    /// Their keys changed since I verified them.
    ChangedSinceVerified,
    /// No encryption identity known (they've never used encryption, or it's not loaded yet).
    Unknown,
}

#[uniffi::export(with_foreign)]
pub trait VerificationListener: Send + Sync {
    fn on_state(&self, state: VerificationState);
}

// MARK: Rules

pub(crate) fn end_reason(info: &CancelInfo, cancelled_here: bool) -> VerificationEnd {
    end_reason_for(info.cancel_code(), info.cancelled_by_us(), cancelled_here)
}

/// `cancelled_here`: the app asked to cancel. The SDK also cancels in my name when a request
/// arrives from someone I'm already verifying with (both stop), which nobody here asked for.
pub(crate) fn end_reason_for(code: &CancelCode, by_us: bool, cancelled_here: bool) -> VerificationEnd {
    match code {
        CancelCode::User if by_us && cancelled_here => VerificationEnd::CancelledHere,
        CancelCode::User if by_us => VerificationEnd::Crossed,
        CancelCode::User => VerificationEnd::Declined,
        CancelCode::MismatchedSas | CancelCode::KeyMismatch | CancelCode::MismatchedCommitment => {
            VerificationEnd::Mismatch
        }
        CancelCode::Timeout => VerificationEnd::TimedOut,
        CancelCode::Accepted => VerificationEnd::AnsweredElsewhere,
        _ => VerificationEnd::Other,
    }
}

fn sas_state(state: SasState, cancelled_here: bool) -> Option<VerificationState> {
    match state {
        SasState::Created { .. } | SasState::Started { .. } | SasState::Accepted { .. } => {
            Some(VerificationState::Starting)
        }
        SasState::KeysExchanged { emojis, decimals } => Some(VerificationState::Compare {
            emojis: emojis
                .map(|e| {
                    e.emojis
                        .iter()
                        .map(|e| SasEmoji { symbol: e.symbol.to_owned(), description: e.description.to_owned() })
                        .collect()
                })
                .unwrap_or_default(),
            decimals: vec![decimals.0, decimals.1, decimals.2],
        }),
        SasState::Confirmed => Some(VerificationState::Confirmed),
        SasState::Done { .. } => Some(VerificationState::Done),
        SasState::Cancelled(info) => Some(VerificationState::Ended { reason: end_reason(&info, cancelled_here) }),
    }
}

fn is_final(state: &VerificationState) -> bool {
    matches!(state, VerificationState::Done | VerificationState::Ended { .. })
}

// MARK: Verification

type SasStream = Pin<Box<dyn Stream<Item = SasState> + Send>>;

/// One verification, from request to done. Dropping it stops following; it doesn't cancel.
#[derive(uniffi::Object)]
pub struct Verification {
    request: VerificationRequest,
    sas: Arc<Mutex<Option<SasVerification>>>,
    peer: VerificationPeer,
    cancelled_here: Arc<AtomicBool>,
    _task: TaskGuard,
}

impl Verification {
    fn new(request: VerificationRequest, listener: Arc<dyn VerificationListener>) -> Arc<Self> {
        let sas: Arc<Mutex<Option<SasVerification>>> = Arc::default();
        let cancelled_here = Arc::new(AtomicBool::new(false));
        let peer = peer_of(&request);
        let task = TaskGuard::spawn(drive(request.clone(), Arc::clone(&sas), Arc::clone(&cancelled_here), listener));
        Arc::new(Self { request, sas, peer, cancelled_here, _task: task })
    }

    fn current_sas(&self) -> Option<SasVerification> {
        self.sas.locked().clone()
    }
}

fn peer_of(request: &VerificationRequest) -> VerificationPeer {
    let device = match request.state() {
        VerificationRequestState::Requested { other_device_data, .. }
        | VerificationRequestState::Ready { other_device_data, .. } => Some(other_device_data),
        _ => None,
    };
    VerificationPeer {
        flow_id: request.flow_id().to_owned(),
        user_id: request.other_user_id().to_string(),
        device_name: device.as_ref().and_then(|d| d.display_name().map(str::to_owned)),
        device_id: device.as_ref().map(|d| d.device_id().to_string()),
        is_self: request.is_self_verification(),
    }
}

/// Follows the request, starts or accepts the emoji comparison when it's time, and reports
/// every step.
async fn drive(
    request: VerificationRequest,
    slot: Arc<Mutex<Option<SasVerification>>>,
    cancelled_here: Arc<AtomicBool>,
    listener: Arc<dyn VerificationListener>,
) {
    let mut requests = request.changes();
    let mut sas_changes: Option<SasStream> = None;

    let here = || cancelled_here.load(Ordering::Relaxed);

    // Reports a state; returns true when the flow is over.
    let report = |state: VerificationState| {
        let done = is_final(&state);
        listener.on_state(state);
        done
    };

    // Adopts an emoji comparison, once, and returns its stream.
    let adopt = |sas: SasVerification| -> Option<(SasVerification, SasStream)> {
        let mut current = slot.locked();
        if current.is_some() {
            return None;
        }
        *current = Some(sas.clone());
        let stream: SasStream = Box::pin(sas.changes());
        Some((sas, stream))
    };

    let mut state = request.state();
    loop {
        match state {
            VerificationRequestState::Created { .. } => {
                report(VerificationState::Requested);
            }
            VerificationRequestState::Requested { .. } => {
                report(VerificationState::Incoming);
            }
            VerificationRequestState::Ready { .. } => {
                report(VerificationState::Starting);
                // The side that asked starts the comparison once the other accepts.
                if request.we_started() {
                    match request.start_sas().await {
                        Ok(Some(sas)) => {
                            if let Some((sas, stream)) = adopt(sas) {
                                sas_changes = Some(stream);
                                if let Some(s) = sas_state(sas.state(), here())
                                    && report(s)
                                {
                                    return;
                                }
                            }
                        }
                        Ok(None) => {}
                        Err(error) => warn!("Starting emoji verification failed: {error}"),
                    }
                }
            }
            VerificationRequestState::Transitioned { verification } => {
                if let SdkVerification::SasV1(sas) = verification
                    && let Some((sas, stream)) = adopt(sas)
                {
                    if !sas.we_started()
                        && let Err(error) = sas.accept().await
                    {
                        warn!("Accepting emoji verification failed: {error}");
                    }
                    sas_changes = Some(stream);
                    if let Some(s) = sas_state(sas.state(), here())
                        && report(s)
                    {
                        return;
                    }
                }
            }
            VerificationRequestState::Done => {
                report(VerificationState::Done);
                return;
            }
            VerificationRequestState::Cancelled(info) => {
                report(VerificationState::Ended { reason: end_reason(&info, here()) });
                return;
            }
        }

        // Wait for the next change from either the request or the comparison.
        loop {
            tokio::select! {
                next = requests.next() => match next {
                    Some(next) => { state = next; break; }
                    None => return,
                },
                next = async {
                    match sas_changes.as_mut() {
                        Some(stream) => stream.next().await,
                        None => std::future::pending().await,
                    }
                } => match next {
                    Some(next) => {
                        if let Some(s) = sas_state(next, here()) && report(s) {
                            return;
                        }
                    }
                    None => sas_changes = None,
                },
            }
        }
    }
}

#[uniffi::export]
impl Verification {
    pub fn peer(&self) -> VerificationPeer {
        self.peer.clone()
    }

    /// Accepts an incoming request (emoji only; Xenia has no camera flow).
    pub async fn accept(&self) -> Result<()> {
        let request = self.request.clone();
        run(async move {
            request.accept_with_methods(vec![VerificationMethod::SasV1]).await.map_err(XeniaError::generic)
        })
        .await
    }

    /// The emoji match.
    pub async fn confirm(&self) -> Result<()> {
        let sas = self.current_sas().ok_or(XeniaError::NotFound)?;
        run(async move { sas.confirm().await.map_err(XeniaError::generic) }).await
    }

    /// The emoji don't match: both sides stop, and nothing is trusted.
    pub async fn mismatch(&self) -> Result<()> {
        let sas = self.current_sas().ok_or(XeniaError::NotFound)?;
        run(async move { sas.mismatch().await.map_err(XeniaError::generic) }).await
    }

    /// Cancels (or declines) at any step.
    pub async fn cancel(&self) {
        self.cancelled_here.store(true, Ordering::Relaxed);
        let sas = self.current_sas();
        let request = self.request.clone();
        run(async move {
            let result = match sas {
                Some(sas) => sas.cancel().await,
                None => request.cancel().await,
            };
            if let Err(error) = result {
                warn!("Cancelling verification failed: {error}");
            }
        })
        .await
    }
}

// MARK: Incoming requests

/// Tells the app when another device or person asks to verify with this one.
pub(crate) fn watch_verification_requests(client: &Client, listener: Arc<dyn ClientListener>) {
    let to_device = Arc::clone(&listener);
    client.add_event_handler(move |event: ToDeviceKeyVerificationRequestEvent, client: Client| {
        let listener = Arc::clone(&to_device);
        async move {
            announce(&client, &event.sender, event.content.transaction_id.as_str(), listener).await;
        }
    });
    client.add_event_handler(move |event: OriginalSyncRoomMessageEvent, client: Client| {
        let listener = Arc::clone(&listener);
        async move {
            if let MessageType::VerificationRequest(_) = &event.content.msgtype {
                announce(&client, &event.sender, event.event_id.as_str(), listener).await;
            }
        }
    });
}

async fn announce(client: &Client, sender: &UserId, flow_id: &str, listener: Arc<dyn ClientListener>) {
    let Some(request) = client.encryption().get_verification_request(sender, flow_id).await else { return };
    // Requests I sent, and ones already over, aren't news.
    if request.we_started() || request.is_done() || request.is_cancelled() || request.is_passive() {
        return;
    }
    listener.on_verification_request(peer_of(&request));
}

// MARK: Client

#[uniffi::export]
impl XeniaClient {
    /// The account's signed-in devices, this one first, then most recently used.
    pub async fn sessions(&self) -> Result<Vec<Session>> {
        let core = self.core().await?;
        run(async move {
            let client = core.client.clone();
            let response = client.devices().await?;
            let me = client.user_id().ok_or(XeniaError::NotSignedIn)?.to_owned();
            let current = client.device_id().map(|d| d.to_owned());
            let mut sessions = Vec::with_capacity(response.devices.len());
            for device in response.devices {
                let is_verified = client
                    .encryption()
                    .get_device(&me, &device.device_id)
                    .await
                    .ok()
                    .flatten()
                    .is_some_and(|d| d.is_verified_with_cross_signing());
                sessions.push(Session {
                    is_current: current.as_ref() == Some(&device.device_id),
                    device_id: device.device_id.to_string(),
                    name: device.display_name.filter(|n| !n.trim().is_empty()),
                    last_seen_ms: device.last_seen_ts.map(|t| i64::from(t.get())),
                    last_seen_ip: device.last_seen_ip,
                    is_verified,
                });
            }
            sort_sessions(&mut sessions);
            Ok(sessions)
        })
        .await
    }

    /// Asks my other devices to verify this one. Any of them can answer.
    pub async fn verify_this_device(&self, listener: Arc<dyn VerificationListener>) -> Result<Arc<Verification>> {
        let core = self.core().await?;
        run(async move {
            let client = &core.client;
            let me = client.user_id().ok_or(XeniaError::NotSignedIn)?;
            let identity = client
                .encryption()
                .get_user_identity(me)
                .await
                .map_err(XeniaError::generic)?
                .ok_or(XeniaError::NotFound)?;
            let request = identity
                .request_verification_with_methods(vec![VerificationMethod::SasV1])
                .await
                .map_err(XeniaError::generic)?;
            Ok(Verification::new(request, listener))
        })
        .await
    }

    /// Asks one of my other devices to verify with this one.
    pub async fn verify_session(
        &self,
        device_id: String,
        listener: Arc<dyn VerificationListener>,
    ) -> Result<Arc<Verification>> {
        let core = self.core().await?;
        run(async move {
            let client = &core.client;
            let me = client.user_id().ok_or(XeniaError::NotSignedIn)?;
            let device_id: OwnedDeviceId = device_id.into();
            let device = client
                .encryption()
                .get_device(me, &device_id)
                .await
                .map_err(XeniaError::generic)?
                .ok_or(XeniaError::NotFound)?;
            let request = device
                .request_verification_with_methods(vec![VerificationMethod::SasV1])
                .await
                .map_err(XeniaError::generic)?;
            Ok(Verification::new(request, listener))
        })
        .await
    }

    /// Asks someone else to compare emoji, through our chat.
    pub async fn verify_person(
        &self,
        user_id: String,
        listener: Arc<dyn VerificationListener>,
    ) -> Result<Arc<Verification>> {
        let core = self.core().await?;
        run(async move {
            let user = UserId::parse(&user_id)?;
            let identity = core
                .client
                .encryption()
                .request_user_identity(&user)
                .await
                .map_err(XeniaError::generic)?
                .ok_or(XeniaError::NotFound)?;
            let request = identity
                .request_verification_with_methods(vec![VerificationMethod::SasV1])
                .await
                .map_err(XeniaError::generic)?;
            Ok(Verification::new(request, listener))
        })
        .await
    }

    /// Picks up a request someone sent (from `on_verification_request`).
    pub async fn incoming_verification(
        &self,
        user_id: String,
        flow_id: String,
        listener: Arc<dyn VerificationListener>,
    ) -> Result<Arc<Verification>> {
        let core = self.core().await?;
        run(async move {
            let user = UserId::parse(&user_id)?;
            let request =
                core.client.encryption().get_verification_request(&user, &flow_id).await.ok_or(XeniaError::NotFound)?;
            Ok(Verification::new(request, listener))
        })
        .await
    }

    /// Whether I've verified someone.
    pub async fn person_trust(&self, user_id: String) -> PersonTrust {
        let Ok(core) = self.core().await else { return PersonTrust::Unknown };
        run(async move {
            let Ok(user) = UserId::parse(&user_id) else { return PersonTrust::Unknown };
            match core.client.encryption().get_user_identity(&user).await {
                Ok(Some(identity)) if identity.is_verified() => PersonTrust::Verified,
                Ok(Some(identity)) if identity.has_verification_violation() => PersonTrust::ChangedSinceVerified,
                Ok(Some(_)) => PersonTrust::NotVerified,
                _ => PersonTrust::Unknown,
            }
        })
        .await
    }

    pub async fn rename_session(&self, device_id: String, name: String) -> Result<()> {
        let core = self.core().await?;
        run(async move {
            let device_id: OwnedDeviceId = device_id.into();
            core.client.rename_device(&device_id, name.trim()).await?;
            Ok(())
        })
        .await
    }

    /// Signs other devices out. Servers ask for the account password first:
    /// `PasswordRequired` means call again with it.
    pub async fn sign_out_sessions(&self, device_ids: Vec<String>, password: Option<String>) -> Result<()> {
        let core = self.core().await?;
        run(async move {
            let client = &core.client;
            let devices: Vec<OwnedDeviceId> = device_ids.into_iter().map(OwnedDeviceId::from).collect();
            if devices.is_empty() {
                return Ok(());
            }
            let Err(error) = client.delete_devices(&devices, None).await else { return Ok(()) };
            let Some(info) = error.as_uiaa_response() else { return Err(XeniaError::from_http(&error)) };
            let auth = password_auth(client, password, info.session.clone())?;
            client.delete_devices(&devices, Some(auth)).await.map_err(|error| {
                if error.as_uiaa_response().is_some() {
                    XeniaError::InvalidCredentials
                } else {
                    XeniaError::from_http(&error)
                }
            })?;
            Ok(())
        })
        .await
    }

    /// Checks the account password with the server, changing nothing (it asks to sign out no
    /// devices, which needs the password). For keeping the password where other devices sign in
    /// with it. A server that doesn't ask for it there can't check it, and it passes.
    pub async fn check_password(&self, password: String) -> Result<()> {
        let core = self.core().await?;
        run(async move {
            let client = &core.client;
            let Err(error) = client.delete_devices(&[], None).await else { return Ok(()) };
            let Some(info) = error.as_uiaa_response() else { return Err(XeniaError::from_http(&error)) };
            // An account that signs in through a web page has no password to check.
            let takes_password = info
                .flows
                .iter()
                .any(|flow| flow.stages.first() == Some(&matrix_sdk::ruma::api::client::uiaa::AuthType::Password));
            if !takes_password {
                return Err(XeniaError::PasswordLoginUnsupported);
            }
            let auth = password_auth(client, Some(password), info.session.clone())?;
            client.delete_devices(&[], Some(auth)).await.map_err(|error| {
                if error.as_uiaa_response().is_some() {
                    XeniaError::InvalidCredentials
                } else {
                    XeniaError::from_http(&error)
                }
            })?;
            Ok(())
        })
        .await
    }

    /// Starts encryption over when no other device or recovery key can verify this one: new keys
    /// that make this device the verified one, and a new recovery key (returned, to show once).
    /// Other devices need verifying again, and messages only the old backup held stay unreadable.
    pub async fn reset_encryption_identity(&self, password: String) -> Result<String> {
        let core = self.core().await?;
        run(async move {
            let client = &core.client;
            let recovery = client.encryption().recovery();
            if let Some(handle) = recovery.reset_identity().await.map_err(XeniaError::generic)? {
                let session = match handle.auth_type() {
                    CrossSigningResetAuthType::Uiaa(info) => info.session.clone(),
                    CrossSigningResetAuthType::OAuth(_) => return Err(XeniaError::PasswordLoginUnsupported),
                };
                let auth = password_auth(client, Some(password), session)?;
                handle.reset(Some(auth)).await.map_err(|error| {
                    let text = error.to_string().to_lowercase();
                    if text.contains("password") || text.contains("forbidden") || text.contains("uiaa") {
                        XeniaError::InvalidCredentials
                    } else {
                        XeniaError::generic(error)
                    }
                })?;
            }
            recovery.enable().await.map_err(XeniaError::generic)
        })
        .await
    }
}

fn password_auth(client: &Client, password: Option<String>, session: Option<String>) -> Result<AuthData> {
    let Some(password) = password.filter(|p| !p.is_empty()) else { return Err(XeniaError::PasswordRequired) };
    let me = client.user_id().ok_or(XeniaError::NotSignedIn)?;
    let mut auth =
        Password::new(UserIdentifier::Matrix(MatrixUserIdentifier::new(me.localpart().to_owned())), password);
    auth.session = session;
    Ok(AuthData::Password(auth))
}

/// This device first, then the most recently seen.
pub(crate) fn sort_sessions(sessions: &mut [Session]) {
    sessions.sort_by(|a, b| b.is_current.cmp(&a.is_current).then(b.last_seen_ms.cmp(&a.last_seen_ms)));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(id: &str, current: bool, seen: Option<i64>) -> Session {
        Session {
            device_id: id.to_owned(),
            name: None,
            last_seen_ms: seen,
            last_seen_ip: None,
            is_current: current,
            is_verified: false,
        }
    }

    #[test]
    fn this_device_comes_first_then_most_recent() {
        let mut sessions = vec![
            session("OLD", false, Some(10)),
            session("NEVER", false, None),
            session("ME", true, Some(5)),
            session("NEW", false, Some(90)),
        ];
        sort_sessions(&mut sessions);
        let ids: Vec<&str> = sessions.iter().map(|s| s.device_id.as_str()).collect();
        assert_eq!(ids, ["ME", "NEW", "OLD", "NEVER"]);
    }

    #[test]
    fn cancellations_say_who_and_why() {
        assert_eq!(end_reason_for(&CancelCode::User, true, true), VerificationEnd::CancelledHere);
        // The SDK stopped both crossed requests in my name; nobody here cancelled.
        assert_eq!(end_reason_for(&CancelCode::User, true, false), VerificationEnd::Crossed);
        assert_eq!(end_reason_for(&CancelCode::User, false, false), VerificationEnd::Declined);
        assert_eq!(end_reason_for(&CancelCode::User, false, true), VerificationEnd::Declined);
        assert_eq!(end_reason_for(&CancelCode::MismatchedSas, false, false), VerificationEnd::Mismatch);
        assert_eq!(end_reason_for(&CancelCode::KeyMismatch, true, false), VerificationEnd::Mismatch);
        assert_eq!(end_reason_for(&CancelCode::Timeout, false, false), VerificationEnd::TimedOut);
        assert_eq!(end_reason_for(&CancelCode::Accepted, false, false), VerificationEnd::AnsweredElsewhere);
        assert_eq!(end_reason_for(&CancelCode::UnknownMethod, false, false), VerificationEnd::Other);
    }
}
