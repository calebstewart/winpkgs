//! Turning one merged document into a directory of HTML.
//!
//! Two rules shape everything here.
//!
//! The first is that **no URL may start with `/`**. The site is published to
//! GitHub Pages under a repository subpath, so a root-relative link points at
//! the user's account page rather than at this site. Every internal link is
//! therefore stored site-root-relative (`options/index.html`) and prefixed at
//! render time with the emitting page's own `root` (`../`, `../../`, …).
//!
//! The second is that **nothing is fetched at view time**. There is no CDN, no
//! webfont and no analytics; the only runtime request the site makes at all is
//! for its own search index, and that is relative too.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use include_dir::{include_dir, Dir};
use minijinja::Environment;
use serde_json::{json, Map, Value};

use crate::config::Config;
use crate::highlight;
use crate::hostgroups;
use crate::markdown::{self, Renderer};
use crate::model::{Docs, Host, LibNamespace, OptionSet, Package};

static TEMPLATES: Dir<'_> = include_dir!("$CARGO_MANIFEST_DIR/templates");

/// Templates rendered as assets rather than as pages. `search.js` is copied
/// verbatim: it is JavaScript full of braces, and running it through a template
/// engine buys nothing but a chance to corrupt it.
const RENDERED_ASSETS: &[&str] = &["style.css"];
const COPIED_ASSETS: &[&str] = &["search.js"];

/// One entry in the sidebar.
#[derive(Clone)]
struct Section {
    id: String,
    title: String,
    url: String,
    children: Vec<NavItem>,
}

/// A sidebar entry below the section level.
///
/// Two levels deep at most, and only Hosts uses the second: a machine is a
/// heading with no page of its own (`url: None`), and its configurations hang
/// off it. Options and Library use a single flat level, where every item is a
/// link and `children` is empty.
#[derive(Clone)]
struct NavItem {
    title: String,
    /// `None` for a grouping heading -- a machine has configurations but no
    /// page, and linking it somewhere approximate would be worse than not
    /// linking it.
    url: Option<String>,
    /// A short kind marker (`nixos`, `darwin`, `home`), so that nesting a
    /// configuration under a machine does not hide what kind of thing it is.
    tag: Option<String>,
    children: Vec<NavItem>,
}

impl NavItem {
    fn link(title: impl Into<String>, url: impl Into<String>) -> Self {
        NavItem {
            title: title.into(),
            url: Some(url.into()),
            tag: None,
            children: Vec::new(),
        }
    }

    fn tagged(title: impl Into<String>, url: impl Into<String>, tag: impl Into<String>) -> Self {
        NavItem {
            tag: Some(tag.into()),
            ..NavItem::link(title, url)
        }
    }

    fn heading(title: impl Into<String>, children: Vec<NavItem>) -> Self {
        NavItem {
            title: title.into(),
            url: None,
            tag: None,
            children,
        }
    }

    /// Rendered form, marking the current page and any heading above it.
    fn to_value(&self, path: &str) -> Value {
        let children: Vec<Value> = self.children.iter().map(|c| c.to_value(path)).collect();
        let active = self.url.as_deref() == Some(path)
            || children
                .iter()
                .any(|c| c.get("active").and_then(Value::as_bool).unwrap_or(false));
        json!({
            "title": self.title,
            "url": self.url,
            "tag": self.tag,
            "active": active,
            "children": children,
        })
    }
}

/// The short marker shown beside a configuration in the sidebar.
fn kind_tag(kind: &str) -> String {
    match kind {
        "home-manager" => "home".to_string(),
        other => other.to_string(),
    }
}

/// A group of options sharing a declaring file -- one rendered page.
struct Module {
    file: String,
    file_url: Option<String>,
    slug: String,
    title: String,
    options: Vec<String>,
}

struct SetPlan {
    slug: String,
    modules: Vec<Module>,
}

pub struct Builder<'a> {
    docs: &'a Docs,
    config: &'a Config,
    out: &'a Path,
    env: Environment<'a>,

    plans: Vec<SetPlan>,
    /// Dotted option name to its site-root-relative URL with anchor. Keyed by
    /// option-set kind first so that a name declared in two trees resolves to
    /// the one a given host actually uses.
    option_urls: BTreeMap<(String, String), String>,
    /// The same, ignoring kind -- for prose cross-references, which have no
    /// kind to go on.
    any_option_urls: BTreeMap<String, String>,
    /// `(kind, module prefix)` to the page documenting it, for a host's list of
    /// enabled modules.
    module_pages: BTreeMap<(String, String), String>,
    /// Qualified library-function name to its page and anchor.
    lib_urls: BTreeMap<String, String>,
    host_slugs: BTreeMap<String, String>,
    package_slugs: BTreeMap<String, String>,
    namespace_slugs: BTreeMap<String, String>,
    sections: Vec<Section>,
    /// Extra rows for the site-wide search drop-down.
    pages_index: Vec<Value>,
}

impl<'a> Builder<'a> {
    pub fn new(
        docs: &'a Docs,
        config: &'a Config,
        out: &'a Path,
        template_dir: Option<&Path>,
    ) -> Result<Self> {
        let env = load_templates(template_dir)?;

        let mut builder = Builder {
            docs,
            config,
            out,
            env,
            plans: Vec::new(),
            option_urls: BTreeMap::new(),
            any_option_urls: BTreeMap::new(),
            module_pages: BTreeMap::new(),
            lib_urls: BTreeMap::new(),
            host_slugs: BTreeMap::new(),
            package_slugs: BTreeMap::new(),
            namespace_slugs: BTreeMap::new(),
            sections: Vec::new(),
            pages_index: Vec::new(),
        };
        builder.plan();
        Ok(builder)
    }

    /// Work out every page's address before rendering any of them, because a
    /// page's prose may link to any other page.
    fn plan(&mut self) {
        let mut set_slugs: HashMap<String, usize> = HashMap::new();

        for set in &self.docs.option_sets {
            let slug = unique(&mut set_slugs, slugify(&set.id));
            let mut modules = group_options(set);
            modules.sort_by(|a, b| a.title.cmp(&b.title).then(a.file.cmp(&b.file)));

            for module in &modules {
                let page = format!("options/{}/{}.html", slug, module.slug);
                self.module_pages
                    .insert((set.kind.clone(), module.title.clone()), page.clone());

                for name in &module.options {
                    let url = format!("{page}#{}", anchor(name));
                    self.option_urls
                        .insert((set.kind.clone(), name.clone()), url.clone());
                    self.any_option_urls.entry(name.clone()).or_insert(url);
                }
            }

            self.plans.push(SetPlan { slug, modules });
        }

        let mut used: HashMap<String, usize> = HashMap::new();
        for host in &self.docs.hosts {
            let slug = unique(&mut used, slugify(&host.name));
            self.host_slugs.insert(host.name.clone(), slug);
        }

        let mut used: HashMap<String, usize> = HashMap::new();
        for attr in self.package_attrs() {
            let slug = unique(&mut used, slugify(&attr));
            self.package_slugs.insert(attr, slug);
        }

        let mut used: HashMap<String, usize> = HashMap::new();
        for ns in &self.docs.lib_namespaces {
            let slug = unique(&mut used, slugify(&ns.name));
            for entry in &ns.entries {
                let full = qualified(ns, entry);
                self.lib_urls
                    .insert(full.clone(), format!("lib/{slug}.html#{}", anchor(&full)));
            }
            self.namespace_slugs.insert(ns.name.clone(), slug);
        }
    }

    /// Package attribute names, deduplicated across systems and sorted.
    fn package_attrs(&self) -> Vec<String> {
        let mut attrs: Vec<String> = self
            .docs
            .packages
            .iter()
            .map(|p| p.attr.clone())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();
        attrs.sort();
        attrs
    }

    fn packages_for(&self, attr: &str) -> Vec<&Package> {
        self.docs.packages.iter().filter(|p| p.attr == attr).collect()
    }

