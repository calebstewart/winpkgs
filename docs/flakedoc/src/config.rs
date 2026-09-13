//! `flakedoc.toml`.
//!
//! Both halves of the generator read the same file, so most of what is in it is
//! addressed to the Nix half -- which module trees to evaluate, which library
//! files to run nixdoc over, whether a missing description should fail the
//! build. None of that is an error here; it is simply not read. Only `[site]`,
//! `[nav]` and `[theme]` say anything about presentation.

use std::path::Path;

use anyhow::{Context, Result};
use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct Site {
    pub name: Option<String>,
    pub title: Option<String>,
    pub description: Option<String>,
    pub repository: Option<String>,
    pub branch: Option<String>,
}

impl Default for Site {
    fn default() -> Self {
        Self {
            name: None,
            title: None,
            description: None,
            repository: None,
            branch: Some("main".to_string()),
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Nav {
    /// Section ids in the order the sidebar should show them. Anything
    /// generated but unlisted is appended; anything listed but not generated is
    /// skipped, so a config may name sections a given flake does not produce.
    pub order: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct Theme {
    pub accent: String,
    #[serde(rename = "accentDark", alias = "accent_dark", alias = "accent-dark")]
    pub accent_dark: String,
}

impl Default for Theme {
    fn default() -> Self {
        Self {
            accent: "#3b82f6".to_string(),
            accent_dark: "#89b4fa".to_string(),
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Config {
    pub site: Site,
    pub nav: Nav,
    pub theme: Theme,
    // optionSets, libNamespaces, packageDir and warningsAreErrors belong to the
    // extraction half. They are deliberately not declared: serde ignores
    // unknown fields by default, which is exactly the behaviour wanted.
}

impl Config {
    /// Load a config from TOML or JSON, deciding by extension and falling back
    /// to trying both.
    pub fn load(path: &Path) -> Result<Self> {
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("reading config {}", path.display()))?;

        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();

        match ext.as_str() {
            "json" => serde_json::from_str(&text)
                .with_context(|| format!("parsing {} as JSON", path.display())),
            "toml" => {
                toml::from_str(&text).with_context(|| format!("parsing {} as TOML", path.display()))
            }
            _ => match toml::from_str(&text) {
                Ok(cfg) => Ok(cfg),
                Err(toml_err) => serde_json::from_str(&text).with_context(|| {
                    format!(
                        "parsing {} as either TOML ({toml_err}) or JSON",
                        path.display()
                    )
                }),
            },
        }
    }
}
