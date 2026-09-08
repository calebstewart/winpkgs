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
  # The primitive both trees write to. Not the user-facing name: a system
  # configuration says `environment.variables` / `environment.path` (NixOS's
  # names, aliased in modules/system/nixos.nix) and a home configuration says
  # `home.sessionVariables` / `home.sessionPath` (home-manager's, translated in
  # modules/home/home-manager.nix).
  options.winpkgs.environment = {
    path = mkOption {
      type = types.listOf types.str;
      default = [ ];
      internal = true;
      visible = false;
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
      internal = true;
      visible = false;
      example = {
        EDITOR = ''%LOCALAPPDATA%\Programs\nvim\bin\nvim.exe'';
      };
      description = ''
        Environment variables, set exactly -- the user's in a home configuration,
        the machine's in a system one. A value containing `%VAR%` is stored
        expandable. New processes see a change at once; running ones do not.
        `PATH` is refused here -- the path option appends instead of replacing.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = !(lib.any (n: lib.toLower n == "path") (lib.attrNames cfg.variables));
        message = "environment variables: set PATH entries with environment.path (system) or home.sessionPath (home), which append rather than replace";
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
