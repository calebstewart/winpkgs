# `nix run .#suggest-winget -- ripgrep fd`: winget ids for nixpkgs attributes,
# ranked from the pinned winget-pkgs, with the overlays/winget.nix entry to
# paste. The pins it reads are the flake's own: its nixpkgs for what an
# attribute is, its winget-pkgs for what winget has -- so a consumer that
# `follows` its own winget-pkgs into winpkgs gets suggestions from that pin.
{
  pkgs,
  self,
  nixpkgs,
  winget-pkgs,
}:
pkgs.writeShellApplication {
  name = "suggest-winget";
  # nix-instantiate is the caller's own, on their PATH: whoever runs this
  # through `nix run` has one, of the version their store expects.
  runtimeInputs = [ pkgs.python3 ];
  text = ''
    export WINPKGS_WINGET_PKGS=${winget-pkgs}
    export WINPKGS_NIXPKGS=${nixpkgs}
    export WINPKGS_SRC=${self}
    exec python3 ${./.}/suggest-winget.py "$@"
  '';
  meta = {
    description = "Suggest overlays/winget.nix entries for nixpkgs attributes";
    mainProgram = "suggest-winget";
  };
}
