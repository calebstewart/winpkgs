//! flakedoc -- the rendering half of a Nix flake's documentation generator.
//!
//! The Nix half (`docs/*.nix` beside this directory) evaluates a flake and
//! writes one JSON document describing it; this program turns that document
//! into a directory of static HTML. Nothing here evaluates Nix, and nothing
//! here reaches the network: the whole job is a pure function from JSON to a
//! site, which is what makes it runnable inside a `runCommand` on a read-only
//! store.
//!
//! This is the renderer StewOS's documentation site is built with
//! (`pkgs/flakedoc` there), carried here so that winpkgs' site is built the
//! same way, plus a catalog page for a flake that installs packages rather
//! than building them.

mod config;
mod highlight;
mod hostgroups;
mod markdown;
mod merge;
mod model;
mod site;

use std::path::PathBuf;

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};

use crate::config::Config;
use crate::model::Docs;

#[derive(Parser)]
#[command(
    name = "flakedoc",
    version,
    about = "Render a Nix flake's extracted documentation into a static site"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Render a site from one or more extracted documents.
    Build {
        /// Path to a docs.json. Repeatable: several documents merge into one
        /// site, which is how a flake that cannot be evaluated on a single
        /// machine still gets documented completely.
        #[arg(long = "input", short = 'i', required = true, value_name = "FILE")]
        inputs: Vec<PathBuf>,

        /// flakedoc.toml (or the same structure as JSON).
        #[arg(long, short = 'c', value_name = "FILE")]
        config: PathBuf,

        /// Directory of hand-written Markdown and assets to weave in.
        #[arg(long, value_name = "DIR")]
        content: Option<PathBuf>,

        /// Directory of templates overriding the built-in ones, by filename.
        #[arg(long, value_name = "DIR")]
        template_dir: Option<PathBuf>,

        /// Directory to write the site to. Created if missing.
        #[arg(long, short = 'o', value_name = "DIR")]
        out: PathBuf,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Build {
            inputs,
            config,
            content,
            template_dir,
            out,
        } => build(inputs, config, content, template_dir, out),
    }
}

fn build(
    inputs: Vec<PathBuf>,
    config_path: PathBuf,
    content: Option<PathBuf>,
    template_dir: Option<PathBuf>,
    out: PathBuf,
) -> Result<()> {
    let config = Config::load(&config_path)?;

    let mut documents = Vec::with_capacity(inputs.len());
    for path in &inputs {
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("reading input {}", path.display()))?;
        let doc: Docs = serde_json::from_str(&text)
            .with_context(|| format!("parsing {} as a flakedoc document", path.display()))?;
        documents.push(doc);
    }

    let docs = merge::merge(documents);

    // A schema bump means a field this renderer knows changed meaning. Adding
    // fields does not bump it, so a newer minor document still renders.
    if docs.schema_version > 1 {
        bail!(
            "document schema version {} is newer than this flakedoc understands (1)",
            docs.schema_version
        );
    }

    if let Some(dir) = &content {
        if !dir.is_dir() {
            bail!("--content {} is not a directory", dir.display());
        }
    }
    if let Some(dir) = &template_dir {
        if !dir.is_dir() {
            bail!("--template-dir {} is not a directory", dir.display());
        }
    }

    std::fs::create_dir_all(&out)
        .with_context(|| format!("creating output directory {}", out.display()))?;

    let mut builder = site::Builder::new(&docs, &config, &out, template_dir.as_deref())?;
    builder.build(content.as_deref())?;

    let pages: usize = docs.option_sets.iter().map(|s| s.options.len()).sum();
    eprintln!(
        "flakedoc: wrote {} to {} ({} options, {} packages, {} catalog entries, {} hosts)",
        if inputs.len() == 1 {
            "1 document".to_string()
        } else {
            format!("{} documents", inputs.len())
        },
        out.display(),
        pages,
        docs.packages.len(),
        docs.catalog.entries.len(),
        docs.hosts.len(),
    );
    Ok(())
}
