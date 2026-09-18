# The system installs, on behalf of its homes, what they cannot install
# themselves. A home configuration never elevates, and some winget packages
# (Alacritty, LLVM -- most MSI and NSIS installers) only have a machine-wide
# installer. Such a package stays declared where it is wanted, in the home's
# `home.packages`; the overlay knows its scope; the home exports it as
# `winpkgs.machinePackages`; and the system configuration that lists the home
# here installs it, elevated. home-manager.useUserPackages is the NixOS
# precedent: the user's packages, installed by the system activation.
#
# Group membership travels the same way. A home says which local groups its
# user wants (`winpkgs.groups`, modules/home/groups.nix) and this folds each
# into `windows.localGroups.<group>.members` with the home's own user, so the
# account is named once, where the home already names it, rather than a second
# time in the system tree where it would go stale as users are renamed or
# added.
{
  lib,
  config,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.winpkgs;
  isHome = h: (h.config.winpkgs.kind or null) == "home";
  homes = lib.filter isHome cfg.homes;

  # "<user>@<host>" -> "<user>", divided at the last `@` because a Windows
  # user name may contain one -- the same reading `lib/installer.nix`'s
  # splitHomeName gives the same name for the account Setup creates, not a
  # second source of truth. Lenient where that one throws: a name this cannot
  # read becomes the assertion below, which names the home, rather than an
  # evaluation error in a configuration that may want nothing of the sort.
  userOf =
    name:
    let
      parts = lib.splitString "@" name;
      user = lib.concatStringsSep "@" (lib.init parts);
    in
    if lib.length parts > 1 && user != "" then user else null;

  groupsOf = h: h.config.winpkgs.groups or [ ];
  # Only a home that asks for a group needs a user: one that does not is
  # nobody's business to name.
  unnamed = lib.filter (h: groupsOf h != [ ] && userOf h.config.winpkgs.name == null) homes;
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
      scope, and each one's `winpkgs.groups` becomes a membership of that
      group for the home's own user. Apply the system before the home
      (`winpkgs system switch`, then `winpkgs home switch`), so the package is
      there when the home's configuration for it lands.
    '';
  };

  config = {
    assertions = [
      {
        assertion = lib.all isHome cfg.homes;
        message = "winpkgs.homes: every entry must be an evaluated home configuration (winpkgs.lib.homeConfiguration)";
      }
      {
        assertion = unnamed == [ ];
        message = ''
          winpkgs.homes: a home configuration is named <user>@<host>, and these ask for group membership (winpkgs.groups) under a name with no user in it, so there is nobody to add:
          ${lib.concatMapStrings (h: "  - ${h.config.winpkgs.name}\n") unnamed}'';
      }
    ];

    winget.packages = lib.concatMap (
      h: map (p: p // { scope = "machine"; }) h.config.winpkgs.machinePackages
    ) homes;

    # One definition per home per group; the module system merges them, and
    # windows.localGroups folds a member the system also names directly.
    windows.localGroups = lib.mkMerge (
      lib.concatMap (
        h:
        let
          user = userOf h.config.winpkgs.name;
        in
        lib.optionals (user != null) (map (group: { ${group}.members = [ user ]; }) (groupsOf h))
      ) homes
    );
  };
}
