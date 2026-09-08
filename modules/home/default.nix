# The home configuration: one user's state, applied as that user, never
# elevated. `HKCU`, `%USERPROFILE%`, user-scope winget, the shell. The
# home-manager-shaped options live here, and so does the `winpkgs` command
# itself -- it is a per-user install, like home-manager's own.
{
  imports = [
    ../common
    ./home.nix
    ./xdg.nix
    ./cli.nix
    ./powershell.nix
    ./explorer.nix
    ./taskbar.nix
    ./theme.nix
  ];
}
