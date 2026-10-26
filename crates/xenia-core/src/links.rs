//! Matrix links (matrix.to and `matrix:`), so mentions, room links and message links open in
//! the app instead of a web page.

use matrix_sdk::ruma::{MatrixToUri, MatrixUri, matrix_uri::MatrixId};

use crate::{
    client::XeniaClient,
    error::{XeniaError, Result},
    runtime::run,
};

/// Where a Matrix link points.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum MatrixLink {
    User {
        user_id: String,
    },
    /// A room by ID ("!abc:server") or alias ("#room:server"), with servers that can find it.
    Room {
        address: String,
        via: Vec<String>,
    },
    /// One message in a room.
    Message {
        address: String,
        event_id: String,
        via: Vec<String>,
    },
}

/// Reads a matrix.to or `matrix:` link; `None` for any other address.
#[uniffi::export]
pub fn parse_matrix_link(url: String) -> Option<MatrixLink> {
    let url = url.trim();
    let (id, via) = if let Ok(uri) = MatrixToUri::parse(url) {
        (uri.id().clone(), uri.via().iter().map(ToString::to_string).collect())
    } else if let Ok(uri) = MatrixUri::parse(url) {
        (uri.id().clone(), uri.via().iter().map(ToString::to_string).collect())
    } else {
        return None;
    };
    Some(match id {
        MatrixId::User(user) => MatrixLink::User { user_id: user.to_string() },
        MatrixId::Room(room) => MatrixLink::Room { address: room.to_string(), via },
        MatrixId::RoomAlias(alias) => MatrixLink::Room { address: alias.to_string(), via },
        MatrixId::Event(room, event) => {
            MatrixLink::Message { address: room.to_string(), event_id: event.to_string(), via }
        }
        _ => return None,
    })
}

#[uniffi::export]
impl XeniaClient {
    /// The joined room a link's address names (an ID, or an alias any joined room carries), or
    /// `None` when I'm not in it.
    pub async fn joined_room(&self, address: String) -> Result<Option<String>> {
        let core = self.core().await?;
        run(async move {
            let address = address.trim();
            let joined = core.client.joined_rooms();
            if address.starts_with('!') {
                return Ok(joined.iter().find(|r| r.room_id().as_str() == address).map(|r| r.room_id().to_string()));
            }
            let named = |room: &matrix_sdk::Room| {
                room.canonical_alias().is_some_and(|a| a.as_str() == address)
                    || room.alt_aliases().iter().any(|a| a.as_str() == address)
            };
            if let Some(room) = joined.iter().find(|r| named(r)) {
                return Ok(Some(room.room_id().to_string()));
            }
            // The alias may be one the room doesn't advertise: ask its server.
            let Ok(alias) = matrix_sdk::ruma::RoomAliasId::parse(address) else { return Err(XeniaError::NotFound) };
            let Ok(response) = core.client.resolve_room_alias(&alias).await else { return Ok(None) };
            Ok(joined.iter().find(|r| r.room_id() == response.room_id).map(|r| r.room_id().to_string()))
        })
        .await
    }

    /// Joins a room from a link, asking the link's servers when mine doesn't know it. Returns
    /// the room ID.
    pub async fn join_link(&self, address: String, via: Vec<String>) -> Result<String> {
        let core = self.core().await?;
        run(async move {
            let id = matrix_sdk::ruma::RoomOrAliasId::parse(address.trim()).map_err(|_| XeniaError::NotFound)?;
            let mut servers: Vec<_> = via.iter().filter_map(|s| s.as_str().try_into().ok()).collect();
            if let Some(server) = id.server_name()
                && !servers.iter().any(|s: &matrix_sdk::ruma::OwnedServerName| s == server)
            {
                servers.push(server.to_owned());
            }
            let room = core.client.join_room_by_id_or_alias(&id, &servers).await?;
            Ok(room.room_id().to_string())
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_every_kind_of_link() {
        assert_eq!(
            parse_matrix_link("https://matrix.to/#/@maya:example.org".into()),
            Some(MatrixLink::User { user_id: "@maya:example.org".into() })
        );
        assert_eq!(
            parse_matrix_link("https://matrix.to/#/%23design:example.org?via=example.org".into()),
            Some(MatrixLink::Room { address: "#design:example.org".into(), via: vec!["example.org".into()] })
        );
        assert_eq!(
            parse_matrix_link("matrix:roomid/abc:example.org/e/def?via=other.org".into()),
            Some(MatrixLink::Message {
                address: "!abc:example.org".into(),
                event_id: "$def".into(),
                via: vec!["other.org".into()],
            })
        );
        assert_eq!(parse_matrix_link("https://example.org/#/@maya:example.org".into()), None);
        assert_eq!(parse_matrix_link("mailto:maya@example.org".into()), None);
    }
}