    /// The sidebar, in the order `[nav] order` asks for. Sections the config
    /// names but the flake does not produce are skipped rather than shown
    /// empty; sections it produces but the config does not name are appended,
    /// so a new kind of page is never invisible just because nobody updated the
    /// config.
    fn build_sections(&mut self, content_pages: &[(String, String, String)]) {
        let mut available: Vec<Section> = Vec::new();

        if !self.docs.option_sets.is_empty() {
            available.push(Section {
                id: "options".into(),
                title: "Options".into(),
                url: "options/index.html".into(),
                children: self
                    .docs
                    .option_sets
                    .iter()
                    .zip(&self.plans)
                    .map(|(set, plan)| {
                        NavItem::link(
                            display_title(&set.title, &set.id),
                            format!("options/{}/index.html", plan.slug),
                        )
                    })
                    .collect(),
            });
        }

        if !self.docs.packages.is_empty() {
            available.push(Section {
                id: "packages".into(),
                title: "Packages".into(),
                url: "packages/index.html".into(),
                children: Vec::new(),
            });
        }

        // The catalog is what "packages" means to a flake that installs
        // rather than builds: the same title, its own page, and its own id so
        // a flake that has both kinds is not made to choose.
        if !self.docs.catalog.is_empty() {
            available.push(Section {
                id: "catalog".into(),
                title: "Packages".into(),
                url: "catalog/index.html".into(),
                children: Vec::new(),
            });
        }

        if !self.docs.hosts.is_empty() {
            available.push(Section {
                id: "hosts".into(),
                title: "Hosts".into(),
                url: "hosts/index.html".into(),
                children: self
                    .host_groups()
                    .iter()
                    .map(|group| {
                        let members: Vec<NavItem> = group
                            .members
                            .iter()
                            .filter_map(|(label, name)| {
                                let host = self.host(name)?;
                                Some(NavItem::tagged(
                                    label.clone(),
                                    self.host_url(name),
                                    kind_tag(&host.kind),
                                ))
                            })
                            .collect();

                        if group.is_machine {
                            NavItem::heading(group.name.clone(), members)
                        } else {
                            // A configuration that paired with nothing keeps
                            // the entry it has always had: its own full name,
                            // linked, at the top level.
                            members
                                .into_iter()
                                .next()
                                .unwrap_or_else(|| NavItem::heading(group.name.clone(), Vec::new()))
                        }
                    })
                    .collect(),
            });
        }

        if !self.docs.lib_namespaces.is_empty() {
            available.push(Section {
                id: "lib".into(),
                title: "Library".into(),
                url: "lib/index.html".into(),
                children: self
                    .docs
                    .lib_namespaces
                    .iter()
                    .map(|n| {
                        NavItem::link(
                            n.name.clone(),
                            format!("lib/{}.html", self.namespace_slugs[&n.name]),
                        )
                    })
                    .collect(),
            });
        }

        available.push(Section {
            id: "flake".into(),
            title: "Flake".into(),
            url: "flake/index.html".into(),
            children: Vec::new(),
        });

        for (id, title, url) in content_pages {
            available.push(Section {
                id: id.clone(),
                title: title.clone(),
                url: url.clone(),
                children: Vec::new(),
            });
        }

        // Overview is pinned ahead of the ordering loop rather than passed
        // through it, and deliberately so. An id the config's `order` does not
        // mention gets appended, and a link home at the *bottom* of the sidebar
        // is worse than no link home at all -- which is what the site had, the
        // wordmark in the header being nowhere near where the eye is on a wide
        // screen. This is a fixed navigational affordance, not a content
        // section, so no configuration may reorder it away. It still carries an
        // id so it can be identified.
        let mut ordered = vec![Section {
            id: "overview".into(),
            title: "Overview".into(),
            url: "index.html".into(),
            children: Vec::new(),
        }];

        for id in &self.config.nav.order {
            if let Some(position) = available.iter().position(|s| &s.id == id) {
                ordered.push(available.remove(position));
            }
        }
        ordered.extend(available);
        self.sections = ordered;
    }

    /// The host groups, computed from names and kinds alone.
    fn host_groups(&self) -> Vec<hostgroups::HostGroup> {
        let names: Vec<(&str, &str)> = self
            .docs
            .hosts
            .iter()
            .map(|h| (h.name.as_str(), h.kind.as_str()))
            .collect();
        hostgroups::group(&names)
    }

    fn host(&self, name: &str) -> Option<&Host> {
        self.docs.hosts.iter().find(|h| h.name == name)
    }

    fn host_url(&self, name: &str) -> String {
        format!("hosts/{}.html", self.host_slugs[name])
    }

    /// The page documenting an option namespace such as `stewos.audio` -- the
    /// module page when one covers exactly that prefix, otherwise the namespace's
    /// own `enable` option. `None` when the flake documents neither, which is
    /// what keeps this from ever producing a dangling link.
    fn namespace_url(&self, kind: &str, name: &str) -> Option<String> {
        self.module_pages
            .get(&(kind.to_string(), name.to_string()))
            .cloned()
            .or_else(|| {
                self.option_urls
                    .get(&(kind.to_string(), format!("{name}.enable")))
                    .cloned()
            })
            .or_else(|| {
                self.option_urls
                    .get(&(kind.to_string(), name.to_string()))
                    .cloned()
            })
    }

    // ------------------------------------------------------------- rendering

