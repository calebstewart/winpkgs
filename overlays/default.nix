# The winpkgs overlay, applied to the Windows cross package set that modules
# see as `pkgs`. It does two things:
#
#  - annotates nixpkgs packages with `winget = { id = ...; }` (or `null` for
#    "no Windows build") so that `home.packages = [ pkgs.git ]` can be turned
#    into a winget install; the derivations themselves are never built;
#  - provides `pkgs.winpkgs.fromWinget "Publisher.Id"` for software that is on
#    winget but not in nixpkgs, as a stub derivation carrying the same
#    annotation.
final: prev:
let
  inherit (prev) lib;
  mappings = import ./winget.nix;

  annotate =
    _name: id: pkg:
    pkg // { winget = if id == null then null else { inherit id; }; };

  # Only names this nixpkgs actually has; the `packages` check pins the pinned
  # nixpkgs to the full table, a consumer's nixpkgs may differ.
  present = lib.filterAttrs (name: _: prev ? ${name}) mappings;
in
lib.mapAttrs (name: id: annotate name id prev.${name}) present
// {
  winpkgs = (prev.winpkgs or { }) // {
    wingetMappings = mappings;

    fromWinget =
      id:
      final.buildPackages.runCommandLocal "winget-${lib.strings.sanitizeDerivationName id}"
        {
          passthru.winget = {
            inherit id;
          };
        }
        ''
          mkdir -p $out
        '';
  };
}
