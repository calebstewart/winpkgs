# Windows services: `windows.services.<name>` declares one -- its program, how
# it starts, what the SCM does when it fails -- and winpkgs creates it or
# brings an existing one into line. Machine scope: services are the machine's.
#
# `type = "userOwn"` declares a per-user service template, what a user service
# manager is hosted by: Windows starts an instance of it in every session that
# signs in, running as that user. A template's instances copy its definition
# when they are created, so a change is made to the instances that exist too,
# and creating a template starts nothing before the next sign-in.
#
# A service winpkgs created is deleted once it leaves the configuration
# (`winpkgs.prune.services`); one that was already there is only managed.
{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.windows.services;

  failureAction = types.submodule {
    options = {
      action = mkOption {
        type = types.enum [
          "restart"
          "reboot"
          "none"
        ];
        description = "What the SCM does after this failure.";
      };
      delay = mkOption {
        type = types.ints.unsigned;
        default = 0;
        description = "Milliseconds to wait first.";
      };
    };
  };

  service = types.submodule (
    { name, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether the service is declared. `false` is the same as leaving it
            out: a service winpkgs created is deleted, anything else left alone.
          '';
        };

        command = mkOption {
          type = types.str;
          example = ''"C:\Program Files\steward\steward.exe"'';
          description = ''
            The command line the SCM runs: the program, quoted if its path has
            spaces, and its arguments.
          '';
        };

        displayName = mkOption {
          type = types.str;
          default = name;
          defaultText = lib.literalMD "the service's name";
          description = "The name Services and `Get-Service` show.";
        };

        description = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "The service's description; `null` leaves whatever is there.";
        };

        type = mkOption {
          type = types.enum [
            "own"
            "userOwn"
          ];
          default = "own";
          description = ''
            `own`: an ordinary service in a process of its own, in session 0.
            `userOwn`: a per-user service template; Windows starts an instance,
            `<name>_<suffix>`, in each session that signs in, as that user. A
            service's type is never changed in place: to change it, remove the
            service, apply, and declare it again.
          '';
        };

        startType = mkOption {
          type = types.enum [
            "automatic"
            "delayedAutomatic"
            "manual"
            "disabled"
          ];
          default = "automatic";
          description = ''
            When it starts. For a template, `automatic` is what makes an
            instance start at sign-in. An own-process service created
            `automatic` is started at once, as a NixOS switch would.
          '';
        };

        account = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "NT AUTHORITY\\LocalService";
          description = ''
            The account an `own` service runs as; `null` is LocalSystem. A
            template's instances run as their user, so it has none.
          '';
        };

        failureActions = mkOption {
          type = types.nullOr (
            types.submodule {
              options = {
                resetAfter = mkOption {
                  type = types.ints.unsigned;
                  default = 86400;
                  description = "Seconds without a failure after which the count of failures starts over.";
                };
                actions = mkOption {
                  type = types.listOf failureAction;
                  description = "What to do after the first failure, the second, and so on.";
                };
              };
            }
          );
          default = null;
          example = lib.literalExpression ''
            {
              resetAfter = 60;
              actions = [ { action = "restart"; delay = 5000; } { action = "restart"; delay = 5000; } ];
            }
          '';
          description = "What the SCM does when the service fails; `null` leaves it alone.";
        };

        restartTriggers = mkOption {
          type = types.listOf types.unspecified;
          default = [ ];
          example = lib.literalExpression "[ pkgs.steward ]";
          description = ''
            Anything whose change should restart the service, as NixOS's
            `systemd.services.<name>.restartTriggers`: when they differ from the
            last apply, the running service -- for a template, every running
            instance -- is restarted once its definition is in place. A new
            `command` restarts it anyway.
          '';
        };

        restartControl = mkOption {
          type = types.nullOr (types.ints.between 128 255);
          default = null;
          example = 128;
          description = ''
            The user-defined control (128-255) that ends the service when
            winpkgs restarts it for a change, in place of Stop; `null` is Stop.
            For a service whose Stop means more than stopping itself: a user
            service manager stops everything it runs on Stop, and hands them
            over to its successor on its own control. The service is expected
            to stop itself once it has the control; one that does not accept
            it is stopped the ordinary way. What NixOS says with
            `reloadIfChanged`, for a service that cannot be re-executed in
            place.
          '';
        };
      };
    }
  );

  enabled = lib.filterAttrs (_: s: s.enable) cfg;
in
{
  options.windows.services = mkOption {
    type = types.attrsOf service;
    default = { };
    description = "Windows services, by name. See `type` for per-user service templates.";
  };

  config = {
    assertions = lib.mapAttrsToList (name: s: {
      assertion = s.type == "own" || s.account == null;
      message = "windows.services.${name}: a userOwn template runs as each user and cannot have an account.";
    }) enabled;

    winpkgs.resources = lib.mapAttrsToList (name: s: {
      type = "winpkgs/service";
      id = "Service ${name}";
      scope = "machine";
      properties = {
        inherit name;
        inherit (s)
          command
          displayName
          description
          type
          startType
          account
          restartControl
          ;
        failureActions =
          if s.failureActions == null then
            null
          else
            {
              reset = s.failureActions.resetAfter;
              actions = map (a: { inherit (a) action delay; }) s.failureActions.actions;
            };
        revision =
          if s.restartTriggers == [ ] then
            null
          else
            builtins.hashString "sha256" (builtins.toJSON s.restartTriggers);
      };
    }) enabled;
  };
}
