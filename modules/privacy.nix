# The things a fresh Windows install does that nobody asked it to: suggested
# apps that install themselves, advertising identifiers, web results in the
# Start menu, telemetry.
#
# The only module here that spans both scopes. The `HKLM` policies below make an
# apply want elevation; the runtime asks for it once, at the end, for all of
# them together.
{ lib, config, ... }:
let
  inherit (lib) types;
  sugar = import ./sugar.nix { inherit lib; };
  cfg = config.winpkgs.privacy;

  contentDelivery = ''HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'';
  advertising = ''HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'';
  search = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Search'';
  explorerPolicy = ''HKCU\Software\Policies\Microsoft\Windows\Explorer'';
  systemPolicy = ''HKLM\SOFTWARE\Policies\Microsoft\Windows\System'';
  dataCollection = ''HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection'';

  settings = {
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

    webSearchInStart = {
      keys = [
        explorerPolicy
        search
      ];
      type = types.bool;
      # Current builds obey the policy value; BingSearchEnabled is what older
      # ones read, and setting both costs nothing.
      writes = v: {
        ${explorerPolicy}.DisableSearchBoxSuggestions = sugar.off v;
        ${search}.BingSearchEnabled = sugar.on v;
      };
      description = "Include web results from Bing when searching from Start.";
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
  options.winpkgs.privacy = sugar.options settings;

  config = {
    winpkgs.registry = sugar.writes settings cfg;
    # Start reads its content and search settings once. The machine-scope
    # policies are not here: those want a sign-out, and restarting the shell
    # would not help.
    winpkgs.explorer.restartKeys = [
      contentDelivery
      search
    ];
  };
}
