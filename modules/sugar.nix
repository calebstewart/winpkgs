# Helpers shared by the modules that wrap `winpkgs.registry`. A plain function
# library, imported directly rather than plumbed through `_module.args`: it
# belongs to the files that use it, not to the option tree.
#
# Every option built here is tri-state and defaults to `null`. A NixOS module
# can own a config file outright; a Windows registry arrives carrying years of
# settings someone chose by hand, so "no opinion" has to mean "write nothing"
# rather than "write the upstream default".
#
# There is no sugar for *deleting* a value -- `null` is spoken for. Deletion
# stays a raw `winpkgs.registry.<key>.<name> = null`.
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
      mkOption {
        type = types.nullOr s.type;
        default = null;
        description = s.description + ''

          `null` leaves whatever the machine already has.
        '';
      }
    ) settings;

  # mkDefault goes on the *leaf*. A `winpkgs.registry` entry written by hand has
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

  # Every key a table touches, for `winpkgs.explorer.restartKeys`.
  keys = settings: lib.unique (lib.concatMap (s: s.keys or [ s.key ]) (lib.attrValues settings));
}
