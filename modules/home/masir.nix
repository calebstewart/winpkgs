# masir, LGUG2Z's focus-follows-mouse daemon: the window under the pointer
# gets focus, no click needed. It stands alone -- no configuration file, a
# handful of flags -- and when komorebi is running it reads komorebi's list of
# managed windows on its own, so only tiled windows take focus by hover.
# komorebi's own `focus_follows_mouse` setting is end-of-life in favour of it.
#
# Started the way programs.whkd starts whkd: a console program under a
# headless console host from the Run key, rather than through `komorebic
# start --masir`, so that it does not depend on komorebi being enabled (or on
# komorebic finding it: `start --masir` refuses to start anything at all when
# masir is missing). `service.enable` runs it as home-manager's
# `systemd.user.services.masir` instead, for a user service manager (steward).
{
  lib,
  config,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption mkEnableOption types;
  cfg = config.programs.masir;

  flags =
    lib.optional cfg.noRaise "--no-raise" ++ lib.optional (!cfg.integrations) "--disable-integrations";
  commandLine = lib.concatStringsSep " " ([ ''"${cfg.executable}"'' ] ++ flags);
  startCommand = "conhost.exe --headless ${commandLine}";
in
{
  options.programs.masir = {
    enable = mkEnableOption "masir, focus follows mouse";

    package = mkOption {
      type = types.nullOr types.package;
      default = pkgs.winpkgs.fromWinget {
        id = "LGUG2Z.masir";
        scope = "machine";
      };
      defaultText = lib.literalExpression ''pkgs.winpkgs.fromWinget { id = "LGUG2Z.masir"; scope = "machine"; }'';
      description = ''
        The package to install. winget's is an MSI, so it is machine scope and
        reaches the system configuration through `winpkgs.homes`. `null`
        installs nothing.
      '';
    };

    executable = mkOption {
      type = types.str;
      default = ''C:\Program Files\masir\bin\masir.exe'';
      description = "The path of masir.exe, for the start-up entry: the MSI's location by default.";
    };

    autostart = mkOption {
      type = types.bool;
      default = true;
      description = "Start masir at sign-in, through `windows.startup`, under a headless console host so no window appears. Moot with `service.enable`.";
    };

    service.enable = mkEnableOption ''
      masir as a user service instead of a Run entry: `systemd.user.services.masir`,
      which a user service manager runs (steward's home module makes it a
      unit). Started with `graphical-session.target` unless the unit says
      otherwise -- after komorebi's service, whose list of windows it reads,
      when there is one -- and restarted if it dies. The Run entry is removed'';

    noRaise = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Focus the window under the pointer without raising it above the
        others (masir's `--no-raise`, which uses Windows' own active window
        tracking). The default raises it.
      '';
    };

    integrations = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Let masir consult a running tiling window manager's list of managed
        windows (komorebi's `komorebi.hwnd.json`), so that only those take
        focus by hover. `false` passes `--disable-integrations`: any window
        does.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = lib.optional (cfg.package != null) cfg.package;
    windows.startup.masir = if cfg.service.enable then null else lib.mkIf cfg.autostart startCommand;

    systemd.user.services.masir = lib.mkIf cfg.service.enable {
      Unit = {
        Description = "masir, focus follows mouse";
        # Ordering only: masir runs without komorebi.
        After = [
          "graphical-session.target"
          "komorebi.service"
        ];
      };
      Service.ExecStart = commandLine;
      Install.WantedBy = lib.mkDefault [ "graphical-session.target" ];
    };
  };
}
