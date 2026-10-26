//! Services only the platform can provide, implemented by each app.

/// Where the app keeps secrets: the session's access token and the key that encrypts the local
/// database. On Apple platforms this is the Keychain; Android would use the Keystore, Windows the
/// Credential Manager, Linux the Secret Service.
///
/// Calls are synchronous and quick; they happen when signing in, restoring and signing out.
#[uniffi::export(with_foreign)]
pub trait SecretStore: Send + Sync {
    /// The value saved under `key`, if any.
    fn load(&self, key: String) -> Option<String>;
    /// Saves `value` under `key`, replacing what was there. Returns false if it couldn't.
    fn save(&self, key: String, value: String) -> bool;
    /// Removes `key`. Removing something that isn't there is fine.
    fn delete(&self, key: String);
}

/// Where Xenia keeps its files, and how this device introduces itself.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ClientConfig {
    /// A folder for databases that must survive (the session's state and encryption keys).
    pub data_dir: String,
    /// A folder the system may clear (media cache).
    pub cache_dir: String,
    /// Shown in the account's device list, like "Xenia on iPhone".
    pub device_name: String,
    /// The HTTP user agent, like "Xenia/1.0 (iOS 27.0)".
    pub user_agent: String,
    /// The server the sign-in screen starts with, like "matrix.org".
    pub default_server: String,
}
