//! Messages in one conversation that mention me, newest first, from two places at once. The
//! server's highlights cover unencrypted rooms, including history this device never downloaded;
//! this device's event cache covers encrypted rooms, which the server can't read. A message found
//! in both shows once.

use std::collections::HashSet;

use matrix_sdk::{
    Room,
    deserialized_responses::TimelineEvent,
    ruma::{
        OwnedEventId, OwnedRoomId, UInt,
        api::client::push::get_notifications::v3::Request,
        events::{AnySyncTimelineEvent, room::message::MessageType},
        serde::Raw,
    },
};
use matrix_sdk_ui::timeline::{Profile, TimelineItemContent};
use regex::Regex;
use tracing::warn;

use crate::{
    client::XeniaClient,
    content::{Actor, Body, Summary, html_of, mentions_me, one_line, summarize},
    error::Result,
    runtime::run,
    text::{TextMark, parse_html},
};

/// Highlights asked of the server per page, and how many pages at most: the list is every
/// room's, so a quiet room's mentions can sit behind a busy one's.
const SERVER_PAGE: u32 = 50;
const SERVER_PAGES: usize = 10;
/// The newest cached messages a room's local scan reads, however long its history here.
const LOCAL_SCAN: usize = 2_000;

/// A message that mentions me.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MentionHit {
    pub room_id: String,
    pub event_id: String,
    pub sender_id: String,
    pub sender_name: String,
    pub sender_avatar_url: Option<String>,
    pub body: Body,
    /// The message's words in runs, the mention of me marked. Starts a few words before the
    /// mention when it comes late in a long message.
    pub preview: Vec<TextMark>,
    pub timestamp_ms: i64,
    /// The thread it's in, by the message that started it.
    pub thread_root_id: Option<String>,
}

/// A message found by either source, before it's worth turning into a hit.
#[derive(Debug, Clone)]
struct Candidate<T> {
    room_id: OwnedRoomId,
    event_id: OwnedEventId,
    timestamp_ms: i64,
    event: T,
}

/// One list from every source: only this room's, each message once, newest first, at most `limit`.
fn merge<T>(sources: impl IntoIterator<Item = Candidate<T>>, room_id: &OwnedRoomId, limit: usize) -> Vec<Candidate<T>> {
    let mut seen = HashSet::new();
    let mut out: Vec<Candidate<T>> =
        sources.into_iter().filter(|c| &c.room_id == room_id).filter(|c| seen.insert(c.event_id.clone())).collect();
    out.sort_by_key(|c| std::cmp::Reverse(c.timestamp_ms));
    out.truncate(limit);
    out
}

fn candidate(room_id: OwnedRoomId, event: TimelineEvent) -> Option<Candidate<TimelineEvent>> {
    let event_id = event.event_id()?.to_owned();
    let timestamp_ms = event.timestamp().map(|t| i64::from(t.get())).unwrap_or(0);
    Some(Candidate { room_id, event_id, timestamp_ms, event })
}

/// The server's highlights in this room: what its push rules marked as about me.
async fn server_mentions(room: &Room, me: &str, want: usize) -> Result<Vec<Candidate<TimelineEvent>>> {
    let client = room.client();
    let mut out = Vec::new();
    let mut from = None;
    for _ in 0..SERVER_PAGES {
        let mut request = Request::new();
        request.only = Some("highlight".to_owned());
        request.limit = Some(UInt::from(SERVER_PAGE));
        request.from = from.take();
        let response = client.send(request).await?;
        // Synapse hands back a token even with nothing after it.
        let is_last = response.notifications.is_empty();
        for notification in response.notifications {
            if notification.room_id != room.room_id() {
                continue;
            }
            let raw = notification.event;
            if crate::push::is_edit(&raw) || sender_of(&raw).as_deref() == Some(me) {
                continue;
            }
            out.extend(candidate(notification.room_id, TimelineEvent::from_plaintext(raw)));
        }
        if is_last || out.len() >= want {
            break;
        }
        match response.next_token {
            Some(token) => from = Some(token),
            None => break,
        }
    }
    Ok(out)
}

