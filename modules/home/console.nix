# The classic console host's colours: what cmd, Windows PowerShell and any
# other program in a conhost window paints with. Sixteen table entries plus a
# default foreground and background, all under HKCU\Console, read when a
# window opens. Windows Terminal has its own settings file and ignores this.
#
# The table is named the ANSI way here (red is red) and written the Windows
# way, where the table runs blue-green-red and each entry is a 0x00BBGGRR
# dword. A base16 palette fills all eighteen at once, with the mapping the
# base16 shell scripts use; a colour set by hand wins over it.
{ lib, config, ... }:
let
  inherit (lib) mkOption types mkDefault;
  color = import ../common/color.nix { inherit lib; };
  cfg = config.windows.console;

  key = ''HKCU\Console'';

  # ANSI order. The Windows table index swaps the red and blue bits.
  ansi = [
    "black"
    "red"
    "green"
    "yellow"
    "blue"
    "magenta"
    "cyan"
    "white"
    "brightBlack"
    "brightRed"
    "brightGreen"
    "brightYellow"
    "brightBlue"
    "brightMagenta"
    "brightCyan"
    "brightWhite"
  ];
  windowsIndex =
    i:
    let
      red = lib.mod i 2;
      green = lib.mod (i / 2) 2;
      blue = lib.mod (i / 4) 2;
      bright = i / 8;
    in
    bright * 8 + red * 4 + green * 2 + blue;
  tableName = i: "ColorTable${lib.fixedWidthNumber 2 (windowsIndex i)}";

  # base16 -> the eighteen, as base16-shell assigns them.
  base16Slots = {
    black = "base00";
    red = "base08";
    green = "base0B";
    yellow = "base0A";
    blue = "base0D";
    magenta = "base0E";
    cyan = "base0C";
    white = "base05";
    brightBlack = "base03";
    brightRed = "base08";
    brightGreen = "base0B";
    brightYellow = "base0A";
    brightBlue = "base0D";
    brightMagenta = "base0E";
    brightCyan = "base0C";
    brightWhite = "base07";
    foreground = "base05";
    background = "base00";
  };
  # nix-colors palettes carry no leading '#'; accept either.
  fromPalette = slot: "#${lib.removePrefix "#" cfg.base16.${slot}}";

  dword = hex: color.abgr 0 (color.parse hex);
  colorOption =
    what:
    mkOption {
      type = types.nullOr color.hex;
      default = null;
      description = "${what}, as `#rrggbb`. `null` leaves whatever the machine has.";
    };

  colors = cfg.colors;
in
{
  options.windows.console = {
    colors = {
      foreground = colorOption "Default text colour";
      background = colorOption "Default background colour";
    }
    // lib.listToAttrs (map (n: lib.nameValuePair n (colorOption "ANSI ${n}")) ansi);

    base16 = mkOption {
      type = types.nullOr (types.attrsOf types.str);
      default = null;
      example = lib.literalExpression "config.colorScheme.palette";
      description = ''
        A base16 palette (`base00` .. `base0F`, with or without the leading
        `#`), such as nix-colors' `colorScheme.palette`. Fills every entry of
        `colors` the way the base16 shell scripts do: black is base00, red
        base08, green base0B, yellow base0A, blue base0D, magenta base0E, cyan
        base0C, white base05, bright black base03, bright white base07, the
        other bright colours their normal ones, text base05 on base00. An
        entry of `colors` set directly wins.
      '';
    };
  };

  config = {
    windows.console.colors = lib.mkIf (cfg.base16 != null) (
      lib.mapAttrs (_: slot: mkDefault (fromPalette slot)) base16Slots
    );

    # Only what is set: `null` in windows.registry would delete the value.
    windows.registry.${key} = lib.filterAttrs (_: v: v != null) (
      lib.listToAttrs (
        lib.imap0 (i: n: lib.nameValuePair (tableName i) (lib.mapNullable dword colors.${n})) ansi
      )
      // {
        DefaultForeground = lib.mapNullable dword colors.foreground;
        DefaultBackground = lib.mapNullable dword colors.background;
      }
    );
  };
}
