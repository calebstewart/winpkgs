# Light/dark, the accent colour and the wallpaper. None of these keys contains
# `\Explorer`, so this is the module `windows.explorer.restartKeys` exists for:
# without it a theme is written and nothing on screen changes.
#
# The wallpaper is not a registry write. Its values under Control Panel\Desktop
# are only read at logon; what repaints the desktop is a SystemParametersInfo
# call, which also writes them. So it is a resource of its own
# (winpkgs/wallpaper), fed from here. An image given as a Nix path travels in
# the closure and is placed under %LOCALAPPDATA%\winpkgs\wallpaper; a string is
# a Windows path already on the machine, such as one home.file wrote.
{ lib, config, ... }:
let
  inherit (lib) types mkOption;
  sugar = import ../common/sugar.nix { inherit lib; };
  color = import ../common/color.nix { inherit lib; };
  cfg = config.windows.theme;

  personalize = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'';
  dwm = ''HKCU\Software\Microsoft\Windows\DWM'';
  accent = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'';

  # A wallpaper image that is not already on the machine is carried there.
  image = cfg.wallpaper.image;
  onMachine = image != null && builtins.isString image && !(lib.hasPrefix "/" image);
  carried = image != null && !onMachine;
  carriedTarget = "%LOCALAPPDATA%/winpkgs/wallpaper/${baseNameOf (toString image)}";
  imagePath =
    if image == null then
      ""
    else if onMachine then
      image
    else
      lib.replaceStrings [ "/" ] [ "\\" ] carriedTarget;
  wantsWallpaper = image != null || cfg.background != null;

  settings = {
    accentColor = {
      keys = [
        accent
        dwm
      ];
      type = color.hex;
      # The colour lives in five places: the menu colour and the derived
      # palette the shell tints from, DWM's copy for window frames, and the
      # colorization pair Windows keeps at 0xC4 alpha. Start takes the first
      # darker shade, as Settings gives it.
      writes =
        hex:
        let
          c = color.parse hex;
        in
        {
          ${accent} = {
            AccentColorMenu = color.abgr 255 c;
            StartColorMenu = color.abgr 255 (color.darker c 0);
            AccentPalette = {
              type = "Binary";
              value = color.palette c;
            };
          };
          ${dwm} = {
            AccentColor = color.abgr 255 c;
            ColorizationColor = color.argb 196 c;
            ColorizationAfterglow = color.argb 196 c;
          };
        };
      example = "#d0000c";
      description = "The accent colour, as `#rrggbb`. What the shell, Start and title bars are tinted with when the two options below allow it.";
    };
    mode = {
      keys = [ personalize ];
      type = types.enum [
        "light"
        "dark"
      ];
      # Windows keeps two switches, one for applications and one for the shell.
      # Setting them apart is possible through `windows.registry`; wanting to is
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
  options.windows.theme = sugar.options settings // {
    wallpaper = {
      image = mkOption {
        type = types.nullOr (types.either types.path types.str);
        default = null;
        example = lib.literalExpression ''./wallpaper.jpg  # or "%USERPROFILE%\\Pictures\\wallpaper.jpg"'';
        description = ''
          The desktop image. A Nix path is copied to the machine (under
          `%LOCALAPPDATA%\winpkgs\wallpaper`); a string is a Windows path that
          is already there, `%VAR%` references allowed. `null` with
          `background` set is a solid colour; `null` alone leaves the desktop
          as it is.
        '';
      };
      fit = mkOption {
        type = types.enum [
          "fill"
          "fit"
          "stretch"
          "center"
          "tile"
          "span"
        ];
        default = "fill";
        description = "How the image is placed: Windows' Fill, Fit, Stretch, Center, Tile and Span.";
      };
    };
    background = mkOption {
      type = types.nullOr color.hex;
      default = null;
      example = "#1e1e2e";
      description = ''
        The desktop's solid colour, as `#rrggbb`: the whole desktop with no
        `wallpaper.image`, the bars beside an image that does not cover it.
        `null` leaves whatever the machine has.
      '';
    };
  };

  config = {
    windows.registry = sugar.writes settings cfg;
    windows.explorer.restartKeys = sugar.keys settings ++ [ dwm ];

    windows.files = lib.mkIf carried { ${carriedTarget}.source = image; };

    winpkgs.resources = lib.optional wantsWallpaper {
      type = "winpkgs/wallpaper";
      id = "Desktop";
      scope = "user";
      properties = {
        image = imagePath;
        inherit (cfg.wallpaper) fit;
        inherit (cfg) background;
      };
    };
  };
}
