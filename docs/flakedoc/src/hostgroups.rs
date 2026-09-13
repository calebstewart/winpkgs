//! Pairing a machine's system and user configurations.
//!
//! A flake that configures three machines usually exposes six configurations:
//! `nixosConfigurations.framework-desktop` and
//! `homeConfigurations."caleb@framework-desktop"` are the system and user halves
//! of one box. Listing all six as peers says there are six machines.
//!
//! **The pairing rule is exact, and deliberately so.** A home configuration
//! joins a machine if and only if its name is `<user>@<machine>`, split on the
//! *last* `@`, and a `nixos` or `darwin` configuration exists under exactly that
//! `<machine>`. Nothing is inferred from partial similarity: a flake whose home
//! configurations are named `laptop-home`, or which names a machine it has no
//! system configuration for, gets precisely the flat list it gets today. The
//! grouping is opportunistic and the flat list is the floor, because a wrong
//! grouping asserts a relationship between two configurations that a reader has
//! no way to check.
//!
//! This module knows nothing about URLs, slugs or rendering. It maps names to
//! names, which is the whole of the rule and all that needs testing.

/// One heading in the host navigation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostGroup {
    /// The machine name, or -- for a configuration that paired with nothing --
    /// that configuration's own full name.
    pub name: String,
    /// True when `name` is a machine rather than a configuration. A machine has
    /// no page of its own, so its heading is text; a lone configuration keeps
    /// its own name as the heading and stays a link.
    pub is_machine: bool,
    /// `(label, configuration name)`, System first and then users alphabetically.
    pub members: Vec<(String, String)>,
}

/// Split `<user>@<machine>` on the last `@`.
///
/// The last, not the first: a user part may contain an `@` of its own, and the
/// machine is what follows the final one. It may also contain dots --
/// `caleb.stewart@huntress-mbp` is one user on one machine -- which is why this
/// splits on `@` specifically rather than on punctuation.
fn split_user_at_machine(name: &str) -> Option<(&str, &str)> {
    let (user, machine) = name.rsplit_once('@')?;
    if user.is_empty() || machine.is_empty() {
        None
    } else {
        Some((user, machine))
    }
}

fn is_system(kind: &str) -> bool {
    kind == "nixos" || kind == "darwin"
}

