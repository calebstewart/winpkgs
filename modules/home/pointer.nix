# The mouse pointer, as Settings > Accessibility > Mouse pointer has it: a
# style and a size. One winpkgs/pointer resource; the cursor files come from
# the set the machine defines under that name, and SystemParametersInfo
# makes the change show.
#
# Not here: a custom colour. On Windows 11, Settings renders every style --
# the custom one included -- from the SVGs in %WINDIR%\Cursors into per-user
# .cur files at the chosen size and colour, and points the Cursors key at
# those. Reproducing that means rasterising the SVGs with the colour
# substituted and packing them with their hotspots, a sub-project of its
# own; until then the three stock sets are what winpkgs can apply faithfully.
{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.windows.pointer;

  # Settings' styles: the cursor set each uses (by the name the machine
  # defines it under), the name it shows for it, and the accessibility type
  # code Settings writes for it (observed on Windows 11; 6 is the custom
  # colour).
  styles = {
    white = {
      scheme = "Windows Aero";
      name = "Windows Aero";
      type = 3;
    };
    black = {
      scheme = "Windows Black";
      name = "Windows Black";
      type = 4;
    };
    inverted = {
      scheme = "Windows Inverted";
      name = "Windows Inverted";
      type = 5;
    };
  };
  style = if cfg.style == null then null else styles.${cfg.style};

  wanted = cfg.style != null || cfg.scheme != null || cfg.size != null;
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
      type = types.nullOr (types.ints.between 1 15);
      default = null;
      example = 3;
      description = "The pointer size, on Settings' scale of 1 to 15. `null` leaves it.";
    };
    scheme = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "Windows Black (large)";
      description = ''
        A cursor set by the name the machine defines it under, instead of a
        `style`: one of Windows' own (`Windows Aero`, `Windows Black (extra
        large)`, ...) or one a cursor pack installed. The machine's
        definition supplies the files.
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

    winpkgs.resources = lib.optional wanted {
      type = "winpkgs/pointer";
      id = "Pointer";
      scope = "user";
      properties = {
        scheme = if style != null then style.scheme else cfg.scheme;
        name = if style != null then style.name else cfg.scheme;
        type = if style != null then style.type else null;
        inherit (cfg) size;
      };
    };
  };
}
