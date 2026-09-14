{
  description = "My Windows configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    winpkgs.url = "github:calebstewart/winpkgs";
    winpkgs.inputs.nixpkgs.follows = "nixpkgs";

    # Package versions come from winpkgs' pinned winget-pkgs, as packages come
    # from nixpkgs. To move them on your own schedule, pin it yourself and
    # point winpkgs at your pin; `nix flake update winget-pkgs` then updates
    # packages without updating winpkgs.
    # winget-pkgs = { url = "github:microsoft/winget-pkgs"; flake = false; };
    # winpkgs.inputs.winget-pkgs.follows = "winget-pkgs";
  };

  outputs =
    { self, winpkgs, ... }:
    {
      # The machine: applied elevated. `winpkgs system switch`. It installs the
      # home's machine-wide packages (Git) too, which a home never elevates for.
      windowsConfigurations.desktop = winpkgs.lib.windowsSystem {
        modules = [
          ./configuration.nix
          { winpkgs.homes = [ self.windowsHomeConfigurations."me@desktop" ]; }
        ];
      };

      # One user on it: applied as that user. `winpkgs home switch`.
      # Name it <Windows user name>@<host> so the winpkgs command finds it.
      windowsHomeConfigurations."me@desktop" = winpkgs.lib.homeConfiguration {
        modules = [ ./home.nix ];
      };
    };
}
