//! From the SDK's timeline items to rows.

use std::{collections::HashMap, sync::Arc};

use matrix_sdk::ruma::events::{
    poll::start::PollKind,
    room::{ImageInfo, MediaSource, message::MessageType},
};
use matrix_sdk_ui::timeline::{
    EventSendState, EventTimelineItem, InReplyToDetails, MsgLikeContent, MsgLikeKind, PollResult, TimelineDetails,
    TimelineItem, TimelineItemContent, TimelineItemKind, VirtualTimelineItem,
};

use super::{
    MediaInfo, MessageContent, NoteLine, PollAnswer, Reaction, Reader, ReplyPreview, ReplyState, RunPosition, TextKind,
    ThreadSummary, TimelineMessage, layout::Raw,
};
use crate::{
    content::{Actor, Summary, html_of, mentions_me, summarize, summarize_msg_like},
    media::source_handle,
    models::SendState,
    text::{is_jumbo_emoji, mentions_in, parse_html, plain_blocks, plain_text},
};

/// Who's who in this room, for read receipts, reactions and typing.
#[derive(Default, Clone)]
pub(crate) struct People {
    pub names: HashMap<String, (String, Option<String>)>,
}

impl People {
    pub(crate) fn name(&self, user_id: &str) -> String {
        self.names.get(user_id).map(|(n, _)| n.clone()).unwrap_or_else(|| crate::text::first_name(user_id))
    }

    pub(crate) fn reader(&self, user_id: &str) -> Reader {
        let (name, avatar) =
            self.names.get(user_id).cloned().unwrap_or_else(|| (crate::text::first_name(user_id), None));
        Reader { user_id: user_id.to_owned(), name, avatar_url: avatar }
    }

    /// Learns names from the senders in the timeline.
    pub(crate) fn learn(&mut self, items: &[Arc<TimelineItem>]) {
        for item in items {
            if let Some(event) = item.as_event()
                && let TimelineDetails::Ready(profile) = event.sender_profile()
                && let Some(name) = profile.display_name.clone().filter(|n| !n.trim().is_empty())
            {
                self.names
                    .insert(event.sender().to_string(), (name, profile.avatar_url.as_ref().map(|a| a.to_string())));
            }
        }
    }
}

pub(crate) struct Context<'a> {
    pub thread_unread: &'a HashMap<String, (String, crate::models::UnreadKind)>,
    pub me: &'a str,
    pub my_name: &'a str,
    pub people: &'a People,
    pub pinned: &'a [String],
    pub can_redact_others: bool,
}

/// The row an item becomes, before layout. `None` for items that aren't shown (date dividers,
/// hidden state events, reactions without a message).
pub(crate) fn raw_row(item: &TimelineItem, cx: &Context<'_>) -> Option<Raw> {
    let id = item.unique_id().0.clone();
    match item.kind() {
        TimelineItemKind::Virtual(VirtualTimelineItem::ReadMarker) => Some(Raw::ReadMarker { id }),
        TimelineItemKind::Virtual(VirtualTimelineItem::TimelineStart) => Some(Raw::Start { id }),
        TimelineItemKind::Virtual(_) => None,
        TimelineItemKind::Event(event) => event_row(id, event, cx),
    }
}

fn sender_profile(event: &EventTimelineItem) -> (String, Option<String>) {
    match event.sender_profile() {
        TimelineDetails::Ready(p) => (
            p.display_name.clone().filter(|n| !n.trim().is_empty()).unwrap_or_else(|| event.sender().to_string()),
            p.avatar_url.as_ref().map(|a| a.to_string()),
        ),
        _ => (event.sender().to_string(), None),
    }
}

