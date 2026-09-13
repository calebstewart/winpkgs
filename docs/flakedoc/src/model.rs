//! The `docs.json` document, as flakedoc reads it.
//!
//! Every field here is optional. The document is produced by evaluating a real
//! flake, and a real flake has packages with no `meta`, options with no
//! `default`, inputs that are not flakes and hosts that set nothing. Unknown
//! fields are ignored outright so that a newer extractor can add data without
//! breaking an older renderer -- the `schemaVersion` is only bumped when an
//! existing field changes meaning.

use std::collections::BTreeMap;

use serde::Deserialize;

/// A piece of prose. nixosOptionsDoc hands descriptions over as a plain string,
/// nixdoc as a list of Markdown blocks, and older nixpkgs wrapped them in an
/// `{ _type = "mdDoc"; text = ...; }`. All three mean the same thing.
#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum Text {
    Plain(String),
    Blocks(Vec<String>),
    Wrapped { text: String },
    /// Anything else at all, kept so that a surprise never fails the parse.
    Other(serde_json::Value),
}

impl Text {
    /// The Markdown this text renders as.
    pub fn markdown(&self) -> String {
        match self {
            Text::Plain(s) => s.clone(),
            Text::Blocks(parts) => parts.join("\n\n"),
            Text::Wrapped { text } => text.clone(),
            Text::Other(v) => match v {
                serde_json::Value::String(s) => s.clone(),
                serde_json::Value::Null => String::new(),
                other => other.to_string(),
            },
        }
    }

    pub fn is_empty(&self) -> bool {
        self.markdown().trim().is_empty()
    }
}

/// An option's `default` or `example`.
///
/// Normally `{ _type = "literalExpression"; text = "false"; }`, but the module
/// system also emits `literalMD`, and a value that never went through
/// `renderOptionValue` arrives as a bare JSON scalar.
#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum Literal {
    Rendered {
        #[serde(rename = "_type", default)]
        kind: Option<String>,
        #[serde(default)]
        text: Option<String>,
    },
    Raw(serde_json::Value),
}

impl Literal {
    /// `true` when this should be rendered as prose rather than as Nix.
    pub fn is_markdown(&self) -> bool {
        matches!(self, Literal::Rendered { kind: Some(k), .. } if k == "literalMD")
    }

    /// The text to show. Nix-valued literals keep their source formatting; a
    /// raw JSON value is printed as the closest thing to Nix that JSON is.
    pub fn text(&self) -> String {
        match self {
            Literal::Rendered { text: Some(t), .. } => t.clone(),
            Literal::Rendered { text: None, .. } => String::new(),
            Literal::Raw(v) => match v {
                serde_json::Value::String(s) => format!("{s:?}"),
                serde_json::Value::Null => "null".to_string(),
                other => serde_json::to_string_pretty(other).unwrap_or_else(|_| other.to_string()),
            },
        }
    }
}

