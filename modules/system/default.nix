# The system configuration: machine-wide state, applied elevated by
# construction. `HKLM`, `%ProgramData%`, machine-scope winget, the WSL distro.
# The NixOS-shaped options live here.
{
  imports = [
    ../common
    ./wsl.nix
    ./developer.nix
    ./nixos.nix
    ./homes.nix
  ];
}
