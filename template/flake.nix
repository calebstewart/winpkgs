{
  description = "My Windows configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    winpkgs.url = "github:calebstewart/winpkgs";
    winpkgs.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { winpkgs, ... }:
    {
      # The machine: applied elevated. `winpkgs system switch`.
      windowsConfigurations.desktop = winpkgs.lib.windowsSystem {
        modules = [ ./configuration.nix ];
      };

      # One user on it: applied as that user. `winpkgs home switch`.
      # Name it <Windows user name>@<host> so the winpkgs command finds it.
      windowsHomeConfigurations."me@desktop" = winpkgs.lib.homeConfiguration {
        modules = [ ./home.nix ];
      };
    };
}
