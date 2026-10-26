//! How a conversation's rows sit on screen, decided once for every platform: which bubbles form
//! a run, where a time header goes after a pause, which notes fold together, and where
//! "Delivered" and "Read" appear. Pure functions over rows, ordered oldest first.

use std::collections::{HashMap, HashSet};

use chrono::{Local, TimeZone};

use super::{Delivery, NoteLine, Reader, RunPosition, Seen, TimelineMessage, TimelineRow, rows::People};

/// Messages from one sender this close together read as one run of bubbles.
pub(crate) const RUN_GAP_MS: i64 = 5 * 60_000;
/// After a pause this long, a time header ("Today 9:41 AM") goes above the next message.
pub(crate) const SESSION_GAP_MS: i64 = 60 * 60_000;
/// Runs of this many notes or more fold into one line until expanded.
pub(crate) const COLLAPSE_AT: usize = 3;

/// A row before layout: what the timeline says, without placement.
#[derive(Debug, Clone)]
pub(crate) enum Raw {
    Message(Box<TimelineMessage>),
    Note(NoteLine),
    ReadMarker { id: String },
    Start { id: String },
}

impl Raw {
    fn timestamp(&self) -> Option<i64> {
        match self {
            Raw::Message(m) => Some(m.timestamp_ms),
            Raw::Note(n) => Some(n.timestamp_ms),
            _ => None,
        }
    }
}

fn local_day(ms: i64) -> Option<chrono::NaiveDate> {
    Local.timestamp_millis_opt(ms).single().map(|d| d.date_naive())
}

fn same_day(a: i64, b: i64) -> bool {
    local_day(a) == local_day(b)
}

/// Whether `b` continues `a`'s run: same sender, close together, and neither a reply nor a
/// thread root (those stand on their own so their quote or summary isn't lost in a run).
fn continues(a: &TimelineMessage, b: &TimelineMessage) -> bool {
    a.sender_id == b.sender_id
        && b.reply.is_none()
        && a.thread.is_none()
        && b.thread.is_none()
        && (b.timestamp_ms - a.timestamp_ms).abs() < RUN_GAP_MS
}

/// Lays out rows: time headers at the start of each sitting, run positions, folded notes and
/// the delivery line. `is_group` shows sender names; `expanded` lists unfolded note groups.
pub(crate) fn lay_out(raw: Vec<Raw>, is_group: bool, expanded: &HashSet<String>, me: &str) -> Vec<TimelineRow> {
    let raw = tidy(raw);

    // 1. Time headers, and which rows start a sitting (a run can't cross one).
    let mut rows: Vec<(Raw, bool)> = Vec::with_capacity(raw.len());
    let mut previous: Option<i64> = None;
    for row in raw {
        let starts = match row.timestamp() {
            Some(ts) if ts > 0 => {
                let starts = previous.is_none_or(|p| ts - p >= SESSION_GAP_MS || !same_day(p, ts));
                previous = Some(ts);
                starts
            }
            _ => false,
        };
        rows.push((row, starts));
    }

    // 2. Run positions.
    let messages: Vec<Option<&TimelineMessage>> = rows
        .iter()
        .map(|(row, _)| match row {
            Raw::Message(m) => Some(m.as_ref()),
            _ => None,
        })
        .collect();
    let mut runs = Vec::with_capacity(rows.len());
    for i in 0..rows.len() {
        let Some(current) = messages[i] else {
            runs.push(None);
            continue;
        };
        let starts_here = rows[i].1;
        let is_first = starts_here || i == 0 || messages[i - 1].is_none_or(|prev| !continues(prev, current));
        let next_starts = rows.get(i + 1).is_some_and(|(_, s)| *s);
        let is_last =
            next_starts || messages.get(i + 1).copied().flatten().is_none_or(|next| !continues(current, next));
        runs.push(Some(RunPosition { is_first, is_last }));
    }

    // 3. Delivery: under my newest sent message, only when nobody has written since.
    let delivery_index = delivery_target(&messages);

    // 4. Assemble, folding runs of notes.
    let mut out = Vec::with_capacity(rows.len() + 8);
    let mut notes: Vec<NoteLine> = Vec::new();
    let flush = |notes: &mut Vec<NoteLine>, out: &mut Vec<TimelineRow>| {
        if notes.is_empty() {
            return;
        }
        let id = format!("notes:{}", notes[0].id);
        if notes.len() >= COLLAPSE_AT && !expanded.contains(&id) {
            out.push(TimelineRow::NoteGroup { id, notes: std::mem::take(notes) });
        } else {
            for note in notes.drain(..) {
                out.push(TimelineRow::Note { line: note });
            }
        }
    };
    for (index, ((row, starts), run)) in rows.into_iter().zip(runs).enumerate() {
        if starts {
            flush(&mut notes, &mut out);
            let ts = row.timestamp().unwrap_or_default();
            out.push(TimelineRow::Header { id: format!("header:{}", row_id(&row)), timestamp_ms: ts });
        }
        match row {
            Raw::Note(note) => notes.push(note),
            Raw::Message(mut message) => {
                flush(&mut notes, &mut out);
                if let Some(run) = run {
                    message.run = run;
                }
                message.show_sender = is_group && !message.is_own && message.run.is_first;
                if Some(index) == delivery_index {
                    let readers: Vec<Reader> = message.read_by.iter().filter(|r| r.user_id != me).cloned().collect();
                    message.delivery = Some(Delivery { is_read: !readers.is_empty(), readers });
                }
                out.push(TimelineRow::Message { message: *message });
            }
            Raw::ReadMarker { id } => {
                flush(&mut notes, &mut out);
                out.push(TimelineRow::ReadMarker { id });
            }
            Raw::Start { id } => {
                flush(&mut notes, &mut out);
                out.push(TimelineRow::Start { id });
            }
        }
    }
    flush(&mut notes, &mut out);
    out
}

