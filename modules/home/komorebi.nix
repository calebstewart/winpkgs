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
# hidden. The Run entry here does the same. whkd and masir are not passed as
# `--whkd` and `--masir`: programs.whkd and programs.masir start their own, so
# each daemon stands on its own.
#
# The files live in %USERPROFILE% because that is where komorebi looks without
# KOMOREBI_CONFIG_HOME, and the Run key runs before a user variable set in a
# shell profile would exist.
#
# `service.enable` runs komorebi as home-manager's `systemd.user.services`
# instead, for a user service manager (steward, whose home module writes them
# as units): komorebi.exe itself, stopped with `komorebic stop` so that the
# windows it hid on other workspaces come back, and a unit per bar,
# `komorebi-bar` (or `komorebi-bar-<monitor>`), part of komorebi's -- what
# `start --bar` launches, each supervised on its own.
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
  baseSettings =
    given
    // lib.optionalAttrs (theme != null && !(given ? theme)) { inherit theme; }
    // lib.optionalAttrs (cfg.applications != null && !(given ? app_specific_configuration_path)) {
      app_specific_configuration_path = "$Env:USERPROFILE/applications.json";
    };

  barGiven = cfg.bar.settings;
  barSettings =
    barGiven // lib.optionalAttrs (theme != null && !(barGiven ? theme)) { inherit theme; };

  # One bar per monitor: each instance is the shared bar settings with the
  # instance's own on top and `monitor` set to its index unless it says
  # otherwise, in its own file that komorebi.json lists.
  perMonitor = cfg.bar.monitors != { };
  monitorFile = index: "komorebi.bar.${index}.json";
  monitorSettings =
    index: overrides: lib.recursiveUpdate barSettings ({ monitor = lib.toInt index; } // overrides);
  barConfigurations = map (index: "$Env:USERPROFILE/${monitorFile index}") (
    lib.attrNames cfg.bar.monitors
  );
  badMonitors = lib.filter (i: builtins.match "[0-9]+" i == null) (lib.attrNames cfg.bar.monitors);

  settings =
    baseSettings
    // lib.optionalAttrs (cfg.bar.enable && perMonitor && !(baseSettings ? bar_configurations)) {
      bar_configurations = barConfigurations;
    };

  startCommand = ''"${cfg.komorebic}" start'' + lib.optionalString cfg.bar.enable " --bar";

  # The bars a service manager runs: one per monitor file, or the one.
  # home.homeDirectory is written into the unit and becomes the real profile
  # directory when winpkgs writes the file.
  barConfig = file: "${config.home.homeDirectory}/${file}";
  bars =
    if perMonitor then
      lib.mapAttrs' (
        index: _: lib.nameValuePair "komorebi-bar-${index}" (monitorFile index)
      ) cfg.bar.monitors
    else
      { komorebi-bar = "komorebi.bar.json"; };
  barService = file: {
    Unit = {
      Description = "komorebi-bar, ${file}";
      After = [ "komorebi.service" ];
      # Stopped and restarted with komorebi.
      PartOf = [ "komorebi.service" ];
    };
    Service.ExecStart = ''"${cfg.bar.executable}" --config "${barConfig file}"'';
    Install.WantedBy = [ "komorebi.service" ];
  };
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

    executable = mkOption {
      type = types.str;
      default = ''C:\Program Files\komorebi\bin\komorebi.exe'';
      description = "komorebi.exe, which a service runs directly: the MSI's location by default.";
    };

    autostart = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Start komorebi at sign-in (and the bar, if enabled) through
        `windows.startup`, the way `komorebic enable-autostart` would. Moot
        with `service.enable`.
      '';
    };

    service.enable = mkEnableOption ''
      komorebi as user services instead of a Run entry:
      `systemd.user.services.komorebi`, and one per bar, which a user service
      manager runs (steward's home module makes them units). komorebi is
      started with `graphical-session.target` unless its unit says otherwise
      and stopped with `komorebic stop`, which gives back the windows it hid;
      the bars start and stop with it. The Run entry is removed'';

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

      executable = mkOption {
        type = types.str;
        default = ''C:\Program Files\komorebi\bin\komorebi-bar.exe'';
        description = "komorebi-bar.exe, which a bar's service runs: the MSI's location by default.";
      };

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
          it when it changes. One bar, on the primary monitor, unless
          `monitors` asks for more, in which case these are the settings every
          instance starts from.
        '';
      };

      monitors = mkOption {
        type = types.attrsOf json.type;
        default = { };
        example = lib.literalExpression ''
          {
            "0" = { };
            "1".monitor.work_area_offset = { left = 0; top = 40; right = 0; bottom = 40; };
          }
        '';
        description = ''
          A bar per monitor, by komorebi monitor index, each an instance of
          `settings` with these on top and `monitor` set to the index unless
          given. Every instance is its own file,
          `%USERPROFILE%\komorebi.bar.<index>.json`, listed in
          `settings.bar_configurations` (unless that is set) so that `start
          --bar` launches one bar per file; `komorebi.bar.json` is then not
          written.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = badMonitors == [ ];
        message = "programs.komorebi.bar.monitors: keys are komorebi monitor indices (\"0\", \"1\", ...), not: ${lib.concatStringsSep ", " badMonitors}";
      }
    ];

    home.packages = lib.optional (cfg.package != null) cfg.package;

    windows.files = {
      "%USERPROFILE%/komorebi.json".source = json.generate "komorebi.json" settings;
      "%USERPROFILE%/komorebi.bar.json" = lib.mkIf (cfg.bar.enable && !perMonitor) {
        source = json.generate "komorebi.bar.json" barSettings;
      };
      "%USERPROFILE%/applications.json" = lib.mkIf (cfg.applications != null) {
        source = cfg.applications;
      };
    }
    // lib.optionalAttrs (cfg.bar.enable && perMonitor) (
      lib.mapAttrs' (
        index: overrides:
        lib.nameValuePair "%USERPROFILE%/${monitorFile index}" {
          source = json.generate (monitorFile index) (monitorSettings index overrides);
        }
      ) cfg.bar.monitors
    );

    windows.startup.komorebi = if cfg.service.enable then null else lib.mkIf cfg.autostart startCommand;

    systemd.user.services = lib.mkIf cfg.service.enable (
      {
        komorebi = {
          Unit = {
            Description = "komorebi, a tiling window manager";
            After = [ "graphical-session.target" ];
          };
          Service = {
            ExecStart = ''"${cfg.executable}"'';
            # Killed, it would leave the windows of other workspaces hidden.
            ExecStop = ''"${cfg.komorebic}" stop'';
          };
          Install.WantedBy = lib.mkDefault [ "graphical-session.target" ];
        };
      }
      // lib.optionalAttrs cfg.bar.enable (lib.mapAttrs (_: barService) bars)
    );
  };
}
