# The Xbox Game Bar and what Windows does around games: background capture,
# Game Mode, full-screen handling, GPU scheduling. Spans both scopes like
# privacy.nix: the per-user switches exist in a home configuration, the
# machine-wide policy and the driver setting in a system one.
{
  lib,
  config,
  winpkgsKind,
  ...
}:
let
  inherit (lib) types;
  sugar = import ./sugar.nix { inherit lib; };
  cfg = config.windows.gaming;

  gameBar = ''HKCU\Software\Microsoft\GameBar'';
  gameDvr = ''HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR'';
  gameConfig = ''HKCU\System\GameConfigStore'';
  gameDvrPolicy = ''HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR'';
  graphicsDrivers = ''HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'';

  settings = sugar.forKind winpkgsKind allSettings;
  allSettings = {
    gameMode = {
      key = gameBar;
      name = "AutoGameModeEnabled";
      type = types.bool;
      encode = sugar.on;
      description = "Let Windows switch into Game Mode when a game is running: fewer background tasks, no update installs mid-session.";
    };

    gameBarWithController = {
      key = gameBar;
      name = "UseNexusForGameBarEnabled";
      type = types.bool;
      encode = sugar.on;
      description = "Open the Xbox Game Bar with the Xbox button on a controller.";
    };

    captures = {
      keys = [
        gameDvr
        gameConfig
      ];
      type = types.bool;
      # Two switches for one feature: the Game Bar's and the one the game
      # configuration store keeps for the capture service. Off in both is
      # what removes the background recording overhead.
      writes = v: {
        ${gameDvr}.AppCaptureEnabled = sugar.on v;
        ${gameConfig}.GameDVR_Enabled = sugar.on v;
      };
      description = "Record game clips and screenshots with the Game Bar, including the background recording that lets it capture what already happened.";
    };

    fullscreenOptimizations = {
      keys = [ gameConfig ];
      type = types.bool;
      # Off is the two values the Compatibility tab writes for "disable
      # full-screen optimizations" applied to everything; on is their defaults.
      writes = v: {
        ${gameConfig} = {
          GameDVR_FSEBehaviorMode = sugar.pair 0 2 v;
          GameDVR_HonorUserFSEBehaviorMode = sugar.off v;
        };
      };
      description = "Run exclusive-full-screen games through the compositor's optimised borderless mode. Off is the old true full-screen exclusive path for every game at once.";
    };

    allowCaptures = {
      key = gameDvrPolicy;
      name = "AllowGameDVR";
      type = types.bool;
      encode = sugar.on;
      description = "Policy: whether game recording and broadcasting are available to any user at all. Machine scope: needs elevation.";
    };

    hardwareAcceleratedScheduling = {
      key = graphicsDrivers;
      name = "HwSchMode";
      type = types.bool;
      encode = sugar.pair 2 1;
      description = "Let the GPU manage its own video memory scheduling (Hardware-accelerated GPU scheduling). Needs a supporting driver and a restart. Machine scope: needs elevation.";
    };
  };
in
{
  options.windows.gaming = sugar.options settings;

  config.windows.registry = sugar.writes settings cfg;
}