/// Most people a run names; the count covers everyone, so a room of thousands stays light.
const SEEN_NAMES: usize = 8;

/// Marks who has read each run of messages, on its last message. `read_up_to` maps people to
/// the newest message they've read (their read receipt, or their own message after it).
/// `members` is how many are in the room, 0 when unknown. Neither I nor the run's sender count.
pub(crate) fn mark_seen(
    rows: &mut [TimelineRow],
    read_up_to: &HashMap<String, String>,
    members: u64,
    people: &People,
    me: &str,
) {
    let index: HashMap<&str, usize> = rows
        .iter()
        .enumerate()
        .filter_map(|(i, row)| match row {
            TimelineRow::Message { message } => Some((message.id.as_str(), i)),
            _ => None,
        })
        .collect();
    let mut positions: Vec<(&str, usize)> = read_up_to
        .iter()
        .filter(|(user, _)| user.as_str() != me)
        .filter_map(|(user, id)| index.get(id.as_str()).map(|&i| (user.as_str(), i)))
        .collect();
    if positions.is_empty() {
        return;
    }
    // By name, so faces keep their places as more people read.
    positions.sort_by_cached_key(|(user, _)| (people.name(user).to_lowercase(), user.to_string()));
    // How far the furthest reader got: runs after it have no readers to look for.
    let furthest = positions.iter().map(|(_, at)| *at).max().unwrap_or(0);

    for (i, row) in rows.iter_mut().enumerate().take(furthest + 1) {
        let TimelineRow::Message { message } = row else { continue };
        if !message.run.is_last || message.event_id.is_none() || message.send_state != crate::models::SendState::Sent {
            continue;
        }
        let sender = message.sender_id.as_str();
        let mut read = Vec::new();
        let mut count = 0u32;
        for (user, at) in &positions {
            if *at >= i && *user != sender {
                count += 1;
                if read.len() < SEEN_NAMES {
                    read.push(people.reader(user));
                }
            }
        }
        if count > 0 {
            // People who read and then left still count, so there are never fewer others than readers.
            let besides = if message.is_own { 1 } else { 2 };
            let others = u32::try_from(members.saturating_sub(besides)).unwrap_or(u32::MAX).max(count);
            message.seen = Some(Seen { read, read_count: count, others: if members == 0 { 0 } else { others } });
        }
    }
}

fn row_id(row: &Raw) -> &str {
    match row {
        Raw::Message(m) => &m.id,
        Raw::Note(n) => &n.id,
        Raw::ReadMarker { id } | Raw::Start { id } => id,
    }
}

fn delivery_target(messages: &[Option<&TimelineMessage>]) -> Option<usize> {
    let last_message = messages.iter().rposition(Option::is_some)?;
    let message = messages[last_message]?;
    (message.is_own && message.send_state == crate::models::SendState::Sent).then_some(last_message)
}

