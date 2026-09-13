# Flake output and input extraction.
#
# The outputs half walks "self" and describes the well-known attributes in
# detail, listing anything else by name so a flake with outputs this file has
# never heard of still gets a complete index.
#
# The inputs half reads flake.lock directly. The lock is the only place the
# resolved revision and its date exist -- inputs as seen from inside the flake
# have already been fetched and no longer remember where they came from.
{ lib }:
let
  try =
    default: value:
    let
      attempt = builtins.tryEval value;
    in
    if attempt.success then attempt.value else default;

  # Outputs holding module trees, and outputs holding evaluated configurations,
  # each listed under its own name. winpkgs' are the Windows ones; the NixOS,
  # home-manager and nix-darwin names are here so the same extractor describes
  # a flake that has those too.
  moduleOutputs = [
    "nixosModules"
    "homeModules"
    "darwinModules"
    "windowsModules"
  ];
  configurationOutputs = [
    "nixosConfigurations"
    "homeConfigurations"
    "darwinConfigurations"
    "windowsConfigurations"
    "windowsHomeConfigurations"
  ];

  # Attributes described below, and therefore not repeated in "other" -- and
  # the ones Nix puts on `self` about the source tree, which are not outputs.
  known = [
    "apps"
    "checks"
    "devShells"
    "formatter"
    "lib"
    "overlays"
    "packages"
    "templates"
    "inputs"
    "outputs"
    "sourceInfo"
    "outPath"
    "narHash"
    "lastModified"
    "lastModifiedDate"
    "rev"
    "shortRev"
    "dirtyRev"
    "dirtyShortRev"
    "revCount"
    "submodules"
  ]
  ++ moduleOutputs
  ++ configurationOutputs;

  # A per-system output is an attrset of attrsets keyed by system; flatten it to
  # a list so the renderer does not have to care which shape it started as.
  perSystem =
    f: attrs:
    lib.concatLists (
      lib.mapAttrsToList (
        system: entries: lib.mapAttrsToList (name: value: { inherit system name; } // f value) entries
      ) attrs
    );

  # Only the outputs the flake has, so an absent tree is absent rather than
  # an empty heading.
  named = names: lib.genAttrs (lib.filter (n: self: self ? ${n}) names);
in
{
  /**
    Describe a flake's outputs.

    `packages` is deliberately absent: it is documented in full elsewhere, and
    restating the attribute names here would only invite the two lists to
    disagree.

    # Type

    ```
    mkOutputs :: AttrSet -> AttrSet
    ```
  */
  mkOutputs =
    { self }:
    let
      present = names: lib.filter (n: self ? ${n}) names;
      byOutput = names: lib.genAttrs (present names) (n: lib.attrNames self.${n});
    in
    {
      apps = perSystem (app: {
        description = try null (app.meta.description or null);
      }) (self.apps or { });

      templates = lib.mapAttrsToList (name: t: {
        inherit name;
        description = try null (t.description or null);
      }) (self.templates or { });

      overlays = lib.attrNames (self.overlays or { });

      modules = byOutput moduleOutputs;
      configurations = byOutput configurationOutputs;

      checks = perSystem (_: { }) (self.checks or { });
      devShells = perSystem (_: { }) (self.devShells or { });

      formatter = lib.mapAttrsToList (system: f: {
        inherit system;
        name = try null (lib.getName f);
      }) (self.formatter or { });

      lib = lib.attrNames (self.lib or { });

      other = lib.filter (n: !(lib.elem n known) && !(lib.hasPrefix "_" n)) (lib.attrNames self);
    };

  /**
    Read a flake's direct inputs out of its lock file.

    Only the root node's inputs are reported. Transitive nodes exist in the lock
    in their hundreds and describe other people's dependency graphs, not this
    flake's surface.

    # Inputs

    `lockFile`
    : Path to `flake.lock`.

    # Type

    ```
    mkInputs :: AttrSet -> [AttrSet]
    ```
  */
  mkInputs =
    { lockFile }:
    let
      lock = builtins.fromJSON (builtins.readFile lockFile);
      nodes = lock.nodes or { };
      rootInputs = nodes.root.inputs or { };

      # A URL good enough to click. The lock stores the pieces, not the address.
      urlOf =
        locked:
        let
          type = locked.type or "";
          host = locked.host or (if type == "github" then "github.com" else "gitlab.com");
        in
        if type == "github" || type == "gitlab" then
          "https://${host}/${locked.owner}/${locked.repo}"
        else if type == "sourcehut" then
          "https://git.sr.ht/${locked.owner}/${locked.repo}"
        else
          locked.url or null;

      describe =
        name: nodeName:
        let
          node = nodes.${nodeName} or { };
          locked = node.locked or { };
          original = node.original or { };
        in
        {
          inherit name;
          type = locked.type or null;
          owner = locked.owner or null;
          repo = locked.repo or null;
          ref = original.ref or null;
          rev = locked.rev or null;
          lastModified = locked.lastModified or null;
          url = urlOf locked;
          # "flake = false" inputs are source trees, not flakes, and behave
          # differently enough to be worth calling out.
          isFlake = original.flake or true;
          # An input value of [ "nixpkgs" ] is a follows edge rather than a node
          # of its own; those are what keep a lock from growing a second copy of
          # nixpkgs per input.
          follows = lib.filterAttrs (_: v: lib.isList v) (node.inputs or { });
        };
    in
    lib.sort (a: b: a.name < b.name) (
      lib.mapAttrsToList describe (lib.filterAttrs (_: v: lib.isString v) rootInputs)
    );
}
