# NixOS's names for the things that mean the same on a Windows system
# configuration. Added where a shared module would use them, not as a table:
# the overlap is thinner than home-manager's, and options with no honest
# Windows meaning (`boot.*`, `users.users`) are left undeclared rather than
# faked.
{
  lib,
  config,
  ...
}:
let
  inherit (lib) mkOption types;
  sugar = import ../common/sugar.nix { inherit lib; };
  cfg = config.environment;
  # A font in systemPackages is a mistake with a better home; the overlay's
  # mark lets the error name it.
  isFont = p: p.isFont or false;
  fontsInSystemPackages = lib.filter isFont cfg.systemPackages;
  translated = sugar.packagesToWinget (lib.filter (p: !isFont p) cfg.systemPackages);
  # The mirror image of a home's machinePackages: an installer that only works
  # per user cannot be installed machine-wide.
  userOnly = lib.filter (p: sugar.wingetScope p == "user") translated.mapped;
in
{
  imports = [
    # environment.variables is the machine-wide environment here, as it is the
    # system environment in NixOS; environment.path is the machine PATH.
    (lib.mkAliasOptionModule [ "environment" "variables" ] [ "winpkgs" "environment" "variables" ])
    (lib.mkAliasOptionModule [ "environment" "path" ] [ "winpkgs" "environment" "path" ])
  ];

  options.networking.hostName = mkOption {
    type = types.nullOr types.str;
    default = null;
    example = "desktop";
    description = ''
      The machine's name, with NixOS's and nix-darwin's option name. It is the
      default for `winpkgs.name`, which labels the closure and is how the
      `winpkgs` command addresses this configuration. Setting the computer's
      actual name is not (yet) something winpkgs does.
    '';
  };

  options.environment.systemPackages = mkOption {
    type = types.listOf types.package;
    default = [ ];
    example = lib.literalExpression "[ pkgs._7zz pkgs.git ]";
    description = ''
      Packages installed for every user, with NixOS's name and type. Installed
      through winget with machine scope, via the same annotations as
      `home.packages` (`pkgs.git.winget.id`, `pkgs.winpkgs.fromWinget`).
    '';
  };

  options.fonts.packages = mkOption {
    type = types.listOf types.package;
    default = [ ];
    example = lib.literalExpression "[ pkgs.nerd-fonts.jetbrains-mono pkgs.inter ]";
    description = ''
      Fonts installed for every user, with NixOS's name and type: each
      package's font files (`share/fonts`) go to `%WINDIR%\Fonts` and are
      registered under `HKLM`. Any package with fonts will do; the overlay's
      `isFont` mark is not needed here. A font one user wants goes in that
      user's `home.packages`, as with home-manager.
    '';
  };

  options.system.stateVersion = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = ''
      Accepted for compatibility with modules shared with NixOS; a Windows
      configuration has no state whose layout depends on it, so it does nothing.
    '';
  };

  config = {
    winpkgs.name = lib.mkIf (config.networking.hostName != null) (
      lib.mkDefault config.networking.hostName
    );

    winget.packages = map (p: {
      id = p.winget.id;
      scope = "machine";
    }) translated.mapped;

    winpkgs.fonts = config.fonts.packages;

    assertions = sugar.packageAssertions "environment.systemPackages" translated ++ [
      {
        assertion = userOnly == [ ];
        message = "environment.systemPackages: these install per user only and belong in a home configuration (home.packages): ${sugar.packageNames userOnly}";
      }
      {
        assertion = fontsInSystemPackages == [ ];
        message = "environment.systemPackages: these are fonts and belong in fonts.packages: ${sugar.packageNames fontsInSystemPackages}";
      }
    ];
  };
}