/// Drops markers with nothing to mark: a read marker with no new message from someone else
/// after it, and a start marker that isn't first.
fn tidy(raw: Vec<Raw>) -> Vec<Raw> {
    let last_from_others = raw.iter().rposition(|r| matches!(r, Raw::Message(m) if !m.is_own));
    let mut out = Vec::with_capacity(raw.len());
    for (i, row) in raw.into_iter().enumerate() {
        let keep = match &row {
            Raw::ReadMarker { .. } => last_from_others.is_some_and(|last| last > i),
            Raw::Start { .. } => out.is_empty(),
            _ => true,
        };
        if keep {
            out.push(row);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        content::Note,
        models::{SendState, UnreadKind},
        timeline::{MessageContent, ReplyPreview, ReplyState, ThreadSummary},
    };

    const MIN: i64 = 60_000;

    fn msg(id: &str, sender: &str, at: i64) -> Raw {
        Raw::Message(Box::new(TimelineMessage {
            id: id.into(),
            event_id: Some(format!("${id}")),
            sender_id: sender.into(),
            sender_name: sender.into(),
            sender_avatar_url: None,
            is_own: sender == "me",
            timestamp_ms: at,
            content: MessageContent::Deleted,
            is_edited: false,
            mentions_me: false,
            send_state: SendState::Sent,
            reactions: vec![],
            reply: None,
            thread: None,
            read_by: vec![],
            can_edit: false,
            can_reply: true,
            can_forward: true,
            can_redact: false,
            is_pinned: false,
            run: RunPosition { is_first: true, is_last: true },
            show_sender: false,
            delivery: None,
            seen: None,
            is_highlighted: false,
        }))
    }

    fn note(id: &str, at: i64) -> Raw {
        Raw::Note(NoteLine { id: id.into(), timestamp_ms: at, note: Note::EncryptionEnabled })
    }

    fn messages(rows: &[TimelineRow]) -> Vec<&TimelineMessage> {
        rows.iter()
            .filter_map(|r| match r {
                TimelineRow::Message { message } => Some(message),
                _ => None,
            })
            .collect()
    }

    // Noon today, so the tests never straddle midnight.
    fn noon() -> i64 {
        Local::now().date_naive().and_hms_opt(12, 0, 0).unwrap().and_local_timezone(Local).unwrap().timestamp_millis()
    }

    #[test]
    fn groups_runs_by_sender_and_time() {
        let t = noon();
        let rows = lay_out(
            vec![
                msg("a", "maya", t),
                msg("b", "maya", t + MIN),
                msg("c", "sam", t + 2 * MIN),
                msg("d", "maya", t + 20 * MIN),
            ],
            true,
            &HashSet::new(),
            "me",
        );
        let m = messages(&rows);
        assert_eq!(m[0].run, RunPosition { is_first: true, is_last: false });
        assert_eq!(m[1].run, RunPosition { is_first: false, is_last: true });
        assert_eq!(m[2].run, RunPosition { is_first: true, is_last: true });
        assert!(m[3].run.is_first);
        assert!(m[0].show_sender && !m[1].show_sender);
    }

    #[test]
    fn headers_after_an_hour() {
        let t = noon();
        let rows = lay_out(vec![msg("a", "maya", t - 3 * 60 * MIN), msg("b", "maya", t)], false, &HashSet::new(), "me");
        let headers = rows.iter().filter(|r| matches!(r, TimelineRow::Header { .. })).count();
        assert_eq!(headers, 2);
        // A header breaks a run even for the same sender.
        assert!(messages(&rows)[1].run.is_first);
    }

    #[test]
    fn a_new_day_starts_a_sitting_however_short_the_pause() {
        let just_after_midnight = Local::now()
            .date_naive()
            .and_hms_opt(0, 5, 0)
            .and_then(|t| t.and_local_timezone(Local).earliest())
            .expect("a local time")
            .timestamp_millis();
        let rows = lay_out(
            vec![msg("a", "maya", just_after_midnight - 15 * MIN), msg("b", "maya", just_after_midnight)],
            true,
            &HashSet::new(),
            "me",
        );
        assert_eq!(rows.iter().filter(|r| matches!(r, TimelineRow::Header { .. })).count(), 2);
        assert!(messages(&rows)[1].run.is_first && messages(&rows)[1].show_sender);
    }

    #[test]
    fn replies_thread_roots_and_the_read_marker_stand_alone() {
        let t = noon();
        let mut reply = msg("b", "maya", t + MIN);
        let Raw::Message(m) = &mut reply else { unreachable!() };
        m.reply = Some(ReplyPreview {
            event_id: "$a".into(),
            sender_id: None,
            sender_name: None,
            is_own: false,
            body: None,
            state: ReplyState::Loading,
        });
        let mut root = msg("c", "maya", t + 2 * MIN);
        let Raw::Message(m) = &mut root else { unreachable!() };
        m.thread = Some(ThreadSummary {
            reply_count: 1,
            unread: UnreadKind::None,
            latest_sender_id: None,
            latest_sender_name: None,
            latest_sender_avatar_url: None,
            latest_body: None,
            latest_timestamp_ms: None,
        });
        let raw = vec![
            msg("a", "maya", t),
            reply,
            root,
            msg("d", "maya", t + 3 * MIN),
            Raw::ReadMarker { id: "rm".into() },
            msg("e", "maya", t + 4 * MIN),
        ];
        let rows = lay_out(raw, true, &HashSet::new(), "me");
        let runs: Vec<(bool, bool)> = messages(&rows).iter().map(|m| (m.run.is_first, m.run.is_last)).collect();
        assert_eq!(runs, [(true, true), (true, true), (true, true), (true, true), (true, true)]);
    }

    #[test]
    fn folds_three_notes_unless_expanded() {
        let t = noon();
        let raw = vec![note("n1", t), note("n2", t), note("n3", t), msg("a", "maya", t)];
        let rows = lay_out(raw.clone(), false, &HashSet::new(), "me");
        assert!(rows.iter().any(|r| matches!(r, TimelineRow::NoteGroup { notes, .. } if notes.len() == 3)));
        let expanded: HashSet<String> = ["notes:n1".to_owned()].into();
        let rows = lay_out(raw, false, &expanded, "me");
        assert_eq!(rows.iter().filter(|r| matches!(r, TimelineRow::Note { .. })).count(), 3);
    }

    #[test]
    fn delivery_only_on_my_last_message() {
        let t = noon();
        let rows = lay_out(vec![msg("a", "me", t), msg("b", "me", t + MIN)], false, &HashSet::new(), "me");
        let m = messages(&rows);
        assert!(m[0].delivery.is_none());
        assert_eq!(m[1].delivery.as_ref().map(|d| d.is_read), Some(false));
        let rows = lay_out(vec![msg("a", "me", t), msg("b", "maya", t + MIN)], false, &HashSet::new(), "me");
        assert!(messages(&rows).iter().all(|m| m.delivery.is_none()));
    }

    #[test]
    fn read_marker_needs_something_new_after_it() {
        let t = noon();
        let rows = lay_out(
            vec![msg("a", "maya", t), Raw::ReadMarker { id: "rm".into() }, msg("b", "me", t + MIN)],
            false,
            &HashSet::new(),
            "me",
        );
        assert!(!rows.iter().any(|r| matches!(r, TimelineRow::ReadMarker { .. })));
        let rows =
            lay_out(vec![Raw::ReadMarker { id: "rm".into() }, msg("b", "maya", t + MIN)], false, &HashSet::new(), "me");
        assert!(rows.iter().any(|r| matches!(r, TimelineRow::ReadMarker { .. })));
    }

    fn readers(seen: &Option<Seen>) -> Vec<String> {
        seen.as_ref().map(|s| s.read.iter().map(|r| r.user_id.clone()).collect()).unwrap_or_default()
    }

    #[test]
    fn seen_counts_receipts_and_own_messages_per_run() {
        let t = noon();
        // My run (a, b), Sam's reply c, then my d. Maya's receipt is on b; Sam read through c by
        // sending it; nobody has read d.
        let mut rows = lay_out(
            vec![msg("a", "me", t), msg("b", "me", t + MIN), msg("c", "sam", t + 2 * MIN), msg("d", "me", t + 3 * MIN)],
            true,
            &HashSet::new(),
            "me",
        );
        let read_up_to: HashMap<String, String> =
            [("maya", "b"), ("sam", "c"), ("me", "d")].map(|(u, m)| (u.into(), m.into())).into();
        mark_seen(&mut rows, &read_up_to, 5, &People::default(), "me");
        let m = messages(&rows);
        assert_eq!(m[1].seen.as_ref().map(|s| (s.read_count, s.others)), Some((2, 4)), "my run: everyone but me");
        assert!(m[0].seen.is_none(), "only a run's last message says who read it");
        assert_eq!(readers(&m[1].seen), ["maya", "sam"]);
        assert!(m[2].seen.is_none(), "the sender doesn't count as reading their own run");
        assert!(m[3].seen.is_none());
    }

    #[test]
    fn seen_in_a_big_room_names_a_few_and_counts_everyone() {
        let t = noon();
        let mut rows = lay_out(vec![msg("a", "maya", t), msg("b", "me", t + MIN)], true, &HashSet::new(), "me");
        let read_up_to: HashMap<String, String> =
            (0..2_000).map(|n| (format!("user{n:04}"), "b".to_string())).collect();
        mark_seen(&mut rows, &read_up_to, 0, &People::default(), "me");
        let seen = messages(&rows)[1].seen.clone().expect("seen");
        assert_eq!((seen.read_count, seen.others), (2_000, 0), "an unknown room size stays unknown");
        assert_eq!(seen.read.len(), SEEN_NAMES);
        assert_eq!(seen.read[0].user_id, "user0000", "names come in a steady order");
        assert_eq!(messages(&rows)[0].seen.as_ref().map(|s| s.read_count), Some(2_000));
    }
}
