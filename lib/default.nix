{
  lib,
  self,
  nixpkgs,
  nixos-wsl,
  home-manager,
  winget-pkgs,
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
        winpkgsInputs = {
          inherit
            nixpkgs
            nixos-wsl
            home-manager
            winget-pkgs
            ;
        };
        winpkgsKind = kind;
      }
      // lib.optionalAttrs isHome { modulesPath = toString "${home-manager}/modules"; }
      // specialArgs;
    };
in
{
  /**
    Evaluate a Windows *system* configuration -- the machine: `HKLM`,
    `%ProgramData%`, machine-scope packages, the WSL distro. Applied elevated,
    by construction. The nix-darwin `darwinSystem` analogue.

    Returns the evalModules result; the closure to apply is
    `.config.system.build.toplevel`, which `nix run` executes as `bin/activate`.
    With `wsl.enable`, `.config.system.build.wsl` is the evaluated NixOS
    configuration of the machine's WSL distro, built as part of the toplevel.
    `.config.system.build.installer` is a program that turns a Windows ISO
    into media that installs this configuration unattended (see
    `winpkgs.installer.*`).

    # Inputs

    `modules`
    : The configuration's modules, as paths or attrsets. `winpkgs.name` is the
      one option without a default.

    `system`
    : The system that *evaluates* -- the WSL distro or the CI runner. Default
      `"x86_64-linux"`.

    `platform`
    : The Windows target, `"x86_64-windows"` (default) or `"aarch64-windows"`.
      Modules see `pkgs` as a nixpkgs cross package set for it.

    `overlays`
    : Overlays applied to that package set after winpkgs' own.

    `config`
    : nixpkgs configuration merged over winpkgs' (`allowUnfree` and
      `allowUnsupportedSystem` are on already).

    `specialArgs`
    : Extra special arguments for the modules, beside `winpkgsSrc` (this
      flake's source), `winpkgsInputs` (its `nixpkgs`, `nixos-wsl`,
      `home-manager` and `winget-pkgs` inputs) and `winpkgsKind`.

    # Example

    ```nix
    windowsConfigurations.desktop = winpkgs.lib.windowsSystem {
      modules = [ ./hosts/desktop/configuration.nix ];
    };
    ```

    # Type

    ```
    windowsSystem :: AttrSet -> AttrSet
    ```
  */
  windowsSystem = evaluate "system";

  /**
    Evaluate a Windows *home* configuration -- one user: `HKCU`, `%USERPROFILE%`,
    user-scope packages, the shell, the `winpkgs` command. Applied as the user,
    never elevated. The home-manager `homeManagerConfiguration` analogue -- and
    literally so: home-manager's modules are evaluated here, so `programs.*`,
    `home.file`, `xdg.configFile`, `home.sessionVariables`, `home.sessionPath`
    and `home.packages` are home-manager's own options, translated to Windows
    (see modules/home/home-manager.nix for what carries over and what does not).

    Same arguments and result as `windowsSystem`.

    # Inputs

    `modules`
    : The configuration's modules. `winpkgs.name` is `<Windows user name>@<host>`,
      which is how the `winpkgs` command finds the configuration.

    `system`, `platform`, `overlays`, `config`, `specialArgs`
    : As for `windowsSystem`.

    # Example

    ```nix
    windowsHomeConfigurations."me@desktop" = winpkgs.lib.homeConfiguration {
      modules = [ ./hosts/desktop/home.nix ];
    };
    ```

    # Type

    ```
    homeConfiguration :: AttrSet -> AttrSet
    ```
  */
  homeConfiguration = evaluate "home";

  /**
    Every machine's installation media as flake `apps`: one per entry of the
    `windowsConfigurations` attrset, so the set of installers is never written
    out beside the set of machines and a machine added there brings its own.

    ```bash
    nix run .#desktop-iso -- --iso ~/Downloads/Win11.iso --out desktop.iso
    ```

    An unattended install creates one account, so a machine with several homes
    gets one app per home, named `<host>-iso-<user>`: the choice
    `system.build.installers` asks for, made in the name. A machine with no
    home has no account to create and so no installer, and gets no app rather
    than one that throws the moment the flake is checked.

    # Inputs

    `configurations`
    : The `windowsConfigurations` attrset, or any part of it. The attribute
      name -- not `winpkgs.name` -- is what the app is named after, so a
      machine is run by the name it is declared under.

    `suffix`
    : What an app's name ends with, `"-iso"` by default.

    # Example

    ```nix
    apps.x86_64-linux = winpkgs.lib.installerApps {
      configurations = self.windowsConfigurations;
    };
    ```

    # Type

    ```
    installerApps :: AttrSet -> AttrSet
    ```
  */
  installerApps =
    {
      configurations,
      suffix ? "-iso",
    }:
    let
      mkApp = installer: {
        type = "app";
        program = lib.getExe installer;
        meta = { inherit (installer.meta) description; };
      };

      # `system.build.installers` is keyed by the account each installer
      # creates, and is empty when the machine has no home -- the filtering
      # that decides whether there is anything to run has happened already.
      forMachine =
        name: configuration:
        let
          installers = configuration.config.system.build.installers;
          users = lib.attrNames installers;
        in
        if users == [ ] then
          { }
        else if lib.length users == 1 then
          { "${name}${suffix}" = mkApp installers.${lib.head users}; }
        else
          lib.mapAttrs' (
            user: installer: lib.nameValuePair "${name}${suffix}-${user}" (mkApp installer)
          ) installers;
    in
    lib.concatMapAttrs forMachine configurations;

  /**
    The pieces an unattended install is made of: the answer file Windows Setup
    reads off the boot media, the payload it runs, and the program that puts
    both onto a copy of a Windows ISO. `modules/system/installer.nix` assembles
    them as `system.build.installer`; this is for anyone who wants the parts,
    and each is documented under `winpkgs.lib.installer`.

    # Type

    ```
    installer :: AttrSet
    ```
  */
  installer = import ./installer.nix {
    inherit lib;
    winpkgsSrc = self;
  };

  /**
    How `winget.packages` finds a version in a winget-pkgs tree: which versions
    a package has, which is latest, and what an entry without a version
    resolves to, all from directory names. And what a version's installer is:
    its installer manifest, parsed by a YAML subset reader of its own; the
    installer a configuration would get; and the record that carries it to
    installation media. The module uses the first half against
    `winget.manifests`; this is the same reader over any tree, for a check or a
    tool of your own, and each piece is documented under `winpkgs.lib.winget`.

    # Example

    ```nix
    winpkgs.lib.winget.latestVersion inputs.winget-pkgs "Git.Git"
    => "2.51.0"
    ```

    # Type

    ```
    winget :: AttrSet
    ```
  */
  winget = import ./winget.nix { inherit lib; };
}
