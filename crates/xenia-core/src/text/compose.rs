//! Turning what someone typed into a Matrix message.
//!
//! The composer shows mentions as "@Maya Okafor". Sending turns each one into a permalink (which
//! clients draw as a pill) and lists the person in `m.mentions`, which is what makes it a ping.
//! The plain body reads naturally ("Thanks Maya Okafor") for clients and notifications that only
//! show plain text. Markdown is honored; "/me waves" becomes an emote.

use std::sync::LazyLock;

use regex::Regex;
use ruma::events::room::message::FormattedBody;

/// A person the composer inserted as a mention.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MentionRef {
    pub user_id: String,
    /// The name as it appears in the composer, without the "@".
    pub name: String,
}

/// A message ready to send.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ComposedMessage {
    /// The plain body.
    pub body: String,
    /// The HTML body, when the message has formatting or mentions.
    pub html: Option<String>,
    /// People pinged by this message (`m.mentions`). Declared even when empty, so other clients
    /// don't guess pings from the text.
    pub mentioned_user_ids: Vec<String>,
    /// "@room" pings everyone.
    pub mentions_room: bool,
    /// Sent as an emote ("/me waves").
    pub is_emote: bool,
}

static ROOM_MENTION: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(^|\s)@room\b").expect("valid pattern"));

fn escape_markdown(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        // A name is text, never markup: "<" and "&" would otherwise pass into the HTML.
        match c {
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '&' => out.push_str("&amp;"),
            '\\' | '[' | ']' | '(' | ')' | '*' | '_' | '`' | '~' => {
                out.push('\\');
                out.push(c);
            }
            _ => out.push(c),
        }
    }
    out
}

fn permalink(user_id: &str) -> String {
    format!("https://matrix.to/#/{user_id}")
}

/// Builds the message to send from the composer's text and the mentions it inserted. Only
/// mentions still present in the text count, so deleting "@Maya" also stops the ping.
#[uniffi::export]
pub fn compose_message(text: String, mentions: Vec<MentionRef>) -> ComposedMessage {
    let trimmed = text.trim();
    let (is_emote, source) = match trimmed.strip_prefix("/me ") {
        Some(rest) => (true, rest.trim_start()),
        None => (false, trimmed),
    };

    // Longest names first, so "@Sam Reyes" isn't split by a mention of "@Sam".
    let mut present: Vec<&MentionRef> =
        mentions.iter().filter(|m| !word_matches(source, &format!("@{}", m.name)).is_empty()).collect();
    present.sort_by_key(|m| std::cmp::Reverse(m.name.chars().count()));

    let mut markdown = source.to_owned();
    let mut body = source.to_owned();
    let mut used: Vec<&MentionRef> = Vec::new();
    let mut user_ids: Vec<String> = Vec::new();
    for mention in present {
        let token = format!("@{}", mention.name);
        // Still there once longer names have taken theirs ("@Sam" inside "@Sam Reyes" isn't),
        // and only as a whole word ("@Sam" isn't in "@Samantha").
        let marker = format!("\u{E000}{}\u{E001}", used.len());
        let (marked, found) = replace_words(&markdown, &token, &marker);
        if found == 0 {
            continue;
        }
        // Placeholders keep a later, shorter name from matching inside an inserted link.
        markdown = marked;
        body = replace_words(&body, &token, &mention.name).0;
        if !user_ids.contains(&mention.user_id) {
            user_ids.push(mention.user_id.clone());
        }
        used.push(mention);
    }
    for (index, mention) in used.iter().enumerate() {
        let marker = format!("\u{E000}{index}\u{E001}");
        let link = format!("[{}]({})", escape_markdown(&mention.name), permalink(&mention.user_id));
        markdown = markdown.replace(&marker, &link);
    }
    let html = FormattedBody::markdown(&markdown).map(|f| f.body.trim_end().to_owned()).or_else(|| {
        // Markdown found nothing to format, but mentions still need their links.
        (!used.is_empty()).then(|| html_with_links(source, &used))
    });

    ComposedMessage { body, html, mentioned_user_ids: user_ids, mentions_room: ROOM_MENTION.is_match(source), is_emote }
}

/// Escaped HTML of `source` with each mention as an anchor, for when markdown produced no HTML.
fn html_with_links(source: &str, present: &[&MentionRef]) -> String {
    let mut marked = source.to_owned();
    for (index, mention) in present.iter().enumerate() {
        marked = replace_words(&marked, &format!("@{}", mention.name), &format!("\u{E000}{index}\u{E001}")).0;
    }
    let mut html = escape_html(&marked).replace('\n', "<br>");
    for (index, mention) in present.iter().enumerate() {
        let anchor = format!("<a href=\"{}\">{}</a>", permalink(&mention.user_id), escape_html(&mention.name));
        html = html.replace(&format!("\u{E000}{index}\u{E001}"), &anchor);
    }
    html
}