/// Messages this device has for the room (decrypted, for encrypted rooms) that mention me, by
/// the rule bubbles are tinted by: a highlight from the push rules, or a mention of me. Reads the
/// newest `LOCAL_SCAN` messages and stops at `limit` found.
async fn local_mentions(room: &Room, me: &str, my_name: &str, limit: usize) -> Vec<Candidate<TimelineEvent>> {
    let client = room.client();
    let events = match client.event_cache_store().lock().await {
        Ok(state) => {
            // A dirty lock only means another process wrote since; reading is still fine.
            let guard = match &state {
                matrix_sdk::cross_process_lock::MappedCrossProcessLockState::Clean(g)
                | matrix_sdk::cross_process_lock::MappedCrossProcessLockState::Dirty(g) => g,
            };
            guard.get_room_events(room.room_id(), Some("m.room.message"), None).await
        }
        Err(error) => {
            warn!("The event cache couldn't be read for mentions: {error}");
            return Vec::new();
        }
    };
    let mut events = match events {
        Ok(events) => events,
        Err(error) => {
            warn!("The event cache couldn't be read for mentions: {error}");
            return Vec::new();
        }
    };
    // The store hands back every cached message in the room, unordered, and that read is the
    // scan's real cost (a newest-first read would mean walking the cache's chunks by hand). The
    // checks below, the expensive part per message, stop at the newest `LOCAL_SCAN`.
    events.sort_unstable_by_key(|e| std::cmp::Reverse(e.timestamp().map(|t| t.get())));
    events.truncate(LOCAL_SCAN);
    let names_me = mention_prefilter(me, my_name);
    let mut out = Vec::new();
    for event in events {
        if out.len() >= limit {
            break;
        }
        let raw = event.raw();
        if crate::push::is_edit(raw) || sender_of(raw).as_deref() == Some(me) {
            continue;
        }
        let highlighted = event.push_actions().is_some_and(|actions| actions.iter().any(|a| a.is_highlight()));
        if !highlighted {
            // Most messages don't name me at all: skip them before the full check.
            if !names_me.as_ref().is_some_and(|pattern| pattern.is_match(raw.json().get())) {
                continue;
            }
            let Some(content) = TimelineItemContent::from_event(room, event.clone()).await else { continue };
            if !mentions_me(&content, me, my_name) {
                continue;
            }
        }
        out.extend(candidate(room.room_id().to_owned(), event));
    }
    out
}

/// A quick test of an event's JSON for my ID, or my name when it's long enough to mean me,
/// ignoring case. Only a first pass: what passes is checked properly.
fn mention_prefilter(me: &str, my_name: &str) -> Option<Regex> {
    let mut terms = vec![regex::escape(me)];
    if my_name.trim().chars().count() >= 2 {
        terms.push(regex::escape(my_name.trim()));
    }
    Regex::new(&format!("(?i){}", terms.join("|"))).ok()
}

fn sender_of(raw: &Raw<AnySyncTimelineEvent>) -> Option<String> {
    raw.get_field::<String>("sender").ok().flatten()
}

/// The thread a message is in, from its relation.
fn thread_root(raw: &Raw<AnySyncTimelineEvent>) -> Option<String> {
    #[derive(serde::Deserialize)]
    struct Relation {
        rel_type: Option<String>,
        event_id: Option<String>,
    }
    #[derive(serde::Deserialize)]
    struct Content {
        #[serde(rename = "m.relates_to")]
        relates_to: Option<Relation>,
    }
    let relation = raw.get_field::<Content>("content").ok().flatten()?.relates_to?;
    (relation.rel_type.as_deref() == Some("m.thread")).then_some(relation.event_id).flatten()
}

/// The words of pills that point at me, as they read in the message ("Luke", "@luke").
fn my_pills(content: &TimelineItemContent, me: &str) -> Vec<String> {
    let Some(message) = content.as_message() else { return Vec::new() };
    let formatted = match message.msgtype() {
        MessageType::Text(c) => c.formatted.as_ref(),
        MessageType::Notice(c) => c.formatted.as_ref(),
        MessageType::Emote(c) => c.formatted.as_ref(),
        _ => None,
    };
    let Some(html) = html_of(formatted) else { return Vec::new() };
    parse_html(html)
        .iter()
        .flat_map(|block| block.spans())
        .filter(|span| span.mention.as_deref() == Some(me))
        .map(|span| span.text.trim().to_owned())
        .filter(|text| !text.is_empty())
        .collect()
}

/// What a mention of me can look like in a message's words: its pills to me, my name, my ID,
/// "@" and my username, and @room.
fn mention_terms(pills: Vec<String>, me: &str, my_name: &str) -> Vec<String> {
    let mut terms = pills;
    terms.push(me.to_owned());
    if let Some(local) = me.split(':').next().filter(|l| l.len() > 1) {
        terms.push(local.to_owned());
    }
    if my_name.trim().chars().count() >= 2 {
        terms.push(my_name.trim().to_owned());
    }
    terms.push("@room".to_owned());
    terms
}

