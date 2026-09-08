# The Windows 11 taskbar. Mostly the same Explorer\Advanced key as
# `winpkgs.explorer`, kept separate because a taskbar setting and a file-manager
# setting have nothing to say to each other.
#
# Auto-hide is deliberately absent: it lives in a byte of the packed
# StuckRects3\Settings blob, and the registry resource writes whole values, so
# declaring it would clobber everything else packed alongside it.
{ lib, config, ... }:
let
  inherit (lib) types;
  sugar = import ./sugar.nix { inherit lib; };
  cfg = config.winpkgs.taskbar;

  advanced = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'';
  developerSettings = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'';
  search = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Search'';

  settings = {
    alignment = {
      key = advanced;
      name = "TaskbarAl";
      type = types.enum [
        "left"
        "center"
      ];
      encode = sugar.choice {
        left = 0;
        center = 1;
      };
      description = "Where taskbar icons sit.";
    };
    searchBox = {
      key = search;
      name = "SearchboxTaskbarMode";
      type = types.enum [
        "hidden"
        "icon"
        "box"
        "iconAndLabel"
      ];
      encode = sugar.choice {
        hidden = 0;
        icon = 1;
        box = 2;
        iconAndLabel = 3;
      };
      description = "How much room the search entry takes on the taskbar.";
    };
    taskViewButton = {
      key = advanced;
      name = "ShowTaskViewButton";
      type = types.bool;
      encode = sugar.on;
      description = "Show the Task View button.";
    };
    widgets = {
      key = advanced;
      name = "TaskbarDa";
      type = types.bool;
      encode = sugar.on;
      description = "Show the Widgets button.";
    };
    chat = {
      key = advanced;
      name = "TaskbarMn";
      type = types.bool;
      encode = sugar.on;
      description = "Show the Chat button.";
    };
    showOnAllDisplays = {
      key = advanced;
      name = "MMTaskbarEnabled";
      type = types.bool;
      encode = sugar.on;
      description = "Show a taskbar on every display, not only the primary one.";
    };
    showSecondsInClock = {
      key = advanced;
      name = "ShowSecondsInSystemClock";
      type = types.bool;
      encode = sugar.on;
      description = "Show seconds in the system clock.";
    };
    endTask = {
      key = developerSettings;
      name = "TaskbarEndTask";
      type = types.bool;
      encode = sugar.on;
      description = "Offer End Task in the right-click menu of a taskbar button.";
    };
    combineButtons = {
      keys = [ advanced ];
      type = types.enum [
        "always"
        "whenFull"
        "never"
      ];
      # Two values: the primary display and every other one. Wanting them to
      # disagree is not a thing anyone has ever wanted.
      writes =
        v:
        let
          n =
            {
              always = 0;
              whenFull = 1;
              never = 2;
            }
            .${v};
        in
        {
          ${advanced} = {
            TaskbarGlomLevel = n;
            MMTaskbarGlomLevel = n;
          };
        };
      description = "When several windows of one application share a single taskbar button.";
    };
  };
in
{
  options.winpkgs.taskbar = sugar.options settings;

  config = {
    winpkgs.registry = sugar.writes settings cfg;
    winpkgs.explorer.restartKeys = sugar.keys settings;
  };
}
