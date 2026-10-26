//! The saved session and where its stores live.

use std::path::{Path, PathBuf};

use matrix_sdk::cross_process_lock::CrossProcessLockConfig;
use matrix_sdk::{
    Client, ThreadingSupport,
    authentication::matrix::MatrixSession,
    encryption::{BackupDownloadStrategy, EncryptionSettings},
    search_index::SearchIndexStoreKind,
    sliding_sync::VersionBuilder,
};
use serde::{Deserialize, Serialize};

use crate::{error::Result, platform::ClientConfig};

/// The key the session is saved under in the app's secret store.
pub(crate) const SESSION_KEY: &str = "xenia.session.v1";

/// Everything needed to come back signed in, kept in the secret store.
#[derive(Serialize, Deserialize, Clone)]
pub(crate) struct StoredSession {
    pub session: MatrixSession,
    pub homeserver_url: String,
    /// The folder, under the data and cache directories, holding this account's stores.
    pub folder: String,
    /// Encrypts the stores and the search index at rest.
    pub passphrase: String,
}

impl std::fmt::Debug for StoredSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("StoredSession").field("folder", &self.folder).finish_non_exhaustive()
    }
}

pub(crate) struct StorePaths {
    pub data: PathBuf,
    pub cache: PathBuf,
    pub search: PathBuf,
}

pub(crate) fn store_paths(config: &ClientConfig, folder: &str) -> StorePaths {
    let data = Path::new(&config.data_dir).join("sessions").join(folder);
    let cache = Path::new(&config.cache_dir).join("sessions").join(folder);
    StorePaths { search: data.join("search"), data, cache }
}

/// Removes an account's stores. Missing folders are fine.
pub(crate) async fn remove_stores(config: &ClientConfig, folder: &str) {
    let paths = store_paths(config, folder);
    for dir in [paths.data, paths.cache] {
        if let Err(error) = tokio::fs::remove_dir_all(&dir).await
            && error.kind() != std::io::ErrorKind::NotFound
        {
            tracing::warn!("Couldn't remove {}: {error}", dir.display());
        }
    }
}

/// Which process opens the stores. The app and its notification extensions share them, each
/// holding the cross-process lock under its own name.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Process {
    App,
    /// Decrypts pushes into notifications.
    NotificationExtension,
    /// Shows a notification's conversation and sends replies from it.
    NotificationContent,
}

impl Process {
    pub(crate) fn lock_holder(self) -> &'static str {
        match self {
            Process::App => "main",
            Process::NotificationExtension => "nse",
            Process::NotificationContent => "nce",
        }
    }
}

