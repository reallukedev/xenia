//! Chat backup and recovery: where it stands, and turning it on or unlocking it.

use std::sync::Arc;

use futures_util::StreamExt;
use matrix_sdk::{
    Client,
    encryption::{VerificationState, recovery::RecoveryState},
};

use crate::{
    client::{ClientListener, XeniaClient},
    error::{XeniaError, Result},
    runtime::{TaskGuard, run},
};

/// Where chat backup stands on this device.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum BackupStatus {
    /// Still finding out.
    Checking,
    /// Backed up and unlocked here.
    On,
    /// Set up on another device; this one needs the recovery key to read older messages.
    NeedsKey,
    /// Not set up: encrypted messages can't be recovered on a new device.
    Off,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct EncryptionStatus {
    pub backup: BackupStatus,
    /// This device is verified with the account's other devices (cross-signed).
    pub is_device_verified: bool,
}

fn backup_status(state: RecoveryState) -> BackupStatus {
    match state {
        RecoveryState::Unknown => BackupStatus::Checking,
        RecoveryState::Enabled => BackupStatus::On,
        RecoveryState::Incomplete => BackupStatus::NeedsKey,
        RecoveryState::Disabled => BackupStatus::Off,
    }
}

fn status(client: &Client) -> EncryptionStatus {
    let encryption = client.encryption();
    EncryptionStatus {
        backup: backup_status(encryption.recovery().state()),
        is_device_verified: matches!(encryption.verification_state().get(), VerificationState::Verified),
    }
}

/// Reports every change to backup or verification.
pub(crate) fn watch_encryption(client: &Client, listener: Arc<dyn ClientListener>) -> TaskGuard {
    let client = client.clone();
    TaskGuard::spawn(async move {
        let encryption = client.encryption();
        let mut recovery = encryption.recovery().state_stream();
        let mut verification = encryption.verification_state();
        let mut last = None;
        loop {
            let now = status(&client);
            if last != Some(now) {
                last = Some(now);
                listener.on_encryption_changed(now);
            }
            tokio::select! {
                next = recovery.next() => if next.is_none() { break },
                next = verification.next() => if next.is_none() { break },
            }
        }
    })
}

#[uniffi::export]
impl XeniaClient {
    /// Where backup and verification stand right now.
    pub async fn encryption_status(&self) -> Result<EncryptionStatus> {
        let core = self.core().await?;
        Ok(status(&core.client))
    }

    /// Turns on chat backup. Returns the new recovery key, which the person must keep.
    pub async fn enable_backup(&self) -> Result<String> {
        let core = self.core().await?;
        run(async move { core.client.encryption().recovery().enable().await.map_err(XeniaError::generic) }).await
    }

    /// Unlocks backup on this device with the recovery key (spaces and case don't matter).
    pub async fn recover(&self, recovery_key: String) -> Result<()> {
        let core = self.core().await?;
        run(async move {
            let key = recovery_key.trim();
            core.client.encryption().recovery().recover(key).await.map_err(|error| {
                // Offline or a busy server isn't a wrong key. (The SDK's wrappers are transparent,
                // so the request failure shows in the text more reliably than in the chain.)
                if let Some(error) = XeniaError::from_source_chain(&error) {
                    return error;
                }
                let text = error.to_string().to_lowercase();
                let by_text = XeniaError::from_text(&text);
                if matches!(by_text, XeniaError::ServerUnreachable | XeniaError::RateLimited) {
                    return by_text;
                }
                let wrong_key = [
                    "mac check",
                    "invalid mac",
                    "base58",
                    "invalid character",
                    "parity",
                    "invalid prefix",
                    "decod",
                    "does not match",
                ];
                if wrong_key.iter().any(|sign| text.contains(sign)) {
                    XeniaError::InvalidRecoveryKey
                } else {
                    XeniaError::generic(error)
                }
            })
        })
        .await
    }

    /// Replaces the recovery key (the old one stops working). Returns the new key.
    pub async fn reset_recovery_key(&self) -> Result<String> {
        let core = self.core().await?;
        run(async move { core.client.encryption().recovery().reset_key().await.map_err(XeniaError::generic) }).await
    }
}
