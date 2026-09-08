# The system installs, on behalf of its homes, what they cannot install
# themselves. A home configuration never elevates, and some winget packages
# (Alacritty, LLVM -- most MSI and NSIS installers) only have a machine-wide
# installer. Such a package stays declared where it is wanted, in the home's
# `home.packages`; the overlay knows its scope; the home exports it as
# `winpkgs.machinePackages`; and the system configuration that lists the home
# here installs it, elevated. home-manager.useUserPackages is the NixOS
# precedent: the user's packages, installed by the system activation.
{
  lib,
  config,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.winpkgs;
  isHome = h: (h.config.winpkgs.kind or null) == "home";
in
{
  options.winpkgs.homes = mkOption {
    type = types.listOf types.raw;
    default = [ ];
    example = lib.literalExpression ''[ self.windowsHomeConfigurations."me@desktop" ]'';
    description = ''
      The home configurations of this machine's users, as evaluated by
      `winpkgs.lib.homeConfiguration`. Each one's `winpkgs.machinePackages` --
      packages it declared in `home.packages` whose winget installer is
      machine-wide -- is installed by this system configuration, with machine
      scope. Apply the system before the home (`winpkgs system switch`, then
      `winpkgs home switch`), so the package is there when the home's
      configuration for it lands.
    '';
  };

  config = {
    assertions = [
      {
        assertion = lib.all isHome cfg.homes;
        message = "winpkgs.homes: every entry must be an evaluated home configuration (winpkgs.lib.homeConfiguration)";
      }
    ];

    winpkgs.packages.winget = lib.concatMap (
      h: map (p: p // { scope = "machine"; }) h.config.winpkgs.machinePackages
    ) (lib.filter isHome cfg.homes);
  };
}
