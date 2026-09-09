# The mouse pointer: a style and a size, from the cursor sets the machine
# defines. One winpkgs/pointer resource; the files come from the set's own
# definition, and SystemParametersInfo makes the change show.
#
# What is not here, and why. On Windows 11, Settings renders every style --
# the custom colour and the fifteen-step size included -- from the SVGs in
# %WINDIR%\Cursors into per-user .cur files, and points the Cursors key at
# those. The stock sets are fixed-size files that Windows does not scale, so
# a size here is a set: each style's normal, large and extra-large variant,
# as the classic Mouse control panel offers them. A custom colour would mean
# rasterising the SVGs with the colour substituted and packing them with
# their hotspots, a sub-project of its own.
{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.windows.pointer;

  # Settings' styles: the cursor sets, by the names the machine defines them
  # under (the trailing parenthesis in the white extra-large one is Windows'
  # own), and the accessibility type code Settings keeps for the style
  # (observed on Windows 11; 6 is the custom colour).
  styles = {
    white = {
      type = 3;
      sets = {
        normal = "Windows Aero";
        large = "Windows Aero L";
        extraLarge = "Windows Aero XL)";
      };
    };
    black = {
      type = 4;
      sets = {
        normal = "Windows Black";
        large = "Windows Black (large)";
        extraLarge = "Windows Black (extra large)";
      };
    };
    inverted = {
      type = 5;
      sets = {
        normal = "Windows Inverted";
        large = "Windows Inverted (large)";
        extraLarge = "Windows Inverted (extra large)";
      };
    };
  };
  style = if cfg.style == null then null else styles.${cfg.style};
  scheme = if style != null then style.sets.${cfg.size} else cfg.scheme;
in
{
  options.windows.pointer = {
    style = mkOption {
      type = types.nullOr (types.enum (lib.attrNames styles));
      default = null;
      example = "black";
      description = "The pointer style: `white`, `black` or `inverted`. `null` leaves it.";
    };
    size = mkOption {
      type = types.enum [
        "normal"
        "large"
        "extraLarge"
      ];
      default = "normal";
      example = "large";
      description = "The size of the `style`'s set: the normal, large or extra-large variant Windows ships of it.";
    };
    scheme = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "Windows Black (large)";
      description = ''
        A cursor set by the name the machine defines it under, instead of a
        `style`: one of Windows' own or one a cursor pack installed. The
        machine's definition supplies the files.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = !(cfg.style != null && cfg.scheme != null);
        message = "windows.pointer: set either style or scheme, not both";
      }
    ];

    winpkgs.resources = lib.optional (scheme != null) {
      type = "winpkgs/pointer";
      id = "Pointer";
      scope = "user";
      properties = {
        inherit scheme;
        name = scheme;
        type = if style != null then style.type else null;
      };
    };
  };
}
