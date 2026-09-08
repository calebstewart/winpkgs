# The machine.
{ pkgs, ... }:
{
  winpkgs.name = "desktop";

  environment.systemPackages = [ pkgs._7zz ];

  windows.developer.longPaths = true;

  # The NixOS-WSL distro that evaluates and applies this configuration.
  wsl = {
    enable = true;
    modules = [ { system.stateVersion = "26.05"; } ];
  };
}
