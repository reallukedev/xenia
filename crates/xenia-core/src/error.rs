use matrix_sdk::ruma::api::error::ErrorKind;

/// What went wrong, in terms an app can put into words.
///
/// The SDK's errors are detailed debug structures; the apps need to know which sentence to show
/// and whether trying again could help. Each variant maps to one message in each app's strings.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum XeniaError {
    /// The username or password was wrong.
    #[error("invalid username or password")]
    InvalidCredentials,
    /// The account exists but was deactivated.
    #[error("account deactivated")]
    UserDeactivated,
    /// The server asked us to slow down.
    #[error("rate limited")]
    RateLimited,
    /// The server couldn't be reached at all (DNS, TLS, no route, timeout).
    #[error("server unreachable")]
    ServerUnreachable,
    /// The address answered, but not as a Matrix server.
    #[error("not a Matrix server")]
    NotAMatrixServer,
    /// The server (or where its address leads) doesn't use https, and isn't on this machine:
    /// a password or access token sent there could be read on the way.
    #[error("insecure server")]
    InsecureServer,
    /// The server doesn't offer the sync Xenia needs (simplified sliding sync).
    #[error("sliding sync unsupported")]
    SlidingSyncUnsupported,
    /// The server only allows signing in through a web page (OIDC), which this build can't do.
    #[error("password login unsupported")]
    PasswordLoginUnsupported,
    /// Something needed a signed-in client and there isn't one.
    #[error("not signed in")]
    NotSignedIn,
    /// A room, event or person that isn't known here.
    #[error("not found")]
    NotFound,
    /// The server refused (no permission, not invited, banned).
    #[error("forbidden: {message}")]
    Forbidden { message: String },
    /// The server wants the account password before it does this (signing out another device).
    #[error("password required")]
    PasswordRequired,
    /// The recovery key didn't unlock the backup.
    #[error("invalid recovery key")]
    InvalidRecoveryKey,
    /// Anything else. `message` is for logs, not for people.
    #[error("{message}")]
    Generic { message: String },
}

impl XeniaError {
    pub(crate) fn generic(error: impl std::fmt::Display) -> Self {
        Self::Generic { message: error.to_string() }
    }

    /// Classifies an HTTP-level failure from the SDK.
    pub(crate) fn from_http(error: &matrix_sdk::HttpError) -> Self {
        if let Some(kind) = error.client_api_error_kind() {
            return Self::from_kind(kind, error.to_string());
        }
        Self::from_text(&error.to_string())
    }

    fn from_kind(kind: &ErrorKind, message: String) -> Self {
        match kind {
            ErrorKind::Forbidden if is_login_failure(&message) => Self::InvalidCredentials,
            ErrorKind::Forbidden => Self::Forbidden { message },
            ErrorKind::UserDeactivated => Self::UserDeactivated,
            ErrorKind::LimitExceeded { .. } => Self::RateLimited,
            ErrorKind::NotFound => Self::NotFound,
            ErrorKind::Unrecognized => Self::NotAMatrixServer,
            _ => Self::Generic { message },
        }
    }