/// How a client finds its server.
pub(crate) enum Server<'a> {
    /// What someone typed: "matrix.org", "https://matrix.example.org", "localhost:8008".
    Typed(&'a str),
    /// The homeserver URL a saved session used.
    Url(&'a str),
}

/// A client with Xenia's settings: SQLite stores, a local encrypted search index, threads,
/// simplified sliding sync, and cross-signing and backups turned on for new accounts.
pub(crate) async fn build_client(
    config: &ClientConfig,
    server: Server<'_>,
    folder: &str,
    passphrase: &str,
    process: Process,
) -> Result<Client> {
    let paths = store_paths(config, folder);
    for dir in [&paths.data, &paths.cache, &paths.search] {
        tokio::fs::create_dir_all(dir).await?;
    }
    let builder = Client::builder();
    // Signing in discovers sliding sync from the server. Restoring doesn't ask the network at
    // all (support was confirmed at sign-in), so Xenia opens offline too.
    let (builder, sliding_sync) = match server {
        Server::Typed(typed) => {
            (builder.server_name_or_homeserver_url(normalize_server(typed)), VersionBuilder::DiscoverNative)
        }
        Server::Url(url) => (builder.homeserver_url(url), VersionBuilder::Native),
    };
    // The search index is a folder only one process can hold; the extensions don't search.
    let search = match process {
        Process::App => SearchIndexStoreKind::EncryptedDirectory(paths.search.clone(), passphrase.to_owned()),
        Process::NotificationExtension | Process::NotificationContent => SearchIndexStoreKind::InMemory,
    };
    let client = builder
        .sqlite_store_with_cache_path(&paths.data, &paths.cache, Some(passphrase))
        .cross_process_store_config(CrossProcessLockConfig::multi_process(process.lock_holder()))
        .search_index_store(search)
        // Thread replies stay out of the main timeline and live in their own.
        .with_threading_support(ThreadingSupport::Enabled { with_subscriptions: false })
        .sliding_sync_version_builder(sliding_sync)
        .with_encryption_settings(EncryptionSettings {
            // The extension only reads: setting up cross-signing or backups is the app's job, and
            // doing it there would cost memory and write keys behind the app's back.
            auto_enable_cross_signing: process == Process::App,
            // Fetch a missing room key from the backup as soon as a message can't be decrypted.
            backup_download_strategy: BackupDownloadStrategy::AfterDecryptionFailure,
            auto_enable_backups: process == Process::App,
        })
        .handle_refresh_tokens()
        .user_agent(&config.user_agent)
        .build()
        .await?;
    require_secure(&client.homeserver())?;
    Ok(client)
}

/// Passwords and access tokens only travel over https, or plain http to a server on this
/// machine or the local network (a test server, or one at home without a certificate). The
/// address someone types, a server's `.well-known` and a saved session's URL are all checked,
/// since any of them could point at http.
pub(crate) fn require_secure(url: &url::Url) -> Result<()> {
    let is_local = match url.host() {
        Some(url::Host::Domain(domain)) => {
            let domain = domain.trim_end_matches('.').to_ascii_lowercase();
            domain == "localhost" || domain.ends_with(".localhost") || domain.ends_with(".local")
        }
        Some(url::Host::Ipv4(ip)) => ip.is_loopback() || ip.is_private() || ip.is_link_local(),
        Some(url::Host::Ipv6(ip)) => ip.is_loopback() || ip.is_unique_local() || ip.is_unicast_link_local(),
        None => false,
    };
    if url.scheme() == "https" || (url.scheme() == "http" && is_local) {
        Ok(())
    } else {
        Err(crate::error::XeniaError::InsecureServer)
    }
}

/// The crypto store's cross-process lock, once the client has a session: the app and the
/// extension must never write keys at the same time. The extension refuses to go on without it;
/// the app carries on (it's the only writer when no extension runs).
pub(crate) async fn lock_crypto_store(client: &Client, process: Process) -> Result<()> {
    match client.encryption().enable_cross_process_store_lock(process.lock_holder().to_owned()).await {
        Ok(()) => Ok(()),
        Err(error) if process == Process::App => {
            tracing::warn!("Couldn't enable the crypto store lock: {error}");
            Ok(())
        }
        Err(error) => Err(crate::error::XeniaError::generic(error)),
    }
}

/// "https://matrix.org/" and " matrix.org " are the same server; "localhost:8008" gets http,
/// since a server on this machine rarely has a certificate.
pub(crate) fn normalize_server(typed: &str) -> String {
    let trimmed = typed.trim().trim_end_matches('/');
    // The host exactly, with or without a port: "localhost.example.com" is somewhere else.
    let host = if trimmed.starts_with('[') {
        trimmed.split_inclusive(']').next().unwrap_or(trimmed)
    } else {
        trimmed.split(':').next().unwrap_or(trimmed)
    };
    let is_local = matches!(host, "localhost" | "127.0.0.1" | "[::1]");
    if is_local && !trimmed.contains("://") { format!("http://{trimmed}") } else { trimmed.to_owned() }
}

/// A random passphrase for the stores: two random UUIDs as 64 hex digits (244 random bits).
pub(crate) fn new_passphrase() -> String {
    let a = uuid::Uuid::new_v4();
    let b = uuid::Uuid::new_v4();
    format!("{}{}", a.simple(), b.simple())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn servers_are_normalized() {
        assert_eq!(normalize_server(" matrix.org/ "), "matrix.org");
        assert_eq!(normalize_server("localhost:8008"), "http://localhost:8008");
        assert_eq!(normalize_server("[::1]:8008"), "http://[::1]:8008");
        assert_eq!(normalize_server("localhost.example.com"), "localhost.example.com");
        assert_eq!(normalize_server("127.0.0.1.nip.io"), "127.0.0.1.nip.io");
        assert_eq!(normalize_server("https://m.example.org/"), "https://m.example.org");
    }

    #[test]
    fn only_https_or_the_local_network() {
        let check = |url: &str| require_secure(&url::Url::parse(url).unwrap()).is_ok();
        assert!(check("https://matrix.org/"));
        assert!(check("http://localhost:8008/"));
        assert!(check("http://127.0.0.1:8008/"));
        assert!(check("http://[::1]:8008/"));
        assert!(check("http://Mac-And-Cheese.local:8008/"));
        assert!(check("http://192.168.1.20:8008/"));
        assert!(check("http://10.0.0.2:8008/"));
        assert!(!check("http://matrix.example.org/"));
        assert!(!check("http://localhost.example.com/"));
        assert!(!check("http://local.example.com/"));
        assert!(!check("http://8.8.8.8:8008/"));
        assert!(!check("ftp://localhost/"));
    }

    #[test]
    fn passphrases_are_long_and_unique() {
        let a = new_passphrase();
        assert_eq!(a.len(), 64);
        assert_ne!(a, new_passphrase());
    }
}
