{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.winpkgs = {
    name = mkOption {
      type = types.str;
      example = "desktop";
      description = "Name of this configuration, typically the host name. Used to label the closure and generations.";
    };

    resources = mkOption {
      type = types.listOf types.attrs;
      default = [ ];
      internal = true;
      description = ''
        The normalised resource list emitted into the document. Modules append
        here; each entry has `type`, `id`, `scope` and `properties`.
      '';
    };
  };

  options.system.build = mkOption {
    type = types.lazyAttrsOf types.raw;
    default = { };
    internal = true;
    description = "Derivations and data produced from this configuration.";
  };

  options.assertions = mkOption {
    type = types.listOf types.unspecified;
    default = [ ];
    internal = true;
    description = "Same shape as NixOS `assertions`: `{ assertion; message; }`.";
  };
}
