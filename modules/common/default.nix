# Everything both kinds of configuration share. The kind itself arrives as the
# `winpkgsKind` special argument and fixes the scope of every resource: machine
# for a system configuration, user for a home configuration.
{ lib, winpkgsInputs, ... }:
let
  # Before the option surface was sorted by what it is about, everything lived
  # under `winpkgs.*`. Now `winpkgs.*` is the tool (name, generations, prune,
  # cli, homes), `windows.*` is the OS being configured (explorer, taskbar,
  # theme, privacy, keyboard, developer, and the registry and files beneath
  # them), `winget.*` the installer and `wsl.*` the distro -- the nix-darwin
  # shape, where `system.defaults.*` is macOS and `homebrew.*` is Homebrew. The
  # old names still work, with a warning naming the new one. Options only one
  # kind declares are renamed in that kind's tree (modules/system, modules/home).
  renamed = [
    (lib.mkRenamedOptionModule [ "winpkgs" "registry" ] [ "windows" "registry" ])
    (lib.mkRenamedOptionModule [ "winpkgs" "registryKeys" ] [ "windows" "registryKeys" ])
    (lib.mkRenamedOptionModule [ "winpkgs" "explorer" ] [ "windows" "explorer" ])
    (lib.mkRenamedOptionModule [ "winpkgs" "privacy" ] [ "windows" "privacy" ])
    (lib.mkRenamedOptionModule [ "winpkgs" "keyboard" ] [ "windows" "keyboard" ])
    (lib.mkRenamedOptionModule [ "winpkgs" "files" ] [ "windows" "files" ])
    (lib.mkRenamedOptionModule [ "winpkgs" "packages" "winget" ] [ "winget" "packages" ])
  ];
in
{
  imports = renamed ++ [
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
    ./fonts.nix
    ./environment.nix
    # Sugar whose settings span both scopes; each kind sees only its own half.
    ./privacy.nix
    ./keyboard.nix
    ./build.nix
  ];
}
