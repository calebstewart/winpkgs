# Power, with nix-darwin's names where they fit: `power.plan`, `power.sleep.*`
# in minutes or "never", `power.buttons.*`, hibernation and fast startup.
# Machine scope throughout; Windows keeps one set of schemes for everyone.
#
# Every timeout and button action is one value with an AC side and a battery
# side. A bare value sets both; `{ ac; battery; }` sets them apart. They
# travel as winpkgs/powerSetting resources naming the scheme, subgroup and
# setting by their guids, which is what powercfg takes and what does not
# change between Windows versions or languages.
{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.power;

  schemes = {
    balanced = "381b4222-f694-41f0-9685-ff5bb260df2e";
    highPerformance = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c";
    powerSaver = "a1841308-3541-4fab-bc81-f71556f20b4a";
    ultimate = "e9a42b02-d5df-448d-aa00-03f14749eb61";
  };
  guid = types.strMatching "[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}";
  sessionManagerPower = ''HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power'';
  planGuid = if cfg.plan == null then null else (schemes.${cfg.plan} or cfg.plan);

  subgroup = {
    sleep = "238c9fa8-0aad-41ed-83f4-97be242c8f20";
    video = "7516b95f-f776-4464-8c53-06167f40cc99";
    disk = "0012ee47-9041-4b5d-9b77-535fba8b1442";
    buttons = "4f971e89-eebd-4455-a8de-9e59040e7347";
  };

  # A value for both power sources, or one per source.
  perSource =
    scalar:
    types.coercedTo scalar
      (v: {
        ac = v;
        battery = v;
      })
      (
        types.submodule {
          options = {
            ac = mkOption {
              type = scalar;
              description = "On mains power.";
            };
            battery = mkOption {
              type = scalar;
              description = "On battery.";
            };
          };
        }
      );

  minutes = types.either (types.enum [ "never" ]) types.ints.unsigned;
  toSeconds = v: if v == "never" then 0 else v * 60;

  action = types.enum [
    "nothing"
    "sleep"
    "hibernate"
    "shutdown"
    "turnOffDisplay"
  ];
  actionCode = {
    nothing = 0;
    sleep = 1;
    hibernate = 2;
    shutdown = 3;
    turnOffDisplay = 4;
  };

  timeoutOption =
    what:
    mkOption {
      type = types.nullOr (perSource minutes);
      default = null;
      example = {
        ac = "never";
        battery = 30;
      };
      description = "${what}, in minutes of idleness, or `never`. One value for both power sources, or `{ ac; battery; }`. `null` leaves the scheme's value.";
    };
  actionOption =
    what:
    mkOption {
      type = types.nullOr (perSource action);
      default = null;
      example = "sleep";
      description = "${what}: `nothing`, `sleep`, `hibernate`, `shutdown` or `turnOffDisplay`. One value for both power sources, or `{ ac; battery; }`. `null` leaves the scheme's value.";
    };

  # label -> where it lives and how its value is encoded.
  table = {
    "sleep.computer" = {
      sub = subgroup.sleep;
      setting = "29f6c1db-86da-48c5-9fdb-f2b67b1f44da";
      value = cfg.sleep.computer;
      encode = toSeconds;
    };
    "sleep.display" = {
      sub = subgroup.video;
      setting = "3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e";
      value = cfg.sleep.display;
      encode = toSeconds;
    };
    "sleep.harddisk" = {
      sub = subgroup.disk;
      setting = "6738e2c4-e8a5-4a42-b16a-e040e769756e";
      value = cfg.sleep.harddisk;
      encode = toSeconds;
    };
    "sleep.hibernate" = {
      sub = subgroup.sleep;
      setting = "9d7815a6-7ee4-497e-8888-515a05f02364";
      value = cfg.sleep.hibernate;
      encode = toSeconds;
    };
    "buttons.lidClose" = {
      sub = subgroup.buttons;
      setting = "5ca83367-6e45-459f-a27b-476b1d01c936";
      value = cfg.buttons.lidClose;
      encode = a: actionCode.${a};
    };
    "buttons.power" = {
      sub = subgroup.buttons;
      setting = "7648efa3-dd9c-4e3e-b566-50f929386280";
      value = cfg.buttons.power;
      encode = a: actionCode.${a};
    };
    "buttons.sleep" = {
      sub = subgroup.buttons;
      setting = "96996bc0-ad50-47ec-923b-6f41874dd9eb";
      value = cfg.buttons.sleep;
      encode = a: actionCode.${a};
    };
  };

  settingResources = lib.concatLists (
    lib.mapAttrsToList (
      label: t:
      lib.optional (t.value != null) {
        type = "winpkgs/powerSetting";
        id = "Power\\${label}";
        scope = "machine";
        properties = {
          inherit label;
          scheme = planGuid;
          subgroup = t.sub;
          inherit (t) setting;
          ac = t.encode t.value.ac;
          dc = t.encode t.value.battery;
        };
      }
    ) table
  );

  lidTurnsOffDisplay =
    cfg.buttons.lidClose != null
    && (
      cfg.buttons.lidClose.ac == "turnOffDisplay" || cfg.buttons.lidClose.battery == "turnOffDisplay"
    );
in
{
  options.power = {
    plan = mkOption {
      type = types.nullOr (types.either (types.enum (lib.attrNames schemes)) guid);
      default = null;
      example = "highPerformance";
      description = ''
        The active power scheme: `balanced`, `highPerformance`, `powerSaver`,
        `ultimate`, or a scheme's guid. The timeouts and actions below are
        written into this scheme, or into whichever is active when this is
        `null`. Windows hides Ultimate Performance until it has been created
        once (`powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61`).
      '';
    };
    sleep = {
      computer = timeoutOption "Sleep";
      display = timeoutOption "Turn off the display";
      harddisk = timeoutOption "Turn off hard disks";
      hibernate = timeoutOption "Hibernate";
    };
    buttons = {
      lidClose = actionOption "Closing the lid";
      power = actionOption "Pressing the power button";
      sleep = actionOption "Pressing the sleep button";
    };
    hibernation = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Whether hibernation is available at all (`powercfg /hibernate`). Off also removes hiberfil.sys, and with it fast startup. `null` leaves it.";
    };
    fastStartup = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Fast startup: shut down by hibernating the kernel session, so the next boot resumes it. Needs hibernation. `null` leaves it.";
    };
  };

  config = {
    winpkgs.resources =
      lib.optional (planGuid != null) {
        type = "winpkgs/powerPlan";
        id = "Power\\plan";
        scope = "machine";
        properties = {
          guid = planGuid;
        };
      }
      ++ settingResources
      ++ lib.optional (cfg.hibernation != null) {
        type = "winpkgs/hibernation";
        id = "Power\\hibernation";
        scope = "machine";
        properties = {
          enabled = cfg.hibernation;
        };
      };

    windows.registry.${sessionManagerPower} = lib.mkIf (cfg.fastStartup != null) {
      HiberbootEnabled = if cfg.fastStartup then 1 else 0;
    };

    assertions = [
      {
        assertion = !(cfg.fastStartup == true && cfg.hibernation == false);
        message = "power.fastStartup needs hibernation; power.hibernation is false";
      }
      {
        assertion = !lidTurnsOffDisplay;
        message = "power.buttons.lidClose: `turnOffDisplay` is not an action a lid can have";
      }
    ];
  };
}
