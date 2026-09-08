# A small but realistic configuration. Built by `nix flake check`.
{ pkgs, ... }:
{
  winpkgs.name = "example";

  # nixpkgs names, installed through winget via the overlay's annotations.
  home.packages = [
    pkgs.git
    pkgs.ripgrep
    (pkgs.winpkgs.fromWinget "Microsoft.PowerToys")
  ];

  # winget ids directly, for pins and for things the table does not know.
  winpkgs.packages.winget = [
    "Microsoft.PowerShell"
    {
      id = "wez.wezterm";
      version = "20240203-110809-5046fc22";
    }
  ];

  winpkgs.explorer = {
    showHiddenFiles = true;
    showFileExtensions = true;
    launchTo = "thisPC";
    contextMenu = "classic";
  };

  winpkgs.taskbar = {
    alignment = "left";
    searchBox = "icon";
    widgets = false;
  };

  winpkgs.theme.mode = "dark";

  winpkgs.privacy = {
    advertisingId = false;
    suggestedApps = false;
    webSearchInStart = false;
  };

  winpkgs.developer.longPaths = true;

  winpkgs.keyboard.remap.CapsLock = "LeftCtrl";

  # Anything the modules above do not model stays reachable, and an entry here
  # overrides one of theirs.
  winpkgs.registry."HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced".DontPrettyPath =
    1;

  # home-manager's names, so this block could sit in a module shared with a
  # NixOS or macOS home configuration.
  home.sessionVariables.EDITOR = ''%LOCALAPPDATA%\Programs\nvim\bin\nvim.exe'';
  home.file.".wezterm.lua".text = ''
    local wezterm = require("wezterm")
    return {
      font = wezterm.font("JetBrains Mono"),
      color_scheme = "Catppuccin Mocha",
    }
  '';
  xdg.configFile."starship.toml".text = ''
    add_newline = false
  '';
}
