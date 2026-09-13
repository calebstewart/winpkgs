//! Syntax highlighting, done once at build time.
//!
//! The output is class-based rather than inline-styled. A site that has to look
//! right in both colour schemes cannot bake colours into its markup: the light
//! and dark palettes for a `hl-keyword` live in `style.css` next to every other
//! colour, and the HTML only says which token this is. That also keeps the
//! generated pages small -- a repeated `<span class="hl-string">` compresses,
//! forty repetitions of a hex colour do not.
//!
//! The syntax set is two-face's, which is bat's: nixpkgs' own `Nix` grammar is
//! not in syntect's defaults, and a documentation generator for a Nix flake that
//! cannot highlight Nix is not worth having.

use std::sync::OnceLock;

use syntect::html::{ClassStyle, ClassedHTMLGenerator};
use syntect::parsing::SyntaxSet;
use syntect::util::LinesWithEndings;

/// Prefix on every emitted class, so the stylesheet's highlighting rules cannot
/// collide with the page's own.
const CLASS_STYLE: ClassStyle = ClassStyle::SpacedPrefixed { prefix: "hl-" };

fn syntaxes() -> &'static SyntaxSet {
    static SET: OnceLock<SyntaxSet> = OnceLock::new();
    SET.get_or_init(two_face::syntax::extra_newlines)
}

/// Highlight `code` as `lang`, returning the inner HTML of a `<pre><code>`.
///
/// An unknown language is not an error: the whole point of a fenced block is
/// that the author writes whatever they like after the backticks, and a block
/// tagged `console` should still render, just without colour.
pub fn highlight(code: &str, lang: Option<&str>) -> String {
    let set = syntaxes();

    let syntax = lang
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .and_then(|l| {
            let l = normalise(l);
            set.find_syntax_by_token(&l)
                .or_else(|| set.find_syntax_by_extension(&l))
                .or_else(|| set.find_syntax_by_name(&l))
        });

    let Some(syntax) = syntax else {
        return escape(code);
    };

    let mut generator = ClassedHTMLGenerator::new_with_class_style(syntax, set, CLASS_STYLE);
    for line in LinesWithEndings::from(code) {
        // A grammar can fail on a fragment -- an option's `example` is very
        // often an expression rather than a file. Falling back to plain escaped
        // text is better than losing the block.
        if generator.parse_html_for_line_which_includes_newline(line).is_err() {
            return escape(code);
        }
    }
    generator.finalize()
}

/// Fence tags people actually write, mapped onto grammar names.
fn normalise(lang: &str) -> String {
    match lang.to_ascii_lowercase().as_str() {
        "nixos" | "nix-repl" => "nix".to_string(),
        "sh" | "shell" | "console" | "bash" => "bash".to_string(),
        "js" => "javascript".to_string(),
        "ts" => "typescript".to_string(),
        "yml" => "yaml".to_string(),
        other => other.to_string(),
    }
}

pub fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(c),
        }
    }
    out
}

/// A complete `<pre>` block, highlighted.
pub fn block(code: &str, lang: Option<&str>) -> String {
    let lang_class = lang
        .map(|l| format!(" data-lang=\"{}\"", escape(l)))
        .unwrap_or_default();
    format!(
        "<div class=\"code-wrap\"><pre class=\"code\"{lang_class}><code>{}</code></pre></div>",
        highlight(code, lang)
    )
}

/// A complete `<pre>` block of Nix -- the shape almost every value in the
/// document has.
pub fn nix(code: &str) -> String {
    block(code, Some("nix"))
}
