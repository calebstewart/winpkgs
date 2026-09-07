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
      windowsConfigurations.desktop = winpkgs.lib.windowsSystem {
        modules = [ ./configuration.nix ];
      };

      # `nix run` from WSL applies the configuration to the Windows host.
      packages.x86_64-linux.default =
        (winpkgs.lib.windowsSystem { modules = [ ./configuration.nix ]; }).config.system.build.toplevel;
    };
}
