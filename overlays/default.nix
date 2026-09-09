# The winpkgs overlay, applied to the Windows cross package set that modules
# see as `pkgs`. It does three things:
#
#  - annotates nixpkgs packages with `winget = { id = ...; }` (or `null` for
#    "no Windows build") so that `home.packages = [ pkgs.git ]` can be turned
#    into a winget install; the derivations themselves are never built;
#  - provides `pkgs.winpkgs.fromWinget "Publisher.Id"` for software that is on
#    winget but not in nixpkgs, as a stub derivation carrying the same
#    annotation;
#  - marks font packages with `isFont = true` (fonts.nix, and every member of
#    `nerd-fonts`), so that `home.packages = [ pkgs.nerd-fonts.jetbrains-mono ]`
#    installs the font's files rather than looking for an installer. Those
#    derivations *are* built -- they are fetched and copied, nothing more --
#    and their files travel in the closure.
final: prev:
let
  inherit (prev) lib;
  mappings = import ./winget.nix;
  fontNames = import ./fonts.nix;

  markFont = pkg: pkg // { isFont = true; };
  presentFonts = lib.filter (name: prev ? ${name}) fontNames;

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
// lib.genAttrs presentFonts (name: markFont prev.${name})
// lib.optionalAttrs (prev ? nerd-fonts) {
  nerd-fonts = lib.mapAttrs (_: p: if lib.isDerivation p then markFont p else p) prev.nerd-fonts;
}
// {
  winpkgs = (prev.winpkgs or { }) // {
    wingetMappings = mappings;
    fontPackages = fontNames;

    # font pkg: mark a package the table does not know as a font, so a home
    # configuration installs its share/fonts instead of asking for a winget id.
    font = markFont;

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
