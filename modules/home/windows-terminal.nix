# Windows Terminal, in home-manager's shape: `programs.windows-terminal.settings`
# is its settings.json, owned outright, as home-manager owns a program's
# configuration file. Terminal watches the file and reloads it as it lands.
#
# Two conveniences write into the same document: `schemes` adds colour
# schemes by name, and `base16` turns a palette (nix-colors'
# colorScheme.palette) into one and makes it the default profile's, unless
# `settings` already says otherwise.
{
  lib,
  config,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption mkEnableOption types;
  cfg = config.programs.windows-terminal;
  json = pkgs.buildPackages.formats.json { };

  strip = lib.removePrefix "#";
  color = slot: "#${strip cfg.base16.palette.${slot}}";
  # Terminal's scheme fields, with the base16 shell assignment (purple is
  # what Terminal calls magenta).
  base16Scheme = {
    name = cfg.base16.name;
    foreground = color "base05";
    background = color "base00";
    cursorColor = color "base05";
    selectionBackground = color "base02";
    black = color "base00";
    red = color "base08";
    green = color "base0B";
    yellow = color "base0A";
    blue = color "base0D";
    purple = color "base0E";
    cyan = color "base0C";
    white = color "base05";
    brightBlack = color "base03";
    brightRed = color "base08";
    brightGreen = color "base0B";
    brightYellow = color "base0A";
    brightBlue = color "base0D";
    brightPurple = color "base0E";
    brightCyan = color "base0C";
    brightWhite = color "base07";
  };

  namedSchemes = lib.mapAttrsToList (name: s: { inherit name; } // s) cfg.schemes;
  extraSchemes = namedSchemes ++ lib.optional (cfg.base16 != null) base16Scheme;

  given = cfg.settings;
  profiles = given.profiles or { };
  defaults = profiles.defaults or { };
  merged = {
    "$schema" = "https://aka.ms/terminal-profiles-schema";
  }
  // given
  // {
    schemes = (given.schemes or [ ]) ++ extraSchemes;
    profiles = profiles // {
      defaults =
        defaults
        // lib.optionalAttrs (cfg.base16 != null && !(defaults ? colorScheme)) {
          colorScheme = cfg.base16.name;
        };
    };
  };

  settingsFile = json.generate "settings.json" merged;
in
{
  options.programs.windows-terminal = {
    enable = mkEnableOption "Windows Terminal configuration";

    package = mkOption {
      type = types.nullOr types.package;
      default = null;
      example = lib.literalExpression ''pkgs.winpkgs.fromWinget "Microsoft.WindowsTerminal"'';
      description = ''
        A package to install for it, through winget. `null`, the default,
        installs nothing: Windows 11 ships Terminal.
      '';
    };

    settingsPath = mkOption {
      type = types.str;
      default = "%LOCALAPPDATA%/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json";
      description = ''
        Where Terminal reads its settings: the Store (and Windows 11 inbox)
        package's path by default; `%LOCALAPPDATA%/Microsoft/Windows
        Terminal/settings.json` for an unpackaged install.
      '';
    };

    settings = mkOption {
      type = json.type;
      default = { };
      example = lib.literalExpression ''
        {
          defaultProfile = "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}";
          copyOnSelect = true;
          profiles.defaults.font.face = "JetBrainsMono Nerd Font Mono";
        }
      '';
      description = ''
        The settings.json document, as Terminal documents it. Written whole:
        what Terminal's own UI changes is overwritten by the next apply, as
        with any file home-manager manages.
      '';
    };

    schemes = mkOption {
      type = types.attrsOf (types.attrsOf types.str);
      default = { };
      example = lib.literalExpression ''{ "My Scheme" = { background = "#000000"; foreground = "#ffffff"; }; }'';
      description = "Colour schemes to add to `settings.schemes`, by name, with Terminal's field names.";
    };

    base16 = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            palette = mkOption {
              type = types.attrsOf types.str;
              example = lib.literalExpression "config.colorScheme.palette";
              description = "A base16 palette, `base00` .. `base0F`, with or without the leading `#`.";
            };
            name = mkOption {
              type = types.str;
              default = "base16";
              description = "The scheme's name in Terminal.";
            };
          };
        }
      );
      default = null;
      example = lib.literalExpression "{ palette = config.colorScheme.palette; name = \"Catppuccin Mocha\"; }";
      description = ''
        A colour scheme from a base16 palette, added to `settings.schemes`
        and made the default profile's `colorScheme` unless `settings` sets
        one. The assignment is the base16 shell scripts': black is base00, red
        base08, green base0B, yellow base0A, blue base0D, purple base0E, cyan
        base0C, white base05, bright black base03, bright white base07, text
        base05 on base00, selection base02.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = lib.optional (cfg.package != null) cfg.package;
    windows.files.${cfg.settingsPath}.source = settingsFile;
  };
}
