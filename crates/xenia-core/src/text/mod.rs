//! Pure text rules: rich text, mentions, emoji, search snippets, names and colors.
//!
//! Nothing here touches the network or the SDK's state, so all of it is unit tested and every
//! platform gets identical behavior.

mod compose;
mod rich;

use std::sync::LazyLock;

pub use compose::*;
use regex::Regex;
pub use rich::*;
use unicode_normalization::UnicodeNormalization;

// One emoji: a pictograph with its variation selector or skin tone, zero-width-joined parts
// (families), a flag built from regional indicators, or a keycap.
const EMOJI: &str = r"(?:\p{Regional_Indicator}{2}|\p{Extended_Pictographic}(?:\x{FE0F}|\p{Emoji_Modifier})*(?:\x{200D}\p{Extended_Pictographic}(?:\x{FE0F}|\p{Emoji_Modifier})*)*|[0-9#*]\x{FE0F}?\x{20E3})";

static ONLY_EMOJI: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(&format!(r"^\s*(?:{EMOJI}\s*){{1,3}}$")).expect("valid emoji pattern"));

/// A message of one to three emoji and nothing else, which Messages shows large, without a bubble.
#[uniffi::export]
pub fn is_jumbo_emoji(text: &str) -> bool {
    !text.is_empty() && text.chars().count() <= 40 && ONLY_EMOJI.is_match(text)
}

/// Lowercased with accents removed, so "Zoë" matches "zoe".
#[uniffi::export]
pub fn normalize_for_search(text: &str) -> String {
    text.nfd().filter(|c| !is_combining_mark(*c)).collect::<String>().to_lowercase()
}

fn is_combining_mark(c: char) -> bool {
    matches!(c as u32, 0x0300..=0x036F | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x20D0..=0x20FF | 0xFE20..=0xFE2F)
}

const SUFFIXES: [&str; 9] = ["jr", "sr", "ii", "iii", "iv", "v", "phd", "md", "esq"];

/// Up to two letters for an avatar without a photo: first and last word, skipping symbols,
/// suffixes ("III") and the "@" and server of a Matrix ID. "Christopher Montgomery-Wellington
/// III" is "CM"; "@maya:server" is "M".
#[uniffi::export]
pub fn initials(name: &str) -> String {
    let trimmed = name.trim().trim_start_matches(['@', '#', '!']);
    let plain = trimmed.split(':').next().unwrap_or(trimmed);
    let letters: Vec<char> = plain
        .split(|c: char| c.is_whitespace() || c == '.' || c == '_')
        .filter(|w| !w.is_empty() && !SUFFIXES.contains(&w.trim_end_matches('.').to_lowercase().as_str()))
        .filter_map(|w| w.chars().find(|c| c.is_alphanumeric()))
        .collect();
    let picked: String = match letters.as_slice() {
        [] => "?".to_owned(),
        [one] => one.to_string(),
        [first, .., last] => format!("{first}{last}"),
    };
    picked.to_uppercase()
}

/// How many person colors there are. Apps keep a palette of this size, in this order: red,
/// orange, green, teal, blue, indigo, purple, pink, brown. (Yellow, mint and cyan are left out:
/// white initials don't read on them.)
pub const AVATAR_COLOR_COUNT: u32 = 9;

/// A stable color for a person or room, from its ID, so everyone sees Maya in the same color on
/// every platform.
#[uniffi::export]
pub fn avatar_color_index(id: &str) -> u32 {
    // The same hash the first Xenia used (Java's String.hashCode over UTF-16), so colors carry
    // over for people who used it.
    let mut hash: i32 = 0;
    for unit in id.encode_utf16() {
        hash = hash.wrapping_mul(31).wrapping_add(unit as i32);
    }
    hash.unsigned_abs() % AVATAR_COLOR_COUNT
}

/// A first name for list previews: "Maya" from "Maya Okafor", "maya" from "@maya:server".
#[uniffi::export]
pub fn first_name(name: &str) -> String {
    if let Some(rest) = name.strip_prefix('@') {
        return rest.split(':').next().unwrap_or(rest).to_owned();
    }
    name.split_whitespace().next().unwrap_or(name).to_owned()
}

/// A run of search-result text, marked when it matches the query.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TextMark {
    pub text: String,
    pub is_match: bool,
}

fn query_terms(query: &str) -> Vec<String> {
    query.split_whitespace().map(regex::escape).collect()
}

