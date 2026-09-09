# Scheduled tasks Windows ships and this machine would rather did not run.
#
# Only whether a task may run. What it does is Windows' business; a
# configuration that redefined its triggers or its action would be replacing
# part of the operating system rather than settling a preference. Turning one
# off is the whole of what is wanted, because some of them exist to undo
# settings -- `\Microsoft\Windows\AppxDeploymentClient\UCPD velocity` runs
# UCPDMgr.exe at every logon and sets the User Choice Protection Driver back.
#
# Machine scope: the tasks worth naming live under `\Microsoft\Windows`, and
# writing those needs elevation.
{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.windows.scheduledTasks;

  # Get-ScheduledTask takes the folder and the name separately, and wants the
  # folder with its trailing backslash. "\A\B\Name" is folder "\A\B\", name
  # "Name"; a bare "Name" is folder "\".
  parts =
    task:
    let
      segments = lib.splitString "\\" task;
      name = lib.last segments;
      folder = lib.concatStringsSep "\\" (lib.init segments);
    in
    {
      inherit name;
      path = if folder == "" then "\\" else "${folder}\\";
    };
in
{
  options.windows.scheduledTasks = mkOption {
    type = types.attrsOf types.bool;
    default = { };
    example = lib.literalExpression ''
      { "\\Microsoft\\Windows\\AppxDeploymentClient\\UCPD velocity" = false; }
    '';
    description = ''
      Whether a scheduled task may run, keyed by its full path. `false` disables
      it; `true` enables it again. Nothing here creates, deletes or redefines a
      task -- asking to enable one that is not there is an error, and a task
      that has already been removed counts as disabled.

      Names are attribute names, so backslashes are doubled:
      `"\\Microsoft\\Windows\\..."`.
    '';
  };

  config.winpkgs.resources = lib.mapAttrsToList (
    task: enabled:
    let
      p = parts task;
    in
    {
      type = "winpkgs/scheduledTask";
      id = "Task ${task}";
      scope = "machine";
      properties = {
        inherit (p) path name;
        inherit enabled;
      };
    }
  ) cfg;
}
