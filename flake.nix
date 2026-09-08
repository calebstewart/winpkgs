{
  description = "winpkgs - declarative Windows configuration: Nix evaluates, PowerShell applies";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Makes the embedded WSL distro (winpkgs.wsl) a NixOS-WSL system.
    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-wsl,
    }:
    let
      inherit (nixpkgs) lib;
      # Systems that *evaluate* configurations (WSL, CI). The target is always Windows.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = lib.genAttrs systems;
      winpkgsLib = import ./lib {
        inherit
          lib
          self
          nixpkgs
          nixos-wsl
          ;
      };
    in
    {
      lib = winpkgsLib;

      # The full module tree, for consumers who want to evalModules themselves.
      windowsModules.default = import ./modules;

      templates.default = {
        path = ./template;
        description = "A flake with one winpkgs Windows configuration";
      };

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          example = winpkgsLib.windowsSystem {
            inherit system;
            modules = [ ./example/configuration.nix ];
          };
          withWsl = winpkgsLib.windowsSystem {
            inherit system;
            modules = [
              ./example/configuration.nix
              {
                winpkgs.wsl.enable = true;
                winpkgs.wsl.modules = [ { system.stateVersion = "26.05"; } ];
              }
            ];
          };
        in
        {
          example = example.config.system.build.toplevel;

          # The example lists Microsoft.PowerShell and winpkgs.powershell ensures
          # it too: they must merge into one resource that upgrades.
          merge =
            pkgs.runCommand "winpkgs-merge"
              {
                doc = builtins.toJSON example.config.system.build.document;
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                n=$(echo "$doc" | jq '[.resources[] | select(.id == "Microsoft.PowerShell")] | length')
                up=$(echo "$doc" | jq '.resources[] | select(.id == "Microsoft.PowerShell") | .properties.upgrade')
                test "$n" = 1 && test "$up" = true
                echo ok > $out
              '';

          # Proves the embedded NixOS-WSL system evaluates, without building a
          # whole NixOS closure in CI: instantiate its toplevel and record the
          # .drv path only.
          wsl-eval =
            pkgs.runCommand "winpkgs-wsl-eval"
              {
                drv = builtins.unsafeDiscardStringContext withWsl.config.system.build.wsl.config.system.build.toplevel.drvPath;
                hostName = withWsl.config.system.build.wsl.config.networking.hostName;
              }
              ''
                test "$hostName" = example
                echo "$drv" > $out
              '';
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
