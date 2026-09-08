# Everything both kinds of configuration share. The kind itself arrives as the
# `winpkgsKind` special argument and fixes the scope of every resource: machine
# for a system configuration, user for a home configuration.
{ lib, winpkgsInputs, ... }:
{
  imports = [
    # `assertions` and `warnings`, as NixOS declares them. home-manager imports
    # this same file; the module system merges the two imports into one.
    "${winpkgsInputs.nixpkgs}/nixos/modules/misc/assertions.nix"
    ./core.nix
    ./state.nix
    # winpkgs.packages.prune predates winpkgs.prune.*.
    (lib.mkAliasOptionModule [ "winpkgs" "packages" "prune" ] [ "winpkgs" "prune" "winget" ])
    ./registry.nix
    ./packages.nix
    ./files.nix
    ./environment.nix
    # Sugar whose settings span both scopes; each kind sees only its own half.
    ./privacy.nix
    ./keyboard.nix
    ./build.nix
  ];
}
