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

  valueType = types.nullOr (
    types.oneOf [
      types.int
      types.str
      (types.listOf types.str)
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
  touchesExplorer = key: lib.hasInfix "\\EXPLORER" (lib.toUpper key);
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
      indented strings freely.

      `HKCU`/`HKEY_CURRENT_USER` keys are user scope; everything else is machine
      scope and needs elevation.

      Plain values are typed by shape: integers become `DWord`, strings become
      `String`, lists of strings become `MultiString`. Use `{ type; value; }`
      for `QWord`, `ExpandString` or `Binary`. `null` deletes the value.
    '';
  };

  options.winpkgs.explorer.restartOnChange = mkOption {
    type = types.bool;
    default = true;
    description = ''
      Restart `explorer.exe` once at the end of an apply if any value under an
      `Explorer` key changed. Most shell settings do not take effect otherwise.
    '';
  };

  config.winpkgs.resources = lib.concatLists (
    lib.mapAttrsToList (
      key: values:
      lib.mapAttrsToList (name: v: {
        type = "winpkgs/registry";
        id = "${key}\\${name}";
        scope = scopeOfKey key;
        properties = {
          inherit key name;
          restartExplorer = config.winpkgs.explorer.restartOnChange && touchesExplorer key;
        }
        // normalise v;
      }) values
    ) cfg
  );
}
