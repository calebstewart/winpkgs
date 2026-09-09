# A small but realistic *home* configuration: one user. Built by
# `nix flake check`. The machine's half is example/configuration.nix.
{ pkgs, ... }:
{
  winpkgs.name = "example@example";

  # home-manager's own modules, so this could sit in a module shared with a
  # NixOS or macOS home configuration. programs.git installs Git (winget) and
  # writes .config/git/config.
  programs.git = {
    enable = true;
    settings.user = {
      name = "Example";
      email = "example@example.com";
    };
  };
  # GitHub CLI, and with it the git credential helper the module above writes
  # for github.com -- as a command on the PATH, where home-manager would have
  # spelled a Nix store path.
  programs.gh.enable = true;

  # A font in home.packages is installed for this user from its files, as
  # home-manager would; a program is installed through winget.
  home.packages = [
    pkgs.ripgrep
    pkgs.nerd-fonts.jetbrains-mono
    (pkgs.winpkgs.fromWinget "Microsoft.PowerToys")
  ];
  home.sessionVariables.EDITOR = ''%LOCALAPPDATA%\Programs\nvim\bin\nvim.exe'';
  home.file.".wezterm.lua".text = ''
    local wezterm = require("wezterm")
    return {
      font = wezterm.font("JetBrainsMono Nerd Font"),
      color_scheme = "Catppuccin Mocha",
    }
  '';
  xdg.configFile."starship.toml".text = ''
    add_newline = false
  '';

  # winget ids directly. Microsoft.PowerShell is also ensured by
  # winpkgs.powershell; the two merge.
  winget.packages = [ "Microsoft.PowerShell" ];

  windows.explorer = {
    showHiddenFiles = true;
    showFileExtensions = true;
    launchTo = "thisPC";
    contextMenu = "classic";
  };

  windows.taskbar = {
    alignment = "left";
    searchBox = "icon";
    widgets = false;
  };

  windows.theme.mode = "dark";

  windows.privacy = {
    advertisingId = false;
    suggestedApps = false;
    webSearchInStart = false;
  };

  # Anything the modules above do not model stays reachable, and an entry here
  # overrides one of theirs.
  windows.registry."HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced".DontPrettyPath =
    1;
}
