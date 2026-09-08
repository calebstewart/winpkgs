{
  lib,
  config,
  winpkgsKind,
  ...
}:
let
  inherit (lib) mkOption types;
  sugar = import ./sugar.nix { inherit lib; };
  scope = sugar.scopeOfKind winpkgsKind;
  other = if winpkgsKind == "system" then "home" else "system";
  misplaced = lib.filter (r: r.scope != scope) config.winpkgs.resources;
in
{
  options.winpkgs = {
    kind = mkOption {
      type = types.enum [
        "system"
        "home"
      ];
      default = winpkgsKind;
      readOnly = true;
      description = ''
        Which kind of configuration this is. A `system` configuration is the
        machine -- `HKLM`, `%ProgramData%`, machine-scope packages -- and is
        applied elevated. A `home` configuration is one user -- `HKCU`,
        `%USERPROFILE%`, user-scope packages -- and is applied as that user.
        Fixed by the evaluator (`windowsSystem` or `homeConfiguration`).
      '';
    };

    name = mkOption {
      type = types.str;
      example = "desktop";
      description = ''
        Name of this configuration: the host name for a system configuration,
        `<user>@<host>` for a home configuration. Labels the closure and, for a
        home configuration, tells the `winpkgs` command which system it belongs to.
      '';
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

  # The one rule that replaces every scope heuristic: a configuration holds
  # resources of its own scope and nothing else.
  config.assertions = [
    {
      assertion = misplaced == [ ];
      message = ''
        This is a ${winpkgsKind} configuration, but these resources are ${sugar.scopeOfKind other} scope and belong in the ${other} configuration:
        ${lib.concatMapStrings (r: "  - ${r.type} ${r.id}\n") misplaced}'';
    }
  ];
}
