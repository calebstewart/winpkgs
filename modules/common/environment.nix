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

  pathEntry = types.submodule {
    options = {
      dir = mkOption {
        type = types.str;
        example = ''%ProgramFiles%\WinGet\Links'';
        description = "The directory.";
      };
      position = mkOption {
        type = types.enum [
          "lead"
          "trail"
        ];
        default = "trail";
        description = ''
          `trail` appends the directory if it is missing and leaves the rest of
          `PATH` as it is -- what a plain string means, and what winpkgs has
          always done. `lead` puts it in front of everything else on that
          `PATH`, entries winpkgs does not own included, which is the only way
          to come before `System32`.
        '';
      };
    };
  };

  # Comparison form, as the runtime compares entries: case-folded, without a
  # trailing separator. `%VAR%` is not expanded here -- Nix cannot -- so two
  # spellings of one directory are told apart on the machine, not at evaluation.
  normal = dir: lib.toLower (lib.removeSuffix "/" (lib.removeSuffix "\\" dir));

  leadDirs = lib.unique (map (e: e.dir) (lib.filter (e: e.position == "lead") cfg.path));
  leadKeys = map normal leadDirs;
  # Lead wins: the same directory named both ways is led, not appended as well.
  # The two definitions come from different modules often enough (a module adds
  # a directory, a configuration wants it first) that this is a rule rather than
  # a refusal.
  trailDirs = lib.unique (
    map (e: e.dir) (
      lib.filter (e: e.position == "trail" && !(lib.elem (normal e.dir) leadKeys)) cfg.path
    )
  );
in
{
  # The primitive both trees write to. Not the user-facing name: a system
  # configuration says `environment.variables` / `environment.path` (NixOS's
  # names, aliased in modules/system/nixos.nix) and a home configuration says
  # `home.sessionVariables` / `home.sessionPath` (home-manager's, translated in
  # modules/home/home-manager.nix).
  options.winpkgs.environment = {
    path = mkOption {
      type = types.listOf (types.coercedTo types.str (dir: { inherit dir; }) pathEntry);
      default = [ ];
      internal = true;
      visible = false;
      example = [
        ''%LOCALAPPDATA%\Programs\nvim\bin''
        {
          dir = ''%ProgramFiles%\WinGet\Links'';
          position = "lead";
        }
      ];
      description = ''
        Directories that must be on `PATH` -- the user's in a home configuration,
        the machine's in a system one. A plain string is appended if missing and
        otherwise left alone; `%VAR%` references are kept unexpanded.

        `{ dir; position = "lead"; }` asks for more: that directory ahead of
        everything else on that `PATH`, `System32` and whatever an installer
        appended included, with the lead entries in the order they are listed
        (`lib.mkBefore` and `lib.mkAfter` order that list). Naming a directory
        `lead` anywhere wins over a `trail` entry for the same directory. A
        machine `PATH` comes before a user `PATH` in any process, so a home
        configuration's `lead` leads the user's half only -- beating `System32`
        is a system configuration's to ask for.

        Removing an entry does not remove it from `PATH`, and neither does
        `rollback` to a generation without it; the same is true of the order,
        which stays as the last apply left it. What the value was before a
        change is in that generation's journal.
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
      }) trailDirs
      # One resource for all of the lead entries: which directory is first is a
      # property of the value, and per-directory resources could not agree on it
      # (each would find the one before it in the way).
      ++ lib.optional (leadDirs != [ ]) {
        type = "winpkgs/pathOrder";
        id = "PathOrder\\${environmentKey}\\Path";
        inherit scope;
        properties = {
          dirs = leadDirs;
          key = environmentKey;
          name = "Path";
        };
      }
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