    fn renderer(&self, root: &str) -> Renderer<'_> {
        Renderer::new(
            root.to_string(),
            Box::new(|name| self.any_option_urls.get(name).cloned()),
            Box::new(|name| self.lib_urls.get(name).cloned()),
        )
    }

    fn site_context(&self) -> Value {
        let meta = &self.docs.meta;
        let title = self
            .config
            .site
            .title
            .clone()
            .filter(|t| !t.is_empty())
            .or_else(|| Some(meta.title.clone()).filter(|t| !t.is_empty()))
            .unwrap_or_else(|| "Flake".to_string());
        let description = self
            .config
            .site
            .description
            .clone()
            .or_else(|| meta.description.clone());
        let repo_url = self
            .config
            .site
            .repository
            .clone()
            .or_else(|| meta.repo_url.clone())
            .filter(|u| !u.is_empty());

        let rev_url = match (&repo_url, &meta.rev) {
            (Some(repo), Some(rev)) if !rev.is_empty() => Some(format!("{repo}/commit/{rev}")),
            _ => None,
        };

        json!({
            "title": title,
            "name": meta.name,
            "description": description,
            "repo_url": repo_url,
            "branch": self.config.site.branch.clone().or_else(|| meta.branch.clone()),
            "rev": meta.rev,
            "rev_short": meta.rev.as_deref().map(abbreviate),
            "rev_url": rev_url,
            "last_modified": meta.last_modified.as_ref().and_then(format_timestamp),
        })
    }

    fn base_context(&self, path: &str, active: &str, title: &str) -> Map<String, Value> {
        let root = root_for(path);
        // A section is current by *id*, never by URL prefix: `index.html` sits
        // at the root, and any prefix rule would make Overview match every page
        // on the site.
        let nav: Vec<Value> = self
            .sections
            .iter()
            .map(|section| {
                json!({
                    "id": section.id,
                    "title": section.title,
                    "url": section.url,
                    "active": section.id == active,
                    "children": section.children.iter()
                        .map(|child| child.to_value(path))
                        .collect::<Vec<_>>(),
                })
            })
            .collect();

        // Which sections exist at all. A template that wants to point at
        // another part of the site has to ask, because a flake with hosts and
        // no documented option sets generates no options/index.html for the
        // hosts page to link to.
        let has: Map<String, Value> = ["options", "packages", "catalog", "hosts", "lib", "flake"]
            .iter()
            .map(|id| {
                (
                    (*id).to_string(),
                    json!(self.sections.iter().any(|s| s.id == *id)),
                )
            })
            .collect();

        let mut context = Map::new();
        context.insert("root".into(), json!(root));
        context.insert("site".into(), self.site_context());
        context.insert("nav".into(), json!(nav));
        context.insert("has".into(), Value::Object(has));
        context.insert(
            "page".into(),
            json!({ "title": title, "description": Value::Null }),
        );
        context.insert("theme".into(), json!({
            "accent": self.config.theme.accent,
            "accent_dark": self.config.theme.accent_dark,
        }));
        context
    }

    fn write(&self, path: &str, template: &str, context: Map<String, Value>) -> Result<()> {
        let template = self
            .env
            .get_template(template)
            .with_context(|| format!("no template named {template}"))?;
        let html = template
            .render(Value::Object(context))
            .with_context(|| format!("rendering {path}"))?;
        write_file(&self.out.join(path), html.as_bytes())
    }

    // ------------------------------------------------------------------ pages

    pub fn build(&mut self, content: Option<&Path>) -> Result<()> {
        let content_files = match content {
            Some(dir) => collect_content(dir)?,
            None => Vec::new(),
        };

        // The nav needs content page titles, and content pages need the nav, so
        // titles are read first and bodies rendered afterwards.
        let sections: Vec<(String, String, String)> = content_files
            .iter()
            .filter(|f| f.is_markdown && f.section_id.is_some())
            .map(|f| {
                (
                    f.section_id.clone().unwrap(),
                    f.title.clone(),
                    f.out_path.clone(),
                )
            })
            .collect();
        self.build_sections(&sections);

        self.render_options()?;
        self.render_packages()?;
        self.render_catalog()?;
        self.render_hosts()?;
        self.render_lib()?;
        self.render_flake()?;
        self.render_content(&content_files)?;
        self.render_landing(&content_files)?;
        self.render_search_index()?;
        self.render_assets()?;
        Ok(())
    }

    fn render_landing(&self, content: &[ContentFile]) -> Result<()> {
        let path = "index.html";
        let mut context = self.base_context(path, "overview", "Overview");

        let body = content
            .iter()
            .find(|f| f.out_path == "index.html")
            .map(|f| self.renderer(&root_for(path)).render(&f.body));

        let option_count: usize = self.docs.option_sets.iter().map(|s| s.options.len()).sum();
        let lib_count: usize = self
            .docs
            .lib_namespaces
            .iter()
            .map(|n| n.entries.len())
            .sum();

        let mut cards = Vec::new();
        if option_count > 0 {
            cards.push(json!({
                "title": "Options", "url": "options/index.html", "count": option_count,
                "blurb": "Every option the modules declare, searchable in one place.",
            }));
        }
        if !self.docs.packages.is_empty() {
            cards.push(json!({
                "title": "Packages", "url": "packages/index.html",
                "count": self.package_attrs().len(),
                "blurb": "What this flake builds.",
            }));
        }
        if !self.docs.catalog.is_empty() {
            cards.push(json!({
                "title": "Packages", "url": "catalog/index.html",
                "count": self.docs.catalog.entries.len(),
                "blurb": "What this flake can install: nixpkgs names and what each means on Windows.",
            }));
        }
        if !self.docs.hosts.is_empty() {
            cards.push(json!({
                "title": "Hosts", "url": "hosts/index.html", "count": self.docs.hosts.len(),
                "blurb": "The configurations that put the modules to use.",
            }));
        }
        if lib_count > 0 {
            cards.push(json!({
                "title": "Library", "url": "lib/index.html", "count": lib_count,
                "blurb": "Nix helpers, from their doc-comments.",
            }));
        }
        cards.push(json!({
            "title": "Flake", "url": "flake/index.html", "count": self.docs.inputs.len(),
            "blurb": "Inputs and outputs.",
        }));

        context.insert("body".into(), json!(body));
        context.insert("cards".into(), json!(cards));
        self.write(path, "index.html", context)
    }

    fn render_options(&mut self) -> Result<()> {
        if self.docs.option_sets.is_empty() {
            return Ok(());
        }

        // The index.
        let path = "options/index.html";
        let root = root_for(path);
        let renderer = self.renderer(&root);
        let sets: Vec<Value> = self
            .docs
            .option_sets
            .iter()
            .zip(&self.plans)
            .map(|(set, plan)| {
                json!({
                    "id": set.id,
                    "title": display_title(&set.title, &set.id),
                    "kind": set.kind,
                    "system": set.system,
                    "count": set.options.len(),
                    "url": format!("options/{}/index.html", plan.slug),
                    "description": set.description.as_ref().map(|d| renderer.render(&d.markdown())),
                })
            })
            .collect();

        let mut context = self.base_context(path, "options", "Options");
        context.insert("sets".into(), json!(sets));
        self.write(path, "options-index.html", context)?;

        // One page per set, and one per declaring file.
        for (set, plan) in self.docs.option_sets.iter().zip(&self.plans) {
            self.render_option_set(set, plan)?;
        }
        Ok(())
    }

    fn render_option_set(&self, set: &OptionSet, plan: &SetPlan) -> Result<()> {
        let path = format!("options/{}/index.html", plan.slug);
        let root = root_for(&path);
        let renderer = self.renderer(&root);

        let set_value = json!({
            "id": set.id,
            "title": display_title(&set.title, &set.id),
            "kind": set.kind,
            "system": set.system,
            "count": set.options.len(),
            "url": format!("options/{}/index.html", plan.slug),
        });

        let modules: Vec<Value> = plan
            .modules
            .iter()
            .map(|module| {
                json!({
                    "title": module.title,
                    "file": module.file,
                    "file_url": module.file_url,
                    "count": module.options.len(),
                    "url": format!("options/{}/{}.html", plan.slug, module.slug),
                })
            })
            .collect();

        let mut context =
            self.base_context(&path, "options", &display_title(&set.title, &set.id));
        context.insert(
            "set".into(),
            merge_into(
                set_value.clone(),
                "description",
                json!(set
                    .description
                    .as_ref()
                    .map(|d| renderer.render(&d.markdown()))),
            ),
        );
        context.insert("modules".into(), json!(modules));
        self.write(&path, "options-set.html", context)?;

        for module in &plan.modules {
            self.render_module(set, plan, module, &set_value)?;
        }
        Ok(())
    }

    fn render_module(
        &self,
        set: &OptionSet,
        plan: &SetPlan,
        module: &Module,
        set_value: &Value,
    ) -> Result<()> {
        let path = format!("options/{}/{}.html", plan.slug, module.slug);
        let root = root_for(&path);
        let renderer = self.renderer(&root);

        let options: Vec<Value> = module
            .options
            .iter()
            .filter_map(|name| set.options.get(name).map(|opt| (name, opt)))
            .map(|(name, opt)| {
                let description = opt
                    .description
                    .as_ref()
                    .filter(|d| !d.is_empty())
                    .map(|d| renderer.render(&d.markdown()));

                let literal = |value: &Option<crate::model::Literal>| -> Value {
                    match value {
                        Some(lit) if lit.is_markdown() => json!(renderer.render(&lit.text())),
                        Some(lit) => {
                            let text = lit.text();
                            if text.trim().is_empty() {
                                Value::Null
                            } else {
                                json!(highlight::nix(&text))
                            }
                        }
                        None => Value::Null,
                    }
                };

                json!({
                    "name": name,
                    "anchor": anchor(name),
                    "type": opt.type_,
                    "read_only": opt.read_only,
                    "description": description,
                    "default": literal(&opt.default),
                    "example": literal(&opt.example),
                    "related_packages": opt.related_packages.as_ref()
                        .filter(|t| !t.is_empty())
                        .map(|t| renderer.render(&t.markdown())),
                    "declarations": opt.declarations.iter().map(|d| json!({
                        "name": d.name, "url": d.url,
                    })).collect::<Vec<_>>(),
                    "used_by": self.hosts_setting(&set.kind, name),
                })
            })
            .collect();

        let mut context = self.base_context(&path, "options", &module.title);
        context.insert("set".into(), set_value.clone());
        context.insert(
            "module".into(),
            json!({
                "title": module.title,
                "file": module.file,
                "file_url": module.file_url,
            }),
        );
        context.insert("options".into(), json!(options));
        self.write(&path, "options-module.html", context)
    }

    /// Hosts that set `name`, restricted to those built from the same kind of
    /// module tree -- a home configuration cannot set a NixOS option, and
    /// saying it does would be a lie the reader has no way to check.
    fn hosts_setting(&self, kind: &str, name: &str) -> Vec<Value> {
        self.docs
            .hosts
            .iter()
            .filter(|host| host.kind == kind)
            .filter(|host| host.settings.iter().any(|s| s.name == name))
            .map(|host| {
                json!({
                    "name": host.name,
                    "url": format!("hosts/{}.html", self.host_slugs[&host.name]),
                })
            })
            .collect()
    }

    fn render_packages(&mut self) -> Result<()> {
        if self.docs.packages.is_empty() {
            return Ok(());
        }

        let path = "packages/index.html";
        let mut rows = Vec::new();
        let mut indexed = Vec::new();

        for attr in self.package_attrs() {
            let entries = self.packages_for(&attr);
            let primary = entries
                .iter()
                .find(|p| p.description.is_some())
                .copied()
                .or_else(|| entries.first().copied());
            let Some(primary) = primary else { continue };

            let slug = &self.package_slugs[&attr];
            let url = format!("packages/{slug}.html");
            let systems: Vec<String> = entries
                .iter()
                .filter_map(|p| p.system.clone())
                .collect::<BTreeSet<_>>()
                .into_iter()
                .collect();

            rows.push(json!({
                "attr": attr,
                "url": url,
                "version": primary.version,
                "description": primary.description,
                "systems": systems,
                "broken": entries.iter().any(|p| p.broken),
                "unfree": entries.iter().any(|p| p.unfree),
            }));

            indexed.push(json!([
                attr,
                "package",
                primary.description.clone().unwrap_or_default(),
                url,
            ]));

            self.render_package(&attr, &entries)?;
        }
        self.pages_index.extend(indexed);

        let mut context = self.base_context(path, "packages", "Packages");
        context.insert("packages".into(), json!(rows));
        self.write(path, "packages-index.html", context)
    }

    fn render_package(&self, attr: &str, entries: &[&Package]) -> Result<()> {
        let slug = &self.package_slugs[attr];
        let path = format!("packages/{slug}.html");
        let root = root_for(&path);
        let renderer = self.renderer(&root);

        let primary = entries
            .iter()
            .find(|p| p.description.is_some())
            .copied()
            .unwrap_or(entries[0]);

        let systems: Vec<String> = entries
            .iter()
            .filter_map(|p| p.system.clone())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();
        let platforms: Vec<String> = entries
            .iter()
            .flat_map(|p| p.platforms.clone())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();
        let outputs: Vec<String> = entries
            .iter()
            .flat_map(|p| p.outputs.clone())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();

        let licenses: Vec<Value> = primary
            .licenses
            .iter()
            .map(|l| {
                json!({
                    "label": l.spdx_id.clone()
                        .or_else(|| l.full_name.clone())
                        .unwrap_or_else(|| "unknown".to_string()),
                    "url": l.url,
                    "free": l.free,
                })
            })
            .collect();

        let command = match systems.first() {
            Some(_) => format!("nix build .#{attr}"),
            None => format!("nix build .#{attr}"),
        };

        let mut context = self.base_context(&path, "packages", attr);
        context.insert(
            "pkg".into(),
            json!({
                "attr": attr,
                "name": primary.name,
                "pname": primary.pname,
                "version": primary.version,
                "description": primary.description,
                "long_description": primary.long_description.as_ref()
                    .map(|d| renderer.render(d)),
                "homepage": primary.homepage,
                "main_program": primary.main_program,
                "broken": entries.iter().any(|p| p.broken),
                "unfree": entries.iter().any(|p| p.unfree),
                "licenses": licenses,
                "systems": systems,
                "platforms": platforms,
                "outputs": outputs,
                "source": primary.source.as_ref().map(|s| json!({
                    "name": s.name, "url": s.url,
                })),
                "build_command": highlight::block(&command, Some("bash")),
            }),
        );
        self.write(&path, "package.html", context)
    }

    /// The overlay's catalog: one page, one table per way of installing.
    ///
    /// A flake that installs through a package manager rather than building
    /// has no `meta` to read and no derivation to describe. What a reader wants
    /// to know is which nixpkgs names they may write, and what happens on the
    /// machine when they do -- so the page is the tables, with the nixpkgs
    /// description beside each name to say what the program is.
    fn render_catalog(&mut self) -> Result<()> {
        if self.docs.catalog.is_empty() {
            return Ok(());
        }

        let path = "catalog/index.html";
        let root = root_for(path);

        let row = |e: &crate::model::CatalogEntry| {
            let anchor = prefixed_anchor("pkg-", &e.attr);
            json!({
                "attr": e.attr,
                "anchor": anchor,
                "id": e.id,
                "scope": e.scope,
                "program_dir": e.program_dir,
                "main_program": e.main_program,
                "description": e.description,
                "homepage": e.homepage,
                "version": e.version,
                "available": e.available,
            })
        };

        let mut by_kind: BTreeMap<&str, Vec<Value>> = BTreeMap::new();
        let mut indexed = Vec::new();
        let mut sorted: Vec<&crate::model::CatalogEntry> = self.docs.catalog.entries.iter().collect();
        sorted.sort_by(|a, b| a.attr.cmp(&b.attr));
        for entry in sorted {
            by_kind
                .entry(entry.kind.as_str())
                .or_default()
                .push(row(entry));

            let what = match entry.kind.as_str() {
                "font" => "font package",
                "portable" => "portable package",
                _ if !entry.available => "package (no Windows build)",
                _ => "winget package",
            };
            let summary = match (&entry.description, &entry.id) {
                (Some(d), _) if !d.trim().is_empty() => d.clone(),
                (_, Some(id)) => id.clone(),
                _ => String::new(),
            };
            indexed.push(json!([
                format!("pkgs.{}", entry.attr),
                what,
                summary,
                format!("{path}#{}", prefixed_anchor("pkg-", &entry.attr)),
            ]));
        }
        self.pages_index.extend(indexed);

        let font_sets: Vec<Value> = self
            .docs
            .catalog
            .font_sets
            .iter()
            .map(|set| {
                json!({
                    "attr": set.attr,
                    "count": set.count,
                    "description": set.description,
                })
            })
            .collect();

        let mut context = self.base_context(path, "catalog", "Packages");
        context.insert("winget".into(), json!(by_kind.remove("winget").unwrap_or_default()));
        context.insert("fonts".into(), json!(by_kind.remove("font").unwrap_or_default()));
        context.insert("portable".into(), json!(by_kind.remove("portable").unwrap_or_default()));
        context.insert("font_sets".into(), json!(font_sets));
        context.insert("count".into(), json!(self.docs.catalog.entries.len()));
        context.insert(
            "lib_url".into(),
            json!(self
                .lib_urls
                .get("pkgs.winpkgs.fromWinget")
                .map(|u| format!("{root}{u}"))),
        );
        self.write(path, "catalog.html", context)
    }

    fn render_hosts(&mut self) -> Result<()> {
        if self.docs.hosts.is_empty() {
            return Ok(());
        }

        let path = "hosts/index.html";

        // The index carries the same grouping as the sidebar, so the two views
        // of the same six configurations cannot disagree about how many
        // machines there are.
        let groups: Vec<Value> = self
            .host_groups()
            .iter()
            .map(|group| {
                let rows: Vec<Value> = group
                    .members
                    .iter()
                    .filter_map(|(label, name)| {
                        let host = self.host(name)?;
                        Some(json!({
                            "label": label,
                            "name": host.name,
                            "kind": host.kind,
                            "tag": kind_tag(&host.kind),
                            "system": host.system,
                            "state_version": host.state_version,
                            "module_count": host.modules_enabled.len(),
                            "url": self.host_url(name),
                        }))
                    })
                    .collect();

                json!({
                    "name": group.name,
                    "anchor": prefixed_anchor("machine-", &group.name),
                    // A machine has no page; a configuration that grouped with
                    // nothing is its own heading and keeps its link.
                    "url": if group.is_machine {
                        Value::Null
                    } else {
                        json!(group.members.first().map(|(_, name)| self.host_url(name)))
                    },
                    "is_machine": group.is_machine,
                    "configurations": rows,
                })
            })
            .collect();

        for host in &self.docs.hosts {
            self.pages_index.push(json!([
                host.name,
                format!("{} host", host.kind),
                host.system.clone().unwrap_or_default(),
                format!("hosts/{}.html", self.host_slugs[&host.name]),
            ]));
        }

        let mut context = self.base_context(path, "hosts", "Hosts");
        context.insert("machines".into(), json!(groups));
        context.insert("count".into(), json!(self.docs.hosts.len()));
        self.write(path, "hosts-index.html", context)?;

        for host in &self.docs.hosts {
            self.render_host(host)?;
        }
        Ok(())
    }

    fn render_host(&self, host: &Host) -> Result<()> {
        let path = format!("hosts/{}.html", self.host_slugs[&host.name]);

        // Settings are grouped by the file they were written in. A host's own
        // configuration.nix and the profile it shares with its siblings are
        // different kinds of statement, and reading them interleaved by option
        // name hides which is which.
        let mut files: Vec<(String, Option<String>, Vec<Value>)> = Vec::new();
        for setting in &host.settings {
            let url = self
                .option_urls
                .get(&(host.kind.clone(), setting.name.clone()))
                .or_else(|| self.any_option_urls.get(&setting.name))
                .cloned();

            for definition in &setting.definitions {
                let row = json!({
                    "name": setting.name,
                    "url": url,
                    "value": highlight::nix(definition.value.as_deref().unwrap_or("")),
                });
                match files.iter_mut().find(|(f, _, _)| *f == definition.file) {
                    Some((_, _, rows)) => rows.push(row),
                    None => files.push((
                        definition.file.clone(),
                        definition.url.clone(),
                        vec![row],
                    )),
                }
            }
        }

        let files: Vec<Value> = files
            .into_iter()
            .map(|(file, url, settings)| {
                json!({
                    "file": file,
                    "url": url,
                    "anchor": file_anchor(&file),
                    "settings": settings,
                })
            })
            .collect();

        let modules: Vec<Value> = host
            .modules_enabled
            .iter()
            .map(|name| json!({ "name": name, "url": self.namespace_url(&host.kind, name) }))
            .collect();

        // Facts describe the machine rather than the source, so they carry no
        // file and get no source link. The name is still linked to the
        // documentation for that namespace where one exists -- that says what
        // the keys in the value mean, which is a different claim from "this was
        // written here".
        let renderer = self.renderer(&root_for(&path));
        let facts: Vec<Value> = renderable_facts(&host.facts)
            .into_iter()
            .map(|fact| {
                json!({
                    "name": fact.name,
                    "anchor": prefixed_anchor("fact-", &fact.name),
                    "url": self.namespace_url(&host.kind, &fact.name),
                    "description": fact.description.as_ref()
                        .filter(|d| !d.is_empty())
                        .map(|d| renderer.render(&d.markdown())),
                    "value": highlight::nix(fact.value.as_deref().unwrap_or("")),
                })
            })
            .collect();

        let mut context = self.base_context(&path, "hosts", &host.name);
        context.insert(
            "host".into(),
            json!({
                "name": host.name,
                "kind": host.kind,
                "system": host.system,
                "state_version": host.state_version,
                "sources": host.sources.iter().map(|s| json!({
                    "file": s.file, "url": s.url,
                })).collect::<Vec<_>>(),
                "modules": modules,
                "facts": facts,
                "files": files,
            }),
        );
        self.write(&path, "host.html", context)
    }

    fn render_lib(&mut self) -> Result<()> {
        if self.docs.lib_namespaces.is_empty() {
            return Ok(());
        }

        let path = "lib/index.html";
        let root = root_for(path);
        let renderer = self.renderer(&root);

        let namespaces: Vec<Value> = self
            .docs
            .lib_namespaces
            .iter()
            .map(|ns| {
                json!({
                    "name": ns.name,
                    "count": ns.entries.len(),
                    "url": format!("lib/{}.html", self.namespace_slugs[&ns.name]),
                    "description": ns.description.as_ref()
                        .filter(|d| !d.is_empty())
                        .map(|d| renderer.render(&d.markdown())),
                })
            })
            .collect();

        let mut indexed = Vec::new();
        for ns in &self.docs.lib_namespaces {
            let page = format!("lib/{}.html", self.namespace_slugs[&ns.name]);
            for entry in &ns.entries {
                let full = qualified(ns, entry);
                indexed.push(json!([
                    full,
                    "library function",
                    entry
                        .description
                        .as_ref()
                        .map(|d| markdown::summarize(&d.markdown(), 90))
                        .unwrap_or_default(),
                    format!("{page}#{}", anchor(&full)),
                ]));
            }
        }
        drop(renderer);
        self.pages_index.extend(indexed);

        let mut context = self.base_context(path, "lib", "Library");
        context.insert("namespaces".into(), json!(namespaces));
        self.write(path, "lib-index.html", context)?;

        for ns in &self.docs.lib_namespaces {
            self.render_namespace(ns)?;
        }
        Ok(())
    }

    fn render_namespace(&self, ns: &LibNamespace) -> Result<()> {
        let path = format!("lib/{}.html", self.namespace_slugs[&ns.name]);
        let root = root_for(&path);
        let renderer = self.renderer(&root);

        let entries: Vec<Value> = ns
            .entries
            .iter()
            .map(|entry| {
                let full = qualified(ns, entry);
                json!({
                    "name": full,
                    "anchor": anchor(&full),
                    "description": entry.description.as_ref()
                        .filter(|d| !d.is_empty())
                        .map(|d| renderer.render(&d.markdown())),
                    // Not highlighted as Nix: `a :: b -> c` is a type
                    // signature, not an expression, and the Nix grammar marks
                    // half of it invalid.
                    "fn_type": entry.fn_type.as_ref().map(|t| highlight::block(t, None)),
                    "example": entry.example.as_ref()
                        .filter(|e| !e.is_empty())
                        .map(|e| renderer.render(&e.markdown())),
                    "args": lib_args(&entry.args).into_iter().map(|(name, doc)| json!({
                        "name": name,
                        "description": doc.map(|d| renderer.render_inline(&d)),
                    })).collect::<Vec<_>>(),
                    "file": entry.file,
                    "url": entry.url,
                })
            })
            .collect();

        let mut context = self.base_context(&path, "lib", &ns.name);
        context.insert(
            "ns".into(),
            json!({
                "name": ns.name,
                "description": ns.description.as_ref()
                    .filter(|d| !d.is_empty())
                    .map(|d| renderer.render(&d.markdown())),
            }),
        );
        context.insert("entries".into(), json!(entries));
        self.write(&path, "lib-namespace.html", context)
    }

    fn render_flake(&self) -> Result<()> {
        let path = "flake/index.html";

        let inputs: Vec<Value> = self
            .docs
            .inputs
            .iter()
            .map(|input| {
                let rev_url = match (&input.url, &input.rev, input.type_.as_deref()) {
                    (Some(url), Some(rev), Some("github" | "gitlab" | "sourcehut"))
                        if !rev.is_empty() =>
                    {
                        Some(format!("{url}/tree/{rev}"))
                    }
                    _ => None,
                };
                let origin = match (&input.type_, &input.owner, &input.repo) {
                    (Some(kind), Some(owner), Some(repo)) => Some(format!("{kind}:{owner}/{repo}")),
                    (Some(kind), _, _) => Some(kind.clone()),
                    _ => None,
                };
                json!({
                    "name": input.name,
                    "url": input.url,
                    "ref": input.ref_,
                    "rev": input.rev,
                    "rev_short": input.rev.as_deref().map(abbreviate),
                    "rev_url": rev_url,
                    "origin": origin,
                    "is_flake": input.is_flake,
                    "last_modified": input.last_modified.map(epoch_to_date),
                    "follows": input.follows.iter()
                        .map(|(k, v)| format!("{k} → {}", v.join("/")))
                        .collect::<Vec<_>>(),
                })
            })
            .collect();

        let mut context = self.base_context(path, "flake", "Flake");
        context.insert("inputs".into(), json!(inputs));
        context.insert("outputs".into(), json!(self.output_groups(&root_for(path))));
        self.write(path, "flake.html", context)
    }

    /// The outputs table, one group per well-known attribute. `packages` is
    /// absent on purpose -- it has a section of its own, and two lists of the
    /// same names is one list too many.
    fn output_groups(&self, root: &str) -> Vec<Value> {
        let out = &self.docs.outputs;
        let mut groups = Vec::new();

        let code = |text: &str| format!("<code>{}</code>", highlight::escape(text));
        let plain = |text: &str| highlight::escape(text);

        if !out.apps.is_empty() {
            groups.push(json!({
                "title": "Apps", "anchor": "apps",
                "columns": ["Name", "System", "Description"],
                "rows": out.apps.iter().map(|a| json!([
                    code(&a.name),
                    a.system.as_deref().map(&code).unwrap_or_else(|| "—".into()),
                    a.description.as_deref().map(&plain).unwrap_or_else(|| "—".into()),
                ])).collect::<Vec<_>>(),
                "note": Value::Null,
            }));
        }

        if !out.templates.is_empty() {
            groups.push(json!({
                "title": "Templates", "anchor": "templates",
                "columns": ["Name", "Description"],
                "rows": out.templates.iter().map(|t| json!([
                    code(t.name.as_deref().unwrap_or("—")),
                    t.description.as_deref().map(&plain).unwrap_or_else(|| "—".into()),
                ])).collect::<Vec<_>>(),
                "note": Value::Null,
            }));
        }

        if out.modules.values().any(|names| !names.is_empty()) {
            let mut rows = Vec::new();
            for (output, names) in &out.modules {
                for name in names {
                    rows.push(json!([code(output), code(name)]));
                }
            }
            groups.push(json!({
                "title": "Module trees", "anchor": "modules",
                "columns": ["Output", "Attribute"], "rows": rows, "note": Value::Null,
            }));
        }

        if out.configurations.values().any(|names| !names.is_empty()) {
            let mut rows = Vec::new();
            for (output, names) in &out.configurations {
                for name in names {
                    let cell = match self.host_slugs.get(name) {
                        Some(slug) => format!(
                            "<a href=\"{}hosts/{}.html\">{}</a>",
                            highlight::escape(root),
                            highlight::escape(slug),
                            code(name)
                        ),
                        None => code(name),
                    };
                    rows.push(json!([code(output), cell]));
                }
            }
            groups.push(json!({
                "title": "Configurations", "anchor": "configurations",
                "columns": ["Output", "Attribute"], "rows": rows, "note": Value::Null,
            }));
        }

        for (title, anchor_id, names) in [
            ("Overlays", "overlays", &out.overlays),
            ("Library attributes", "lib", &out.lib),
            ("Other outputs", "other", &out.other),
        ] {
            if names.is_empty() {
                continue;
            }
            groups.push(json!({
                "title": title, "anchor": anchor_id,
                "columns": ["Attribute"],
                "rows": names.iter().map(|n| json!([code(n)])).collect::<Vec<_>>(),
                "note": Value::Null,
            }));
        }

        for (title, anchor_id, entries) in [
            ("Checks", "checks", &out.checks),
            ("Dev shells", "devshells", &out.dev_shells),
            ("Formatter", "formatter", &out.formatter),
        ] {
            if entries.is_empty() {
                continue;
            }
            groups.push(json!({
                "title": title, "anchor": anchor_id,
                "columns": ["System", "Name"],
                "rows": entries.iter().map(|e| json!([
                    e.system.as_deref().map(&code).unwrap_or_else(|| "—".into()),
                    e.name.as_deref().map(&code).unwrap_or_else(|| "—".into()),
                ])).collect::<Vec<_>>(),
                "note": Value::Null,
            }));
        }

        groups
    }

    fn render_content(&self, files: &[ContentFile]) -> Result<()> {
        for file in files {
            if !file.is_markdown {
                write_file(&self.out.join(&file.out_path), &file.raw)?;
                continue;
            }
            // The landing page is rendered by render_landing, which folds the
            // Markdown into the generated overview rather than replacing it
            // wholesale.
            if file.out_path == "index.html" {
                continue;
            }

            let root = root_for(&file.out_path);
            let body = self.renderer(&root).render(&file.body);
            let section = file.section_id.clone().unwrap_or_default();

            let mut context = self.base_context(&file.out_path, &section, &file.title);
            context.insert("body".into(), json!(body));
            self.write(&file.out_path, "content.html", context)?;
        }
        Ok(())
    }

    /// The search index: options first, since option search is what the index
    /// exists for, then everything else for the header drop-down.
    fn render_search_index(&self) -> Result<()> {
        let sets: Vec<Value> = self
            .docs
            .option_sets
            .iter()
            .map(|set| {
                json!({
                    "id": set.id,
                    "title": display_title(&set.title, &set.id),
                    "kind": set.kind,
                })
            })
            .collect();

        let mut items = Vec::new();
        for (set_index, (set, plan)) in self.docs.option_sets.iter().zip(&self.plans).enumerate() {
            for module in &plan.modules {
                let page = format!("options/{}/{}.html", plan.slug, module.slug);
                for name in &module.options {
                    let Some(opt) = set.options.get(name) else {
                        continue;
                    };
                    let summary = opt
                        .description
                        .as_ref()
                        .map(|d| markdown::summarize(&d.markdown(), 120))
                        .unwrap_or_default();
                    items.push(json!([
                        name,
                        set_index,
                        opt.type_.clone().unwrap_or_default(),
                        summary,
                        format!("{page}#{}", anchor(name)),
                    ]));
                }
            }
        }

        let index = json!({
            "sets": sets,
            "items": items,
            "pages": self.pages_index,
        });
        write_file(
            &self.out.join("search-index.json"),
            serde_json::to_string(&index)?.as_bytes(),
        )
    }

    fn render_assets(&self) -> Result<()> {
        for name in RENDERED_ASSETS {
            let template = self
                .env
                .get_template(name)
                .with_context(|| format!("no template named {name}"))?;
            let rendered = template.render(json!({
                "theme": {
                    "accent": self.config.theme.accent,
                    "accent_dark": self.config.theme.accent_dark,
                },
                "site": self.site_context(),
            }))?;
            write_file(&self.out.join(name), rendered.as_bytes())?;
        }

        for name in COPIED_ASSETS {
            let source = self
                .env
                .get_template(name)
                .with_context(|| format!("no template named {name}"))?;
            write_file(&self.out.join(name), source.source().as_bytes())?;
        }
        Ok(())
    }
}