fn escape_html(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// One of my messages, back in the composer to be edited.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EditableText {
    pub text: String,
    pub mentions: Vec<MentionRef>,
}

/// Where `needle` appears in `text` as a whole word: nothing alphanumeric right before or after.
fn word_matches(text: &str, needle: &str) -> Vec<usize> {
    let is_word = |c: Option<char>| c.is_some_and(char::is_alphanumeric);
    text.match_indices(needle)
        .filter(|(at, _)| {
            !is_word(text[..*at].chars().next_back()) && !is_word(text[at + needle.len()..].chars().next())
        })
        .map(|(at, _)| at)
        .collect()
}

/// `text` with every whole-word `needle` replaced, and how many there were.
fn replace_words(text: &str, needle: &str, with: &str) -> (String, usize) {
    let found = word_matches(text, needle);
    let mut out = String::with_capacity(text.len());
    let mut from = 0;
    for &at in &found {
        out.push_str(&text[from..at]);
        out.push_str(with);
        from = at + needle.len();
    }
    out.push_str(&text[from..]);
    (out, found.len())
}

/// What the composer shows to edit a message: its text as typed (the plain body keeps the
/// markdown), with each pill back as "@Name" so it stays a mention, and "/me" for an emote.
///
/// The body carries no record of where its pills were, so they're found by order: the third
/// "Sam" in the formatted text is the pill, so the third whole-word "Sam" in the body gets the
/// "@". Other uses of the name stay plain words.
pub(crate) fn editable_text(body: &str, html: Option<&str>, is_emote: bool) -> EditableText {
    let body = body.trim();
    let spans: Vec<crate::text::RichSpan> = html
        .map(|html| crate::text::parse_html(html).iter().flat_map(|b| b.spans().to_vec()).collect())
        .unwrap_or_default();
    let pill_name = |span: &crate::text::RichSpan| span.text.trim().trim_start_matches('@').to_owned();
    let mut names: Vec<String> = spans.iter().filter(|s| s.mention.is_some()).map(pill_name).collect();
    names.retain(|n| !n.is_empty());
    names.sort();
    names.dedup();

    // Each pill as (name, which whole-word occurrence of the name it is).
    let mut seen: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
    let mut pills: Vec<(String, String, usize)> = Vec::new();
    for span in &spans {
        let own = span.mention.as_ref().map(|_| pill_name(span));
        for name in &names {
            let count = seen.entry(name.as_str()).or_default();
            if own.as_deref() == Some(name.as_str()) {
                pills.push((span.mention.clone().unwrap_or_default(), name.clone(), *count));
                *count += 1;
            } else {
                *count += word_matches(&span.text, name).len();
            }
        }
    }

    let mut inserts: Vec<usize> = Vec::new();
    let mut mentions: Vec<MentionRef> = Vec::new();
    for (user_id, name, index) in pills {
        let Some(&at) = word_matches(body, &name).get(index) else { continue };
        if !body[..at].ends_with('@') {
            inserts.push(at);
        }
        let mention = MentionRef { user_id, name };
        if !mentions.contains(&mention) {
            mentions.push(mention);
        }
    }
    inserts.sort_unstable();
    inserts.dedup();
    let mut text = body.to_owned();
    for at in inserts.into_iter().rev() {
        text.insert(at, '@');
    }
    if is_emote {
        text = format!("/me {text}");
    }
    EditableText { text, mentions }
}

