{
  lib,
  self,
  nixpkgs,
  nixos-wsl,
  home-manager,
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
          # The set is read for names and winget ids, never built, so nixpkgs'
          # verdict on whether a package *would* build for Windows is noise:
          # `pkgs.python3` must evaluate for a module that mentions it to
          # evaluate. What actually cannot reach Windows -- a store path in a
          # file -- is caught where it happens, when the closure is built.
          allowUnsupportedSystem = true;
          allowBroken = true;
          allowUnfree = true;
        }
        // config;
        overlays = [ (import ../overlays) ] ++ overlays;
      };

      # A home configuration is home-manager's own module tree, evaluated
      # against the Windows `pkgs` and with home-manager's extended lib
      # (`lib.hm`), exactly as home-manager itself does it -- plus winpkgs'
      # modules, one of which (modules/home/home-manager.nix) turns what
      # home-manager produced into Windows resources. `useNixpkgsModule =
      # false` is home-manager's "use the pkgs you were given".
      isHome = kind == "home";
      hmLib = import "${home-manager}/modules/lib/stdlib-extended.nix" lib;
      hmModules = lib.optionals isHome (
        import "${home-manager}/modules/modules.nix" {
          inherit pkgs;
          lib = hmLib;
          useNixpkgsModule = false;
        }
      );
      evalLib = if isHome then hmLib else lib;
    in
    evalLib.evalModules {
      modules = [
        (../modules + "/${kind}")
        { _module.args.pkgs = pkgs; }
      ]
      ++ hmModules
      ++ modules;
      specialArgs = {
        winpkgsSrc = self;
        winpkgsInputs = { inherit nixpkgs nixos-wsl home-manager; };
        winpkgsKind = kind;
      }
      // lib.optionalAttrs isHome { modulesPath = toString "${home-manager}/modules"; }
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
    With `wsl.enable`, `.config.system.build.wsl` is the evaluated NixOS
    configuration of the machine's WSL distro, built as part of the toplevel.
  */
  windowsSystem = evaluate "system";

  /*
    Evaluate a Windows *home* configuration -- one user: `HKCU`, `%USERPROFILE%`,
    user-scope packages, the shell, the `winpkgs` command. Applied as the user,
    never elevated. The home-manager `homeManagerConfiguration` analogue -- and
    literally so: home-manager's modules are evaluated here, so `programs.*`,
    `home.file`, `xdg.configFile`, `home.sessionVariables`, `home.sessionPath`
    and `home.packages` are home-manager's own options, translated to Windows
    (see modules/home/home-manager.nix for what carries over and what does not).

    Same shape and result as `windowsSystem`.
  */
  homeConfiguration = evaluate "home";

  /*
    The pieces an unattended install is made of: the answer file Windows Setup
    reads off the boot media, and the facts it needs that a winpkgs
    configuration already carries.

    Not a builder yet -- `mkUnattend` returns the XML as a string, and the
    payload and the remastered ISO are built on top of it.
  */
  installer = import ./installer.nix { inherit lib; };
}