// --------------------------------------------------------------------- content

struct ContentFile {
    out_path: String,
    is_markdown: bool,
    title: String,
    section_id: Option<String>,
    body: String,
    raw: Vec<u8>,
}

/// Read `--content`, turning Markdown into pages and passing everything else
/// through unchanged. Images, diagrams and downloads live beside the prose that
/// references them, and a relative `![](diagram.svg)` has to keep working.
fn collect_content(dir: &Path) -> Result<Vec<ContentFile>> {
    let mut files = Vec::new();
    walk(dir, dir, &mut files)?;
    files.sort_by(|a, b| a.out_path.cmp(&b.out_path));
    Ok(files)
}

fn walk(root: &Path, dir: &Path, out: &mut Vec<ContentFile>) -> Result<()> {
    let mut entries: Vec<PathBuf> = std::fs::read_dir(dir)
        .with_context(|| format!("reading content directory {}", dir.display()))?
        .map(|e| e.map(|e| e.path()))
        .collect::<std::result::Result<_, _>>()?;
    entries.sort();

    for path in entries {
        if path.is_dir() {
            walk(root, &path, out)?;
            continue;
        }

        let relative = path
            .strip_prefix(root)
            .unwrap_or(&path)
            .to_string_lossy()
            .replace('\\', "/");
        let extension = path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();

        if extension == "md" || extension == "markdown" {
            let text = std::fs::read_to_string(&path)
                .with_context(|| format!("reading {}", path.display()))?;
            let (front_title, body) = split_front_matter(&text);
            let stem = relative
                .rsplit_once('.')
                .map(|(s, _)| s.to_string())
                .unwrap_or_else(|| relative.clone());
            let out_path = format!("{stem}.html");
            let title = front_title
                .or_else(|| first_heading(&body))
                .unwrap_or_else(|| humanize(&stem));
            let section_id = if out_path == "index.html" {
                None
            } else {
                Some(stem.clone())
            };

            out.push(ContentFile {
                out_path,
                is_markdown: true,
                title,
                section_id,
                body,
                raw: Vec::new(),
            });
        } else {
            let raw =
                std::fs::read(&path).with_context(|| format!("reading {}", path.display()))?;
            out.push(ContentFile {
                out_path: relative,
                is_markdown: false,
                title: String::new(),
                section_id: None,
                body: String::new(),
                raw,
            });
        }
    }
    Ok(())
}