/// Splits text into runs, marking each whole-word occurrence of any term (ignoring case), and
/// starts it a little before the first one when that comes late.
fn mark_mentions(text: &str, terms: &[String]) -> Vec<TextMark> {
    const LEAD: usize = 40;
    let flat = one_line(text);
    let whole = |text: String| vec![TextMark { text, is_match: false }];
    let mut sorted: Vec<&String> = terms.iter().filter(|t| !t.is_empty()).collect();
    // The longest first, so "Luke Skywalker" wins over "Luke".
    sorted.sort_by_key(|t| std::cmp::Reverse(t.len()));
    sorted.dedup();
    if sorted.is_empty() {
        return whole(flat);
    }
    let alternatives: Vec<String> = sorted.iter().map(|t| regex::escape(t)).collect();
    let Ok(pattern) = Regex::new(&format!("(?i)(?:{})", alternatives.join("|"))) else {
        return whole(flat);
    };
    let is_word = |c: Option<char>| c.is_some_and(|c| c.is_alphanumeric() || c == '_');
    let matches = |text: &str| -> Vec<(usize, usize)> {
        pattern
            .find_iter(text)
            .filter(|m| !is_word(text[..m.start()].chars().next_back()) && !is_word(text[m.end()..].chars().next()))
            .map(|m| (m.start(), m.end()))
            .collect()
    };
    let mut shown = flat.as_str();
    let mut prefix = "";
    if let Some(&(start, _)) = matches(shown).first()
        && shown[..start].chars().count() > LEAD
    {
        // Back up about half the lead, to the start of a word.
        let target = shown.floor_char_boundary(start.saturating_sub(LEAD / 2));
        let from = shown[..target].rfind(' ').map_or(target, |i| i + 1);
        shown = &shown[from..];
        prefix = "…";
    }
    let mut out = Vec::new();
    let mut last = 0;
    for (start, end) in matches(shown) {
        if start > last {
            out.push(TextMark { text: shown[last..start].to_owned(), is_match: false });
        }
        out.push(TextMark { text: shown[start..end].to_owned(), is_match: true });
        last = end;
    }
    if last < shown.len() {
        out.push(TextMark { text: shown[last..].to_owned(), is_match: false });
    }
    match out.first_mut() {
        Some(first) if !prefix.is_empty() && !first.is_match => first.text.insert_str(0, prefix),
        Some(_) if !prefix.is_empty() => out.insert(0, TextMark { text: prefix.to_owned(), is_match: false }),
        Some(_) => {}
        None => return whole(flat),
    }
    out
}

async fn hit(room: &Room, candidate: Candidate<TimelineEvent>, me: &str, my_name: &str) -> Option<MentionHit> {
    let event = candidate.event;
    let sender = event.sender()?;
    let thread_root_id = thread_root(event.raw());
    let content = TimelineItemContent::from_event(room, event).await?;
    let profile = Profile::load(room, &sender).await;
    let sender_avatar_url = profile.as_ref().and_then(|p| p.avatar_url.as_ref()).map(|a| a.to_string());
    let sender_name =
        profile.and_then(|p| p.display_name).filter(|n| !n.trim().is_empty()).unwrap_or_else(|| sender.to_string());
    let Summary::Message { body } = summarize(&content, Actor { name: &sender_name, is_you: false }, me) else {
        return None;
    };
    if matches!(body, Body::Deleted | Body::Unsupported) {
        return None;
    }
    let terms = mention_terms(my_pills(&content, me), me, my_name);
    let preview = mark_mentions(body.text().unwrap_or_default(), &terms);
    Some(MentionHit {
        room_id: candidate.room_id.to_string(),
        event_id: candidate.event_id.to_string(),
        sender_id: sender.to_string(),
        sender_name,
        sender_avatar_url,
        body,
        preview,
        timestamp_ms: candidate.timestamp_ms,
        thread_root_id,
    })
}

