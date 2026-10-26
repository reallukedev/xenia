//! What an event says, in structured form: the body of a message for previews and quotes, and
//! the notes for membership and room changes. Apps put these into words in their own language.

use matrix_sdk::ruma::events::room::{MediaSource, message::MessageType};
use matrix_sdk_ui::timeline::{
    AnyOtherStateEventContentChange, MembershipChange, MsgLikeContent, MsgLikeKind, TimelineItemContent,
};

use crate::text::{parse_html, plain_text};

/// What a message says, for one-line previews, reply quotes, thread summaries and notifications.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum, serde::Serialize, serde::Deserialize)]
pub enum Body {
    /// Text, with any formatting flattened to plain words on one line.
    Text {
        text: String,
    },
    /// "/me waves": the app shows it after the sender's name.
    Emote {
        text: String,
    },
    Notice {
        text: String,
    },
    Image {
        caption: Option<String>,
    },
    Video {
        caption: Option<String>,
    },
    Audio {
        caption: Option<String>,
    },
    Voice,
    File {
        name: String,
        caption: Option<String>,
    },
    Sticker {
        description: String,
    },
    Poll {
        question: String,
    },
    Location,
    Gallery {
        count: u32,
    },
    Deleted,
    /// Couldn't be decrypted (yet).
    Encrypted,
    Unsupported,
    /// An invitation to join (for a pushed invite).
    Invite,
}

impl Body {
    /// The words themselves, for search and mentions-by-name; media without a caption has none.
    pub fn text(&self) -> Option<&str> {
        match self {
            Body::Text { text } | Body::Emote { text } | Body::Notice { text } => Some(text),
            Body::Image { caption }
            | Body::Video { caption }
            | Body::Audio { caption }
            | Body::File { caption, .. } => caption.as_deref(),
            Body::Poll { question } => Some(question),
            _ => None,
        }
    }
}

/// A change to a conversation, shown as a centered line in the timeline.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum, serde::Serialize, serde::Deserialize)]
pub enum Note {
    /// Someone joined, left, was invited... `is_you` when it's about the signed-in person.
    Membership {
        name: String,
        is_you: bool,
        change: MembershipNote,
    },
    /// Someone changed their display name.
    Renamed {
        old_name: String,
        new_name: String,
    },
    RoomNamed {
        by: String,
        by_you: bool,
        name: String,
    },
    TopicChanged {
        by: String,
        by_you: bool,
    },
    PhotoChanged {
        by: String,
        by_you: bool,
    },
    EncryptionEnabled,
    Created {
        by: String,
        by_you: bool,
    },
    CallStarted {
        by: String,
        by_you: bool,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum, serde::Serialize, serde::Deserialize)]
pub enum MembershipNote {
    Joined,
    Left,
    Invited,
    DeclinedInvite,
    InviteWithdrawn,
    Removed,
    Banned,
    RemovedAndBanned,
    Unbanned,
    AskedToJoin,
}

/// How an event reads, before the app decides where it goes.
pub(crate) enum Summary {
    Message { body: Body },
    Note(Note),
    Hidden,
}

/// Who did something, for notes: the name, and whether it was the signed-in person.
pub(crate) struct Actor<'a> {
    pub name: &'a str,
    pub is_you: bool,
}

pub(crate) fn summarize(content: &TimelineItemContent, actor: Actor<'_>, me: &str) -> Summary {
    let by = actor.name.to_owned();
    let by_you = actor.is_you;
    match content {
        TimelineItemContent::MsgLike(msg) => summarize_msg_like(msg),
        TimelineItemContent::MembershipChange(change) => {
            let Some(note) = change.change().and_then(membership_note) else {
                return Summary::Hidden;
            };
            let name = change.display_name().unwrap_or_else(|| change.user_id().to_string());
            Summary::Note(Note::Membership { name, is_you: change.user_id().as_str() == me, change: note })
        }
        TimelineItemContent::ProfileChange(change) => match change.displayname_change() {
            Some(names) => match (&names.old, &names.new) {
                (Some(old), Some(new)) if old != new => {
                    Summary::Note(Note::Renamed { old_name: old.clone(), new_name: new.clone() })
                }
                _ => Summary::Hidden,
            },
            None => Summary::Hidden,
        },
        TimelineItemContent::OtherState(state) => match state.content() {
            AnyOtherStateEventContentChange::RoomName(change) => match change {
                ruma::events::StateEventContentChange::Original { content, .. } if !content.name.is_empty() => {
                    Summary::Note(Note::RoomNamed { by, by_you, name: content.name.clone() })
                }
                _ => Summary::Hidden,
            },
            AnyOtherStateEventContentChange::RoomTopic(_) => Summary::Note(Note::TopicChanged { by, by_you }),
            AnyOtherStateEventContentChange::RoomAvatar(_) => Summary::Note(Note::PhotoChanged { by, by_you }),
            AnyOtherStateEventContentChange::RoomEncryption(_) => Summary::Note(Note::EncryptionEnabled),
            AnyOtherStateEventContentChange::RoomCreate(_) => Summary::Note(Note::Created { by, by_you }),
            _ => Summary::Hidden,
        },
        TimelineItemContent::CallInvite | TimelineItemContent::RtcNotification { .. } => {
            Summary::Note(Note::CallStarted { by, by_you })
        }
        _ => Summary::Hidden,
    }
}