/// A leading `---` block, of which only `title:` is read. Nothing else in it
/// would have anywhere to go.
fn split_front_matter(text: &str) -> (Option<String>, String) {
    let Some(rest) = text.strip_prefix("---\n") else {
        return (None, text.to_string());
    };
    let Some(end) = rest.find("\n---") else {
        return (None, text.to_string());
    };
    let (front, after) = rest.split_at(end);
    let body = after
        .trim_start_matches('\n')
        .trim_start_matches("---")
        .trim_start_matches('\n')
        .to_string();

    let title = front.lines().find_map(|line| {
        line.split_once(':')
            .filter(|(key, _)| key.trim() == "title")
            .map(|(_, value)| value.trim().trim_matches('"').trim_matches('\'').to_string())
    });
    (title, body)
}

fn first_heading(markdown: &str) -> Option<String> {
    markdown.lines().find_map(|line| {
        line.strip_prefix("# ")
            .map(|h| h.trim().trim_matches('`').to_string())
    })
}

fn humanize(stem: &str) -> String {
    let leaf = stem.rsplit('/').next().unwrap_or(stem);
    let mut result = String::new();
    for (index, word) in leaf.split(['-', '_']).enumerate() {
        if index > 0 {
            result.push(' ');
        }
        let mut chars = word.chars();
        if let Some(first) = chars.next() {
            result.extend(first.to_uppercase());
            result.push_str(chars.as_str());
        }
    }
    result
}

