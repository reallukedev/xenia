//! Who has read one of my messages, and who hasn't yet, for the message's Read Receipts.

use std::collections::{HashMap, HashSet};

use super::Reader;

/// Someone who has read the message, and when, if their receipt says.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ReadReceipt {
    pub reader: Reader,
    pub timestamp_ms: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ReadReceipts {
    /// Most recent first.
    pub read: Vec<ReadReceipt>,
    /// Everyone else in the room, by name. Includes people who keep their receipts private.
    pub unread: Vec<Reader>,
}

/// Where each person has read up to: the timeline position of their newest receipt (or their
/// own message after it) and its time.
pub(crate) type ReadMarks = HashMap<String, (usize, Option<i64>)>;

/// Splits the room into who has read the message at `target` and who hasn't. Neither I nor
/// the sender count; `members` names everyone still in the room.
pub(crate) fn split(target: usize, marks: &ReadMarks, members: &[Reader], sender: &str, me: &str) -> ReadReceipts {
    let by_id: HashMap<&str, &Reader> = members.iter().map(|m| (m.user_id.as_str(), m)).collect();
    let mut read: Vec<ReadReceipt> = marks
        .iter()
        .filter(|(user, (at, _))| *at >= target && user.as_str() != me && user.as_str() != sender)
        .map(|(user, (_, ts))| ReadReceipt {
            reader: by_id.get(user.as_str()).map(|r| (*r).clone()).unwrap_or_else(|| Reader {
                user_id: user.clone(),
                name: user.clone(),
                avatar_url: None,
            }),
            timestamp_ms: *ts,
        })
        .collect();
    read.sort_by(|a, b| {
        b.timestamp_ms
            .cmp(&a.timestamp_ms)
            .then_with(|| a.reader.name.to_lowercase().cmp(&b.reader.name.to_lowercase()))
    });
    let has_read: HashSet<&str> = read.iter().map(|r| r.reader.user_id.as_str()).collect();
    let mut unread: Vec<Reader> = members
        .iter()
        .filter(|m| m.user_id != me && m.user_id != sender && !has_read.contains(m.user_id.as_str()))
        .cloned()
        .collect();
    unread.sort_by_cached_key(|m| (m.name.to_lowercase(), m.user_id.clone()));
    ReadReceipts { read, unread }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn person(id: &str) -> Reader {
        Reader { user_id: id.into(), name: id.to_uppercase(), avatar_url: None }
    }

    #[test]
    fn splits_the_room_at_the_message() {
        let members = ["me", "maya", "sam", "alex", "priya"].map(person);
        // The message is at 5. Maya read it at 6, Sam exactly at 5, Alex stopped at 4, Priya
        // never sent a receipt; Pat left after reading.
        let marks: ReadMarks = [
            ("maya", (6, Some(2_000))),
            ("sam", (5, Some(3_000))),
            ("alex", (4, Some(1_000))),
            ("pat", (9, None)),
            ("me", (9, Some(4_000))),
        ]
        .into_iter()
        .map(|(u, m)| (u.to_string(), m))
        .collect();
        let lists = split(5, &marks, &members, "me", "me");
        let read: Vec<_> = lists.read.iter().map(|r| r.reader.user_id.as_str()).collect();
        assert_eq!(read, ["sam", "maya", "pat"], "most recent first, unknown times last");
        assert_eq!(lists.read[2].reader.name, "pat", "someone who left keeps their ID as a name");
        let unread: Vec<_> = lists.unread.iter().map(|r| r.user_id.as_str()).collect();
        assert_eq!(unread, ["alex", "priya"]);
    }

    #[test]
    fn the_sender_is_on_neither_side() {
        let members = ["me", "maya", "sam"].map(person);
        let marks: ReadMarks = [("maya".to_string(), (3, Some(1)))].into();
        let lists = split(3, &marks, &members, "maya", "me");
        assert!(lists.read.is_empty());
        assert_eq!(lists.unread.iter().map(|r| r.user_id.as_str()).collect::<Vec<_>>(), ["sam"]);
    }
}