fn event_row(id: String, event: &EventTimelineItem, cx: &Context<'_>) -> Option<Raw> {
    let (sender_name, avatar) = sender_profile(event);
    let timestamp_ms: i64 = event.timestamp().get().into();
    let content = event.content();

    let TimelineItemContent::MsgLike(msg) = content else {
        return match summarize(content, Actor { name: &sender_name, is_you: event.is_own() }, cx.me) {
            Summary::Note(note) => Some(Raw::Note(NoteLine { id, timestamp_ms, note })),
            _ => None,
        };
    };
    if matches!(summarize_msg_like(msg), Summary::Hidden) {
        return None;
    }

    let (content_row, is_edited) = message_content(msg, cx.me, event.is_own(), cx.people);
    let event_id = event.event_id().map(|e| e.to_string());
    let send_state = match event.send_state() {
        None | Some(EventSendState::Sent { .. }) => SendState::Sent,
        Some(EventSendState::SendingFailed { .. }) => SendState::Failed,
        Some(EventSendState::NotSentYet { .. }) => SendState::Sending,
    };
    let mentions_me = !event.is_own()
        && (event.is_highlighted()
            || mentions_me(content, cx.me, cx.my_name)
            || matches!(&content_row, MessageContent::Text { blocks, .. } if mentions_in(blocks).iter().any(|u| u == cx.me)));

    let reactions = msg
        .reactions
        .iter()
        .map(|(key, senders)| Reaction {
            key: key.clone(),
            count: senders.len() as u32,
            is_mine: senders.keys().any(|s| s.as_str() == cx.me),
            sender_names: senders
                .keys()
                .map(|s| if s.as_str() == cx.me { String::new() } else { cx.people.name(s.as_str()) })
                .collect(),
        })
        .collect();

    let read_by = event
        .read_receipts()
        .keys()
        .filter(|u| u.as_str() != cx.me && *u != event.sender())
        .map(|u| cx.people.reader(u.as_str()))
        .collect();

    let is_text = matches!(content_row, MessageContent::Text { .. });
    Some(Raw::Message(Box::new(TimelineMessage {
        id,
        is_pinned: event_id.as_ref().is_some_and(|e| cx.pinned.contains(e)),
        event_id,
        sender_id: event.sender().to_string(),
        sender_name,
        sender_avatar_url: avatar,
        is_own: event.is_own(),
        timestamp_ms,
        can_edit: event.is_editable() && is_text,
        can_reply: event.can_be_replied_to(),
        can_forward: event.event_id().is_some() && matches!(msg.kind, MsgLikeKind::Message(_)),
        can_redact: is_message_like_redactable(&msg.kind) && (event.is_own() || cx.can_redact_others),
        content: content_row,
        is_edited,
        mentions_me,
        send_state,
        reactions,
        reply: msg.in_reply_to.as_ref().map(|r| reply_preview(r, cx)),
        thread: thread_summary(msg, event.event_id().map(|e| e.as_str()), cx),
        read_by,
        run: RunPosition { is_first: true, is_last: true },
        show_sender: false,
        delivery: None,
        seen: None,
        is_highlighted: false,
    })))
}

fn is_message_like_redactable(kind: &MsgLikeKind) -> bool {
    !matches!(kind, MsgLikeKind::Redacted)
}

fn media(source: &MediaSource, filename: &str, info: Option<&ImageInfo>, mimetype: Option<String>) -> MediaInfo {
    MediaInfo {
        source: source_handle(source),
        thumbnail: info.and_then(|i| i.thumbnail_source.as_ref()).map(source_handle),
        width: pixels(info.and_then(|i| i.width)),
        height: pixels(info.and_then(|i| i.height)),
        blurhash: info.and_then(|i| i.blurhash.clone()),
        mimetype: mimetype.or_else(|| info.and_then(|i| i.mimetype.clone())),
        size: info.and_then(|i| i.size).map(u64::from),
        filename: filename.to_owned(),
    }
}

/// A size from media info, 0 when it's missing or absurd.
fn pixels(value: Option<matrix_sdk::ruma::UInt>) -> u32 {
    value.and_then(|v| u32::try_from(u64::from(v)).ok()).unwrap_or(0)
}

fn caption_of(caption: Option<&str>) -> Option<String> {
    caption.map(str::trim).filter(|c| !c.is_empty()).map(str::to_owned)
}

