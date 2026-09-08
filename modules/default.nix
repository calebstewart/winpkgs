{
  imports = [
    # Primitives: each turns its options into `winpkgs.resources`.
    ./system.nix
    ./registry.nix
    ./packages.nix
    ./powershell.nix
    ./files.nix
    ./environment.nix
    ./wsl.nix
    ./cli.nix
    # Sugar: each turns its options into the primitives above, so that value
    # typing, scope and deduplication stay in exactly one place.
    ./explorer.nix
    ./taskbar.nix
    ./build.nix
  ];
}
