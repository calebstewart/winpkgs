# Scheduled tasks: whether one may run, and the tasks winpkgs defines itself.
#
# An entry without a `command` says only whether an existing task may run.
# What such a task does is Windows' business -- or an application's; a
# configuration that redefined its triggers or its action would be replacing
# part of the operating system rather than settling a preference. Turning one
# off is the whole of what is wanted, because some of them exist to undo
# settings -- `\Microsoft\Windows\AppxDeploymentClient\UCPD velocity` runs
# UCPDMgr.exe at every logon and sets the User Choice Protection Driver back.
# `true` and `false` are short for that kind of entry.
#
# An entry with a `command` defines a task: winpkgs registers it, with the
# security descriptor in the same call, and deletes it once it leaves the
# configuration (`winpkgs.prune.scheduledTasks`). A task by that name that is
# already there, and that winpkgs did not create, is refused rather than
# replaced. This is what a system module that needs something run as SYSTEM
# at every sign-in uses, where an activation script would register it once
# and leave it behind forever.
#
# Machine scope: the tasks worth naming live under `\Microsoft\Windows`,
# writing those needs elevation, and a task that runs as another account is
# the machine's.
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

  # The accounts a task runs as with no password and no session: SYSTEM,
  # LOCAL SERVICE and NETWORK SERVICE, however they are written.
  serviceAccounts = map lib.toLower [
    "S-1-5-18"
    "SYSTEM"
    "LocalSystem"
    "NT AUTHORITY\\SYSTEM"
    "S-1-5-19"
    "LocalService"
    "LOCAL SERVICE"
    "NT AUTHORITY\\LocalService"
    "NT AUTHORITY\\LOCAL SERVICE"
    "S-1-5-20"
    "NetworkService"
    "NETWORK SERVICE"
    "NT AUTHORITY\\NetworkService"
    "NT AUTHORITY\\NETWORK SERVICE"
  ];
  isServiceAccount = account: lib.elem (lib.toLower account) serviceAccounts;

  # ISO 8601, as the Task Scheduler writes durations: PT3M, P1DT12H, PT0S.
  duration = types.strMatching "P([0-9]+D)?(T([0-9]+H)?([0-9]+M)?([0-9]+S)?)?";

  trigger = types.submodule {
    options = {
      type = mkOption {
        type = types.enum [
          "logon"
          "boot"
        ];
        description = "`logon`: when a user signs in. `boot`: when the machine starts, before anyone signs in.";
      };
      user = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "S-1-5-21-1-2-3-1001";
        description = ''
          For a logon trigger, whose sign-in it waits for: an account's SID
          or name. `null` is every user's.
        '';
      };
      delay = mkOption {
        type = types.nullOr duration;
        default = null;
        example = "PT30S";
        description = "How long after the event the task starts, as an ISO 8601 duration; `null` is at once.";
      };
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether this trigger starts the task.";
      };
    };
  };

  task = types.submodule (
    { config, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether the task may run. For a task this configuration defines,
            `false` keeps it registered and disabled; to remove one, leave it
            out. For one it does not define, this is the whole declaration.
          '';
        };

        command = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = ''C:\Program Files\steward\steward.exe'';
          description = ''
            The program the task runs, unquoted. Setting it makes this entry a
            task winpkgs defines; `null` leaves the task as it is and says only
            whether it may run.
          '';
        };

        arguments = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "provision-eventlog";
          description = "The program's arguments, as one command-line string.";
        };

        workingDirectory = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "The directory the program starts in; `null` is Windows' choice (System32 for SYSTEM).";
        };

        description = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "The task's description, as Task Scheduler shows it.";
        };

        author = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "The task's author, as Task Scheduler shows it.";
        };

        runAs = mkOption {
          type = types.str;
          default = "S-1-5-18";
          example = "S-1-5-32-545";
          description = ''
            The account, or with `logonType = "group"` the group, the task runs
            as: a SID or a name. The default is SYSTEM.
          '';
        };

        logonType = mkOption {
          type = types.enum [
            "serviceAccount"
            "interactiveToken"
            "s4u"
            "group"
          ];
          default = if isServiceAccount config.runAs then "serviceAccount" else "interactiveToken";
          defaultText = lib.literalMD "`serviceAccount` for SYSTEM, LOCAL SERVICE and NETWORK SERVICE, else `interactiveToken`";
          description = ''
            How the task runs as `runAs` without a stored password.
            `serviceAccount`: as SYSTEM, LOCAL SERVICE or NETWORK SERVICE.
            `interactiveToken`: as the user, only while they are signed in,
            in their session. `s4u`: as the user whether signed in or not,
            with no network credentials. `group`: as whichever member of the
            group is signed in. Passwords are never stored.
          '';
        };

        runLevel = mkOption {
          type = types.enum [
            "limited"
            "highest"
          ];
          default = "limited";
          description = ''
            `highest` runs with the account's full rights -- elevated, for an
            administrator; `limited` with the filtered token UAC gives them.
          '';
        };

        triggers = mkOption {
          type = types.listOf trigger;
          default = [ ];
          example = lib.literalExpression ''[ { type = "logon"; } ]'';
          description = "What starts the task. None: it runs only when started on demand.";
        };

        multipleInstances = mkOption {
          type = types.enum [
            "parallel"
            "queue"
            "ignoreNew"
            "stopExisting"
          ];
          default = "ignoreNew";
          description = ''
            What a start does while the task is still running: run alongside
            it, wait for it, be dropped (Windows' default), or stop it.
            `queue` is what a logon task that must run for every user needs,
            since two sign-ins at once would otherwise lose one.
          '';
        };

        disallowStartIfOnBatteries = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Whether the task is kept from starting while the machine runs on
            battery. Windows' own default is `true`, which on a laptop away
            from its charger means a trigger silently does nothing; winpkgs'
            is `false`.
          '';
        };

        stopIfGoingOnBatteries = mkOption {
          type = types.bool;
          default = false;
          description = "Whether a running task is stopped when the machine switches to battery. Windows' own default is `true`; winpkgs' is `false`.";
        };

        startWhenAvailable = mkOption {
          type = types.bool;
          default = false;
          description = "Whether a start missed while the machine was off, or the task disabled, happens as soon as it can.";
        };

        allowStartOnDemand = mkOption {
          type = types.bool;
          default = true;
          description = "Whether the task may be started by hand, or by a program, as well as by its triggers.";
        };

        executionTimeLimit = mkOption {
          type = duration;
          default = "PT72H";
          example = "PT3M";
          description = "How long the task may run before it is stopped, as an ISO 8601 duration; `PT0S` is no limit.";
        };

        securityDescriptor = mkOption {
          type = types.nullOr (types.strMatching "D:[^:]*");
          default = null;
          example = "D:(A;;FA;;;BA)(A;;FA;;;SY)(A;;0x1200a9;;;AU)";
          description = ''
            Who may read, run, change and delete the task: its discretionary
            ACL in SDDL, with file rights (`FA` everything, `FR` read, `FRFX`
            or `0x1200a9` read and run). Set in the same call that registers
            the task, so a task that runs as SYSTEM is never open to rewriting
            in between. `null` leaves Windows' default, which gives
            administrators and SYSTEM everything and the account the task runs
            as read access -- and nobody else anything, so a plan, which runs
            unelevated, cannot read the task and counts it as a change every
            time. Compared by meaning: `AU` and `S-1-5-11` are one trustee,
            `FRFX` and `0x1200a9` one mask, and the entries Windows adds itself
            (what the folder hands down, read for the account it runs as) are
            not counted. The DACL only.
          '';
        };
      };
    }
  );

  defined = lib.filterAttrs (_: t: t.command != null) cfg;
  toggled = lib.filterAttrs (_: t: t.command == null) cfg;
