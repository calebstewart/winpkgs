# The things a fresh Windows install does that nobody asked it to: suggested
# apps that install themselves, advertising identifiers, web results in the
# Start menu, telemetry.
#
# Spans both scopes, so it is imported by both kinds of configuration and each
# declares only its half: the `HKCU` settings exist in a home configuration,
# the `HKLM` policies in a system configuration.
{
  lib,
  config,
  winpkgsKind,
  ...
}:
let
  inherit (lib) types;
  sugar = import ./sugar.nix { inherit lib; };
  cfg = config.windows.privacy;

  contentDelivery = ''HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'';
  advertising = ''HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'';
  search = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Search'';
  explorerPolicy = ''HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer'';
  systemPolicy = ''HKLM\SOFTWARE\Policies\Microsoft\Windows\System'';
  dataCollection = ''HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection'';

  settings = sugar.forKind winpkgsKind allSettings;
  allSettings = {
    advertisingId = {
      key = advertising;
      name = "Enabled";
      type = types.bool;
      encode = sugar.on;
      description = "Let applications use an advertising ID to profile you across them.";
    };

    suggestedContent = {
      keys = [ contentDelivery ];
      type = types.bool;
      # Content Delivery Manager has one value per surface it can advertise on
      # and no master switch, so one option covers the lot.
      writes =
        v:
        let
          n = sugar.on v;
        in
        {
          ${contentDelivery} = {
            "SubscribedContent-338393Enabled" = n; # settings app
            "SubscribedContent-353694Enabled" = n; # settings app, second surface
            "SubscribedContent-353696Enabled" = n; # settings app, third surface
            SoftLandingEnabled = n; # post-update "here's what's new"
            SystemPaneSuggestionsEnabled = n; # Start menu
            RotatingLockScreenOverlayEnabled = n; # lock screen
          };
        };
      description = "Show suggested content -- tips, promotions and Spotlight overlays -- in Start, Settings and the lock screen.";
    };

    suggestedApps = {
      keys = [ contentDelivery ];
      type = types.bool;
      writes =
        v:
        let
          n = sugar.on v;
        in
        {
          ${contentDelivery} = {
            SilentInstalledAppsEnabled = n;
            PreInstalledAppsEnabled = n;
            OemPreInstalledAppsEnabled = n;
          };
        };
      description = "Let Windows install suggested and OEM-bundled applications on its own after a sign-in or an update.";
    };

    tips = {
      key = contentDelivery;
      name = "SubscribedContent-338389Enabled";
      type = types.bool;
      encode = sugar.on;
      description = "Show tips, tricks and suggestions as notifications.";
    };

    # One option, one half per kind, because the two values Windows reads for
    # this live in different hives. The policy is what current builds obey and
    # it is machine-wide; BingSearchEnabled is what older ones read and it is
    # per-user. Setting both is still the complete answer -- it now takes both
    # configurations, which is what declaring a machine-wide policy has always
    # meant here.
    #
    # The policy half used to be written to HKCU\Software\Policies from the home
    # configuration. That subtree is ReadKey for the user on any profile a
    # recent Windows created, so the write failed and took the whole apply with
    # it; it only ever succeeded on profiles old enough to predate Microsoft
    # tightening the default.
    webSearchInStart =
      if winpkgsKind == "system" then
        {
          key = explorerPolicy;
          name = "DisableSearchBoxSuggestions";
          type = types.bool;
          encode = sugar.off;
          description = "Include web results from Bing when searching from Start (the machine-wide policy current builds obey; the per-user half is the option of the same name in a home configuration).";
        }
      else
        {
          key = search;
          name = "BingSearchEnabled";
          type = types.bool;
          encode = sugar.on;
          description = "Include web results from Bing when searching from Start (what older builds read; current ones obey the machine-wide policy, which is the option of the same name in a system configuration).";
        };

    activityFeed = {
      keys = [ systemPolicy ];
      type = types.bool;
      writes =
        v:
        let
          n = sugar.on v;
        in
        {
          ${systemPolicy} = {
            EnableActivityFeed = n;
            PublishUserActivities = n;
            UploadUserActivities = n;
          };
        };
      description = "Record and upload an activity history (Timeline). Machine scope: needs elevation.";
    };

    telemetry = {
      key = dataCollection;
      name = "AllowTelemetry";
      type = types.enum [
        "security"
        "required"
        "enhanced"
        "optional"
      ];
      encode = sugar.choice {
        security = 0;
        required = 1;
        enhanced = 2;
        optional = 3;
      };
      description = ''
        How much diagnostic data Windows sends. `security` is honoured only on
        Enterprise, Education and IoT; every other edition treats it as
        `required`, which is the real floor. Machine scope: needs elevation.
      '';
    };
  };
in
{
  options.windows.privacy = sugar.options settings;

  config = {
    windows.registry = sugar.writes settings cfg;
    # Start reads its content and search settings once. The machine-scope
    # policies are not here: those want a sign-out, and restarting the shell
    # would not help.
    windows.explorer.restartKeys = [
      contentDelivery
      search
    ];
  };
}
