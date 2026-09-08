# The `home.file` / `xdg.*File` entry, with home-manager's option names, so a
# module can set the same attrset on any platform. Options Windows has no use
# for are accepted rather than rejected -- a shared module should not have to
# branch on them -- except `onChange`, which would silently do nothing.
{ lib }:
let
  inherit (lib) mkOption types;
in
types.submodule (
  { name, ... }:
  {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to manage this file.";
      };
      target = mkOption {
        type = types.str;
        default = name;
        description = "Path relative to the directory this attribute set is rooted in. Defaults to the attribute name.";
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
        description = "For a directory `source`: manage each file inside it individually and leave unmanaged siblings alone.";
      };
      executable = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Accepted for compatibility with home-manager. Windows has no executable bit; this does nothing.";
      };
      force = mkOption {
        type = types.bool;
        default = false;
        description = "Accepted for compatibility with home-manager. winpkgs always overwrites an unmanaged file at the target, and journals it so `rollback` can put it back.";
      };
      onChange = mkOption {
        type = types.nullOr types.lines;
        default = null;
        description = "Not supported: winpkgs has no resource that runs a command. Setting this is an evaluation error rather than a silent no-op.";
      };
    };
  }
)