// --------------------------------------------------------------------- helpers

fn load_templates<'a>(template_dir: Option<&Path>) -> Result<Environment<'a>> {
    let mut env = Environment::new();
    env.set_keep_trailing_newline(true);
    env.set_formatter(format_escaped);

    for file in TEMPLATES.files() {
        let name = file.path().to_string_lossy().to_string();
        let source = String::from_utf8_lossy(file.contents()).into_owned();
        env.add_template_owned(name, source)?;
    }

    // A --template-dir file replaces the built-in of the same name. Overriding
    // one template must not mean vendoring all of them, so this is a merge
    // rather than a swap.
    if let Some(dir) = template_dir {
        let entries = std::fs::read_dir(dir)
            .with_context(|| format!("reading template directory {}", dir.display()))?;
        for entry in entries {
            let path = entry?.path();
            if !path.is_file() {
                continue;
            }
            let name = path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default();
            let source = std::fs::read_to_string(&path)
                .with_context(|| format!("reading template {}", path.display()))?;
            env.add_template_owned(name, source)?;
        }
    }

    Ok(env)
}

/// Auto-escaping that leaves `/` alone.
///
/// minijinja's default escapes it to `&#x2f;`, which is correct HTML and
/// completely unreadable in a page that is mostly URLs and file paths. A slash
/// is not dangerous in any HTML context this generator emits -- it can neither
/// close a tag on its own nor break out of a quoted attribute -- so the entity
/// buys nothing but noise, and makes "does this page contain a root-relative
/// link" impossible to answer by reading it.
fn format_escaped(
    out: &mut minijinja::Output,
    state: &minijinja::State,
    value: &minijinja::value::Value,
) -> std::result::Result<(), minijinja::Error> {
    if value.is_safe() || !matches!(state.auto_escape(), minijinja::AutoEscape::Html) {
        return minijinja::escape_formatter(out, state, value);
    }
    if value.is_undefined() || value.is_none() {
        return Ok(());
    }

    let owned;
    let text = match value.as_str() {
        Some(text) => text,
        None => {
            owned = value.to_string();
            &owned
        }
    };

    for c in text.chars() {
        match c {
            '&' => out.write_str("&amp;")?,
            '<' => out.write_str("&lt;")?,
            '>' => out.write_str("&gt;")?,
            '"' => out.write_str("&quot;")?,
            '\'' => out.write_str("&#39;")?,
            _ => out.write_str(c.encode_utf8(&mut [0u8; 4]))?,
        }
    }
    Ok(())
}

