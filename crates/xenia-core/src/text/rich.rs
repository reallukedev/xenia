//! Message text as blocks of styled spans.
//!
//! Matrix messages carry a plain body and, often, an HTML body. Xenia shows the parts people use
//! (emphasis, code, links, mention pills, quotes, lists, headings) and turns everything else into
//! plain text, never markup on screen. Plain bodies go through the same shape, with their links
//! found, so an app renders every text message one way.

use std::sync::LazyLock;

use matrix_sdk::ruma::{MatrixToUri, MatrixUri, matrix_uri::MatrixId};
use regex::Regex;
use ruma::html::{Html, NodeData, NodeRef};

/// A run of text with one style.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct RichSpan {
    pub text: String,
    pub bold: bool,
    pub italic: bool,
    pub strike: bool,
    pub code: bool,
    /// An http(s) or mailto link.
    pub link: Option<String>,
    /// A person mentioned with a pill: their Matrix ID.
    pub mention: Option<String>,
}

impl RichSpan {
    fn plain(text: impl Into<String>) -> Self {
        Self { text: text.into(), ..Self::default() }
    }

    fn same_style(&self, other: &Style) -> bool {
        self.bold == other.bold
            && self.italic == other.italic
            && self.strike == other.strike
            && self.code == other.code
            && self.link == other.link
            && self.mention == other.mention
    }
}

/// One block of a message.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum RichBlock {
    Paragraph {
        spans: Vec<RichSpan>,
    },
    /// `level` is 1 to 6, as in HTML.
    Heading {
        level: u8,
        spans: Vec<RichSpan>,
    },
    Quote {
        spans: Vec<RichSpan>,
    },
    Code {
        text: String,
        language: Option<String>,
    },
    /// `marker` is "•" or "3."; `depth` is 0 for a top-level item.
    ListItem {
        marker: String,
        depth: u8,
        spans: Vec<RichSpan>,
    },
    /// A horizontal rule.
    Rule,
}

impl RichBlock {
    pub(crate) fn spans(&self) -> &[RichSpan] {
        match self {
            Self::Paragraph { spans }
            | Self::Heading { spans, .. }
            | Self::Quote { spans }
            | Self::ListItem { spans, .. } => spans,
            Self::Code { .. } | Self::Rule => &[],
        }
    }
}

#[derive(Debug, Clone, Default)]
struct Style {
    bold: bool,
    italic: bool,
    strike: bool,
    code: bool,
    link: Option<String>,
    mention: Option<String>,
}

struct ListState {
    ordered: bool,
    next: u32,
}

#[derive(Default)]
struct Builder {
    blocks: Vec<RichBlock>,
    spans: Vec<RichSpan>,
    quote_depth: u32,
    heading: Option<u8>,
    lists: Vec<ListState>,
    item: Option<(String, u8)>,
    /// Elements open around the one being read.
    depth: usize,
}

/// Deeper than any real message nests. Past it the rest reads as plain text, so a message built
/// to nest thousands deep can't exhaust the stack.
const MAX_DEPTH: usize = 64;

impl Builder {
    fn push_text(&mut self, raw: &str, style: &Style) {
        // HTML collapses whitespace; line breaks come from <br> and blocks.
        let collapsed = collapse_whitespace(raw);
        if collapsed.is_empty() {
            return;
        }
        // Text outside a link still gets its URLs found.
        if style.link.is_none() && style.mention.is_none() && !style.code {
            for segment in linkify(&collapsed) {
                let mut s = style.clone();
                s.link = segment.url;
                self.push_styled(&segment.text, &s);
            }
        } else {
            self.push_styled(&collapsed, style);
        }
    }

    fn push_styled(&mut self, text: &str, style: &Style) {
        if let Some(last) = self.spans.last_mut()
            && last.same_style(style)
        {
            // Two spaces in a row across a tag boundary read as one.
            if last.text.ends_with(' ') && text.starts_with(' ') {
                last.text.push_str(&text[1..]);
            } else {
                last.text.push_str(text);
            }
            return;
        }
        let text = if self.spans.last().is_some_and(|s| s.text.ends_with(' ')) && text.starts_with(' ') {
            &text[1..]
        } else {
            text
        };
        if text.is_empty() {
            return;
        }
        self.spans.push(RichSpan {
            text: text.to_owned(),
            bold: style.bold,
            italic: style.italic,
            strike: style.strike,
            code: style.code,
            link: style.link.clone(),
            mention: style.mention.clone(),
        });
    }