/// Where a module or a package was written.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Declaration {
    pub name: String,
    pub url: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Meta {
    pub name: String,
    pub title: String,
    pub description: Option<String>,
    pub repo_url: Option<String>,
    pub branch: Option<String>,
    pub rev: Option<String>,
    /// `self.lastModifiedDate`, i.e. `YYYYMMDDHHMMSS`. Accepted as a number too
    /// so that an epoch works.
    pub last_modified: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct OptionDoc {
    pub loc: Vec<String>,
    pub declarations: Vec<Declaration>,
    pub description: Option<Text>,
    #[serde(rename = "type")]
    pub type_: Option<String>,
    pub read_only: bool,
    pub default: Option<Literal>,
    pub example: Option<Literal>,
    pub related_packages: Option<Text>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct OptionSet {
    pub id: String,
    pub title: String,
    /// `nixos`, `home-manager` or `darwin`.
    pub kind: String,
    pub system: Option<String>,
    pub description: Option<Text>,
    /// Keyed by dotted option name. A `BTreeMap` so the rendered order is the
    /// sorted one no matter what order the extractor emitted.
    pub options: BTreeMap<String, OptionDoc>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Definition {
    pub file: String,
    pub url: Option<String>,
    pub value: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Setting {
    pub name: String,
    pub definitions: Vec<Definition>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Source {
    pub file: String,
    pub url: Option<String>,
}

/// Something that is true of a host, read from an option's merged *value*
/// rather than from where that value was written.
///
/// The settings table is built from `definitionsWithLocations`, and not every
/// definition has a location a reader could follow: a value handed to
/// `mkNixOSHost` by an inline module in `flake.nix` is attributed to nixpkgs'
/// own `flake.nix` on the NixOS side and to `<unknown-file>` on the
/// home-manager side. A fact sidesteps provenance entirely, which is why it
/// carries no file and no URL and must never be rendered as though it did.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Fact {
    pub name: String,
    pub description: Option<Text>,
    /// Pretty-printed Nix, usually multi-line.
    pub value: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Host {
    pub name: String,
    pub kind: String,
    pub system: Option<String>,
    pub state_version: Option<String>,
    pub modules_enabled: Vec<String>,
    pub settings: Vec<Setting>,
    pub sources: Vec<Source>,
    pub facts: Vec<Fact>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct License {
    pub spdx_id: Option<String>,
    pub full_name: Option<String>,
    pub url: Option<String>,
    pub free: Option<bool>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Package {
    pub attr: String,
    pub system: Option<String>,
    pub pname: Option<String>,
    pub version: Option<String>,
    pub name: Option<String>,
    pub description: Option<String>,
    pub long_description: Option<String>,
    pub homepage: Option<String>,
    pub main_program: Option<String>,
    pub platforms: Vec<String>,
    pub broken: bool,
    pub unfree: bool,
    pub licenses: Vec<License>,
    pub outputs: Vec<String>,
    pub source: Option<Declaration>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct AppOutput {
    pub system: Option<String>,
    pub name: String,
    pub description: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct NamedOutput {
    pub name: Option<String>,
    pub description: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct SystemOutput {
    pub system: Option<String>,
    pub name: Option<String>,
}

/// Attribute names under one output, keyed by the output's own name --
/// `nixosModules`, `windowsModules`, `homeConfigurations` and so on. A map
/// rather than one field per kind, so that a flake with a module tree this
/// renderer has never heard of still gets it listed under the right heading.
/// A `BTreeMap` so the rendered order is stable whatever the extractor did.
pub type ByOutput = BTreeMap<String, Vec<String>>;

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Outputs {
    pub apps: Vec<AppOutput>,
    pub templates: Vec<NamedOutput>,
    pub overlays: Vec<String>,
    pub modules: ByOutput,
    pub configurations: ByOutput,
    pub checks: Vec<SystemOutput>,
    pub dev_shells: Vec<SystemOutput>,
    pub formatter: Vec<SystemOutput>,
    pub lib: Vec<String>,
    pub other: Vec<String>,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Input {
    pub name: String,
    #[serde(rename = "type")]
    pub type_: Option<String>,
    pub owner: Option<String>,
    pub repo: Option<String>,
    #[serde(rename = "ref")]
    pub ref_: Option<String>,
    pub rev: Option<String>,
    pub last_modified: Option<i64>,
    pub url: Option<String>,
    pub is_flake: bool,
    pub follows: BTreeMap<String, Vec<String>>,
}

impl Default for Input {
    fn default() -> Self {
        Self {
            name: String::new(),
            type_: None,
            owner: None,
            repo: None,
            ref_: None,
            rev: None,
            last_modified: None,
            url: None,
            is_flake: default_true(),
            follows: BTreeMap::new(),
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct LibEntry {
    pub name: String,
    pub prefix: Option<String>,
    pub category: Option<String>,
    pub description: Option<Text>,
    pub fn_type: Option<String>,
    pub example: Option<Text>,
    /// nixdoc's shape here has changed more than once; it is read as opaque
    /// JSON and normalised at render time by [`crate::site::lib_args`].
    pub args: Vec<serde_json::Value>,
    pub location: Option<serde_json::Value>,
    pub file: Option<String>,
    pub url: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct LibNamespace {
    pub name: String,
    pub description: Option<Text>,
    pub entries: Vec<LibEntry>,
}

/// A nixpkgs attribute the overlay knows how to install on Windows: through
/// winget, from its font files, or from a release archive. This is what a
/// package *is* to a flake that never builds one -- a name a shared module can
/// speak, and what that name means on the machine.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CatalogEntry {
    /// The nixpkgs attribute, `pkgs.<attr>`.
    pub attr: String,
    /// `winget`, `font` or `portable`.
    pub kind: String,
    /// The winget package id, for a `winget` entry. `None` with `available =
    /// false` records a package that has no Windows build at all.
    pub id: Option<String>,
    /// `machine` or `user` when the installer works at one scope only.
    pub scope: Option<String>,
    /// Where the package's programs land, in `%VAR%` form.
    pub program_dir: Option<String>,
    /// The program `getExe` names.
    pub main_program: Option<String>,
    /// nixpkgs' one-line description of the package.
    pub description: Option<String>,
    /// The upstream project, from nixpkgs' `meta.homepage` or the entry.
    pub homepage: Option<String>,
    /// A portable entry's pinned version.
    pub version: Option<String>,
    #[serde(default = "default_true")]
    pub available: bool,
}

/// The overlay's tables, as a catalog of what `home.packages` and
/// `environment.systemPackages` can name.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Catalog {
    pub entries: Vec<CatalogEntry>,
    /// Attribute sets every member of which is a font -- `nerd-fonts` -- listed
    /// by set name rather than one entry per face.
    pub font_sets: Vec<FontSet>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct FontSet {
    pub attr: String,
    pub count: usize,
    pub description: Option<String>,
}

impl Catalog {
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty() && self.font_sets.is_empty()
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Docs {
    pub schema_version: u32,
    pub meta: Meta,
    pub option_sets: Vec<OptionSet>,
    pub hosts: Vec<Host>,
    pub packages: Vec<Package>,
    pub catalog: Catalog,
    pub outputs: Outputs,
    pub inputs: Vec<Input>,
    pub lib_namespaces: Vec<LibNamespace>,
}
