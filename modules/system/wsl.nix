{
  lib,
  config,
  winpkgsInputs,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.wsl;
in
{
  options.wsl = {
    enable = lib.mkEnableOption "a NixOS-WSL distro as part of this machine's configuration";

    modules = mkOption {
      type = types.listOf types.deferredModule;
      default = [ ];
      example = lib.literalExpression ''
        [
          ./wsl.nix
          { system.stateVersion = "26.05"; }
        ]
      '';
      description = ''
        Additional NixOS modules for the distro -- anything a
        `nixosSystem { modules = ...; }` call would take. Optional: without any,
        the distro is the slim base winpkgs needs to run (NixOS-WSL, flakes
        enabled, `git`), with `wsl.defaultUser` from `wsl.defaultUser`
        and `networking.hostName` defaulting to `winpkgs.name`. You will want at
        least `system.stateVersion`.
      '';
    };

    specialArgs = mkOption {
      type = types.attrsOf types.raw;
      default = { };
      description = "Passed to `nixosSystem` as `specialArgs` (your flake's `inputs`, typically).";
    };

    nixpkgs = mkOption {
      type = types.raw;
      default = winpkgsInputs.nixpkgs;
      defaultText = lib.literalMD "winpkgs' own `nixpkgs` input";
      description = "The nixpkgs flake whose `lib.nixosSystem` evaluates the distro.";
    };

    pkgs = mkOption {
      type = types.nullOr types.raw;
      default = null;
      description = ''
        A pre-instantiated package set to use as `nixpkgs.pkgs`, so the distro
        shares overlays and `config` with your other NixOS hosts. When null, the
        NixOS modules instantiate `nixpkgs` for `x86_64-linux`.
      '';
    };

    defaultUser = mkOption {
      type = types.str;
      default = "nixos";
      description = "Login user of the distro (`wsl.defaultUser`). Your modules must create it if it is not `nixos`.";
    };

    distro = mkOption {
      type = types.str;
      default = "NixOS";
      description = "Name of the WSL distribution (`wsl -d <name>`). Informational for now.";
    };
  };

  config = lib.mkIf cfg.enable {
    # A WSL 2 distro runs on the Virtual Machine Platform feature, so declaring
    # the distro declares the feature -- as `virtualisation.docker.enable`
    # brings in what Docker needs -- at mkDefault, so a host can say otherwise.
    # Not the `Microsoft-Windows-Subsystem-Linux` feature: the Store build of
    # WSL that Windows 11 runs does not need it (a machine with it disabled and
    # a working distro is what this was written on). Not Hyper-V: WSL uses the
    # platform layer, not the hypervisor role, and Hyper-V is the consumer's
    # to want. On a machine install.ps1 set up the feature is already on, so
    # this is a noop there and never owned; on one where it is off, the apply
    # reports the restart it needs.
    windows.features.VirtualMachinePlatform = lib.mkDefault true;

    # The evaluated NixOS configuration, not just its toplevel, so a consumer can
    # expose it as a nixosConfiguration of its own for nixos-rebuild and docs.
    system.build.wsl = cfg.nixpkgs.lib.nixosSystem {
      inherit (cfg) specialArgs;
      modules = [
        winpkgsInputs.nixos-wsl.nixosModules.default
        # The slim base: only what winpkgs needs from the distro. Everything
        # else is the consumer's business, via wsl.modules.
        (
          { lib, pkgs, ... }:
          {
            wsl.enable = true;
            wsl.defaultUser = lib.mkDefault cfg.defaultUser;
            networking.hostName = lib.mkDefault config.winpkgs.name;

            # activate execs pwsh.exe from inside the distro. Let NixOS own the
            # binfmt_misc registration for Windows executables; relying on WSL's
            # init to do it is what leaves "MZ: command not found" behind after a
            # systemd-binfmt restart or a cold VM start.
            wsl.interop.register = true;

            # Evaluate flakes, and fetch a git-hosted configuration to evaluate.
            nix.settings.experimental-features = [
              "nix-command"
              "flakes"
            ];
            environment.systemPackages = [ pkgs.git ];
          }
        )
      ]
      ++ lib.optional (cfg.pkgs != null) { nixpkgs.pkgs = cfg.pkgs; }
      ++ lib.optional (cfg.pkgs == null) { nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux"; }
      ++ cfg.modules;
    };
  };
}