    fn line_break(&mut self) {
        if let Some(last) = self.spans.last_mut() {
            while last.text.ends_with(' ') {
                last.text.pop();
            }
            // A pill or link ends where its words do.
            if last.link.is_none() && last.mention.is_none() {
                last.text.push('\n');
                return;
            }
        }
        self.spans.push(RichSpan::plain("\n"));
    }

    fn flush(&mut self) {
        let mut spans = std::mem::take(&mut self.spans);
        trim_edges(&mut spans);
        if spans.is_empty() {
            // An item's first line may still be coming (`<li><p>one</p></li>`).
            return;
        }
        let block = if let Some((marker, depth)) = self.item.take() {
            RichBlock::ListItem { marker, depth, spans }
        } else if let Some(level) = self.heading {
            RichBlock::Heading { level, spans }
        } else if self.quote_depth > 0 {
            RichBlock::Quote { spans }
        } else {
            RichBlock::Paragraph { spans }
        };
        self.blocks.push(block);
    }

    fn walk(&mut self, node: &NodeRef, style: &Style) {
        match node.data() {
            NodeData::Text(text) => self.push_text(&text.borrow(), style),
            NodeData::Element(_) if self.depth >= MAX_DEPTH => {
                let mut text = String::new();
                collect_text(node, &mut text);
                self.push_text(&text, style);
            }
            NodeData::Element(element) => {
                let tag = element.name.local.to_string().to_ascii_lowercase();
                let attr = |name: &str| {
                    element
                        .attrs
                        .borrow()
                        .iter()
                        .find(|a| a.name.local.as_ref().eq_ignore_ascii_case(name))
                        .map(|a| a.value.to_string())
                };
                self.depth += 1;
                self.element(node, &tag, attr, style);
                self.depth -= 1;
            }
            NodeData::Document => self.walk_children(node, style),
            NodeData::Other => {}
        }
    }

    fn walk_children(&mut self, node: &NodeRef, style: &Style) {
        for child in node.children() {
            self.walk(&child, style);
        }
    }

    fn element(&mut self, node: &NodeRef, tag: &str, attr: impl Fn(&str) -> Option<String>, style: &Style) {
        let styled = |f: &dyn Fn(&mut Style)| {
            let mut s = style.clone();
            f(&mut s);
            s
        };
        match tag {
            // Replies carry a quote of the original; the app shows its own.
            "mx-reply" | "script" | "style" | "head" => {}
            "br" => self.line_break(),
            "hr" => {
                self.flush();
                self.blocks.push(RichBlock::Rule);
            }
            "p" | "div" | "tr" | "table" | "details" | "summary" => {
                self.flush();
                self.walk_children(node, style);
                self.flush();
            }
            "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
                self.flush();
                self.heading = tag[1..].parse().ok();
                self.walk_children(node, style);
                self.flush();
                self.heading = None;
            }
            "blockquote" => {
                self.flush();
                self.quote_depth += 1;
                self.walk_children(node, style);
                self.flush();
                self.quote_depth -= 1;
            }
            "pre" => {
                self.flush();
                let mut text = String::new();
                collect_text(node, &mut text);
                let language = code_language(node);
                let text = text.trim_end_matches('\n').to_owned();
                if !text.is_empty() {
                    self.blocks.push(RichBlock::Code { text, language });
                }
            }
            "ul" | "ol" => {
                self.flush();
                let start = attr("start").and_then(|s| s.trim().parse::<u32>().ok()).unwrap_or(1);
                self.lists.push(ListState { ordered: tag == "ol", next: start });
                self.walk_children(node, style);
                self.flush();
                self.lists.pop();
            }
            "li" => {
                self.flush();
                let depth = u8::try_from(self.lists.len().saturating_sub(1)).unwrap_or(u8::MAX);
                let marker = match self.lists.last_mut() {
                    Some(list) if list.ordered => {
                        let n = list.next;
                        list.next = list.next.saturating_add(1);
                        format!("{n}.")
                    }
                    _ => "•".to_owned(),
                };
                // A nested list inside the item flushes the item's own line first.
                self.item = Some((marker, depth));
                self.walk_children(node, style);
                self.flush();
                // An empty item mustn't lend its marker to what follows the list.
                self.item = None;
            }
            "strong" | "b" => self.walk_children(node, &styled(&|s| s.bold = true)),
            "em" | "i" => self.walk_children(node, &styled(&|s| s.italic = true)),
            "del" | "s" | "strike" => self.walk_children(node, &styled(&|s| s.strike = true)),
            "code" => self.walk_children(node, &styled(&|s| s.code = true)),
            "a" => {
                let href = attr("href").map(|h| h.trim().to_owned()).unwrap_or_default();
                let next = if let Some(user) = mentioned_user(&href) {
                    styled(&|s| {
                        s.mention = Some(user.clone());
                        s.link = None;
                    })
                } else if is_safe_link(&href) {
                    styled(&|s| s.link = Some(href.clone()))
                } else {
                    style.clone()
                };
                self.walk_children(node, &next);
            }
            // Custom emoji and inline images: their alt text reads in place.
            "img" => {
                if let Some(alt) = attr("alt").or_else(|| attr("title")) {
                    self.push_text(&alt, style);
                }
            }
            _ => self.walk_children(node, style),
        }
    }
}

