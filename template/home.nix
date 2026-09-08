# One user.
{ pkgs, ... }:
{
  winpkgs.name = "me@desktop";

  home.packages = [ pkgs.git ];

  winpkgs.explorer = {
    showHiddenFiles = true;
    showFileExtensions = true;
  };

  # Where this flake is checked out on Windows, so `winpkgs` finds it.
  winpkgs.cli.flake = ''%USERPROFILE%\config'';
}
