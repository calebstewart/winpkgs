# The home configuration: one user's state, applied as that user, never
# elevated. `HKCU`, `%USERPROFILE%`, user-scope winget, the shell. home-manager's
# modules are evaluated alongside these (lib/default.nix adds them), and
# home-manager.nix here is what turns their output into Windows resources. The
# `winpkgs` command itself lives here too -- it is a per-user install, like
# home-manager's own.
{
  imports = [
    ../common
    ./home-manager.nix
    ./cli.nix
    ./powershell.nix
    ./explorer.nix
    ./taskbar.nix
    ./theme.nix
  ];
}