/// Every text node under `node`, in order. Walked with a stack of its own rather than by
/// recursion, however deep the elements nest.
fn collect_text(node: &NodeRef, out: &mut String) {
    let mut pending: Vec<NodeRef> = node.children().collect();
    pending.reverse();
    while let Some(child) = pending.pop() {
        match child.data() {
            NodeData::Text(text) => out.push_str(&text.borrow()),
            NodeData::Element(e) if e.name.local.as_ref().eq_ignore_ascii_case("br") => out.push('\n'),
            _ => pending.extend(child.children().collect::<Vec<_>>().into_iter().rev()),
        }
    }
}

fn code_language(pre: &NodeRef) -> Option<String> {
    let code = pre.children().find(|c| c.as_element().is_some_and(|e| e.name.local.as_ref() == "code"))?;
    let element = code.as_element()?;
    let attrs = element.attrs.borrow();
    let class = attrs.iter().find(|a| a.name.local.as_ref() == "class")?;
    class.value.split_whitespace().find_map(|c| c.strip_prefix("language-")).map(str::to_owned)
}

fn collapse_whitespace(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut in_space = false;
    for ch in text.chars() {
        if ch.is_whitespace() && ch != '\u{a0}' {
            if !in_space {
                out.push(' ');
            }
            in_space = true;
        } else {
            out.push(ch);
            in_space = false;
        }
    }
    out
}

fn trim_edges(spans: &mut Vec<RichSpan>) {
    while spans.first().is_some_and(|s| s.text.trim().is_empty()) {
        spans.remove(0);
    }
    while spans.last().is_some_and(|s| s.text.trim().is_empty()) {
        spans.pop();
    }
    if let Some(first) = spans.first_mut() {
        first.text = first.text.trim_start().to_owned();
    }
    if let Some(last) = spans.last_mut() {
        last.text = last.text.trim_end().to_owned();
    }
}

fn is_safe_link(href: &str) -> bool {
    let lower = href.to_ascii_lowercase();
    lower.starts_with("https://") || lower.starts_with("http://") || lower.starts_with("mailto:")
}

/// The user ID in a permalink to a person (matrix.to or matrix: URI), if it is one.
pub fn mentioned_user(href: &str) -> Option<String> {
    let href = href.trim();
    if let Ok(uri) = MatrixToUri::parse(href)
        && let MatrixId::User(user) = uri.id()
    {
        return Some(user.to_string());
    }
    if let Ok(uri) = MatrixUri::parse(href)
        && let MatrixId::User(user) = uri.id()
    {
        return Some(user.to_string());
    }
    None
}

/// Parses a formatted (HTML) body into blocks.
pub fn parse_html(html: &str) -> Vec<RichBlock> {
    let document = Html::parse(html);
    let mut builder = Builder::default();
    let style = Style::default();
    for child in document.children() {
        builder.walk(&child, &style);
    }
    builder.flush();
    builder.blocks
}

/// A plain body as one paragraph, with its links found. Line breaks are kept as they were typed.
pub fn plain_blocks(text: &str) -> Vec<RichBlock> {
    let trimmed = text.trim_matches(|c: char| c == '\n' || c == ' ');
    if trimmed.is_empty() {
        return Vec::new();
    }
    let spans =
        linkify(trimmed).into_iter().map(|s| RichSpan { text: s.text, link: s.url, ..RichSpan::default() }).collect();
    vec![RichBlock::Paragraph { spans }]
}

