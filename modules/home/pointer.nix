# The mouse pointer, as Settings > Accessibility > Mouse pointer has it: a
# style, a colour for the custom style, a size. One winpkgs/pointer resource;
# the cursor files come from the set the machine defines under that name,
# and SystemParametersInfo makes the change show.
{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  color = import ../common/color.nix { inherit lib; };
  cfg = config.windows.pointer;

  # Settings' four styles: the cursor set each uses (by the name the machine
  # defines it under), the name it shows for it, and the accessibility type.
  # The custom colour is the white set, tinted by Windows.
  styles = {
    white = {
      scheme = "Windows Aero";
      name = "Windows Default";
      type = 0;
    };
    black = {
      scheme = "Windows Black";
      name = "Windows Black";
      type = 1;
    };
    inverted = {
      scheme = "Windows Inverted";
      name = "Windows Inverted";
      type = 2;
    };
    custom = {
      scheme = "Windows Aero";
      name = "Windows Default";
      type = 3;
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
      description = "The pointer style: `white`, `black`, `inverted`, or `custom` with `color`. `null` leaves it.";
    };
    color = mkOption {
      type = types.nullOr color.hex;
      default = null;
      example = "#89b4fa";
      description = "The pointer colour for the `custom` style, as `#rrggbb`.";
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
        assertion = !(cfg.style == "custom" && cfg.color == null);
        message = "windows.pointer.style = \"custom\" needs windows.pointer.color";
      }
      {
        assertion = !(cfg.color != null && cfg.style != "custom");
        message = "windows.pointer.color only applies to style = \"custom\"";
      }
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
        inherit (cfg) color size;
      };
    };
  };
}
