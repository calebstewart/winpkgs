{
  description = "winpkgs - declarative Windows configuration: Nix evaluates, PowerShell applies";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      # Systems that *evaluate* configurations (WSL, CI). The target is always Windows.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = lib.genAttrs systems;
      winpkgsLib = import ./lib { inherit lib self nixpkgs; };
    in
    {
      lib = winpkgsLib;

      # The full module tree, for consumers who want to evalModules themselves.
      windowsModules.default = import ./modules;

      templates.default = {
        path = ./template;
        description = "A flake with one winpkgs Windows configuration";
      };

      checks = forAllSystems (system: {
        example =
          (winpkgsLib.windowsSystem {
            inherit system;
            modules = [ ./example/configuration.nix ];
          }).config.system.build.toplevel;
      });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
