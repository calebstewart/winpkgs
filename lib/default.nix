{
  lib,
  self,
  nixpkgs,
  nixos-wsl,
}:
{
  /*
    Evaluate a Windows configuration. The nix-darwin `darwinSystem` analogue.

    Returns the evalModules result; the closure to apply is
    `.config.system.build.toplevel`, which `nix run` executes as `bin/activate`.
    With `winpkgs.wsl.enable`, `.config.system.build.wsl` is the evaluated NixOS
    configuration of the machine's WSL distro, built as part of the toplevel.

    `system` is the system that *evaluates* (your WSL distro or CI runner), not
    the target - the target is always Windows.
  */
  windowsSystem =
    {
      modules,
      system ? "x86_64-linux",
      specialArgs ? { },
    }:
    let
      pkgs = nixpkgs.legacyPackages.${system};
    in
    lib.evalModules {
      modules = [
        ../modules
        { _module.args.pkgs = pkgs; }
      ]
      ++ modules;
      specialArgs = {
        winpkgsSrc = self;
        winpkgsInputs = { inherit nixpkgs nixos-wsl; };
      }
      // specialArgs;
    };
}
