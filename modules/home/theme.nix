# Light/dark and the accent colour. None of these keys contains `\Explorer`, so
# this is the module `winpkgs.explorer.restartKeys` exists for: without it a
# theme is written and nothing on screen changes.
#
# Wallpaper is not here. Its registry values do not repaint the desktop on their
# own -- that needs a SystemParametersInfo call, so it wants a resource of its
# own rather than a registry write.
{ lib, config, ... }:
let
  inherit (lib) types;
  sugar = import ../common/sugar.nix { inherit lib; };
  cfg = config.winpkgs.theme;

  personalize = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'';
  dwm = ''HKCU\Software\Microsoft\Windows\DWM'';

  settings = {
    mode = {
      keys = [ personalize ];
      type = types.enum [
        "light"
        "dark"
      ];
      # Windows keeps two switches, one for applications and one for the shell.
      # Setting them apart is possible through `winpkgs.registry`; wanting to is
      # rare enough not to model.
      writes =
        m:
        let
          n = if m == "light" then 1 else 0;
        in
        {
          ${personalize} = {
            AppsUseLightTheme = n;
            SystemUsesLightTheme = n;
          };
        };
      description = "Light or dark, for applications and the shell alike.";
    };
    transparency = {
      key = personalize;
      name = "EnableTransparency";
      type = types.bool;
      encode = sugar.on;
      description = "Give the taskbar, Start and other shell surfaces a transparent background.";
    };
    accentOnStartAndTaskbar = {
      key = personalize;
      name = "ColorPrevalence";
      type = types.bool;
      encode = sugar.on;
      description = "Tint Start, the taskbar and the action centre with the accent colour.";
    };
    accentOnTitleBars = {
      key = dwm;
      name = "ColorPrevalence";
      type = types.bool;
      encode = sugar.on;
      description = "Tint title bars and window borders with the accent colour.";
    };
  };
in
{
  options.winpkgs.theme = sugar.options settings;

  config = {
    winpkgs.registry = sugar.writes settings cfg;
    winpkgs.explorer.restartKeys = sugar.keys settings ++ [ dwm ];
  };
}
