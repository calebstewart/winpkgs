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
# masir is missing).
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
  startCommand = lib.concatStringsSep " " (
    [
      "conhost.exe"
      "--headless"
      ''"${cfg.executable}"''
    ]
    ++ flags
  );
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
      description = "Start masir at sign-in, through `windows.startup`, under a headless console host so no window appears.";
    };

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
    windows.startup.masir = lib.mkIf cfg.autostart startCommand;
  };
}