fn text_content(body: &str, html: Option<&str>, kind: TextKind) -> MessageContent {
    let blocks = html.map(parse_html).filter(|b| !b.is_empty()).unwrap_or_else(|| plain_blocks(body));
    let plain = if html.is_some() { plain_text(&blocks) } else { body.trim().to_owned() };
    let is_jumbo = kind == TextKind::Normal && is_jumbo_emoji(&plain);
    MessageContent::Text { blocks, plain, kind, is_jumbo }
}

pub(crate) fn message_content(msg: &MsgLikeContent, me: &str, is_own: bool, people: &People) -> (MessageContent, bool) {
    match &msg.kind {
        MsgLikeKind::Message(message) => {
            let content = match message.msgtype() {
                MessageType::Text(c) => text_content(&c.body, html_of(c.formatted.as_ref()), TextKind::Normal),
                MessageType::Notice(c) => text_content(&c.body, html_of(c.formatted.as_ref()), TextKind::Notice),
                MessageType::Emote(c) => text_content(&c.body, html_of(c.formatted.as_ref()), TextKind::Emote),
                MessageType::Image(c) => MessageContent::Image {
                    media: media(&c.source, c.filename(), c.info.as_deref(), None),
                    caption: caption_of(c.caption()),
                },
                MessageType::Video(c) => {
                    let info = c.info.as_deref();
                    MessageContent::Video {
                        media: MediaInfo {
                            source: source_handle(&c.source),
                            thumbnail: info.and_then(|i| i.thumbnail_source.as_ref()).map(source_handle),
                            width: pixels(info.and_then(|i| i.width)),
                            height: pixels(info.and_then(|i| i.height)),
                            blurhash: info.and_then(|i| i.blurhash.clone()),
                            mimetype: info.and_then(|i| i.mimetype.clone()),
                            size: info.and_then(|i| i.size).map(u64::from),
                            filename: c.filename().to_owned(),
                        },
                        duration_ms: info
                            .and_then(|i| i.duration)
                            .map(|d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX)),
                        caption: caption_of(c.caption()),
                    }
                }
                MessageType::Audio(c) => MessageContent::Audio {
                    source: source_handle(&c.source),
                    filename: c.filename().to_owned(),
                    duration_ms: c
                        .info
                        .as_deref()
                        .and_then(|i| i.duration)
                        .map(|d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX)),
                    size: c.info.as_deref().and_then(|i| i.size).map(u64::from),
                    mimetype: c.info.as_deref().and_then(|i| i.mimetype.clone()),
                    is_voice: c.voice.is_some(),
                    caption: caption_of(c.caption()),
                },
                MessageType::File(c) => MessageContent::File {
                    source: source_handle(&c.source),
                    filename: c.filename().to_owned(),
                    size: c.info.as_deref().and_then(|i| i.size).map(u64::from),
                    mimetype: c.info.as_deref().and_then(|i| i.mimetype.clone()),
                    caption: caption_of(c.caption()),
                },
                MessageType::Location(c) => {
                    MessageContent::Location { geo_uri: c.geo_uri.clone(), description: caption_of(Some(&c.body)) }
                }
                other => text_content(other.body(), None, TextKind::Normal),
            };
            (content, message.is_edited())
        }
        MsgLikeKind::Sticker(sticker) => {
            let c = sticker.content();
            let source = MediaSource::from(c.source.clone());
            (
                MessageContent::Sticker {
                    media: media(&source, &c.body, Some(&c.info), None),
                    description: c.body.clone(),
                },
                false,
            )
        }
        MsgLikeKind::Poll(poll) => (poll_content(&poll.results(), me, is_own, people), poll.is_edit()),
        MsgLikeKind::Redacted => (MessageContent::Deleted, false),
        MsgLikeKind::UnableToDecrypt(_) => (MessageContent::Encrypted, false),
        MsgLikeKind::LiveLocation(_) => (MessageContent::Location { geo_uri: String::new(), description: None }, false),
        MsgLikeKind::Other(_) => (MessageContent::Unsupported, false),
    }
}