/// The mention being typed at the end of `text_before_cursor`: what follows the "@" (possibly
/// empty, right after typing "@"). `None` when the cursor isn't in a mention.
#[uniffi::export]
pub fn mention_query(text_before_cursor: &str) -> Option<String> {
    static PARTIAL: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"(?:^|\s)@([\p{L}\p{N}._-]{0,32})$").expect("valid pattern"));
    PARTIAL.captures(text_before_cursor).map(|c| c[1].to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn maya() -> MentionRef {
        MentionRef { user_id: "@maya:localhost".into(), name: "Maya Okafor".into() }
    }

    #[test]
    fn plain_text_has_no_html() {
        let m = compose_message("hello there".into(), vec![]);
        assert_eq!(m.body, "hello there");
        assert_eq!(m.html, None);
        assert!(!m.is_emote);
    }

    #[test]
    fn markdown_becomes_html() {
        let m = compose_message("some **bold** text".into(), vec![]);
        assert_eq!(m.body, "some **bold** text");
        assert!(m.html.unwrap().contains("<strong>bold</strong>"));
    }

    #[test]
    fn mentions_become_pills() {
        let m = compose_message("Thanks @Maya Okafor!".into(), vec![maya()]);
        assert_eq!(m.body, "Thanks Maya Okafor!");
        assert_eq!(m.mentioned_user_ids, vec!["@maya:localhost".to_owned()]);
        let html = m.html.unwrap();
        assert!(html.contains("href=\"https://matrix.to/#/@maya:localhost\""), "{html}");
        assert!(html.contains(">Maya Okafor</a>"), "{html}");
    }

    #[test]
    fn names_never_become_markup() {
        let bob = MentionRef { user_id: "@bob:localhost".into(), name: "Bob</a><a href=\"https://evil\">".into() };
        let m = compose_message(format!("Hi @{}", bob.name), vec![bob]);
        let html = m.html.unwrap();
        assert!(!html.contains("<a href=\"https://evil"), "{html}");
        assert!(html.contains("matrix.to/#/@bob:localhost"), "{html}");
    }

    #[test]
    fn deleted_mentions_do_not_ping() {
        let m = compose_message("Thanks!".into(), vec![maya()]);
        assert!(m.mentioned_user_ids.is_empty());
        assert_eq!(m.html, None);
    }

    #[test]
    fn longer_names_win() {
        let sam = MentionRef { user_id: "@sam:localhost".into(), name: "Sam".into() };
        let sam_reyes = MentionRef { user_id: "@samr:localhost".into(), name: "Sam Reyes".into() };
        let m = compose_message("@Sam Reyes and @Sam".into(), vec![sam.clone(), sam_reyes.clone()]);
        assert_eq!(m.body, "Sam Reyes and Sam");
        assert_eq!(m.mentioned_user_ids, vec!["@samr:localhost".to_owned(), "@sam:localhost".to_owned()]);
        // A mention is a whole word: "@Samantha" doesn't mention Sam.
        let m = compose_message("@Samantha and @Sam".into(), vec![sam.clone()]);
        assert_eq!(m.body, "@Samantha and Sam");
        // "@Sam" deleted: the only "@Sam" left is inside "@Sam Reyes", so Sam isn't pinged.
        let m = compose_message("hi @Sam Reyes".into(), vec![sam, sam_reyes]);
        assert_eq!(m.mentioned_user_ids, vec!["@samr:localhost".to_owned()]);
        let html = m.html.unwrap();
        assert!(html.contains(">Sam Reyes</a>") && !html.contains("@sam:localhost\""), "{html}");
    }

    #[test]
    fn edits_start_from_what_was_sent() {
        // What compose_message sends comes back as it was typed: markdown, pills and "/me".
        let sent = compose_message("Thanks **@Maya Okafor**, see `docs`".into(), vec![maya()]);
        let editable = editable_text(&sent.body, sent.html.as_deref(), false);
        assert_eq!(editable.text, "Thanks **@Maya Okafor**, see `docs`");
        assert_eq!(editable.mentions, vec![maya()]);
        let resent = compose_message(editable.text, editable.mentions);
        assert_eq!(resent.html, sent.html);
        assert_eq!(resent.mentioned_user_ids, sent.mentioned_user_ids);

        let emote = compose_message("/me waves".into(), vec![]);
        assert_eq!(editable_text(&emote.body, emote.html.as_deref(), true).text, "/me waves");
        // A name that's also a plain word elsewhere: only the pill becomes a mention again,
        // wherever it was, and a longer word that starts with the name is left alone.
        let sent = compose_message("Maya Okafor met @Maya Okafor".into(), vec![maya()]);
        assert_eq!(editable_text(&sent.body, sent.html.as_deref(), false).text, "Maya Okafor met @Maya Okafor");
        let sam = MentionRef { user_id: "@sam:localhost".into(), name: "Sam".into() };
        let sent = compose_message("Samantha, ask @Sam".into(), vec![sam.clone()]);
        assert_eq!(sent.body, "Samantha, ask Sam");
        let editable = editable_text(&sent.body, sent.html.as_deref(), false);
        assert_eq!(editable.text, "Samantha, ask @Sam");
        assert_eq!(compose_message(editable.text, editable.mentions).html, sent.html);
    }

    #[test]
    fn emotes_and_room_mentions() {
        let m = compose_message("/me waves at @room".into(), vec![]);
        assert!(m.is_emote);
        assert!(m.mentions_room);
        assert_eq!(m.body, "waves at @room");
    }

    #[test]
    fn mention_queries() {
        assert_eq!(mention_query("hey @ma"), Some("ma".into()));
        assert_eq!(mention_query("@"), Some(String::new()));
        assert_eq!(mention_query("email@ma"), None);
        assert_eq!(mention_query("hey @maya "), None);
    }
}