fn membership_note(change: MembershipChange) -> Option<MembershipNote> {
    Some(match change {
        MembershipChange::Joined | MembershipChange::InvitationAccepted | MembershipChange::KnockAccepted => {
            MembershipNote::Joined
        }
        MembershipChange::Left => MembershipNote::Left,
        MembershipChange::Invited => MembershipNote::Invited,
        MembershipChange::InvitationRejected => MembershipNote::DeclinedInvite,
        MembershipChange::InvitationRevoked => MembershipNote::InviteWithdrawn,
        MembershipChange::Kicked => MembershipNote::Removed,
        MembershipChange::Banned => MembershipNote::Banned,
        MembershipChange::KickedAndBanned => MembershipNote::RemovedAndBanned,
        MembershipChange::Unbanned => MembershipNote::Unbanned,
        MembershipChange::Knocked => MembershipNote::AskedToJoin,
        _ => return None,
    })
}

pub(crate) fn summarize_msg_like(msg: &MsgLikeContent) -> Summary {
    match &msg.kind {
        MsgLikeKind::Message(message) => Summary::Message { body: body_of(message.msgtype()) },
        MsgLikeKind::Sticker(sticker) => {
            Summary::Message { body: Body::Sticker { description: sticker.content().body.clone() } }
        }
        MsgLikeKind::Poll(poll) => Summary::Message { body: Body::Poll { question: poll.results().question } },
        MsgLikeKind::Redacted => Summary::Message { body: Body::Deleted },
        MsgLikeKind::UnableToDecrypt(_) => Summary::Message { body: Body::Encrypted },
        MsgLikeKind::LiveLocation(_) => Summary::Message { body: Body::Location },
        MsgLikeKind::Other(_) => Summary::Hidden,
    }
}

fn caption(caption: Option<&str>) -> Option<String> {
    caption.map(one_line).filter(|c| !c.is_empty())
}

