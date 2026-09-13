//! Markdown, plus the nixpkgs documentation roles that appear inside it.
//!
//! Option descriptions are not plain CommonMark. nixpkgs writes them in the
//! MyST-flavoured dialect its manual is built from, where `{option}` and
//! friends mark up a term with what kind of thing it is. Those roles have to be
//! resolved before the Markdown parser sees them -- to CommonMark, `` {option}
//! `x` `` is the literal text `{option}` followed by a code span, which is how
//! it renders if nothing intervenes.
//!
//! Only `{option}` produces a link, and only when the option it names actually
//! exists in one of the documented sets. A dangling cross-reference in
//! generated documentation is worse than no cross-reference: it says the thing
//! is documented somewhere it is not.

use pulldown_cmark::{CodeBlockKind, Event, Options, Parser, Tag, TagEnd};

use crate::highlight;

/// Resolves an option name to a site-root-relative URL, or `None` if the flake
/// does not declare it.
pub type OptionResolver<'a> = dyn Fn(&str) -> Option<String> + 'a;

/// Everything a page needs to render prose: where it sits in the tree, and how
/// to look an option up.
pub struct Renderer<'a> {
    /// `""`, `"../"`, `"../../"` -- the prefix that turns a site-root-relative
    /// path into one relative to the page being rendered. The site is published
    /// under a path prefix on GitHub Pages, so nothing may be rooted at `/`.
    pub root: String,
    resolve: Box<OptionResolver<'a>>,
    resolve_lib: Box<OptionResolver<'a>>,
}

impl<'a> Renderer<'a> {
    pub fn new(
        root: impl Into<String>,
        resolve: Box<OptionResolver<'a>>,
        resolve_lib: Box<OptionResolver<'a>>,
    ) -> Self {
        Self {
            root: root.into(),
            resolve,
            resolve_lib,
        }
    }

    /// Render Markdown to HTML.
    pub fn render(&self, markdown: &str) -> String {
        let prepared = self.rewrite_roles(markdown);
        render_html(&prepared)
    }

    /// Render Markdown that is known to be a single paragraph, without the
    /// wrapping `<p>` -- for table cells and list items.
    pub fn render_inline(&self, markdown: &str) -> String {
        let html = self.render(markdown);
        let trimmed = html.trim();
        match trimmed
            .strip_prefix("<p>")
            .and_then(|s| s.strip_suffix("</p>"))
        {
            // Only unwrap when there is exactly one paragraph; a stripped
            // prefix and suffix around two paragraphs would produce garbage.
            Some(inner) if !inner.contains("<p>") => inner.to_string(),
            _ => trimmed.to_string(),
        }
    }

    /// Replace nixpkgs roles with CommonMark, leaving fenced code alone.
    fn rewrite_roles(&self, markdown: &str) -> String {
        let mut out = String::with_capacity(markdown.len());
        let mut fence: Option<String> = None;

        for line in markdown.split_inclusive('\n') {
            let (body, newline) = match line.strip_suffix('\n') {
                Some(b) => (b, "\n"),
                None => (line, ""),
            };

            match &fence {
                Some(marker) => {
                    out.push_str(body);
                    out.push_str(newline);
                    if body.trim_start().starts_with(marker.as_str()) {
                        fence = None;
                    }
                    continue;
                }
                None => {
                    if let Some(marker) = fence_marker(body) {
                        fence = Some(marker);
                        out.push_str(body);
                        out.push_str(newline);
                        continue;
                    }
                }
            }

            out.push_str(&self.rewrite_line(body));
            out.push_str(newline);
        }

        out
    }

    fn rewrite_line(&self, line: &str) -> String {
        let line = self.rewrite_manual_anchors(line);
        let line = line.as_str();
        let bytes = line.as_bytes();
        let mut out = String::with_capacity(line.len());
        let mut i = 0;

        while i < bytes.len() {
            if bytes[i] != b'{' {
                let next = line[i..]
                    .find('{')
                    .map(|p| i + p)
                    .unwrap_or(bytes.len());
                out.push_str(&line[i..next]);
                i = next;
                continue;
            }

            match self.parse_role(line, i) {
                Some((replacement, end)) => {
                    out.push_str(&replacement);
                    i = end;
                }
                None => {
                    out.push('{');
                    i += 1;
                }
            }
        }

        out
    }

    /// Point nixpkgs-manual fragments at this site instead.
    ///
    /// nixdoc's own convention is to cross-reference a sibling function as
    /// `(#function-library-lib.docs.evalTree)`, which is the id the *nixpkgs
    /// manual* would give it. A doc-comment written that way is correct where
    /// it was written and dangling here, so the fragment is translated rather
    /// than left to 404 in place.
    const MANUAL_PREFIX: &'static str = "#function-library-";