fn poll_content(results: &PollResult, me: &str, is_own: bool, people: &People) -> MessageContent {
    let answers: Vec<(&str, &str)> = results.answers.iter().map(|a| (a.id.as_str(), a.text.as_str())).collect();
    let poll = PollTally {
        question: &results.question,
        is_disclosed: results.kind == PollKind::Disclosed,
        max_selections: results.max_selections,
        answers: &answers,
        votes: &results.votes,
        is_ended: results.end_time.is_some(),
    };
    poll.content(me, is_own, people)
}

/// A poll's answers and votes, as the SDK compiled them.
struct PollTally<'a> {
    question: &'a str,
    is_disclosed: bool,
    max_selections: u64,
    answers: &'a [(&'a str, &'a str)],
    votes: &'a HashMap<String, Vec<String>>,
    is_ended: bool,
}

impl PollTally<'_> {
    fn content(&self, me: &str, is_own: bool, people: &People) -> MessageContent {
        let count = |id: &str| self.votes.get(id).map_or(0, Vec::len) as u32;
        let most = self.answers.iter().map(|(id, _)| count(id)).max().unwrap_or(0);
        let mut voters: Vec<&String> = self.votes.values().flatten().collect();
        voters.sort_unstable();
        voters.dedup();
        MessageContent::Poll {
            question: self.question.to_owned(),
            answers: self
                .answers
                .iter()
                .map(|(id, text)| PollAnswer {
                    id: (*id).to_owned(),
                    text: (*text).to_owned(),
                    votes: count(id),
                    is_mine: self.votes.get(*id).is_some_and(|v| v.iter().any(|u| u == me)),
                    voters: self
                        .votes
                        .get(*id)
                        .map(|v| v.iter().map(|u| people.reader(u)).collect())
                        .unwrap_or_default(),
                    is_winner: self.is_ended && most > 0 && count(id) == most,
                })
                .collect(),
            is_disclosed: self.is_disclosed,
            max_selections: u32::try_from(self.max_selections).unwrap_or(1).max(1),
            voter_count: voters.len() as u32,
            is_ended: self.is_ended,
            can_end: is_own && !self.is_ended,
        }
    }
}

/// What a thread's unread state depends on, as far as its summary says: its latest reply. My
/// receipts in it aren't in the summary, so a receipt of mine has it worked out again instead.
pub(crate) fn thread_key(summary: &matrix_sdk_ui::timeline::ThreadSummary) -> String {
    match &summary.latest_event {
        TimelineDetails::Ready(e) => format!("{:?}", e.identifier),
        _ => String::new(),
    }
}

/// The latest reply is someone else's: whether my receipt is past it takes a look.
pub(crate) fn may_be_unread(summary: &matrix_sdk_ui::timeline::ThreadSummary, me: &str) -> bool {
    let TimelineDetails::Ready(latest) = &summary.latest_event else { return false };
    latest.sender.as_str() != me
        && matches!(latest.identifier, matrix_sdk_ui::timeline::TimelineEventItemId::EventId(_))
}

fn reply_preview(reply: &InReplyToDetails, cx: &Context<'_>) -> ReplyPreview {
    let event_id = reply.event_id.to_string();
    match &reply.event {
        TimelineDetails::Ready(embedded) => {
            let name = match &embedded.sender_profile {
                TimelineDetails::Ready(p) => p.display_name.clone().filter(|n| !n.trim().is_empty()),
                _ => None,
            }
            .unwrap_or_else(|| cx.people.name(embedded.sender.as_str()));
            let is_own = embedded.sender.as_str() == cx.me;
            let body = match summarize(&embedded.content, Actor { name: &name, is_you: is_own }, cx.me) {
                Summary::Message { body, .. } => Some(body),
                _ => None,
            };
            ReplyPreview {
                event_id,
                sender_id: Some(embedded.sender.to_string()),
                sender_name: Some(name),
                is_own,
                body,
                state: ReplyState::Ready,
            }
        }
        TimelineDetails::Error(_) => ReplyPreview {
            event_id,
            sender_id: None,
            sender_name: None,
            is_own: false,
            body: None,
            state: ReplyState::Unavailable,
        },
        TimelineDetails::Pending | TimelineDetails::Unavailable => ReplyPreview {
            event_id,
            sender_id: None,
            sender_name: None,
            is_own: false,
            body: None,
            state: ReplyState::Loading,
        },
    }
}

