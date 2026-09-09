# komorebi, LGUG2Z's tiling window manager, beside programs.whkd (komorebi has
# no key bindings of its own; whkd sends it komorebic commands). `settings` is
# komorebi.json, owned outright; `bar.settings` is komorebi.bar.json for the
# status bar that ships with it. Both programs watch their files and reload
# them as they land, so a changed configuration takes effect at the end of an
# apply with nothing to restart -- unlike whkd.
#
# Starting it: komorebi.exe is a console program, and upstream's own autostart
# is a shortcut to komorebic-no-console.exe, a komorebic built without a
# console window, running `start` (plus `--bar`), which launches komorebi.exe
# hidden. The Run entry here does the same. whkd is not passed as `--whkd`:
# programs.whkd starts it itself, so each daemon stands on its own.
#
# The files live in %USERPROFILE% because that is where komorebi looks without
# KOMOREBI_CONFIG_HOME, and the Run key runs before a user variable set in a
# shell profile would exist.
{
  lib,
  config,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption mkEnableOption types;
  cfg = config.programs.komorebi;
  json = pkgs.buildPackages.formats.json { };

  # A base16 palette (nix-colors' colorScheme.palette, base00..base0F) as
  # komorebi's Custom theme: the same slots, spelled base_00..base_0f, with the
  # border and bar roles left at komorebi's defaults for the palette.
  slots = map (n: lib.toUpper (lib.toHexString n)) (lib.range 0 15);
  pad = s: if lib.stringLength s == 1 then "0${s}" else s;
  strip = lib.removePrefix "#";
  customTheme = palette: {
    palette = "Custom";
    colours = lib.listToAttrs (
      map (s: {
        name = "base_${lib.toLower (pad s)}";
        value = "#${strip palette."base${pad s}"}";
      }) slots
    );
  };
  theme = if cfg.base16 == null then null else customTheme cfg.base16.palette;

  given = cfg.settings;
  settings =
    given
    // lib.optionalAttrs (theme != null && !(given ? theme)) { inherit theme; }
    // lib.optionalAttrs (cfg.applications != null && !(given ? app_specific_configuration_path)) {
      app_specific_configuration_path = "$Env:USERPROFILE/applications.json";
    };

  barGiven = cfg.bar.settings;
  barSettings =
    barGiven // lib.optionalAttrs (theme != null && !(barGiven ? theme)) { inherit theme; };

  startCommand = ''"${cfg.komorebic}" start'' + lib.optionalString cfg.bar.enable " --bar";
in
{
  options.programs.komorebi = {
    enable = mkEnableOption "komorebi, a tiling window manager";

    package = mkOption {
      type = types.nullOr types.package;
      default = pkgs.winpkgs.fromWinget {
        id = "LGUG2Z.komorebi";
        scope = "machine";
      };
      defaultText = lib.literalExpression ''pkgs.winpkgs.fromWinget { id = "LGUG2Z.komorebi"; scope = "machine"; }'';
      description = ''
        The package to install: komorebi, komorebic and komorebi-bar together.
        winget's is an MSI, so it is machine scope and reaches the system
        configuration through `winpkgs.homes`. `null` installs nothing.
      '';
    };

    komorebic = mkOption {
      type = types.str;
      default = ''C:\Program Files\komorebi\bin\komorebic-no-console.exe'';
      description = ''
        The komorebic that the start-up entry runs, by full path: the
        console-less build the MSI ships, at its location, by default.
      '';
    };

    autostart = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Start komorebi at sign-in (and the bar, if enabled) through
        `windows.startup`, the way `komorebic enable-autostart` would.
      '';
    };

    settings = mkOption {
      type = json.type;
      default = { };
      example = lib.literalExpression ''
        {
          default_workspace_padding = 5;
          default_container_padding = 5;
          border = true;
          border_width = 1;
          monitors = [
            { workspaces = map (name: { inherit name; layout = "BSP"; }) [ "1" "2" "3" "4" "5" ]; }
          ];
        }
      '';
      description = ''
        komorebi.json, as komorebi documents it (the schema is at
        https://komorebi.lgug2z.com/schema). Written whole to
        `%USERPROFILE%\komorebi.json`; komorebi reloads it when it changes.
      '';
    };

    applications = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = lib.literalExpression ''"''${inputs.komorebi-asc}/applications.json"'';
      description = ''
        The application-specific configuration file (the community list of
        applications that need special handling, which `komorebic fetch-asc`
        downloads), placed at `%USERPROFILE%\applications.json` and named in
        `settings.app_specific_configuration_path` unless that is set. `null`
        leaves both alone.
      '';
    };

    base16 = mkOption {
      type = types.nullOr (
        types.submodule {
          options.palette = mkOption {
            type = types.attrsOf types.str;
            example = lib.literalExpression "config.colorScheme.palette";
            description = "A base16 palette, `base00` .. `base0F`, with or without the leading `#`.";
          };
        }
      );
      default = null;
      example = lib.literalExpression "{ palette = config.colorScheme.palette; }";
      description = ''
        A theme from a base16 palette: komorebi's `Custom` palette with the
        same sixteen colours, used as `settings.theme` and the bar's
        `theme` unless either sets its own. Which slot colours which border
        stays at komorebi's defaults (single Base0D, stack Base0B, monocle
        Base0F, floating Base09, unfocused Base03, bar accent Base0D).
      '';
    };

    bar = {
      enable = mkEnableOption "komorebi-bar, komorebi's status bar";

      settings = mkOption {
        type = json.type;
        default = { };
        example = lib.literalExpression ''
          {
            font_family = "JetBrainsMono Nerd Font";
            left_widgets = [ { Komorebi = { workspaces.enable = true; focused_window.enable = true; }; } ];
            right_widgets = [ { Date.enable = true; } { Time.enable = true; } ];
          }
        '';
        description = ''
          komorebi.bar.json (schema at https://komorebi-bar.lgug2z.com/schema),
          written whole to `%USERPROFILE%\komorebi.bar.json`; the bar reloads
          it when it changes. One bar, on the primary monitor: for one per
          monitor, list files in `settings.bar_configurations` and write them
          with `windows.files`.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = lib.optional (cfg.package != null) cfg.package;

    windows.files = {
      "%USERPROFILE%/komorebi.json".source = json.generate "komorebi.json" settings;
      "%USERPROFILE%/komorebi.bar.json" = lib.mkIf cfg.bar.enable {
        source = json.generate "komorebi.bar.json" barSettings;
      };
      "%USERPROFILE%/applications.json" = lib.mkIf (cfg.applications != null) {
        source = cfg.applications;
      };
    };

    windows.startup.komorebi = lib.mkIf cfg.autostart startCommand;
  };
}
