//! Merging several `docs.json` documents into one.
//!
//! Evaluating a module tree needs a package set for that tree's system, and not
//! every machine can produce one -- a darwin option set reads fine from Linux,
//! but a NixOS host's `config` does not evaluate without a Linux builder. So the
//! extraction half may be run more than once, on more than one machine, and the
//! renderer is what puts the pieces back together.
//!
//! Everything merges by identity: option sets by `id`, packages by
//! `(system, attr)`, catalog entries by `(kind, attr)`, hosts by `name`, inputs
//! by `name`, library namespaces by `name`. Later documents win, on the
//! reasoning that the caller listed them in the order they wanted applied.

use std::collections::BTreeMap;

use crate::model::{Docs, Meta};

/// Fold `docs` into a single document, in the order given.
pub fn merge(docs: Vec<Docs>) -> Docs {
    let mut out = Docs::default();
    let mut seen_any = false;

    for doc in docs {
        if !seen_any {
            out.schema_version = doc.schema_version;
            seen_any = true;
        } else if doc.schema_version > out.schema_version {
            out.schema_version = doc.schema_version;
        }

        merge_meta(&mut out.meta, doc.meta);
        merge_option_sets(&mut out, doc.option_sets);
        merge_by(&mut out.hosts, doc.hosts, |h| h.name.clone());
        merge_by(&mut out.packages, doc.packages, |p| {
            format!("{}\u{0}{}", p.system.clone().unwrap_or_default(), p.attr)
        });
        merge_by(&mut out.catalog.entries, doc.catalog.entries, |e| {
            format!("{}\u{0}{}", e.kind, e.attr)
        });
        merge_by(&mut out.catalog.font_sets, doc.catalog.font_sets, |f| {
            f.attr.clone()
        });
        merge_by(&mut out.inputs, doc.inputs, |i| i.name.clone());
        merge_by(&mut out.lib_namespaces, doc.lib_namespaces, |n| {
            n.name.clone()
        });
        merge_outputs(&mut out.outputs, doc.outputs);
    }

    out
}

/// `meta` comes from the first document that has a non-empty value, field by
/// field: a document extracted on a machine that could not resolve the revision
/// should not blank out one that could.
fn merge_meta(into: &mut Meta, from: Meta) {
    fn fill(slot: &mut String, value: String) {
        if slot.trim().is_empty() && !value.trim().is_empty() {
            *slot = value;
        }
    }
    fn fill_opt<T>(slot: &mut Option<T>, value: Option<T>) {
        if slot.is_none() {
            *slot = value;
        }
    }

    fill(&mut into.name, from.name);
    fill(&mut into.title, from.title);
    fill_opt(&mut into.description, from.description);
    fill_opt(&mut into.repo_url, from.repo_url);
    fill_opt(&mut into.branch, from.branch);
    fill_opt(&mut into.rev, from.rev);
    fill_opt(&mut into.last_modified, from.last_modified);
}

/// Option sets merge one option at a time. Two documents describing the same
/// set is the normal case when a flake targets several systems, and the union
/// of what each machine could evaluate is the whole set.
fn merge_option_sets(out: &mut Docs, sets: Vec<crate::model::OptionSet>) {
    for set in sets {
        match out.option_sets.iter_mut().find(|s| s.id == set.id) {
            Some(existing) => {
                if !set.title.is_empty() {
                    existing.title = set.title;
                }
                if !set.kind.is_empty() {
                    existing.kind = set.kind;
                }
                if set.system.is_some() {
                    existing.system = set.system;
                }
                if set.description.is_some() {
                    existing.description = set.description;
                }
                for (name, opt) in set.options {
                    existing.options.insert(name, opt);
                }
            }
            None => out.option_sets.push(set),
        }
    }
}

/// Replace-by-key, preserving first-seen order.
fn merge_by<T, K, F>(into: &mut Vec<T>, from: Vec<T>, key: F)
where
    F: Fn(&T) -> K,
    K: Ord,
{
    let mut index: BTreeMap<K, usize> = into
        .iter()
        .enumerate()
        .map(|(i, item)| (key(item), i))
        .collect();

    for item in from {
        let k = key(&item);
        match index.get(&k) {
            Some(&i) => into[i] = item,
            None => {
                index.insert(k, into.len());
                into.push(item);
            }
        }
    }
}

/// Outputs are flat lists of names, so the union is the merge. Deduplicated by
/// the same identity the renderer displays.
fn merge_outputs(into: &mut crate::model::Outputs, from: crate::model::Outputs) {
    merge_by(&mut into.apps, from.apps, |a| {
        format!("{}\u{0}{}", a.system.clone().unwrap_or_default(), a.name)
    });
    merge_by(&mut into.templates, from.templates, |t| {
        t.name.clone().unwrap_or_default()
    });
    union(&mut into.overlays, from.overlays);
    union_by_output(&mut into.modules, from.modules);
    union_by_output(&mut into.configurations, from.configurations);
    merge_by(&mut into.checks, from.checks, system_named);
    merge_by(&mut into.dev_shells, from.dev_shells, system_named);
    merge_by(&mut into.formatter, from.formatter, |f| {
        f.system.clone().unwrap_or_default()
    });
    union(&mut into.lib, from.lib);
    union(&mut into.other, from.other);
}

fn system_named(o: &crate::model::SystemOutput) -> String {
    format!(
        "{}\u{0}{}",
        o.system.clone().unwrap_or_default(),
        o.name.clone().unwrap_or_default()
    )
}

fn union(into: &mut Vec<String>, from: Vec<String>) {
    for item in from {
        if !into.contains(&item) {
            into.push(item);
        }
    }
}

fn union_by_output(into: &mut crate::model::ByOutput, from: crate::model::ByOutput) {
    for (output, names) in from {
        union(into.entry(output).or_default(), names);
    }
}
