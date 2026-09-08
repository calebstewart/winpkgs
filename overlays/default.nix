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

  # A table entry or a fromWinget argument: an id, or { id; scope; }. The
  # annotation always has both fields; scope null means either scope works.
  normalise =
    entry:
    if entry == null then
      null
    else if builtins.isString entry then
      {
        id = entry;
        scope = null;
      }
    else
      { scope = null; } // entry;

  annotate =
    _name: entry: pkg:
    pkg // { winget = normalise entry; };

  # Only names this nixpkgs actually has; the `packages` check pins the pinned
  # nixpkgs to the full table, a consumer's nixpkgs may differ.
  present = lib.filterAttrs (name: _: prev ? ${name}) mappings;
in
lib.mapAttrs (name: entry: annotate name entry prev.${name}) present
// {
  winpkgs = (prev.winpkgs or { }) // {
    wingetMappings = mappings;

    # fromWinget "Publisher.Id", or fromWinget { id; scope = "machine"; } for a
    # package whose installer is machine-wide.
    fromWinget =
      spec:
      let
        winget = normalise spec;
      in
      final.buildPackages.runCommandLocal "winget-${lib.strings.sanitizeDerivationName winget.id}"
        {
          passthru = {
            inherit winget;
          };
        }
        ''
          mkdir -p $out
        '';
  };
}