fn thread_summary(msg: &MsgLikeContent, root: Option<&str>, cx: &Context<'_>) -> Option<ThreadSummary> {
    let summary = msg.thread_summary.as_ref()?;
    if summary.num_replies == 0 {
        return None;
    }
    let latest = match &summary.latest_event {
        TimelineDetails::Ready(e) => Some(e),
        _ => None,
    };
    let latest_name = latest.map(|e| match &e.sender_profile {
        TimelineDetails::Ready(p) => {
            p.display_name.clone().filter(|n| !n.trim().is_empty()).unwrap_or_else(|| e.sender.to_string())
        }
        _ => cx.people.name(e.sender.as_str()),
    });
    let latest_body = latest.and_then(|e| {
        let name = latest_name.clone().unwrap_or_default();
        match summarize(&e.content, Actor { name: &name, is_you: e.sender.as_str() == cx.me }, cx.me) {
            Summary::Message { body, .. } => Some(body),
            _ => None,
        }
    });
    let unread = match root.and_then(|r| cx.thread_unread.get(r)) {
        Some((key, kind)) if *key == thread_key(summary) => *kind,
        // Not worked out yet: a reply from someone else after my receipt is unread for now.
        _ if may_be_unread(summary, cx.me) => crate::models::UnreadKind::Unread,
        _ => crate::models::UnreadKind::None,
    };
    Some(ThreadSummary {
        reply_count: summary.num_replies,
        unread,
        latest_sender_id: latest.map(|e| e.sender.to_string()),
        latest_sender_name: latest_name,
        latest_sender_avatar_url: latest.and_then(|e| match &e.sender_profile {
            TimelineDetails::Ready(p) => p.avatar_url.as_ref().map(|a| a.to_string()),
            _ => None,
        }),
        latest_body,
        latest_timestamp_ms: latest.map(|e| e.timestamp.get().into()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn poll(votes: &[(&str, &[&str])], is_ended: bool, is_own: bool) -> (Vec<PollAnswer>, u32, bool) {
        let votes: HashMap<String, Vec<String>> = votes
            .iter()
            .map(|(id, users)| ((*id).to_owned(), users.iter().map(|u| (*u).to_owned()).collect()))
            .collect();
        let tally = PollTally {
            question: "Lunch?",
            is_disclosed: true,
            max_selections: 1,
            answers: &[("a", "Tacos"), ("b", "Pho"), ("c", "Salad")],
            votes: &votes,
            is_ended,
        };
        let MessageContent::Poll { answers, voter_count, can_end, .. } =
            tally.content("@me:x", is_own, &People::default())
        else {
            panic!("not a poll")
        };
        (answers, voter_count, can_end)
    }

    #[test]
    fn poll_counts_people_once_and_crowns_ties_only_when_ended() {
        let votes: &[(&str, &[&str])] = &[("a", &["@me:x", "@sam:x"]), ("b", &["@sam:x", "@ana:x"])];
        let (answers, voters, can_end) = poll(votes, false, true);
        assert_eq!(voters, 3);
        assert!(can_end);
        assert_eq!(answers.iter().map(|a| a.votes).collect::<Vec<_>>(), [2, 2, 0]);
        assert_eq!(answers.iter().map(|a| a.is_mine).collect::<Vec<_>>(), [true, false, false]);
        assert!(answers.iter().all(|a| !a.is_winner));

        let (answers, _, can_end) = poll(votes, true, true);
        assert!(!can_end);
        assert_eq!(answers.iter().map(|a| a.is_winner).collect::<Vec<_>>(), [true, true, false]);

        // Nobody voted: an ended poll has no winner.
        let (answers, voters, _) = poll(&[], true, false);
        assert_eq!(voters, 0);
        assert!(answers.iter().all(|a| !a.is_winner));
    }
}
