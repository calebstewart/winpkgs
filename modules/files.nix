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
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Whether to manage this file. `false` makes the entry inert: nothing is written and an existing file is left alone.";
        };
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
        recursive = mkOption {
          type = types.bool;
          default = false;
          description = ''
            For a directory `source`: manage each file inside it as its own
            resource and leave files that are not in the source alone -- what
            home-manager's `recursive` means. The default mirrors the directory
            as a whole, which also deletes anything not in the source.
          '';
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

  # Last path component of a Windows or POSIX path; baseNameOf only knows "/".
  lastComponent = p: lib.last (lib.splitString "\\" (lib.last (lib.splitString "/" p)));
  sanitize = lib.strings.sanitizeDerivationName;

  isDirectory = p: lib.filesystem.pathType p == "directory";

  # One closure entry per file to copy. A recursive directory source expands to
  # one entry -- and so one resource -- per file inside it.
  entries = lib.concatLists (
    lib.imap0 (
      i: name:
      let
        f = cfg.${name};
      in
      if !f.enable then
        [ ]
      else if f.source != null && f.recursive && isDirectory f.source then
        lib.imap0 (
          j: file:
          let
            rel = lib.removePrefix (toString f.source + "/") (toString file);
          in
          {
            closureName = "${toString i}-${toString j}-${sanitize (lastComponent rel)}";
            target = "${f.target}/${rel}";
            inherit (f) scope;
            src = file;
          }
        ) (lib.filesystem.listFilesRecursive f.source)
      else
        [
          {
            closureName = "${toString i}-${sanitize (lastComponent f.target)}";
            inherit (f) target scope;
            src =
              if f.text != null then
                pkgs.buildPackages.writeText (sanitize (lastComponent f.target)) f.text
              else
                f.source;
          }
        ]
    ) (lib.attrNames cfg)
  );
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
        "%LOCALAPPDATA%/nvim" = { source = ./nvim; recursive = true; };
      }
    '';
    description = ''
      Files to place on the machine, keyed by destination path. Contents are
      copied (not linked) and compared by hash, so unchanged files are left alone.

      Forward slashes are fine in paths (Win32 accepts them), which avoids
      doubling backslashes in the attribute name. For files under the home
      directory, `home.file` and `xdg.configFile` are the same thing with
      home-manager's names.
    '';
  };

  config = {
    assertions = lib.mapAttrsToList (name: f: {
      assertion = !f.enable || ((f.text != null) != (f.source != null));
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
