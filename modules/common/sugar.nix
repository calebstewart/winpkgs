# Helpers shared by the modules that wrap `windows.registry`. A plain function
# library, imported directly rather than plumbed through `_module.args`: it
# belongs to the files that use it, not to the option tree.
#
# Every option built here is tri-state and defaults to `null`. A NixOS module
# can own a config file outright; a Windows registry arrives carrying years of
# settings someone chose by hand, so "no opinion" has to mean "write nothing"
# rather than "write the upstream default".
#
# There is no sugar for *deleting* a value -- `null` is spoken for. Deletion
# stays a raw `windows.registry.<key>.<name> = null`.
{ lib }:
let
  inherit (lib) mkOption types;
in
rec {
  # Encoders. Windows is inconsistent about which way round a boolean runs and
  # which pair of numbers it uses, so every setting spells its own out.
  pair =
    t: f: v:
    if v then t else f;
  on = pair 1 0;
  off = pair 0 1; # for values that name what they hide, like HideFileExt
  choice = table: v: table.${v};

  # A setting table declares the option and the value it writes in one place, so
  # the two cannot drift apart:
  #
  #   showHiddenFiles = {
  #     key = advanced;
  #     name = "Hidden";
  #     type = types.bool;
  #     encode = pair 1 2;          # Explorer spells this one 1/2
  #     description = "Show files and folders marked hidden.";
  #   };
  #
  # A setting that drives more than one value gives `keys` and a `writes`
  # function instead of `key`/`name`/`encode`.
  options =
    settings:
    lib.mapAttrs (
      _: s:
      mkOption (
        {
          type = types.nullOr s.type;
          default = null;
          description = s.description + ''

            `null` leaves whatever the machine already has.
          '';
        }
        // lib.optionalAttrs (s ? example) { inherit (s) example; }
      )
    ) settings;

  # mkDefault goes on the *leaf*. A `windows.registry` entry written by hand has
  # to win, and at the key level the module system would drop the whole attrset
  # -- siblings included -- rather than the one value.
  writes =
    settings: cfg:
    lib.mkMerge (
      lib.mapAttrsToList (
        n: s:
        if cfg.${n} == null then
          { }
        else if s ? writes then
          lib.mapAttrs (_: lib.mapAttrs (_: lib.mkDefault)) (s.writes cfg.${n})
        else
          { ${s.key}.${s.name} = lib.mkDefault ((s.encode or lib.id) cfg.${n}); }
      ) settings
    );

  # Every key a table touches, for `windows.explorer.restartKeys`.
  keys = settings: lib.unique (lib.concatMap (s: s.keys or [ s.key ]) (lib.attrValues settings));

  # Scope, from a registry hive and from a configuration kind.
  scopeOfKey =
    key:
    let
      k = lib.toUpper key;
    in
    if lib.hasPrefix "HKCU" k || lib.hasPrefix "HKEY_CURRENT_USER" k then "user" else "machine";
  scopeOfKind = kind: if kind == "system" then "machine" else "user";

  # A setting table split by kind: a module whose settings span both hives
  # (privacy, keyboard) declares only the half that belongs to the tree it is
  # evaluated in, so the other half is "option does not exist" rather than a
  # misplaced resource.
  forKind =
    kind: settings:
    lib.filterAttrs (
      _: s: lib.all (k: scopeOfKey k == scopeOfKind kind) (s.keys or [ s.key ])
    ) settings;

  # nixpkgs packages -> winget, through the overlay's annotations. Shared by
  # home.packages and environment.systemPackages.
  packagesToWinget = packages: {
    mapped = lib.filter (p: (p ? winget) && p.winget != null) packages;
    unmapped = lib.filter (p: !(p ? winget)) packages;
    unavailable = lib.filter (p: (p ? winget) && p.winget == null) packages;
  };

  # The one scope a mapped package's installer supports, or null for either.
  wingetScope = p: p.winget.scope or null;

  packageNames = ps: lib.concatStringsSep ", " (map (p: p.pname or p.name or "<unnamed package>") ps);

  packageAssertions =
    optionName: translated:
    let
      names = ps: lib.concatStringsSep ", " (map (p: p.pname or p.name or "<unnamed package>") ps);
    in
    [
      {
        assertion = translated.unmapped == [ ];
        message = ''
          ${optionName}: no winget mapping for: ${names translated.unmapped}
          Add the nixpkgs attribute to winpkgs' overlay table (overlays/winget.nix), use
          `pkgs.winpkgs.fromWinget "Publisher.Id"`, or list the id in winget.packages.'';
      }
      {
        assertion = translated.unavailable == [ ];
        message = "${optionName}: no Windows build exists for: ${names translated.unavailable}";
      }
    ];
}