    fn rewrite_manual_anchors(&self, line: &str) -> String {
        if !line.contains(Self::MANUAL_PREFIX) {
            return line.to_string();
        }

        let mut out = String::with_capacity(line.len());
        let mut rest = line;
        while let Some(at) = rest.find(Self::MANUAL_PREFIX) {
            out.push_str(&rest[..at]);
            let after = &rest[at + Self::MANUAL_PREFIX.len()..];
            let end = after
                .find(|c: char| !(c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-')))
                .unwrap_or(after.len());
            let name = &after[..end];

            match (self.resolve_lib)(name) {
                Some(url) => out.push_str(&format!("{}{url}", self.root)),
                None => {
                    out.push_str(Self::MANUAL_PREFIX);
                    out.push_str(name);
                }
            }
            rest = &after[end..];
        }
        out.push_str(rest);
        out
    }

    /// Parse `{role}`` `content` ``` starting at `start`, which must be the `{`.
    /// Returns the replacement and the index just past the role.
    fn parse_role(&self, line: &str, start: usize) -> Option<(String, usize)> {
        let rest = &line[start + 1..];
        let close = rest.find('}')?;
        let role = &rest[..close];
        if role.is_empty() || !role.chars().all(|c| c.is_ascii_lowercase() || c == '-') {
            return None;
        }

        let after = start + 1 + close + 1;
        let tail = line.get(after..)?;
        let ticks = tail.chars().take_while(|c| *c == '`').count();
        if ticks == 0 {
            return None;
        }

        let delim = "`".repeat(ticks);
        let body_start = after + ticks;
        let body_end = line.get(body_start..)?.find(&delim)? + body_start;
        let content = &line[body_start..body_end];
        let end = body_end + ticks;

        let replacement = match role {
            "option" => match (self.resolve)(content) {
                // The angle-bracket form because an option anchor contains
                // dots and a `#`, and a bare URL in a Markdown link is only
                // parsed up to the first character it does not like.
                Some(url) => format!("[{delim}{content}{delim}](<{}{url}>)", self.root),
                None => format!("{delim}{content}{delim}"),
            },
            "command" | "file" | "var" | "env" | "manpage" | "literal" | "code" | "path" => {
                format!("{delim}{content}{delim}")
            }
            // Not a role this generator knows. Leaving it verbatim is the
            // honest outcome: inventing a rendering for it would hide the fact
            // that the source used something unsupported.
            _ => return None,
        };

        Some((replacement, end))
    }
}

/// The closing marker a fence opened on this line would need, if it opened one.
fn fence_marker(line: &str) -> Option<String> {
    let trimmed = line.trim_start();
    for c in ['`', '~'] {
        let run = trimmed.chars().take_while(|x| *x == c).count();
        if run >= 3 {
            return Some(c.to_string().repeat(run));
        }
    }
    None
}

/// Markdown to HTML, with the extensions nixpkgs prose actually uses and code
/// blocks handed to syntect.
fn render_html(markdown: &str) -> String {
    let mut options = Options::empty();
    options.insert(Options::ENABLE_TABLES);
    options.insert(Options::ENABLE_STRIKETHROUGH);
    options.insert(Options::ENABLE_FOOTNOTES);
    options.insert(Options::ENABLE_TASKLISTS);
    // Smart punctuation is deliberately off: this prose is full of `--flag`,
    // and an en dash in the middle of a command line is a typo the reader would
    // then copy.

    let parser = Parser::new_ext(markdown, options);

    let mut events: Vec<Event> = Vec::new();
    let mut code: Option<(Option<String>, String)> = None;

    for event in parser {
        match event {
            Event::Start(Tag::CodeBlock(kind)) => {
                let lang = match kind {
                    CodeBlockKind::Fenced(l) if !l.is_empty() => Some(l.to_string()),
                    _ => None,
                };
                code = Some((lang, String::new()));
            }
            Event::End(TagEnd::CodeBlock) => {
                if let Some((lang, text)) = code.take() {
                    events.push(Event::Html(
                        highlight::block(&text, lang.as_deref()).into(),
                    ));
                }
            }
            Event::Text(text) | Event::Code(text) if code.is_some() => {
                if let Some((_, buffer)) = code.as_mut() {
                    buffer.push_str(&text);
                }
            }
            other => events.push(other),
        }
    }

    let mut html = String::new();
    pulldown_cmark::html::push_html(&mut html, events.into_iter());
    // Tables and long code lines must scroll inside their own box rather than
    // pushing the page sideways; code blocks get their wrapper in
    // highlight::block, tables get theirs here.
    html.replace("<table>", "<div class=\"table-wrap\"><table>")
        .replace("</table>", "</table></div>")
}

/// Shorten prose to a single line of at most `limit` characters, for a search
/// result or an index row.
pub fn summarize(markdown: &str, limit: usize) -> String {
    let mut text = String::new();
    let mut fence = None;

    for line in markdown.lines() {
        match &fence {
            Some(marker) => {
                if line.trim_start().starts_with(marker) {
                    fence = None;
                }
                continue;
            }
            None => {
                if let Some(marker) = fence_marker(line) {
                    fence = Some(marker);
                    continue;
                }
            }
        }
        let line = line.trim();
        if line.is_empty() {
            if !text.is_empty() {
                break;
            }
            continue;
        }
        if !text.is_empty() {
            text.push(' ');
        }
        text.push_str(line);
    }

    // Strip the punctuation that means something to Markdown but nothing in a
    // one-line summary.
    let cleaned: String = text
        .chars()
        .filter(|c| !matches!(c, '`' | '*' | '_' | '#' | '{' | '}'))
        .collect();
    let cleaned = cleaned.split_whitespace().collect::<Vec<_>>().join(" ");

    if cleaned.chars().count() <= limit {
        return cleaned;
    }
    let mut truncated: String = cleaned.chars().take(limit).collect();
    if let Some(space) = truncated.rfind(' ') {
        if space > limit / 2 {
            truncated.truncate(space);
        }
    }
    format!("{}…", truncated.trim_end())
}
