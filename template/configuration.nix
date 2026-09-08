# The machine.
{ pkgs, ... }:
{
  winpkgs.name = "desktop";

  environment.systemPackages = [ pkgs._7zz ];

  winpkgs.developer.longPaths = true;

  # The NixOS-WSL distro that evaluates and applies this configuration.
  winpkgs.wsl = {
    enable = true;
    modules = [ { system.stateVersion = "26.05"; } ];
  };
}
