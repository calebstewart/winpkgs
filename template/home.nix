# One user.
{ pkgs, ... }:
{
  winpkgs.name = "me@desktop";

  # home-manager's modules work here; this installs Git and writes .config/git/config.
  programs.git = {
    enable = true;
    settings.user = {
      name = "Me";
      email = "me@example.com";
    };
  };
  home.packages = [ pkgs.ripgrep ];

  windows.explorer = {
    showHiddenFiles = true;
    showFileExtensions = true;
  };

  # Where this flake is checked out on Windows, so `winpkgs` finds it.
  winpkgs.cli.flake = ''%USERPROFILE%\config'';
}