/// Collapses whitespace to single spaces: previews are one line.
pub(crate) fn one_line(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The plain words of a text message, preferring its formatted body so markdown or HTML never
/// shows through.
pub(crate) fn text_of(body: &str, formatted_html: Option<&str>) -> String {
    let plain = formatted_html.map(|html| plain_text(&parse_html(html))).filter(|t| !t.trim().is_empty());
    one_line(plain.as_deref().unwrap_or(body))
}

pub(crate) fn html_of(formatted: Option<&ruma::events::room::message::FormattedBody>) -> Option<&str> {
    formatted.filter(|f| f.format == ruma::events::room::message::MessageFormat::Html).map(|f| f.body.as_str())
}

/// The picture worth showing with a notification, as a media handle: a photo's thumbnail (or the
/// photo, when it has none and isn't big), or a video's still.
pub(crate) fn picture_of(content: &TimelineItemContent) -> Option<String> {
    // Whole encrypted photos are decrypted in memory, and the notification extension has little.
    const LARGEST_WHOLE_PHOTO: u64 = 4 * 1024 * 1024;
    let TimelineItemContent::MsgLike(msg) = content else { return None };
    let MsgLikeKind::Message(message) = &msg.kind else { return None };
    match message.msgtype() {
        MessageType::Image(image) => {
            let info = image.info.as_deref();
            if let Some(thumbnail) = info.and_then(|i| i.thumbnail_source.as_ref()) {
                return Some(crate::media::source_handle(thumbnail));
            }
            // The server scales unencrypted photos itself.
            let fits = matches!(image.source, MediaSource::Plain(_))
                || info.and_then(|i| i.size).is_some_and(|size| u64::from(size) <= LARGEST_WHOLE_PHOTO);
            fits.then(|| crate::media::source_handle(&image.source))
        }
        MessageType::Video(video) => {
            video.info.as_deref().and_then(|i| i.thumbnail_source.as_ref()).map(crate::media::source_handle)
        }
        _ => None,
    }
}

pub(crate) fn body_of(msgtype: &MessageType) -> Body {
    match msgtype {
        MessageType::Text(c) => Body::Text { text: text_of(&c.body, html_of(c.formatted.as_ref())) },
        MessageType::Emote(c) => Body::Emote { text: text_of(&c.body, html_of(c.formatted.as_ref())) },
        MessageType::Notice(c) => Body::Notice { text: text_of(&c.body, html_of(c.formatted.as_ref())) },
        MessageType::Image(c) => Body::Image { caption: caption(c.caption()) },
        MessageType::Video(c) => Body::Video { caption: caption(c.caption()) },
        MessageType::Audio(c) if c.voice.is_some() => Body::Voice,
        MessageType::Audio(c) => Body::Audio { caption: caption(c.caption()) },
        MessageType::File(c) => Body::File { name: c.filename().to_owned(), caption: caption(c.caption()) },
        MessageType::Location(_) => Body::Location,
        other => {
            let body = one_line(other.body());
            if body.is_empty() { Body::Unsupported } else { Body::Text { text: body } }
        }
    }
}

/// Whether a message mentions `me`: its `m.mentions` when it has them (other clients' guesses
/// are exactly what they're there to replace), else a pill in its HTML, else my ID or display
/// name in its text. The quote of an earlier message in a reply never counts.
pub(crate) fn mentions_me(content: &TimelineItemContent, me: &str, my_name: &str) -> bool {
    let Some(message) = content.as_message() else {
        return false;
    };
    let (body, html) = match message.msgtype() {
        MessageType::Text(c) => (&c.body, html_of(c.formatted.as_ref())),
        MessageType::Notice(c) => (&c.body, html_of(c.formatted.as_ref())),
        MessageType::Emote(c) => (&c.body, html_of(c.formatted.as_ref())),
        _ => return false,
    };
    if me.is_empty() {
        return false;
    }
    if let Some(mentions) = message.mentions() {
        // @room counts only when the sender may notify the room, which the push rules decide
        // (the event's highlight and the room's mention count), not anyone who sets the flag.
        return mentions.user_ids.iter().any(|u| u.as_str() == me);
    }
    if let Some(html) = html
        && html.contains(me)
        && crate::text::mentions_in(&crate::text::parse_html(html)).iter().any(|u| u == me)
    {
        return true;
    }
    let body = without_reply_fallback(body);
    body.contains(me) || mentions_word(body, my_name)
}

/// A plain body without the "> <@someone> what they said" lines older clients put before a reply.
fn without_reply_fallback(body: &str) -> &str {
    if !body.starts_with("> ") {
        return body;
    }
    match body.find("\n\n") {
        Some(end) if body[..end].lines().all(|line| line.starts_with('>')) => &body[end + 2..],
        _ => body,
    }
}

/// `name` appears in `text` as a whole word (not inside another word), ignoring case.
pub(crate) fn mentions_word(text: &str, name: &str) -> bool {
    if name.chars().count() < 2 {
        return false;
    }
    // Called for every row and summary: a plain scan, not a pattern compiled each time.
    let text = text.to_lowercase();
    let name = name.to_lowercase();
    let is_word = |c: Option<char>| c.is_some_and(char::is_alphanumeric);
    text.match_indices(&name)
        .any(|(at, _)| !is_word(text[..at].chars().next_back()) && !is_word(text[at + name.len()..].chars().next()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn name_mentions_are_whole_words() {
        assert!(mentions_word("hey Luke, look", "Luke"));
        assert!(mentions_word("luke?", "Luke"));
        assert!(!mentions_word("Lukewarm tea", "Luke"));
        assert!(!mentions_word("a", "a"));
        assert!(mentions_word("Zoë!", "zoë"));
        assert!(!mentions_word("Zoëy", "Zoë"));
    }

    #[test]
    fn reply_quotes_are_not_part_of_the_message() {
        assert_eq!(without_reply_fallback("> <@luke:localhost> are you in?\n\nyes, Maya"), "yes, Maya");
        assert_eq!(without_reply_fallback("> a quote I typed"), "> a quote I typed");
        assert_eq!(without_reply_fallback("hi @luke"), "hi @luke");
    }

    #[test]
    fn formatted_text_is_flattened() {
        assert_eq!(text_of("**hi**  there", Some("<strong>hi</strong>\nthere")), "hi there");
        assert_eq!(text_of("plain  body\n", None), "plain body");
    }
}
