{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.winpkgs.environment;
in
{
  options.winpkgs.environment.path = mkOption {
    type = types.listOf types.str;
    default = [ ];
    example = [ ''%LOCALAPPDATA%\Programs\nvim\bin'' ];
    description = ''
      Directories that must be on the user's `PATH` (`HKCU\Environment`). Each is
      appended if missing and otherwise left alone; `%VAR%` references are kept
      unexpanded. Removing an entry here does not remove it from `PATH` (use
      `rollback`, or edit the value by hand).
    '';
  };

  config.winpkgs.resources = map (dir: {
    type = "winpkgs/path";
    id = "Path\\${dir}";
    scope = "user";
    properties = {
      inherit dir;
      key = "HKCU\\Environment";
      name = "Path";
    };
  }) cfg.path;
}
