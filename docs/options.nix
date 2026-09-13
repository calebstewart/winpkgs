# Option extraction.
#
# Everything here funnels into nixpkgs' own nixosOptionsDoc, which already knows
# how to walk submodules, render defaults that cannot be serialized, and turn an
# option tree into a flat attrset keyed by dotted name. What this file adds is
# deciding which of the resulting options belong to winpkgs rather than to
# home-manager or nixpkgs: a home configuration evaluates home-manager's whole
# module list, and its thousands of options are not this flake's to document.
{ lib }:
{
  /**
    Render an evaluated option tree into a documentation record.

    Options are kept when at least one of their declarations lives inside
    `src`. That is a better filter than matching an option-name prefix: it needs
    no configuration, it cannot be fooled by a third-party module that happens
    to share a namespace, and it catches options declared *outside* the
    `winpkgs.*` namespace -- which is most of them: `windows.*`, `winget.*`,
    `wsl.*`, `programs.whkd.*`, and the `enablePowerShellIntegration` this flake
    adds to home-manager's own `programs.starship`.

    It needs the tree to have been evaluated through the flake's own store path,
    which `winpkgs.lib.windowsSystem` and `homeConfiguration` do by construction:
    an option's `declarations` record the store path the module was read from,
    and the prefix test below is what recognises this flake's.

    # Inputs

    `docPkgs`
    : Package set used to *build* the JSON -- the system the docs are built on.

    `options`
    : The `options` attrset of an evaluated configuration.

    `set`
    : The option set's `{ id, title, kind, system, ... }` record from the
      configuration file.

    `exclude`
    : Dotted option-name prefixes to drop even though they pass the declaration
      filter -- a deprecated alias, say.

    # Type

    ```
    mkOptionSet :: AttrSet -> AttrSet
    ```
  */
  mkOptionSet =
    {
      docPkgs,
      options,
      src,
      repoUrl,
      branch,
      set,
      exclude ? [ ],
      warningsAreErrors ? false,
    }:
    let
      prefix = "${toString src}/";
      isOurs = decl: lib.hasPrefix prefix (toString decl);
      rel = decl: lib.removePrefix prefix (toString decl);

      name = o: lib.showOption o.loc;
      isExcluded =
        o: lib.any (p: o.loc == lib.splitString "." p || lib.hasPrefix "${p}." (name o)) exclude;

      doc = docPkgs.nixosOptionsDoc {
        inherit options warningsAreErrors;

        transformOptions =
          o:
          if isExcluded o || !(lib.any isOurs o.declarations) then
            # Not ours. nixosOptionsDoc drops invisible options, so this is how
            # home-manager's and nixpkgs' thousands get discarded.
            o // { visible = false; }
          else
            o
            // {
              declarations = map (d: {
                name = rel d;
                url = "${repoUrl}/blob/${branch}/${rel d}";
              }) o.declarations;
            };
      };
    in
    {
      inherit (set)
        id
        title
        kind
        system
        ;
      description = set.description or null;
      options = doc.optionsNix;
    };
}