/// Split a set's options into one group per declaring file.
///
/// The first declaration is the one that counts: an option declared in two
/// places was declared once and then extended, and the page a reader wants is
/// the one where it was introduced.
fn group_options(set: &OptionSet) -> Vec<Module> {
    let mut by_file: BTreeMap<String, (Option<String>, Vec<String>)> = BTreeMap::new();

    for (name, option) in &set.options {
        let (file, url) = match option.declarations.first() {
            Some(decl) => (decl.name.clone(), decl.url.clone()),
            None => ("(undeclared)".to_string(), None),
        };
        let entry = by_file.entry(file).or_insert((url, Vec::new()));
        entry.1.push(name.clone());
    }

    let mut slugs: HashMap<String, usize> = HashMap::new();
    by_file
        .into_iter()
        .map(|(file, (url, options))| {
            let slug = unique(&mut slugs, slugify(file.trim_end_matches(".nix")));
            Module {
                title: module_title(&file, &options),
                file,
                file_url: url,
                slug,
                options,
            }
        })
        .collect()
}

/// Name a group by what its options have in common.
///
/// `modules/nixos/audio.nix` declares `stewos.audio.enable` and
/// `stewos.audio.lowLatency`, and "stewos.audio" is what a reader is looking
/// for -- the file path is an implementation detail of where it happens to be
/// written. A file whose options share nothing keeps the path.
fn module_title(file: &str, options: &[String]) -> String {
    if options.is_empty() {
        return file.to_string();
    }

    let mut common: Vec<&str> = options[0].split('.').collect();
    for name in &options[1..] {
        let parts: Vec<&str> = name.split('.').collect();
        let shared = common
            .iter()
            .zip(&parts)
            .take_while(|(a, b)| a == b)
            .count();
        common.truncate(shared);
        if common.is_empty() {
            break;
        }
    }

    // A single option would otherwise name the page after itself, which reads
    // as though the page documents one thing when it documents its namespace.
    if options.len() == 1 && common.len() > 1 {
        common.pop();
    }

    if common.is_empty() {
        file.to_string()
    } else {
        common.join(".")
    }
}

fn qualified(ns: &LibNamespace, entry: &crate::model::LibEntry) -> String {
    match (&entry.prefix, &entry.category) {
        (Some(prefix), Some(category)) if !prefix.is_empty() && !category.is_empty() => {
            format!("{prefix}.{category}.{}", entry.name)
        }
        _ if !ns.name.is_empty() => format!("{}.{}", ns.name, entry.name),
        _ => entry.name.clone(),
    }
}

