{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.winpkgs.environment;
  environmentKey = "HKCU\\Environment";
in
{
  options.winpkgs.environment = {
    path = mkOption {
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

    variables = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        EDITOR = ''%LOCALAPPDATA%\Programs\nvim\bin\nvim.exe'';
      };
      description = ''
        User environment variables (`HKCU\Environment`), set exactly. A value
        containing `%VAR%` is stored expandable. New processes see a change at
        once; running ones do not. `PATH` is refused here -- use
        `winpkgs.environment.path`, which appends instead of replacing.
        `home.sessionVariables` is the same option under home-manager's name.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = !(lib.any (n: lib.toLower n == "path") (lib.attrNames cfg.variables));
        message = "winpkgs.environment.variables: set PATH entries with winpkgs.environment.path, which appends rather than replaces";
      }
    ];

    winpkgs.resources =
      map (dir: {
        type = "winpkgs/path";
        id = "Path\\${dir}";
        scope = "user";
        properties = {
          inherit dir;
          key = environmentKey;
          name = "Path";
        };
      }) cfg.path
      ++ lib.mapAttrsToList (name: value: {
        type = "winpkgs/environment";
        id = "Environment\\${name}";
        scope = "user";
        properties = {
          inherit name value;
          key = environmentKey;
        };
      }) cfg.variables;
  };
}
