{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.winpkgs.registry;

  # A value may be written plainly (int -> DWord, string -> String, list ->
  # MultiString), as null to delete it, or explicitly as { type; value; }.
  explicitValue = types.submodule {
    options = {
      type = mkOption {
        type = types.enum [
          "DWord"
          "QWord"
          "String"
          "ExpandString"
          "MultiString"
          "Binary"
        ];
        description = "Registry value kind.";
      };
      value = mkOption {
        type = types.oneOf [
          types.int
          types.str
          (types.listOf types.str)
          (types.listOf types.int)
        ];
        description = "The value. `Binary` takes a list of byte integers.";
      };
    };
  };

  # A MultiString is one value, not an accumulator. `listOf` merges by
  # concatenating, so two modules that disagreed about the same value would
  # silently produce the union of both instead of an error.
  multiString = lib.mkOptionType {
    name = "multiString";
    description = "list of strings";
    check = v: builtins.isList v && lib.all builtins.isString v;
    merge = lib.mergeEqualOption;
  };

  valueType = types.nullOr (
    types.oneOf [
      types.int
      types.str
      multiString
      explicitValue
    ]
  );

  normalise =
    v:
    if v == null then
      {
        type = "Absent";
        value = null;
      }
    else if builtins.isInt v then
      {
        type = "DWord";
        value = v;
      }
    else if builtins.isString v then
      {
        type = "String";
        value = v;
      }
    else if builtins.isList v then
      {
        type = "MultiString";
        value = v;
      }
    else
      { inherit (v) type value; };

  scopeOfKey =
    key:
    let
      k = lib.toUpper key;
    in
    if lib.hasPrefix "HKCU" k || lib.hasPrefix "HKEY_CURRENT_USER" k then "user" else "machine";

  # Explorer reads most of its settings once; a restart makes them take effect.
  # Not everything that needs one lives under an `Explorer` key -- themes and
  # DWM do not -- so the list is an option modules extend, not a constant.
  restartKeys = map lib.toUpper config.winpkgs.explorer.restartKeys;
  touchesExplorer =
    key:
    let
      k = lib.toUpper key;
    in
    config.winpkgs.explorer.restartOnChange && lib.any (p: lib.hasInfix p k) restartKeys;

  # The registry API calls a key's unnamed default value "", which is what the
  # runtime needs; "(default)" is what someone reading a plan expects to see.
  displayName = name: if name == "" then "(default)" else name;
in
{
  options.winpkgs.registry = mkOption {
    type = types.attrsOf (types.attrsOf valueType);
    default = { };
    example = lib.literalExpression ''
      {
        "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced" = {
          Hidden = 1;          # DWord
          HideFileExt = 0;
          LaunchTo = null;     # delete the value if present
        };
        "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize" = {
          AppsUseLightTheme = 0;
          SystemUsesLightTheme = 0;
        };
        "HKCU\\Environment" = {
          EDITOR = { type = "ExpandString"; value = '''%LOCALAPPDATA%\Programs\nvim\bin\nvim.exe'''; };
        };
      }
    '';
    description = ''
      Registry values to enforce, keyed by full key path then value name.

      Keys are attribute names, so they must be double-quoted with backslashes
      doubled: `"HKCU\\Software\\..."`. (Nix does not allow indented strings as
      attribute names, and forward slashes are not substituted because real keys
      such as `...\Content Type\application/json` contain them.) Values may use
      indented strings freely. A key's unnamed default value is written under
      the attribute name `""`; it shows up in plans as `(default)`.

      `HKCU`/`HKEY_CURRENT_USER` keys are user scope; everything else is machine
      scope and needs elevation.

      Plain values are typed by shape: integers become `DWord`, strings become
      `String`, lists of strings become `MultiString`. Use `{ type; value; }`
      for `QWord`, `ExpandString` or `Binary`. `null` deletes the value.

      The higher-level modules (`winpkgs.explorer`, `winpkgs.theme`, ...) write
      here at `mkDefault`, so an entry written by hand always wins -- this is
      the escape hatch for anything they model wrongly. Two hand-written
      definitions of one value that disagree are an evaluation error.

      Priority applies per *value*, not per key: write
      `winpkgs.registry.''${key}.Name = lib.mkDefault 1`, never
      `winpkgs.registry.''${key} = lib.mkDefault { ... }`. The latter is dropped
      whole, siblings included, as soon as anything else defines the same key.
    '';
  };

  options.winpkgs.registryKeys = mkOption {
    type = types.attrsOf types.bool;
    default = { };
    example = lib.literalExpression ''
      { "HKCU\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}" = false; }
    '';
    description = ''
      Whether a key itself exists, irrespective of the values in it. Writing a
      value creates its key, so this is only needed to say that a key must be
      *absent* -- switching off a feature that a key's mere presence enables.

      `false` deletes the key and everything under it. Rollback restores it from
      a `reg.exe export` taken beforehand, which merges rather than replaces:
      values added since the backup survive it.
    '';
  };

  options.winpkgs.explorer.restartOnChange = mkOption {
    type = types.bool;
    default = true;
    description = ''
      Restart `explorer.exe` once at the end of an apply if anything under a key
      in `winpkgs.explorer.restartKeys` changed. Most shell settings do not take
      effect otherwise.
    '';
  };

  options.winpkgs.explorer.restartKeys = mkOption {
    type = types.listOf types.str;
    default = [ ''\Explorer'' ];
    internal = true;
    description = ''
      Key-path fragments, matched case-insensitively as substrings. A change to
      anything under a matching key restarts Explorer. Modules that write shell
      settings outside an `Explorer` key -- themes, DWM, `Control Panel` --
      append their own keys here.
    '';
  };

  config.winpkgs.resources =
    lib.concatLists (
      lib.mapAttrsToList (
        key: values:
        lib.mapAttrsToList (name: v: {
          type = "winpkgs/registry";
          id = "${key}\\${displayName name}";
          scope = scopeOfKey key;
          properties = {
            inherit key name;
            restartExplorer = touchesExplorer key;
          }
          // normalise v;
        }) values
      ) cfg
    )
    ++ lib.mapAttrsToList (key: present: {
      type = "winpkgs/registryKey";
      id = "Key ${key}";
      scope = scopeOfKey key;
      properties = {
        inherit key present;
        restartExplorer = touchesExplorer key;
      };
    }) config.winpkgs.registryKeys;
}
