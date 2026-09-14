# A winget-pkgs tree, read for what its directory names say.
#
# microsoft/winget-pkgs is the winget manifest repository: for every package
# id, a directory per version, each holding that version's YAML manifests. A
# commit of it fixes what "latest" means for every id, the way a commit of
# nixpkgs fixes what `pkgs.git` is -- which is why it is a flake input, and why
# a `winget.packages` entry that names no version gets the one the input pins
# (modules/common/packages.nix).
#
# Only names are read here. The manifests' contents -- installer URLs, hashes,
# switches -- are the business of a later step that carries installers on the
# media, and reading them means parsing YAML, which Nix cannot do without an
# import-from-derivation. Nothing here needs it: `builtins.readDir` on one
# directory of a fetched input is all a version costs.
#
# Every function takes the tree first, so the module (over its
# `winget.manifests` option), the flake checks (over a fixture tree) and the
# documentation (over the real input) share one reader.
{ lib }:
rec {
  /**
    Where a package's manifests are in a winget-pkgs tree. The layout is
    winget's own: the id's first character, lowercased, then the id split at
    its dots, each piece a directory.

    A publisher's directory exists too (`manifests/g/Git` for `Git.Git`), so a
    directory being there says nothing about a package being there; that is
    what `hasPackage` is for.

    # Inputs

    `root`
    : The tree: the `winget-pkgs` flake input, or any directory laid out like
      it.

    `id`
    : A winget package id, exact and case-sensitive: `"Git.Git"`.

    # Example

    ```nix
    manifestDir inputs.winget-pkgs "Python.Python.3.13"
    => "/nix/store/...-source/manifests/p/Python/Python/3/13"
    ```

    # Type

    ```
    manifestDir :: Path -> String -> String
    ```
  */
  manifestDir =
    root: id:
    "${toString root}/manifests/${
      lib.toLower (lib.substring 0 1 id)
    }/${lib.concatStringsSep "/" (lib.splitString "." id)}";

  /**
    The versions a package has in the tree, in no particular order: the
    directories under `manifestDir` that hold the package's own version
    manifest, `<version>/<id>.yaml`.

    The manifest is the test, not the directory alone, because a package's
    directory also holds the packages named under it: `Microsoft.PowerShell`
    has `Preview/` beside its versions, and that is `Microsoft.PowerShell.Preview`,
    not a version of PowerShell. Empty when the package is not in the tree.

    # Inputs

    `root`, `id`
    : As for `manifestDir`.

    # Example

    ```nix
    versionsOf inputs.winget-pkgs "Microsoft.PowerShell"
    => [ "7.4.6.0" "7.5.0.0" ... ]
    ```

    # Type

    ```
    versionsOf :: Path -> String -> [String]
    ```
  */
  versionsOf =
    root: id:
    let
      dir = manifestDir root id;
    in
    if !builtins.pathExists dir then
      [ ]
    else
      lib.filter (v: builtins.pathExists "${dir}/${v}/${id}.yaml") (
        lib.attrNames (lib.filterAttrs (_: kind: kind == "directory") (builtins.readDir dir))
      );

  /**
    Whether the tree has the package at all: at least one version of it.

    # Inputs

    `root`, `id`
    : As for `manifestDir`.

    # Type

    ```
    hasPackage :: Path -> String -> Bool
    ```
  */
  hasPackage = root: id: versionsOf root id != [ ];

  /**
    The package's newest version in the tree, or `null` when it has none.

    Newest by `builtins.compareVersions`: segment by segment, digits as
    numbers, so `7.4.10` is newer than `7.4.9` and `2.47.10` than `2.47.9`,
    which is how winget orders them too. A date-stamped version such as
    wezterm's `20240203-110809-5046fc22` orders by its date. Pre-releases are
    not a concern: winget-pkgs gives them ids of their own (`.Preview`,
    `.Nightly`) rather than versions beside the stable ones.

    # Inputs

    `root`, `id`
    : As for `manifestDir`.

    # Example

    ```nix
    latestVersion inputs.winget-pkgs "Git.Git"
    => "2.51.0"
    ```

    # Type

    ```
    latestVersion :: Path -> String -> String | Null
    ```
  */
  latestVersion =
    root: id:
    let
      versions = versionsOf root id;
    in
    if versions == [ ] then
      null
    else
      lib.foldl' (a: b: if lib.versionOlder a b then b else a) (lib.head versions) (lib.tail versions);

  /**
    The tree, named for a message: the input's short revision when it has
    one, else where the tree is (a fixture, a `path:` input, a checkout).

    # Inputs

    `root`
    : As for `manifestDir`.

    # Example

    ```nix
    describe inputs.winget-pkgs
    => "winget-pkgs at 3f2a1c9"
    ```

    # Type

    ```
    describe :: Path -> String
    ```
  */
  describe =
    root:
    if builtins.isAttrs root && root ? shortRev then
      "winget-pkgs at ${root.shortRev}"
    else
      "the winget-pkgs tree at ${toString root}";

  /**
    What a `winget.packages` entry asks for, once the tree has been consulted:
    the version to hand the runtime, and whether it is a pin.

    An entry with a `version` is pinned to it exactly, whatever the tree says.
    An entry without one, from the `winget` source, gets the tree's latest and
    is not pinned: the runtime treats that version as a floor, installing it
    when the package is absent and upgrading to it when what is installed is
    older, but leaving a newer install alone. A package from another source
    (`msstore`) is not in winget-pkgs, so its version stays as given, usually
    `null`, and present is enough.

    `version` is `null` when the package is not in the tree; the module refuses
    that with a message naming the id before it reaches a document.

    # Inputs

    `root`
    : As for `manifestDir`.

    `package`
    : A merged `winget.packages` entry: `{ id; version; source; ... }`.

    # Example

    ```nix
    resolve inputs.winget-pkgs { id = "Git.Git"; version = null; source = "winget"; }
    => { version = "2.51.0"; pinned = false; }

    resolve inputs.winget-pkgs { id = "Git.Git"; version = "2.47.1"; source = "winget"; }
    => { version = "2.47.1"; pinned = true; }
    ```

    # Type

    ```
    resolve :: Path -> AttrSet -> { version :: String | Null; pinned :: Bool; }
    ```
  */
  resolve =
    root: package:
    let
      given = package.version or null;
    in
    if (package.source or "winget") != "winget" then
      {
        version = given;
        pinned = given != null;
      }
    else if given != null then
      {
        version = given;
        pinned = true;
      }
    else
      {
        version = latestVersion root package.id;
        pinned = false;
      };
}
