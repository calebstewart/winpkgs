# The home configuration: one user's state, applied as that user, never
# elevated. `HKCU`, `%USERPROFILE%`, user-scope winget, the shell. home-manager's
# modules are evaluated alongside these (lib/default.nix adds them), and
# home-manager.nix here is what turns their output into Windows resources. The
# `winpkgs` command itself lives here too -- it is a per-user install, like
# home-manager's own.
{ lib, ... }:
{
  imports = [
    ../common
    # Old names for the home-only OS settings (see ../common/default.nix).
    (lib.mkRenamedOptionModule [ "winpkgs" "taskbar" ] [ "windows" "taskbar" ])
    (lib.mkRenamedOptionModule [ "winpkgs" "theme" ] [ "windows" "theme" ])
    ./home-manager.nix
    ./cli.nix
    ./powershell.nix
    ./powershell-profile.nix
    ./explorer.nix
    ./taskbar.nix
    ./theme.nix
    ./console.nix
    ./pointer.nix
    ./windows-terminal.nix
    ./whkd.nix
    ./komorebi.nix
    ./masir.nix
    ./flow-launcher.nix
  ];
}
