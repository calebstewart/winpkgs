# The runtime needs PowerShell 7. Rather than leave that to bootstrap.ps1 and
# hope, the configuration ensures it -- and by default keeps it current, so the
# pwsh that runs the runtime is the one winget considers latest.
{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.winpkgs.powershell;
in
{
  options.winpkgs.powershell = {
    ensure = mkOption {
      type = types.bool;
      default = true;
      description = "Install PowerShell 7 (`Microsoft.PowerShell` from winget). The runtime and the `winpkgs` command need it.";
    };

    upgrade = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Treat an available winget update for PowerShell as drift and apply it.
        Upgrading the pwsh that is running the apply is fine -- the installer
        replaces it for the next launch -- but open a new terminal afterwards.
      '';
    };
  };

  config = lib.mkIf cfg.ensure {
    winget.packages = [
      {
        id = "Microsoft.PowerShell";
        upgrade = cfg.upgrade;
      }
    ];
  };
}
