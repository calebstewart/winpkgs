{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.winpkgs.packages;

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
        description = "Pin to this version. `null` installs the latest available and never upgrades on its own.";
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
          Installer scope passed to winget. `machine` runs in the elevated phase
          with `--scope machine`. `null` lets the installer decide and runs
          unelevated; installers that need admin will raise their own UAC prompt.
        '';
      };
    };
  };
in
{
  options.winpkgs.packages = {
    winget = mkOption {
      type = types.listOf (types.coercedTo types.str (id: { inherit id; }) wingetPackage);
      default = [ ];
      example = lib.literalExpression ''
        [
          "Git.Git"
          "Microsoft.PowerShell"
          { id = "wez.wezterm"; version = "20240203-110809-5046fc22"; }
          { id = "Microsoft.VisualStudioCode"; scope = "machine"; }
        ]
      '';
      description = "Packages to install with winget. A bare string is the package id.";
    };

    prune = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Uninstall winget packages that winpkgs installed earlier but that are no
        longer declared. Only packages recorded in winpkgs' own ledger are ever
        removed; nothing pre-existing is touched.
      '';
    };
  };

  config.winpkgs.resources = map (p: {
    type = "winpkgs/winget";
    id = p.id;
    scope = if p.scope == "machine" then "machine" else "user";
    properties = {
      inherit (p)
        id
        version
        source
        scope
        ;
    };
  }) cfg.winget;
}