/// Normalise nixdoc's argument list.
///
/// The shape has changed across nixdoc releases -- a bare string, a record, and
/// a `Flat`/`Pattern` enum have all been emitted -- and a documentation
/// generator that fails to build because an argument list is one layer deeper
/// than it was is not much of a generator. Anything unrecognised is dropped
/// rather than guessed at.
fn lib_args(values: &[Value]) -> Vec<(String, Option<String>)> {
    fn one(value: &Value, out: &mut Vec<(String, Option<String>)>) {
        match value {
            Value::String(s) => out.push((s.clone(), None)),
            Value::Array(items) => items.iter().for_each(|item| one(item, out)),
            Value::Object(map) => {
                if let Some(name) = map.get("name").and_then(Value::as_str) {
                    let doc = map
                        .get("doc")
                        .or_else(|| map.get("description"))
                        .and_then(Value::as_str)
                        .map(str::to_string);
                    out.push((name.to_string(), doc));
                    return;
                }
                // The externally tagged enum form: { "Flat": {...} } or
                // { "Pattern": [...] }.
                for nested in map.values() {
                    one(nested, out);
                }
            }
            _ => {}
        }
    }

    let mut out = Vec::new();
    values.iter().for_each(|value| one(value, &mut out));
    out
}

/// The facts worth putting on a page.
///
/// A fact whose value is blank says nothing, and rendering it would produce a
/// named heading over an empty code block. Dropping it here rather than in the
/// template is what lets the section's presence be decided by one rule: it is
/// shown when this returns anything, and `huntress-mbp` -- a darwin host, whose
/// `mkDarwinHost` takes no user -- correctly gets no heading at all.
///
/// Nothing is deduplicated. The same fact appears on both halves of a machine
/// on purpose, and the two halves are not guaranteed to agree: on
/// framework-desktop the system side reports `groups = [ "nordvpn" ]` and the
/// user side `groups = [ ]`. Each host reports what is true of it.
fn renderable_facts(facts: &[crate::model::Fact]) -> Vec<&crate::model::Fact> {
    facts
        .iter()
        .filter(|fact| !fact.name.trim().is_empty())
        .filter(|fact| fact.value.as_deref().is_some_and(|v| !v.trim().is_empty()))
        .collect()
}

/// A set's display title, falling back to its id rather than to nothing.
fn display_title(title: &str, id: &str) -> String {
    if title.trim().is_empty() {
        id.to_string()
    } else {
        title.to_string()
    }
}

fn merge_into(mut value: Value, key: &str, extra: Value) -> Value {
    if let Value::Object(map) = &mut value {
        map.insert(key.to_string(), extra);
    }
    value
}

/// The `../` prefix a page at `path` needs to reach the site root.
fn root_for(path: &str) -> String {
    "../".repeat(path.matches('/').count())
}

/// A filesystem-safe, URL-safe name.
fn slugify(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut last_dash = false;
    for c in text.chars() {
        if c.is_ascii_alphanumeric() || c == '.' || c == '_' {
            out.push(c.to_ascii_lowercase());
            last_dash = false;
        } else if !last_dash {
            out.push('-');
            last_dash = true;
        }
    }
    let trimmed = out.trim_matches('-').trim_matches('.').to_string();
    if trimmed.is_empty() {
        "index".to_string()
    } else {
        trimmed
    }
}

/// An HTML `id` for an option or a library function. Dots are kept:
/// `#opt-stewos.audio.enable` is a URL a reader can read, and a slugified one
/// is not.
fn anchor(name: &str) -> String {
    prefixed_anchor("opt-", name)
}

/// The same, for the per-file sections of a host page.
fn file_anchor(file: &str) -> String {
    prefixed_anchor("file-", file)
}

fn prefixed_anchor(prefix: &str, name: &str) -> String {
    let mut out = String::from(prefix);
    for c in name.chars() {
        if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') {
            out.push(c);
        } else {
            out.push('-');
        }
    }
    out
}

fn unique(seen: &mut HashMap<String, usize>, candidate: String) -> String {
    let count = seen.entry(candidate.clone()).or_insert(0);
    *count += 1;
    if *count == 1 {
        candidate
    } else {
        format!("{candidate}-{}", *count)
    }
}

fn abbreviate(rev: &str) -> String {
    rev.chars().take(7).collect()
}

/// Nix records `lastModifiedDate` as `YYYYMMDDHHMMSS` and the lock records
/// `lastModified` as an epoch. Both mean a day, and a day is all a reader wants.
fn format_timestamp(value: &Value) -> Option<String> {
    match value {
        Value::Number(n) => n.as_i64().map(epoch_to_date),
        Value::String(s) => {
            let digits: String = s.chars().filter(|c| c.is_ascii_digit()).collect();
            if digits.len() >= 8 {
                Some(format!(
                    "{}-{}-{}",
                    &digits[0..4],
                    &digits[4..6],
                    &digits[6..8]
                ))
            } else if digits.is_empty() {
                None
            } else {
                digits.parse::<i64>().ok().map(epoch_to_date)
            }
        }
        _ => None,
    }
}

/// Epoch seconds to `YYYY-MM-DD`, UTC.
///
/// Hand-rolled rather than pulled from a date crate: the whole requirement is
/// one civil-from-days conversion, and a documentation generator has no other
/// reason to know what a time zone is.
fn epoch_to_date(epoch: i64) -> String {
    let days = epoch.div_euclid(86_400);
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let day_of_era = z - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let mp = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if month <= 2 { year + 1 } else { year };
    format!("{year:04}-{month:02}-{day:02}")
}

fn write_file(path: &Path, contents: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating {}", parent.display()))?;
    }
    std::fs::write(path, contents).with_context(|| format!("writing {}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn root_is_relative_at_every_depth() {
        assert_eq!(root_for("index.html"), "");
        assert_eq!(root_for("options/index.html"), "../");
        assert_eq!(root_for("options/nixos/audio.html"), "../../");
    }

    #[test]
    fn module_title_is_the_common_prefix() {
        let options = vec![
            "stewos.audio.enable".to_string(),
            "stewos.audio.lowLatency".to_string(),
        ];
        assert_eq!(module_title("modules/nixos/audio.nix", &options), "stewos.audio");
    }

    #[test]
    fn a_lone_option_names_its_namespace() {
        let options = vec!["stewos.zsa.enable".to_string()];
        assert_eq!(module_title("modules/nixos/zsa.nix", &options), "stewos.zsa");
    }

    #[test]
    fn unrelated_options_keep_the_file_name() {
        let options = vec!["programs.nh.enable".to_string(), "stewos.zsa.enable".to_string()];
        assert_eq!(module_title("modules/misc.nix", &options), "modules/misc.nix");
    }

    fn fact(name: &str, value: Option<&str>) -> crate::model::Fact {
        crate::model::Fact {
            name: name.to_string(),
            description: None,
            value: value.map(str::to_string),
        }
    }

    #[test]
    fn a_host_with_no_facts_gets_no_facts_section() {
        // huntress-mbp: mkDarwinHost takes no user, so the extractor reports an
        // empty list and the page must not grow an empty heading.
        assert!(renderable_facts(&[]).is_empty());
    }

    #[test]
    fn a_fact_with_a_real_value_is_rendered() {
        let facts = vec![fact("stewos.user", Some("{\n  username = \"caleb\";\n}"))];
        let kept = renderable_facts(&facts);
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].name, "stewos.user");
    }

    #[test]
    fn a_fact_with_no_usable_value_is_dropped_rather_than_shown_empty() {
        let facts = vec![
            fact("stewos.user", None),
            fact("stewos.other", Some("   \n ")),
            fact("", Some("true")),
        ];
        assert!(renderable_facts(&facts).is_empty());
    }

    #[test]
    fn identical_facts_on_two_hosts_are_both_kept() {
        // The same fact appears on both halves of a machine by design, and the
        // two are not guaranteed equal -- nothing here deduplicates or compares.
        let system = vec![fact("stewos.user", Some("{ groups = [ \"nordvpn\" ]; }"))];
        let user = vec![fact("stewos.user", Some("{ groups = [ ]; }"))];
        assert_eq!(renderable_facts(&system).len(), 1);
        assert_eq!(renderable_facts(&user).len(), 1);
        assert_ne!(
            renderable_facts(&system)[0].value,
            renderable_facts(&user)[0].value
        );
    }

    #[test]
    fn dates_convert() {
        assert_eq!(epoch_to_date(0), "1970-01-01");
        assert_eq!(epoch_to_date(1_755_000_000), "2025-08-12");
    }
}
