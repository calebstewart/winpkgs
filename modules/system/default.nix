# The system configuration: machine-wide state, applied elevated by
# construction. `HKLM`, `%ProgramData%`, machine-scope winget, the WSL distro.
# The NixOS-shaped options live here.
{ lib, ... }:
{
  imports = [
    ../common
    # Old names for the system-only options (see ../common/default.nix).
    (lib.mkRenamedOptionModule [ "winpkgs" "developer" ] [ "windows" "developer" ])
    (lib.mkRenamedOptionModule [ "winpkgs" "wsl" ] [ "wsl" ])
    ./wsl.nix
    ./developer.nix
    ./nixos.nix
    ./power.nix
    ./time.nix
    ./homes.nix
  ];
}
