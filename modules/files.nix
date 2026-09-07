{
  lib,
  config,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.winpkgs.files;

  userMarkers = [
    "%APPDATA%"
    "%LOCALAPPDATA%"
    "%USERPROFILE%"
    "%HOMEPATH%"
    "%TEMP%"
    "%TMP%"
  ];
  defaultScope =
    target:
    let
      t = lib.toUpper target;
    in
    if lib.any (m: lib.hasInfix m t) userMarkers || lib.hasPrefix "~" target then "user" else "machine";

  fileEntry = types.submodule (
    { name, config, ... }:
    {
      options = {
        target = mkOption {
          type = types.str;
          default = name;
          description = ''
            Destination path on the Windows machine. `%VAR%` environment
            references are expanded at apply time. Defaults to the attribute name.
          '';
        };
        text = mkOption {
          type = types.nullOr types.lines;
          default = null;
          description = "File contents. Mutually exclusive with `source`.";
        };
        source = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "A file or directory to copy. Mutually exclusive with `text`.";
        };
        scope = mkOption {
          type = types.enum [
            "user"
            "machine"
          ];
          default = defaultScope config.target;
          defaultText = lib.literalMD "`user` if the target contains a per-user environment variable, else `machine`";
          description = "Which phase writes this file.";
        };
      };
    }
  );

  entries = lib.imap0 (
    i: name:
    let
      f = cfg.${name};
      closureName = "${toString i}-${lib.strings.sanitizeDerivationName (baseNameOf f.target)}";
    in
    {
      inherit closureName;
      inherit (f) target scope;
      src = if f.text != null then pkgs.writeText closureName f.text else f.source;
    }
  ) (lib.attrNames cfg);
in
{
  options.winpkgs.files = mkOption {
    type = types.attrsOf fileEntry;
    default = { };
    example = lib.literalExpression ''
      {
        "%APPDATA%/wezterm/wezterm.lua".text = '''
          return { font = wezterm.font("JetBrains Mono") }
        ''';
        "%USERPROFILE%/.gitconfig".source = ../shared/gitconfig;
      }
    '';
    description = ''
      Files to place on the machine, keyed by destination path. Contents are
      copied (not linked) and compared by hash, so unchanged files are left alone.

      Forward slashes are fine in paths (Win32 accepts them), which avoids
      doubling backslashes in the attribute name.
    '';
  };

  config = {
    assertions = lib.mapAttrsToList (name: f: {
      assertion = (f.text != null) != (f.source != null);
      message = "winpkgs.files.\"${name}\": exactly one of `text` or `source` must be set";
    }) cfg;

    # Consumed by build.nix to populate $out/files.
    system.build.fileEntries = entries;

    winpkgs.resources = map (e: {
      type = "winpkgs/file";
      id = e.target;
      scope = e.scope;
      properties = {
        inherit (e) target;
        source = "files/${e.closureName}";
      };
    }) entries;
  };
}