#[uniffi::export]
impl XeniaClient {
    /// Messages in a conversation that mention me, newest first, at most `limit`. Fails only
    /// when the server can't be asked and this device has nothing to show.
    pub async fn mentions(&self, room_id: String, limit: u32) -> Result<Vec<MentionHit>> {
        let room = self.sdk_room(&room_id).await?;
        let core = self.core().await?;
        run(async move {
            let me = core.user_id.clone();
            let my_name = core.my_name();
            let limit = limit.max(1) as usize;
            let (server, local) =
                tokio::join!(server_mentions(&room, &me, limit), local_mentions(&room, &me, &my_name, limit));
            let server = match server {
                Ok(found) => found,
                Err(error) if local.is_empty() => return Err(error),
                Err(error) => {
                    warn!("The server's mentions couldn't be loaded: {error}");
                    Vec::new()
                }
            };
            let mut hits = Vec::new();
            // The local copy first: it's decrypted, where the server's might not be.
            for candidate in merge(local.into_iter().chain(server), &room.room_id().to_owned(), limit) {
                hits.extend(hit(&room, candidate, &me, &my_name).await);
            }
            Ok(hits)
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use matrix_sdk::ruma::{event_id, room_id};

    use super::*;

    fn found(room: &str, event: &str, at: i64) -> Candidate<()> {
        Candidate {
            room_id: room.try_into().unwrap(),
            event_id: event.try_into().unwrap(),
            timestamp_ms: at,
            event: (),
        }
    }

    fn ids(list: &[Candidate<()>]) -> Vec<&str> {
        list.iter().map(|c| c.event_id.as_str()).collect()
    }

    #[test]
    fn merge_keeps_only_this_room() {
        let here = room_id!("!here:x").to_owned();
        let merged = merge([found("!here:x", "$a", 1), found("!there:x", "$b", 2)], &here, 10);
        assert_eq!(ids(&merged), ["$a"]);
    }

    #[test]
    fn merge_shows_a_message_found_twice_once() {
        let here = room_id!("!here:x").to_owned();
        let merged =
            merge([found("!here:x", "$a", 1), found("!here:x", "$a", 1), found("!here:x", "$b", 2)], &here, 10);
        assert_eq!(ids(&merged), ["$b", "$a"]);
    }

    #[test]
    fn merge_puts_newest_first_and_stops_at_the_limit() {
        let here = room_id!("!here:x").to_owned();
        let merged =
            merge([found("!here:x", "$old", 1), found("!here:x", "$new", 3), found("!here:x", "$mid", 2)], &here, 2);
        assert_eq!(ids(&merged), ["$new", "$mid"]);
    }

    #[test]
    fn merge_keeps_the_first_source_copy() {
        let here = room_id!("!here:x").to_owned();
        let mut local = found("!here:x", "$a", 1);
        local.timestamp_ms = 5;
        let merged = merge([local, found("!here:x", "$a", 1)], &here, 10);
        assert_eq!(merged[0].timestamp_ms, 5);
        assert_eq!(merged[0].event_id, event_id!("$a"));
    }

    fn marked(marks: &[TextMark]) -> Vec<&str> {
        marks.iter().filter(|m| m.is_match).map(|m| m.text.as_str()).collect()
    }

    fn terms() -> Vec<String> {
        mention_terms(vec!["Luke".to_owned()], "@luke:example.org", "Luke Skywalker")
    }

    #[test]
    fn marks_pills_names_and_room_mentions() {
        let marks = mark_mentions("Luke, can you and @room look? Thanks Luke Skywalker", &terms());
        assert_eq!(marked(&marks), ["Luke", "@room", "Luke Skywalker"]);
    }

    #[test]
    fn marks_only_whole_words() {
        let marks = mark_mentions("Lukewarm coffee for @luke", &terms());
        assert_eq!(marked(&marks), ["@luke"]);
    }

    #[test]
    fn marking_keeps_every_word() {
        let text = "hey @luke:example.org, look";
        let joined: String = mark_mentions(text, &terms()).iter().map(|m| m.text.as_str()).collect();
        assert_eq!(joined, text);
    }

    #[test]
    fn a_late_mention_starts_the_preview_near_it() {
        let text = format!("{} so what do you think Luke?", "word ".repeat(30));
        let marks = mark_mentions(&text, &terms());
        assert!(marks[0].text.starts_with('…'));
        assert_eq!(marked(&marks), ["Luke"]);
    }

    #[test]
    fn the_prefilter_finds_my_id_or_name_in_any_case() {
        let pattern = mention_prefilter("@luke:example.org", "Luke Skywalker").expect("a pattern");
        assert!(pattern.is_match(r#"{"body":"ping @LUKE:example.org"}"#));
        assert!(pattern.is_match(r#"{"body":"thanks luke skywalker"}"#));
        assert!(!pattern.is_match(r#"{"body":"thanks Luke"}"#));
        // A one-letter name would match nearly everything, so only the ID counts then.
        let pattern = mention_prefilter("@l:x", "L").expect("a pattern");
        assert!(!pattern.is_match(r#"{"body":"hello"}"#));
    }

    #[test]
    fn text_without_a_mention_is_one_run() {
        let marks = mark_mentions("nothing here", &terms());
        assert_eq!(marks, vec![TextMark { text: "nothing here".to_owned(), is_match: false }]);
    }
}
