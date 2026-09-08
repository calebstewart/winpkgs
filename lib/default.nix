{
  lib,
  self,
  nixpkgs,
  nixos-wsl,
}:
let
  # The Windows target, as a nixpkgs cross platform. Evaluation happens on
  # `system` (WSL, CI); the configuration is *for* Windows, and `pkgs` says so.
  crossFor = {
    "x86_64-windows" = "mingwW64";
    "aarch64-windows" = "ucrtAarch64";
  };
in
{
  /*
    Evaluate a Windows configuration. The nix-darwin `darwinSystem` analogue.

    Returns the evalModules result; the closure to apply is
    `.config.system.build.toplevel`, which `nix run` executes as `bin/activate`.
    With `winpkgs.wsl.enable`, `.config.system.build.wsl` is the evaluated NixOS
    configuration of the machine's WSL distro, built as part of the toplevel.

    `system` is the system that *evaluates* (your WSL distro or CI runner);
    `platform` is the Windows target. Modules receive `pkgs` as a cross package
    set for that target, so `pkgs.stdenv.hostPlatform.isWindows` is true and
    `isLinux`/`isDarwin` are false -- platform detection works the way it does
    in NixOS and nix-darwin modules. Anything that must *run* while building
    the closure comes from `pkgs.buildPackages`.
  */
  windowsSystem =
    {
      modules,
      system ? "x86_64-linux",
      platform ? "x86_64-windows",
      specialArgs ? { },
    }:
    let
      buildPkgs = nixpkgs.legacyPackages.${system};
      cross =
        crossFor.${platform}
          or (throw "winpkgs: unsupported platform '${platform}'; one of: ${lib.concatStringsSep ", " (lib.attrNames crossFor)}");
      pkgs = buildPkgs.pkgsCross.${cross};
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