/// Group `(name, kind)` pairs by machine.
///
/// Groups come out sorted by name; within a group the system configuration
/// comes first and users follow alphabetically.
pub fn group<S: AsRef<str>>(hosts: &[(S, S)]) -> Vec<HostGroup> {
    let names: Vec<(&str, &str)> = hosts
        .iter()
        .map(|(name, kind)| (name.as_ref(), kind.as_ref()))
        .collect();

    // Which names a home configuration is allowed to attach to. Built first, so
    // that a system configuration declared after the home configuration that
    // names it still pairs -- the document's order is not a fact about the
    // flake.
    let machines: Vec<&str> = names
        .iter()
        .filter(|(_, kind)| is_system(kind))
        .map(|(name, _)| *name)
        .collect();

    let mut groups: Vec<HostGroup> = Vec::new();
    let find = |groups: &mut Vec<HostGroup>, name: &str, is_machine: bool| -> usize {
        match groups
            .iter()
            .position(|g| g.name == name && g.is_machine == is_machine)
        {
            Some(index) => index,
            None => {
                groups.push(HostGroup {
                    name: name.to_string(),
                    is_machine,
                    members: Vec::new(),
                });
                groups.len() - 1
            }
        }
    };

    for (name, kind) in &names {
        if is_system(kind) {
            let index = find(&mut groups, name, true);
            groups[index]
                .members
                .push(("System".to_string(), name.to_string()));
        }
    }

    for (name, kind) in &names {
        if is_system(kind) {
            continue;
        }
        match split_user_at_machine(name).filter(|(_, machine)| machines.contains(machine)) {
            Some((user, machine)) => {
                let index = find(&mut groups, machine, true);
                groups[index]
                    .members
                    .push((user.to_string(), name.to_string()));
            }
            None => {
                let index = find(&mut groups, name, false);
                groups[index]
                    .members
                    .push((name.to_string(), name.to_string()));
            }
        }
    }

    for group in &mut groups {
        // "System" is not sorted into place; it is pinned, because a machine's
        // system configuration is the one a reader is looking for first and a
        // user named "adam" would otherwise displace it.
        let systems = group
            .members
            .iter()
            .filter(|(label, _)| label == "System")
            .count();
        group.members[systems..].sort();
    }
    groups.sort_by(|a, b| a.name.cmp(&b.name));
    groups
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hosts(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
        pairs
            .iter()
            .map(|(a, b)| (a.to_string(), b.to_string()))
            .collect()
    }

    fn shape(groups: &[HostGroup]) -> Vec<(String, bool, Vec<(String, String)>)> {
        groups
            .iter()
            .map(|g| (g.name.clone(), g.is_machine, g.members.clone()))
            .collect()
    }

    #[test]
    fn the_happy_path_pairs_system_and_user() {
        let groups = group(&hosts(&[
            ("framework-desktop", "nixos"),
            ("framework16", "nixos"),
            ("huntress-mbp", "darwin"),
            ("caleb@framework-desktop", "home-manager"),
            ("caleb@framework16", "home-manager"),
            ("caleb.stewart@huntress-mbp", "home-manager"),
        ]));

        assert_eq!(
            shape(&groups),
            vec![
                (
                    "framework-desktop".into(),
                    true,
                    vec![
                        ("System".into(), "framework-desktop".into()),
                        ("caleb".into(), "caleb@framework-desktop".into()),
                    ]
                ),
                (
                    "framework16".into(),
                    true,
                    vec![
                        ("System".into(), "framework16".into()),
                        ("caleb".into(), "caleb@framework16".into()),
                    ]
                ),
                (
                    "huntress-mbp".into(),
                    true,
                    vec![
                        ("System".into(), "huntress-mbp".into()),
                        (
                            "caleb.stewart".into(),
                            "caleb.stewart@huntress-mbp".into()
                        ),
                    ]
                ),
            ]
        );
    }

    #[test]
    fn a_user_part_may_contain_dots() {
        let groups = group(&hosts(&[
            ("huntress-mbp", "darwin"),
            ("caleb.stewart@huntress-mbp", "home-manager"),
        ]));
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].members[1].0, "caleb.stewart");
    }

    #[test]
    fn a_home_config_whose_machine_has_no_system_config_stays_top_level() {
        let groups = group(&hosts(&[
            ("framework-desktop", "nixos"),
            ("caleb@some-machine-that-has-no-system-config", "home-manager"),
        ]));

        assert_eq!(
            shape(&groups),
            vec![
                (
                    "caleb@some-machine-that-has-no-system-config".into(),
                    false,
                    vec![(
                        "caleb@some-machine-that-has-no-system-config".into(),
                        "caleb@some-machine-that-has-no-system-config".into()
                    )]
                ),
                (
                    "framework-desktop".into(),
                    true,
                    vec![("System".into(), "framework-desktop".into())]
                ),
            ]
        );
    }

    #[test]
    fn with_no_system_configs_the_list_is_entirely_flat() {
        let groups = group(&hosts(&[
            ("laptop-home", "home-manager"),
            ("caleb@framework16", "home-manager"),
        ]));

        assert!(groups.iter().all(|g| !g.is_machine));
        assert_eq!(
            groups.iter().map(|g| g.name.as_str()).collect::<Vec<_>>(),
            vec!["caleb@framework16", "laptop-home"]
        );
        assert!(groups.iter().all(|g| g.members.len() == 1));
        // Each keeps its own full name as both heading and label.
        assert_eq!(groups[0].members[0].0, "caleb@framework16");
        assert_eq!(groups[0].members[0].1, "caleb@framework16");
    }

    #[test]
    fn a_name_with_no_at_sign_stays_top_level() {
        let groups = group(&hosts(&[
            ("framework16", "nixos"),
            ("laptop-home", "home-manager"),
        ]));
        assert_eq!(groups.len(), 2);
        assert_eq!(groups[0].name, "framework16");
        assert!(groups[0].is_machine);
        assert_eq!(groups[1].name, "laptop-home");
        assert!(!groups[1].is_machine);
    }

    #[test]
    fn a_machine_with_two_users_lists_both_sorted() {
        let groups = group(&hosts(&[
            ("shared", "nixos"),
            ("zoe@shared", "home-manager"),
            ("adam@shared", "home-manager"),
        ]));

        assert_eq!(groups.len(), 1);
        assert_eq!(
            groups[0].members,
            vec![
                ("System".into(), "shared".into()),
                ("adam".into(), "adam@shared".into()),
                ("zoe".into(), "zoe@shared".into()),
            ]
        );
    }

    #[test]
    fn a_machine_with_no_home_config_still_forms_a_group() {
        let groups = group(&hosts(&[("headless", "nixos")]));
        assert_eq!(
            shape(&groups),
            vec![(
                "headless".into(),
                true,
                vec![("System".into(), "headless".into())]
            )]
        );
    }

    #[test]
    fn two_at_signs_split_on_the_last() {
        let groups = group(&hosts(&[
            ("c", "nixos"),
            ("a@b@c", "home-manager"),
            ("a@b", "home-manager"),
        ]));

        // "a@b@c" pairs with machine "c" under the user "a@b"; "a@b" finds no
        // machine "b" and stays where it is.
        assert_eq!(
            shape(&groups),
            vec![
                ("a@b".into(), false, vec![("a@b".into(), "a@b".into())]),
                (
                    "c".into(),
                    true,
                    vec![
                        ("System".into(), "c".into()),
                        ("a@b".into(), "a@b@c".into()),
                    ]
                ),
            ]
        );
    }

    #[test]
    fn a_leading_or_trailing_at_sign_is_not_a_pairing() {
        let groups = group(&hosts(&[
            ("machine", "nixos"),
            ("@machine", "home-manager"),
            ("caleb@", "home-manager"),
        ]));

        assert_eq!(groups.len(), 3);
        assert_eq!(
            groups.iter().map(|g| g.name.as_str()).collect::<Vec<_>>(),
            vec!["@machine", "caleb@", "machine"]
        );
        assert!(!groups[0].is_machine);
        assert!(!groups[1].is_machine);
        assert!(groups[2].is_machine);
    }

    #[test]
    fn a_system_config_declared_after_its_user_still_pairs() {
        let groups = group(&hosts(&[
            ("caleb@framework16", "home-manager"),
            ("framework16", "nixos"),
        ]));
        assert_eq!(groups.len(), 1);
        assert!(groups[0].is_machine);
        assert_eq!(groups[0].members.len(), 2);
    }

    #[test]
    fn no_hosts_produce_no_groups() {
        let groups = group::<String>(&[]);
        assert!(groups.is_empty());
    }
}
