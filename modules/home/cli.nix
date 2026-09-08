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
        `winpkgs -Flake`. `%VAR%` references are expanded on use. The path is
        translated for the distro with `wslpath`, so it may also be a
        `\\wsl.localhost\...` path.
      '';
    };

    systemName = mkOption {
      type = types.str;
      default = lib.last (lib.splitString "@" config.winpkgs.name);
      defaultText = lib.literalMD "the part of `winpkgs.name` after the last `@`";
      description = "Name of the system configuration (`windowsConfigurations.<name>`) this user's machine is; the default for `winpkgs system`.";
    };

    distro = mkOption {
      type = types.str;
      default = "NixOS";
      description = "The WSL distribution the `winpkgs` command evaluates and builds in.";
    };
  };

  config = lib.mkIf cfg.enable {
    winpkgs.files = {
      # A 5.1-compatible launcher: `winpkgs` typed in Windows PowerShell resolves
      # to this file and runs it there, so it hands off to pwsh for the real CLI
      # (in ..\runtime\cli.ps1, part of the runtime copy below).
      "${stateDir}\\bin\\winpkgs.ps1".source = "${winpkgsSrc}/runtime/cli-launcher.ps1";
      # cmd.exe and the Run dialog. Goes through Windows PowerShell, which always
      # exists, and lets the launcher explain if pwsh is missing.
      "${stateDir}\\bin\\winpkgs.cmd".text = ''
        @echo off
        powershell -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0winpkgs.ps1" %*
        exit /b %ERRORLEVEL%
      '';
      "${stateDir}\\runtime".source = "${winpkgsSrc}/runtime";
      "${stateDir}\\cli.json".text = builtins.toJSON {
        flake = cfg.flake;
        system = cfg.systemName;
        home = config.winpkgs.name;
        distro = cfg.distro;
      };
    };

    winpkgs.environment.path = [ "${stateDir}\\bin" ];
  };
}
