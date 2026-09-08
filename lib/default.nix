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

  /*
    Both evaluators share this. `kind` picks the module tree -- system or home
    -- and is handed to modules as the `winpkgsKind` special argument, which is
    what fixes the scope of every resource they emit.

    `system` is the system that *evaluates* (your WSL distro or CI runner);
    `platform` is the Windows target. Modules receive `pkgs` as a cross package
    set for that target, so `pkgs.stdenv.hostPlatform.isWindows` is true and
    `isLinux`/`isDarwin` are false -- platform detection works the way it does
    in NixOS and nix-darwin modules. Anything that must *run* while building
    the closure comes from `pkgs.buildPackages`.

    The set carries the winpkgs overlay (`pkgs.git.winget.id == "Git.Git"`,
    `pkgs.winpkgs.fromWinget`) and allows unsupported systems, so `pkgs.neovim`
    evaluates even though nixpkgs does not claim to build it for Windows -- it
    is only ever mapped to winget, never built. `overlays` and `config` extend
    both.
  */
  evaluate =
    kind:
    {
      modules,
      system ? "x86_64-linux",
      platform ? "x86_64-windows",
      overlays ? [ ],
      config ? { },
      specialArgs ? { },
    }:
    let
      cross =
        crossFor.${platform}
          or (throw "winpkgs: unsupported platform '${platform}'; one of: ${lib.concatStringsSep ", " (lib.attrNames crossFor)}");
      pkgs = import nixpkgs {
        localSystem = system;
        crossSystem = lib.systems.examples.${cross};
        config = {
          allowUnsupportedSystem = true;
          allowUnfree = true;
        }
        // config;
        overlays = [ (import ../overlays) ] ++ overlays;
      };
    in
    lib.evalModules {
      modules = [
        (../modules + "/${kind}")
        { _module.args.pkgs = pkgs; }
      ]
      ++ modules;
      specialArgs = {
        winpkgsSrc = self;
        winpkgsInputs = { inherit nixpkgs nixos-wsl; };
        winpkgsKind = kind;
      }
      // specialArgs;
    };
in
{
  /*
    Evaluate a Windows *system* configuration -- the machine: `HKLM`,
    `%ProgramData%`, machine-scope packages, the WSL distro. Applied elevated,
    by construction. The nix-darwin `darwinSystem` analogue.

    Returns the evalModules result; the closure to apply is
    `.config.system.build.toplevel`, which `nix run` executes as `bin/activate`.
    With `winpkgs.wsl.enable`, `.config.system.build.wsl` is the evaluated NixOS
    configuration of the machine's WSL distro, built as part of the toplevel.
  */
  windowsSystem = evaluate "system";

  /*
    Evaluate a Windows *home* configuration -- one user: `HKCU`, `%USERPROFILE%`,
    user-scope packages, the shell, the `winpkgs` command. Applied as the user,
    never elevated. The home-manager `homeManagerConfiguration` analogue, and
    where its option names (`home.file`, `xdg.configFile`, `home.packages`,
    `home.sessionVariables`) are declared.

    Same shape and result as `windowsSystem`.
  */
  homeConfiguration = evaluate "home";
}
