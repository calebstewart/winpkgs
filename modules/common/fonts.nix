# Fonts, installed from Nix packages. A font package is data -- fetched,
# unpacked, copied to share/fonts -- so it builds on the Windows cross set as
# readily as anywhere, and its files can travel in the closure the way
# windows.files do. On the machine a font is a file in a fonts directory plus
# a registry value naming it (per user under %LOCALAPPDATA%\Microsoft\Windows\
# Fonts and HKCU, machine-wide under %WINDIR%\Fonts and HKLM); the runtime's
# winpkgs/font resource does both, one resource per package.
#
# This is the primitive both trees feed and not the user-facing name: a system
# configuration says `fonts.packages` (NixOS's option, modules/system/nixos.nix)
# and a home configuration lists font packages in `home.packages`, as
# home-manager does (modules/home/home-manager.nix; the overlay's `isFont` mark
# is how they are told apart from programs).
{
  lib,
  config,
  winpkgsKind,
  ...
}:
let
  inherit (lib) mkOption types;
  sugar = import ./sugar.nix { inherit lib; };
  scope = sugar.scopeOfKind winpkgsKind;

  # The resource id, stable across versions of the same font so an upgrade is
  # an update of the one resource rather than a remove and a create.
  nameOf = p: p.pname or p.name;
  # The same font listed twice (two modules want it) is one resource. Keyed by
  # name rather than compared: comparing derivations forces their store paths.
  byName = lib.listToAttrs (map (p: lib.nameValuePair (nameOf p) p) config.winpkgs.fonts);

  entries = lib.mapAttrsToList (name: package: {
    inherit name package;
    closureName = lib.strings.sanitizeDerivationName name;
  }) byName;
in
{
  options.winpkgs.fonts = mkOption {
    type = types.listOf types.package;
    default = [ ];
    internal = true;
    visible = false;
    description = ''
      Font packages to install -- for every user in a system configuration,
      for this user in a home configuration. Each package's font files
      (`share/fonts/**/*.ttf`, `.otf`, `.ttc`) are copied into the closure and
      installed on the machine.
    '';
  };

  config = {
    # Consumed by build.nix to populate $out/fonts.
    system.build.fontEntries = entries;

    winpkgs.resources = map (e: {
      type = "winpkgs/font";
      id = e.name;
      inherit scope;
      properties = {
        inherit (e) name;
        source = "fonts/${e.closureName}";
        inherit scope;
      };
    }) entries;
  };
}
