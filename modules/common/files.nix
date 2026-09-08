{
  lib,
  config,
  pkgs,
  winpkgsKind,
  ...
}:
let
  inherit (lib) mkOption types;
  sugar = import ./sugar.nix { inherit lib; };
  cfg = config.winpkgs.files;
  scope = sugar.scopeOfKind winpkgsKind;

  # Not how scope is decided any more -- the kind of configuration is -- but a
  # path that plainly belongs to the other scope is still worth an error.
  userMarkers = [
    "%APPDATA%"
    "%LOCALAPPDATA%"
    "%USERPROFILE%"
    "%HOMEPATH%"
    "%TEMP%"
    "%TMP%"
  ];
  machineMarkers = [
    "%PROGRAMDATA%"
    "%ALLUSERSPROFILE%"
    "%PROGRAMFILES%"
    "%PROGRAMFILES(X86)%"
    "%SYSTEMROOT%"
    "%WINDIR%"
  ];
  looksUser = t: lib.any (m: lib.hasInfix m (lib.toUpper t)) userMarkers || lib.hasPrefix "~" t;
  looksMachine = t: lib.any (m: lib.hasInfix m (lib.toUpper t)) machineMarkers;
  misplaced = t: if winpkgsKind == "system" then looksUser t else looksMachine t;

  fileEntry = types.submodule (
    { name, ... }:
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
            src = file;
          }
        ) (lib.filesystem.listFilesRecursive f.source)
      else
        [
          {
            closureName = "${toString i}-${sanitize (lastComponent f.target)}";
            inherit (f) target;
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
      doubling backslashes in the attribute name. In a home configuration,
      `home.file` and `xdg.configFile` are the same thing with home-manager's
      names. Written by the phase this configuration is applied in: as the user
      for a home configuration, elevated for a system one.
    '';
  };

  config = {
    assertions =
      lib.mapAttrsToList (name: f: {
        assertion = !f.enable || ((f.text != null) != (f.source != null));
        message = "winpkgs.files.\"${name}\": exactly one of `text` or `source` must be set";
      }) cfg
      ++ lib.mapAttrsToList (name: f: {
        assertion = !f.enable || !(misplaced f.target);
        message = "winpkgs.files.\"${name}\": this path is ${
          sugar.scopeOfKind (if winpkgsKind == "system" then "home" else "system")
        } scope and belongs in the ${if winpkgsKind == "system" then "home" else "system"} configuration";
      }) cfg;

    # Consumed by build.nix to populate $out/files.
    system.build.fileEntries = entries;

    winpkgs.resources = map (e: {
      type = "winpkgs/file";
      id = e.target;
      inherit scope;
      properties = {
        inherit (e) target;
        source = "files/${e.closureName}";
      };
    }) entries;
  };
}
