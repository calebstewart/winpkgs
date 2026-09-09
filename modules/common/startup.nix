# Programs that start at sign-in: the Run key, for this user in a home
# configuration (HKCU) and for every user in a system one (HKLM). Each entry
# is a name and a command line.
#
# Task Manager's Startup tab does not delete a Run entry it disables; it
# records the veto under StartupApproved. So an entry here writes both: the
# command, and an "enabled" record beside it, which is what makes a declared
# program actually start rather than stay quietly vetoed. Removing an entry
# (`null`) deletes both.
{
  lib,
  config,
  winpkgsKind,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.windows.startup;

  hive = if winpkgsKind == "system" then "HKLM" else "HKCU";
  run = ''${hive}\Software\Microsoft\Windows\CurrentVersion\Run'';
  approved = ''${hive}\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'';

  # StartupApproved's record: a twelve-byte blob whose first byte is 02 for
  # enabled (03 is disabled); the rest is the time it was last toggled, which
  # nothing needs.
  enabled = {
    type = "Binary";
    value = [ 2 ] ++ lib.replicate 11 0;
  };
in
{
  options.windows.startup = mkOption {
    type = types.attrsOf (types.nullOr types.str);
    default = { };
    example = lib.literalExpression ''
      {
        "Ember Mug" = '''"%LOCALAPPDATA%\Programs\embermug-tray\embermug-tray.exe" --minimized''';
        OneDrive = null;   # remove an entry
      }
    '';
    description = ''
      Programs to run at sign-in, by name, as command lines (quote a path with
      spaces). For this user in a home configuration, for every user in a
      system one. `null` removes the entry, whoever put it there; a name not
      listed is left alone.
    '';
  };

  config.windows.registry = {
    ${run} = lib.mapAttrs (_: cmd: cmd) cfg;
    ${approved} = lib.mapAttrs (_: cmd: if cmd == null then null else enabled) cfg;
  };
}