in
{
  options.windows.scheduledTasks = mkOption {
    type = types.attrsOf (types.coercedTo types.bool (enable: { inherit enable; }) task);
    default = { };
    example = lib.literalExpression ''
      {
        "\\Microsoft\\Windows\\AppxDeploymentClient\\UCPD velocity" = false;
        "\\steward-provision-eventlog" = {
          command = '''C:\Program Files\steward\steward.exe''';
          arguments = "provision-eventlog";
          runLevel = "highest";
          triggers = [ { type = "logon"; } ];
          multipleInstances = "queue";
          securityDescriptor = "D:(A;;FA;;;BA)(A;;FA;;;SY)(A;;0x1200a9;;;AU)";
        };
      }
    '';
    description = ''
      Scheduled tasks, keyed by their full path. An entry with a `command` is a
      task winpkgs defines, registers and -- once it leaves the configuration
      -- deletes; one that already exists and that winpkgs did not create is
      refused. An entry without one, or plain `true`/`false`, says only
      whether an existing task may run: `false` disables it, `true` enables it
      again, asking to enable one that is not there is an error, and one that
      has already been removed counts as disabled.

      Names are attribute names, so backslashes are doubled:
      `"\\Microsoft\\Windows\\..."`.
    '';
  };

  config = {
    assertions =
      lib.mapAttrsToList (path: t: {
        assertion =
          t.arguments == null
          && t.workingDirectory == null
          && t.description == null
          && t.author == null
          && t.triggers == [ ]
          && t.securityDescriptor == null;
        message = ''windows.scheduledTasks."${lib.escape [ "\\" ] path}": arguments, a working directory, a description, an author, triggers and a security descriptor describe a task, which needs a `command`; without one an entry only says whether an existing task may run.'';
      }) toggled
      ++ lib.mapAttrsToList (path: t: {
        assertion = (t.logonType == "serviceAccount") == isServiceAccount t.runAs;
        message = ''windows.scheduledTasks."${lib.escape [ "\\" ] path}": logonType "serviceAccount" is for SYSTEM, LOCAL SERVICE and NETWORK SERVICE, and they take no other; runAs is "${t.runAs}".'';
      }) defined
      ++ lib.concatLists (
        lib.mapAttrsToList (
          path: t:
          map (tr: {
            assertion = tr.type == "logon" || tr.user == null;
            message = ''windows.scheduledTasks."${lib.escape [ "\\" ] path}": only a logon trigger waits for a user.'';
          }) t.triggers
        ) defined
      );

    winpkgs.resources = lib.mapAttrsToList (
      task: t:
      let
        p = parts task;
      in
      if t.command == null then
        {
          type = "winpkgs/scheduledTask";
          id = "Task ${task}";
          scope = "machine";
          properties = {
            inherit (p) path name;
            enabled = t.enable;
          };
        }
      else
        {
          type = "winpkgs/task";
          id = "Task ${task}";
          scope = "machine";
          properties = {
            inherit (p) path name;
            inherit (t)
              command
              arguments
              workingDirectory
              description
              author
              runAs
              logonType
              runLevel
              multipleInstances
              disallowStartIfOnBatteries
              stopIfGoingOnBatteries
              startWhenAvailable
              allowStartOnDemand
              executionTimeLimit
              securityDescriptor
              ;
            enabled = t.enable;
            triggers = map (tr: {
              inherit (tr) type user delay;
              enabled = tr.enable;
            }) t.triggers;
          };
        }
    ) cfg;
  };
}
