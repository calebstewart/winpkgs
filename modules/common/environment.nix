# Environment variables and PATH -- the user's in a home configuration
# (`HKCU\Environment`), the machine's in a system configuration.
{
  lib,
  config,
  winpkgsKind,
  ...
}:
let
  inherit (lib) mkOption types;
  sugar = import ./sugar.nix { inherit lib; };
  cfg = config.winpkgs.environment;
  scope = sugar.scopeOfKind winpkgsKind;
  environmentKey =
    if winpkgsKind == "system" then
      ''HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment''
    else
      ''HKCU\Environment'';
in
{
  options.winpkgs.environment = {
    path = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ ''%LOCALAPPDATA%\Programs\nvim\bin'' ];
      description = ''
        Directories that must be on `PATH` -- the user's in a home configuration,
        the machine's in a system one. Each is appended if missing and otherwise
        left alone; `%VAR%` references are kept unexpanded. Removing an entry here
        does not remove it from `PATH` (use `rollback`, or edit the value by hand).
      '';
    };

    variables = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        EDITOR = ''%LOCALAPPDATA%\Programs\nvim\bin\nvim.exe'';
      };
      description = ''
        Environment variables, set exactly -- the user's in a home configuration,
        the machine's in a system one. A value containing `%VAR%` is stored
        expandable. New processes see a change at once; running ones do not.
        `PATH` is refused here -- use `winpkgs.environment.path`, which appends
        instead of replacing. `home.sessionVariables` (home) and
        `environment.variables` (system) are the same option under
        home-manager's and NixOS's names.
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
        inherit scope;
        properties = {
          inherit dir;
          key = environmentKey;
          name = "Path";
        };
      }) cfg.path
      ++ lib.mapAttrsToList (name: value: {
        type = "winpkgs/environment";
        id = "Environment\\${name}";
        inherit scope;
        properties = {
          inherit name value;
          key = environmentKey;
        };
      }) cfg.variables;
  };
}
