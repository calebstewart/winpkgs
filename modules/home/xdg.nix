# XDG base directories, home-manager style. Deliberately `~/.config` and
# `~/.local/share` rather than `%APPDATA%`: the tools that honour XDG on Windows
# (wezterm, starship, bat, ripgrep, ...) read exactly `$HOME/.config` there too,
# so `xdg.configFile."wezterm/wezterm.lua"` is right on every platform. A tool
# with its own Windows convention (nvim in `%LOCALAPPDATA%`, alacritty in
# `%APPDATA%`) is not honouring XDG and gets an explicit `home.file` path --
# the same call home-manager users make for `~/Library/Application Support`.
{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.xdg;
  homeFile = import ./home-file.nix { inherit lib; };

  filesUnder =
    root: entries:
    lib.mapAttrs' (
      _: f:
      lib.nameValuePair "${root}/${f.target}" {
        inherit (f)
          enable
          text
          source
          recursive
          ;
      }
    ) entries;

  onChangeAssertions =
    optionName: entries:
    lib.mapAttrsToList (n: f: {
      assertion = f.onChange == null;
      message = "${optionName}.\"${n}\".onChange is not supported by winpkgs (no command-running resource yet)";
    }) entries;
in
{
  options.xdg = {
    configHome = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.config";
      defaultText = lib.literalExpression ''"''${home.homeDirectory}/.config"'';
      description = "XDG config home. `~/.config`, as it is everywhere.";
    };
    dataHome = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.local/share";
      defaultText = lib.literalExpression ''"''${home.homeDirectory}/.local/share"'';
      description = "XDG data home.";
    };
    stateHome = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.local/state";
      defaultText = lib.literalExpression ''"''${home.homeDirectory}/.local/state"'';
      description = "XDG state home.";
    };
    cacheHome = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.cache";
      defaultText = lib.literalExpression ''"''${home.homeDirectory}/.cache"'';
      description = "XDG cache home.";
    };

    configFile = mkOption {
      type = types.attrsOf homeFile;
      default = { };
      example = lib.literalExpression ''{ "wezterm/wezterm.lua".source = ./wezterm.lua; }'';
      description = "Files under `xdg.configHome`, with home-manager's option names.";
    };
    dataFile = mkOption {
      type = types.attrsOf homeFile;
      default = { };
      description = "Files under `xdg.dataHome`, with home-manager's option names.";
    };
  };

  config = {
    winpkgs.files = lib.mkMerge [
      (filesUnder cfg.configHome cfg.configFile)
      (filesUnder cfg.dataHome cfg.dataFile)
    ];

    assertions =
      onChangeAssertions "xdg.configFile" cfg.configFile
      ++ onChangeAssertions "xdg.dataFile" cfg.dataFile;
  };
}
