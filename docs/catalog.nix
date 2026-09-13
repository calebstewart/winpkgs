# Package catalog extraction.
#
# winpkgs builds no packages: `home.packages = [ pkgs.git ]` is read for the
# overlay's annotation and installed the way the annotation says. So what a
# package *is* to this flake is a row in one of three tables -- winget ids
# (overlays/winget.nix), fonts installed from their files (overlays/fonts.nix)
# and programs unpacked from a release archive (overlays/portable.nix) -- and
# the Packages page is those tables, with nixpkgs' own description beside each
# name to say what the program is.
#
# The tables are read as files rather than through the overlay, so the page
# says what the source says and needs no cross package set to do it. nixpkgs'
# meta comes from the package set the documentation is built with; a
# description is the same on every platform.
{ lib }:
{
  /**
    Read the overlay's tables into catalog entries.

    # Inputs

    `pkgs`
    : The package set the documentation is built with, read for `meta` only.

    `src`
    : The flake's source, normally `self.outPath`.

    # Type

    ```
    mkCatalog :: AttrSet -> AttrSet
    ```
  */
  mkCatalog =
    { pkgs, src }:
    let
      mappings = import "${src}/overlays/winget.nix";
      fontNames = import "${src}/overlays/fonts.nix";
      portables = import "${src}/overlays/portable.nix";

      try =
        default: value:
        let
          attempt = builtins.tryEval value;
        in
        if attempt.success then attempt.value else default;

      # A package's meta, or nothing: a name the build platform's nixpkgs lacks
      # (the `packages` check pins the pinned nixpkgs to the table, so this is
      # only a consumer's) documents its table entry and no more.
      metaOf =
        attr:
        let
          pkg = pkgs.${attr} or null;
        in
        if pkg == null then { } else try { } (pkg.meta or { });

      homepageOf =
        meta:
        let
          h = meta.homepage or null;
        in
        if lib.isList h then (lib.head h) else h;

      describe = meta: {
        description = try null (meta.description or null);
        homepage = try null (homepageOf meta);
      };

      wingetEntry =
        attr: entry:
        let
          meta = metaOf attr;
          isAttrs = builtins.isAttrs entry;
        in
        {
          inherit attr;
          kind = "winget";
          available = entry != null;
          id =
            if entry == null then
              null
            else if isAttrs then
              entry.id
            else
              entry;
          scope = if isAttrs then entry.scope or null else null;
          programDir = if isAttrs then entry.programDir or null else null;
          # The program getExe names: the entry's, else nixpkgs'.
          mainProgram =
            if isAttrs && entry ? mainProgram then entry.mainProgram else try null (meta.mainProgram or null);
        }
        // describe meta;

      fontEntry =
        attr:
        {
          inherit attr;
          kind = "font";
        }
        // describe (metaOf attr);

      portableEntry = name: p: {
        attr = name;
        kind = "portable";
        version = p.version or null;
        programDir = ''%LOCALAPPDATA%\Programs\${name}'';
        mainProgram = p.mainProgram or name;
        description = p.description or null;
        homepage = p.homepage or null;
      };

      nerdFonts = try [ ] (
        lib.filter (n: lib.isDerivation (pkgs.nerd-fonts.${n} or null)) (
          lib.attrNames (pkgs.nerd-fonts or { })
        )
      );
    in
    {
      entries =
        lib.mapAttrsToList wingetEntry mappings
        ++ map fontEntry fontNames
        ++ lib.mapAttrsToList portableEntry portables;

      # Every member of nerd-fonts is marked in the overlay; one row for the
      # set rather than one per face.
      fontSets = lib.optional (nerdFonts != [ ]) {
        attr = "nerd-fonts";
        count = lib.length nerdFonts;
        description = "Every Nerd Font face nixpkgs packages, each patched with icons and glyphs -- `pkgs.nerd-fonts.jetbrains-mono`, `pkgs.nerd-fonts.fira-code` and the rest.";
      };
    };
}
