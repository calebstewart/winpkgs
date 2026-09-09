# Flow Launcher, the keyboard launcher: installed for this user, started at
# sign-in, and its Settings.json owned when `settings` says anything.
#
# Its installer is Squirrel's (winget: user scope, no machine install), so it
# lives in %LOCALAPPDATA%\FlowLauncher, where a stub Flow.Launcher.exe runs
# whichever versioned app-x.y.z\ directory is current. The stub is what the
# start-up entry and `showCommand` run, because it survives Flow's own updates
# where the versioned path does not. Flow is single-instance: starting it
# again while it runs shows the query window, which is how a hotkey daemon
# summons it (`programs.whkd.keybindings."alt + d" = showCommand`) without
# fighting Flow for a global hotkey registration.
#
# Settings.json is Flow's to rewrite: it saves the whole document, every
# setting included, when one changes and when it exits. A managed file is
# therefore rewritten back at the next apply -- what home-manager does with any
# program that edits its own configuration -- and Flow reads it at start, so a
# changed file wants a restart of Flow. Nothing is written when `settings` is
# empty, so a Flow left to its own devices causes no churn.
{
  lib,
  config,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption mkEnableOption types;
  cfg = config.programs.flow-launcher;
  json = pkgs.buildPackages.formats.json { };

  # "%LOCALAPPDATA%\..." as PowerShell says it, for a command whkd runs.
  vars = [
    "%LOCALAPPDATA%"
    "%APPDATA%"
    "%USERPROFILE%"
    "%PROGRAMFILES%"
  ];
  toPowerShell = lib.replaceStrings vars (
    map (v: "$Env:${lib.removeSuffix "%" (lib.removePrefix "%" v)}") vars
  );
in
{
  options.programs.flow-launcher = {
    enable = mkEnableOption "Flow Launcher";

    package = mkOption {
      type = types.nullOr types.package;
      default = pkgs.winpkgs.fromWinget {
        id = "Flow-Launcher.Flow-Launcher";
        scope = "user";
      };
      defaultText = lib.literalExpression ''pkgs.winpkgs.fromWinget { id = "Flow-Launcher.Flow-Launcher"; scope = "user"; }'';
      description = "The package to install: winget's, a per-user install. `null` installs nothing.";
    };

    executable = mkOption {
      type = types.str;
      default = ''%LOCALAPPDATA%\FlowLauncher\Flow.Launcher.exe'';
      description = "Flow's stub executable, which runs the current version; the installer's location by default.";
    };

    autostart = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Start Flow at sign-in through `windows.startup`. Leave Flow's own
        "start on system startup" setting off: this entry replaces it, and
        points at the stub rather than the versioned path Flow would write.
      '';
    };

    settings = mkOption {
      type = json.type;
      default = { };
      example = lib.literalExpression ''
        {
          Hotkey = "Alt + Space";
          Theme = "Darker";
          ColorScheme = "Dark";
          StartFlowLauncherOnSystemStartup = false;
        }
      '';
      description = ''
        Flow's Settings.json (`%APPDATA%\FlowLauncher\Settings\Settings.json`),
        with Flow's own field names; a field left out keeps Flow's default.
        Written whole when set to anything, and Flow rewrites it with every
        field whenever it saves, so expect the next apply to put this back.
        Flow reads it at start. Empty, the default, leaves the file alone.
      '';
    };

    showCommand = mkOption {
      type = types.str;
      readOnly = true;
      default = ''Start-Process "${toPowerShell cfg.executable}"'';
      defaultText = lib.literalExpression ''"Start-Process \"$Env:LOCALAPPDATA\\FlowLauncher\\Flow.Launcher.exe\""'';
      description = ''
        A PowerShell command that shows the query window: Flow is
        single-instance, so starting it again brings up the running one. For
        a hotkey daemon binding, e.g. `programs.whkd.keybindings."alt + d"`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = lib.optional (cfg.package != null) cfg.package;

    windows.files."%APPDATA%/FlowLauncher/Settings/Settings.json" = lib.mkIf (cfg.settings != { }) {
      source = json.generate "Settings.json" cfg.settings;
    };

    windows.startup."Flow.Launcher" = lib.mkIf cfg.autostart ''"${cfg.executable}"'';
  };
}
