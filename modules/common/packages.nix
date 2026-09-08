{
  lib,
  config,
  winpkgsKind,
  ...
}:
let
  inherit (lib) mkOption types;
  sugar = import ./sugar.nix { inherit lib; };
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
        description = "Pin to this version. `null` installs the latest available.";
      };
      upgrade = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Treat an available winget update as drift and apply it, so the package
          is kept at the latest version rather than merely present. Ignored when
          `version` is set.
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
        merged and must not disagree on `version`, `scope` or `source`.
      '';
    };

  };

  config = {
    assertions = conflicts ++ [
      {
        assertion = wrongKind == [ ];
        message = "winget.packages: ${lib.concatStringsSep ", " (map (p: p.id) wrongKind)}: scope `${
          sugar.scopeOfKind (if winpkgsKind == "system" then "home" else "system")
        }` belongs in the ${if winpkgsKind == "system" then "home" else "system"} configuration";
      }
    ];

    winpkgs.resources = map (p: {
      type = "winpkgs/winget";
      id = p.id;
      inherit scope;
      properties = {
        inherit (p)
          id
          version
          upgrade
          source
          ;
        scope = installerScope p;
      };
    }) merged;
  };
}