    /// The HTTP failure inside a wrapped SDK error (a timeline action, recovery), classified by
    /// what the server said rather than by the wrapper's text.
    pub(crate) fn from_source_chain(error: &(dyn std::error::Error + 'static)) -> Option<Self> {
        let mut current = Some(error);
        while let Some(error) = current {
            if let Some(http) = error.downcast_ref::<matrix_sdk::HttpError>() {
                return Some(Self::from_http(http));
            }
            if let Some(matrix_sdk::Error::Http(http)) = error.downcast_ref::<matrix_sdk::Error>() {
                return Some(Self::from_http(http));
            }
            current = error.source();
        }
        None
    }

    /// Last resort: the SDK's errors are nested enums whose useful part is often only in the
    /// rendered text, so the common cases are recognised by it.
    pub(crate) fn from_text(text: &str) -> Self {
        let lower = text.to_lowercase();
        let has = |needle: &str| lower.contains(needle);
        if has("invalid username or password") || has("invalid password") {
            Self::InvalidCredentials
        } else if has("m_forbidden") {
            // Only signing in says anything about the password; anywhere else it's permission.
            Self::Forbidden { message: text.to_owned() }
        } else if has("m_user_deactivated") {
            Self::UserDeactivated
        } else if has("m_limit_exceeded") {
            Self::RateLimited
        } else if has("sliding sync") || has("slidingsync") {
            Self::SlidingSyncUnsupported
        } else if has("error sending request")
            || has("dns")
            || has("connection refused")
            || has("timed out")
            || has("tcp connect")
            || has("certificate")
        {
            Self::ServerUnreachable
        } else if has("well-known")
            || has("wellknown")
            || has("discovery")
            || has("invalid server name")
            || has("unrecognized")
            || has("expected value")
            // A bare 404 means the address isn't a Matrix server; a Matrix "not found" from one
            // (a missing event) doesn't.
            || (has("404") && !has("m_not_found"))
        {
            Self::NotAMatrixServer
        } else if has("m_not_found") {
            Self::NotFound
        } else {
            Self::Generic { message: text.to_owned() }
        }
    }
}

fn is_login_failure(message: &str) -> bool {
    let m = message.to_lowercase();
    m.contains("password") || m.contains("username") || m.contains("login")
}

impl From<matrix_sdk::Error> for XeniaError {
    fn from(error: matrix_sdk::Error) -> Self {
        Self::from_source_chain(&error).unwrap_or_else(|| Self::from_text(&error.to_string()))
    }
}

impl From<matrix_sdk::HttpError> for XeniaError {
    fn from(error: matrix_sdk::HttpError) -> Self {
        Self::from_http(&error)
    }
}

impl From<matrix_sdk::ClientBuildError> for XeniaError {
    fn from(error: matrix_sdk::ClientBuildError) -> Self {
        Self::from_text(&format!("{error:?} {error}"))
    }
}

impl From<matrix_sdk_ui::timeline::Error> for XeniaError {
    fn from(error: matrix_sdk_ui::timeline::Error) -> Self {
        Self::from_source_chain(&error).unwrap_or_else(|| Self::from_text(&error.to_string()))
    }
}

impl From<matrix_sdk::IdParseError> for XeniaError {
    fn from(_: matrix_sdk::IdParseError) -> Self {
        Self::NotFound
    }
}

impl From<std::io::Error> for XeniaError {
    fn from(error: std::io::Error) -> Self {
        Self::generic(error)
    }
}

pub type Result<T, E = XeniaError> = std::result::Result<T, E>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognises_common_failures_by_text() {
        assert_eq!(XeniaError::from_text("M_FORBIDDEN: Invalid username or password"), XeniaError::InvalidCredentials);
        assert_eq!(XeniaError::from_text("M_LIMIT_EXCEEDED: Too many requests"), XeniaError::RateLimited);
        assert_eq!(
            XeniaError::from_text("error sending request for url (http://nowhere.invalid/): dns error"),
            XeniaError::ServerUnreachable
        );
        assert_eq!(
            XeniaError::from_text("the server doesn't support sliding sync"),
            XeniaError::SlidingSyncUnsupported
        );
        assert!(matches!(XeniaError::from_text("something odd"), XeniaError::Generic { .. }));
        // A refused redaction is about permission, and a missing event isn't a missing server.
        assert!(matches!(
            XeniaError::from_text("[403 / M_FORBIDDEN] You don't have permission to redact events"),
            XeniaError::Forbidden { .. }
        ));
        assert_eq!(XeniaError::from_text("[404 / M_NOT_FOUND] Event not found"), XeniaError::NotFound);
        assert_eq!(
            XeniaError::from_text("AutoDiscovery error: well-known lookup failed [404 / M_NOT_FOUND]"),
            XeniaError::NotAMatrixServer
        );
    }
}
