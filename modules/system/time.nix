# Time: the zone, what the hardware clock means, and the NTP client. Machine
# scope throughout -- Windows keeps one clock for everyone.
#
# NixOS' names where they fit (`time.timeZone`, `time.hardwareClockInLocalTime`)
# so a flake that already answers these questions for a NixOS machine answers
# them here from the same values. `time.timeZone` therefore takes IANA names and
# translates through CLDR's table on the way out; a Windows id passes through,
# for the handful Windows has and IANA does not name the same way.
#
# Two resources rather than plain registry values, for two different reasons.
# The zone is a winpkgs/timeZone because only tzutil recomputes the bias and the
# DST rules from an id -- writing `TimeZoneKeyName` alone leaves the clock on
# the old offset until a reboot. The NTP client is one winpkgs/timeSync because
# its settings are spread over three keys and w32time reads them once: they take
# effect together, on `w32tm /config /update`, or not at all.
{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.time;

  zones = import ./time-zones.nix;

  timeZoneInformation = ''HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'';
  tzautoupdate = ''HKLM\SYSTEM\CurrentControlSet\Services\tzautoupdate'';

  # An IANA name, or a Windows id already.
  resolved =
    if cfg.timeZone == null then
      null
    else if zones.byIana ? ${cfg.timeZone} then
      zones.byIana.${cfg.timeZone}
    else if lib.elem cfg.timeZone zones.windows then
      cfg.timeZone
    else
      null;

  # Casing is the usual near-miss: "central standard time" is a Windows id
  # spelled wrong, not an unknown zone, and saying so beats "unknown".
  sameButForCase = lib.findFirst (
    w: lib.toLower w == lib.toLower (toString cfg.timeZone)
  ) null zones.windows;

  # `host` means the flags Windows ships; `host,0x2` means exactly that. 0x9 is
  # SpecialInterval|Client -- poll on `pollInterval` rather than on the interval
  # w32time would compute for itself.
  withFlags = s: if lib.hasInfix "," s then s else "${s},${cfg.ntp.flags}";
  peerList = lib.concatStringsSep " " (map withFlags cfg.ntp.servers);

  unlimited = 4294967295; # 0xFFFFFFFF: accept a correction of any size
  correction = if cfg.ntp.maxCorrection == "unlimited" then unlimited else cfg.ntp.maxCorrection;

  syncConfigured =
    cfg.ntp.enable != null
    || cfg.ntp.servers != [ ]
    || cfg.ntp.pollInterval != null
    || cfg.ntp.maxCorrection != null;
in
{
  options.time = {
    timeZone = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "America/Chicago";
      description = ''
        The system time zone, as an IANA name (`America/Chicago`) or as the id
        Windows itself uses (`Central Standard Time`). IANA names are translated
        through CLDR's table, which is the same translation .NET and ICU do, so
        this option takes the value a NixOS `time.timeZone` already holds.

        The translation is many-to-one -- Windows has one id per offset and DST
        rule where IANA has one per place -- so `America/Chicago` and
        `America/Winnipeg` both land on `Central Standard Time`. That is Windows
        being coarser, not a loss of information this module could avoid.

        `null` leaves the machine's zone alone.
      '';
    };

    hardwareClockInLocalTime = mkOption {
      type = types.nullOr types.bool;
      default = null;
      example = false;
      description = ''
        Whether the CMOS clock holds local time. Windows assumes it does; Linux
        and macOS assume it holds UTC. On a machine that boots more than one of
        them the two assumptions disagree by exactly the UTC offset, and
        whichever booted last leaves the clock wrong for the other -- five hours
        fast in `America/Chicago`, and wrong in a way that survives until the
        next successful NTP poll.

        `false` sets `RealTimeIsUniversal`, which puts Windows on UTC and ends
        the argument. This is the side to change: it is the one every other
        system already takes, and it is immune to DST, where local time is
        ambiguous for an hour a year.

        Setting it does not fix the clock, only the interpretation; the current
        reading is off by the offset until the machine resyncs or reboots. Note
        also that the firmware setup screen will show UTC afterwards.

        `null` leaves it alone, which means Windows' assumption.
      '';
    };

    autoTimeZone = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = ''
        Whether Windows sets the time zone from the machine's location -- the
        "Set time zone automatically" switch, which is the `tzautoupdate`
        service. Needs location services on to do anything, and overrides
        `time.timeZone` when it fires, so the two are worth deciding together.

        `null` leaves it alone.
      '';
    };

    ntp = {
      enable = mkOption {
        type = types.nullOr types.bool;
        default = null;
        example = true;
        description = ''
          Whether the machine synchronises its clock over NTP -- the "Set time
          automatically" switch. `true` enables w32time's NTP client, sets the
          service to start automatically and starts it; `false` stops it
          synchronising. `null` leaves it alone.

          On a workstation Windows leaves w32time on a trigger start, so the
          clock is corrected on a schedule that assumes it was right to begin
          with. `true` is the honest setting for a machine that keeps drifting.
        '';
      };

      servers = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [
          "time.cloudflare.com"
          "time.nist.gov"
        ];
        description = ''
          NTP servers, in preference order -- the analogue of NixOS'
          `networking.timeServers`, and it takes the same values.

          Each entry may carry Windows' per-peer flags after a comma
          (`time.nist.gov,0x8`); one that does not gets `time.ntp.flags`. An
          empty list leaves the machine's peers alone, which on a fresh install
          means `time.windows.com`.
        '';
      };

      flags = mkOption {
        type = types.str;
        default = "0x9";
        description = ''
          Per-peer flags for `time.ntp.servers` entries that do not carry their
          own: `0x1` SpecialInterval (poll on `time.ntp.pollInterval` rather
          than on an interval w32time computes), `0x2` UseAsFallbackOnly, `0x4`
          SymmetricActive, `0x8` Client. `0x9` is what Windows ships, and what
          makes `pollInterval` mean anything.
        '';
      };

      pollInterval = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        example = 3600;
        description = ''
          Seconds between polls, for peers carrying the SpecialInterval flag
          (`SpecialPollInterval`). Windows ships 32768 -- nine hours and change
          -- which is why a clock that jumps stays wrong for most of a day and
          why toggling "Set time automatically" off and on appears to be the fix:
          that forces the resync that was not otherwise due.

          An hour is a reasonable floor to ask of a public server. `null` leaves
          it alone.
        '';
      };

      maxCorrection = mkOption {
        type = types.nullOr (types.either types.ints.unsigned (types.enum [ "unlimited" ]));
        default = null;
        example = 54000;
        description = ''
          The largest correction, in seconds, w32time will apply rather than
          reject and log (`MaxPosPhaseCorrection` and `MaxNegPhaseCorrection`,
          set together). A clock that is wrong by a whole UTC offset needs this
          to be larger than that offset or the sync silently does nothing.

          Windows ships 54000 (15 hours) on a workstation, which covers every
          offset. `"unlimited"` accepts any correction, which is the right
          setting for a machine whose clock can be arbitrarily wrong at boot and
          the wrong one for a machine where a bad server should not be able to
          move the clock. `null` leaves it alone.
        '';
      };

      resync = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Force a resync (`w32tm /resync`) after changing any of the above, so
          an apply that fixes the configuration also fixes the clock instead of
          waiting for the next poll. No effect on an apply that changes nothing.
        '';
      };
    };
  };

  config = {
    winpkgs.resources =
      lib.optional (resolved != null) {
        type = "winpkgs/timeZone";
        id = ''Time\zone'';
        scope = "machine";
        properties = {
          id = resolved;
        };
      }
      ++ lib.optional syncConfigured {
        type = "winpkgs/timeSync";
        id = ''Time\sync'';
        scope = "machine";
        properties = {
          enabled = cfg.ntp.enable;
          servers = if cfg.ntp.servers == [ ] then null else peerList;
          pollInterval = cfg.ntp.pollInterval;
          maxCorrection = correction;
          resync = cfg.ntp.resync;
        };
      };

    # Neither of these needs w32time told: the first is read when the kernel
    # reads the clock, the second is a service's start type.
    windows.registry = lib.mkMerge [
      (lib.mkIf (cfg.hardwareClockInLocalTime != null) {
        ${timeZoneInformation}.RealTimeIsUniversal = lib.mkDefault (
          if cfg.hardwareClockInLocalTime then 0 else 1
        );
      })
      (lib.mkIf (cfg.autoTimeZone != null) {
        ${tzautoupdate}.Start = lib.mkDefault (if cfg.autoTimeZone then 3 else 4);
      })
    ];

    assertions = [
      {
        assertion = cfg.timeZone == null || resolved != null;
        message =
          "time.timeZone: ${toString cfg.timeZone} is neither an IANA name nor a Windows time-zone id"
          + (
            if sameButForCase != null then
              ''-- did you mean "${sameButForCase}"?''
            else
              ". See modules/system/time-zones.nix for both spellings."
          );
      }
      {
        assertion = cfg.ntp.enable != false || cfg.ntp.servers == [ ];
        message = "time.ntp.servers is set but time.ntp.enable is false; the machine would not use them";
      }
    ];
  };
}