/// Splits text into runs, marking every occurrence of any query word (ignoring case).
#[uniffi::export]
pub fn mark_matches(text: &str, query: &str) -> Vec<TextMark> {
    let terms = query_terms(query);
    let whole = || vec![TextMark { text: text.to_owned(), is_match: false }];
    if terms.is_empty() {
        return whole();
    }
    let Ok(pattern) = Regex::new(&format!("(?i)(?:{})", terms.join("|"))) else {
        return whole();
    };
    let mut out = Vec::new();
    let mut last = 0;
    for m in pattern.find_iter(text) {
        if m.start() > last {
            out.push(TextMark { text: text[last..m.start()].to_owned(), is_match: false });
        }
        out.push(TextMark { text: m.as_str().to_owned(), is_match: true });
        last = m.end();
    }
    if last < text.len() {
        out.push(TextMark { text: text[last..].to_owned(), is_match: false });
    }
    if out.is_empty() { whole() } else { out }
}

/// Starts the text a few words before the first match when the match would otherwise fall past
/// the visible lines, with an ellipsis so it reads as a quote from the middle.
#[uniffi::export]
pub fn search_snippet(text: &str, query: &str) -> String {
    const LEAD: usize = 40;
    let flat = crate::content::one_line(text);
    let terms = query_terms(query);
    if terms.is_empty() {
        return flat;
    }
    let Ok(pattern) = Regex::new(&format!("(?i){}", terms.join("|"))) else {
        return flat;
    };
    let Some(m) = pattern.find(&flat) else {
        return flat;
    };
    let chars_before = flat[..m.start()].chars().count();
    if chars_before <= LEAD {
        return flat;
    }
    // Back up about half the lead, to the start of a word.
    let target = flat.floor_char_boundary(m.start().saturating_sub(LEAD / 2));
    let from = flat[..target].rfind(' ').map_or(target, |i| i + 1);
    format!("…{}", &flat[from..])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jumbo_emoji() {
        assert!(is_jumbo_emoji("😀"));
        assert!(is_jumbo_emoji("👍🏽 🎉"));
        assert!(is_jumbo_emoji("👨‍👩‍👧"));
        assert!(is_jumbo_emoji("🇯🇵"));
        assert!(!is_jumbo_emoji("😀😀😀😀"));
        assert!(!is_jumbo_emoji("hi 😀"));
        assert!(!is_jumbo_emoji(""));
        assert!(!is_jumbo_emoji("123"));
    }

    #[test]
    fn normalizes_accents_and_case() {
        assert_eq!(normalize_for_search("Zoë Ångström"), "zoe angstrom");
    }

    #[test]
    fn initials_skip_suffixes_and_ids() {
        assert_eq!(initials("Christopher Montgomery-Wellington III"), "CM");
        assert_eq!(initials("@maya:localhost"), "M");
        assert_eq!(initials("maya okafor"), "MO");
        assert_eq!(initials("  "), "?");
        assert_eq!(initials("Émile Zola"), "ÉZ");
    }

    #[test]
    fn avatar_colors_follow_javas_string_hash() {
        // "hello".hashCode() is 99162322; this one's hash is i32::MIN, whose sign can't flip.
        assert_eq!(avatar_color_index("hello"), 99_162_322 % AVATAR_COLOR_COUNT);
        assert_eq!(avatar_color_index("polygenelubricants"), 2_147_483_648_u32 % AVATAR_COLOR_COUNT);
    }

    #[test]
    fn first_names() {
        assert_eq!(first_name("Maya Okafor"), "Maya");
        assert_eq!(first_name("@maya:localhost"), "maya");
    }

    #[test]
    fn marks_every_term() {
        let marks = mark_matches("Lunch at noon, lunch again", "LUNCH noon");
        let matched: Vec<_> = marks.iter().filter(|m| m.is_match).map(|m| m.text.as_str()).collect();
        assert_eq!(matched, vec!["Lunch", "noon", "lunch"]);
        assert_eq!(marks.iter().map(|m| m.text.as_str()).collect::<String>(), "Lunch at noon, lunch again");
    }

    #[test]
    fn snippet_starts_near_the_match() {
        let text = "This is a long message that goes on and on about many things before finally mentioning the word pineapple somewhere";
        let s = search_snippet(text, "pineapple");
        assert!(s.starts_with('…'));
        assert!(s.contains("pineapple"));
        assert_eq!(search_snippet("short pineapple", "pineapple"), "short pineapple");
    }
}