/// Everyone a message mentions with a pill.
pub fn mentions_in(blocks: &[RichBlock]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for span in blocks.iter().flat_map(RichBlock::spans) {
        if let Some(user) = &span.mention
            && !out.contains(user)
        {
            out.push(user.clone());
        }
    }
    out
}

/// The words of a formatted message without its markup: for previews, notifications and Copy.
pub fn plain_text(blocks: &[RichBlock]) -> String {
    blocks
        .iter()
        .filter_map(|block| match block {
            RichBlock::Code { text, .. } => Some(text.clone()),
            RichBlock::Rule => None,
            RichBlock::ListItem { marker, spans, .. } => Some(format!("{marker} {}", join_spans(spans))),
            other => Some(join_spans(other.spans())),
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn join_spans(spans: &[RichSpan]) -> String {
    spans.iter().map(|s| s.text.as_str()).collect()
}

/// A piece of text, and the address it links to if it's a link.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TextSegment {
    pub text: String,
    pub url: Option<String>,
}

static URL: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"(?i)\b(?:https?://|www\.)[^\s<>"]+"#).expect("valid URL pattern"));
static TRAILING: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"[.,;:!?'")\]}]+$"#).expect("valid pattern"));

/// Splits text into plain runs and links. Trailing punctuation belongs to the sentence, not the
/// link, except a closing parenthesis whose opening one is inside the link (Wikipedia URLs).
#[uniffi::export]
pub fn linkify(text: &str) -> Vec<TextSegment> {
    let mut out = Vec::new();
    let mut last = 0;
    for m in URL.find_iter(text) {
        let mut raw = m.as_str();
        if let Some(trailing) = TRAILING.find(raw) {
            let t = trailing.as_str();
            if t.starts_with(')') && raw[..trailing.start()].contains('(') {
                raw = &raw[..trailing.start() + 1];
            } else {
                raw = &raw[..trailing.start()];
            }
        }
        // Punctuation trimmed away everything after the scheme ("http://." or "www.."): no link.
        let lower = raw.to_ascii_lowercase();
        let address = ["https://", "http://", "www."].iter().find_map(|prefix| lower.strip_prefix(prefix));
        if address.is_none_or(str::is_empty) {
            continue;
        }
        if m.start() > last {
            out.push(TextSegment { text: text[last..m.start()].to_owned(), url: None });
        }
        let url = if lower.starts_with("www.") { format!("https://{raw}") } else { raw.to_owned() };
        out.push(TextSegment { text: raw.to_owned(), url: Some(url) });
        last = m.start() + raw.len();
    }
    if last < text.len() {
        out.push(TextSegment { text: text[last..].to_owned(), url: None });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn para(spans: Vec<RichSpan>) -> RichBlock {
        RichBlock::Paragraph { spans }
    }

    #[test]
    fn parses_emphasis_and_links() {
        let blocks = parse_html("Hello <b>bold</b> and <a href=\"https://example.org\">a link</a>");
        assert_eq!(
            blocks,
            vec![para(vec![
                RichSpan::plain("Hello "),
                RichSpan { text: "bold".into(), bold: true, ..Default::default() },
                RichSpan::plain(" and "),
                RichSpan { text: "a link".into(), link: Some("https://example.org".into()), ..Default::default() },
            ])]
        );
    }

    #[test]
    fn hostile_html_reads_as_text_instead_of_crashing() {
        // Thousands of nested elements once overflowed the stack, aborting the app whenever the
        // message was a room's latest.
        let depth = 3_000;
        let html = format!("{}deep{}", "<div><b>".repeat(depth), "</b></div>".repeat(depth));
        assert_eq!(plain_text(&parse_html(&html)), "deep");
        let pre = format!("<pre>{}code{}</pre>", "<span>".repeat(depth), "</span>".repeat(depth));
        assert_eq!(parse_html(&pre), vec![RichBlock::Code { text: "code".into(), language: None }]);
        // A list numbered from the largest start stays at it rather than overflowing.
        let markers: Vec<String> = parse_html("<ol start=\"4294967295\"><li>a</li><li>b</li></ol>")
            .into_iter()
            .filter_map(|b| match b {
                RichBlock::ListItem { marker, .. } => Some(marker),
                _ => None,
            })
            .collect();
        assert_eq!(markers, vec!["4294967295.", "4294967295."]);
    }

    #[test]
    fn turns_permalinks_into_mentions() {
        let blocks = parse_html("Hi <a href=\"https://matrix.to/#/@maya:localhost\">Maya</a>!");
        assert_eq!(mentions_in(&blocks), vec!["@maya:localhost".to_owned()]);
        assert_eq!(plain_text(&blocks), "Hi Maya!");
    }

    #[test]
    fn drops_reply_fallbacks() {
        let blocks = parse_html("<mx-reply><blockquote>old</blockquote></mx-reply>new");
        assert_eq!(plain_text(&blocks), "new");
    }

    #[test]
    fn numbers_ordered_lists_from_start() {
        let blocks = parse_html("<ol start=\"3\"><li>three</li><li>four</li></ol>");
        assert!(matches!(&blocks[0], RichBlock::ListItem { marker, depth: 0, .. } if marker == "3."));
        assert!(matches!(&blocks[1], RichBlock::ListItem { marker, .. } if marker == "4."));
    }

    #[test]
    fn loose_list_items_keep_their_markers() {
        // Markdown with blank lines between items wraps each one in a paragraph.
        let blocks = parse_html("<ul><li><p>one</p></li><li><p>two</p></li></ul>");
        assert_eq!(
            blocks,
            vec![
                RichBlock::ListItem { marker: "•".into(), depth: 0, spans: vec![RichSpan::plain("one")] },
                RichBlock::ListItem { marker: "•".into(), depth: 0, spans: vec![RichSpan::plain("two")] },
            ]
        );
    }

    #[test]
    fn line_breaks_stay_out_of_pills_and_links() {
        let blocks = parse_html("<a href=\"https://matrix.to/#/@maya:x\">Maya</a><br>hi");
        let RichBlock::Paragraph { spans } = &blocks[0] else { panic!("{blocks:?}") };
        assert_eq!(spans[0].text, "Maya");
        assert_eq!(spans[1], RichSpan::plain("\nhi"));
    }

    #[test]
    fn keeps_code_blocks_verbatim() {
        let blocks = parse_html("<pre><code class=\"language-rust\">fn main() {\n    run();\n}\n</code></pre>");
        assert_eq!(
            blocks,
            vec![RichBlock::Code { text: "fn main() {\n    run();\n}".into(), language: Some("rust".into()) }]
        );
    }

    #[test]
    fn decodes_entities_and_ignores_unsafe_links() {
        let blocks = parse_html("a &amp; b <a href=\"javascript:alert(1)\">x</a>");
        assert_eq!(blocks, vec![para(vec![RichSpan::plain("a & b x")])]);
    }

    #[test]
    fn keeps_line_breaks() {
        let blocks = parse_html("one<br>two<br/>three");
        assert_eq!(plain_text(&blocks), "one\ntwo\nthree");
    }

    #[test]
    fn quotes_and_headings() {
        let blocks = parse_html("<h2>Title</h2><blockquote><p>quoted</p></blockquote>");
        assert!(matches!(&blocks[0], RichBlock::Heading { level: 2, .. }));
        assert!(matches!(&blocks[1], RichBlock::Quote { .. }));
    }

    #[test]
    fn linkify_trims_sentence_punctuation() {
        let segments = linkify("See https://example.org/a. Or (www.example.com).");
        assert_eq!(segments[1].url.as_deref(), Some("https://example.org/a"));
        assert_eq!(segments[3].url.as_deref(), Some("https://www.example.com"));
        assert_eq!(segments[3].text, "www.example.com");
    }

    #[test]
    fn linkify_needs_an_address_after_the_scheme() {
        assert_eq!(
            linkify("Wait... http://. or www.."),
            vec![TextSegment { text: "Wait... http://. or www..".into(), url: None }]
        );
    }

    #[test]
    fn linkify_keeps_balanced_parentheses() {
        let segments = linkify("https://en.wikipedia.org/wiki/Rust_(language) is neat");
        assert_eq!(segments[0].text, "https://en.wikipedia.org/wiki/Rust_(language)");
    }

    #[test]
    fn plain_blocks_find_links() {
        let blocks = plain_blocks("look at https://xenia.example\nnow");
        let RichBlock::Paragraph { spans } = &blocks[0] else { panic!() };
        assert_eq!(spans[1].link.as_deref(), Some("https://xenia.example"));
        assert_eq!(spans[2].text, "\nnow");
    }

    #[test]
    fn finds_links_in_formatted_text() {
        let blocks = parse_html("<p>go to https://example.org now</p>");
        let RichBlock::Paragraph { spans } = &blocks[0] else { panic!() };
        assert_eq!(spans[1].link.as_deref(), Some("https://example.org"));
    }
}
