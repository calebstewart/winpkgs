# A small but realistic configuration. Built by `nix flake check`.
{ ... }:
{
  winpkgs.name = "example";

  winpkgs.packages.winget = [
    "Git.Git"
    "Microsoft.PowerShell"
    {
      id = "wez.wezterm";
      version = "20240203-110809-5046fc22";
    }
  ];

  winpkgs.registry = {
    # Explorer: show hidden files and extensions, open to This PC.
    "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced" = {
      Hidden = 1;
      HideFileExt = 0;
      LaunchTo = 1;
      ShowSuperHidden = null; # delete if someone set it
    };
    # Dark mode.
    "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize" = {
      AppsUseLightTheme = 0;
      SystemUsesLightTheme = 0;
    };
    "HKCU\\Environment" = {
      EDITOR = {
        type = "ExpandString";
        value = ''%LOCALAPPDATA%\Programs\nvim\bin\nvim.exe'';
      };
    };
  };

  winpkgs.files = {
    "%USERPROFILE%/.wezterm.lua".text = ''
      local wezterm = require("wezterm")
      return {
        font = wezterm.font("JetBrains Mono"),
        color_scheme = "Catppuccin Mocha",
      }
    '';
  };
}
