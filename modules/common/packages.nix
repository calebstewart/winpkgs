# Packages installed through winget, and what version each one means.
#
# The version is nixpkgs' semantics. An entry that names none gets the latest
# version the pinned winget-pkgs input knows (`winget.manifests`), the way
# `pkgs.git` is whatever the pinned nixpkgs says it is, so updating packages is
# `nix flake update winget-pkgs` and a consumer moves the pin on their own
# schedule. What differs from nixpkgs is that Windows programs update
# themselves, so a resolved version is a floor rather than a target: the
# runtime installs it when the package is absent and upgrades to it when what
# is installed is older, but a newer install is not drift. A version the user
# wrote is a pin and is enforced exactly, downgrade included; `pinned` in the
# document is how the runtime tells the two apart.
#
# Resolution happens once, here, after the entries from every module have
# merged by id, so home.packages, environment.systemPackages, a program
# module's fromWinget default and a bare id in winget.packages all go through
# the same reader (lib/winget.nix) and get the same answer.
{
  lib,
  config,
  winpkgsKind,
  winpkgsInputs,
  ...
}:
let
  inherit (lib) mkOption types;
  sugar = import ./sugar.nix { inherit lib; };
  wingetLib = import ../../lib/winget.nix { inherit lib; };
  cfg = config.winget;
  scope = sugar.scopeOfKind winpkgsKind;

  wingetPackage = types.submodule {
    options = {
      id = mkOption {
        type = types.str;
        example = "Git.Git";
        description = "Exact winget package identifier.";
      };
      version = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Pin to exactly this version, downgrading an install that is newer.
          `null`, the default, is the latest version in `winget.manifests`
          (winpkgs' pinned winget-pkgs), and acts as a floor rather than a
          pin: installed when the package is absent, upgraded to when what is
          installed is older, left alone when it is newer. Not consulted for
          `source = "msstore"`, which winget-pkgs does not carry.
        '';
      };
      upgrade = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Follow winget's latest: treat an available winget update as drift
          and apply it, rather than stopping at the version `winget.manifests`
          knows. Ignored when `version` is set.
        '';
      };
      source = mkOption {
        type = types.str;
        default = "winget";
        description = "winget source name (`winget` or `msstore`).";
      };
      scope = mkOption {
        type = types.nullOr (
          types.enum [
            "user"
            "machine"
          ]
        );
        default = null;
        description = ''
          Installer scope passed to winget (`--scope`). Defaults to the scope of
          the configuration: `user` in a home configuration, `machine` in a
          system one -- so a package whose installer only supports the other
          scope fails with "no applicable installer" instead of a home apply
          quietly prompting for UAC. The other scope is an error; that package
          belongs in the other configuration.
        '';
      };
    };
  };

  installerScope = p: if p.scope != null then p.scope else scope;
  wrongKind = lib.filter (p: p.scope != null && p.scope != scope) merged;

  # The same id may be listed by several modules (a host lists Microsoft.PowerShell,
  # winpkgs.powershell ensures it too). Merge them: one resource per id, pins and
  # scopes must agree, upgrade if anyone asked.
  byId = lib.groupBy (p: p.id) cfg.packages;

  distinct = f: ps: lib.unique (lib.filter (v: v != null) (map f ps));

  merged = lib.mapAttrsToList (
    id: ps:
    let
      versions = distinct (p: p.version) ps;
      scopes = distinct (p: p.scope) ps;
      sources = distinct (p: p.source) ps;
    in
    {
      inherit id;
      version = if versions == [ ] then null else lib.head versions;
      scope = if scopes == [ ] then null else lib.head scopes;
      source = lib.head sources;
      upgrade = lib.any (p: p.upgrade) ps;
    }
  ) byId;

  conflicts = lib.concatLists (
    lib.mapAttrsToList (
      id: ps:
      lib.optional (lib.length (distinct (p: p.version) ps) > 1) {
        assertion = false;
        message = "winget.packages: ${id} is pinned to conflicting versions: ${
          lib.concatStringsSep ", " (distinct (p: p.version) ps)
        }";
      }
      ++ lib.optional (lib.length (distinct (p: p.scope) ps) > 1) {
        assertion = false;
        message = "winget.packages: ${id} is given conflicting scopes";
      }
      ++ lib.optional (lib.length (distinct (p: p.source) ps) > 1) {
        assertion = false;
        message = "winget.packages: ${id} is given conflicting sources";
      }
    ) byId
  );

  # What the tree has to know about. Only the winget source lives in
  # winget-pkgs. A home's machine-wide packages are handed to the system
  # (winpkgs.machinePackages) rather than listed here, and a misspelt one
  # would otherwise only be caught once a system lists the home, so they are
  # looked up here too; the system tree has no such option.
  fromWinget = lib.filter (p: p.source == "winget") merged;
  lookedUp = lib.unique (
    map (p: p.id) fromWinget ++ map (p: p.id) (config.winpkgs.machinePackages or [ ])
  );
  where = wingetLib.describe cfg.manifests;
  relativeDir =
    id: lib.removePrefix "${toString cfg.manifests}/" (wingetLib.manifestDir cfg.manifests id);
  missing = lib.filter (id: !wingetLib.hasPackage cfg.manifests id) lookedUp;
  notInTree = map (id: {
    assertion = false;
    message = ''
      winget.packages: ${id} is not in ${where} (${relativeDir id} has no version directory holding ${id}.yaml).
        Ids are exact, case included; `winget search ${id}` shows the spelling winget knows. A package added
        upstream after that revision needs `nix flake update winget-pkgs`; a Store package takes `source = "msstore"`.'';
  }) missing;

  # A pin the tree does not list is a warning, not an error: winget-pkgs
  # prunes old manifests, and the pin is the user's exact statement. winget
  # will refuse it if its source has moved on too; the apply says so then.
  stalePins = lib.filter (
    p:
    p.version != null
    && wingetLib.hasPackage cfg.manifests p.id
    && !(lib.elem p.version (wingetLib.versionsOf cfg.manifests p.id))
  ) fromWinget;

  resolved = map (p: p // wingetLib.resolve cfg.manifests p) merged;
in
{
  options.winget = {
    packages = mkOption {
      type = types.listOf (types.coercedTo types.str (id: { inherit id; }) wingetPackage);
      default = [ ];
      example = lib.literalExpression ''
        [
          "Git.Git"
          { id = "Microsoft.PowerShell"; upgrade = true; }
          { id = "wez.wezterm"; version = "20240203-110809-5046fc22"; }
          { id = "Microsoft.VisualStudioCode"; scope = "machine"; }
        ]
      '';
      description = ''
        Packages to install with winget. A bare string is the package id. Listing
        an id more than once (e.g. from several modules) is fine; the entries are
        merged and must not disagree on `version`, `scope` or `source`. An id
        must exist in `winget.manifests`; a misspelling is an evaluation error
        that names it.
      '';
    };

    manifests = mkOption {
      type = types.path;
      default = winpkgsInputs.winget-pkgs;
      defaultText = lib.literalMD "winpkgs' own `winget-pkgs` input";
      description = ''
        The winget-pkgs source tree (microsoft/winget-pkgs, or a tree laid out
        like it) that `winget.packages` reads default versions from: an entry
        without a `version` gets the latest one listed here, and an id has to
        be listed here at all. Read for directory names only; no manifest is
        parsed. `nix flake update winget-pkgs` moves it, and a consuming flake
        pins its own with `inputs.winpkgs.inputs.winget-pkgs.follows`.
      '';
    };
  };

  config = {
    assertions =
      conflicts
      ++ notInTree
      ++ [
        {
          assertion = wrongKind == [ ];
          message = "winget.packages: ${lib.concatStringsSep ", " (map (p: p.id) wrongKind)}: scope `${
            sugar.scopeOfKind (if winpkgsKind == "system" then "home" else "system")
          }` belongs in the ${if winpkgsKind == "system" then "home" else "system"} configuration";
        }
      ];

    warnings = map (
      p:
      "winget.packages: ${p.id} is pinned to ${p.version}, which ${where} does not list; winget will fail to find it unless its source still has it"
    ) stalePins;

    # `version` is what the runtime installs when the package is absent. It
    # is a floor unless `pinned`, which is the one thing Test-WinPkgsWinGetPackage
    # reads to tell a resolved default from a pin the user wrote.
    winpkgs.resources = map (p: {
      type = "winpkgs/winget";
      id = p.id;
      inherit scope;
      properties = {
        inherit (p)
          id
          version
          pinned
          upgrade
          source
          ;
        scope = installerScope p;
      };
    }) resolved;
  };
}
