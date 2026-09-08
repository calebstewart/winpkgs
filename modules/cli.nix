# The `winpkgs` command on the Windows side, installed by apply itself. After
# the first activation from WSL, everything is driven from a Windows terminal.
{
  lib,
  config,
  winpkgsSrc,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.winpkgs.cli;
  stateDir = ''%LOCALAPPDATA%\winpkgs'';
in
{
  options.winpkgs.cli = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Install the `winpkgs` command (`plan`, `apply`, `switch`, `generations`,
        `rollback`, ...) into `%LOCALAPPDATA%\winpkgs\bin` and put that directory on
        the user's `PATH`. Also installs a copy of the runtime so `generations` and
        `rollback` work without WSL.
      '';
    };

    flake = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = ''%USERPROFILE%\git\stewos'';
      description = ''
        Windows path of the flake this configuration lives in -- the default for
        `winpkgs -Flake`. `%VAR%` references are expanded on use; an optional
        `#name` selects the configuration (default: `winpkgs.name`). The path is
        translated for the distro with `wslpath`, so it may also be a
        `\\wsl.localhost\...` path.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    winpkgs.files = {
      "${stateDir}\\bin\\winpkgs.ps1".source = "${winpkgsSrc}/runtime/cli.ps1";
      # cmd.exe and the Run dialog; pwsh finds winpkgs.ps1 on PATH by itself.
      "${stateDir}\\bin\\winpkgs.cmd".text = ''
        @echo off
        pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0winpkgs.ps1" %*
        exit /b %ERRORLEVEL%
      '';
      "${stateDir}\\runtime".source = "${winpkgsSrc}/runtime";
      "${stateDir}\\cli.json".text = builtins.toJSON {
        flake = cfg.flake;
        name = config.winpkgs.name;
        distro = config.winpkgs.wsl.distro;
      };
    };

    winpkgs.environment.path = [ "${stateDir}\\bin" ];
  };
}
